%global kmodname macbook12-audio
%global bundle %{kmodname}
%global debug_package %{nil}
%global AkmodsBuildRequires elfutils-libelf-devel, gcc, kmod, make

%define check_driver_conflicts() %{expand:
if [ -d /var/lib/dkms/macbook12-audio-driver ]; then
    echo "Remove the macbook12-audio-driver DKMS installation before installing %{kmodname}." >&2
    exit 1
fi
for module in /usr/lib/modules/*/updates/snd-hda-codec-cs420x.ko*; do
    if [ -e "$module" ]; then
        echo "Remove the manually installed CS420x module at $module first." >&2
        exit 1
    fi
done
}

Name:           %{kmodname}-kmod
Version:        0.1
Release:        5%{?dist}
Summary:        Replacement CS420x kernel module for the 12-inch MacBook
License:        GPL-2.0-or-later
URL:            https://github.com/leifliddy/macbook12-audio-driver
Source0:        %{bundle}.tar.xz

ExclusiveArch:  x86_64
BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  kmod
BuildRequires:  kmodtool
BuildRequires:  make

# The normal build produces an akmod. akmodsbuild defines kernels when it
# rebuilds the embedded SRPM, which selects the per-kernel RPM template.
%{expand:%(kmodtool --target %{_target_cpu} --kmodname %{kmodname} --akmod %{?kernels:--for-kernels "%{kernels}"})}

%description
Build the replacement CS420x codec module for the 2016 and 2017 12-inch MacBook.

%if "%{?kernels}" == ""
%package -n %{kmodname}
Summary:        Module selection configuration for MacBook 12 audio
Provides:       %{kmodname}-kmod-common = %{version}-%{release}

%description -n %{kmodname}
Configure depmod to prefer the packaged CS420x module when available.
%endif

%prep
if [ "0%{?fedora}" -ne 45 ]; then
    echo "This source package targets Fedora 45 only." >&2
    exit 1
fi
%{?kmodtool_check}
%autosetup -n %{bundle}
%if "%{?kernels}" != ""
# Each target needs its own objects and final module, including in one build.
for kernel in %{kernel_versions}; do
    cp -a . "../build-${kernel%%___*}"
done
%endif

%build
%if "%{?kernels}" != ""
for kernel in %{kernel_versions}; do
    ./build-offline.sh "$PWD/../build-${kernel%%___*}" "${kernel##*___}"
done
%endif

%install
%if "%{?kernels}" == ""
install -d "%{buildroot}%{_prefix}/lib/depmod.d"
printf 'override snd-hda-codec-cs420x * extra/%s\n' '%{kmodname}' \
    > "%{buildroot}%{_prefix}/lib/depmod.d/%{kmodname}.conf"
%{akmod_install}
%else
for kernel in %{kernel_versions}; do
    install -D -m 0644 "../build-${kernel%%___*}/sound/hda/codecs/cirrus/snd-hda-codec-cs420x.ko" \
        "%{buildroot}%{kmodinstdir_prefix}${kernel%%___*}%{kmodinstdir_postfix}snd-hda-codec-cs420x.ko"
done
%endif

%if "%{?kernels}" == ""
# The akmod subpackage exists only when kmodtool templates are expanded.
%if %{defined akmod_install}
%pre -n akmod-%{kmodname}
%check_driver_conflicts
%endif

%pre -n %{kmodname}
%check_driver_conflicts

%files -n %{kmodname}
%license LICENSE
%doc README.txt sources.lock
%{_prefix}/lib/depmod.d/%{kmodname}.conf
%endif

%changelog
* Sun Nov 08 2026 MacBook 12 Audio Project - 0.1-5
- Package the plain-text README.

* Sun Nov 08 2026 MacBook 12 Audio Project - 0.1-4
- Reuse the prepared sources across compatible Fedora 45 x86_64 kernels.
- Isolate each kernel build and verify the same akmod against two kernels.

* Sun Nov 08 2026 MacBook 12 Audio Project - 0.1-3
- Verify automatic COPR submission after the Fedora 45 CI checks.

* Sun Nov 08 2026 MacBook 12 Audio Project - 0.1-2
- Build the source-carrying akmod in COPR and run the pinned compile check in CI.

* Sun Nov 08 2026 MacBook 12 Audio Project - 0.1-1
- Package the CS420x akmod for the pinned Fedora 45 kernel.
