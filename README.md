# pine-a64-gh-runner

Immutable, auto-updating **GitHub Actions self-hosted runner** image for the
**Pine A64-DB Rev B** (Allwinner A64). Flash an SD card, drop in a token file,
power on: the board registers itself as an *ephemeral* runner, executes exactly
one job per cycle, then wipes everything short of `/data`.

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
| Ephemeral per job | Runner runs with `--ephemeral --disableupdate`; when the job ends the listener exits, `supervise-daemon` restarts the cycle script which rebuilds a fresh tmpfs-overlaid chroot and re-registers |
| Dropped privileges | Everything runs as uid 1001 (`runner`) via `setpriv`, inside a Debian chroot, zero sudo, locked passwords, cgroup memory limit (768M) |
| Persistent data | Only `/data` (ext4, p4) is writable across reboots: credentials (`conf/env`), logs, caches, `_work` (wiped between cycles) |
| A/B updates | `ab-flash` writes the inactive slot + new kernel assets, flips a marker file atomically; rollback = `gha-slot-select a` |

### Why the Debian chroot?

The official [`actions/runner`](https://github.com/actions/runner/issues/801) is **glibc-only** and will not run on musl/Alpine. We keep the tiny immutable Alpine host and bake a minimal Debian bookworm rootfs (`/srv/chroot-template`) into the read-only slot; at runtime a tmpfs-overlay clone is created so job debris never touches storage and vanishes on the next cycle.

---

## Quick start

### 1. Get an image

Every push to `master` (and a weekly cron) produces a release containing:

* `sdcard.img.gz` — full image, flash this
* `sdcard_update.tar.gz` — on-device update bundle for `ab-flash`
* `versions.txt`

PRs and manual dispatches upload the same files as workflow artifacts without creating a release.

### 2. Flash

```sh
gunzip -c sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

(≥8 GB card recommended; slots are 2 GB each by default.)

### 3. Provision credentials

Either re-insert the SD card into your laptop and edit the `data` partition,
or wait for first boot and SSH in:

```sh
sudo -i                      # via doas as admin, key-only SSH
cd /data/conf
cp env.example env
vi env                       # set GITHUB_URL, GITHUB_TOKEN
chmod 600 env
reboot                       # or: rc-service gha-runner restart
```

`env` contents:

```sh
GITHUB_URL=https://github.com/OWNER/REPO
GITHUB_TOKEN=github_pat_...   # fine-grained PAT: Administration:read/write on that repo
RUNNER_LABELS=pine64,aarch64,self-hosted   # optional
```

The PAT is used **only** to mint short-lived (1 h) registration tokens at each
cycle start; it never leaves the box and is never baked into any image.

### 4. Verify

The device appears under *Settings → Actions → Runners* within ~a minute of
boot. Trigger a job tagged with your labels.

---

## Updating a running device

```sh
scp output/sdcard_update.tar.gz admin@device:/tmp/
ssh admin@device
doas ab-flash /tmp/sdcard_update.tar.gz
doas reboot
```

Rollback if the new slot misbehaves:

```sh
doas gha-slot-select a && doas reboot   # 'b' to go back forward
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
| Secrets | None in image. PAT lives in `/data/conf/env` (0600 root-only); registration tokens live ~seconds |
| Credentials hygiene | `.credentials` land on tmpfs upperdir — wiped after every single job |
| Network | nftables default-drop inbound (SSH only); egress blocks link-local metadata (169.254.169.254) & carrier ranges; LAN stays reachable for DNS/gateway (documented tradeoff) |
| Services | sshd key-only (`admin` user only), root password locked, serial console login impossible (locked root) |
| Resources | cgroup-v2 `memory.max=768M` on the runner tree; zram swap absorbs spikes |
| Supply chain | Runner tarball checksummed against GitHub's published digest when available; `RUNNER_SHA256` enforces pinning; kernel/rootfs come from pinned Alpine branch |

**Honest caveat:** this is still a self-hosted runner executing untrusted PR
code. GitHub's guidance applies — prefer private repos, require approval for
first-time contributors, and treat physical theft of the SD card as in-scope
(the PAT is on it).

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
