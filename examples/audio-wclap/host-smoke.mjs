// Loads the q64 WCLAP plugin in the plinken.org reference browser host —
// the phase-D exit criterion (docs/audio-roadmap.md): "loads in the
// reference browser host, and processes audio".
//
// Unlike check.mjs (our own minimal host), this drives the REAL host —
// the wclap-host app from the public plinken-org repo, running the
// WebCLAP `wclap-host-js` runtime inside an AudioWorklet — through its
// UI, exactly as a user would: add the bundle URL to the shelf, click
// the chip to load it into a rack slot, press play, and watch the RMS
// meters move. Requires a running wclap-host dev server (see README) and
// Playwright with Chromium.
//
//   node host-smoke.mjs [host-url] [bundle-url] [--expect-silent]
//   node host-smoke.mjs http://localhost:5199/ /samples/q64-voice.wclap.tar.gz
//
// --expect-silent: for note-driven instruments (examples/audio-poly),
// which render silence until a note event arrives — headless Chromium
// has no Web MIDI source, so the check stops at loaded-with-no-errors
// and the audible half stays with the plugin's own check.mjs.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  console.error("host-smoke: playwright not found — `npm i -D playwright` or set NODE_PATH to a global install");
  process.exit(2);
}

const args = process.argv.slice(2).filter((a) => a !== "--expect-silent");
const expectSilent = process.argv.includes("--expect-silent");
const hostUrl = args[0] ?? "http://localhost:5199/";
// Must be absolute — the host's add-by-URL flow parses it with `new URL`
// and routes the fetch through its same-origin /r2-proxy.
const bundleUrl = args[1] ?? new URL("/samples/q64-voice.wclap.tar.gz", hostUrl).href;
// The shelf chip is labeled from the URL's filename, sans extension.
const chipLabel = (new URL(bundleUrl).pathname.split("/").pop() ?? "").replace(/\.(wclap\.tar\.gz|wasm)$/i, "");

const browser = await chromium.launch({
  headless: true,
  // The host resumes its AudioContext on the shelf-click gesture; headless
  // has no real gesture, so lift the autoplay gate.
  args: ["--autoplay-policy=no-user-gesture-required"],
});
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(`console.error: ${m.text()}`);
});

try {
  await page.goto(hostUrl, { waitUntil: "load" });

  // Add the bundle to the shelf by URL, then click its chip to load it.
  await page.fill("#shelfUrlInput", bundleUrl);
  await page.click("#shelfUrlAdd");
  const chip = page.locator(".shelfChip", { hasText: chipLabel });
  await chip.waitFor({ timeout: 10_000 });
  await chip.click();
  await page.waitForFunction(
    () => document.getElementById("statusLabel")?.textContent?.includes("loaded in slot"),
    undefined,
    { timeout: 20_000 },
  );
  const status = await page.textContent("#statusLabel");
  console.log(`ok: ${status?.trim()}`);

  // The shelf-click load already resumes the AudioContext (the host
  // treats the click as the autoplay gesture), which disables Start while
  // audio runs — so only press it if it's still enabled. Then require the
  // RMS meter to move — a plugin that loads but renders silence never
  // lights it.
  if (await page.locator("#playBtn").isEnabled()) await page.click("#playBtn");
  if (expectSilent) {
    await page.waitForTimeout(3000); // let any load/activate error surface
    console.log("ok: loaded and running (note-driven instrument — silent without MIDI, as expected)");
  } else {
    await page.waitForFunction(
      () => {
        const w = document.getElementById("meterL")?.style.width ?? "0%";
        return parseFloat(w) > 1;
      },
      undefined,
      { timeout: 15_000 },
    );
    const meterL = await page.evaluate(() => document.getElementById("meterL").style.width);
    const meterR = await page.evaluate(() => document.getElementById("meterR").style.width);
    console.log(`ok: audio flowing — meters L=${meterL} R=${meterR}`);
  }

  const errBoxHidden = await page.evaluate(() => document.getElementById("errorBox")?.hidden ?? true);
  if (!errBoxHidden) {
    const err = await page.textContent("#errorBox");
    throw new Error(`host error box visible: ${err?.trim()}`);
  }
  const fatal = errors.filter((e) => !/favicon/.test(e));
  if (fatal.length) throw new Error(`page errors:\n  ${fatal.join("\n  ")}`);

  console.log("host-smoke: PASS — the q64 plugin loads and processes audio in the reference browser host");
} finally {
  await browser.close();
}
