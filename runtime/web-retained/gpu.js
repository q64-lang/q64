// WebGPU + SDF rendering primitives for the retained QView host.
// Lifted verbatim (logic-identical) from runtime/web/app.js so the retained host
// reuses the proven procedural-SDF pipeline: rounded-rect widgets via an SDF,
// text via a single-channel SDF atlas. No DOM, resolution-independent.
//
// Public surface used by app.js / widgets.js:
//   initGPU(canvas) -> {device, ctx}        set up device + pipeline
//   drawPrim(pass, x, y, w, h, fill, opts)   one SDF or glyph quad (CSS px)
//   sdfTexture(text) -> {tex, view, w, h}    rasterize a string to an SDF atlas
//   beginFrame() / endFrame()                clear + submit around a draw pass
//   DPR
export const DPR = Math.max(1, Math.min(3, window.devicePixelRatio || 1));

let device, ctx, format, primPipe, sampler, uniformBuf, whiteTex, bgLayout;

export async function initGPU(canvas) {
  if (!navigator.gpu) throw new Error('WebGPU not available in this browser');
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error('no WebGPU adapter');
  device = await adapter.requestDevice();
  ctx = canvas.getContext('webgpu');
  format = navigator.gpu.getPreferredCanvasFormat();
  // COPY_SRC on the canvas texture so the drawing buffer can be read back for
  // snapshots (canvas.toBlob/convertToBlob); without it WebGPU canvas capture
  // returns a blank/null image on Safari.
  ctx.configure({
    device, format, alphaMode: 'opaque',
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
  });

  uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });

  const wgsl = /* wgsl */`
    struct VP { size: vec2f, _pad: vec2f };
    @group(0) @binding(0) var<uniform> vp: VP;
    struct Prim { rect: vec4f, fill: vec4f, border: vec4f, params: vec4f };
    @group(0) @binding(1) var<uniform> p: Prim;
    @group(0) @binding(2) var samp: sampler;
    @group(0) @binding(3) var tex: texture_2d<f32>;
    struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) px: vec2f };
    @vertex fn vmain(@builtin(vertex_index) vi: u32) -> VOut {
      var cs = array<vec2f,6>(vec2f(0,0),vec2f(1,0),vec2f(0,1),vec2f(0,1),vec2f(1,0),vec2f(1,1));
      let corner = cs[vi];
      let isGlyph = p.params.z > 0.5;
      let pad = select(3.0, 0.0, isGlyph);
      let origin = p.rect.xy - vec2f(pad, pad);
      let size = p.rect.zw + vec2f(pad * 2.0, pad * 2.0);
      let px = origin + corner * size;
      let clip = vec2f(px.x / vp.size.x * 2.0 - 1.0, 1.0 - px.y / vp.size.y * 2.0);
      var o: VOut; o.pos = vec4f(clip, 0.0, 1.0); o.uv = corner; o.px = px; return o;
    }
    fn sdRoundBox(pt: vec2f, b: vec2f, r: f32) -> f32 {
      let q = abs(pt) - b + vec2f(r, r);
      return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0, 0.0))) - r;
    }
    @fragment fn fmain(in: VOut) -> @location(0) vec4f {
      if (p.params.z > 0.5) {
        let dist = textureSample(tex, samp, in.uv).r;
        let aa = max(fwidth(dist), 0.0001);
        let a = smoothstep(0.5 - aa, 0.5 + aa, dist);
        return vec4f(p.fill.rgb, p.fill.a * a);
      }
      let half = p.rect.zw * 0.5;
      let center = p.rect.xy + half;
      let d = sdRoundBox(in.px - center, half, p.params.x);
      let aa = max(fwidth(d), 0.0001);
      let cov = 1.0 - smoothstep(0.0, aa, d);
      let band = smoothstep(0.0, aa, d + p.params.y);
      let col = mix(p.fill, p.border, clamp(band, 0.0, 1.0));
      return vec4f(col.rgb, col.a * cov);
    }`;
  const mod = device.createShaderModule({ code: wgsl });
  if (mod.getCompilationInfo) {
    const info = await mod.getCompilationInfo();
    const errs = info.messages.filter((m) => m.type === 'error');
    if (errs.length) throw new Error('shader: ' + errs.map((m) => m.message).join('; '));
  }
  whiteTex = device.createTexture({ size: [1, 1], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
  device.queue.writeTexture({ texture: whiteTex }, new Uint8Array([255, 255, 255, 255]), {}, [1, 1]);

  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.VERTEX, buffer: {} },
      { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: {} },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT, texture: {} },
    ],
  });
  const pl = device.createPipelineLayout({ bindGroupLayouts: [layout] });
  const blend = { color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha' }, alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha' } };
  primPipe = device.createRenderPipeline({
    layout: pl,
    vertex: { module: mod, entryPoint: 'vmain' },
    fragment: { module: mod, entryPoint: 'fmain', targets: [{ format, blend }] },
    primitive: { topology: 'triangle-list' },
  });
  bgLayout = layout;
  return { device, ctx };
}

