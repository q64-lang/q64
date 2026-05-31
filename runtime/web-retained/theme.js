// Per-platform theme tokens. One self-drawn renderer, three looks. Widgets read
// these via `r.theme`; structural differences (e.g. the switch) additionally
// branch on `r.platform` / a variant token below. Keep token parity across all
// three palettes so every widget resolves every token it reads.
//
// Colors are [r,g,b,a] in 0..1 (what drawPrim wants). Text uses `system-ui`,
// which already resolves to the native font ON-DEVICE (SF on iOS, Roboto on
// Android); `font` lets a desktop preview approximate it.

const rgb = (r, g, b, a = 1) => [r / 255, g / 255, b / 255, a];

// iOS (dark). System blue accent, green toggles, continuous-feel radii.
const ios = {
  name: 'ios',
  bg:          rgb(0, 0, 0),
  surface:     rgb(28, 28, 30),
  fg:          rgb(255, 255, 255),
  muted:       rgb(142, 142, 147),
  accent:      rgb(10, 132, 255),     // systemBlue (dark)
  accentInk:   rgb(255, 255, 255),
  border:      rgb(56, 56, 58),
  track:       rgb(57, 57, 61),       // switch OFF track
  on:          rgb(48, 209, 88),      // systemGreen — iOS switch ON
  knob:        rgb(255, 255, 255),
  // shape / variant tokens
  font:        'system-ui, -apple-system, sans-serif',
  controlRadius: 7,
  buttonShape:   'rounded',           // iOS: rounded rect
  buttonRadius:  12,
  switchVariant: 'ios',               // full-height white knob, color track
  checkShape:    'roundedSquare',
  checkRadius:   6,
};

// Material 3 (dark). Tonal primary, outline, track+growing-thumb switch.
const android = {
  name: 'android',
  bg:          rgb(28, 27, 31),
  surface:     rgb(28, 27, 31),
  fg:          rgb(230, 225, 229),
  muted:       rgb(202, 196, 208),
  accent:      rgb(208, 188, 255),    // M3 dark primary
  accentInk:   rgb(56, 30, 114),      // onPrimary
  border:      rgb(147, 143, 153),    // outline
  track:       rgb(73, 69, 79),       // surfaceVariant — switch OFF track
  on:          rgb(208, 188, 255),    // M3: track ON = primary
  knob:        rgb(230, 225, 229),
  font:        'system-ui, Roboto, sans-serif',
  controlRadius: 4,
  buttonShape:   'pill',              // M3 buttons are fully rounded
  buttonRadius:  9999,
  switchVariant: 'material',          // small thumb off / large thumb on
  checkShape:    'square',
  checkRadius:   2,
};

// Desktop — the neutral house look (the original gallery palette).
const desktop = {
  name: 'desktop',
  bg:          rgb(7, 9, 13),
  surface:     rgb(26, 33, 46),
  fg:          rgb(230, 242, 255),
  muted:       rgb(158, 176, 199),
  accent:      rgb(94, 212, 255),
  accentInk:   rgb(8, 13, 20),
  border:      rgb(41, 115, 158),
  track:       rgb(46, 56, 71),
  on:          rgb(94, 212, 255),
  knob:        rgb(230, 242, 255),
  font:        'system-ui, sans-serif',
  controlRadius: 8,
  buttonShape:   'rounded',
  buttonRadius:  14,
  switchVariant: 'ios',
  checkShape:    'roundedSquare',
  checkRadius:   6,
};

// Back-compat aliases for tokens widgets referenced before the per-platform
// split (accentDim/inkOnAccent). Derived so existing draw code keeps working.
for (const t of [ios, android, desktop]) {
  t.accentDim   = t.accent.map((c, i) => (i < 3 ? c * 0.7 : c));
  t.inkOnAccent = t.accentInk;
}

export const THEMES = { ios, android, desktop };
export function themeFor(platform) { return THEMES[platform] ?? THEMES.desktop; }
export const THEME = desktop; // default/back-compat
