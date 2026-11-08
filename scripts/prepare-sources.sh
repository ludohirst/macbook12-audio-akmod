#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
export LC_ALL=C
umask 022

if (( $# > 2 )); then
    echo "Usage: $0 [output-directory] [download-cache]" >&2
    exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/sources.lock"
output_dir=${1:-"$repo_dir/dist"}
cache_dir=${2:-"$repo_dir/.cache/sources"}
mkdir -p -- "$output_dir" "$cache_dir"
work_dir=$(mktemp -d)
download_tmp=
output_tmp=
trap 'rm -rf -- "$work_dir"; rm -f -- "$download_tmp" "$output_tmp"' EXIT

verify() {
    local actual
    actual=$(sha256sum < "$1") || return
    [[ ${actual%% *} == "$2" ]]
}

verify_kernel_signature() {
    local archive=$1
    local gpg_home="$work_dir/gnupg"
    mkdir -m 0700 -- "$gpg_home"
    curl --fail --location --retry 3 --silent --show-error \
        --proto '=https' --proto-redir '=https' \
        --output "$work_dir/linux.tar.sign" "${linux_url%.xz}.sign" || return
    local signer
    for signer in gregkh sashal torvalds; do
        gpg --homedir "$gpg_home" --batch --auto-key-locate clear,wkd \
            --locate-external-keys "$signer@kernel.org" >&2 ||
            printf 'Could not retrieve %s@kernel.org.\n' "$signer" >&2
    done
    # Match the primary key fingerprint, including when a signing subkey is used.
    # https://www.kernel.org/signature.html
    xz -dc -- "$archive" | gpg --homedir "$gpg_home" --batch --status-fd 1 \
        --verify "$work_dir/linux.tar.sign" - > "$work_dir/signature-status" || return
    if ! awk '$2 == "VALIDSIG" && ($NF == "ABAF11C65A2970B130ABE3C479BE3E4300411886" ||
                                   $NF == "647F28654894E3BD457199BE38DBBDC86092693E" ||
                                   $NF == "E27E5D8A3403A2EF6687DEBA6FF797772CDC") { trusted = 1 }
             END { exit !trusted }' "$work_dir/signature-status"; then
        echo "Kernel archive was not signed by an approved Linux release key." >&2
        return 1
    fi
}

verify_archive() {
    local archive=$1 checksum=$2
    if [[ -n $checksum ]]; then
        verify "$archive" "$checksum"
    else
        verify_kernel_signature "$archive"
    fi
}

fetch() {
    local url=$1 destination=$2 checksum=$3
    if [[ ! -f $destination ]]; then
        download_tmp=$(mktemp -- "$cache_dir/.download.XXXXXXXX")
        curl --fail --location --retry 3 --silent --show-error \
            --proto '=https' --proto-redir '=https' --output "$download_tmp" "$url"
        if ! verify_archive "$download_tmp" "$checksum"; then
            echo "Source verification failed for $url" >&2
            exit 1
        fi
        mv -T -- "$download_tmp" "$destination"
        download_tmp=
    elif ! verify_archive "$destination" "$checksum"; then
        echo "Source verification failed for $destination. Remove the invalid cache file and rerun." >&2
        exit 1
    fi
}

driver_archive="$cache_dir/driver-$driver_commit.tar.gz"
linux_archive="$cache_dir/linux-$linux_version.tar.xz"
[[ $driver_sha256 =~ ^[0-9a-f]{64}$ ]]
fetch "$driver_url" "$driver_archive" "$driver_sha256"
fetch "$linux_url" "$linux_archive" "$linux_sha256"
linux_digest=$(sha256sum < "$linux_archive")

bundle_name=macbook12-audio
bundle="$work_dir/$bundle_name"
codec_dir="$bundle/sound/hda/codecs/cirrus"
mkdir -p -- "$codec_dir" "$work_dir/driver"

linux_prefix="linux-$linux_version"
tar -xJf "$linux_archive" -C "$bundle" --strip-components=1 \
    "$linux_prefix/sound/hda/common/hda_auto_parser.h" \
    "$linux_prefix/sound/hda/common/hda_jack.h" \
    "$linux_prefix/sound/hda/common/hda_local.h" \
    "$linux_prefix/sound/hda/codecs/generic.h" \
    "$linux_prefix/LICENSES/preferred/GPL-2.0"

driver_prefix="macbook12-audio-driver-$driver_commit/patch_cirrus"
tar -xzf "$driver_archive" -C "$work_dir/driver" --strip-components=2 \
    "$driver_prefix/cs420x.c" \
    "$driver_prefix/patch_cirrus_a1534_setup.h" \
    "$driver_prefix/patch_cirrus_a1534_pcm.h" \
    "$driver_prefix/Makefile_cs420x"

cp -- "$work_dir/driver/"*.c "$work_dir/driver/"*.h "$codec_dir/"
cp -- "$work_dir/driver/Makefile_cs420x" "$codec_dir/Kbuild"

# Mirror upstream preparation for the modern HDA codec remove callback.
pcm_header="$codec_dir/patch_cirrus_a1534_pcm.h"
grep -q '\.free = cs_4208_free_explicit,' "$pcm_header"
sed -i 's/\.free = cs_4208_free_explicit,/\.remove = cs_4208_free_explicit,/' "$pcm_header"

install -m 0644 -- "$repo_dir/sources.lock" "$repo_dir/README.txt" "$repo_dir/LICENSE" "$bundle/"
sed -i "s/^linux_sha256=.*/linux_sha256=${linux_digest%% *}/" "$bundle/sources.lock"
install -m 0755 -- "$repo_dir/scripts/build-offline.sh" "$bundle/build-offline.sh"

output_tmp=$(mktemp -- "$output_dir/.$bundle_name.XXXXXXXX")
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --mode='u+rw,go+r,go-w,a+X' -cJf "$output_tmp" -C "$work_dir" "$bundle_name"
chmod 0644 -- "$output_tmp"
archive="$output_dir/$bundle_name.tar.xz"
mv -T -- "$output_tmp" "$archive"
output_tmp=
printf '%s\n' "$archive"
