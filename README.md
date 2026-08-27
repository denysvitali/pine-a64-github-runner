# pine-a64-gh-runner

Immutable, auto-updating **GitHub Actions self-hosted runner** image for the
**Pine A64-DB Rev B** (Allwinner A64). Flash an SD card, SSH in for guided
first-time setup, and the board registers itself as an isolated runner. It
executes exactly one job per cycle, then wipes everything short of `/data`.

Sibling project of [raspi-k3s](https://github.com/denysvitali/raspi-k3s) and built entirely **in GitHub Actions CI** — no local tooling required.

---

## Design at a glance

```
SD card (MBR)
┌──────────────┬──────────────┬──────────────┬─────────────────────┐
│ p1 BOOT vfat │ p2 slot-a    │ p3 slot-b    │ p4 DATA ext4        │
│ boot.scr     │ ext4 ro      │ ext4 ro      │ rw persistent       │
│ Image.a/b    │ Alpine root  │ update target│ /data               │
│ initramfs.a/b│ +Debian      │              │  conf/env (0600)    │
│ dtbs.a/b     │ chroot+runner│              │  runner/_work       │
│ boot_slot_b  │              │              │  log cache          │
└──────────────┴──────────────┴──────────────┴─────────────────────┘
   ▲ MBR (LBA0) + raw U-Boot (u-boot-sunxi-with-spl.bin @ offset 8 KiB,
     the fixed sunxi BROM load address; partitions start at 1 MiB)
```

| Concern | Mechanism |
|---|---|
| Immutable rootfs | Stock Alpine `mkinitfs`: `overlaytmpfs=yes` mounts the slot **read-only** and overlays a RAM upperdir → pristine state on every boot |
| Clean environment per job | Runner runs one job with `--once`; when the listener exits, `supervise-daemon` rebuilds a fresh tmpfs-overlaid chroot and restores its persistent runner identity |
| Dropped privileges | Everything runs as uid 1001 (`runner`) via `setpriv`, inside a Debian chroot, zero sudo, locked passwords, cgroup memory limit (768M) |
| Persistent data | Only `/data` (ext4, p4) is writable across reboots: onboarding state and credentials (`conf/`), logs, caches, `_work` (wiped between cycles) |
| A/B updates | `ab-flash` writes the inactive slot + new kernel assets, flips a marker file atomically; rollback = `gha-slot-select a` |

### Why the Debian chroot?

The official [`actions/runner`](https://github.com/actions/runner/issues/801) is **glibc-only** and will not run on musl/Alpine. We keep the tiny immutable Alpine host and bake a minimal Debian bookworm rootfs (`/srv/chroot-template`) into the read-only slot; at runtime a tmpfs-overlay clone is created so job debris never touches storage and vanishes on the next cycle.

---

## Quick start

### 1. Get an image

Every push to `master` (and a weekly cron) produces a release containing:

* `sdcard.img.zst` — full image, flash this (zstd; the two A/B slots dedup,
  so it stays under GitHub's 2 GiB release-asset cap)
* `sdcard_update.tar.gz` — on-device update bundle for `ab-flash`
* `versions.txt`

PRs and manual dispatches upload the same files as workflow artifacts without creating a release.

### 2. Flash

```sh
zstd -dc sdcard.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

(≥8 GB card recommended; slots are 2 GB each by default.)

### 3. Run first-time setup

Find the board's DHCP address, wait for SSH to start, and log in with the
temporary bootstrap credential:

```sh
ssh admin@DEVICE_IP
# temporary password: pine64-setup
```

The `admin` account's shell is always `/bin/ash`; onboarding is not present in
`/etc/passwd` and cannot intercept login. The MOTD suggests setup, but setup is
optional so you can always inspect or recover the device first. Start it explicitly:

```sh
doas /usr/local/sbin/gha-setup
```

The wizard asks for your SSH public key, repository URL, the short-lived runner
registration token shown under **Settings → Actions → Runners → New
self-hosted runner**, optional runner labels/name, and a new local console
password. It never asks for or stores a GitHub PAT. Review the summary and
confirm; the wizard starts registration, replaces the public bootstrap password,
and switches SSH to key-only authentication. Reconnect using your key:

```sh
ssh admin@DEVICE_IP
```

The registration token is stored root-only only until the first successful
registration, then deleted. The resulting runner identity is kept under
`/data/runner/config` so each clean job cycle does not need another token. Run
`doas /usr/local/sbin/gha-setup` later to replace the key, local password, or runner registration.

For unrestricted recovery administration, run `doas -s` and enter the current
`admin` password. Setup, A/B updates, slot selection, reboot, and poweroff also
have narrow passwordless rules when invoked by their absolute paths.

> **Security note:** `admin` / `pine64-setup` is public and intentionally works
> only until onboarding completes. Keep a new device on a trusted local network,
> complete setup immediately, and do not expose TCP port 22 to the internet
> before then. Setup never replaces the login shell: if it is interrupted or
> fails, reconnect normally and retry `doas /usr/local/sbin/gha-setup`. The Actions runner does
> not start until onboarding is complete.

The SSH host key is generated on the physical device during its first boot and
persisted on `/data`; no device identity or self-signed certificate is generated
in CI or shared between images.

### 4. Verify

The device appears under *Settings → Actions → Runners* within ~a minute of
boot. Trigger a job tagged with your labels.

### Recovery shell

Setup is never a forced login shell. Before onboarding, sign in with the
temporary password and simply decline to run setup; after onboarding,
sign in with the installed SSH key. A failed or interrupted wizard can always be
rerun from that shell.

For images containing the older BusyBox `chmod --reference` setup failure, the
key was persisted before the crash. Recover with the private key matching the
public key entered in the wizard, apply a current update bundle, and reboot:

```sh
ssh -i /path/to/private_key admin@DEVICE_IP
doas /usr/local/sbin/ab-flash /tmp/sdcard_update.tar.gz
doas /sbin/reboot
```

Then reconnect with the same key and run `doas /usr/local/sbin/gha-setup` with a fresh runner
registration token. Reflashing the DATA partition is not required.

---

## Updating a running device

```sh
scp output/sdcard_update.tar.gz admin@device:/tmp/
ssh admin@device
doas /usr/local/sbin/ab-flash /tmp/sdcard_update.tar.gz
doas /sbin/reboot
```

Rollback if the new slot misbehaves:

```sh
doas /usr/local/sbin/gha-slot-select a && doas /sbin/reboot   # 'b' to go back forward
```

---

## Building in CI

`.github/workflows/build-image.yaml` runs on GitHub's **native `ubuntu-24.04-arm`**
runners (no QEMU emulation), builds the image in a container, smoke-tests the
artifacts, uploads them on every run and publishes a release on `master`
pushes, weekly cron and manual dispatch.

Optional repository **Variables** override build knobs without touching code:
`RUNNER_VERSION`, `ALPINE_BRANCH`, `SIZE_SLOT`, `SIZE_IMAGE`, `DEFAULT_HOSTNAME`.
All other knobs live in `.env.example` (committed defaults).

> The weekly cron is not cosmetic: self-hosted runners must be within **30 days**
> of the latest release or GitHub stops queuing jobs to them. Since the image
> pins the runner version (`--disableupdate`), rebuilds ship new runner versions.

Local builds work too on any Linux box with Docker (arm64 hosts natively;
x86 hosts need `docker/setup-qemu-action`-style binfmt):

```sh
cp .env.example .env && ./build_image.sh
```

---

## Security model

| Layer | Control |
|---|---|
| Root filesystem | Read-only slot + RAM overlay; power-cycle = factory state |
| Job isolation | uid 1001, no sudo/doas membership, no docker socket, chroot cage |
| Secrets | None in image. The one-time registration token is deleted after use; the registered runner's private identity is stored mode 0600 on `/data` |
| Credentials hygiene | Runner identity persists on `/data`; job tokens and the working copy live in the per-job overlay and are wiped after every job |
| Network | nftables default-drop inbound (SSH only); egress blocks link-local metadata (169.254.169.254) & carrier ranges; LAN stays reachable for DNS/gateway (documented tradeoff) |
| Services | sshd allows the temporary `admin` password only during onboarding, then enforces key-only login; root is always locked |
| Resources | cgroup-v2 `memory.max=768M` on the runner tree; zram swap absorbs spikes |
| Supply chain | Runner tarball checksummed against GitHub's published digest when available; `RUNNER_SHA256` enforces pinning; kernel/rootfs come from pinned Alpine branch |

**Honest caveat:** this is still a self-hosted runner executing untrusted PR
code. GitHub's guidance applies — prefer private repos, require approval for
first-time contributors, and treat physical theft of the SD card as in-scope
(the registered runner identity is on it; remove that runner in GitHub to revoke it).

---

## Hardware notes (Pine A64-DB Rev B)

* **Serial console:** UART0 on EXP header **pin 7 TX, pin 8 RX, pin 9 GND**, 115200 8N1, 3.3 V logic. Avoid the Euler-header UART.
* **Power:** micro-USB is power-only (≥2 A recommended). FEL recovery via the USB-A OTG port.
* **Ethernet** (RMII Realtek PHY) works out of the box on mainline; **WiFi/BT** module (optional RTL8723BS) is *not* enabled in v1 (needs a DT overlay).
* Kernel cmdline selects `sun50i-a64-pine64.dtb`; both `pine64` and `pine64-plus` DTBs are shipped.

## Sizing reality check

| Board RAM | Verdict |
|---|---|
| 512 MB | Not supported |
| 1 GB | Light jobs only (zram helps, expect OOM kills on heavy builds) |
| 2 GB | Comfortable target |

## Known limitations (v1)

* No Docker/container actions or service containers (no daemon on-board; keeps RAM + attack surface down).
* `github.com` URLs only (GHES: adjust the API base in `gha-runner-cycle.sh`).
* `/data` doesn't auto-grow on larger cards; resize manually (`resize2fs`) or raise `SIZE_IMAGE`.
* Runner labels/name derive from hostname+MAC suffix; rename via `RUNNER_NAME` in `env`.

---

## Repository layout

```
.github/workflows/build-image.yaml   # all-in-CI pipeline (arm-native runners)
builder/Dockerfile                   # build container (apk/debootstrap/mkimage/sfdisk)
scripts/
  build.sh                           # stage orchestrator (container entrypoint)
  10-fetch.sh                        # minirootfs + actions-runner fetch & verify
  20-rootfs.sh                       # Alpine rootfs: packages, users, mkinitfs, services
  30-chroot.sh                       # Debian bookworm chroot + runner install
  40-image.sh                        # MBR image, U-Boot, boot.scr, A/B slots, bundles
input/
  boot.cmd                           # U-Boot A/B selection script
  packages, chroot-packages          # package manifests
  rootfs/                            # overlay tree: OpenRC units, firewall, wrappers
build_image.sh                       # local docker wrapper (same path CI uses)
```
