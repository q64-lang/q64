# brand

Brand assets for q64.dev — logo marks, the brand sheet, the
color palette, and the mascot concept.

> **Source image needed:** drop the brand sheet here as
> `brand-sheet.png` (or `.webp`). The `tokens.json5` in this
> folder was derived from a visual read of the sheet and is the
> canonical machine-readable form going forward; whenever the
> sheet is updated, regenerate the tokens.

## Layout

```
brand/
  README.md             # this file
  tokens.json5          # machine-readable brand tokens (palette, type, voice)
  brand-sheet.png       # source artwork — full reference sheet  (TODO: add)
  marks/
    q-mark.svg          # the Q-tesseract mark (TODO)
    q64-wordmark.svg    # "Q64" wordmark (TODO)
    q64-lockup.svg      # Q mark + wordmark + tagline lockup (TODO)
  icons/
    compiler.svg        # purple hex glyph (TODO)
    runtime.svg         # ringed-planet glyph (TODO)
    packages.svg        # teal cube glyph (TODO)
    build.svg           # starburst glyph (TODO)
  mascot/
    omniscient.png      # full-body mascot illustration (TODO)
```

## Tagline

- **Primary**: COMPILE. RUN. EVERYWHERE.
- **Subline**: *A modern toolchain for WebAssembly and beyond.*

## Mascot — the Omniscient Observer

Hooded, glowing-Q-headed figure with hands outstretched, set
against a particle field. The brand sheet describes it as:

> An omniscient observer. Beyond time, beyond systems. Here to
> empower builders.

This is q64's nod to **Q** of *Star Trek: The Next Generation* —
the omnipotent entity from the Q Continuum (cf. the etymology
note that lived in the old design repo's README and now in
`docs/history/`). The mascot is not a literal Q character; it's
a stylized "observer beyond systems" who happens to share a
silhouette and a single-letter signifier.

## Usage notes (from the sheet)

- The Q-mark is a *tesseract / hexagonal projection* inscribed
  inside the Q's letterform. Don't recolor the mark away from
  white-on-dark or violet-on-dark.
- Lockups exist for three backgrounds: deep-space (default),
  white surface (light-mode docs), violet-tinted (announcement
  banners).
- App-icon variant uses a tight square crop with the Q glowing.

## CLI splash

The CLI splash example renders the wordmark in a chunky pixel
font next to the tagline. The runtime command for it (intended):

```
$ q64 --version
Q64 Compiler 0.1.0
Target: WebAssembly (wasm32)
Optimize. Ship. Run anywhere.
```

The splash is shown by `q64 --version` and the first run of
`q64 init`.
