#!/bin/sh
# Boot LJOS in QEMU

if [ ! -f initramfs.cpio.gz ]; then
    ./build_initramfs.sh
fi

QEMU="qemu-system-x86_64"
FLAGS="-kernel bzImage -initrd initramfs.cpio.gz -m 512M -net nic,model=e1000 -net user"

if [ "$1" = "--nographic" ]; then
    echo "Booting in nographic mode (serial console)..."
    $QEMU $FLAGS -nographic -append "console=ttyS0 earlyprintk=ttyS0,115200"
else
    echo "Booting in graphical mode..."
    # Standard VGA + PS/2 Mouse/Kbd + Framebuffer initialization
    $QEMU $FLAGS -vga std -append "video=800x600 console=ttyS0 bochs-drm.modeset=1" -serial pipe:/tmp/qemu_serial
fi
