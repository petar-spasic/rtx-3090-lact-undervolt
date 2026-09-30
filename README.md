# RTX 3090 undervolt via LACT

~230–240 W sustained instead of ~350 W, +200 MHz clock offset, **no power limit**,
applied at boot.

## How
No direct voltage control on Linux, so via LACT (NVML):
- **+200 MHz offset** on P0 (graphics) and P2 (CUDA/compute; GeForce runs compute in P2).
- **Clocks locked to 300–1700 MHz**: 1700 MHz runs at the stock ~1500 MHz voltage
  (~0.75–0.78 V) and can't climb higher.
- `power_cap` never set; removed if present.

`lact-3090-undervolt.sh` finds GPUs named `… 3090` (not 3090 Ti) and atomically merges into
`/etc/lact/config.yaml` → `gpus.<id>` and every `profiles.<name>.gpus.<id>`: `min_core_clock` + `max_core_clock` (lock needs both),
`gpu_clock_offsets: {0: 200, 2: 200}`. Other settings (fan curves) kept; comments stripped
(lactd strips them too on save). Pre-first-run config kept as `config.yaml.bak`.
Rewritten only on change.
Tunables at top: `MIN_CLOCK`, `MAX_CLOCK`, `CLOCK_OFFSET`, `GPU_MATCH`.

## Requirements
- Root on the host with the 3090s, systemd. Not in an unprivileged container
  (e.g. Proxmox LXC: can't set clocks, inherits the host's). Proxmox: run on the PVE host.
- NVIDIA driver with its CUDA/NVML libraries (LACT requirement; not nouveau), `nvidia-smi` working.
- LACT native package, headless is enough (script calls the `lact` binary; not Flatpak/Docker):
  [releases][r] (per distro version; v0.10.1 has no Debian 12 / PVE 8 build), Fedora also
  [Copr](https://copr.fedorainfracloud.org/coprs/ilyaz/LACT/). Gentoo, NixOS, Solus:
  [LACT install](https://github.com/ilya-zlobintsev/LACT#installation).
- PyYAML: `python3-yaml` (Debian/Ubuntu), `python3-pyyaml` (Fedora/RHEL),
  `python3-PyYAML` (openSUSE), `python-yaml` (Arch).

[r]: https://github.com/ilya-zlobintsev/LACT/releases

## Install
```bash
# 1. LACT + PyYAML, one line for your distro (.deb/.rpm from releases):
apt install ./lact-headless-*.deb python3-yaml        # Debian 13 (PVE 9), Ubuntu 24.04/26.04; .deb outside /root
dnf install ./lact-headless-*.rpm python3-pyyaml      # Fedora 43/44, RHEL 8/9
zypper install ./lact-headless-*.rpm python3-PyYAML   # openSUSE Tumbleweed
pacman -S lact python-yaml                            # Arch

# 2. Start LACT
systemctl enable --now lactd
lact cli list-gpus                                    # must list the 3090s

# 3. Install and run the script
cp lact-3090-undervolt.sh /usr/local/bin/ && chmod +x /usr/local/bin/lact-3090-undervolt.sh
cp lact-3090-undervolt.service /etc/systemd/system/
systemctl enable --now lact-3090-undervolt.service
```
lactd re-applies the config every boot; the unit is optional (without it, run the script once).

## Verify / tune
```bash
nvidia-smi --query-gpu=clocks.sm,power.draw --format=csv -l 2
```
- Expect ~1700 MHz at ~230–240 W under load.
- `MAX_CLOCK=1800` → ~250 W, more performance. Lower it if unstable.
- P2 offset error in `journalctl -u lactd` → drop the `2:` entry; the clock lock still covers compute.