// opts: { radius, border, borderColor, texView } — px in CSS units. texView =>
// glyph mode; else a rounded-rect SDF. fill / borderColor are [r,g,b,a] in 0..1.
export function drawPrim(pass, x, y, w, h, fill, opts = {}) {
  const texView = opts.texView ?? null;
  const bcol = opts.borderColor ?? [0, 0, 0, 0];
  const params = [(opts.radius ?? 0) * DPR, (opts.border ?? 0) * DPR, texView ? 1 : 0, 0];
  const buf = device.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(buf, 0, new Float32Array([x * DPR, y * DPR, w * DPR, h * DPR, ...fill, ...bcol, ...params]));
  const bg = device.createBindGroup({
    layout: bgLayout,
    entries: [
      { binding: 0, resource: { buffer: uniformBuf } },
      { binding: 1, resource: { buffer: buf } },
      { binding: 2, resource: sampler },
      { binding: 3, resource: texView ?? whiteTex.createView() },
    ],
  });
  pass.setPipeline(primPipe);
  pass.setBindGroup(0, bg);
  pass.draw(6);
}

// Begin a render pass (clears the surface); returns the pass for drawing.
// `bg` is the platform background [r,g,b,a] in 0..1 (defaults to the house dark).
export function beginFrame(bg = [0.027, 0.035, 0.05, 1]) {
  const canvas = ctx.canvas;
  device.queue.writeBuffer(uniformBuf, 0, new Float32Array([canvas.width, canvas.height, 0, 0]));
  const enc = device.createCommandEncoder();
  const clearValue = { r: bg[0], g: bg[1], b: bg[2], a: bg[3] ?? 1 };
  const pass = enc.beginRenderPass({ colorAttachments: [{ view: ctx.getCurrentTexture().createView(), clearValue, loadOp: 'clear', storeOp: 'store' }] });
  return { enc, pass };
}
export function endFrame(frame) { frame.pass.end(); device.queue.submit([frame.enc.finish()]); }

// Clip subsequent draws to a rect (CSS px; scaled by DPR). Pass null to reset to
// the full surface. Used to keep scrolled content from bleeding over a sticky bar.
export function setScissor(pass, rect) {
  const cw = ctx.canvas.width, ch = ctx.canvas.height;
  if (!rect) { pass.setScissorRect(0, 0, cw, ch); return; }
  // Clamp the ORIGIN to the target too, not just the size. WebGPU requires
  // x+w ≤ width and y+h ≤ height; if a clip rect is off-screen (e.g. a text
  // field scrolled below the viewport, y > height) an unclamped x/y makes the
  // rect invalid → the render pass errors → a blank frame. Clamping x/y to
  // [0, cw]/[0, ch] keeps it valid (a degenerate 0-size rect when off-screen).
  const x = Math.max(0, Math.min(cw, Math.round(rect.x * DPR)));
  const y = Math.max(0, Math.min(ch, Math.round(rect.y * DPR)));
  const w = Math.max(0, Math.min(cw - x, Math.round(rect.w * DPR)));
  const h = Math.max(0, Math.min(ch - y, Math.round(rect.h * DPR)));
  pass.setScissorRect(x, y, w, h);
}

// ---- SDF text (8SSEDT). Identical algorithm to runtime/web/app.js. ----
function edt(seed, w, h) {
  const INF = 1e9;
  const gx = new Float64Array(w * h), gy = new Float64Array(w * h);
  for (let i = 0; i < w * h; i++) { gx[i] = seed[i] ? 0 : INF; gy[i] = seed[i] ? 0 : INF; }
  const d2 = (i) => gx[i] * gx[i] + gy[i] * gy[i];
  const cmp = (x, y, ox, oy) => {
    const nx = x + ox, ny = y + oy;
    if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
    const c = y * w + x, n = ny * w + nx;
    const cgx = gx[n] + ox, cgy = gy[n] + oy;
    if (cgx * cgx + cgy * cgy < d2(c)) { gx[c] = cgx; gy[c] = cgy; }
  };
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) { cmp(x, y, -1, 0); cmp(x, y, 0, -1); cmp(x, y, -1, -1); cmp(x, y, 1, -1); }
    for (let x = w - 1; x >= 0; x--) cmp(x, y, 1, 0);
  }
  for (let y = h - 1; y >= 0; y--) {
    for (let x = w - 1; x >= 0; x--) { cmp(x, y, 1, 0); cmp(x, y, 0, 1); cmp(x, y, -1, 1); cmp(x, y, 1, 1); }
    for (let x = 0; x < w; x++) cmp(x, y, -1, 0);
  }
  const out = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) out[i] = Math.sqrt(d2(i));
  return out;
}

