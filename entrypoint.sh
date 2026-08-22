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

# Check if this is first boot (disk doesn't exist)
if [[ ! -f "$DISK" ]]; then
    echo "Creating disk image..."
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
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
