// TEST: golden — structured concurrency with scope + spawn + catch
// SPEC: concurrency.md#panics-across-tasks
// EXPECTED: ok

fn primary_db { env.out("db up") }
fn primary_cache { env.out("cache up") }
fn fallback_db { env.out("fallback db up") }
fn fallback_cache { env.out("fallback cache up") }

fn boot {
    scope {
        spawn { primary_db() }
        spawn { primary_cache() }
    } catch (e: Panic) {
        env.out("primary startup failed: {e.fmt()}")
        scope {
            spawn { fallback_db() }
            spawn { fallback_cache() }
        }
    }
}

fn main {
    boot()
}
