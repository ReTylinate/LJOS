#!/bin/sh
# Populate rootfs/bin with BusyBox symlinks
CDIR=$(pwd)
cd rootfs/bin
for tool in tar mkdir rm rmdir mv cp ls ln wc sha256sum test chmod stty cat mount umount ifconfig udhcpc wget route echo tee touch clear mdev dd id; do

    if [ ! -e $tool ]; then
        ln -s luabox.lua $tool
    fi
done
cd "$CDIR"
echo "Created BusyBox symlinks in rootfs/bin"
