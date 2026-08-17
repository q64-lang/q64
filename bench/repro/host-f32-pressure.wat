;; Finding-1 repro (see bench/README.md): the q64-emitted 16-chain f32
;; multiply loop, verbatim, wrapped in a minimal WASI _start. Identical
;; bytes run in ~8 ms under a ReleaseFast-built q64-wasmtime-host (or the
;; wasmtime CLI, at any setting) and ~267 ms under a Debug-built host —
;; same source, same libwasmtime.so. The cliff appears once more than 16
;; f32 locals are live.
;;
;;   wat2wasm bench/repro/host-f32-pressure.wat -o /tmp/shape.wasm
;;   (cd runtime/wasmtime && zig build)                        # Debug
;;   time runtime/wasmtime/zig-out/bin/q64-wasmtime-host /tmp/shape.wasm
;;   (cd runtime/wasmtime && zig build -Doptimize=ReleaseFast)
;;   time runtime/wasmtime/zig-out/bin/q64-wasmtime-host /tmp/shape.wasm
(module
  (type (;0;) (func (param i64) (result f64)))
  (func $pass (type 0) (param i64) (result f64)
    (local f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 i64)
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 1
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 2
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 3
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 4
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 5
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 6
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 7
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 8
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 9
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 10
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 11
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 12
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 13
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 14
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 15
    f64.const 0x1p+0 (;=1;)
    f32.demote_f64
    local.set 16
    f64.const 0x1.ffffef39085f5p-1 (;=1;)
    f32.demote_f64
    local.set 17
    i64.const 0
    local.set 18
    block  ;; label = @1
      loop  ;; label = @2
        local.get 18
        local.get 0
        i64.lt_s
        i32.eqz
        br_if 1 (;@1;)
        local.get 1
        local.get 17
        f32.mul
        local.set 1
        local.get 2
        local.get 17
        f32.mul
        local.set 2
        local.get 3
        local.get 17
        f32.mul
        local.set 3
        local.get 4
        local.get 17
        f32.mul
        local.set 4
        local.get 5
        local.get 17
        f32.mul
        local.set 5
        local.get 6
        local.get 17
        f32.mul
        local.set 6
        local.get 7
        local.get 17
        f32.mul
        local.set 7
        local.get 8
        local.get 17
        f32.mul
        local.set 8
        local.get 9
        local.get 17
        f32.mul
        local.set 9
        local.get 10
        local.get 17
        f32.mul
        local.set 10
        local.get 11
        local.get 17
        f32.mul
        local.set 11
        local.get 12
        local.get 17
        f32.mul
        local.set 12
        local.get 13
        local.get 17
        f32.mul
        local.set 13
        local.get 14
        local.get 17
        f32.mul
        local.set 14
        local.get 15
        local.get 17
        f32.mul
        local.set 15
        local.get 16
        local.get 17
        f32.mul
        local.set 16
        local.get 18
        i64.const 1
        i64.add
        local.set 18
        br 0 (;@2;)
      end
      unreachable
    end
    local.get 1
    f64.promote_f32
    local.get 2
    f64.promote_f32
    f64.add
    local.get 3
    f64.promote_f32
    f64.add
    local.get 4
    f64.promote_f32
    f64.add)
  (func (export "_start")
    (drop (call $pass (i64.const 1000000)))
  )
)
