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
        print_info "$repo_name - already exists, skipping download"
    else
        git clone "$repo_url" -b "$repo_branch" --depth 1 --recursive
    fi
}

fetch_tarball_if_not_existing() {
    local dl_url="$1"
    local dl_name="${dl_url##*/}"
    dl_name="${dl_name%.tar.*}"

    if [ -d "$dl_name" ]; then
        print_info "$dl_name - already exists, skipping download"
    else
        curl --location --remote-name "$dl_url"
        tar xJf "${dl_url##*/}"
    fi
}

setup_gcc() {
    print_header "Setting up GCC repositories"

    if [ -n "$deviceinfo_kernel_gcc_toolchain_source" ] && [ -n "$deviceinfo_kernel_gcc_toolchain_dir" ]; then
        fetch_tarball_if_not_existing "$deviceinfo_kernel_gcc_toolchain_source"
        # shellcheck disable=SC2154
        GCC_PATH="$TMPDOWN/$deviceinfo_kernel_gcc_toolchain_dir"
    elif [ "$deviceinfo_arch" = "aarch64" ]; then
        clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9" "pie-gsi"
        # shellcheck disable=SC2034
        GCC_PATH="$TMPDOWN/aarch64-linux-android-4.9"
    fi

    if [ "$deviceinfo_arch" = "aarch64" ] || [ "$deviceinfo_arch" = "arm" ]; then
        clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9" "pie-gsi"
        # shellcheck disable=SC2034
        GCC_ARM32_PATH="$TMPDOWN/arm-linux-androideabi-4.9"
    fi
}

setup_clang() {
    # shellcheck disable=SC2154
    if ! $deviceinfo_kernel_clang_compile; then
        print_info "Compiling with clang is disabled, skipping repo setup"
        return
    fi

    print_header "Setting up clang repositories"

    local CLANG_BRANCH
    local CLANG_REVISION
    # shellcheck disable=SC2154
    case "$deviceinfo_halium_version" in
        9)
            CLANG_BRANCH="pie-gsi"
            CLANG_REVISION="4691093"
            ;;
        10)
            CLANG_BRANCH="android10-gsi"
            CLANG_REVISION="r353983c"
            ;;
        11)
            CLANG_BRANCH="android11-gsi"
            CLANG_REVISION="r383902"
            ;;
        12)
            CLANG_BRANCH="android12L-gsi"
            CLANG_REVISION="r416183b"
            ;;
        *)
            print_error "Clang is not supported with halium version '$deviceinfo_halium_version'"
            exit 1
            ;;
    esac

    clone_if_not_existing "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" "$CLANG_BRANCH"
    # shellcheck disable=SC2034
    CLANG_PATH="$TMPDOWN/linux-x86/clang-$CLANG_REVISION"
    rm -rf "$TMPDOWN/linux-x86/.git" "$TMPDOWN/linux-x86/"!(clang-$CLANG_REVISION)

    if [ -n "$deviceinfo_kernel_llvm_compile" ] && $deviceinfo_kernel_llvm_compile; then
        export LLVM=1 LLVM_IAS=1
    fi

    if [ -n "$deviceinfo_kernel_use_lld" ] && $deviceinfo_kernel_use_lld; then
        export LD=ld.ldd
    fi
}

setup_tooling() {
    print_header "Setting up additional tooling repositories"

    if ([ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay) || [ -n "$deviceinfo_dtbo" ]; then
        clone_if_not_existing "https://android.googlesource.com/platform/external/dtc" "pie-gsi"
        clone_if_not_existing "https://android.googlesource.com/platform/system/libufdt" "pie-gsi"
    fi

    clone_if_not_existing "https://android.googlesource.com/platform/external/avb" "android13-gsi"

    if [ -n "$deviceinfo_kernel_use_dtc_ext" ] && $deviceinfo_kernel_use_dtc_ext; then
        if [ -f "dtc_ext" ]; then
            print_info "dtc_ext - already exists, skipping download"
        else
            curl --location https://android.googlesource.com/platform/prebuilts/misc/+/refs/heads/android10-gsi/linux-x86/dtc/dtc?format=TEXT | base64 --decode > dtc_ext
        fi
        chmod +x dtc_ext
        export DTC_EXT="$TMPDOWN/dtc_ext"
    fi

    if [ -n "$deviceinfo_bootimg_append_vbmeta" ] && $deviceinfo_bootimg_append_vbmeta; then
        if [ -f "vbmeta.img" ]; then
            print_info "vbmeta.img - already exists, skipping download"
        else
            wget https://dl.google.com/developers/android/qt/images/gsi/vbmeta.img
        fi
    fi
}

setup_kernel() {
    print_header "Setting up kernel repositories"

    # shellcheck disable=SC2154
    KERNEL_DIR="$(basename "${deviceinfo_kernel_source}")"
    KERNEL_DIR="${KERNEL_DIR%.*}"
    # shellcheck disable=SC2154
    clone_if_not_existing "$deviceinfo_kernel_source" "$deviceinfo_kernel_source_branch" "$KERNEL_DIR"
}

setup_ramdisk() {
    if [ -f halium-boot-ramdisk.img ]; then
        print_info "halium-boot-ramdisk.img - already exists, skipping download"
        return
    fi

    print_header "Setting up ramdisk"

    # shellcheck disable=SC2154
    if [ -n "$deviceinfo_prebuilt_boot_ramdisk" ] && [ -f "$deviceinfo_prebuilt_boot_ramdisk" ]; then
        print_message "Using prebuilt ramdisk: $deviceinfo_prebuilt_boot_ramdisk"
        cp "$deviceinfo_prebuilt_ramdisk" halium-boot-ramdisk.img
    elif [ -n "$deviceinfo_prebuilt_boot_ramdisk_source" ]; then
        print_message "Downloading prebuilt ramdisk from: $deviceinfo_prebuilt_boot_ramdisk_source"
        RAMDISK_URL="$deviceinfo_prebuilt_boot_ramdisk_source"
    elif [[ "$deviceinfo_kernel_cmdline" = *"systempart=/dev/mapper"* ]]; then
        print_message "Selecting dynparts ramdisk for devices with dynamic partitions"
        RAMDISK_URL="https://github.com/halium/initramfs-tools-halium/releases/download/dynparts/initrd.img-touch-${RAMDISK_ARCH}"
    else
        print_message "Selecting default ramdisk"
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
