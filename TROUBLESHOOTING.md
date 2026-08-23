# Troubleshooting domarchy

Findings from a full bring-up session: seven defects, their root causes, and the
fixes applied. Ordered roughly as you hit them.

---

## 1. `compose build requires buildx 0.17.0 or later`

**Host-side, not a project bug.** A hand-installed buildx binary in
`~/.docker/cli-plugins/` shadows the apt-managed plugin, because the user plugin
directory takes priority over `/usr/libexec/docker/cli-plugins/`.

```bash
docker buildx version                                  # what actually resolves
ls -la ~/.docker/cli-plugins/docker-buildx             # the stale copy
/usr/libexec/docker/cli-plugins/docker-buildx version  # the packaged one
```

Fix: remove or rename the user-level copy. The `docker-buildx-plugin` package
supersedes it and keeps getting updates, which a manual copy never will.

---

## 2. Installer reboots into itself forever

**Symptom:** Omarchy installs, reboots, and comes straight back to
"Let's setup your machine…" — indefinitely.

**Cause:** QEMU boot letters are `c` = first hard disk, `d` = CD-ROM. The
original `-boot order=dc` puts the CD-ROM ahead of the disk on *every* boot, so
the post-install reboot re-runs the installer. The already-installed branch had
the mirror-image bug: `order=d` told a VM with no CD-ROM attached to boot from
CD-ROM, producing `Boot failed: Could not read from CDROM (code 0003)` before
SeaBIOS fell through to the disk.

**Fix** (`entrypoint.sh`) — QEMU's `once` parameter applies to the first boot of
the QEMU process, then reverts to `order`:

```bash
BOOT_OPTS="order=c,once=d"   # fresh install: ISO this boot, disk after
BOOT_OPTS="order=c"          # already installed: disk only
```

**Diagnosing it:** the disk was never the problem. `du -sh` on the qcow2
distinguishes the two cases instantly — 196K means bare metadata and nothing was
ever installed; several GB means the install succeeded and only boot order is
wrong.

---

## 3. QEMU exits 1 with `pulseaudio: Access denied`

The socket is world-writable, so this is **not** a filesystem permission
problem — it is PulseAudio cookie authentication. The container runs as root
with no `~/.config/pulse/cookie`, so the server rejects the client.

**Fix** (`docker-compose.yml`): mount the host cookie and point PulseAudio at it
explicitly, so it does not depend on `$HOME` inside the container.

```yaml
volumes:
  - ${HOME}/.config/pulse/cookie:/tmp/pulse.cookie:ro
environment:
  - PULSE_COOKIE=/tmp/pulse.cookie
```

`entrypoint.sh` also gained `AUDIO=none`, which swaps in `-audiodev none` for
environments with no PulseAudio at all (Kubernetes). `-audiodev pa` was
previously unconditional, so QEMU died outright wherever no socket existed.

---

## 4. Container dies mid-session, `exit=137`

```bash
docker inspect domarchy --format '{{.State.ExitCode}} oom={{.State.OOMKilled}}'
# 137 oom=true
```

The compose file set guest RAM `MEMORY=8G` **and** a container limit of exactly
`8G`. QEMU needs real headroom beyond the guest allocation — page tables, device
emulation, the VGA framebuffer, plus websockify. Once the guest touched most of
its RAM the container crossed the limit and was killed.

**Fix:** limit raised to `10G` while the guest stays at `8G`. Keep roughly 1–2G
of margin whenever you change `MEMORY`.

---

## 5. Black desktop after login

The single most misleading symptom in the session. **The browser was never at
fault** — noVNC faithfully relays whatever the guest paints, and the text-mode
installer rendering correctly earlier proves the whole path works.

### Ruling out the display stack

Screendump straight from QEMU's framebuffer, upstream of VNC and noVNC entirely:

```bash
docker exec domarchy python3 -c "
import socket,time
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/tmp/qemu-monitor.sock')
s.settimeout(5); s.recv(4096)
s.sendall(b'screendump /tmp/shot.png -f png\n'); time.sleep(2)"
docker cp domarchy:/tmp/shot.png .
```

Identical black frame → the guest genuinely paints black, and switching to a
native VNC client would change nothing.

`hyprctl monitors` then showed a perfectly healthy output — `1760x990@74.99`,
`dpmsStatus: 1`, `disabled: false` — and 225 registered keybindings proved the
config loaded completely. So the compositor was fine and the desktop was empty.

### The actual cause

```
journalctl --user -t omarchy-shell -n 25
```

```
quickshell: symbol lookup error: quickshell: undefined symbol:
  _ZN23QUntypedPropertyBindingC1EP23QPropertyBindingPrivate
Omarchy shell exited with status 127; relaunching.
Giving up on the Omarchy shell after 6 relaunches in under a minute.
```

A **Qt6 ABI break**. `quickshell-git` is an AUR *git* build compiled against
whatever Qt6 was current at build time; a system upgrade moved `qt6-base` to
`6.11.2-2` and nothing rebuilt quickshell. Triggered by running the system
update after install — not by virtualization, and not by anything in this repo.

### Why it blacked out the *entire* desktop

Omarchy v4 "Quattro" replaced nine separate apps (Waybar, Walker, Mako, …) with
a **single Quickshell process**. On v3 a dead Waybar cost you the bar alone. On
v4 `quickshell` *is* the desktop, so one unresolved symbol removes the bar,
wallpaper, notifications, launcher and lock screen simultaneously, leaving
Hyprland's bare background. `pgrep waybar` finds nothing on v4 because there is
no waybar.

### Recovery

