#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare or verify the Fedora 45 COPR packages against the tested SRPM."""

import subprocess
import sys
import time

import rpm

PACKAGES = ("akmod-macbook12-audio", "macbook12-audio")
COPR_REPO = "copr:copr.fedorainfracloud.org:ludohirst:macbook12-audio-akmod"


def enable_copr():
    subprocess.run(
        ["dnf", "-y", "copr", "enable", "ludohirst/macbook12-audio-akmod", "fedora-45-x86_64"],
        check=True,
        stdout=sys.stderr,
    )


def evr(text):
    fields = text.split()
    if len(fields) != 3:
        raise SystemExit(f"Expected one RPM epoch, version and release, got {text!r}")
    epoch, version, release = fields
    return ("0" if epoch == "(none)" else epoch, version, release)


def published_evr(package):
    result = subprocess.check_output(
        [
            "dnf", "-q", "--refresh", f"--repo={COPR_REPO}",
            "repoquery", "--available", "--arch=x86_64", "--latest-limit=1",
            "--qf", "%{epoch} %{version} %{release}", package,
        ],
        text=True,
        timeout=45,
    )
    return evr(result) if result.strip() else None


def verify(candidate):
    for attempt in range(1, 9):
        try:
            versions = {package: published_evr(package) for package in PACKAGES}
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            print(f"DNF query failed (attempt {attempt}): {error}", file=sys.stderr)
        else:
            if all(version == candidate for version in versions.values()):
                for package in PACKAGES:
                    print(f"DNF offers `{package}-{candidate[1]}-{candidate[2]}.x86_64` from COPR.")
                return
            print(f"Waiting for COPR metadata (attempt {attempt}): {versions}", file=sys.stderr)
        if attempt < 8:
            time.sleep(15)
    raise SystemExit(f"DNF did not find both COPR RPMs at {candidate[1]}-{candidate[2]}.")


def smoke_install(candidate):
    enable_copr()
    verify(candidate)
    epoch, version, release = candidate
    nevras = [f"{name}-{epoch}:{version}-{release}.x86_64" for name in PACKAGES]
    subprocess.run(
        [
            "dnf", "-y", "--refresh",
            f"--setopt={COPR_REPO}.pkg_gpgcheck=1",
            f"--setopt={COPR_REPO}.includepkgs={','.join(PACKAGES)}",
            "install", f"--from-repo={COPR_REPO}", *nevras,
        ],
        check=True,
        timeout=300,
        stdout=sys.stderr,
    )
    for name, nevra in zip(PACKAGES, nevras):
        installed = subprocess.check_output(
            ["rpm", "-q", "--qf", "%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}", name],
            text=True,
        )
        if installed != nevra:
            raise SystemExit(f"Expected {nevra}, installed {installed}.")
    print(f"Clean Fedora 45 DNF install passed for both COPR RPMs at `{version}-{release}` with signature checks enabled.")


candidate = evr(sys.argv[1])
if sys.argv[2:] == ["--verify"]:
    verify(candidate)
elif sys.argv[2:] == ["--smoke-install"]:
    smoke_install(candidate)
else:
    enable_copr()
    published = published_evr(PACKAGES[0])
    if published is None:
        raise SystemExit("DNF did not find an existing COPR akmod to compare against.")
    comparison = rpm.labelCompare(candidate, published)
    print(f"Candidate {candidate[1]}-{candidate[2]}, COPR {published[1]}-{published[2]}", file=sys.stderr)
    print("publish" if comparison > 0 else "verify" if comparison == 0 else "skip")
