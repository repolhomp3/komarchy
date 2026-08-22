FROM archlinux:latest

# Arch ships QEMU display models as separate packages; without the virtio-gpu
# ones the only option is bochs-drm via "VGA", which leaves Hyprland on a black
# screen.
RUN pacman -Syu --noconfirm --needed qemu-system-x86 qemu-img edk2-ovmf wget qemu-audio-pa samba python-pip \
    qemu-hw-display-virtio-gpu qemu-hw-display-virtio-vga qemu-hw-display-virtio-gpu-pci

RUN pip install --break-system-packages --no-cache-dir websockify && \
    wget -qO- https://github.com/novnc/noVNC/archive/refs/tags/v1.6.0.tar.gz | tar xz -C /opt && \
    mv /opt/noVNC-1.6.0 /opt/novnc && \
    cp /opt/novnc/vnc.html /opt/novnc/index.html && \
    printf '{"autoconnect":true,"resize":"scale","path":"websockify"}\n' > /opt/novnc/defaults.json

EXPOSE 5900 8900

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
