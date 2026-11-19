#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
older=7.2.11-300.fc45.x86_64
newer=7.2.15-300.fc45.x86_64
start='Executing(%build): /bin/sh -e /var/tmp/rpm-tmp.123'
failed='error: Bad exit status from /var/tmp/rpm-tmp.123 (%build)'
helper() {
    printf '+ ./build-offline.sh /builddir/build-%s /usr/src/kernels/%s\n' "$1" "$1"
}
check() {
    local expected=$1
    shift
    local result
    result=$(printf '%s\n' "$@" | awk -f scripts/mock-failure.awk)
    [[ $result == "$expected" ]] || {
        printf 'Expected "%s", got "%s"\n' "$expected" "$result" >&2
        return 1
    }
}
check "$older build" "$start" "$(helper "$older")" "$failed" 'Executing(rmbuild): /bin/sh -e /tmp/cleanup'
second=("$start" "$(helper "$older")" "Built /builddir/build-$older/module.ko" "$(helper "$newer")")
check "$newer module-verification" "${second[@]}" 'Unexpected module vermagic: wrong' "$failed"
check '' "${second[@]}"  # Truncated trace: no failing exit from the helper.
check '' "${second[@]}" "Built /builddir/build-$newer/module.ko" "$failed"
check '' "${second[@]}" 'Executing(%install): /bin/sh -e /var/tmp/rpm-tmp.456' "$failed"
printf 'Combined mock failure attribution checks passed.\n'
