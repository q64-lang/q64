// scene (kind 21): a content-agnostic 3D viewport. The 3D is rendered by the
// host's engine on a separate canvas BEHIND #gpu (see scene3d.js), from the
// PROJECT's own scene + assets (qube.json5 `game` block, injected as
// window.__qubonautGame). This widget (1) activates that scene and (2) keeps the
// engine canvas placed; QView widgets after this node composite on top.
//
// Stage 1 renders the scene FULL-BLEED. While the 3D isn't live yet (booting, no
// content, or a boot failure) we paint a dim placeholder AND the engine's boot
// STATUS text on #gpu — so a Snap (which only captures #gpu, never the engine
// canvas) reveals the actual reason on-device instead of a blank black layer.
import { KIND, ATTR } from '../protocol.js';
import { register } from '../registry.js';
import { activate, place, isLive, status } from '../scene3d.js';

register(KIND.scene, {
  draw(node, r) {
    void r.attr(node, ATTR.scene_id, 0);  // reserved: select among a project's scenes
    activate();          // boots the engine + loads the project's scene; idempotent
    place(null);         // Stage 1: full-bleed backdrop (whole #gpu rect)
    if (isLive()) return;
    // Not live yet → dim placeholder + the boot status line (Snap-visible).
    const cv = document.getElementById('gpu');
    const w = cv ? cv.clientWidth : 0, h = cv ? cv.clientHeight : 0;
    if (w <= 0 || h <= 0) return;
    r.drawPrim(r.pass, 0, 0, w, h, [0.03, 0.04, 0.06, 1], {});
    if (r.glyphForStr) {
      const g = r.glyphForStr(status(), 16);
      if (g) r.drawPrim(r.pass, Math.max(8, (w - g.w) / 2), 72, g.w, g.h, [0.55, 0.85, 1, 1], { texView: g.view });
    }
  },
  measure() { return { w: 0, h: 0 }; },
});
