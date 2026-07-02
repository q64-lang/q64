(module
  ;; v2: the real async wait. nap(ns) measures a wait-for(ns) bracketed by
  ;; clock reads, WITHOUT blocking the host: the initial call starts the
  ;; wait as a subtask, parks it in a waitable-set, returns WAIT; the
  ;; callback fires on subtask completion, task.returns the measured span.
  (import "wasi:clocks/monotonic-clock@0.3.0-rc-2026-03-15" "now" (func $now (result i64)))
  (import "wasi:clocks/monotonic-clock@0.3.0-rc-2026-03-15" "[async-lower]wait-for" (func $wait_for (param i64) (result i32)))
  (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
  (import "$root" "[waitable-join]" (func $join (param i32 i32)))
  (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
  (import "[export]$root" "[task-return]nap" (func $task_return (param i64)))
  (global $t0 (mut i64) (i64.const 0))
  (global $subtask (mut i32) (i32.const 0))
  (global $ws (mut i32) (i32.const 0))
  (memory (export "memory") 1)
  (func (export "[async-lift]nap") (param i64) (result i32)
    (local $st i32)
    (global.set $t0 (call $now))
    (local.set $st (call $wait_for (local.get 0)))
    ;; packed = (subtask << 4) | state; RETURNED (2) = completed eagerly
    (if (i32.eq (i32.and (local.get $st) (i32.const 0xf)) (i32.const 2))
      (then
        (call $task_return (i64.sub (call $now) (global.get $t0)))
        (return (i32.const 0))))
    (global.set $subtask (i32.shr_u (local.get $st) (i32.const 4)))
    (global.set $ws (call $ws_new))
    (call $join (global.get $subtask) (global.get $ws))
    ;; CallbackCode WAIT (2) | waitable-set << 4
    (i32.or (i32.const 2) (i32.shl (global.get $ws) (i32.const 4))))
  (func (export "[callback][async-lift]nap") (param i32 i32 i32) (result i32)
    (call $subtask_drop (global.get $subtask))
    (call $task_return (i64.sub (call $now) (global.get $t0)))
    (i32.const 0))
)
