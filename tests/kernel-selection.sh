#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Regression checks for discovery failures and an accidentally reduced matrix.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/dnf" <<'DNF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *' --repo=updates-testing '*) printf '%s\n' "$TEST_TESTING" ;;
    *) printf '%s\n' "$TEST_STABLE" ;;
esac
exit "${TEST_DNF_STATUS:-0}"
DNF
chmod +x "$work/dnf"
export PATH="$work:$PATH"
export TEST_STABLE=$'7.2.15-300.fc45.x86_64\n7.2.11-300.fc45.x86_64\n7.2.15-300.fc45.x86_64'
export TEST_TESTING=7.3.3-300.fc45.x86_64
selector="$repo/scripts/select-test-kernels.sh"
expected=$'7.2.11-300.fc45.x86_64\n7.2.15-300.fc45.x86_64'
test "$("$selector")" = "$expected"
test "$("$selector" --testing)" = $'7.2.15-300.fc45.x86_64\n7.3.3-300.fc45.x86_64'
TEST_TESTING=7.2.15-300.fc45.x86_64
test "$("$selector" --testing)" = "$expected"

reject() {
    if "$selector" "$@" > "$work/output" 2> "$work/error"; then
        echo 'Invalid kernel discovery unexpectedly succeeded.' >&2
        exit 1
    fi
    test ! -s "$work/output"
}
TEST_DNF_STATUS=1 reject
for TEST_STABLE in '' '7.2.15-300.fc45.x86_64' \
    $'7.2.15-300.fc45.x86_64\n7.2.15-300.fc45.x86_64' \
    $'7.2.11-300.fc44.x86_64\n7.2.15-300.fc45.x86_64' \
    $'7.2.11-300.fc45.aarch64\n7.2.15-300.fc45.x86_64'; do
    reject
done
TEST_STABLE=$expected
TEST_TESTING=$'7.3.3-300.fc45.x86_64\n7.3.4-300.fc45.x86_64'
reject --testing
reject --unknown
printf 'Kernel selection regression checks passed.\n'