Reinstalling from the ISO restores a matched quickshell/Qt6 pair. Decline the
first-boot "Update System" prompt until you are ready to rebuild quickshell.
A black desktop after a future update means `journalctl --user -t omarchy-shell`,
not a broken VM.

---

## 6. Hyprland needs virtio-gpu, and Arch ships it separately

Arch splits QEMU display models into their own packages. Without them the only
option is `-device VGA` (bochs-drm), which is a poor fit for a wlroots
compositor.

```bash
docker run --rm --entrypoint qemu-system-x86_64 <image> -device help | grep -i vga
```

Added to the `Dockerfile`: `qemu-hw-display-virtio-gpu`,
`qemu-hw-display-virtio-vga`, `qemu-hw-display-virtio-gpu-pci`. `entrypoint.sh`
now defaults to `VIDEO=virtio-vga`; set `VIDEO=VGA` to revert.

Note this was **not** the cause of the black screen — the desktop had rendered
on plain `VGA` before the upgrade. virtio-vga is the better device for Hyprland
and is confirmed working (the guest picks up the EDID mode), but it fixed
nothing on its own.

---

## 7. VM permanently unbootable after a restart mid-install

**Symptom:** after the pod or container is replaced, the VM never comes back:

```
Boot failed: not a bootable disk
Booting from DVD/CD... Boot failed: Could not read from CDROM (code 0003)
iPXE ... Nothing to boot: No such file or directory
No bootable device.
```

Nothing recovers it — every subsequent restart lands in the same place.

**Cause:** the sequel to finding 2. Boot order was right, but the *branch
choosing* it was wrong. `entrypoint.sh` used the existence of the qcow2 as a
proxy for "an OS is installed", and `qemu-img create` makes that file in the
first seconds of the first boot. So the proxy only holds if the install
completes inside the lifetime of one container. It did not here: a k3d node
reboot replaced the pod while the installer was still sitting at its prompt,
leaving a blank 196K qcow2 on the PVC. On the next start the existence test took
the "already installed" path — `order=c`, no `-cdrom` — and pointed QEMU at an
empty disk with no installer attached.

Note the failure is *sticky*: the installer is exactly what would write the
missing OS, and it is the thing the logic has decided not to attach.

**Fix:** decide from what is on the disk, not from whether the file exists.
An installed disk carries bootloader code in the MBR bootstrap area (Omarchy 4
uses Limine) followed by the 0x55AA signature:

```bash
qemu-img dd -U -f qcow2 -O raw bs=512 count=1 if=$DISK of=/tmp/mbr.bin
od -An -v -tx1 -j510 -N2 /tmp/mbr.bin    # 55 aa on an installed disk
od -An -v -tx1 -N440 /tmp/mbr.bin        # Limine boot code; zeros if not installed
```

The signature alone is **not** sufficient. GPT partitioning writes a protective
MBR that carries 0x55AA over a zeroed bootstrap, so a restart between
partitioning and bootloader install would look installed and dead-end the same
way. Both halves are required.

`od -v` is load-bearing: without it `od` collapses repeated identical lines to
`*`, and an all-zero bootstrap then reads as non-zero — inverting the test. This
bit the first version of the check.

Verified against four disk states — installed (bootable), freshly created
(not), GPT-partitioned without a bootloader (not), and absent (not).

`entrypoint.sh` also now fails loudly if it needs the ISO and the ISO is missing
or empty, rather than handing QEMU a `-cdrom` path that is not there, and
accepts `FORCE_INSTALL=1` to re-run the installer over a working disk.

**Unrelated to the chart:** the pod was not OOM-killed and no probe fired.
`kubectl get events` showed `node(s) were unschedulable` then an untolerated
taint — the k3d node restarted with the host. `restartCount` stayed 0 because
the pod was replaced, not restarted.

---

## Debugging without guest credentials

`entrypoint.sh` exposes a QEMU monitor at `/tmp/qemu-monitor.sock`. It makes the
guest fully inspectable from the host — screendumps, TTY switching, and synthetic
keystrokes — without SSH or a password.

```
sendkey ctrl-alt-f2          # switch to a console
sendkey meta_l-k             # send Super+K
screendump /tmp/out.png -f png
```

Screendump captures the framebuffer *before* VNC, which is what makes it
decisive for separating guest-side from transport-side rendering faults.

---

## noVNC and the Super key

Omarchy is Super-driven, and GNOME on the host claims Super for the Activities
overlay, so Chrome never forwards it to noVNC. The bindings themselves are fine —
verify with `sendkey meta_l-k`, which bypasses the browser and opens the
cheatsheet.

Options, best first:

1. Native VNC client with keyboard grab (`vncviewer localhost:5900`, Remmina).
2. noVNC fullscreen — helps, still unreliable for Super under GNOME.
3. Remap the mod key to `ALT` in `~/.config/hypr/bindings.lua`.

---

## Omarchy v4 notes

Worth knowing when reading the guest's filesystem:

- Hyprland config is **Lua** (`hyprland.lua`, `bindings.lua`, `autostart.lua`),
  not `hyprland.conf` — required for Hyprland 0.56.
- Omarchy internals moved from git to system packages, so they live in
  `/usr/share/omarchy`, **not** `~/.local/share/omarchy`. That directory being
  absent is correct on v4.
- `~/.config/hypr/*.lua` are user overrides layered *after* Omarchy's defaults,
  so package updates can improve defaults without touching your files.
- The desktop shell is Quickshell, launched by `omarchy-launch-shell`, which logs
  to the journal under the tag `omarchy-shell`.
