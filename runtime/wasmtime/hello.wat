;; runtime/wasmtime/hello.wat
;;
;; The hand-crafted byte-level golden for the q64 hello-world program:
;;
;;     fn main {
;;         env.out("Hello, q64.")
;;     }
;;
;; This is the shape `q64 build` will eventually emit from that source
;; once codegen lands. Until then, the host (src/main.zig) runs *this*
;; module and serves as the regression target downstream codegen will
;; aim at.
;;
;; ABI (v0):
;;   - env.out :: (ptr: i64, len: i64) -> ()
;;       Writes `len` bytes from linear memory starting at `ptr` to
;;       the host's stdout, verbatim. UTF-8 is the producer contract.
;;       Pointers are i64: q64 targets Wasm Memory64 (spec/memory.md).
;;   - The module exports a single 64-bit linear memory named `memory`
;;     and a start function named `_start`.
;;
;; Per spec/env.md §"Capability faces", `env.out("…")` is sugar for
;; writing the string followed by a newline. So the data segment
;; holds `Hello, q64.\n` (12 bytes); the toolchain owns the newline.

(module
  (import "env" "out" (func $env_out (param i64 i64)))

  (memory (export "memory") i64 1)
  (data (i64.const 0) "Hello, q64.\n")

  (func (export "_start")
    i64.const 0       ;; ptr — offset of the string in linear memory
    i64.const 12      ;; len — bytes of "Hello, q64.\n"
    call $env_out)
)
