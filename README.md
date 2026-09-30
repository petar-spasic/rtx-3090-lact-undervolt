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
- Root on the host with the 3090s. Proxmox: the PVE host, not an LXC (containers can't set clocks; they inherit the host's).
- NVIDIA driver with its CUDA/NVML libraries (LACT requirement; not nouveau), `nvidia-smi` working.
- [LACT](https://github.com/ilya-zlobintsev/LACT/releases) headless `.deb`.
- `python3-yaml`.

## Install
```bash
apt install ./lact-headless-*.deb python3-yaml   # .deb outside /root avoids the _apt warning
systemctl enable --now lactd
lact cli list-gpus                               # must list the 3090s

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
