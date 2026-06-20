// scene3d — the WEB renderer for the QView `scene` viewport kind (protocol 21).
//
// A `scene` node is a content-agnostic 3D viewport: the producer names a scene by
// integer id (ATTR.scene_id), the host renders it. On the web that renderer is
// the **quine** game engine (the cross-platform wasm 3D engine, loaded from the
// CDN) drawn on its OWN canvas BEHIND the QView (#gpu) canvas; QView widgets then
// composite on top (app.js makes #gpu transparent while a scene is live). A
// native host renders the same scene id through its own 3D backend.
//
// CONTENT LIVES IN THE PROJECT, NEVER HERE. This framework module carries no
// scene and no meshes. The project (a qube) declares its 3D scene + assets in its
// qube.json5 `game` block; the host loads them from the project and injects them
// as `window.__qubonautGame = { scene: <json>, assets: [{ name, b64 }] }` (see
// scripts/build-qview.sh + the Qubonaut shell). The engine takes meshes by name
// via `quine_provide_asset`. A `.glb` is user data — it is never baked into the
// engine or this host (quine/world CLAUDE.md: distribution is the CDN/project's
// job, the engine is content-agnostic).
//
// Heavily guarded: if WebGL/WebGPU, the engine bundle, or the project content is
// unavailable, it logs and no-ops, and the QView form still renders.

const ENGINE_BASE = 'https://cdn.qubeworlds.com/engine';

const DPR = Math.max(1, Math.min(3, (typeof window !== 'undefined' && window.devicePixelRatio) || 1));
const log = (m) => console.log('[qview scene3d]', m);

// The project's 3D content, injected by the host (or null for a plain 2D qube).
function game() { return (typeof window !== 'undefined' && window.__qubonautGame) || null; }

let backCanvas = null;     // the engine's own <canvas>, behind #gpu
let booting = false;       // engine bundle requested, runtime not yet ready
let ready = false;         // onRuntimeInitialized fired
let failed = false;        // boot failed — stop retrying, stay degraded
let active = false;        // a scene is currently shown
let want = false;          // a scene was requested before the runtime was ready
let provided = false;      // the project's assets have been handed to the engine

function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Create (once) the back canvas, positioned to overlay the #gpu canvas's rect.
function ensureCanvas() {
  if (backCanvas) return backCanvas;
  const gpu = document.getElementById('gpu');
  if (!gpu) return null;
  const c = document.createElement('canvas');
  c.id = 'quine';
  c.style.position = 'fixed';
  c.style.zIndex = '0';            // behind #gpu (which we raise to 1)
  c.style.background = '#07090d';
  c.style.display = 'none';
  c.style.pointerEvents = 'none';  // taps belong to the QView canvas on top
  gpu.style.position = 'relative';
  gpu.style.zIndex = '1';
  gpu.parentElement.insertBefore(c, gpu);   // DOM order; z-index does the layering
  backCanvas = c;
  return c;
}

// Hand the PROJECT's assets (meshes) to the engine by name, before the scene
// builds. Bytes come from the injected game content, never from this module.
function provideAssets() {
  if (provided) return;
  const g = game();
  if (!g || !Array.isArray(g.assets)) return;
  for (const a of g.assets) {
    try {
      const bytes = b64ToBytes(a.b64);
      const p = window.Module._malloc(bytes.length);
      window.Module.HEAPU8.set(bytes, p);
      window.Module.ccall('quine_provide_asset', null, ['string', 'number', 'number'], [a.name, p, bytes.length]);
      window.Module._free(p);
    } catch (e) { log('provide asset failed (' + (a && a.name) + '): ' + (e && e.message)); }
  }
  provided = true;
}

// Feed the project's scene into the running engine (assets first, then the scene).
function enqueueScene() {
  const g = game();
  if (!g || !g.scene) { log('no project scene to render (window.__qubonautGame is empty)'); return; }
  try {
    provideAssets();
    window.Module.ccall('quine_enqueue', null, ['string'], [JSON.stringify({ type: 'scene', json: g.scene })]);
    window.Module.ccall('quine_set_autoplay', null, ['number'], [1]);
    try { window.Module.ccall('quine_set_hud', null, ['number'], [0]); } catch {}
    active = true;
  } catch (e) { log('enqueue failed: ' + (e && e.message)); }
}

async function boot() {
  if (booting || ready || failed) return;
  if (!game()) { log('no project 3D content injected — nothing to render'); return; }
  booting = true;
  const canvas = ensureCanvas();
  if (!canvas) { booting = false; return; }
  // Backend: prefer a real WebGPU adapter; fall back to the WebGL2 floor.
  let backend = 'webgl2';
  try { if (navigator.gpu && (await navigator.gpu.requestAdapter())) backend = 'webgpu'; } catch {}
  const bust = '?v=' + Date.now();
  window.Module = {
    canvas,
    locateFile: (p) => ENGINE_BASE + '/' + p + bust,
    print: (t) => log('engine: ' + t),
    printErr: (t) => log('engine[err]: ' + t),
    onAbort: (w) => { log('engine ABORT: ' + w); failed = true; },
    onRuntimeInitialized: () => {
      ready = true; booting = false;
      if (want) { enqueueScene(); if (active) canvas.style.display = ''; }
    },
  };
  const s = document.createElement('script');
  s.async = true; s.crossOrigin = 'anonymous';
  s.src = ENGINE_BASE + '/quine-' + backend + '.js' + bust;
  s.onerror = () => { log('engine script failed to load: ' + s.src); failed = true; booting = false; };
  document.head.appendChild(s);
  log('booting engine (' + backend + ')');
}

/** Activate the project's scene (boot lazily on first call). Returns true if a 3D
 *  layer is (or is becoming) live — app.js uses this to make #gpu transparent. */
export function activate() {
  if (failed || !game()) return false;
  want = true;
  if (!ready) { void boot(); return true; }
  if (!active) enqueueScene();
  if (backCanvas) backCanvas.style.display = '';
  return true;
}

/** No scene node present this frame — hide the 3D layer (engine keeps idling). */
export function deactivate() {
  active = false;
  if (backCanvas) backCanvas.style.display = 'none';
}

/** Size + place the back canvas to a CSS-px rect in the #gpu canvas's local space
 *  (the scene node's laid-out rect), or null to fill the whole #gpu surface. */
export function place(rect) {
  if (!backCanvas) return;
  const gpu = document.getElementById('gpu');
  if (!gpu) return;
  const r = gpu.getBoundingClientRect();
  const x = r.left + ((rect && rect.x) || 0);
  const y = r.top + ((rect && rect.y) || 0);
  const w = (rect && rect.w) || gpu.clientWidth;
  const h = (rect && rect.h) || gpu.clientHeight;
  backCanvas.style.left = x + 'px';
  backCanvas.style.top = y + 'px';
  backCanvas.style.width = w + 'px';
  backCanvas.style.height = h + 'px';
  const bw = Math.max(1, Math.round(w * DPR)), bh = Math.max(1, Math.round(h * DPR));
  if (backCanvas.width !== bw || backCanvas.height !== bh) { backCanvas.width = bw; backCanvas.height = bh; }
}

export function isLive() { return ready && active; }
