// QView Stage-1 retained mutation protocol — the frozen contract.
// Mirrors spec/qview-protocol.md. These enums are APPEND-ONLY and shared by
// every producer (the q64 compiler, agents) and the host. A widget adds a KIND
// tag here and a draw entry in widgets.js; it never edits the op set.
//
// PROTOCOL_VERSION bumps minor on append, major on any meaning/encoding change.
export const PROTOCOL_VERSION = '1.11';

// Node kinds (spec §"Node kinds").
export const KIND = {
  box: 0, row: 1, column: 2, stack: 3, label: 4, image: 5, button: 6,
  checkbox: 7, switch: 8, radio: 9, slider: 10, progress: 11, dropdown: 12,
  divider: 13,   // thin separator line (hairline rule)
  group: 14,     // titled container: a panel + heading that holds sub-widgets
  meter: 15,     // level/VU meter (mono or stereo) — value=level, used for peak meters
  knob: 16,      // rotary control (pan, volume) — value on min..max, dragged to rotate
  text_input: 17, // single-line text field (host-owned editable value)
  text_area: 18,  // multi-line text field (wraps; Enter inserts a newline)
  icon: 19,       // a vector icon (Lucide) rendered as an SDF, tinted by fg
  spinner: 20,    // round animated wait cursor (dot-ring; host drives the RAF)
  // scene (21): a content-AGNOSTIC 3D scene viewport. The host fills the node's
  // rect with the 3D scene named by ATTR.scene_id (a host scene catalog, like
  // text_id is a host glyph catalog — no strings cross the wasm boundary). The
  // viewport is a back layer; QView widgets drawn after it (e.g. a card placed
  // over it in a `stack`) composite ON TOP — this is how a form overlays 3D.
  // Renderer-agnostic: the web host renders it with the quine game engine; a
  // native host renders the same scene id through its own 3D backend (sokol /
  // render.zig). The cube is just one scene's DATA, never baked into this kind.
  scene: 21,
};
export const KIND_NAME = Object.fromEntries(Object.entries(KIND).map(([k, v]) => [v, k]));

// Attributes (spec §"Attributes"). Geometry (0..3,18) applies to every node.
export const ATTR = {
  x: 0, y: 1, w: 2, h: 3, radius: 4, border_w: 5, fill: 6, border: 7, fg: 8,
  text_id: 9, image_id: 10, enabled: 11, checked: 12, selected: 13, group: 14,
  min: 15, max: 16, value: 17, z: 18, gap: 19,
  // surface (20): a SEMANTIC fill role resolved against the platform theme,
  // instead of a literal AARRGGBB `fill`. Lets a producer say "this is a frosted
  // bar" and get the iOS/Material/desktop material automatically. Values = SURFACE.
  surface: 20,
  // align (21): cross-axis alignment of a stack's children (a row aligns on y, a
  // column on x). Values = ALIGN. pad (22): inner padding of a stack/group.
  align: 21, pad: 22,
  // value2 (23): a second channel value (a stereo meter's right level; left is
  // ATTR.value). peak (24): peak-hold level for the left channel; peak2 (25) the
  // right. All on the min..max scale.
  value2: 23, peak: 24, peak2: 25,
  // icon (26): the host ICONS catalog index of a vector icon to draw — on an
  // `icon` node, or on a `button` (icon-only, or icon + label).
  icon: 26,
  // max_w (27) / min_w (28): width constraints clamped by the layout engine. On
  // a `column` child with `align: stretch`, max_w caps the stretched width and
  // the child is re-centered in the freed space — the responsive "content
  // container" (fill small screens, cap + center on wide ones). They also clamp
  // a node's intrinsic/explicit width anywhere. See arrange.js.
  max_w: 27, min_w: 28,
  // scene_id (29): on a `scene` node, the host scene-catalog id of the 3D scene
  // to render in the viewport (mirrors text_id's host-catalog pattern — an
  // integer, no strings cross wasm). Catalog id 0 is the host's default scene
  // (a slowly turning cube). Unknown ids fall back to the default.
  scene_id: 29,
};
export const ATTR_NAME = Object.fromEntries(Object.entries(ATTR).map(([k, v]) => [v, k]));

// Surface roles for ATTR.surface (theme-resolved translucent fills). Alpha
// material today; true backdrop blur is a deferred renderer pass.
export const SURFACE = {
  none: 0, surface: 1, material: 2, materialThin: 3, scrim: 4,
};

// Cross-axis alignment for stack children (ATTR.align). SwiftUI-style.
export const ALIGN = {
  start: 0, center: 1, end: 2, stretch: 3,
};

// Events (spec §"Events"). text_input uses input (per keystroke), change (on
// commit/blur), focus, blur.
export const EVENT = {
  press: 0, change: 1, input: 2, drag: 3, key: 4, focus: 5, blur: 6,
};
export const EVENT_NAME = Object.fromEntries(Object.entries(EVENT).map(([k, v]) => [v, k]));

// Text-channel keys for the `set_text` op (a STRING crosses the wasm boundary as
// (ptr, len) into linear memory — distinct from the integer `set_attr`). A node
// carries a small set of named strings; the host reads UTF-8 from wasm memory.
//   value:       the field's text (app sets initial/validated text; host owns edits)
//   placeholder: dimmed prompt shown when value is empty
export const TEXTKEY = { value: 0, placeholder: 1 };
export const TEXTKEY_NAME = Object.fromEntries(Object.entries(TEXTKEY).map(([k, v]) => [v, k]));

// A packed-color i64 (0x00AARRGGBB) -> normalized [r,g,b,a] for WebGPU.
export function unpackColor(v) {
  const n = Number(v) >>> 0;
  const a = (n >>> 24) & 0xff, r = (n >>> 16) & 0xff, g = (n >>> 8) & 0xff, b = n & 0xff;
  return [r / 255, g / 255, b / 255, a / 255];
}
