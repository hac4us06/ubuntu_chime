#!/bin/bash
set -ex

device=$1
output=$(realpath "$2")
dir=$(realpath "$3")
# https://wiki.debian.org/UsrMerge
usrmerge=${4:-false}

echo "Working on device: $device; usrmerge: $usrmerge"
if [ ! -f "$dir/partitions/boot.img" ]; then
    echo "boot.img does not exist!"
exit 1; fi

if [ "$usrmerge" = "true" ]; then
    cd "$dir"
    # make sure udev rules and kernel modules are installed into /usr/lib
    # as /lib is symlink to /usr/lib on focal+
    if [ -d system/lib ]; then
        mkdir -p system/usr
        mv system/lib system/usr/
    fi
fi

output_name=device_"$device"
[ "$usrmerge" = "true" ] && output_name=device_"$device"_usrmerge

tar -cJf "$output/$output_name.tar.xz" -C "$dir" partitions/ system/
echo "$(date +%Y%m%d)-$RANDOM" > "$output/$output_name.tar.build"
