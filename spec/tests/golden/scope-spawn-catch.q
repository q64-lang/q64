// TEST: golden — structured concurrency with scope + spawn + catch
// SPEC: concurrency.md#panics-across-tasks
// EXPECTED: ok

fn primary_db(env: Env) { env.out("db up") }
fn primary_cache(env: Env) { env.out("cache up") }
fn fallback_db(env: Env) { env.out("fallback db up") }
fn fallback_cache(env: Env) { env.out("fallback cache up") }

fn boot(env: Env) {
    scope {
        spawn { primary_db(env) }
        spawn { primary_cache(env) }
    } catch (e: Panic) {
        env.out("primary startup failed: {e.fmt()}")
        scope {
            spawn { fallback_db(env) }
            spawn { fallback_cache(env) }
        }
    }
}

fn main(env: Env) {
    boot(env)
}
