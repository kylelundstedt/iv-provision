---
title: "Tailscale in Apple Containers"
---

## Verified configuration

Apple Container 1.4.1 can run Tailscale with the Linux kernel TUN path. This was
verified on `klundstedt-mini` on 2026-09-20 with the official
`tailscale/tailscale` image (Tailscale 1.102.4, Linux/arm64).

“Native” here means Tailscale uses `/dev/net/tun`, a `tailscale0` interface,
kernel routing, and netfilter inside Apple Container's Linux VM. It does not
mean that the container bypasses the VM and attaches directly to the macOS
network stack.

The minimum reliable capability set is:

```text
NET_ADMIN
NET_RAW
```

Apple Container currently includes `NET_RAW` in its default capability set, so
adding only `NET_ADMIN` appears to work. Do not depend on that implicit default:
with `NET_RAW` explicitly dropped, `tailscaled` and `tailscale0` still start but
iptables cannot open the `filter` or `nat` tables. That half-working state is
particularly misleading because `tailscale status` alone does not expose the
netfilter failure.

Unlike Docker, Apple Container 1.4.1 has no `--device` option. Adding
`NET_ADMIN` makes its existing `/dev/net/tun` available to the container; no
`--device=/dev/net/tun` flag is needed.

## Persistent setup

Create a named volume so replacing or recreating the container keeps the same
Tailscale node identity:

```bash
container volume create tailscale-state
```

Use a reusable, pre-authorized auth key whose allowed tag matches the node's
intended role. Bootstrap the node with the key inherited from the shell rather
than writing it into a command line:

```bash
export TS_AUTHKEY='tskey-auth-...'

container run -d --name tailscale-bootstrap \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -e TS_AUTHKEY \
  -e TS_AUTH_ONCE=true \
  -e TS_HOSTNAME=apple-container \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=false \
  -v tailscale-state:/var/lib/tailscale \
  tailscale/tailscale:v1.102.4

container exec tailscale-bootstrap tailscale status
unset TS_AUTHKEY
```

After the first successful join, recreate the container without the auth key so
it is not retained in the long-lived container configuration. The named volume
contains the authenticated state:

```bash
container stop tailscale-bootstrap
container rm tailscale-bootstrap

container run -d --name tailscale \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -e TS_AUTH_ONCE=true \
  -e TS_HOSTNAME=apple-container \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=false \
  -v tailscale-state:/var/lib/tailscale \
  tailscale/tailscale:v1.102.4

container exec tailscale tailscale status
```

Pin the image to a version that has been tested for the workload. The example
uses the version verified above; deliberately update it rather than silently
substituting `latest` in a persistent deployment.

## Validation

Confirm the kernel and device before debugging Tailscale itself:

```bash
container run --rm --cap-add NET_ADMIN alpine sh -c \
  'ls -l /dev/net/tun; zcat /proc/config.gz | grep CONFIG_TUN'
```

The verified result was:

```text
crw------- 1 root root 10, 200 /dev/net/tun
CONFIG_TUN=y
```

Then inspect the running node:

```bash
container exec tailscale ip -details link show tailscale0
container exec tailscale iptables -t filter -S
container exec tailscale iptables -t nat -S
container exec tailscale tailscale netcheck
container exec tailscale tailscale ping <peer>
```

Expected interface properties include `POINTOPOINT`, `UP`, and `tun type tun`.
The iptables commands must complete without `Permission denied`; interface
creation by itself is not enough.

The most useful peer test is `tailscale ping <peer>`. It reports whether traffic
becomes direct or remains relayed through DERP. Apple `vmnet` NAT plus the LAN's
NAT creates two translation layers, so path establishment—not TUN creation—is
the main remaining platform-specific uncertainty.

Also test the reverse direction from another tailnet node, then verify state
persistence:

```bash
container stop tailscale
container start tailscale
container exec tailscale tailscale status
```

The restarted container should return as the same node without another login.
If it registers a new node, `/var/lib/tailscale` is not using the intended named
volume.

## What was observed

The native-engine startup test produced a live kernel interface:

```text
3: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280
    tun type tun pi off vnet_hdr on persist off
```

`tailscaled` also initialized its WireGuard engine, selected iptables, and could
read both the filter and NAT tables with `NET_ADMIN` and `NET_RAW`. With
`NET_RAW` removed, it logged errors of this form instead:

```text
iptables: can't initialize iptables table `filter': Permission denied
iptables: can't initialize iptables table `nat': Permission denied
```

That establishes the kernel, TUN, routing, and netfilter prerequisites. Joining
the tailnet is control-plane HTTPS; the peer checks above determine the behavior
of Apple Container's NAT in actual tailnet traffic.
