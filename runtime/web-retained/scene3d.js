// scene3d — the WEB renderer for the QView `scene` viewport kind (protocol 21).
//
// A `scene` node is a content-agnostic 3D viewport: the producer names a scene by
// integer id (ATTR.scene_id), the host renders it. On the web that renderer is
// the **quine** game engine (the cross-platform wasm 3D engine, loaded from the
// CDN) drawn on its OWN canvas BEHIND the QView (#gpu) canvas; QView widgets then
// composite on top (app.js makes #gpu transparent while a scene is live). A
// native host renders the same scene id through its own 3D backend — the producer
// never knows which (spec/qview-protocol.md §"3D scene viewport").
//
// This module owns one engine instance and one back canvas, booted lazily the
// first time a scene becomes active. It is heavily guarded: if WebGL/WebGPU or
// the engine bundle is unavailable, it logs and no-ops, and the QView form still
// renders (graceful degradation, like quine's own 2D fallback).
//
// The host scene CATALOG mirrors the glyph catalog: an integer id -> a scene. Only
// id 0 (a slowly turning cube) ships today; add scenes here, never strings over
// the wasm boundary. The engine BUNDLE comes from the CDN; the scene DATA (and the
// cube mesh) are local (we don't depend on a CDN scene existing).

const ENGINE_BASE = 'https://cdn.qubeworlds.com/engine';

// The cube MESH, a tiny embedded glTF (.glb), provided to the engine by name.
// NB: the engine only animates MESH entities (its `spin` ECS system rotates the
// transform, and the mesh renderer honours it). An SDF shape can't spin — the
// raymarcher ignores the entity transform — so a turning cube must be a mesh, and
// there is no built-in cube; hence this asset.
const CUBE_GLB_B64 = 'Z2xURgIAAAC8BQAAGAMAAEpTT057ImFzc2V0Ijp7InZlcnNpb24iOiIyLjAiLCJnZW5lcmF0b3IiOiJxdmlldy1jdWJlIn0sInNjZW5lIjowLCJzY2VuZXMiOlt7Im5vZGVzIjpbMF19XSwibm9kZXMiOlt7Im1lc2giOjB9XSwibWVzaGVzIjpbeyJwcmltaXRpdmVzIjpbeyJhdHRyaWJ1dGVzIjp7IlBPU0lUSU9OIjowLCJOT1JNQUwiOjF9LCJpbmRpY2VzIjoyLCJtYXRlcmlhbCI6MH1dfV0sIm1hdGVyaWFscyI6W3sicGJyTWV0YWxsaWNSb3VnaG5lc3MiOnsiYmFzZUNvbG9yRmFjdG9yIjpbMC4zLDAuNjIsMS4wLDEuMF0sIm1ldGFsbGljRmFjdG9yIjowLjAsInJvdWdobmVzc0ZhY3RvciI6MC41NX19XSwiYnVmZmVycyI6W3siYnl0ZUxlbmd0aCI6NjQ4fV0sImJ1ZmZlclZpZXdzIjpbeyJidWZmZXIiOjAsImJ5dGVPZmZzZXQiOjAsImJ5dGVMZW5ndGgiOjI4OCwidGFyZ2V0IjozNDk2Mn0seyJidWZmZXIiOjAsImJ5dGVPZmZzZXQiOjI4OCwiYnl0ZUxlbmd0aCI6Mjg4LCJ0YXJnZXQiOjM0OTYyfSx7ImJ1ZmZlciI6MCwiYnl0ZU9mZnNldCI6NTc2LCJieXRlTGVuZ3RoIjo3MiwidGFyZ2V0IjozNDk2M31dLCJhY2Nlc3NvcnMiOlt7ImJ1ZmZlclZpZXciOjAsImNvbXBvbmVudFR5cGUiOjUxMjYsImNvdW50IjoyNCwidHlwZSI6IlZFQzMiLCJtaW4iOlstMSwtMSwtMV0sIm1heCI6WzEsMSwxXX0seyJidWZmZXJWaWV3IjoxLCJjb21wb25lbnRUeXBlIjo1MTI2LCJjb3VudCI6MjQsInR5cGUiOiJWRUMzIn0seyJidWZmZXJWaWV3IjoyLCJjb21wb25lbnRUeXBlIjo1MTIzLCJjb3VudCI6MzYsInR5cGUiOiJTQ0FMQVIifV19AACIAgAAQklOAAAAgL8AAIC/AACAPwAAgD8AAIC/AACAPwAAgD8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIC/AACAvwAAgL8AAIC/AACAvwAAgL8AAIA/AACAvwAAgD8AAIA/AACAvwAAgD8AAIC/AACAPwAAgD8AAIC/AACAvwAAgD8AAIA/AACAvwAAgD8AAIA/AACAPwAAgL8AAIC/AACAvwAAgL8AAIC/AACAPwAAgL8AAIA/AACAPwAAgL8AAIA/AACAvwAAgL8AAIA/AACAPwAAgD8AAIA/AACAPwAAgD8AAIA/AACAvwAAgL8AAIA/AACAvwAAgL8AAIC/AACAvwAAgD8AAIC/AACAvwAAgD8AAIC/AACAPwAAgL8AAIC/AACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAAAAAAAAAAACAvwAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAgL8AAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAAAAAIC/AAAAAAAAAQACAAAAAgADAAQABQAGAAQABgAHAAgACQAKAAgACgALAAwADQAOAAwADgAPABAAEQASABAAEgATABQAFQAWABQAFgAXAA==';

