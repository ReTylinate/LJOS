#!/bin/sh
# Build initramfs for LJOS

echo "Building initramfs..."
cd rootfs
find . | cpio -H newc -o 2>/dev/null | gzip > ../initramfs.cpio.gz
cd ..
echo "Done: initramfs.cpio.gz"
