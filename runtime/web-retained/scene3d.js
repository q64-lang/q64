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

import { unpackColor } from './protocol.js';

const ENGINE_BASE = 'https://cdn.qubeworlds.com/engine';

const DPR = Math.max(1, Math.min(3, (typeof window !== 'undefined' && window.devicePixelRatio) || 1));
const log = (m) => console.log('[qview scene3d]', m);

// A human-readable boot status, drawn ON the QView canvas by the scene widget
// while the 3D isn't live — so a Snap (which only captures #gpu) reveals the
// actual failure (no content / engine abort / CDN load / context) on-device.
let statusLine = 'scene: idle';
function note(s) { statusLine = s; log(s); }
export function status() { return statusLine; }

// The project's 3D content, injected by the host (or null for a plain 2D qube).
function game() { return (typeof window !== 'undefined' && window.__qubonautGame) || null; }

// Full injection-pipeline trace (each hop writes a sessionStorage flag): so one
// Snap shows exactly where the project's `game` payload was lost on the way to
// the iframe.  recv=tab onPreview · show=showPreview · set=qnGame bytes written ·
// shim=iframe parse · win=window.__qubonautGame present.
function ss(k) { try { return sessionStorage.getItem(k) || '-'; } catch { return '?'; } }
function traceStr() { return `recv=${ss('qnT_recv')} show=${ss('qnT_show')} set=${ss('qnT_set')} shim=${ss('qnT_shim')} win=${game() ? 'Y' : 'N'}`; }

let backCanvas = null;     // the engine's own <canvas>, behind #gpu
let booting = false;       // engine bundle requested, runtime not yet ready
let ready = false;         // onRuntimeInitialized fired
let failed = false;        // boot failed — stop retrying, stay degraded
let active = false;        // a scene is currently shown
let want = false;          // a scene was requested before the runtime was ready
let provided = false;      // the project's assets have been handed to the engine
let sceneObj = null;       // the project's scene, parsed ONCE and kept in memory
let tintPacked = 0;        // producer tint (packed AARRGGBB on the scene node's `fill`); 0 = the scene's own colors

// The scene object, parsed once from the injected content and cached — so a tint
// update is a cheap in-memory mutate + re-stringify, not a re-parse (fast scene
// changes, per the design). The host edits the scene it hands over; the ENGINE
// stays content-agnostic (the only producer→3D channel is `quine_enqueue`).
function sceneObject() {
  if (sceneObj) return sceneObj;
  const g = game();
  if (!g || !g.scene) return null;
  try { sceneObj = JSON.parse(g.scene); } catch { sceneObj = null; }
  return sceneObj;
}

// The current scene JSON, with the active tint applied to each rendered entity's
// material (the cube). `tintPacked === 0` leaves the scene's authored colors.
function currentSceneJson() {
  const obj = sceneObject();
  if (!obj) return null;
  if (tintPacked) {
    const [r, g, b, a] = unpackColor(tintPacked);
    for (const e of obj.entities || []) {
      if (e && e.geometry && e.material) e.material.color = [r, g, b, a];
    }
  }
  return JSON.stringify(obj);
}

/** Tint the scene's mesh(es) to a packed AARRGGBB color (0 = the scene's own
 *  colors). Called by the `scene` widget from the node's `fill` attr. On a
 *  change it re-pushes the in-memory scene, which the engine hot-reloads with
 *  the new material — so tapping recolors the live cube. No-ops when unchanged
 *  (the widget calls it every frame) and when the color hasn't actually moved. */
export function setTint(packed) {
  packed = (packed >>> 0);
  if (packed === tintPacked) return;
  tintPacked = packed;
  if (!ready || !active) return; // applied when the scene next enqueues (boot)
  const json = currentSceneJson();
  if (!json) return;
  try {
    window.Module.ccall('quine_enqueue', null, ['string'], [JSON.stringify({ type: 'scene', json })]);
    window.Module.ccall('quine_set_autoplay', null, ['number'], [1]);
  } catch (e) { log('setTint enqueue failed: ' + (e && e.message)); }
}

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
  if (!g || !g.scene) { note('no 3D content · ' + traceStr()); return; }
  try {
    provideAssets();
    window.Module.ccall('quine_enqueue', null, ['string'], [JSON.stringify({ type: 'scene', json: currentSceneJson() ?? g.scene })]);
    window.Module.ccall('quine_set_autoplay', null, ['number'], [1]);
    try { window.Module.ccall('quine_set_hud', null, ['number'], [0]); } catch {}
    active = true;
    note('scene: engine ready — ' + (g.assets ? g.assets.length : 0) + ' asset(s)');
  } catch (e) { note('scene: enqueue failed — ' + (e && e.message)); }
}

async function boot() {
  if (booting || ready || failed) return;
  if (!game()) { note('no 3D content · ' + traceStr()); return; }
  booting = true;
  const canvas = ensureCanvas();
  if (!canvas) { booting = false; return; }
  // Backend: WebGL2 (NOT WebGPU). On iPad Safari the WebGPU bundle boots "ready"
  // but renders nothing; WebGL2 is the proven path (it rendered this exact scene
  // in headless GL, and three.js/WebGL renders on the device). qubeworlds renders
  // on webgl2 too. Pin it rather than probing for a WebGPU adapter that draws blank.
  const backend = 'webgl2';
  note('scene: booting engine (' + backend + ')');
  const bust = '?v=' + Date.now();
  window.Module = {
    canvas,
    locateFile: (p) => ENGINE_BASE + '/' + p + bust,
    print: (t) => log('engine: ' + t),
    printErr: (t) => { log('engine[err]: ' + t); note('scene: engine err — ' + t); },
    onAbort: (w) => { failed = true; note('scene: engine ABORT — ' + w); },
    onRuntimeInitialized: () => {
      ready = true; booting = false;
      if (want) { enqueueScene(); if (active) canvas.style.display = ''; }
    },
  };
  const s = document.createElement('script');
  s.async = true; s.crossOrigin = 'anonymous';
  s.src = ENGINE_BASE + '/quine-' + backend + '.js' + bust;
  s.onerror = () => { failed = true; booting = false; note('scene: engine bundle failed to load (CDN/CORS)'); };
  document.head.appendChild(s);
}

/** Activate the project's scene (boot lazily on first call). Returns true if a 3D
 *  layer is (or is becoming) live — app.js uses this to make #gpu transparent. */
export function activate() {
  if (failed) return false;
  if (!game()) { note('no 3D content · ' + traceStr()); return false; }
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
  // Set ONLY the CSS size + position. The engine (sokol) OWNS the canvas backing
  // store — it tracks the CSS size and sizes its framebuffer/GL viewport to match.
  // Setting backCanvas.width/height here fights it (viewport ≠ buffer) and squashes
  // the render into a corner — which was the wrong-size bug.
}

export function isLive() { return ready && active; }
