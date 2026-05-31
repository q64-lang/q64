// Platform detection for the QView PWA. We self-draw everything (one WebGPU
// renderer), but adapt the LOOK per OS: iOS-ish on iOS, Material-ish on Android.
// This module only decides *which* look; the theme + widget draw code apply it.
//
// A `?platform=ios|android|desktop` query override forces a look (so all three
// can be previewed on one machine — and so the gallery can show them side by
// side). Otherwise we sniff the environment.

export function detectPlatform(nav = (typeof navigator !== 'undefined' ? navigator : {})) {
  const ua = nav.userAgent || '';
  // Chromium Client Hints: the most reliable signal where present.
  const uaData = nav.userAgentData;
  if (uaData && typeof uaData.platform === 'string') {
    const p = uaData.platform.toLowerCase();
    if (p.includes('android')) return 'android';
    if (p.includes('ios')) return 'ios';
  }
  if (/android/i.test(ua)) return 'android';
  if (/iphone|ipad|ipod/i.test(ua)) return 'ios';
  // iPadOS 13+ reports as desktop Safari ("Macintosh") but is touch-first.
  if (/macintosh/i.test(ua) && (nav.maxTouchPoints || 0) > 1) return 'ios';
  return 'desktop';
}

// The active platform: ?platform= override wins, else detection.
export function resolvePlatform() {
  if (typeof location !== 'undefined') {
    const q = new URLSearchParams(location.search).get('platform');
    if (q === 'ios' || q === 'android' || q === 'desktop') return q;
  }
  return detectPlatform();
}
