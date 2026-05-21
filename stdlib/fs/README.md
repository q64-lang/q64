# stdlib/fs → `q64.fs`

Filesystem access via the `env.fs` capability.

> **Status: not yet implemented.**

## Surface (planned)

- **`Path`** — a distinct kind, normalized at construction.
- **Read / write** — `env.fs.read(path)`, `env.fs.write(path, bytes)`,
  returning `Result<T, IoError>`.
- **Streaming** — `env.fs.open(path).stream()` returning `Stream<Bytes>` for
  large files, with backpressure.
- **Directory operations** — `list`, `mkdir`, `remove`, `rename`.
- **Metadata** — size, mtime, permissions (where the host supports them).
- **Watch** — `Event<FsChange>` for filesystem watching where the host
  supports it (inotify, kqueue, ReadDirectoryChangesW, OPFS observers).

Host backing varies: WASI on Wasmtime / Wasmer; OPFS in the browser; the
real filesystem in native CLI tools. The user-facing surface is identical
across hosts.

All operations carry `@io` effects. `@realtime` stages cannot call them.
