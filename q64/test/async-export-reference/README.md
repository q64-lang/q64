# async-export-reference — the rung-3 protocol, pinned

Hand-authored cores proving the **Component Model async ABI** (the
`[async-lift]` export + callback re-entry + `task.return`) under
`wasmtime -W component-model-async -S p3`, before codegen learns to emit
it. Same pattern as `kv-component-reference`: the reference pins the
bytes; the compiler then has a known-good target.

Run: `./verify.sh` (needs the vendored `wasm-tools` + `wasmtime` CLI).

## Findings (empirically verified against wasmtime 45 / wasm-tools 1.251)

- **Manglings are name-driven, LEGACY scheme only.** The standard `cm32p2`
  mangling "does not yet support async-related features" (wasm-tools'
  own words), so the async pieces use the legacy names:
  `[async-lift]nap` + `[callback][async-lift]nap` exports,
  `[async-lower]wait-for` import, `[task-return]nap` on `[export]$root`,
  and the built-ins (`[waitable-set-new]`, `[waitable-join]`,
  `[subtask-drop]`, …) on `$root`. Codegen consequence: an async-lifted
  qube's core must be emitted with legacy manglings (or the whole module
  switched to them) until wasm-tools grows async in the standard scheme.
- **Constants** (all confirmed by a live run, not just the spec):
  - async-lowered call result: `(subtask_handle << 4) | state`, where
    state `RETURNED = 2` means completed eagerly (no subtask);
    anything else parks.
  - callback codes returned by lift/callback: `EXIT = 0`, `YIELD = 1`,
    `WAIT = 2 | (waitable_set << 4)`.
  - the callback receives `(event, waitable, payload)` i32s.
- **wasmtime's p3 WASI is rc-versioned.** The interfaces are
  `wasi:clocks@0.3.0-rc-2026-03-15` (not `@0.3.0`), and 0.3
  monotonic-clock renames `instant` → `mark` and `resolution` →
  `get-resolution`. Importing `@0.3.0` fails instantiation with a
  misleading "wrong type" error — pin the rc string (`wit/deps/clocks`
  here is wasmtime 45's own file, verbatim).
- **`--invoke` drives async exports fine**: the CLI runs its event loop
  until `task.return` delivers.

## The codegen mapping (rung-3 design)

The scheduler state machine (`buildScopeScheduled`) is already shaped
like the callback protocol — the mapping is:

| Scheduler (today) | Async export (rung 3) |
|---|---|
| the `while` round loop | run rounds inside `[async-lift]` / the callback |
| all tasks at terminal | `task.return(result)`; return `EXIT` |
| idle path: block-sleep until earliest deadline | start `wait-for(earliest - now)` as a subtask, join to the waitable-set, return `WAIT(set)` |
| (re-entry) | the callback runs rounds again, same decision tail |

The one real compiler change this needs: the scheduler's state (`pc`,
deadlines, task locals) lives in FUNCTION LOCALS today, which die
between the lift call and the callback — rung-3 codegen must spill them
to globals or a memory frame so `main` becomes re-entrant. That, plus
emitting the legacy-mangled async imports/exports, is the remaining
work; the protocol itself is proven here.
