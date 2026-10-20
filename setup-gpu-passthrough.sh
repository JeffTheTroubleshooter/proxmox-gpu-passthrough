#!/usr/bin/env bash
# =============================================================================
# setup-gpu-passthrough.sh  -  Proxmox VE GPU passthrough
# Pre-checks first. Asks to continue or remove passthrough.
# Forces any leftover GPU functions onto vfio-pci.
# Never reboots.
#
# Usage:
#   bash setup-gpu-passthrough.sh            # setup (asks for VM)
#   bash setup-gpu-passthrough.sh --remove   # FULL remove (VM + mapping + vfio + initramfs)
#   bash setup-gpu-passthrough.sh --check    # checks only
# =============================================================================
set -euo pipefail

CHECK_ONLY=0; FORCE=0; REMOVE=0; VMID=""; MAP_ID="${MAP_ID:-GPU}"; VM_MEM="${VM_MEM:-4096}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --remove) REMOVE=1 ;;
    --vm) VMID="$2"; shift ;;
    --map-id) MAP_ID="$2"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac; shift
done

say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){ printf '   \033[32m[PASS]\033[0m %s\n' "$*"; }
warn(){ printf '   \033[33m[WARN]\033[0m %s\n' "$*"; }
fail(){ printf '   \033[31m[FAIL]\033[0m %s\n' "$*"; }
ask(){ [ "$CHECK_ONLY" = 1 ] && return 1; read -r -p "   $1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }

[ "$(id -u)" = 0 ] || { echo "Must run as root."; exit 1; }
command -v pveversion >/dev/null || { echo "Not a Proxmox host."; exit 1; }
NODE=$(hostname)

# =============================================================================
# FULL REMOVE MODE
# =============================================================================
if [ "$REMOVE" -eq 1 ]; then
  say "FULL REMOVE GPU PASSTHROUGH"
  echo "This will detach the GPU from a VM, delete the mapping, remove vfio config,"
  echo "and rebuild initramfs so the GPU returns to the host after reboot."
  echo
  echo "Existing VMs:"
  qm list | awk 'NR>1 {printf "  %s  %s\n", $1, $2}'
  echo
  if [ -z "$VMID" ]; then
    read -r -p "Enter VMID to remove GPU from (or press Enter to skip VM): " VMID
  fi
  if [ -n "$VMID" ]; then
    if qm status "$VMID" >/dev/null 2>&1; then
      if ask "Remove hostpci0 from VM $VMID?"; then
        qm set "$VMID" --delete hostpci0 2>/dev/null || true
        ok "Removed hostpci0 from VM $VMID"
      fi
    else
      warn "VM $VMID does not exist"
    fi
  fi

  if ask "Delete PCI mapping '$MAP_ID'?"; then
    pvesh delete /cluster/mapping/pci/$MAP_ID 2>/dev/null && ok "Mapping deleted" || warn "Mapping did not exist"
  fi

  if ask "Remove vfio.conf and blacklist?"; then
    rm -f /etc/modprobe.d/vfio.conf /etc/modprobe.d/blacklist-gpu-host.conf
    ok "Removed vfio.conf and blacklist"
  fi

  if ask "Remove vfio modules from /etc/modules?"; then
    sed -i '/^vfio$/d;/^vfio_iommu_type1$/d;/^vfio_pci$/d' /etc/modules
    ok "Removed vfio lines from /etc/modules"
  fi

  if ask "Rebuild initramfs + update bootloader (required for full unbind on next boot)?"; then
    update-initramfs -u -k all
    if [ -f /etc/kernel/proxmox-boot-uuids ]; then
      proxmox-boot-tool refresh
    else
      update-grub
    fi
    ok "initramfs rebuilt"
  fi

  say "Full remove finished"
  echo "Reboot the host for the GPU to return to the normal drivers."
  echo "After reboot check: lspci -nnk -s 0000:01:00  (should no longer show vfio-pci)"
  exit 0
fi

# =============================================================================
# PRE-CHECKS
# =============================================================================
say "PRE-CHECKS (read-only)"

CRITICAL=0
CPU_VENDOR=$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
  IOMMU_OPTS="intel_iommu=on iommu=pt"
  ok "Intel CPU"
elif [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
  IOMMU_OPTS="iommu=pt"
  ok "AMD CPU"
else
  fail "Unknown CPU"; CRITICAL=1
fi

if [ -d /sys/kernel/iommu_groups ] && [ "$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)" -gt 0 ]; then
  ok "IOMMU active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
else
  fail "IOMMU not active. Enable VT-d/AMD-Vi in BIOS + add $IOMMU_OPTS"
  CRITICAL=1
fi

if [ -z "${GPU_SLOT:-}" ]; then
  GPU_SLOT=$(lspci -Dnn | awk '/\[10de:/ && /VGA|3D/ {print $1; exit}' | sed 's/\.[0-9]$//' || true)
fi
if [ -z "$GPU_SLOT" ]; then
  fail "No NVIDIA GPU found"; CRITICAL=1
else
  ok "NVIDIA GPU at $GPU_SLOT"
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
  ok "GPU functions: ${#FUNCS[@]} | ids: $IDS"
fi

if [ -n "${GROUP:-}" ]; then
  DEVS=$(ls /sys/kernel/iommu_groups/$GROUP/devices 2>/dev/null | wc -l)
  if [ "$DEVS" -le 4 ]; then
    ok "GPU group $GROUP looks isolated ($DEVS devices)"
  else
    warn "GPU shares group $GROUP with $DEVS devices"
  fi
fi

NV_PKGS=$(dpkg -l 2>/dev/null | awk '/^i/ && /nvidia|libcuda1|libnvcuvid1/ {print $2}' | grep -v pve-nvidia-vgpu-helper || true)
if [ -n "$NV_PKGS" ]; then
  fail "Host NVIDIA packages found (must be removed):"
  echo "$NV_PKGS" | sed 's/^/       /'
  CRITICAL=1
else
  ok "No NVIDIA packages on host"
fi

MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "$MEM_AVAIL_KB" -gt $((VM_MEM * 1024 * 2)) ]; then
  ok "Enough free RAM for ${VM_MEM}MB VM"
else
  warn "Low free RAM"
fi

echo
if [ "$CRITICAL" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  fail "Critical checks failed. Fix them or use --force."
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  ok "Checks finished. No changes made."
  exit 0
fi

# Explicit continue prompt
echo
read -r -p "Checks done. Continue and apply changes? [y/N] " CONTINUE
[[ "$CONTINUE" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# APPLY CHANGES
# =============================================================================
say "Applying configuration"

if [ -f /etc/kernel/cmdline ]; then
  if ! grep -q "iommu=pt" /etc/kernel/cmdline; then
    ask "Add IOMMU options to /etc/kernel/cmdline?" && sed -i "1 s/$/ $IOMMU_OPTS/" /etc/kernel/cmdline
  else ok "IOMMU already in cmdline"; fi
else
  if ! grep -q 'iommu=pt' /etc/default/grub; then
    ask "Add IOMMU options to GRUB?" && sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_OPTS\"/" /etc/default/grub
  else ok "IOMMU already in GRUB"; fi
fi

if [ -n "$NV_PKGS" ]; then
  ask "Purge host NVIDIA packages?" && { apt-get purge -y $NV_PKGS; apt-get autoremove -y; }
fi

say "vfio-pci"
VFIO_CONF=/etc/modprobe.d/vfio.conf
WANT="options vfio-pci ids=$IDS disable_vga=1"
if ! grep -qs "ids=$IDS" "$VFIO_CONF" 2>/dev/null; then
  if ask "Write vfio.conf?"; then
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
    ok "vfio written"
  fi
else
  ok "vfio already set"
fi

if ask "Rebuild initramfs + update bootloader?"; then
  update-initramfs -u -k all
  for k in /boot/vmlinuz-*; do
    v=${k#/boot/vmlinuz-}
    [ -f "/boot/initrd.img-$v" ] || update-initramfs -c -k "$v"
  done
  if [ -f /etc/kernel/proxmox-boot-uuids ]; then proxmox-boot-tool refresh; else update-grub; fi
fi

say "PCI mapping"
SUBSYS=$(cat /sys/bus/pci/devices/$MAIN/subsystem_vendor 2>/dev/null | sed 's/0x//'):$(cat /sys/bus/pci/devices/$MAIN/subsystem_device 2>/dev/null | sed 's/0x//')
MAP_ENTRY="id=$VGA_ID,iommugroup=$GROUP,node=$NODE,path=$GPU_SLOT,subsystem-id=$SUBSYS"
if pvesh get /cluster/mapping/pci/$MAP_ID >/dev/null 2>&1; then
  ask "Update mapping '$MAP_ID'?" && pvesh set /cluster/mapping/pci/$MAP_ID --map "$MAP_ENTRY" --description "NVIDIA GPU"
else
  ask "Create mapping '$MAP_ID'?" && pvesh create /cluster/mapping/pci --id "$MAP_ID" --map "$MAP_ENTRY" --description "NVIDIA GPU"
fi

say "Attach GPU to a VM?"
if [ -z "$VMID" ]; then
  echo "Existing VMs:"
  qm list | awk 'NR>1 {printf "  %s  %s\n", $1, $2}'
  echo
  read -r -p "Enter VMID to configure (or press Enter to skip): " VMID
fi

if [ -n "$VMID" ]; then
  if ! qm status "$VMID" >/dev/null 2>&1; then
    warn "VM $VMID does not exist. Skipping."
  else
    if ask "Set VM $VMID to q35 + OVMF + ${VM_MEM}MB balloon=0 + hostpci0=mapping=$MAP_ID,pcie=1?"; then
      qm set "$VMID" --machine q35 --bios ovmf --memory "$VM_MEM" --balloon 0 --cpu host --hostpci0 "mapping=$MAP_ID,pcie=1" || true
      ok "VM $VMID updated"
    fi
  fi
else
  ok "Skipped VM configuration"
fi

# =============================================================================
# FORCE BIND (load module first)
# =============================================================================
say "Verifying and forcing vfio binding"
modprobe vfio-pci 2>/dev/null || true
if [ ! -d /sys/bus/pci/drivers/vfio-pci ]; then
  warn "vfio-pci module not loaded yet. Reboot first, then re-run the script or check with lspci."
else
  for f in "${FUNCS[@]}"; do
    drv=$(basename "$(readlink -f /sys/bus/pci/devices/$f/driver 2>/dev/null)" 2>/dev/null || echo none)
    if [ "$drv" != "vfio-pci" ]; then
      warn "$f is using $drv — forcing to vfio-pci"
      [ -d "/sys/bus/pci/drivers/$drv" ] && echo "$f" > /sys/bus/pci/drivers/$drv/unbind 2>/dev/null || true
      echo "$f" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
      sleep 0.5
      newdrv=$(basename "$(readlink -f /sys/bus/pci/devices/$f/driver 2>/dev/null)" 2>/dev/null || echo none)
      if [ "$newdrv" = "vfio-pci" ]; then
        ok "$f now on vfio-pci"
      else
        fail "$f still on $newdrv (reboot may be required)"
      fi
    else
      ok "$f already on vfio-pci"
    fi
  done
fi

say "Done"
echo "Reboot when ready. Local screen goes blank after ramdisk (no iGPU) — use the web UI."
echo "After reboot: lspci -nnk -s $GPU_SLOT   (should show vfio-pci on all functions)"
