#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Removing the version pin must not remove distro, architecture or config guards.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/source" "$work/devel/include/config"
printf 'CONFIG_X86_64=y\nCONFIG_SND_HDA_CODEC_CS420X=m\n' > "$work/devel/.config"
reject() {
    if "$repo/scripts/build-offline.sh" "$work/source" "$work/devel" > "$work/log" 2>&1; then
        echo 'Unsupported build target unexpectedly accepted.' >&2
        exit 1
    fi
    grep -Fq "$1" "$work/log"
}
for release in 7.2.15-300.fc44.x86_64 7.2.15-300.fc45.aarch64 \
    7.2.15-300.fc45.x86_64+debug invalid; do
    printf '%s\n' "$release" > "$work/devel/include/config/kernel.release"
    reject 'Expected a Fedora 45 x86_64 kernel-devel tree'
done
printf '7.2.15-300.fc45.x86_64\n' > "$work/devel/include/config/kernel.release"
printf 'CONFIG_SND_HDA_CODEC_CS420X=m\n' > "$work/devel/.config"
reject 'Expected a Fedora 45 x86_64 kernel-devel tree'
printf 'CONFIG_X86_64=y\nCONFIG_SND_HDA_CODEC_CS420X=y\n' > "$work/devel/.config"
reject 'The target kernel must build CS420x as a module.'
printf 'Build target regression checks passed.\n'
