//! q64-clap-check — an honest minimal native CLAP host. It loads the
//! plugin exactly like a DAW does: dlopen the `.clap`, resolve the
//! `clap_entry` symbol, walk entry → factory → descriptor → plugin, and
//! drive the full lifecycle with real clap_process blocks and real
//! input-event lists. The native sibling of examples/audio-poly's
//! check.mjs; the same behaviors are asserted in the rendered audio.
//!
//!   q64-clap-check <path/to/libq64clap.so> [path/to/q64.wasm]

const std = @import("std");
const clap = @import("clap");

const SR = 48000.0;
const FRAMES: u32 = 128;

var pending: std.ArrayListUnmanaged(*const clap.EventHeader) = .empty;

fn evSize(_: *const clap.InputEvents) callconv(.c) u32 {
    return @intCast(pending.items.len);
}
fn evGet(_: *const clap.InputEvents, i: u32) callconv(.c) ?*const clap.EventHeader {
    if (i >= pending.items.len) return null;
    return pending.items[i];
}

fn hostGetExtension(_: *const clap.Host, _: [*:0]const u8) callconv(.c) ?*const anyopaque {
    return null;
}
fn hostNop(_: *const clap.Host) callconv(.c) void {}

const host = clap.Host{
    .clap_version = clap.version_1_2_2,
    .host_data = null,
    .name = "q64-clap-check",
    .vendor = "q64",
    .url = "https://q64.dev",
    .version = "0.1.0",
    .get_extension = hostGetExtension,
    .request_restart = hostNop,
    .request_process = hostNop,
    .request_callback = hostNop,
};

fn noteEvent(a: std.mem.Allocator, kind: u16, key: i16, velocity: f64, time: u32) !*const clap.EventHeader {
    const ev = try a.create(clap.EventNote);
    ev.* = .{
        .header = .{ .size = @sizeOf(clap.EventNote), .time = time, .space_id = 0, .type = kind, .flags = 0 },
        .note_id = -1,
        .port_index = 0,
        .channel = 0,
        .key = key,
        .velocity = velocity,
    };
    return &ev.header;
}

