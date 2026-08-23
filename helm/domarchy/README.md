# domarchy Helm chart

Runs Omarchy in a QEMU/KVM virtual machine on Kubernetes, reachable over VNC
(5900) and noVNC in the browser (8900).

## Install

```bash
helm install domarchy ./helm/domarchy
kubectl port-forward svc/domarchy 8900:8900
# browse to http://127.0.0.1:8900
```

First install downloads a ~5.8G ISO and then boots the Omarchy installer. Walk
through setup in the browser; when the installer reboots the guest it boots the
installed disk rather than looping back into setup.

Whether to boot the installer is decided by reading the disk's boot sector, so a
pod rescheduled part-way through setup returns to the installer instead of
stranding itself on a blank disk. Set `FORCE_INSTALL=1` to reinstall over a
working VM.

## What differs from docker-compose

| | compose | chart |
|---|---|---|
| Audio | host PulseAudio passthrough | disabled (`AUDIO=none`) |
| Storage | bind mount `./data` | 50Gi PVC |
| qcow2 size | 50G | 40G, so it fits beside the ISO |
| Memory limit | 10G | 9Gi limit / 9Gi request |

## Storage

One claim holds both the ISO (~5.8G) and the qcow2, so `vm.diskSize` plus about
7G needs to fit inside `persistence.size`. The defaults (40G disk, 50Gi claim)
are sized for that; the chart prints a warning on install if you set a
combination that cannot fit.

The claim carries `helm.sh/resource-policy: keep`, so `helm uninstall` leaves
your installed VM intact. Delete it by hand to reclaim the space.

`persistence.enabled=false` swaps in an emptyDir — the VM is destroyed on every
pod restart and the ISO redownloads. Useful only for throwaway testing.

## KVM

`kvm.privileged=true` (the default) grants `/dev/kvm` the way compose does. For
a least-privilege cluster, run a KVM device plugin instead:

```yaml
kvm:
  privileged: false
  deviceResource:
    devices.kubevirt.io/kvm: 1
```

With neither, QEMU falls back to TCG software emulation — technically working,
far too slow for an interactive desktop.

## Audio

Off by default: cluster nodes have no per-user PulseAudio socket, and
hostPath-mounting one pins the pod to a single node. On a single-node cluster
where the socket exists you can enable it:

```yaml
audio:
  enabled: true
  socketPath: /run/user/1000/pulse/native
  cookiePath: /home/<you>/.config/pulse/cookie   # PulseAudio rejects clients without it
```

## Exposing noVNC

`ingress.enabled=true` routes port 8900. noVNC is a WebSocket app, so the
ingress controller needs upgrade support and long timeouts — for ingress-nginx:

```yaml
ingress:
  enabled: true
  host: domarchy.example.com
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

Raw VNC on 5900 is not HTTP and cannot go through an Ingress — use a
LoadBalancer or NodePort service for it.

## Values

See `values.yaml`; every key is commented inline.
