;; Design-of-record for the `env.kv` → `wasi:keyvalue` component lowering.
;;
;; This is the EXACT core-module shape `q64 emit --component` must produce for a
;; qube that reaches `env.kv` — hand-written and proven end-to-end through
;; `wasm-tools` (`run.sh` here builds + validates the component). The q64 Binaryen
;; codegen targets this byte pattern; when it diverges, this file is the spec.
;;
;; A q64 source `pub fn bump() -> i64 { env.kv.increment("count", 1) ... }`
;; lowers to the body below. The canonical-ABI facts it pins:
;;   * Import module names use the wasm-tools `cm32p2|<iface-id>@<ver>` convention.
;;   * `store.open(id) -> result<bucket,error>` lowers to `(id_ptr,id_len,retptr)`;
;;     the result lands at retptr as {disc:u8 @0, bucket-handle:i32 @4}.
;;   * `atomics.increment(borrow<bucket>, key, s64) -> result<s64,error>` lowers to
;;     `(handle,key_ptr,key_len,delta:i64,retptr)`; result {disc:u8 @0, s64 @8}
;;     (8-byte align — the s64 ok-arm forces payload offset 8).
;;   * The bucket handle is adapter-held: the qube opens it lazily with an EMPTY
;;     identifier and the host pins it to the qube's identity (spec/env.md §env.kv).
;;   * `component new` requires `cm32p2_memory` + `cm32p2_realloc` +
;;     `cm32p2_initialize` exports; exports are named `cm32p2||<name>`.
(module
  ;; --- canonical-ABI imports (cm32p2 convention, wasm-tools 1.251) ---
  ;; store.open(identifier_ptr, identifier_len, retptr) -> writes result<bucket,error> @ retptr
  (import "cm32p2|wasi:keyvalue/store@0.2.0-draft2" "open"
    (func $open (param i32 i32 i32)))
  ;; atomics.increment(bucket, key_ptr, key_len, delta:i64, retptr) -> writes result<u64,error> @ retptr
  (import "cm32p2|wasi:keyvalue/atomics@0.2.0-draft2" "increment"
    (func $increment (param i32 i32 i32 i64 i32)))

  (memory (export "cm32p2_memory") 1)

  ;; the adapter-held bucket handle (lazily opened); -1 = unopened
  (global $bucket (mut i32) (i32.const -1))

  ;; "count" key bytes at offset 16
  (data (i32.const 16) "count")

  ;; minimal bump realloc the canonical ABI requires (unused for these calls,
  ;; but `component new` requires the export to exist).
  (global $heap (mut i32) (i32.const 2048))
  (func (export "cm32p2_realloc") (param i32 i32 i32 i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $heap))
    (global.set $heap (i32.add (local.get $p) (local.get 3)))
    (local.get $p))

  (func (export "cm32p2_initialize"))

  (func (export "cm32p2||bump") (result i64)
    ;; lazy open: store.open("", retptr=1024) -> result<bucket,error> {disc@0, handle@4}
    (if (i32.eq (global.get $bucket) (i32.const -1))
      (then
        (call $open (i32.const 0) (i32.const 0) (i32.const 1024))
        (if (i32.ne (i32.load8_u (i32.const 1024)) (i32.const 0))
          (then (return (i64.const 0))))           ;; open errored
        (global.set $bucket (i32.load (i32.const 1028)))))
    ;; increment(bucket, "count", delta=1, retptr=1040) -> result<u64,error> {disc@0, u64@8}
    (call $increment
      (global.get $bucket) (i32.const 16) (i32.const 5)
      (i64.const 1) (i32.const 1040))
    (if (i32.ne (i32.load8_u (i32.const 1040)) (i32.const 0))
      (then (return (i64.const 0))))               ;; increment errored
    (i64.load (i32.const 1048)))
)
