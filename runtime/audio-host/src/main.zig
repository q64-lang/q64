//! q64-clap — a native CLAP plugin that embeds wasmtime and runs a
//! q64-compiled wasm32 audio module (docs/audio-roadmap.md phase D3,
//! target 2). The native sibling of `q64/src/codegen/wclap.zig`: it
//! consumes the SAME guest plugin convention (spec/audio-face.md
//! §interim convention) — it never emulates the browser WCLAP table
//! ABI, it just calls the guest exports from native CLAP callbacks.
//!
//! v1 requires the full convention (the `examples/audio-poly` surface):
//!   alloc_f32, state_cells, prepare, note_on, note_off, process,
//!   param_count, param_info, param_name, set_param, get_param
//! (`midi` optional). The wasm ships beside the plugin: `q64.wasm` next
//! to the `.clap`, or the `Q64_CLAP_WASM` env var overrides.
//!
//! Audio path: the guest renders into a guest-side Vec<f32> io buffer
//! (allocated at activate, `max_frames` cells); event application is
//! sample-offset-accurate via the same split-the-block walk the WCLAP
//! shim does — per segment the host rewrites the io vec header in guest
//! memory (data += pos·4, len = segment) and calls guest `process`. One
//! copy-out per block moves the rendered frames from guest linear
//! memory into the host's channel buffers (ch1 mirrors ch0).
//!
//! Threading: all guest calls take one mutex. CLAP splits main-thread
//! (params) from audio-thread (process); a wasmtime store is not
//! thread-safe, so v1 serializes — fine for the render workload, and
//! honest about it.

const std = @import("std");
const clap = @import("clap.zig");

const c = @cImport({
    @cInclude("wasmtime.h");
});

const gpa = std.heap.c_allocator;

// The handful of libc calls the plugin needs (this std's file API needs
// an Io instance a shared library doesn't have).
const libc = struct {
    const FILE = opaque {};
    extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern fn fclose(f: *FILE) c_int;
    extern fn fseek(f: *FILE, offset: c_long, whence: c_int) c_int;
    extern fn ftell(f: *FILE) c_long;
    extern fn fread(buf: [*]u8, item: usize, n: usize, f: *FILE) usize;
    extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

// ---- the single-instance runtime state --------------------------------

const Guest = struct {
    engine: *c.wasm_engine_t,
    store: *c.wasmtime_store_t,
    context: *c.wasmtime_context_t,
    instance: c.wasmtime_instance_t,
    memory: c.wasmtime_memory_t,
    // required guest exports (the plugin convention)
    alloc_f32: c.wasmtime_func_t,
    state_cells: c.wasmtime_func_t,
    prepare: c.wasmtime_func_t,
    note_on: c.wasmtime_func_t,
    note_off: c.wasmtime_func_t,
    process: c.wasmtime_func_t,
    param_count: c.wasmtime_func_t,
    param_info: c.wasmtime_func_t,
    param_name: c.wasmtime_func_t,
    set_param: c.wasmtime_func_t,
    get_param: c.wasmtime_func_t,
    midi: ?c.wasmtime_func_t,
    // runtime handles
    st_head: i32 = 0,
    io_head: i32 = 0,
    io_data: u32 = 0,
    max_frames: u32 = 0,
};

var g_guest: ?Guest = null;
// This Zig's std.atomic.Mutex is try-lock only; the critical sections
// here are short (one guest call), so a spin acquire is fine.
var g_mutex: std.atomic.Mutex = .unlocked;

fn lockGuest() void {
    while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn mem(g: *Guest) []u8 {
    const data = c.wasmtime_memory_data(g.context, &g.memory);
    const size = c.wasmtime_memory_data_size(g.context, &g.memory);
    return data[0..size];
}

const CallError = error{ Trap, Error };

fn call(g: *Guest, f: *const c.wasmtime_func_t, args: []const c.wasmtime_val_t, results: []c.wasmtime_val_t) CallError!void {
    var trap: ?*c.wasm_trap_t = null;
    const err = c.wasmtime_func_call(g.context, f, if (args.len > 0) args.ptr else null, args.len, if (results.len > 0) results.ptr else null, results.len, &trap);
    if (err) |e| {
        c.wasmtime_error_delete(e);
        return CallError.Error;
    }
    if (trap) |t| {
        c.wasm_trap_delete(t);
        return CallError.Trap;
    }
}

fn vi32(x: i32) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = x } };
}
fn vi64(x: i64) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_I64, .of = .{ .i64 = x } };
}
fn vf32(x: f32) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_F32, .of = .{ .f32 = x } };
}
fn vf64(x: f64) c.wasmtime_val_t {
    return .{ .kind = c.WASMTIME_F64, .of = .{ .f64 = x } };
}

