#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Print two distinct test targets, oldest first. Never edit package inputs.
set -euo pipefail
export LC_ALL=C
mode=${1:---stable}
if (( $# > 1 )) || [[ $mode != --stable && $mode != --testing ]]; then
    echo "Usage: $0 [--stable|--testing]" >&2
    exit 2
fi

query() {
    dnf -q --refresh --releasever=45 --repo=fedora --repo=updates \
        repoquery "$@" --available --arch=x86_64 \
        --queryformat '%{version}-%{release}.%{arch}\n' kernel-devel
}

validate() {
    local kernel
    for kernel in "$@"; do
        if [[ ! $kernel =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)*\.fc45\.x86_64$ ]]; then
            printf 'Invalid Fedora 45 kernel-devel result: %s\n' "$kernel" >&2
            exit 1
        fi
    done
}

# CI also records the repository of each target, including the stable target
# already known if the updates-testing query fails.
record_targets() {
    if [[ -n ${KERNEL_CHANNELS_FILE:-} ]]; then
        printf '%s\t%s\n' "$@" > "$KERNEL_CHANNELS_FILE"
    fi
}

# Capture query status before mapfile: process substitutions can hide failures.
available=$(query --latest-limit=2)
mapfile -t stable < <(printf '%s\n' "$available" | sort -Vu)
validate "${stable[@]}"
if (( ${#stable[@]} != 2 )); then
    if (( ${#stable[@]} == 1 )); then
        record_targets "${stable[0]}" stable
    fi
    echo 'Expected two distinct stable kernels; refusing a one-kernel check.' >&2
    exit 1
fi

if [[ $mode == --testing ]]; then
    record_targets "${stable[1]}" stable
    testing=$(query --repo=updates-testing --latest-limit=1)
    validate "$testing"
    if [[ $testing != "${stable[1]}" ]]; then
        record_targets "${stable[1]}" stable "$testing" updates-testing
        printf '%s\n' "${stable[1]}" "$testing"
        exit 0
    fi
    echo 'No newer updates-testing kernel; checking both stable kernels.' >&2
fi
record_targets "${stable[0]}" stable "${stable[1]}" stable
printf '%s\n' "${stable[@]}"