// Scene 0 — a turning cube: the glТF cube mesh above + a `spin` component (the
// engine's ECS spin system rotates it), a directional key light, a sky/ambient
// environment, and an orbit camera. The cube is DATA here, never baked into the
// protocol or host.
const CUBE_SCENE = JSON.stringify({
  schemaVersion: 1,
  name: 'cube',
  entities: [
    {
      name: 'cube',
      geometry: { kind: 'gltf', source: 'cube' },
      material: { color: [0.30, 0.62, 1.0, 1.0], metallic: 0.0, roughness: 0.55 },
      spin: { velocity: [0.35, 0.7, 0.0] },
    },
    { name: 'key', light: { kind: 'directional', direction: [-0.4, -0.8, -0.5], color: [1, 1, 1], intensity: 1.3 } },
    { name: 'sky', environment: { sky: { zenith: [0.03, 0.05, 0.09], horizon: [0.08, 0.11, 0.18] }, ambient: { color: [0.40, 0.50, 0.70], intensity: 0.5 } } },
    { name: 'camera', transform: { position: [3, 2, 5] }, camera: { controller: { kind: 'orbit', target: [0, 0, 0], distance: 5, yaw: 0.6, pitch: 0.25 } } },
  ],
});

// Assets each scene needs provided (by name) before it builds. Scene 0 -> the cube mesh.
const SCENE_ASSETS = { 0: [{ name: 'cube', b64: CUBE_GLB_B64 }] };

const CATALOG = { 0: CUBE_SCENE };

const DPR = Math.max(1, Math.min(3, (typeof window !== 'undefined' && window.devicePixelRatio) || 1));
const log = (m) => console.log('[qview scene3d]', m);

let backCanvas = null;     // the engine's own <canvas>, behind #gpu
let booting = false;       // engine bundle requested, runtime not yet ready
let ready = false;         // onRuntimeInitialized fired
let failed = false;        // boot failed — stop retrying, stay degraded
let activeId = null;       // currently-rendered scene id, or null
let pendingId = null;      // scene id requested before the runtime was ready
const provided = new Set();// asset names already handed to the engine

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

// Hand a scene's assets (meshes) to the engine by name, BEFORE the scene builds.
function provideAssets(id) {
  const list = SCENE_ASSETS[id] ?? [];
  for (const a of list) {
    if (provided.has(a.name)) continue;
    try {
      const bytes = b64ToBytes(a.b64);
      const p = window.Module._malloc(bytes.length);
      window.Module.HEAPU8.set(bytes, p);
      window.Module.ccall('quine_provide_asset', null, ['string', 'number', 'number'], [a.name, p, bytes.length]);
      window.Module._free(p);
      provided.add(a.name);
    } catch (e) { log('provide asset failed (' + a.name + '): ' + (e && e.message)); }
  }
}

// Feed the active scene into the running engine (assets first, then the scene).
function enqueueScene(id) {
  const json = CATALOG[id] ?? CATALOG[0];
  try {
    provideAssets(id in CATALOG ? id : 0);
    window.Module.ccall('quine_enqueue', null, ['string'], [JSON.stringify({ type: 'scene', json })]);
    window.Module.ccall('quine_set_autoplay', null, ['number'], [1]);
    try { window.Module.ccall('quine_set_hud', null, ['number'], [0]); } catch {}
    activeId = id;
  } catch (e) { log('enqueue failed: ' + (e && e.message)); }
}

async function boot(id) {
  if (booting || ready || failed) return;
  booting = true;
  const canvas = ensureCanvas();
  if (!canvas) { booting = false; return; }
  // Backend: prefer a real WebGPU adapter; fall back to the WebGL2 floor.
  let backend = 'webgl2';
  try { if (navigator.gpu && (await navigator.gpu.requestAdapter())) backend = 'webgpu'; } catch {}
  const bust = '?v=' + Date.now();
  pendingId = id;
  window.Module = {
    canvas,
    locateFile: (p) => ENGINE_BASE + '/' + p + bust,
    print: (t) => log('engine: ' + t),
    printErr: (t) => log('engine[err]: ' + t),
    onAbort: (w) => { log('engine ABORT: ' + w); failed = true; },
    onRuntimeInitialized: () => {
      ready = true; booting = false;
      enqueueScene(pendingId ?? 0);
      if (activeId !== null) canvas.style.display = '';
    },
  };
  const s = document.createElement('script');
  s.async = true; s.crossOrigin = 'anonymous';
  s.src = ENGINE_BASE + '/quine-' + backend + '.js' + bust;
  s.onerror = () => { log('engine script failed to load: ' + s.src); failed = true; booting = false; };
  document.head.appendChild(s);
  log('booting engine (' + backend + ')');
}

/** Activate scene `id` (boot lazily on first call). Returns true if a 3D layer is
 *  (or is becoming) live — app.js uses this to make #gpu transparent. */
export function activate(id) {
  if (failed) return false;
  const sid = Number(id) || 0;
  if (!ready) { pendingId = sid; void boot(sid); return true; }
  if (sid !== activeId) enqueueScene(sid);
  if (backCanvas) backCanvas.style.display = '';
  return true;
}

/** No scene node present this frame — hide the 3D layer (engine keeps idling). */
export function deactivate() {
  activeId = null;
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

export function isLive() { return ready && activeId !== null; }
