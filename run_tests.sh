#!/usr/bin/env bash
# Runs every test file and example. Extra args go to `mojo run`, e.g.
#   ./run_tests.sh -D ASSERT=all
# Then checks that each file in test/compile_fail/ fails to compile with the
# message in its `# EXPECT:` line.
set -euo pipefail
cd "$(dirname "$0")"
status=0
for f in test/test_*.mojo examples/*.mojo; do
    echo "== $f"
    if ! mojo run "$@" -I . -I test "$f"; then
        status=1
    fi
done

echo "== test/compile_fail"
for f in test/compile_fail/*.mojo; do
    expect=$(sed -n 's/^# EXPECT: //p' "$f")
    if out=$(mojo build -I . "$f" -o /dev/null 2>&1); then
        echo "    FAIL $f: compiled, but should not"
        status=1
    elif ! grep -qF -- "$expect" <<<"$out"; then
        echo "    FAIL $f: expected error not found: $expect"
        echo "$out" | grep error | head -3
        status=1
    else
        echo "    PASS $f"
    fi
done
exit $status