// Turn a supersampled `inside` coverage mask (hw×hh) into a downsampled SDF
// `r8unorm` texture (the signed distance to the shape edge, normalized around
// 0.5). Shared by text glyphs and icons. `pad` (CSS px) is the spread baked
// around the ink on every side. ink size = (w or h) - 2*pad.
function buildSdf(inside, hw, hh, spread, SS) {
  const outside = new Uint8Array(hw * hh);
  for (let i = 0; i < hw * hh; i++) outside[i] = inside[i] ? 0 : 1;
  const dOut = edt(inside, hw, hh);
  const dIn = edt(outside, hw, hh);
  const sdfHi = new Float32Array(hw * hh);
  for (let i = 0; i < hw * hh; i++) {
    const sd = inside[i] ? dIn[i] : -dOut[i];
    sdfHi[i] = Math.max(0, Math.min(1, 0.5 + sd / (2 * spread)));
  }
  const w = Math.floor(hw / SS), h = Math.floor(hh / SS);
  const bytes = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let acc = 0;
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) acc += sdfHi[(y * SS + sy) * hw + (x * SS + sx)];
    bytes[y * w + x] = Math.max(0, Math.min(255, Math.round((acc / (SS * SS)) * 255)));
  }
  const tex = device.createTexture({ size: [w, h], format: 'r8unorm', usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
  device.queue.writeTexture({ texture: tex }, bytes, { bytesPerRow: w }, [w, h]);
  return { tex, view: tex.createView(), w: w / DPR, h: h / DPR, pad: spread / SS / DPR };
}

export function sdfTexture(text, sizePx = 17) {
  const SS = 3;
  const fontPx = Math.round(sizePx * DPR) * SS;
  const spread = Math.round(6 * DPR) * SS;
  const oc = new OffscreenCanvas(8, 8);
  let g = oc.getContext('2d');
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  const hw = Math.ceil(g.measureText(text).width) + spread * 2;
  const hh = fontPx + spread * 2;
  oc.width = hw; oc.height = hh;
  g = oc.getContext('2d');
  g.clearRect(0, 0, hw, hh);
  g.font = `${fontPx}px system-ui, -apple-system, sans-serif`;
  g.fillStyle = '#fff'; g.textBaseline = 'top';
  g.fillText(text, spread, spread);
  const a = g.getImageData(0, 0, hw, hh).data;
  const inside = new Uint8Array(hw * hh);
  for (let i = 0; i < hw * hh; i++) inside[i] = a[i * 4 + 3] > 127 ? 1 : 0;
  return buildSdf(inside, hw, hh, spread, SS);
}

// Rasterize a Lucide-style icon (a list of stroked elements on a 24×24 viewBox,
// stroke-2, round caps/joins) to an SDF texture at `sizePx`, reusing the glyph
// pipeline — so an icon draws as a tinted quad and stays crisp when scaled.
// `elements`: [['path', d] | ['circle', cx, cy, r] | ['line', x1, y1, x2, y2]].
export function iconSdf(elements, sizePx = 22) {
  const SS = 3;
  const spread = Math.round(6 * DPR) * SS;
  const S = Math.round(sizePx * DPR) * SS;       // icon ink size (supersampled device px)
  const hw = S + spread * 2, hh = S + spread * 2;
  const oc = new OffscreenCanvas(hw, hh);
  const g = oc.getContext('2d');
  g.clearRect(0, 0, hw, hh);
  g.translate(spread, spread);
  g.scale(S / 24, S / 24);                       // 24×24 viewBox → ink size
  g.strokeStyle = '#fff';
  g.lineWidth = 2; g.lineCap = 'round'; g.lineJoin = 'round';
  for (const el of elements) {
    if (el[0] === 'path') g.stroke(new Path2D(el[1]));
    else if (el[0] === 'circle') { g.beginPath(); g.arc(el[1], el[2], el[3], 0, Math.PI * 2); g.stroke(); }
    else if (el[0] === 'line') { g.beginPath(); g.moveTo(el[1], el[2]); g.lineTo(el[3], el[4]); g.stroke(); }
  }
  const a = g.getImageData(0, 0, hw, hh).data;
  const inside = new Uint8Array(hw * hh);
  for (let i = 0; i < hw * hh; i++) inside[i] = a[i * 4 + 3] > 110 ? 1 : 0;
  return buildSdf(inside, hw, hh, spread, SS);
}
