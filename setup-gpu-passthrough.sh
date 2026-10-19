#!/usr/bin/env bash
# =============================================================================
# setup-gpu-passthrough.sh  -  Proxmox VE GPU passthrough setup (with pre-checks)
# Written by Prox for Jeffrey, 2026-10-17. Updated 2026-10-18 after clean reinstall.
# Tested on: i7-9700F (no iGPU), RTX 2060 SUPER, PVE 9.2, kernel 7.0.14-23-pve,
# VM "jex-server" (Ubuntu 26.04 + Ollama).
#
# ALWAYS run the checks first (especially for a video):
#   bash setup-gpu-passthrough.sh --check          # full read-only verification
#   bash setup-gpu-passthrough.sh                  # checks, then asks before every change
#   bash setup-gpu-passthrough.sh --vm 102         # same + configure VM 102
#   bash setup-gpu-passthrough.sh --force          # ignore critical check failures
#
# It never reboots by itself.
# =============================================================================
set -euo pipefail

CHECK_ONLY=0; FORCE=0; VMID=""; MAP_ID="${MAP_ID:-GPU}"; VM_MEM="${VM_MEM:-4096}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --vm) VMID="$2"; shift ;;
    --map-id) MAP_ID="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac; shift
done

say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '   \033[32m[PASS]\033[0m %s\n' "$*"; }
warn(){ printf '   \033[33m[WARN]\033[0m %s\n' "$*"; }
fail(){ printf '   \033[31m[FAIL]\033[0m %s\n' "$*"; }
ask(){ [ "$CHECK_ONLY" = 1 ] && return 1; read -r -p "   $1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }

CRITICAL=0
[ "$(id -u)" = 0 ] || { echo "Must run as root on the Proxmox host."; exit 1; }
command -v pveversion >/dev/null || { echo "Not a Proxmox host."; exit 1; }
NODE=$(hostname)

# =============================================================================
# PRE-CHECKS (always run, never change anything)
# =============================================================================
say "PRE-CHECKS (read-only)"

# 1. CPU / IOMMU capability
CPU_VENDOR=$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
  IOMMU_OPTS="intel_iommu=on iommu=pt"
  ok "Intel CPU detected"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
  IOMMU_OPTS="iommu=pt"
  ok "AMD CPU detected"
else
  fail "Unknown CPU vendor: $CPU_VENDOR"; CRITICAL=1
fi

# 2. IOMMU currently active?
if [ -d /sys/kernel/iommu_groups ] && [ "$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)" -gt 0 ]; then
  ok "IOMMU is active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
else
  fail "IOMMU is NOT active. Enable VT-d / AMD-Vi in BIOS and add $IOMMU_OPTS to kernel cmdline."
  CRITICAL=1
fi

# 3. Find GPU
if [ -z "${GPU_SLOT:-}" ]; then
  GPU_SLOT=$(lspci -Dnn | awk '/\[10de:/ && /VGA|3D/ {print $1; exit}' | sed 's/\.[0-9]$//' || true)
fi
if [ -z "$GPU_SLOT" ]; then
  fail "No NVIDIA GPU found."
  CRITICAL=1
else
  ok "NVIDIA GPU found at $GPU_SLOT"
  mapfile -t FUNCS < <(lspci -Dnn -s "$GPU_SLOT" | awk '{print $1}')
  IDS=""
  for f in "${FUNCS[@]}"; do
    id=$(lspci -n -s "$f" | awk '{print $3}')
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/$f/driver 2>/dev/null)" 2>/dev/null || echo none)
    grp=$(basename "$(readlink -f /sys/bus/pci/devices/$f/iommu_group 2>/dev/null)" 2>/dev/null || echo "?")
    printf '     %s  %s  group=%s  driver=%s\n' "$f" "$id" "$grp" "$drv"
    IDS="${IDS:+$IDS,}$id"
  done
  MAIN="${FUNCS[0]}"
  VGA_ID=$(lspci -n -s "$MAIN" | awk '{print $3}')
  GROUP=$(basename "$(readlink -f /sys/bus/pci/devices/$MAIN/iommu_group)" 2>/dev/null || echo "")
  ok "GPU functions: ${#FUNCS[@]}  |  vfio ids: $IDS"
fi

# 4. IOMMU group isolation
if [ -n "${GROUP:-}" ]; then
  DEVS_IN_GROUP=$(ls /sys/kernel/iommu_groups/$GROUP/devices 2>/dev/null | wc -l)
  if [ "$DEVS_IN_GROUP" -le 4 ]; then
    ok "GPU IOMMU group $GROUP looks isolated ($DEVS_IN_GROUP devices)"
  else
    warn "GPU shares IOMMU group $GROUP with $DEVS_IN_GROUP devices. ACS override may be needed."
  fi
fi

# 5. Host NVIDIA packages (must be absent)
NV_PKGS=$(dpkg -l 2>/dev/null | awk '/^i/ && /nvidia|libcuda1|libnvcuvid1/ {print $2}' | grep -v pve-nvidia-vgpu-helper || true)
if [ -n "$NV_PKGS" ]; then
  fail "Host has NVIDIA packages installed (will break passthrough and kernel updates):"
  echo "$NV_PKGS" | sed 's/^/       /'
  CRITICAL=1
else
  ok "No NVIDIA packages on the host"
