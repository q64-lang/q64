//! WCLAP wrap — `q64 emit … --wclap` (docs/audio-roadmap.md phase D).
//!
//! An isolated read-back post-pass (same shape as asyncify/optimize): the
//! emitted core module is read into Binaryen and a CLAP shim is
//! synthesized around it — the entry/factory/descriptor/plugin vtables in
//! linear memory, a growable exported funcref table carrying the shim
//! callbacks, `malloc`/`free`, the `clap.audio-ports` extension, and a
//! process trampoline. The result is a single wasm module a WCLAP host
//! loads directly: it reads the `clap_entry` global, walks the structs,
//! and calls the callbacks through `__indirect_function_table`.
//!
//! v0 plugin convention — the wrapped module must export:
//!   alloc_f32(n: i64) -> i64                  // a state buffer, by v.head
//!   process(st, io, n: i64, inc, b0, b1, b2, a1, a2, drive) -> i64
//! (the `examples/audio-worklet` surface). The shim allocates the state
//! vec at plugin.init, and at process() builds a vec *header* over the
//! host's channel-0 buffer so the q64 code writes the host memory
//! directly — zero copy, the `v.head` re-entry model. Channel 1 is a
//! memcpy of channel 0 (mono voice, stereo out). Parameters are fixed in
//! v0 (`clap.params` is the next slice); the sample rate arrives from
//! `activate` and drives the oscillator increment.
//!
//! Layout: shim structs + strings live in a scratch block at SCRATCH
//! (896 KiB — between the scope arena, which grows up from the static
//! data, and the vec heap at 1 MiB; a v0 module whose arena reaches
//! 896 KiB is far outside this wrapper's use). They are *written by the
//! module's start function* (chained before any existing start) rather
//! than a data segment, so the original memory layout is untouched;
//! `clap_entry` itself is an immutable i32 global holding SCRATCH.
//! Host-side `malloc` bumps a private pointer at 3 MiB — disjoint from
//! the guest vec heap (1 MiB, growing up), inside the module's fixed
//! 4 MiB memory. wasm32 only — WCLAP hosts are browser hosts.

const std = @import("std");

const c = @cImport({
    @cInclude("binaryen-c.h");
});

pub const Error = error{
    ModuleInvalid,
    SerializeEmpty,
    Wasm64Unsupported,
    /// The wrapped module doesn't export the v0 plugin convention
    /// (`alloc_f32` + `process`).
    MissingExport,
    OutOfMemory,
};

pub const Meta = struct {
    id: []const u8 = "dev.q64.voice",
    name: []const u8 = "q64 Voice",
    vendor: []const u8 = "q64",
    version: []const u8 = "0.1.0",
};

// ---- scratch layout (all offsets from SCRATCH) ------------------------

const SCRATCH: u32 = 0xE0000;
/// Host-side malloc region: disjoint from the guest vec heap (1 MiB+).
const HOST_HEAP: u32 = 0x300000;

const ENTRY: u32 = 0; // clap_plugin_entry: version(12) + 3 fn ptrs = 24
const FACTORY: u32 = 24; // clap_plugin_factory: 3 fn ptrs = 12
const DESC: u32 = 40; // clap_plugin_descriptor: version(12) + 9 ptrs = 48
const PLUGIN: u32 = 96; // clap_plugin: desc + data + 10 fn ptrs = 48
const AUDIO_PORTS: u32 = 144; // clap_plugin_audio_ports: 2 fn ptrs = 8
const FEATURES: u32 = 160; // const char*[3]: two features + null
const IO_HDR: u32 = 176; // scratch Vec<f32> header {data, len, cap}
const STRINGS: u32 = 200;

// ---- table indices (order of `shim_funcs` below) ----------------------
// Base 1: a host that null-checks a CLAP fn pointer must not see index 0.