/// call a guest fn returning one i64 (the convention's status/handle type)
fn call1i64(g: *Guest, f: *const c.wasmtime_func_t, args: []const c.wasmtime_val_t) CallError!i64 {
    var results = [_]c.wasmtime_val_t{vi64(0)};
    try call(g, f, args, &results);
    return results[0].of.i64;
}

fn call1f64(g: *Guest, f: *const c.wasmtime_func_t, args: []const c.wasmtime_val_t) CallError!f64 {
    var results = [_]c.wasmtime_val_t{vf64(0)};
    try call(g, f, args, &results);
    return results[0].of.f64;
}

fn exportFunc(context: *c.wasmtime_context_t, instance: *c.wasmtime_instance_t, name: []const u8) ?c.wasmtime_func_t {
    var item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(context, instance, name.ptr, name.len, &item)) return null;
    if (item.kind != c.WASMTIME_EXTERN_FUNC) return null;
    return item.of.func;
}

// ---- entry ------------------------------------------------------------

fn entryInit(plugin_path: [*:0]const u8) callconv(.c) bool {
    lockGuest();
    defer g_mutex.unlock();
    if (g_guest != null) return true;

    // Resolve the wasm: Q64_CLAP_WASM wins; else q64.wasm beside the .clap.
    const path_slice = std.mem.span(plugin_path);
    var wasm_path_buf: [4096]u8 = undefined;
    const wasm_path: []const u8 = blk: {
        if (libc.getenv("Q64_CLAP_WASM")) |envp| {
            const p = std.mem.span(envp);
            if (p.len > 0 and p.len < wasm_path_buf.len) {
                @memcpy(wasm_path_buf[0..p.len], p);
                break :blk wasm_path_buf[0..p.len];
            }
        }
        const dir = std.fs.path.dirname(path_slice) orelse ".";
        const joined = std.fmt.bufPrint(&wasm_path_buf, "{s}/q64.wasm", .{dir}) catch return false;
        break :blk joined;
    };

    // libc file read — a shared library has no std.Io instance to thread.
    var path_z_buf: [4096]u8 = undefined;
    if (wasm_path.len >= path_z_buf.len) return false;
    @memcpy(path_z_buf[0..wasm_path.len], wasm_path);
    path_z_buf[wasm_path.len] = 0;
    const fh = libc.fopen(path_z_buf[0..wasm_path.len :0].ptr, "rb") orelse return false;
    defer _ = libc.fclose(fh);
    if (libc.fseek(fh, 0, 2) != 0) return false; // SEEK_END
    const fsize = libc.ftell(fh);
    if (fsize <= 0) return false;
    if (libc.fseek(fh, 0, 0) != 0) return false; // SEEK_SET
    const size: usize = @intCast(fsize);
    const bytes = gpa.alloc(u8, size) catch return false;
    defer gpa.free(bytes);
    if (libc.fread(bytes.ptr, 1, size, fh) != size) return false;

    const engine = c.wasm_engine_new() orelse return false;
    errdefer c.wasm_engine_delete(engine);
    const store = c.wasmtime_store_new(engine, null, null) orelse {
        c.wasm_engine_delete(engine);
        return false;
    };
    const context = c.wasmtime_store_context(store).?;

    var module: ?*c.wasmtime_module_t = null;
    if (c.wasmtime_module_new(engine, bytes.ptr, bytes.len, &module)) |e| {
        c.wasmtime_error_delete(e);
        c.wasmtime_store_delete(store);
        c.wasm_engine_delete(engine);
        return false;
    }
    defer c.wasmtime_module_delete(module);

    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasm_trap_t = null;
    // q64 audio modules are import-free; instantiate directly.
    if (c.wasmtime_instance_new(context, module, null, 0, &instance, &trap)) |e| {
        c.wasmtime_error_delete(e);
        c.wasmtime_store_delete(store);
        c.wasm_engine_delete(engine);
        return false;
    }
    if (trap) |t| {
        c.wasm_trap_delete(t);
        c.wasmtime_store_delete(store);
        c.wasm_engine_delete(engine);
        return false;
    }

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(context, &instance, "memory", "memory".len, &memory_item) or memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        c.wasmtime_store_delete(store);
        c.wasm_engine_delete(engine);
        return false;
    }

    const req = struct {
        fn f(ctx: *c.wasmtime_context_t, inst: *c.wasmtime_instance_t, name: []const u8) ?c.wasmtime_func_t {
            return exportFunc(ctx, inst, name);
        }
    }.f;
    const names = [_][]const u8{ "alloc_f32", "state_cells", "prepare", "note_on", "note_off", "process", "param_count", "param_info", "param_name", "set_param", "get_param" };
    var fns: [names.len]c.wasmtime_func_t = undefined;
    for (names, 0..) |nm, i| {
        fns[i] = req(context, &instance, nm) orelse {
            c.wasmtime_store_delete(store);
            c.wasm_engine_delete(engine);
            return false;
        };
    }

    g_guest = Guest{
        .engine = engine,
        .store = store,
        .context = context,
        .instance = instance,
        .memory = memory_item.of.memory,
        .alloc_f32 = fns[0],
        .state_cells = fns[1],
        .prepare = fns[2],
        .note_on = fns[3],
        .note_off = fns[4],
        .process = fns[5],
        .param_count = fns[6],
        .param_info = fns[7],
        .param_name = fns[8],
        .set_param = fns[9],
        .get_param = fns[10],
        .midi = exportFunc(context, &instance, "midi"),
    };
    return true;
}

