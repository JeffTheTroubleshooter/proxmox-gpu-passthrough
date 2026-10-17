#!/usr/bin/env bash
# =============================================================================
# setup-gpu-passthrough.sh  -  Proxmox VE GPU passthrough backup / rebuild script
# Written by Prox for Jeffrey, 2026-10-17, from the setup that worked on
# host "proxmox" (10.0.0.210): i7-9700F (no iGPU), RTX 2060 SUPER at 0000:01:00,
# PVE 9.2 / kernel 7.0.14-23-pve, VM 102 "jex-server" (Ubuntu 26.04 + Ollama).
#
# RUN ON THE PROXMOX HOST AS ROOT (web UI > node > Shell):
#   bash setup-gpu-passthrough.sh            # interactive, asks before changes
#   bash setup-gpu-passthrough.sh --check    # read-only report, changes nothing
#   bash setup-gpu-passthrough.sh --vm 102   # also attach the GPU to VM 102
#   GPU_SLOT=0000:01:00 bash setup-gpu-passthrough.sh   # pick a GPU by slot
#
# What it does (host side):
#   1. Finds the NVIDIA GPU and ALL its functions (VGA, audio, USB, USB-C).
#   2. Makes sure IOMMU is on in the kernel cmdline (GRUB or systemd-boot).
#      It does NOT add pcie_aspm=off (that hung kernel 7.0.14-20 on this box).
#   3. Purges any NVIDIA driver installed ON THE HOST (a broken nvidia DKMS
#      build left kernel 7.0.14-23 without an initrd -> kernel panic).
#   4. Binds every GPU function to vfio-pci at boot (modprobe.d + softdeps).
#   5. Rebuilds initramfs, and VERIFIES every installed kernel has an initrd
#      before you reboot.
#   6. Creates/updates the cluster PCI mapping "GPU" as the whole card.
#   7. Optionally sets the VM's hostpci0 / q35 / OVMF / no-balloon options.
# It never reboots by itself.
#
# Lessons learned (2026-10-16/17):
#   - Pass the WHOLE card (path without .0) - passing only 01:00.0 gave
#     "GPU has fallen off the bus" in the guest.
#   - If the host's xhci_hcd keeps 01:00.2 you get "error getting device from
#     group 1: Invalid argument" -> the vfio-pci ids bind below fixes it.
#   - Passthrough VMs pin ALL their RAM. Host has 8.2 GB: VM at 6 GB caused a
#     host OOM and froze the API. 4 GB works (host keeps ~1.8 GB free).
#   - No iGPU: after "Loading initial ramdisk" the host monitor goes blank.
#     That is normal - use the web UI. GRUB menu is still visible at boot.
#   - If a kernel panics with "unable to mount root fs on unknown-block(0,0)",
#     its initrd is missing: boot an older kernel from GRUB > Advanced options,
#     then run: update-initramfs -c -k <version> && update-grub
#   - Inside the guest: install the NVIDIA driver there (ubuntu-drivers install),
#     not on the host. Guest driver 595-open + Ollama got ~64 tok/s qwen3:8b.
# =============================================================================
set -euo pipefail

CHECK_ONLY=0; VMID=""; MAP_ID="${MAP_ID:-GPU}"; VM_MEM="${VM_MEM:-4096}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --vm) VMID="$2"; shift ;;
    --map-id) MAP_ID="$2"; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac; shift
done

