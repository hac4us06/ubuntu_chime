#!/bin/bash
set -xe
shopt -s extglob

BUILD_DIR=
OUT=
ONLY_CLONE=
ONLY_KERNEL=
MENUCONFIG=

while [ $# -gt 0 ]
do
    case "$1" in
    (-b) BUILD_DIR="$(realpath "$2")"; shift;;
    (-o) OUT="$2"; shift;;
    (-c) ONLY_CLONE="true";;
    (-k) ONLY_KERNEL="true";;
    (-m) MENUCONFIG="true";;
    (-*) echo "$0: Error: unknown option $1" 1>&2; exit 1;;
    (*) OUT="$2"; break;;
    esac
    shift
done

OUT="$(realpath "$OUT" 2>/dev/null || echo 'out')"
mkdir -p "$OUT"

if [ -z "$BUILD_DIR" ]; then
    TMP=$(mktemp -d)
    TMPDOWN=$(mktemp -d)
else
    TMP="$BUILD_DIR/tmp"
    # Clean up installation dir in case of local builds
    rm -rf "$TMP"
    mkdir -p "$TMP"
    TMPDOWN="$BUILD_DIR/downloads"
    mkdir -p "$TMPDOWN"
fi

HERE=$(pwd)
SCRIPT="$(dirname "$(realpath "$0")")"/build
if [ ! -d "$SCRIPT" ]; then
    SCRIPT="$(dirname "$SCRIPT")"
fi

mkdir -p "${TMP}/system" "${TMP}/partitions"

source "${HERE}/deviceinfo"
source "$SCRIPT/common_functions.sh"
source "$SCRIPT/setup_repositories.sh" "${TMPDOWN}"
if [ "$ONLY_CLONE" = "true" ]; then
    exit 0
fi

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    "$SCRIPT/build-ufdt-apply-overlay.sh" "${TMPDOWN}"
fi

if $deviceinfo_kernel_clang_compile; then
    if [ -n "$deviceinfo_kernel_llvm_compile" ] && $deviceinfo_kernel_llvm_compile; then
        # Restrict available binaries in PATH to make builds less susceptible to host differences
        ALLOWED_HOST_TOOLS="bash git perl sh sync tar"

        HOST_TOOLS=${TMPDOWN}/host_tools
        rm -rf ${HOST_TOOLS}
        mkdir -p ${HOST_TOOLS}
        for tool in ${ALLOWED_HOST_TOOLS}
        do
            ln -sf $(which $tool) ${HOST_TOOLS}
        done

        BUILD_TOOLS_BIN="${TMPDOWN}/build-tools/linux-x86/bin"
        BUILD_TOOLS_PATH="${TMPDOWN}/build-tools/path/linux-x86"

        EXTRA_TOYBOX_TOOLS="dd expr nproc tr"
        for tool in ${EXTRA_TOYBOX_TOOLS}
        do
            ln -sf ../../linux-x86/bin/toybox "${BUILD_TOOLS_PATH}/${tool}"
        done

        KERNEL_BUILD_TOOLS_BIN="${TMPDOWN}/kernel-build-tools/linux-x86/bin"

        PATH="$CLANG_PATH/bin:${BUILD_TOOLS_BIN}:${BUILD_TOOLS_PATH}:${KERNEL_BUILD_TOOLS_BIN}:${HOST_TOOLS}" \
            "$SCRIPT/build-kernel.sh" "${TMPDOWN}" "${TMP}/system" "${MENUCONFIG}"
    else
        CC=clang \
            PATH="$CLANG_PATH/bin:$GCC_PATH/bin:$GCC_ARM32_PATH/bin:${PATH}" \
            "$SCRIPT/build-kernel.sh" "${TMPDOWN}" "${TMP}/system" "${MENUCONFIG}"
    fi
else
    PATH="$GCC_PATH/bin:$GCC_ARM32_PATH/bin:${PATH}" \
        "$SCRIPT/build-kernel.sh" "${TMPDOWN}" "${TMP}/system" "${MENUCONFIG}"
fi

# If deviceinfo_skip_dtbo_partition is set to true, do not copy an image for dedicated dtbo partition.
# It does not affect recovery partition image build performed in make-bootimage.sh
if [ -z "$deviceinfo_skip_dtbo_partition" ] || ! $deviceinfo_skip_dtbo_partition; then
    if [ -n "$deviceinfo_prebuilt_dtbo" ]; then
        cp "$deviceinfo_prebuilt_dtbo" "${TMP}/partitions/dtbo.img"
    elif [ -n "$deviceinfo_dtbo" ]; then
        "$SCRIPT/make-dtboimage.sh" "${TMPDOWN}" "${TMPDOWN}/KERNEL_OBJ" "${TMP}/partitions/dtbo.img"
    fi
fi

"$SCRIPT/make-bootimage.sh" "${TMPDOWN}" "${TMPDOWN}/KERNEL_OBJ" "${TMPDOWN}/halium-boot-ramdisk.img" \
    "${TMP}/partitions/boot.img" "${TMP}/system"
if [ "$ONLY_KERNEL" = "true" ]; then
    exit 0
fi

cp -av overlay/* "${TMP}/"

INITRC_PATHS="
${TMP}/system/opt/halium-overlay/system/etc/init
${TMP}/system/usr/share/halium-overlay/system/etc/init
${TMP}/system/opt/halium-overlay/vendor/etc/init
${TMP}/system/usr/share/halium-overlay/vendor/etc/init
${TMP}/system/android/system/etc/init
${TMP}/system/android/vendor/etc/init
"
while IFS= read -r path ; do
    if [ -d "$path" ]; then
        find "$path" -type f -exec chmod 644 {} \;
    fi
done <<< "$INITRC_PATHS"

BUILDPROP_PATHS="
${TMP}/system/opt/halium-overlay/system
${TMP}/system/usr/share/halium-overlay/system
${TMP}/system/opt/halium-overlay/vendor
${TMP}/system/usr/share/halium-overlay/vendor
${TMP}/system/android/system
${TMP}/system/android/vendor
"
while IFS= read -r path ; do
    if [ -d "$path" ]; then
        find "$path" -type f \( -name "prop.halium" -o -name "build.prop" \) -exec chmod 600 {} \;
    fi
done <<< "$BUILDPROP_PATHS"

if [ -z "$deviceinfo_use_overlaystore" ]; then
    "$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}"
    # create device tarball for https://wiki.debian.org/UsrMerge rootfs
    "$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}" "usrmerge"
else
    "$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}" "overlaystore"
    # create a symlink for _usrmerge variant so that common pipeline just works.
    ln -sf "device_${deviceinfo_codename}.tar.xz" "${OUT}/device_${deviceinfo_codename}_usrmerge.tar.xz"
fi

# Upload Module.symvers to artifacts for GKI debugging
[ -f "${TMPDOWN}/KERNEL_OBJ/Module.symvers" ] && cp "${TMPDOWN}/KERNEL_OBJ/Module.symvers" "${OUT}"

if [ -z "$BUILD_DIR" ]; then
    rm -r "${TMP}"
    rm -r "${TMPDOWN}"
fi

echo "done"