fn entryDeinit() callconv(.c) void {
    lockGuest();
    defer g_mutex.unlock();
    if (g_guest) |*g| {
        c.wasmtime_store_delete(g.store);
        c.wasm_engine_delete(g.engine);
        g_guest = null;
    }
}

// ---- plugin lifecycle -------------------------------------------------

fn pluginInit(_: *const clap.Plugin) callconv(.c) bool {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return false);
    const cells = call1i64(g, &g.state_cells, &.{}) catch return false;
    var args = [_]c.wasmtime_val_t{vi64(cells)};
    const head = call1i64(g, &g.alloc_f32, &args) catch return false;
    g.st_head = @intCast(head);
    return true;
}

fn pluginDestroy(_: *const clap.Plugin) callconv(.c) void {}

fn pluginActivate(_: *const clap.Plugin, sample_rate: f64, _: u32, max_frames: u32) callconv(.c) bool {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return false);
    var aargs = [_]c.wasmtime_val_t{vi64(@intCast(max_frames))};
    const io = call1i64(g, &g.alloc_f32, &aargs) catch return false;
    g.io_head = @intCast(io);
    g.max_frames = max_frames;
    // The io buffer's element-data address, read from the vec header
    // {data, len, cap} the guest handed us.
    const m = mem(g);
    g.io_data = std.mem.readInt(u32, m[@intCast(g.io_head)..][0..4], .little);
    var pargs = [_]c.wasmtime_val_t{ vi32(g.st_head), vf64(sample_rate) };
    _ = call1i64(g, &g.prepare, &pargs) catch return false;
    return true;
}

fn pluginDeactivate(_: *const clap.Plugin) callconv(.c) void {}
fn pluginStartProcessing(_: *const clap.Plugin) callconv(.c) bool {
    return true;
}
fn pluginStopProcessing(_: *const clap.Plugin) callconv(.c) void {}
fn pluginReset(_: *const clap.Plugin) callconv(.c) void {}
fn pluginOnMainThread(_: *const clap.Plugin) callconv(.c) void {}

// ---- events -----------------------------------------------------------

fn applyOne(g: *Guest, ev: *const clap.EventHeader) void {
    if (ev.space_id != clap.core_event_space) return;
    switch (ev.type) {
        clap.event_param_value => {
            const pe: *const clap.EventParamValue = @alignCast(@ptrCast(ev));
            var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi64(pe.param_id), vf64(pe.value) };
            _ = call1i64(g, &g.set_param, &args) catch {};
        },
        clap.event_note_on => {
            const ne: *const clap.EventNote = @alignCast(@ptrCast(ev));
            if (ne.key < 0 or ne.key > 127) return;
            const vel: f32 = @floatCast(std.math.clamp(ne.velocity, 0.0, 1.0));
            var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi64(ne.key), vf32(vel) };
            _ = call1i64(g, &g.note_on, &args) catch {};
        },
        clap.event_note_off, clap.event_note_choke => {
            const ne: *const clap.EventNote = @alignCast(@ptrCast(ev));
            var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi64(ne.key) };
            _ = call1i64(g, &g.note_off, &args) catch {};
        },
        clap.event_midi => {
            const me: *const clap.EventMidi = @alignCast(@ptrCast(ev));
            if (g.midi) |*mf| {
                var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi64(me.data[0]), vi64(me.data[1]), vi64(me.data[2]) };
                _ = call1i64(g, mf, &args) catch {};
            }
        },
        else => {},
    }
}

