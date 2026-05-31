// QView Stage-1 retained mutation protocol — the frozen contract.
// Mirrors spec/qview-protocol.md. These enums are APPEND-ONLY and shared by
// every producer (the q64 compiler, agents) and the host. A widget adds a KIND
// tag here and a draw entry in widgets.js; it never edits the op set.
//
// PROTOCOL_VERSION bumps minor on append, major on any meaning/encoding change.
export const PROTOCOL_VERSION = '1.0';

// Node kinds (spec §"Node kinds"). 13 = text_input is RESERVED (deferred).
export const KIND = {
  box: 0, row: 1, column: 2, stack: 3, label: 4, image: 5, button: 6,
  checkbox: 7, switch: 8, radio: 9, slider: 10, progress: 11, dropdown: 12,
  // text_input: 13,  // reserved — focus/blur/key follow-up
};
export const KIND_NAME = Object.fromEntries(Object.entries(KIND).map(([k, v]) => [v, k]));

// Attributes (spec §"Attributes"). Geometry (0..3,18) applies to every node.
export const ATTR = {
  x: 0, y: 1, w: 2, h: 3, radius: 4, border_w: 5, fill: 6, border: 7, fg: 8,
  text_id: 9, image_id: 10, enabled: 11, checked: 12, selected: 13, group: 14,
  min: 15, max: 16, value: 17, z: 18, gap: 19,
};
export const ATTR_NAME = Object.fromEntries(Object.entries(ATTR).map(([k, v]) => [v, k]));

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