say(){ printf '\n\033[1;31m==>\033[0m %s\n' "$*"; }
ok(){ printf '   \033[32mOK\033[0m %s\n' "$*"; }
warn(){ printf '   \033[33mWARN\033[0m %s\n' "$*"; }
ask(){ [ "$CHECK_ONLY" = 1 ] && return 1; read -r -p "   $1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }

[ "$(id -u)" = 0 ] || { echo "Run as root on the Proxmox host."; exit 1; }
command -v pveversion >/dev/null || { echo "This is not a Proxmox host."; exit 1; }
NODE=$(hostname)

# --- 1. Find the GPU ---------------------------------------------------------
say "1. Finding the GPU"
if [ -z "${GPU_SLOT:-}" ]; then
  GPU_SLOT=$(lspci -Dnn | awk '/\[10de:/ && /VGA|3D/ {print $1; exit}' | sed 's/\.[0-9]$//')
fi
[ -n "$GPU_SLOT" ] || { echo "No NVIDIA GPU found. Set GPU_SLOT=0000:BB:DD"; exit 1; }
mapfile -t FUNCS < <(lspci -Dnn -s "$GPU_SLOT" | awk '{print $1}')
IDS=""
for f in "${FUNCS[@]}"; do
  id=$(lspci -n -s "$f" | awk '{print $3}')
  drv=$(basename "$(readlink -f /sys/bus/pci/devices/$f/driver 2>/dev/null)" 2>/dev/null || echo none)
  grp=$(basename "$(readlink -f /sys/bus/pci/devices/$f/iommu_group 2>/dev/null)" 2>/dev/null || echo "?")
  printf '   %s  %s  iommu_group=%s  driver=%s  %s\n' "$f" "$id" "$grp" "$drv" "$(lspci -s "$f" | cut -d' ' -f2-)"
  IDS="${IDS:+$IDS,}$id"
done
MAIN="${FUNCS[0]}"
VGA_ID=$(lspci -n -s "$MAIN" | awk '{print $3}')
SUBSYS=$(cat /sys/bus/pci/devices/$MAIN/subsystem_vendor 2>/dev/null | sed 's/0x//'):$(cat /sys/bus/pci/devices/$MAIN/subsystem_device 2>/dev/null | sed 's/0x//')
GROUP=$(basename "$(readlink -f /sys/bus/pci/devices/$MAIN/iommu_group)" 2>/dev/null || echo "")
echo "   GPU slot $GPU_SLOT, vfio ids: $IDS"

# --- 2. IOMMU ----------------------------------------------------------------
say "2. IOMMU"
CPU_VENDOR=$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
[ "$CPU_VENDOR" = "GenuineIntel" ] && IOMMU_OPTS="intel_iommu=on iommu=pt" || IOMMU_OPTS="iommu=pt"
echo "   running cmdline: $(cat /proc/cmdline)"
if [ -d /sys/kernel/iommu_groups ] && [ "$(ls /sys/kernel/iommu_groups | wc -l)" -gt 0 ]; then
  ok "IOMMU active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
else
  warn "IOMMU not active - also check VT-d / AMD-Vi is enabled in BIOS"
fi
if [ -n "$GROUP" ]; then
  echo "   devices in GPU's group $GROUP:"; ls /sys/kernel/iommu_groups/$GROUP/devices | sed 's/^/     /'
fi
if [ -f /etc/kernel/cmdline ]; then
  BOOTFILE=/etc/kernel/cmdline   # systemd-boot (ZFS / proxmox-boot-tool)
  grep -q "iommu=pt" $BOOTFILE && ok "$BOOTFILE has iommu options" || {
    warn "$BOOTFILE is missing: $IOMMU_OPTS"
    ask "Add '$IOMMU_OPTS' to $BOOTFILE?" && sed -i "1 s/\$/ $IOMMU_OPTS/" $BOOTFILE; }
else
  BOOTFILE=/etc/default/grub
  grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=.*iommu=pt' $BOOTFILE && ok "GRUB has iommu options" || {
    warn "GRUB_CMDLINE_LINUX_DEFAULT is missing: $IOMMU_OPTS"
    ask "Add '$IOMMU_OPTS' to GRUB?" && sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_OPTS\"/" $BOOTFILE; }
  grep -q pcie_aspm=off $BOOTFILE && warn "pcie_aspm=off is set - it hung kernel 7.0.14-20 here; consider removing it"
fi

# --- 3. Host NVIDIA driver ---------------------------------------------------
say "3. NVIDIA driver on the host (should be none)"
NV_PKGS=$(dpkg -l | awk '/^i/ && /nvidia|libcuda1|libnvcuvid1/ {print $2}' | grep -v pve-nvidia-vgpu-helper || true)
if [ -n "$NV_PKGS" ]; then
  warn "host has $(echo "$NV_PKGS" | wc -l) NVIDIA packages installed (breaks kernel updates + passthrough)"
  ask "Purge them?" && { apt-get purge -y $NV_PKGS; apt-get autoremove -y; }
else ok "no host NVIDIA packages"; fi
dkms status 2>/dev/null | grep -i nvidia && warn "nvidia still in dkms" || ok "dkms clean"

