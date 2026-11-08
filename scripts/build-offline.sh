#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 <extracted-source-directory> <kernel-devel-directory>" >&2
    exit 2
fi

source_dir=$(cd -- "$1" && pwd -P)
kernel_dir=$(cd -- "$2" && pwd -P)
actual_release=$(<"$kernel_dir/include/config/kernel.release")
if [[ ! $actual_release =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)*\.fc45\.x86_64$ ]] ||
   ! grep -qx 'CONFIG_X86_64=y' "$kernel_dir/.config"; then
    printf 'Expected a Fedora 45 x86_64 kernel-devel tree, got %s\n' "$actual_release" >&2
    exit 1
fi

if ! grep -qx 'CONFIG_SND_HDA_CODEC_CS420X=m' "$kernel_dir/.config"; then
    echo "The target kernel must build CS420x as a module." >&2
    exit 1
fi

codec_dir="$source_dir/sound/hda/codecs/cirrus"
module="$codec_dir/snd-hda-codec-cs420x.ko"
make -C "$kernel_dir" M="$codec_dir" modules

vermagic=$(modinfo -F vermagic "$module")
if [[ ${vermagic%% *} != "$actual_release" ]]; then
    echo "Unexpected module vermagic: $vermagic" >&2
    exit 1
fi

printf 'Built %s\n' "$module"
