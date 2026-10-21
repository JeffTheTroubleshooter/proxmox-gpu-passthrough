# proxmox-gpu-passthrough

GPU passthrough setup script for Proxmox VE.

## Hardware

| Component | Spec |
|-----------|------|
| Proxmox   | 9.2.21 |
| Kernel    | 7.0.14-24-pve |
| CPU       | Intel i7-9700F |
| RAM       | 8 GB |
| GPU       | NVIDIA GeForce RTX 2060 SUPER |

## Quick Start

### 1. Get the script

```bash
git clone https://github.com/JeffTheTroubleshooter/proxmox-gpu-passthrough.git
cd proxmox-gpu-passthrough
```

Or download `setup-gpu-passthrough.sh` directly.

### 2. Make it executable

```bash
chmod +x setup-gpu-passthrough.sh
```

### 3. Run the checks (read-only)

```bash
./setup-gpu-passthrough.sh --check
```

This verifies IOMMU, GPU detection, and that no host NVIDIA packages are installed. It changes nothing.

### 4. Run the full setup

```bash
./setup-gpu-passthrough.sh
```

Answer **y** at each prompt. When it asks for a VMID, enter the ID of the VM you want to attach the GPU to (or press Enter to skip).

<img width="513" height="115" alt="VM selection" src="https://github.com/user-attachments/assets/d24e6b21-1146-481a-9f0e-648d068f909b" />

### 5. Reboot and verify

After the script finishes, reboot the host. Then check:

```bash
lspci -nnk -s 0000:01:00
```

All GPU functions should show `Kernel driver in use: vfio-pci`.

<img width="2336" height="848" alt="lrEon" src="https://github.com/user-attachments/assets/4f4e9902-3ca2-4be0-9082-302197fddd43" />

## Remove Passthrough

To fully undo the setup:

```bash
./setup-gpu-passthrough.sh --remove
```

This detaches the GPU from the VM, deletes the PCI mapping, removes the vfio config, and rebuilds initramfs. Reboot afterward.

After reboot the GPU returns to the default host drivers:

- `nouveau` → VGA
- `snd_hda_intel` → audio
- `xhci_hcd` → USB controller
- `nvidia-gpu` → UCSI

<img width="1020" height="375" alt="default drivers" src="https://github.com/user-attachments/assets/c5f80694-d3a9-4d06-b03e-9affe60819a9" />