# --- 4. vfio-pci binding -----------------------------------------------------
say "4. vfio-pci binding"
VFIO_CONF=/etc/modprobe.d/vfio.conf
WANT="options vfio-pci ids=$IDS disable_vga=1"
if grep -qs "ids=$IDS" $VFIO_CONF; then ok "$VFIO_CONF already binds $IDS"
else
  echo "   would write $VFIO_CONF:"; echo "     $WANT"
  if ask "Write $VFIO_CONF and add vfio modules to /etc/modules?"; then
    cat > $VFIO_CONF <<CONF
$WANT
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep xhci_pci pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
softdep i2c_nvidia_gpu pre: vfio-pci
softdep ucsi_ccg pre: vfio-pci
CONF
    for m in vfio vfio_iommu_type1 vfio_pci; do grep -qx $m /etc/modules || echo $m >> /etc/modules; done
    printf 'blacklist nouveau\nblacklist nvidiafb\n' > /etc/modprobe.d/blacklist-gpu-host.conf
    ok "written"
  fi
fi

# --- 5. initramfs + boot entries, then VERIFY --------------------------------
say "5. initramfs and boot loader"
if ask "Rebuild initramfs for all kernels and refresh the boot loader?"; then
  update-initramfs -u -k all
  for k in /boot/vmlinuz-*; do v=${k#/boot/vmlinuz-}
    [ -f /boot/initrd.img-$v ] || { echo "   creating missing initrd for $v"; update-initramfs -c -k "$v"; }
  done
  [ -f /etc/kernel/proxmox-boot-uuids ] && proxmox-boot-tool refresh || update-grub
fi
BAD=0
for k in /boot/vmlinuz-*; do v=${k#/boot/vmlinuz-}
  if [ -f /boot/initrd.img-$v ]; then ok "kernel $v has initrd ($(du -h /boot/initrd.img-$v | cut -f1))"
  else warn "kernel $v has NO initrd - it will panic. Fix: update-initramfs -c -k $v"; BAD=1; fi
done

# --- 6. Cluster PCI mapping (whole card) -------------------------------------
say "6. PCI mapping '$MAP_ID' (whole card, all functions)"
MAP_ENTRY="id=$VGA_ID,iommugroup=$GROUP,node=$NODE,path=$GPU_SLOT,subsystem-id=$SUBSYS"
echo "   entry: $MAP_ENTRY"
if pvesh get /cluster/mapping/pci/$MAP_ID >/dev/null 2>&1; then
  ask "Update existing mapping '$MAP_ID' to the whole card?" && \
    pvesh set /cluster/mapping/pci/$MAP_ID --map "$MAP_ENTRY" --description "NVIDIA GPU (all functions)"
else
  ask "Create mapping '$MAP_ID'?" && \
    pvesh create /cluster/mapping/pci --id "$MAP_ID" --map "$MAP_ENTRY" --description "NVIDIA GPU (all functions)"
fi

# --- 7. VM settings (optional) ------------------------------------------------
if [ -n "$VMID" ]; then
  say "7. VM $VMID settings"
  qm config "$VMID" | grep -E '^(machine|bios|efidisk0|memory|balloon|hostpci)' || true
  if ask "Set VM $VMID to q35 + OVMF + ${VM_MEM} MB (no balloon) + hostpci0=mapping=$MAP_ID,pcie=1?"; then
    qm config "$VMID" | grep -q '^efidisk0' || warn "VM has no efidisk0 - add one (Hardware > Add > EFI Disk) before booting OVMF"
    qm set "$VMID" --machine q35 --bios ovmf --memory "$VM_MEM" --balloon 0 --cpu host \
                   --hostpci0 "mapping=$MAP_ID,pcie=1"
    ok "VM $VMID updated (stop/start the VM, not just reboot the guest)"
  fi
fi

# --- Summary -----------------------------------------------------------------
say "Done"
[ "$BAD" = 1 ] && warn "Some kernels have NO initrd - fix that BEFORE rebooting!"
cat <<TXT
   Next steps:
   - Reboot the host when ready. The monitor goes blank after "Loading initial
     ramdisk" (no iGPU) - that's expected; use https://<host>:8006.
   - After reboot check:  journalctl -b | grep -i vfio    (should list $IDS)
                          lspci -nnk -s $GPU_SLOT         (driver in use: vfio-pci)
   - In the guest:  sudo ubuntu-drivers install && sudo reboot ; nvidia-smi
   - If the guest logs "Xid 79 / fallen off the bus": stop+start the VM from
     Proxmox, check the card's power cable/seating and BIOS PCIe slot = Auto/Gen3.
TXT