const TBL_BASE = 1;
const IDX_ENTRY_INIT = TBL_BASE + 0;
const IDX_ENTRY_DEINIT = TBL_BASE + 1;
const IDX_GET_FACTORY = TBL_BASE + 2;
const IDX_COUNT = TBL_BASE + 3;
const IDX_GET_DESC = TBL_BASE + 4;
const IDX_CREATE = TBL_BASE + 5;
const IDX_P_INIT = TBL_BASE + 6;
const IDX_P_DESTROY = TBL_BASE + 7;
const IDX_P_ACTIVATE = TBL_BASE + 8;
const IDX_P_DEACTIVATE = TBL_BASE + 9;
const IDX_P_START = TBL_BASE + 10;
const IDX_P_STOP = TBL_BASE + 11;
const IDX_P_RESET = TBL_BASE + 12;
const IDX_P_PROCESS = TBL_BASE + 13;
const IDX_P_GET_EXT = TBL_BASE + 14;
const IDX_P_ON_MAIN = TBL_BASE + 15;
const IDX_PORTS_COUNT = TBL_BASE + 16;
const IDX_PORTS_GET = TBL_BASE + 17;
const N_SHIM_FUNCS = 18;

const shim_funcs = [N_SHIM_FUNCS][*:0]const u8{
    "__wclap_entry_init",   "__wclap_entry_deinit", "__wclap_get_factory",
    "__wclap_count",        "__wclap_get_desc",     "__wclap_create",
    "__wclap_p_init",       "__wclap_p_destroy",    "__wclap_p_activate",
    "__wclap_p_deactivate", "__wclap_p_start",      "__wclap_p_stop",
    "__wclap_p_reset",      "__wclap_p_process",    "__wclap_p_get_ext",
    "__wclap_p_on_main",    "__wclap_ports_count",  "__wclap_ports_get",
};

/// Builder context: the module, the couple of types every shim function
/// needs, and the resolved *internal* names of the guest exports (a
/// read-back binary may carry no name section, so `process` inside the
/// module can be named anything — the export table is the truth).
const B = struct {
    m: c.BinaryenModuleRef,
    i32t: c.BinaryenType,
    i64t: c.BinaryenType,
    f32t: c.BinaryenType,
    f64t: c.BinaryenType,
    none: c.BinaryenType,
    fn_alloc_f32: [*c]const u8,
    fn_process: [*c]const u8,

    fn ci32(self: B, v: i64) c.BinaryenExpressionRef {
        return c.BinaryenConst(self.m, c.BinaryenLiteralInt32(@intCast(v)));
    }
    fn addr(self: B, off: u32) c.BinaryenExpressionRef {
        return self.ci32(@as(i64, SCRATCH) + off);
    }
    fn get(self: B, idx: u32, t: c.BinaryenType) c.BinaryenExpressionRef {
        return c.BinaryenLocalGet(self.m, idx, t);
    }
    fn load32(self: B, off: u32, ptr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return c.BinaryenLoad(self.m, 4, false, off, 0, self.i32t, ptr, null);
    }
    fn store32(self: B, off: u32, ptr: c.BinaryenExpressionRef, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return c.BinaryenStore(self.m, 4, off, 0, ptr, v, self.i32t, null);
    }
};

/// Resolve an export's internal function name; null if not exported.
fn exportedFn(m: c.BinaryenModuleRef, name: [*:0]const u8) ?[*c]const u8 {
    const ex = c.BinaryenGetExport(m, name);
    if (ex == null) return null;
    if (c.BinaryenExportGetKind(ex) != c.BinaryenExternalFunction()) return null;
    return c.BinaryenExportGetValue(ex);
}

