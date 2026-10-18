# Proxmox VE GPU Passthrough Setup Guide

This guide documents the exact host and VM configuration that worked for an RTX 2060 SUPER passed through to Ubuntu 26.04 (VM 102 "jex-server") on Proxmox VE 9.2 / kernel 7.0.14-23-pve. It is written so you can replicate it after a clean Proxmox reinstall.

**Hardware notes from this box:**
- CPU: Intel i7-9700F (no iGPU)
- GPU: NVIDIA RTX 2060 SUPER at 0000:01:00 (whole card)
- Host RAM: ~8.2 GB total — VM uses 4 GB pinned (balloon=0)
- Guest: Ubuntu 26.04.1 LTS with NVIDIA driver 595 + Ollama (~64 tok/s on qwen3:8b)

The companion script `setup-gpu-passthrough.sh` automates the host side and asks before every change. Run it with `--check` first.

## 1. Factory Reset / Clean Start

There is **no one-click factory reset** in Proxmox. The only clean way is a full reinstall from the official ISO.

1. Download the latest Proxmox VE ISO from the official site.
2. Backup anything you care about first:
   ```bash
   tar czf /root/pve-backup-$(date +%F).tar.gz /etc/pve /etc/network/interfaces /etc/hosts /etc/hostname
   ```
   Copy the tarball off the box.
3. Boot the ISO, install on the **boot disk only**. Leave any separate data disks unselected so existing VM disks survive.
4. After install, set up networking, storage, and then follow this guide.
5. If you want to restore old VM configs later, copy the `.conf` files back into `/etc/pve/qemu-server/` after storage is re-added.

## 2. BIOS Prerequisites

- Enable VT-d (Intel) or AMD-Vi / IOMMU.
- Disable CSM / Legacy boot (UEFI only).
- Disable Resizable BAR / Smart Access Memory if present.
- Set the PCIe slot for the GPU to Auto or Gen3 (this card only trained at x4).
- Update BIOS if possible.

After reboot, verify:
```bash
dmesg | grep -e DMAR -e IOMMU
ls /sys/kernel/iommu_groups | wc -l   # should be > 0
```

## 3. Host Setup (use the script or do manually)

### Option A — Run the script (recommended)
```bash
bash setup-gpu-passthrough.sh --check          # report only
bash setup-gpu-passthrough.sh --vm 102         # full setup + attach to VM 102
```

### Option B — Manual steps (what the script does)

1. **Find the GPU and all functions**
   ```bash
   lspci -Dnn | grep -i nvidia
   ```
   Note the slot (e.g. `0000:01:00`) and every function (`.0` VGA, `.1` audio, `.2`/`.3` USB).

2. **Enable IOMMU** in `/etc/default/grub` (or `/etc/kernel/cmdline` if using systemd-boot):
   ```
   GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
   ```
   Then `update-grub` or `proxmox-boot-tool refresh`. **Do not** add `pcie_aspm=off` — it hung kernel 7.0.14-20 on this hardware.

3. **Purge any NVIDIA packages from the host** (the driver belongs only in the guest):
   ```bash
   apt purge -y $(dpkg -l | awk '/^i/ && /nvidia|libcuda1|libnvcuvid1/ {print $2}' | grep -v pve-nvidia-vgpu-helper)
   apt autoremove -y
   ```
   A broken host DKMS package previously left a kernel without an initrd → panic.

4. **Bind the whole card to vfio-pci**
   Create `/etc/modprobe.d/vfio.conf`:
   ```
   options vfio-pci ids=10de:XXXX,10de:YYYY,... disable_vga=1
   softdep nouveau pre: vfio-pci
   softdep nvidia pre: vfio-pci
   softdep xhci_pci pre: vfio-pci
   softdep snd_hda_intel pre: vfio-pci
   ```
   Add to `/etc/modules`:
   ```
   vfio
   vfio_iommu_type1
   vfio_pci
   ```
   Blacklist host GPU drivers:
   ```
   echo -e "blacklist nouveau\nblacklist nvidiafb" > /etc/modprobe.d/blacklist-gpu-host.conf
   ```

5. **Rebuild initramfs and verify every kernel has one**
   ```bash
   update-initramfs -u -k all
   update-grub
   ls -la /boot/initrd.img-*
   ```
   Missing initrd = kernel panic on that version.

6. **Create the cluster PCI mapping** (whole card, path without `.0`):
   Use the web UI or `pvesh` so the mapping is named `GPU` and points at the full slot.

Reboot the host. The local monitor goes blank after "Loading initial ramdisk" (no iGPU) — this is normal. Use the web UI at `https://<host>:8006`.

After reboot check:
```bash
lspci -nnk -s 0000:01:00     # Kernel driver in use: vfio-pci
journalctl -b | grep -i vfio
```

## 4. Create / Configure the VM

Matching the working `jex-server` configuration:

- **OS**: Linux 7.x / Ubuntu Server or Desktop ISO
- **Machine**: q35
- **BIOS**: OVMF (UEFI) + EFI Disk
- **CPU**: host, 6 cores (1 socket)
- **Memory**: 4096 MB, Ballooning = 0
- **SCSI Controller**: VirtIO SCSI single
- **Hard Disk**: 80 GB (or larger), VirtIO SCSI, iothread=1, on your storage
- **Network**: VirtIO, bridge=vmbr0
- **Display**: Standard VGA (std) or none once GPU works
- **PCI Device**: Add → Use the `GPU` mapping, PCIe = on
- **CloudInit**: optional
- **Serial**: optional
- **Hotplug**: Disk, Network, USB
- **Start at boot**: your choice

CLI equivalent of the key settings:
```bash
qm set 102 --machine q35 --bios ovmf --cpu host --cores 6 --memory 4096 --balloon 0 \
           --hostpci0 mapping=GPU,pcie=1
```

**Important**: Passthrough VMs pin all RAM. Do not give the VM more than the host can spare (4 GB worked; 6 GB OOM'd the host).

Install the guest OS, then power off and attach the PCI device if you didn't during creation.

## 5. Guest (Ubuntu) Setup

Inside the VM:
```bash
sudo ubuntu-drivers install
sudo reboot
nvidia-smi          # should show the RTX 2060 SUPER
```

Then install Ollama or whatever you need. The working combination was driver 595 + CUDA 13.2.

## 6. Lessons Learned / Troubleshooting

- **Always pass the whole card** (path without `.0`). Passing only the VGA function caused "GPU has fallen off the bus" (Xid 79).
- **No NVIDIA packages on the host.** They fight passthrough and can break kernel updates.
- **Verify initrd for every kernel** before rebooting after changes.
- **Blank host screen after ramdisk** is expected with no iGPU.
- **PCIe link at x4** on this box slows model loading but not generation. Check slot and BIOS if you want full width.
- If the guest sees the GPU then it drops: hard power-cycle the host, reseat the card and power cable, then stop/start the VM from Proxmox (not just reboot the guest).
- Host memory stayed healthy with 4 GB pinned to the VM (~1.8 GB free).

## 7. Verification

- Host: `lspci -nnk` shows `vfio-pci` on all GPU functions.
- Guest: `nvidia-smi` works and stays stable under load.
- Ollama (or your workload) reports CUDA and runs on the GPU.

---

Script and this guide written from the working setup on 2026-10-17. Re-test after any kernel or Proxmox update.
