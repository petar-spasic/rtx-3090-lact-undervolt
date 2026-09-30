#!/usr/bin/env bash
# lact-3090-undervolt.sh - effective RTX 3090 undervolt via LACT, no power limit.
#
# +CLOCK_OFFSET MHz on P0/P2 shifts the V/F curve; locking clocks to
# MIN_CLOCK..MAX_CLOCK caps it. 1700 MHz lands at the stock ~1500 MHz voltage
# (~0.75-0.78 V), ~230-240 W sustained instead of ~350 W. power_cap is removed.
#
# Merges into /etc/lact/config.yaml (keeps other settings; strips comments, as lactd
# does on save; pre-first-run config kept as config.yaml.bak). Rewrites only on change.
# lactd applies it immediately and on every boot. Idempotent. Run as root on the
# host (not an unprivileged container). Requires lactd and PyYAML. Applied to the
# top-level gpus and every LACT profile.

set -euo pipefail

MIN_CLOCK=300      # MHz, lower bound of the locked range (idle clocks stay low)
MAX_CLOCK=1700     # MHz, locked ceiling -> ~230-240 W; 1800 -> ~250 W
CLOCK_OFFSET=200   # MHz, positive V/F curve offset = the actual undervolt
GPU_MATCH="3090"   # only touch GPUs whose name ends with this (excludes 3090 Ti)
CONFIG=/etc/lact/config.yaml

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

if ! python3 -c 'import yaml' &>/dev/null; then
    echo "PyYAML required: python3-yaml (Debian/Ubuntu), python3-pyyaml (Fedora/RHEL)," >&2
    echo "python3-PyYAML (openSUSE), python-yaml (Arch)" >&2
    exit 1
fi

# Wait until lactd lists the matching GPUs (at boot they can appear late). Lines:
#   0: 10DE:2204-1458:403B-0000:0b:00.0 (GeForce RTX 3090) [Dedicated]
# (older LACT: "(NVIDIA GeForce RTX 3090) [Nvidia]")
GPU_IDS=()
for _ in $(seq 1 30); do
    list=$(timeout 5 lact cli list-gpus 2>/dev/null) || list=""
    mapfile -t GPU_IDS < <(sed -nE "s/^[0-9]+: ([^ ]+) \([^)]*$GPU_MATCH\).*/\1/Ip" <<<"$list")
    [[ ${#GPU_IDS[@]} -gt 0 ]] && break
    sleep 1
done
if [[ ${#GPU_IDS[@]} -eq 0 ]]; then
    echo "no GPUs matching '$GPU_MATCH' after 30 tries (check: lact cli list-gpus, systemctl status lactd)" >&2
    exit 1
fi
echo "found ${#GPU_IDS[@]} matching GPU(s): ${GPU_IDS[*]}"

# Keep the pre-first-run config (and its comments) once.
if [[ -f $CONFIG && ! -e $CONFIG.bak ]]; then
    cp -p "$CONFIG" "$CONFIG.bak"
    echo "backed up pre-first-run config to $CONFIG.bak"
fi

GPU_IDS="${GPU_IDS[*]}" MIN_CLOCK=$MIN_CLOCK MAX_CLOCK=$MAX_CLOCK \
CLOCK_OFFSET=$CLOCK_OFFSET CONFIG=$CONFIG python3 - <<'EOF'
import os, yaml

path = os.environ["CONFIG"]
try:
    with open(path) as f:
        old = f.read()
except FileNotFoundError:
    old = None
config = yaml.safe_load(old or "") or {}

# An active profile (manual or auto-switched) replaces the top-level gpus, so
# apply to the top level and to every profile.
sections = [config] + [p for p in (config.get("profiles") or {}).values() if isinstance(p, dict)]
for section in sections:
    gpus = section["gpus"] = section.get("gpus") or {}
    for gpu_id in os.environ["GPU_IDS"].split():
        gpu = gpus[gpu_id] = gpus.get(gpu_id) or {}
        gpu["min_core_clock"] = int(os.environ["MIN_CLOCK"])
        gpu["max_core_clock"] = int(os.environ["MAX_CLOCK"])
        offsets = gpu["gpu_clock_offsets"] = gpu.get("gpu_clock_offsets") or {}
        # P0 = graphics load, P2 = CUDA/compute load on GeForce
        offsets[0] = int(os.environ["CLOCK_OFFSET"])
        offsets[2] = int(os.environ["CLOCK_OFFSET"])
        # make sure no power limit is configured
        gpu.pop("power_cap", None)

try:
    new = yaml.safe_dump(config, sort_keys=False, default_flow_style=False)
except TypeError:  # PyYAML < 5.1 (RHEL 8): no sort_keys, keys come out sorted
    new = yaml.safe_dump(config, default_flow_style=False)
if old is not None and yaml.safe_load(old) == config:
    # unchanged: don't make lactd reload and re-apply everything
    print(f"{path} already up to date")
    raise SystemExit

os.makedirs(os.path.dirname(path), exist_ok=True)
# atomic replace: lactd watches the directory and must never see a partial file
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(new)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, path)
print(f"updated {path}")
EOF

# lactd watches /etc/lact and applies changes automatically. Current clocks/power
# (idle clocks stay low; check under load):
sleep 2
nvidia-smi --query-gpu=index,name,clocks.sm,power.draw --format=csv || true
