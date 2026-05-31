// QView Stage-1 retained mutation protocol — the frozen contract.
// Mirrors spec/qview-protocol.md. These enums are APPEND-ONLY and shared by
// every producer (the q64 compiler, agents) and the host. A widget adds a KIND
// tag here and a draw entry in widgets.js; it never edits the op set.
//
// PROTOCOL_VERSION bumps minor on append, major on any meaning/encoding change.
export const PROTOCOL_VERSION = '1.4';

// Node kinds (spec §"Node kinds"). 13 = text_input is RESERVED (deferred).
export const KIND = {
  box: 0, row: 1, column: 2, stack: 3, label: 4, image: 5, button: 6,
  checkbox: 7, switch: 8, radio: 9, slider: 10, progress: 11, dropdown: 12,
  divider: 13,   // thin separator line (hairline rule)
  group: 14,     // titled container: a panel + heading that holds sub-widgets
  meter: 15,     // level/VU meter (mono or stereo) — value=level, used for peak meters
  // text_input: 16,  // reserved — focus/blur/key follow-up
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

// Events (spec §"Events"). 4..6 reserved for text_input.
export const EVENT = {
  press: 0, change: 1, input: 2, drag: 3, key: 4, focus: 5, blur: 6,
};
export const EVENT_NAME = Object.fromEntries(Object.entries(EVENT).map(([k, v]) => [v, k]));

// A packed-color i64 (0x00AARRGGBB) -> normalized [r,g,b,a] for WebGPU.
export function unpackColor(v) {
  const n = Number(v) >>> 0;
  const a = (n >>> 24) & 0xff, r = (n >>> 16) & 0xff, g = (n >>> 8) & 0xff, b = n & 0xff;
  return [r / 255, g / 255, b / 255, a / 255];
}