/// Read `wasm` back, weave in the CLAP shim, re-serialize. Caller owns
/// the returned bytes.
pub fn wclapWrap(allocator: std.mem.Allocator, wasm: []const u8, wasm64: bool, meta: Meta) Error![]u8 {
    if (wasm64) return Error.Wasm64Unsupported;

    const features = c.BinaryenFeatureMultivalue() | c.BinaryenFeatureBulkMemory() |
        c.BinaryenFeatureBulkMemoryOpt() | c.BinaryenFeatureMutableGlobals() |
        c.BinaryenFeatureNontrappingFPToInt() | c.BinaryenFeatureSIMD128() |
        c.BinaryenFeatureRelaxedSIMD() | c.BinaryenFeatureReferenceTypes();

    const buf = try allocator.dupe(u8, wasm);
    defer allocator.free(buf);
    const m = c.BinaryenModuleReadWithFeatures(buf.ptr, buf.len, features) orelse return Error.ModuleInvalid;
    defer c.BinaryenModuleDispose(m);
    c.BinaryenModuleSetFeatures(m, features);

    const b = B{
        .m = m,
        .i32t = c.BinaryenTypeInt32(),
        .i64t = c.BinaryenTypeInt64(),
        .f32t = c.BinaryenTypeFloat32(),
        .f64t = c.BinaryenTypeFloat64(),
        .none = c.BinaryenTypeNone(),
        .fn_alloc_f32 = exportedFn(m, "alloc_f32") orelse return Error.MissingExport,
        .fn_process = exportedFn(m, "process") orelse return Error.MissingExport,
    };

    // ---- globals ------------------------------------------------------
    // clap_entry: the address of the entry struct — what the host reads.
    _ = c.BinaryenAddGlobal(m, "clap_entry", b.i32t, false, b.addr(ENTRY));
    _ = c.BinaryenAddGlobalExport(m, "clap_entry", "clap_entry");
    // The plugin's state-vec header address (set at plugin.init), the
    // activated sample rate, and the host-side malloc bump pointer.
    _ = c.BinaryenAddGlobal(m, "__wclap_st", b.i32t, true, b.ci32(0));
    _ = c.BinaryenAddGlobal(m, "__wclap_sr", b.f64t, true, c.BinaryenConst(m, c.BinaryenLiteralFloat64(48000.0)));
    _ = c.BinaryenAddGlobal(m, "__wclap_hp", b.i32t, true, b.ci32(HOST_HEAP));

    // ---- malloc / free ------------------------------------------------
    // The host allocates id strings, event lists, and the clap_process
    // block inside plugin memory at setup time. Bump the private host
    // heap (16-byte aligned); free is a no-op — setup-time only, never
    // on the audio path.
    addMalloc(b);

    // ---- the shim functions ------------------------------------------
    var strings = StringTable{};
    defer strings.bytes.deinit(allocator);
    const str_id = try strings.intern(allocator, meta.id);
    const str_name = try strings.intern(allocator, meta.name);
    const str_vendor = try strings.intern(allocator, meta.vendor);
    const str_version = try strings.intern(allocator, meta.version);
    const str_empty = try strings.intern(allocator, "");
    const str_instrument = try strings.intern(allocator, "instrument");
    const str_synth = try strings.intern(allocator, "synthesizer");
    const str_factory_id = try strings.intern(allocator, "clap.plugin-factory");
    const str_ports_id = try strings.intern(allocator, "clap.audio-ports");
    const str_stereo = try strings.intern(allocator, "stereo");

    addStreq(b);
    addEntryFns(b, str_factory_id);
    addFactoryFns(b);
    addPluginFns(b, str_ports_id);
    addPortsFns(b, str_stereo);

    // ---- the data-init function --------------------------------------
    // Writes every struct field and string into the scratch block; chained
    // in front of any existing start.
    try addDataInit(allocator, b, &strings, .{
        .id = str_id,
        .name = str_name,
        .vendor = str_vendor,
        .version = str_version,
        .empty = str_empty,
        .instrument = str_instrument,
        .synth = str_synth,
    });

    // ---- the table ----------------------------------------------------
    // Growable (generous max): WCLAP hosts grow the plugin's table to
    // install their own callback trampolines — a capped table fails at
    // load with `WebAssembly.Table.grow()`. Slot 0 stays empty (null).
    _ = c.BinaryenAddTable(m, "__indirect_function_table", TBL_BASE + N_SHIM_FUNCS, 1024, c.BinaryenTypeFuncref(), null);
    var fnames: [N_SHIM_FUNCS][*c]const u8 = undefined;
    for (shim_funcs, 0..) |nm, i| fnames[i] = nm;
    _ = c.BinaryenAddActiveElementSegment(m, "__indirect_function_table", "__wclap_elems", @ptrCast(&fnames), N_SHIM_FUNCS, b.ci32(TBL_BASE));
    _ = c.BinaryenAddTableExport(m, "__indirect_function_table", "__indirect_function_table");

    if (!c.BinaryenModuleValidate(m)) return Error.ModuleInvalid;
    const result = c.BinaryenModuleAllocateAndWrite(m, null);
    defer if (result.binary) |p| std.c.free(p);
    const ptr = result.binary orelse return Error.SerializeEmpty;
    if (result.binaryBytes == 0) return Error.SerializeEmpty;
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, @as([*]const u8, @ptrCast(ptr))[0..result.binaryBytes]);
    return out;
}

