#!/bin/bash

DISK=/data/omarchy.qcow2
ISO=/data/omarchy.iso
MEMORY=${MEMORY:-8G}
CPUS=${CPUS:-4}
DISK_SIZE=${DISK_SIZE:-50G}
# pa = host PulseAudio passthrough; none = no audio backend (for environments
# such as Kubernetes where there is no user PulseAudio socket to bind).
AUDIO=${AUDIO:-pa}
PULSE_SOCKET=${PULSE_SOCKET:-/tmp/pulse.socket}
# Omarchy's desktop is Hyprland, a wlroots compositor that needs a DRM/KMS
# device with working GL. Plain "VGA" only exposes bochs-drm, which leaves the
# session running on a black screen. virtio-vga provides virtio_gpu, which
# wlroots drives via llvmpipe when there is no host GPU.
VIDEO=${VIDEO:-virtio-vga}
XRES=${XRES:-1760}
YRES=${YRES:-990}

if [[ ! -f "$ISO" ]]; then
    echo "Downloading Omarchy ISO..."
    wget -O "$ISO" "https://iso.omarchy.org/omarchy-4.0.0.iso" || echo "Download failed"
fi

# Whether to boot the installer depends on what is ON the disk, not on whether
# the disk file exists. A container replaced before setup finishes -- a node
# reboot, a rescheduled pod -- leaves a blank qcow2 behind on the volume, and an
# existence test then aims QEMU at an empty disk with no installer attached:
# "No bootable device", with no way back.
#
# An installed disk carries bootloader code in the MBR bootstrap area (Omarchy
# uses Limine) followed by the 0x55AA signature. The signature alone is not
# sufficient: GPT partitioning writes a protective MBR that carries the
# signature over a zeroed bootstrap, so a restart part-way through the install
# would look installed and dead-end the same way.
disk_is_bootable() {
    local mbr=/tmp/mbr.bin
    qemu-img dd -U -f qcow2 -O raw bs=512 count=1 \
        if="$DISK" of="$mbr" >/dev/null 2>&1 || return 1
    [[ "$(od -An -v -tx1 -j510 -N2 "$mbr" | tr -d ' \n')" == "55aa" ]] || return 1
    od -An -v -tx1 -N440 "$mbr" | tr -d ' \n' | grep -qv '^0*$'
}

if [[ ! -f "$DISK" ]]; then
    echo "Creating disk image..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi

if [[ "$FORCE_INSTALL" == "1" ]] || ! disk_is_bootable; then
    echo "No bootable OS on $DISK - booting the installer."
    if [[ ! -s "$ISO" ]]; then
        echo "ERROR: installer needed but $ISO is missing or empty." >&2
        exit 1
    fi
    CDROM_OPTION="-cdrom $ISO"
    # once=d boots the installer ISO for this boot only; when the installer
    # reboots the guest, order=c takes over and boots the freshly installed
    # disk. Without once=, the ISO wins every reboot and setup loops forever.
    BOOT_OPTS="order=c,once=d"
else
    echo "Starting Omarchy..."
    CDROM_OPTION=""
    BOOT_OPTS="order=c"
fi

if [[ "$VIDEO" == "VGA" ]]; then
    VIDEO_DEVICE="-device VGA,edid=on,xres=$XRES,yres=$YRES,vgamem_mb=32"
else
    VIDEO_DEVICE="-device $VIDEO,edid=on,xres=$XRES,yres=$YRES"
fi

if [[ "$AUDIO" == "none" ]]; then
    AUDIODEV="-audiodev none,id=audio0"
else
    AUDIODEV="-audiodev pa,id=audio0,server=unix:$PULSE_SOCKET"
fi

websockify --web /opt/novnc 8900 localhost:5900 &

exec qemu-system-x86_64 \
    -m $MEMORY -smp $CPUS -machine q35,accel=kvm:tcg \
    -drive file="$DISK",format=qcow2 \
    $CDROM_OPTION \
    -boot $BOOT_OPTS \
    -display vnc=:0 \
    $VIDEO_DEVICE \
    -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
    $AUDIODEV \
    -device ich9-intel-hda \
    -device hda-output,audiodev=audio0 \
    -net user,smb=/shared \
    -net nic