fi

# 6. Memory headroom
MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
MEM_AVAIL_GB=$((MEM_AVAIL_KB / 1024 / 1024))
if [ "$MEM_AVAIL_KB" -gt $((VM_MEM * 1024 * 2)) ]; then
  ok "Enough free RAM (${MEM_AVAIL_GB}G available, VM will pin ${VM_MEM}MB)"
else
  warn "Low free RAM (${MEM_AVAIL_GB}G). Passthrough VM pins all memory."
fi

# 7. Bootloader type
if [ -f /etc/kernel/cmdline ]; then
  ok "Using systemd-boot (/etc/kernel/cmdline)"
  BOOTFILE=/etc/kernel/cmdline
else
  ok "Using GRUB (/etc/default/grub)"
  BOOTFILE=/etc/default/grub
fi

# Summary of checks
echo
if [ "$CRITICAL" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  fail "CRITICAL checks failed. Fix the issues above (especially IOMMU and host NVIDIA packages) then re-run."
  echo "   Use --force only if you understand the risk."
  exit 1
fi
if [ "$CHECK_ONLY" -eq 1 ]; then
  ok "All critical checks passed. Safe to proceed with changes when ready."
  exit 0
fi
ok "Pre-checks finished. Proceeding to configuration (will ask before every change)."

# =============================================================================
# CONFIGURATION (only if checks passed or --force)
# =============================================================================

# IOMMU cmdline
say "Kernel command line"
if [ -f /etc/kernel/cmdline ]; then
  if ! grep -q "iommu=pt" /etc/kernel/cmdline; then
    ask "Add '$IOMMU_OPTS' to /etc/kernel/cmdline?" && sed -i "1 s/\$/ $IOMMU_OPTS/" /etc/kernel/cmdline
  else
    ok "IOMMU options already present"
  fi
else
  if ! grep -q 'iommu=pt' /etc/default/grub; then
    ask "Add '$IOMMU_OPTS' to GRUB?" && sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_OPTS\"/" /etc/default/grub
  else
    ok "IOMMU options already present"
  fi
fi

# Purge host NVIDIA if present
if [ -n "$NV_PKGS" ]; then
  ask "Purge host NVIDIA packages now?" && { apt-get purge -y $NV_PKGS; apt-get autoremove -y; }
fi

# vfio bind
say "vfio-pci binding"
VFIO_CONF=/etc/modprobe.d/vfio.conf
WANT="options vfio-pci ids=$IDS disable_vga=1"
if ! grep -qs "ids=$IDS" "$VFIO_CONF" 2>/dev/null; then
  echo "   Will write: $WANT"
  if ask "Write vfio.conf and load modules?"; then
    cat > "$VFIO_CONF" <<EOF
$WANT
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep xhci_pci pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
    for m in vfio vfio_iommu_type1 vfio_pci; do
      grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules
    done
    printf 'blacklist nouveau\nblacklist nvidiafb\n' > /etc/modprobe.d/blacklist-gpu-host.conf
    ok "vfio configuration written"
  fi
else
  ok "vfio already configured for this GPU"
fi

# initramfs
say "initramfs"
if ask "Rebuild initramfs and update bootloader?"; then
  update-initramfs -u -k all
  for k in /boot/vmlinuz-*; do
    v=${k#/boot/vmlinuz-}
    [ -f "/boot/initrd.img-$v" ] || update-initramfs -c -k "$v"
  done
  if [ -f /etc/kernel/proxmox-boot-uuids ]; then
    proxmox-boot-tool refresh
  else
    update-grub
  fi
fi

# PCI mapping
say "PCI mapping '$MAP_ID'"
SUBSYS=$(cat /sys/bus/pci/devices/$MAIN/subsystem_vendor 2>/dev/null | sed 's/0x//'):$(cat /sys/bus/pci/devices/$MAIN/subsystem_device 2>/dev/null | sed 's/0x//')
MAP_ENTRY="id=$VGA_ID,iommugroup=$GROUP,node=$NODE,path=$GPU_SLOT,subsystem-id=$SUBSYS"
if pvesh get /cluster/mapping/pci/$MAP_ID >/dev/null 2>&1; then
  ask "Update existing mapping '$MAP_ID'?" && pvesh set /cluster/mapping/pci/$MAP_ID --map "$MAP_ENTRY" --description "NVIDIA GPU (all functions)"
else
  ask "Create mapping '$MAP_ID'?" && pvesh create /cluster/mapping/pci --id "$MAP_ID" --map "$MAP_ENTRY" --description "NVIDIA GPU (all functions)"
fi

# Optional VM config
if [ -n "$VMID" ]; then
  say "VM $VMID"
  if ask "Configure VM $VMID (q35 + OVMF + ${VM_MEM}MB balloon=0 + hostpci0=mapping=$MAP_ID,pcie=1)?"; then
    qm set "$VMID" --machine q35 --bios ovmf --memory "$VM_MEM" --balloon 0 --cpu host --hostpci0 "mapping=$MAP_ID,pcie=1" || true
    ok "VM updated"
  fi
fi

say "Finished"
echo "Reboot the host when ready. Local monitor goes blank after ramdisk (no iGPU) — use the web UI."
echo "After reboot: lspci -nnk -s $GPU_SLOT  (should show vfio-pci)"
