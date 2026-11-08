#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run from a trusted checkout. Download the archive for hashing only.
set -euo pipefail

upstream=https://github.com/leifliddy/macbook12-audio-driver
archive_base=https://codeload.github.com/leifliddy/macbook12-audio-driver/tar.gz
spec=packaging/macbook12-audio-kmod.spec
current=$(sed -n 's/^driver_commit=//p' sources.lock)
[[ $current =~ ^[0-9a-f]{40}$ ]]

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git init -q --bare "$work/upstream"
git -C "$work/upstream" fetch --no-tags "$upstream" refs/heads/master
latest=$(git -C "$work/upstream" rev-parse FETCH_HEAD)
[[ $latest =~ ^[0-9a-f]{40}$ ]]
if [[ $current == "$latest" ]]; then
    echo "Driver already pins upstream master at $current."
    exit 0
fi

if ! git -C "$work/upstream" merge-base --is-ancestor "$current" "$latest"; then
    echo "::error::Upstream master no longer descends from the pinned commit. Review upstream history before changing the pin."
    exit 1
fi

url="$archive_base/$latest"
curl --fail --location --retry 3 --silent --show-error \
    --proto '=https' --proto-redir '=https' --output "$work/driver.tar.gz" "$url"
checksum=$(sha256sum < "$work/driver.tar.gz")

release=$(sed -nE 's/^Release:[[:blank:]]+([0-9]+)%\{\?dist\}$/\1/p' "$spec")
[[ $release =~ ^[1-9][0-9]*$ ]]
sed -i \
    -e "s/^driver_commit=.*/driver_commit=$latest/" \
    -e "s|^driver_url=.*|driver_url=$url|" \
    -e "s/^driver_sha256=.*/driver_sha256=${checksum%% *}/" sources.lock
sed -i -E "s/^(Release:[[:blank:]]+)$release(%\{\?dist\})$/\1$((release + 1))\2/" "$spec"