// ---- string interning into the scratch block --------------------------

const StringTable = struct {
    next: u32 = STRINGS,
    bytes: std.ArrayListUnmanaged(u8) = .empty, // flat, NUL-separated

    /// Reserve `s` (+ NUL) in the scratch block; returns its absolute address.
    fn intern(self: *StringTable, allocator: std.mem.Allocator, s: []const u8) Error!u32 {
        const at = SCRATCH + self.next;
        try self.bytes.appendSlice(allocator, s);
        try self.bytes.append(allocator, 0);
        self.next += @intCast(s.len + 1);
        return at;
    }
};

// ---- shim pieces -------------------------------------------------------

fn addMalloc(b: B) void {
    const m = b.m;
    // aligned = (hp + 15) & ~15; hp = aligned + size; return aligned
    const aligned = c.BinaryenBinary(m, c.BinaryenAndInt32(), c.BinaryenBinary(m, c.BinaryenAddInt32(), c.BinaryenGlobalGet(m, "__wclap_hp", b.i32t), b.ci32(15)), b.ci32(-16));
    var body = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(m, 1, aligned),
        c.BinaryenGlobalSet(m, "__wclap_hp", c.BinaryenBinary(m, c.BinaryenAddInt32(), b.get(1, b.i32t), b.get(0, b.i32t))),
        b.get(1, b.i32t),
    };
    var vt = [_]c.BinaryenType{b.i32t};
    _ = c.BinaryenAddFunction(m, "__wclap_malloc", b.i32t, b.i32t, @ptrCast(&vt), vt.len, c.BinaryenBlock(m, null, @ptrCast(&body), body.len, b.i32t));
    _ = c.BinaryenAddFunctionExport(m, "__wclap_malloc", "malloc");
    _ = c.BinaryenAddFunction(m, "__wclap_free", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    _ = c.BinaryenAddFunctionExport(m, "__wclap_free", "free");
}

