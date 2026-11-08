#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run as root inside the disposable Fedora 45 CI container.
set -euo pipefail
export LC_ALL=C
shopt -s nullglob

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./sources.lock
output=/ci-output
mock_options=(--no-bootstrap-chroot --isolation=simple -r fedora-45-x86_64)

require_offline() {
    cat /proc/net/dev
    if [[ $(awk 'NR > 2 { print $1 }' /proc/net/dev) != lo: ]]; then
        echo "Run this check in a network namespace with only loopback." >&2
        exit 1
    fi
}

read_targets() {
    mapfile -t kernels < "$output/kernels.txt"
    test "${#kernels[@]}" -eq 2
    test "${kernels[0]}" != "${kernels[1]}"
    local kernel
    for kernel in "${kernels[@]}"; do
        [[ $kernel =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+(\.[0-9]+)*\.fc45\.x86_64$ ]]
    done
}

stage() {
    test "$(rpm -E '%fedora')" = 45
    test "$(uname -m)" = x86_64
    dnf -y --setopt=install_weak_deps=False install \
        akmods curl gnupg2 kmod kmodtool mock rpm-build xz \
        gcc make elfutils-libelf-devel
    mkdir -p "$output"
    scripts/select-test-kernels.sh "${1:---stable}" > "$output/kernels.txt"
    read_targets
    printf 'Test kernel: %s\n' "${kernels[@]}"
    scripts/prepare-sources.sh "$output/sources" /var/tmp/macbook12-source-cache
    sha256sum "$output/sources/macbook12-audio.tar.xz" > "$output/source.sha256"

    # Stage both Fedora-signed targets; never change the source lock/spec.
    local kernel_rpms=/var/tmp/macbook12-kernel-rpms
    local keyring="$kernel_rpms/fedora45-keyring"
    mkdir -p "$keyring"
    rpmkeys --dbpath "$keyring" --import /usr/share/distribution-gpg-keys/fedora/RPM-GPG-KEY-fedora-45-primary
    local kernel version release koji package path
    local rpms=() devel=()
    for kernel in "${kernels[@]}"; do
        version=${kernel%%-*}
        release=${kernel#*-}
        release=${release%.x86_64}
        koji="https://kojipkgs.fedoraproject.org/packages/kernel/$version/$release/data/signed/f577861e/x86_64"
        for package in kernel-core kernel-modules-core kernel-modules kernel-devel kernel-devel-matched; do
            path="$kernel_rpms/$package-$kernel.rpm"
            if [[ ! -f $path ]]; then
                curl --fail --location --retry 3 --silent --show-error \
                    --proto '=https' --proto-redir '=https' \
                    "$koji/$package-$kernel.rpm" -o "$path.part"
                mv -- "$path.part" "$path"
            fi
            rpmkeys --dbpath "$keyring" --define '_pkgverify_level all' --checksig "$path"
            test "$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$path")" = "$package-$kernel"
            rpms+=("$path")
        done
        devel+=("$kernel_rpms/kernel-devel-$kernel.rpm")
    done
    # Populate both stock trees without boot-related scriptlets.
    rpm -i --replacepkgs --noscripts --notriggers "${rpms[@]}"
    for kernel in "${kernels[@]}"; do
        depmod -a "$kernel"
    done
    mock "${mock_options[@]}" --init
    mock "${mock_options[@]}" --install "${devel[@]}" \
        kmodtool kmod gcc make elfutils-libelf-devel
}

verify_mock() {
    require_offline
    read_targets
    sha256sum --check "$output/source.sha256"
    local opts=("${mock_options[@]}" --offline --no-clean --no-cleanup-after)
    mock "${opts[@]}" --buildsrpm --spec packaging/macbook12-audio-kmod.spec \
        --sources "$output/sources" --resultdir "$output/srpm"
    local srpm=("$output/srpm/"*.src.rpm)
    test "${#srpm[@]}" -eq 1
    # Build one reusable akmod, then compile the same SRPM for both kernels.
    mock "${opts[@]}" --rebuild "${srpm[0]}" --resultdir "$output/mock-rpms"
    mock "${opts[@]}" --define "kernels ${kernels[*]}" \
        --rebuild "${srpm[0]}" --resultdir "$output/mock-kmods"

    # Catch shared-output bugs: each RPM must contain its own kernel's module.
    local kernel work module vermagic
    for kernel in "${kernels[@]}"; do
        local rpms=("$output/mock-kmods/kmod-macbook12-audio-$kernel-"*.x86_64.rpm)
        test "${#rpms[@]}" -eq 1
        work=$(mktemp -d)
        (cd "$work"; rpm2cpio "${rpms[0]}" | cpio -idm --quiet)
        local modules=("$work"/{lib,usr/lib}/modules/"$kernel"/extra/macbook12-audio/snd-hda-codec-cs420x.ko*)
        test "${#modules[@]}" -eq 1
        module=${modules[0]}
        vermagic=$(modinfo -F vermagic "$module")
        [[ ${vermagic%% *} == "$kernel" ]]
        printf 'Offline mock verified %s: %s\n' "$kernel" "$vermagic"
        rm -rf -- "$work"
    done
    sha256sum --check "$output/source.sha256"
}

