#!/bin/bash
set -ex

# shellcheck disable=SC2154
case $deviceinfo_arch in
    "armhf") RAMDISK_ARCH="armhf";;
    "aarch64") RAMDISK_ARCH="arm64";;
    "x86") RAMDISK_ARCH="i386";;
esac

clone_if_not_existing() {
    local repo_url="$1"
    local repo_branch="$2"
    if [ -z ${3+x} ]; then
        local repo_name="${repo_url##*/}"
    else
        local repo_name="$3"
    fi

    if [ -d "$repo_name" ]; then
        echo "$repo_name - already exists, skipping download"
    else
        git clone "$repo_url" -b "$repo_branch" --depth 1 --recursive
    fi
}

setup_gcc() {
    echo "Setting up GCC repositories"

    clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9" "pie-gsi"
    # shellcheck disable=SC2034
    GCC_PATH="$TMPDOWN/aarch64-linux-android-4.9"

    if [ "$deviceinfo_arch" = "aarch64" ]; then
        clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9" "pie-gsi"
        # shellcheck disable=SC2034
        GCC_ARM32_PATH="$TMPDOWN/arm-linux-androideabi-4.9"
    fi
}

setup_clang() {
    # shellcheck disable=SC2154
    if ! $deviceinfo_kernel_clang_compile; then
        echo "Compiling with clang is disabled, skipping repo setup"
        return
    fi

    echo "Setting up clang repositories"

    clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" "android11-gsi"
    # shellcheck disable=SC2034
    CLANG_PATH="$TMPDOWN/linux-x86/clang-r383902"
    rm -rf "$TMPDOWN/linux-x86/.git" "$TMPDOWN/linux-x86/"!(clang-r383902)

    if [ -n "$deviceinfo_kernel_use_lld" ] && $deviceinfo_kernel_use_lld; then
        export LD=ld.ldd
    fi
}

setup_tooling() {
    echo "Setting up additional tooling repositories"

    if ([ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay) || [ -n "$deviceinfo_dtbo" ]; then
        clone_if_not_existing "https://android.googlesource.com/platform/external/dtc" "pie-gsi"
        clone_if_not_existing "https://android.googlesource.com/platform/system/libufdt" "pie-gsi"
    fi

    clone_if_not_existing "https://android.googlesource.com/platform/external/avb" "android13-gsi"

    if [ -n "$deviceinfo_kernel_use_dtc_ext" ] && $deviceinfo_kernel_use_dtc_ext; then
        if [ -f "dtc_ext" ]; then
            echo "dtc_ext - already exists, skipping download"
        else
            curl --location https://android.googlesource.com/platform/prebuilts/misc/+/refs/heads/android10-gsi/linux-x86/dtc/dtc?format=TEXT | base64 --decode > dtc_ext
        fi
        chmod +x dtc_ext
        export DTC_EXT="$TMPDOWN/dtc_ext"
    fi

    if [ -n "$deviceinfo_bootimg_append_vbmeta" ] && $deviceinfo_bootimg_append_vbmeta; then
        if [ -f "vbmeta.img" ]; then
            echo "vbmeta.img - already exists, skipping download"
        else
            wget https://dl.google.com/developers/android/qt/images/gsi/vbmeta.img
        fi
    fi
}

setup_kernel() {
    echo "Setting up kernel repositories"

    # shellcheck disable=SC2154
    KERNEL_DIR="$(basename "${deviceinfo_kernel_source}")"
    KERNEL_DIR="${KERNEL_DIR%.*}"
    # shellcheck disable=SC2154
    clone_if_not_existing "$deviceinfo_kernel_source" "$deviceinfo_kernel_source_branch" "$KERNEL_DIR"
}

setup_ramdisk() {
    if [ -f halium-boot-ramdisk.img ]; then
        echo "halium-boot-ramdisk.img - already exists, skipping download"
        return
    fi

    echo "Setting up ramdisk"

    # shellcheck disable=SC2154
    if [[ "$deviceinfo_kernel_cmdline" = *"systempart=/dev/mapper"* ]]; then
        echo "Selecting dynparts ramdisk for devices with dynamic partitions"
        RAMDISK_URL="https://github.com/halium/initramfs-tools-halium/releases/download/dynparts/initrd.img-touch-${RAMDISK_ARCH}"
    else
        echo "Selecting default ramdisk"
        RAMDISK_URL="https://github.com/halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-${RAMDISK_ARCH}"
    fi
    curl --location --output halium-boot-ramdisk.img "$RAMDISK_URL"
}

cd "$TMPDOWN"
    setup_gcc
    setup_clang
    setup_tooling
    setup_ramdisk
    setup_kernel

    ls .
cd "$HERE"
