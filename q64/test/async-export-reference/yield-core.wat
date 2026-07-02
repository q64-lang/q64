(module
  ;; v1 of the async-export reference: no host imports at all. The initial
  ;; call YIELDs (proving the host re-enters via the callback); the callback
  ;; delivers the result via task.return and EXITs.
  (import "[export]$root" "[task-return]nap" (func $task_return (param i64)))
  (global $arg (mut i64) (i64.const 0))
  (memory (export "memory") 1)
  (func (export "[async-lift]nap") (param i64) (result i32)
    (global.set $arg (local.get 0))
    ;; CallbackCode YIELD = 1 (host runs other work, then re-enters callback)
    (i32.const 1))
  (func (export "[callback][async-lift]nap") (param i32 i32 i32) (result i32)
    ;; re-entered: deliver arg+1 and EXIT (CallbackCode EXIT = 0)
    (call $task_return (i64.add (global.get $arg) (i64.const 1)))
    (i32.const 0))
)
