// scene (kind 21): a content-agnostic 3D viewport. The 3D itself is NOT drawn on
// the QView (#gpu) canvas — it is rendered by the host's engine on a separate
// canvas BEHIND #gpu (see scene3d.js), from the PROJECT's own scene + assets
// (qube.json5 `game` block, injected as window.__qubonautGame). This widget only
// (1) activates that scene and (2) keeps the engine canvas placed, so QView
// widgets after this node composite on top — the overlay.
//
// Stage 1 renders the scene FULL-BLEED (a backdrop): a qube can't know the device
// size, and the common case is "3D behind a form." draw() paints (almost) nothing
// to #gpu — while a scene is live the host clears #gpu transparent so the engine
// shows through; a dim placeholder fills the surface only until the engine's first
// frame lands (or stays, if the project shipped no 3D content / the engine failed).
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';
import { activate, place, isLive } from '../scene3d.js';

register(KIND.scene, {
  draw(node, r) {
    // ATTR.scene_id is read for forward-compat (selecting among a project's
    // scenes later); today the project declares one scene, which the host loads.
    void r.attr(node, ATTR.scene_id, 0);
    activate();          // boots the engine + loads the project's scene; idempotent
    place(null);         // Stage 1: full-bleed backdrop (whole #gpu rect)
    if (!isLive()) {     // placeholder until the engine's first frame lands
      const cv = document.getElementById('gpu');
      const w = cv ? cv.clientWidth : 0, h = cv ? cv.clientHeight : 0;
      if (w > 0 && h > 0) r.drawPrim(r.pass, 0, 0, w, h, [0.03, 0.04, 0.06, 1], {});
    }
  },
  measure() { return { w: 0, h: 0 }; },
});