/// `__wclap_streq(a, b) -> i32` — NUL-terminated byte equality.
fn addStreq(b: B) void {
    const m = b.m;
    const cha = c.BinaryenLoad(m, 1, false, 0, 0, b.i32t, b.get(0, b.i32t), null);
    const chb = c.BinaryenLoad(m, 1, false, 0, 0, b.i32t, b.get(1, b.i32t), null);
    var loop_body = [_]c.BinaryenExpressionRef{
        // if (*a != *b) return 0
        c.BinaryenIf(m, c.BinaryenBinary(m, c.BinaryenNeInt32(), cha, chb), c.BinaryenReturn(m, b.ci32(0)), null),
        // if (*a == 0) return 1
        c.BinaryenIf(m, c.BinaryenUnary(m, c.BinaryenEqZInt32(), c.BinaryenLoad(m, 1, false, 0, 0, b.i32t, b.get(0, b.i32t), null)), c.BinaryenReturn(m, b.ci32(1)), null),
        c.BinaryenLocalSet(m, 0, c.BinaryenBinary(m, c.BinaryenAddInt32(), b.get(0, b.i32t), b.ci32(1))),
        c.BinaryenLocalSet(m, 1, c.BinaryenBinary(m, c.BinaryenAddInt32(), b.get(1, b.i32t), b.ci32(1))),
        c.BinaryenBreak(m, "cmp", null, null),
    };
    const loop = c.BinaryenLoop(m, "cmp", c.BinaryenBlock(m, null, @ptrCast(&loop_body), loop_body.len, b.none));
    var body = [_]c.BinaryenExpressionRef{ loop, c.BinaryenUnreachable(m) };
    var params = [_]c.BinaryenType{ b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_streq", c.BinaryenTypeCreate(&params, params.len), b.i32t, null, 0, c.BinaryenBlock(m, null, @ptrCast(&body), body.len, b.i32t));
}

fn addEntryFns(b: B, factory_id: u32) void {
    const m = b.m;
    // entry.init(plugin_path*) -> bool
    _ = c.BinaryenAddFunction(m, "__wclap_entry_init", b.i32t, b.i32t, null, 0, b.ci32(1));
    _ = c.BinaryenAddFunction(m, "__wclap_entry_deinit", b.none, b.none, null, 0, c.BinaryenNop(m));
    // entry.get_factory(id*) -> factory* | 0
    var args = [_]c.BinaryenExpressionRef{ b.get(0, b.i32t), b.ci32(factory_id) };
    const is_factory = c.BinaryenCall(m, "__wclap_streq", @ptrCast(&args), args.len, b.i32t);
    _ = c.BinaryenAddFunction(m, "__wclap_get_factory", b.i32t, b.i32t, null, 0, c.BinaryenSelect(m, is_factory, b.addr(FACTORY), b.ci32(0)));
}

fn addFactoryFns(b: B) void {
    const m = b.m;
    // factory.get_plugin_count(factory*) -> 1
    _ = c.BinaryenAddFunction(m, "__wclap_count", b.i32t, b.i32t, null, 0, b.ci32(1));
    // factory.get_plugin_descriptor(factory*, index) -> desc* | 0
    var p2 = [_]c.BinaryenType{ b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_get_desc", c.BinaryenTypeCreate(&p2, p2.len), b.i32t, null, 0, c.BinaryenSelect(m, c.BinaryenUnary(m, c.BinaryenEqZInt32(), b.get(1, b.i32t)), b.addr(DESC), b.ci32(0)));
    // factory.create_plugin(factory*, host*, id*) -> plugin*  (v0: the one
    // plugin, unconditionally — the host looked the id up in our descriptor).
    var p3 = [_]c.BinaryenType{ b.i32t, b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_create", c.BinaryenTypeCreate(&p3, p3.len), b.i32t, null, 0, b.addr(PLUGIN));
}

fn addPluginFns(b: B, ports_id: u32) void {
    const m = b.m;
    // plugin.init(plugin*) -> bool: allocate the 16-slot state vec through
    // the guest's own export and remember its header address.
    var ainit = [_]c.BinaryenExpressionRef{c.BinaryenConst(m, c.BinaryenLiteralInt64(16))};
    var init_body = [_]c.BinaryenExpressionRef{
        c.BinaryenGlobalSet(m, "__wclap_st", c.BinaryenUnary(m, c.BinaryenWrapInt64(), c.BinaryenCall(m, b.fn_alloc_f32, @ptrCast(&ainit), ainit.len, b.i64t))),
        b.ci32(1),
    };
    _ = c.BinaryenAddFunction(m, "__wclap_p_init", b.i32t, b.i32t, null, 0, c.BinaryenBlock(m, null, @ptrCast(&init_body), init_body.len, b.i32t));
    _ = c.BinaryenAddFunction(m, "__wclap_p_destroy", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    // plugin.activate(plugin*, sample_rate f64, min u32, max u32) -> bool
    var pact = [_]c.BinaryenType{ b.i32t, b.f64t, b.i32t, b.i32t };
    var act_body = [_]c.BinaryenExpressionRef{
        c.BinaryenGlobalSet(m, "__wclap_sr", b.get(1, b.f64t)),
        b.ci32(1),
    };
    _ = c.BinaryenAddFunction(m, "__wclap_p_activate", c.BinaryenTypeCreate(&pact, pact.len), b.i32t, null, 0, c.BinaryenBlock(m, null, @ptrCast(&act_body), act_body.len, b.i32t));
    _ = c.BinaryenAddFunction(m, "__wclap_p_deactivate", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    _ = c.BinaryenAddFunction(m, "__wclap_p_start", b.i32t, b.i32t, null, 0, b.ci32(1));
    _ = c.BinaryenAddFunction(m, "__wclap_p_stop", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    _ = c.BinaryenAddFunction(m, "__wclap_p_reset", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    _ = c.BinaryenAddFunction(m, "__wclap_p_on_main", b.i32t, b.none, null, 0, c.BinaryenNop(m));
    // plugin.get_extension(plugin*, id*) -> ext* | 0
    var p2 = [_]c.BinaryenType{ b.i32t, b.i32t };
    var eargs = [_]c.BinaryenExpressionRef{ b.get(1, b.i32t), b.ci32(ports_id) };
    const is_ports = c.BinaryenCall(m, "__wclap_streq", @ptrCast(&eargs), eargs.len, b.i32t);
    _ = c.BinaryenAddFunction(m, "__wclap_p_get_ext", c.BinaryenTypeCreate(&p2, p2.len), b.i32t, null, 0, c.BinaryenSelect(m, is_ports, b.addr(AUDIO_PORTS), b.ci32(0)));

    addProcess(b);
}

/// plugin.process(plugin*, clap_process*) -> clap_process_status.
/// clap_process (wasm32): steady_time i64 @0, frames u32 @8, transport @12,
/// audio_inputs @16, audio_outputs @20, in_count @24, out_count @28,
/// in_events @32, out_events @36. clap_audio_buffer: data32 @0, data64 @4,
/// channel_count @8, latency @12, constant_mask u64 @16.
fn addProcess(b: B) void {
    const m = b.m;
    const P = 1; // param 1: clap_process*
    // locals: 2=frames(i32) 3=outs(buffer*) 4=data32 5=ch0
    const FRAMES = 2;
    // inc = f32(220 / sr) — the fixed 110 Hz voice until clap.params
    // (the saw increment convention is 2*f/sr).
    const inc = c.BinaryenUnary(m, c.BinaryenDemoteFloat64(), c.BinaryenBinary(m, c.BinaryenDivFloat64(), c.BinaryenConst(m, c.BinaryenLiteralFloat64(220.0)), c.BinaryenGlobalGet(m, "__wclap_sr", b.f64t)));
    const cf = struct {
        fn k(bb: B, v: f64) c.BinaryenExpressionRef {
            return c.BinaryenConst(bb.m, c.BinaryenLiteralFloat32(@floatCast(v)));
        }
    }.k;
    // 1 kHz Butterworth low-pass @48k — fixed voice tone until clap.params.
    var pargs = [_]c.BinaryenExpressionRef{
        c.BinaryenGlobalGet(m, "__wclap_st", b.i32t),
        b.addr(IO_HDR),
        c.BinaryenUnary(m, c.BinaryenExtendUInt32(), b.get(FRAMES, b.i32t)),
        inc,
        cf(b, 0.000944692), cf(b, 0.001889384), cf(b, 0.000944692),
        cf(b, -1.911196288), cf(b, 0.914975055),
        cf(b, 1.8),
    };
    var body = [_]c.BinaryenExpressionRef{
        // frames = proc.frames_count
        c.BinaryenLocalSet(m, FRAMES, b.load32(8, b.get(P, b.i32t))),
        // if (out_count == 0) return CONTINUE (nothing to fill)
        c.BinaryenIf(m, c.BinaryenUnary(m, c.BinaryenEqZInt32(), b.load32(28, b.get(P, b.i32t))), c.BinaryenReturn(m, b.ci32(1)), null),
        // outs = proc.audio_outputs; data32 = outs[0].data32; ch0 = data32[0]
        c.BinaryenLocalSet(m, 3, b.load32(20, b.get(P, b.i32t))),
        c.BinaryenLocalSet(m, 4, b.load32(0, b.get(3, b.i32t))),
        c.BinaryenLocalSet(m, 5, b.load32(0, b.get(4, b.i32t))),
        // io header over the host's ch0 buffer: {data, len, cap}
        b.store32(0, b.addr(IO_HDR), b.get(5, b.i32t)),
        b.store32(4, b.addr(IO_HDR), b.get(FRAMES, b.i32t)),
        b.store32(8, b.addr(IO_HDR), b.get(FRAMES, b.i32t)),
        // the q64 voice renders straight into host memory
        c.BinaryenDrop(m, c.BinaryenCall(m, b.fn_process, @ptrCast(&pargs), pargs.len, b.i64t)),
        // stereo: ch1 = ch0 when a second channel exists
        c.BinaryenIf(
            m,
            c.BinaryenBinary(m, c.BinaryenGtUInt32(), b.load32(8, b.get(3, b.i32t)), b.ci32(1)),
            c.BinaryenMemoryCopy(m, b.load32(4, b.get(4, b.i32t)), b.get(5, b.i32t), c.BinaryenBinary(m, c.BinaryenShlInt32(), b.get(FRAMES, b.i32t), b.ci32(2)), null, null),
            null,
        ),
        b.ci32(1), // CLAP_PROCESS_CONTINUE
    };
    var params = [_]c.BinaryenType{ b.i32t, b.i32t };
    var vt = [_]c.BinaryenType{ b.i32t, b.i32t, b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_p_process", c.BinaryenTypeCreate(&params, params.len), b.i32t, @ptrCast(&vt), vt.len, c.BinaryenBlock(m, null, @ptrCast(&body), body.len, b.i32t));
}

fn addPortsFns(b: B, stereo: u32) void {
    const m = b.m;
    // audio_ports.count(plugin*, is_input) -> u32: one output port, no inputs.
    var p2 = [_]c.BinaryenType{ b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_ports_count", c.BinaryenTypeCreate(&p2, p2.len), b.i32t, null, 0, c.BinaryenSelect(m, b.get(1, b.i32t), b.ci32(0), b.ci32(1)));
    // audio_ports.get(plugin*, index, is_input, info*) -> bool.
    // clap_audio_port_info: id @0, name[256] @4, flags @260,
    // channel_count @264, port_type* @268, in_place_pair @272 (276 bytes).
    const info = 3; // param
    var body = [_]c.BinaryenExpressionRef{
        // only (index 0, output)
        c.BinaryenIf(m, c.BinaryenBinary(m, c.BinaryenOrInt32(), b.get(1, b.i32t), b.get(2, b.i32t)), c.BinaryenReturn(m, b.ci32(0)), null),
        b.store32(0, b.get(info, b.i32t), b.ci32(0)), // id
        // name = "out\0"
        c.BinaryenStore(m, 1, 4, 0, b.get(info, b.i32t), b.ci32('o'), b.i32t, null),
        c.BinaryenStore(m, 1, 5, 0, b.get(info, b.i32t), b.ci32('u'), b.i32t, null),
        c.BinaryenStore(m, 1, 6, 0, b.get(info, b.i32t), b.ci32('t'), b.i32t, null),
        c.BinaryenStore(m, 1, 7, 0, b.get(info, b.i32t), b.ci32(0), b.i32t, null),
        b.store32(260, b.get(info, b.i32t), b.ci32(1)), // CLAP_AUDIO_PORT_IS_MAIN
        b.store32(264, b.get(info, b.i32t), b.ci32(2)), // stereo
        b.store32(268, b.get(info, b.i32t), b.ci32(stereo)),
        b.store32(272, b.get(info, b.i32t), b.ci32(-1)), // CLAP_INVALID_ID
        b.ci32(1),
    };
    var p4 = [_]c.BinaryenType{ b.i32t, b.i32t, b.i32t, b.i32t };
    _ = c.BinaryenAddFunction(m, "__wclap_ports_get", c.BinaryenTypeCreate(&p4, p4.len), b.i32t, null, 0, c.BinaryenBlock(m, null, @ptrCast(&body), body.len, b.i32t));
}

const DescStrings = struct {
    id: u32,
    name: u32,
    vendor: u32,
    version: u32,
    empty: u32,
    instrument: u32,
    synth: u32,
};

/// The start-chained data-init: writes the structs and every interned
/// string into the scratch block.
fn addDataInit(allocator: std.mem.Allocator, b: B, strings: *StringTable, ds: DescStrings) Error!void {
    const m = b.m;
    var stmts: std.ArrayListUnmanaged(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);

    const w = struct {
        fn f(bb: B, off: u32, v: i64) c.BinaryenExpressionRef {
            return bb.store32(0, bb.ci32(@as(i64, SCRATCH) + off), bb.ci32(v));
        }
    }.f;

    // entry: clap_version {1, 2, 2} + init/deinit/get_factory table indices
    try stmts.appendSlice(allocator, &.{
        w(b, ENTRY + 0, 1),               w(b, ENTRY + 4, 2),                 w(b, ENTRY + 8, 2),
        w(b, ENTRY + 12, IDX_ENTRY_INIT), w(b, ENTRY + 16, IDX_ENTRY_DEINIT), w(b, ENTRY + 20, IDX_GET_FACTORY),
        // factory
        w(b, FACTORY + 0, IDX_COUNT),     w(b, FACTORY + 4, IDX_GET_DESC),    w(b, FACTORY + 8, IDX_CREATE),
        // descriptor
        w(b, DESC + 0, 1),                w(b, DESC + 4, 2),                  w(b, DESC + 8, 2),
        w(b, DESC + 12, ds.id),           w(b, DESC + 16, ds.name),
        w(b, DESC + 20, ds.vendor),       w(b, DESC + 24, ds.empty), // url
        w(b, DESC + 28, ds.empty),        w(b, DESC + 32, ds.empty), // manual, support
        w(b, DESC + 36, ds.version),      w(b, DESC + 40, ds.empty), // description
        w(b, DESC + 44, SCRATCH + FEATURES),
        // plugin
        w(b, PLUGIN + 0, SCRATCH + DESC), w(b, PLUGIN + 4, 0),
        w(b, PLUGIN + 8, IDX_P_INIT),     w(b, PLUGIN + 12, IDX_P_DESTROY),
        w(b, PLUGIN + 16, IDX_P_ACTIVATE), w(b, PLUGIN + 20, IDX_P_DEACTIVATE),
        w(b, PLUGIN + 24, IDX_P_START),   w(b, PLUGIN + 28, IDX_P_STOP),
        w(b, PLUGIN + 32, IDX_P_RESET),   w(b, PLUGIN + 36, IDX_P_PROCESS),
        w(b, PLUGIN + 40, IDX_P_GET_EXT), w(b, PLUGIN + 44, IDX_P_ON_MAIN),
        // audio-ports extension
        w(b, AUDIO_PORTS + 0, IDX_PORTS_COUNT), w(b, AUDIO_PORTS + 4, IDX_PORTS_GET),
        // features: ["instrument", "synthesizer", NULL]
        w(b, FEATURES + 0, ds.instrument), w(b, FEATURES + 4, ds.synth), w(b, FEATURES + 8, 0),
    });

    // The interned strings, byte by byte.
    for (strings.bytes.items, 0..) |byte, i| {
        try stmts.append(allocator, c.BinaryenStore(m, 1, @intCast(i), 0, b.ci32(@as(i64, SCRATCH) + STRINGS), b.ci32(byte), b.i32t, null));
    }

    // Chain any existing start after the writes.
    const old_start = c.BinaryenGetStart(m);
    if (old_start != null) {
        try stmts.append(allocator, c.BinaryenCall(m, c.BinaryenFunctionGetName(old_start), null, 0, b.none));
    }

    _ = c.BinaryenAddFunction(m, "__wclap_data_init", b.none, b.none, null, 0, c.BinaryenBlock(m, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), b.none));
    c.BinaryenSetStart(m, c.BinaryenGetFunction(m, "__wclap_data_init"));
}
