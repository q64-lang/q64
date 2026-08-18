//! Native CLAP ABI (the C structs from free-audio/clap, hand-declared
//! as Zig extern structs for the host's native pointer width). Only the
//! surface the q64 plugin shim uses: entry / factory / descriptor /
//! plugin / process / events / params / audio-ports / note-ports.
//!
//! Layouts follow clap-1.2 headers; extern struct gives C alignment, so
//! the f64 fields in the event payloads land on the same padded offsets
//! as in C.

pub const Version = extern struct {
    major: u32,
    minor: u32,
    revision: u32,
};

pub const version_1_2_2 = Version{ .major = 1, .minor = 2, .revision = 2 };

pub const PluginDescriptor = extern struct {
    clap_version: Version,
    id: [*:0]const u8,
    name: [*:0]const u8,
    vendor: [*:0]const u8,
    url: [*:0]const u8,
    manual_url: [*:0]const u8,
    support_url: [*:0]const u8,
    version: [*:0]const u8,
    description: [*:0]const u8,
    features: [*:null]const ?[*:0]const u8,
};

pub const process_error: i32 = 0;
pub const process_continue: i32 = 1;

pub const AudioBuffer = extern struct {
    data32: ?[*][*]f32,
    data64: ?[*][*]f64,
    channel_count: u32,
    latency: u32,
    constant_mask: u64,
};

pub const EventHeader = extern struct {
    size: u32,
    time: u32,
    space_id: u16,
    type: u16,
    flags: u32,
};

pub const core_event_space: u16 = 0;
pub const event_note_on: u16 = 0;
pub const event_note_off: u16 = 1;
pub const event_note_choke: u16 = 2;
pub const event_param_value: u16 = 5;
pub const event_midi: u16 = 10;

pub const EventNote = extern struct {
    header: EventHeader,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    velocity: f64,
};

pub const EventParamValue = extern struct {
    header: EventHeader,
    param_id: u32,
    cookie: ?*anyopaque,
    note_id: i32,
    port_index: i16,
    channel: i16,
    key: i16,
    value: f64,
};

pub const EventMidi = extern struct {
    header: EventHeader,
    port_index: u16,
    data: [3]u8,
};

pub const InputEvents = extern struct {
    ctx: ?*anyopaque,
    size: *const fn (list: *const InputEvents) callconv(.c) u32,
    get: *const fn (list: *const InputEvents, index: u32) callconv(.c) ?*const EventHeader,
};

pub const OutputEvents = extern struct {
    ctx: ?*anyopaque,
    try_push: *const fn (list: *const OutputEvents, event: *const EventHeader) callconv(.c) bool,
};

pub const Process = extern struct {
    steady_time: i64,
    frames_count: u32,
    transport: ?*const anyopaque,
    audio_inputs: ?[*]const AudioBuffer,
    audio_outputs: ?[*]AudioBuffer,
    audio_inputs_count: u32,
    audio_outputs_count: u32,
    in_events: ?*const InputEvents,
    out_events: ?*const OutputEvents,
};

pub const Plugin = extern struct {
    desc: *const PluginDescriptor,
    plugin_data: ?*anyopaque,
    init: *const fn (plugin: *const Plugin) callconv(.c) bool,
    destroy: *const fn (plugin: *const Plugin) callconv(.c) void,
    activate: *const fn (plugin: *const Plugin, sample_rate: f64, min_frames: u32, max_frames: u32) callconv(.c) bool,
    deactivate: *const fn (plugin: *const Plugin) callconv(.c) void,
    start_processing: *const fn (plugin: *const Plugin) callconv(.c) bool,
    stop_processing: *const fn (plugin: *const Plugin) callconv(.c) void,
    reset: *const fn (plugin: *const Plugin) callconv(.c) void,
    process: *const fn (plugin: *const Plugin, process: *const Process) callconv(.c) i32,
    get_extension: *const fn (plugin: *const Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque,
    on_main_thread: *const fn (plugin: *const Plugin) callconv(.c) void,
};

pub const Host = extern struct {
    clap_version: Version,
    host_data: ?*anyopaque,
    name: [*:0]const u8,
    vendor: [*:0]const u8,
    url: [*:0]const u8,
    version: [*:0]const u8,
    get_extension: *const fn (host: *const Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque,
    request_restart: *const fn (host: *const Host) callconv(.c) void,
    request_process: *const fn (host: *const Host) callconv(.c) void,
    request_callback: *const fn (host: *const Host) callconv(.c) void,
};

pub const PluginFactory = extern struct {
    get_plugin_count: *const fn (factory: *const PluginFactory) callconv(.c) u32,
    get_plugin_descriptor: *const fn (factory: *const PluginFactory, index: u32) callconv(.c) ?*const PluginDescriptor,
    create_plugin: *const fn (factory: *const PluginFactory, host: *const Host, plugin_id: [*:0]const u8) callconv(.c) ?*const Plugin,
};

pub const PluginEntry = extern struct {
    clap_version: Version,
    init: *const fn (plugin_path: [*:0]const u8) callconv(.c) bool,
    deinit: *const fn () callconv(.c) void,
    get_factory: *const fn (factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque,
};

// ---- clap.params ------------------------------------------------------

pub const param_is_automatable: u32 = 1 << 5;

pub const ParamInfo = extern struct {
    id: u32,
    flags: u32,
    cookie: ?*anyopaque,
    name: [256]u8,
    module: [1024]u8,
    min_value: f64,
    max_value: f64,
    default_value: f64,
};

pub const PluginParams = extern struct {
    count: *const fn (plugin: *const Plugin) callconv(.c) u32,
    get_info: *const fn (plugin: *const Plugin, index: u32, info: *ParamInfo) callconv(.c) bool,
    get_value: *const fn (plugin: *const Plugin, id: u32, out: *f64) callconv(.c) bool,
    value_to_text: *const fn (plugin: *const Plugin, id: u32, value: f64, out: [*]u8, cap: u32) callconv(.c) bool,
    text_to_value: *const fn (plugin: *const Plugin, text: [*:0]const u8, out: *f64) callconv(.c) bool,
    flush: *const fn (plugin: *const Plugin, in: ?*const InputEvents, out: ?*const OutputEvents) callconv(.c) void,
};

// ---- clap.audio-ports -------------------------------------------------

pub const audio_port_is_main: u32 = 1 << 0;

pub const AudioPortInfo = extern struct {
    id: u32,
    name: [256]u8,
    flags: u32,
    channel_count: u32,
    port_type: ?[*:0]const u8,
    in_place_pair: u32,
};

pub const PluginAudioPorts = extern struct {
    count: *const fn (plugin: *const Plugin, is_input: bool) callconv(.c) u32,
    get: *const fn (plugin: *const Plugin, index: u32, is_input: bool, info: *AudioPortInfo) callconv(.c) bool,
};

// ---- clap.note-ports --------------------------------------------------

pub const note_dialect_clap: u32 = 1 << 0;
pub const note_dialect_midi: u32 = 1 << 1;

pub const NotePortInfo = extern struct {
    id: u32,
    supported_dialects: u32,
    preferred_dialect: u32,
    name: [256]u8,
};

pub const PluginNotePorts = extern struct {
    count: *const fn (plugin: *const Plugin, is_input: bool) callconv(.c) u32,
    get: *const fn (plugin: *const Plugin, index: u32, is_input: bool, info: *NotePortInfo) callconv(.c) bool,
};
