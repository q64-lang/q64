// scene (kind 21): a content-agnostic 3D viewport. The 3D itself is NOT drawn on
// the QView (#gpu) canvas — it is rendered by the host's engine on a separate
// canvas BEHIND #gpu (see scene3d.js). This widget's job is only to (1) activate
// the named scene and (2) keep the engine canvas placed, so QView widgets that
// come AFTER this node composite on top — that is the overlay.
//
// Stage 1 renders the scene FULL-BLEED (the whole surface) as a backdrop: a qube
// can't know the device size, and the common case is "3D behind a form." A
// placed/sub-rect viewport (honoring the node's laid-out x/y/w/h) is a
// forward-compatible follow-up. draw() paints (almost) nothing to #gpu: while a
// scene is live the host clears #gpu transparent so the engine shows through; a
// dim placeholder fills the surface only until the engine's first frame lands.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';
import { activate, place, isLive } from '../scene3d.js';

register(KIND.scene, {
  draw(node, r) {
    const sceneId = r.attr(node, ATTR.scene_id, 0);
    activate(sceneId);   // boots the engine lazily; idempotent per id
    place(null);         // Stage 1: full-bleed backdrop (whole #gpu rect)
    if (!isLive()) {     // placeholder until the engine's first frame lands
      const cv = document.getElementById('gpu');
      const w = cv ? cv.clientWidth : 0, h = cv ? cv.clientHeight : 0;
      if (w > 0 && h > 0) r.drawPrim(r.pass, 0, 0, w, h, [0.03, 0.04, 0.06, 1], {});
    }
  },
  // No intrinsic size — it's a backdrop. Report a small box so layout/centering of
  // sibling overlay nodes isn't skewed by a giant phantom extent.
  measure() { return { w: 0, h: 0 }; },
});
