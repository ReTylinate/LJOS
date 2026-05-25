#!/bin/sh
# Send a command to QEMU via pipe
echo "$1" > /tmp/qemu_serial.in
# Give it a moment to process and print to output
sleep 0.5
cat /tmp/qemu_serial.out