/// Render frames [pos, pos+len) of the current block: point the guest io
/// vec header at the offset, call guest process.
fn renderSeg(g: *Guest, pos: u32, len: u32) void {
    if (len == 0) return;
    const m = mem(g);
    const hdr: usize = @intCast(g.io_head);
    std.mem.writeInt(u32, m[hdr..][0..4], g.io_data + pos * 4, .little);
    std.mem.writeInt(u32, m[hdr + 4 ..][0..4], len, .little);
    std.mem.writeInt(u32, m[hdr + 8 ..][0..4], len, .little);
    var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi32(g.io_head), vi64(@intCast(len)) };
    _ = call1i64(g, &g.process, &args) catch {};
}

fn pluginProcess(_: *const clap.Plugin, process: *const clap.Process) callconv(.c) i32 {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return clap.process_error);
    const frames = process.frames_count;
    if (frames > g.max_frames) return clap.process_error;

    // Sample-offset event walk, same algorithm as the WCLAP shim: render
    // up to each event's time, apply it, render the remainder.
    var pos: u32 = 0;
    if (process.in_events) |list| {
        const n = list.size(list);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const ev = list.get(list, i) orelse continue;
            var t = ev.time;
            if (t > frames) t = frames;
            if (t > pos) {
                renderSeg(g, pos, t - pos);
                pos = t;
            }
            applyOne(g, ev);
        }
    }
    if (process.audio_outputs_count == 0 or process.audio_outputs == null) return clap.process_continue;
    renderSeg(g, pos, frames - pos);

    // Copy the rendered block out of guest memory into the host buffers.
    const m = mem(g);
    const src = std.mem.bytesAsSlice(f32, m[@intCast(g.io_data)..][0 .. frames * 4]);
    const out = &process.audio_outputs.?[0];
    if (out.data32) |chans| {
        var ch: u32 = 0;
        while (ch < out.channel_count) : (ch += 1) {
            @memcpy(chans[ch][0..frames], src);
        }
    }
    return clap.process_continue;
}

// ---- clap.params (served from the guest's table) ----------------------

fn paramsCount(_: *const clap.Plugin) callconv(.c) u32 {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return 0);
    const n = call1i64(g, &g.param_count, &.{}) catch return 0;
    return @intCast(n);
}

fn guestParamField(g: *Guest, index: u32, field: i64) f64 {
    var args = [_]c.wasmtime_val_t{ vi64(index), vi64(field) };
    return call1f64(g, &g.param_info, &args) catch 0;
}

fn paramsGetInfo(_: *const clap.Plugin, index: u32, info: *clap.ParamInfo) callconv(.c) bool {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return false);
    const n = call1i64(g, &g.param_count, &.{}) catch return false;
    if (index >= n) return false;
    info.* = std.mem.zeroes(clap.ParamInfo);
    info.id = @intFromFloat(guestParamField(g, index, 0));
    info.flags = @intFromFloat(guestParamField(g, index, 4));
    info.min_value = guestParamField(g, index, 1);
    info.max_value = guestParamField(g, index, 2);
    info.default_value = guestParamField(g, index, 3);
    var j: u32 = 0;
    while (j < 255) : (j += 1) {
        var nargs = [_]c.wasmtime_val_t{ vi64(index), vi64(j) };
        const ch = call1i64(g, &g.param_name, &nargs) catch 0;
        info.name[j] = @intCast(ch & 0xff);
        if (ch == 0) break;
    }
    return true;
}

fn paramsGetValue(_: *const clap.Plugin, id: u32, out: *f64) callconv(.c) bool {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return false);
    const n = call1i64(g, &g.param_count, &.{}) catch return false;
    if (id >= n) return false;
    var args = [_]c.wasmtime_val_t{ vi32(g.st_head), vi64(id) };
    out.* = call1f64(g, &g.get_param, &args) catch return false;
    return true;
}

fn paramsValueToText(_: *const clap.Plugin, _: u32, _: f64, _: [*]u8, _: u32) callconv(.c) bool {
    return false; // host default formatting
}
fn paramsTextToValue(_: *const clap.Plugin, _: [*:0]const u8, _: *f64) callconv(.c) bool {
    return false;
}