fn paramEvent(a: std.mem.Allocator, id: u32, value: f64) !*const clap.EventHeader {
    const ev = try a.create(clap.EventParamValue);
    ev.* = .{
        .header = .{ .size = @sizeOf(clap.EventParamValue), .time = 0, .space_id = 0, .type = clap.event_param_value, .flags = 0 },
        .param_id = id,
        .cookie = null,
        .note_id = -1,
        .port_index = -1,
        .channel = -1,
        .key = -1,
        .value = value,
    };
    return &ev.header;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("q64-clap-check: FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn measurePeriod(samples: []const f32) f64 {
    var first: i64 = -1;
    var last: i64 = -1;
    var count: u32 = 0;
    var i: usize = 1;
    while (i < samples.len) : (i += 1) {
        if (samples[i - 1] < 0 and samples[i] >= 0) {
            if (first < 0) first = @intCast(i);
            last = @intCast(i);
            count += 1;
        }
    }
    if (count < 3) fail("too few zero-crossings ({d}) to measure pitch", .{count});
    return @as(f64, @floatFromInt(last - first)) / @as(f64, @floatFromInt(count - 1));
}

fn rms(samples: []const f32) f64 {
    var acc: f64 = 0;
    for (samples) |x| acc += @as(f64, x) * @as(f64, x);
    return @sqrt(acc / @as(f64, @floatFromInt(samples.len)));
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var args_it = try init.minimal.args.iterateAllocator(a);
    _ = args_it.next();
    const lib_path: []const u8 = args_it.next() orelse fail("usage: q64-clap-check <libq64clap.so> [q64.wasm]", .{});
    if (args_it.next()) |wasm| {
        // hand the plugin its wasm without relying on file placement
        const buf = try a.dupeZ(u8, wasm);
        _ = c_setenv("Q64_CLAP_WASM", buf.ptr, 1);
    }

    var lib = std.DynLib.open(lib_path) catch |e| fail("dlopen {s}: {s}", .{ lib_path, @errorName(e) });
    defer lib.close();
    const entry = lib.lookup(*const clap.PluginEntry, "clap_entry") orelse fail("no clap_entry symbol", .{});
    if (entry.clap_version.major != 1) fail("clap_version {d}", .{entry.clap_version.major});

    const lib_path_z = try a.dupeZ(u8, lib_path);
    if (!entry.init(lib_path_z.ptr)) fail("entry.init returned false (wasm not found or invalid?)", .{});
    std.debug.print("ok: entry.init (clap {d}.{d}.{d})\n", .{ entry.clap_version.major, entry.clap_version.minor, entry.clap_version.revision });

    const factory: *const clap.PluginFactory = @alignCast(@ptrCast(entry.get_factory("clap.plugin-factory") orelse fail("no plugin factory", .{})));
    if (factory.get_plugin_count(factory) != 1) fail("plugin count != 1", .{});
    const desc = factory.get_plugin_descriptor(factory, 0) orelse fail("no descriptor", .{});
    std.debug.print("ok: descriptor id=\"{s}\" name=\"{s}\"\n", .{ desc.id, desc.name });

    const plugin = factory.create_plugin(factory, &host, desc.id) orelse fail("create_plugin failed", .{});
    if (!plugin.init(plugin)) fail("plugin.init failed", .{});

    // extensions
    const params: *const clap.PluginParams = @alignCast(@ptrCast(plugin.get_extension(plugin, "clap.params") orelse fail("no clap.params", .{})));
    const aports: *const clap.PluginAudioPorts = @alignCast(@ptrCast(plugin.get_extension(plugin, "clap.audio-ports") orelse fail("no clap.audio-ports", .{})));
    const nports: *const clap.PluginNotePorts = @alignCast(@ptrCast(plugin.get_extension(plugin, "clap.note-ports") orelse fail("no clap.note-ports", .{})));
    if (aports.count(plugin, false) != 1 or aports.count(plugin, true) != 0) fail("audio port counts wrong", .{});
    var pinfo: clap.AudioPortInfo = undefined;
    if (!aports.get(plugin, 0, false, &pinfo)) fail("audio_ports.get failed", .{});
    if (pinfo.channel_count != 2) fail("channel_count {d}", .{pinfo.channel_count});
    if (nports.count(plugin, true) != 1) fail("note port count wrong", .{});
    std.debug.print("ok: ports — audio out \"{s}\" 2ch, 1 note in\n", .{std.mem.sliceTo(&pinfo.name, 0)});

    const n_params = params.count(plugin);
    if (n_params != 2) fail("param count {d}, expected 2", .{n_params});
    var par: clap.ParamInfo = undefined;
    if (!params.get_info(plugin, 0, &par)) fail("get_info(0) failed", .{});
    const cutoff_name = std.mem.sliceTo(&par.name, 0);
    if (!std.mem.eql(u8, cutoff_name, "Cutoff")) fail("param 0 name \"{s}\"", .{cutoff_name});
    if (par.min_value != 100 or par.max_value != 8000 or par.default_value != 1000) fail("cutoff range wrong", .{});
    if (par.flags & clap.param_is_automatable == 0) fail("cutoff not automatable", .{});
    std.debug.print("ok: guest params via native ext — [{s} {d}..{d} def {d}]\n", .{ cutoff_name, par.min_value, par.max_value, par.default_value });

    if (!plugin.activate(plugin, SR, 32, FRAMES)) fail("activate failed", .{});
    if (!plugin.start_processing(plugin)) fail("start_processing failed", .{});

    // ---- process plumbing ---------------------------------------------
    var ch0 = [_]f32{0} ** FRAMES;
    var ch1 = [_]f32{0} ** FRAMES;
    var chans = [_][*]f32{ &ch0, &ch1 };
    var out_buf = clap.AudioBuffer{
        .data32 = &chans,
        .data64 = null,
        .channel_count = 2,
        .latency = 0,
        .constant_mask = 0,
    };
    const in_events = clap.InputEvents{ .ctx = null, .size = evSize, .get = evGet };
    var process = clap.Process{
        .steady_time = 0,
        .frames_count = FRAMES,
        .transport = null,
        .audio_inputs = null,
        .audio_outputs = @ptrCast(&out_buf),
        .audio_inputs_count = 0,
        .audio_outputs_count = 1,
        .in_events = &in_events,
        .out_events = null,
    };

    const runBlocks = struct {
        fn f(al: std.mem.Allocator, p: *const clap.Plugin, proc: *clap.Process, buf: *[FRAMES]f32, buf1: *[FRAMES]f32, n: u32) []f32 {
            const out = al.alloc(f32, n * FRAMES) catch unreachable;
            var q: u32 = 0;
            while (q < n) : (q += 1) {
                if (p.process(p, proc) != clap.process_continue) fail("process returned error", .{});
                pending.clearRetainingCapacity();
                for (buf, buf1) |l, r| if (l != r) fail("channel 1 diverged from channel 0", .{});
                @memcpy(out[q * FRAMES ..][0..FRAMES], buf);
            }
            return out;
        }
    }.f;

    // Silent before the first note.
    const quiet = runBlocks(a, plugin, &process, &ch0, &ch1, 20);
    if (rms(quiet) > 1e-9) fail("not silent before the first note (rms {d})", .{rms(quiet)});
    std.debug.print("ok: silent before the first note\n", .{});

    // Note-on A4: measured 440 Hz.
    try pending.append(a, try noteEvent(a, clap.event_note_on, 69, 1.0, 0));
    _ = runBlocks(a, plugin, &process, &ch0, &ch1, 40);
    const a4 = runBlocks(a, plugin, &process, &ch0, &ch1, 40);
    const period = measurePeriod(a4);
    const want = SR / 440.0;
    if (@abs(period - want) > want * 0.1) fail("period {d:.1}, expected ~{d:.1} (440 Hz)", .{ period, want });
    std.debug.print("ok: note-on key 69 -> period {d:.1} samples (~{d:.1} Hz)\n", .{ period, SR / period });

    // Cutoff automation: readback through the native params ext.
    try pending.append(a, try paramEvent(a, 0, 5000.0));
    _ = runBlocks(a, plugin, &process, &ch0, &ch1, 2);
    var v: f64 = 0;
    if (!params.get_value(plugin, 0, &v)) fail("get_value failed", .{});
    if (v != 5000) fail("cutoff after event {d}, expected 5000", .{v});
    std.debug.print("ok: param event -> cutoff {d} by readback\n", .{v});

    // Note-off releases to silence.
    try pending.append(a, try noteEvent(a, clap.event_note_off, 69, 0.0, 0));
    _ = runBlocks(a, plugin, &process, &ch0, &ch1, 60);
    const tail = runBlocks(a, plugin, &process, &ch0, &ch1, 10);
    if (rms(tail) > 1e-3) fail("not silent after note-off (rms {d})", .{rms(tail)});
    std.debug.print("ok: note-off releases to silence\n", .{});

    // Sample-offset accuracy: time=64 note-on leaves [0,64) exactly zero.
    try pending.append(a, try noteEvent(a, clap.event_note_on, 69, 1.0, 64));
    const off_block = runBlocks(a, plugin, &process, &ch0, &ch1, 1);
    for (off_block[0..64], 0..) |x, i| if (x != 0) fail("sample {d} nonzero before the time=64 note-on", .{i});
    var after: f64 = 0;
    for (off_block[64..FRAMES]) |x| after += @abs(x);
    if (after == 0) fail("no audio after the time=64 note-on", .{});
    std.debug.print("ok: sample-offset accuracy — [0,64) exactly zero, [64,128) sounding\n", .{});

    plugin.stop_processing(plugin);
    plugin.deactivate(plugin);
    plugin.destroy(plugin);
    entry.deinit();
    std.debug.print("q64-clap-check: PASS — the q64 wasm runs as a native CLAP plugin\n", .{});
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const c_setenv = setenv;
