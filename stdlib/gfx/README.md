# stdlib/gfx → `q64.gfx`

Graphics primitives and GPU bridging.

> **Status: not yet implemented.**

## Surface (planned)

- **Color types** — `Rgb<Space, Repr>`, `Hsv<Space, Repr>`, `Lab<Repr>`,
  `Rgba<Space, Repr, Alpha>`, parameterized by color space (sRGB / Linear /
  Display P3 / Rec.709 / Rec.2020 / ACEScg), representation (`u8`, `u10`,
  `f16`, `f32`), and alpha convention (Straight / Premul).
- **Images** — `Image<Pixel>` with stride and bounds in the type.
- **GPU bridging** — WebGPU (in browser), Vulkan/Metal/D3D12 (native) via
  the runtime adapter. The user-facing surface is host-agnostic; the
  adapter picks the backing API.
- **Shaders** — q64-source compute and render shaders compiled to WGSL /
  SPIR-V via the compiler, not embedded as strings.

## Today: scenes render through an engine, not this surface

Until the typed surface above lands, 3D reaches the screen as **data, not draw
calls**: a QView `scene` viewport names a host scene by id and the host renders
it with a real cross-platform engine (web → the **quine** wasm engine; native →
its sokol backend). That keeps a turning cube + an overlaid form working on the
integer-only QView ABI with no `q64.gfx`/`q64.math` yet. See
[`spec/qview-protocol.md` §"3D scene viewport"](../../spec/qview-protocol.md) and
the `scene_overlay` registry composite. An imperative `gfx` draw face is a later
addition once the color/math types here exist; it does not replace the
scene-as-data path.

The type system catches the standard graphics bugs: blending in sRGB instead
of linear, mixing color spaces on the same canvas, swapping straight and
premultiplied alpha.