fn paramsFlush(_: *const clap.Plugin, in: ?*const clap.InputEvents, _: ?*const clap.OutputEvents) callconv(.c) void {
    lockGuest();
    defer g_mutex.unlock();
    const g = &(g_guest orelse return);
    const list = in orelse return;
    const n = list.size(list);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (list.get(list, i)) |ev| applyOne(g, ev);
    }
}

const params_ext = clap.PluginParams{
    .count = paramsCount,
    .get_info = paramsGetInfo,
    .get_value = paramsGetValue,
    .value_to_text = paramsValueToText,
    .text_to_value = paramsTextToValue,
    .flush = paramsFlush,
};

// ---- clap.audio-ports / clap.note-ports -------------------------------

fn audioPortsCount(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 0 else 1;
}

fn audioPortsGet(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.AudioPortInfo) callconv(.c) bool {
    if (is_input or index != 0) return false;
    info.* = std.mem.zeroes(clap.AudioPortInfo);
    info.id = 0;
    @memcpy(info.name[0..4], "out\x00");
    info.flags = clap.audio_port_is_main;
    info.channel_count = 2;
    info.port_type = "stereo";
    info.in_place_pair = std.math.maxInt(u32); // CLAP_INVALID_ID
    return true;
}

const audio_ports_ext = clap.PluginAudioPorts{
    .count = audioPortsCount,
    .get = audioPortsGet,
};

fn notePortsCount(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
    return if (is_input) 1 else 0;
}

fn notePortsGet(_: *const clap.Plugin, index: u32, is_input: bool, info: *clap.NotePortInfo) callconv(.c) bool {
    if (!is_input or index != 0) return false;
    info.* = std.mem.zeroes(clap.NotePortInfo);
    info.id = 0;
    info.supported_dialects = clap.note_dialect_clap | clap.note_dialect_midi;
    info.preferred_dialect = clap.note_dialect_clap;
    @memcpy(info.name[0..6], "notes\x00");
    return true;
}

const note_ports_ext = clap.PluginNotePorts{
    .count = notePortsCount,
    .get = notePortsGet,
};

fn pluginGetExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const s = std.mem.span(id);
    if (std.mem.eql(u8, s, "clap.params")) return &params_ext;
    if (std.mem.eql(u8, s, "clap.audio-ports")) return &audio_ports_ext;
    if (std.mem.eql(u8, s, "clap.note-ports")) return &note_ports_ext;
    return null;
}

// ---- descriptor / factory / entry -------------------------------------

const features = [_:null]?[*:0]const u8{ "instrument", "synthesizer" };

const descriptor = clap.PluginDescriptor{
    .clap_version = clap.version_1_2_2,
    .id = "dev.q64.poly",
    .name = "q64 Poly",
    .vendor = "q64",
    .url = "https://q64.dev",
    .manual_url = "",
    .support_url = "",
    .version = "0.1.0",
    .description = "A q64-compiled wasm synth running in-process via wasmtime.",
    .features = &features,
};

const plugin = clap.Plugin{
    .desc = &descriptor,
    .plugin_data = null,
    .init = pluginInit,
    .destroy = pluginDestroy,
    .activate = pluginActivate,
    .deactivate = pluginDeactivate,
    .start_processing = pluginStartProcessing,
    .stop_processing = pluginStopProcessing,
    .reset = pluginReset,
    .process = pluginProcess,
    .get_extension = pluginGetExtension,
    .on_main_thread = pluginOnMainThread,
};

fn factoryGetPluginCount(_: *const clap.PluginFactory) callconv(.c) u32 {
    return 1;
}

fn factoryGetPluginDescriptor(_: *const clap.PluginFactory, index: u32) callconv(.c) ?*const clap.PluginDescriptor {
    return if (index == 0) &descriptor else null;
}

fn factoryCreatePlugin(_: *const clap.PluginFactory, _: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const clap.Plugin {
    return &plugin;
}

const factory = clap.PluginFactory{
    .get_plugin_count = factoryGetPluginCount,
    .get_plugin_descriptor = factoryGetPluginDescriptor,
    .create_plugin = factoryCreatePlugin,
};

fn entryGetFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (std.mem.eql(u8, std.mem.span(factory_id), "clap.plugin-factory")) return &factory;
    return null;
}

export const clap_entry = clap.PluginEntry{
    .clap_version = clap.version_1_2_2,
    .init = entryInit,
    .deinit = entryDeinit,
    .get_factory = entryGetFactory,
};
