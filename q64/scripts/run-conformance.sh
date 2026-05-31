#!/usr/bin/env bash
# Run every conformance test in ../../spec/tests/ against the q64 binary.
#
# For each `<stem>.q`:
#   - Run `q64 check <stem>.q --diagnostics json`, capturing stderr.
#   - Compare the emitted envelope's diagnostics to `<stem>.expected.json`.
#   - Match by `code` and `severity` only; message text is not compared
#     (per spec/tests/README.md §"Matching rules").
#
# Exit 0 iff every test passes.

set -u
set -o pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/spec/tests"
Q64_BIN="${Q64_BIN:-$REPO_ROOT/q64/zig-out/bin/q64}"

if [[ ! -x "$Q64_BIN" ]]; then
    echo "error: q64 binary not found at $Q64_BIN" >&2
    echo "       run 'cd q64 && zig build' first" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 2
fi

pass=0
fail=0
skip=0
failing_tests=()

# Sort the test list deterministically so output is stable across runs.
mapfile -t q_files < <(find "$TESTS_DIR" -name '*.q' | sort)

for q_file in "${q_files[@]}"; do
    rel="${q_file#$REPO_ROOT/}"
    expected="${q_file%.q}.expected.json"

    if [[ ! -f "$expected" ]]; then
        echo "SKIP $rel (no .expected.json)"
        skip=$((skip + 1))
        continue
    fi

    # Run q64 check, capturing stderr (the envelope). Exit code is not
    # asserted directly — the envelope's `ok` field is the source of
    # truth.
    actual="$("$Q64_BIN" check "$q_file" --diagnostics json 2>&1 1>/dev/null || true)"

    # Strip everything before the first `{` in case there's stray
    # output. The envelope is always a single line.
    actual_json="${actual##*$'\n'}"

    expected_ok="$(jq -r '.ok' < "$expected")"
    actual_ok="$(jq -r '.ok' <<<"$actual_json" 2>/dev/null || echo "PARSE_ERROR")"

    if [[ "$actual_ok" == "PARSE_ERROR" ]]; then
        echo "FAIL $rel — emitter produced invalid JSON"
        echo "     stderr: $actual"
        fail=$((fail + 1))
        failing_tests+=("$rel")
        continue
    fi

    if [[ "$expected_ok" != "$actual_ok" ]]; then
        echo "FAIL $rel — ok mismatch: expected $expected_ok, got $actual_ok"
        echo "     emitted: $actual_json"
        fail=$((fail + 1))
        failing_tests+=("$rel")
        continue
    fi

    # Compare diagnostic codes + severities as sorted sets.
    expected_codes="$(jq -c '[.diagnostics[] | {code, severity}] | sort' < "$expected")"
    actual_codes="$(jq -c '[.diagnostics[] | {code, severity}] | sort' <<<"$actual_json")"

    if [[ "$expected_codes" != "$actual_codes" ]]; then
        # Per spec/tests/README.md: implementations may emit *additional*
        # diagnostics unless the test pins `allow_extra: false`. The
        # expected set must be a subset of the actual set.
        allow_extra="$(jq -r '.allow_extra // true' < "$expected")"
        missing="$(jq -c --argjson exp "$expected_codes" --argjson got "$actual_codes" -n '$exp - $got')"

        if [[ "$missing" != "[]" ]]; then
            echo "FAIL $rel — missing expected diagnostics: $missing"
            echo "     emitted: $actual_codes"
            fail=$((fail + 1))
            failing_tests+=("$rel")
            continue
        fi

        if [[ "$allow_extra" == "false" ]]; then
            extra="$(jq -c --argjson exp "$expected_codes" --argjson got "$actual_codes" -n '$got - $exp')"
            echo "FAIL $rel — extra diagnostics (allow_extra=false): $extra"
            fail=$((fail + 1))
            failing_tests+=("$rel")
            continue
        fi
    fi

    pass=$((pass + 1))
done

echo
echo "Results: $pass passed, $fail failed, $skip skipped (of $((pass + fail + skip)) tests)"

if [[ $fail -gt 0 ]]; then
    echo
    echo "Failing tests:"
    for t in "${failing_tests[@]}"; do
        echo "  $t"
    done
    exit 1
fi