build_akmod() {
    local kernel=$1
    shift
    if ! akmods --force "$@" --kernels "$kernel" --akmod macbook12-audio ||
       ! rpm -q "kmod-macbook12-audio-$kernel"; then
        local log
        for log in /var/cache/akmods/macbook12-audio/*.log; do
            cat "$log"
        done
        exit 1
    fi
}

verify_akmods() {
    require_offline
    read_targets
    local kernel module vermagic signer
    local -A stocks digests
    for kernel in "${kernels[@]}"; do
        stocks[$kernel]=$(modinfo -k "$kernel" -F filename snd_hda_codec_cs420x)
        [[ ${stocks[$kernel]} == */kernel/* ]]
        digests[$kernel]=$(sha256sum "${stocks[$kernel]}")
    done
    local akmod=("$output/mock-rpms/"akmod-macbook12-audio-*.x86_64.rpm)
    local common=("$output/mock-rpms/"macbook12-audio-*.x86_64.rpm)
    test "${#akmod[@]}" -eq 1
    test "${#common[@]}" -eq 1
    kmodgenca -a
    dnf -y --nogpgcheck --disablerepo='*' install "${akmod[0]}" "${common[0]}"
    local embedded=/usr/src/akmods/macbook12-audio-kmod.latest
    sha256sum "$embedded" > "$output/embedded-srpm.sha256"
    for kernel in "${kernels[@]}"; do
        build_akmod "$kernel"
    done
    # Prove rollback kernels remain rebuildable with this same installed akmod.
    # --rebuild forces compilation and uses DNF reinstall, so keep it installed.
    build_akmod "${kernels[0]}" --rebuild
    sha256sum --check "$output/embedded-srpm.sha256"

    local kmods=()
    for kernel in "${kernels[@]}"; do
        module=$(modinfo -k "$kernel" -F filename snd_hda_codec_cs420x)
        vermagic=$(modinfo -F vermagic "$module")
        signer=$(modinfo -F signer "$module")
        printf 'Selected module %s\nVermagic %s\nSigner %s\n' "$module" "$vermagic" "$signer"
        [[ $module == */extra/macbook12-audio/snd-hda-codec-cs420x.ko* ]]
        [[ ${vermagic%% *} == "$kernel" && -n $signer ]]
        [[ $(sha256sum "${stocks[$kernel]}") == "${digests[$kernel]}" ]]
        local kmod="kmod-macbook12-audio-$kernel"
        kmods+=("$kmod")
        local built=(/var/cache/akmods/macbook12-audio/"$kmod"-*.x86_64.rpm)
        test "${#built[@]}" -eq 1
        install -D -m 0644 "${built[0]}" "$output/verification-kmod/${built[0]##*/}"
    done
    rpm -e "${kmods[@]}" akmod-macbook12-audio macbook12-audio
    for kernel in "${kernels[@]}"; do
        [[ $(modinfo -k "$kernel" -F filename snd_hda_codec_cs420x) == "${stocks[$kernel]}" ]]
        printf 'Rollback selected %s\n' "${stocks[$kernel]}"
    done
}

case "${1:-}" in
    stage) stage "${2:---stable}" ;;
    mock) verify_mock ;;
    akmods) verify_akmods ;;
    summary)
        read_targets
        srpms=("$output/srpm/"*.src.rpm)
        test "${#srpms[@]}" -eq 1
        printf '### Fedora 45 reusable akmod\n\n- Packaging commit: `%s`\n- Driver commit: `%s`\n- Private HDA headers: Linux `%s`\n- Tested SRPM: `%s`\n' \
            "$2" "$driver_commit" "$linux_version" "${srpms[0]##*/}"
        printf -- '- Offline mock and akmods passed: `%s`\n' "${kernels[@]}"
        printf -- '- Same installed akmod rebuilt the older kernel after the newer one.\n- Removal restored both stock modules; hardware and Secure Boot loading are not tested.\n'
        ;;
    *) echo "Usage: $0 {stage [--stable|--testing]|mock|akmods|summary COMMIT}" >&2; exit 2 ;;
esac
