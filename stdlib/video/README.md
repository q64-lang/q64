# stdlib/video → `q64.video`

Video frame types and codec interfaces.

> **Status: not yet implemented.**

## Surface (planned)

- **Frame types** — `Frame[Pixel, Subsampling, W, H]` with resolution,
  color standard, transfer function, and chroma subsampling all in the type.
  Concrete aliases: `Hd1080p10`, `Uhd4kHdr`, `MasterF16`.
- **Video standards** — `BT601`, `BT709`, `BT2020`, `BT2020Pq` (HDR10),
  `BT2020Hlg`.
- **YCbCr / RGB conversion** — explicit, named, color-space-aware.
- **Codecs** — H.264, H.265, AV1 encode/decode via the runtime adapter
  (WebCodecs in browser, FFmpeg or hardware encoders native).
- **Tonemapping** — HDR → SDR, with the result reflected in the type.

Resolution, color standard, and subsampling live in the type, so a pipeline
mixing BT.709 SDR with BT.2020 HDR fails to compile.
