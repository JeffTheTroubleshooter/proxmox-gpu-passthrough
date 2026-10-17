# proxmox-gpu-passthrough

A backup and rebuild script for GPU passthrough on Jeffrey's Proxmox VE host. It covers an RTX 2060 SUPER passed to a VM with vfio-pci and IOMMU, mapped as the whole card. It was written from the setup that worked on 2026-10-17. The header of the script has all the notes and lessons learned.

## What it does

1. Finds the NVIDIA GPU and all of its functions (VGA, audio, USB, USB-C).
2. Makes sure IOMMU is on in the kernel command line (GRUB or systemd-boot).
3. Removes any NVIDIA driver installed on the host. The driver belongs in the guest.
4. Binds every GPU function to `vfio-pci` at boot.
5. Rebuilds the initramfs and checks that every installed kernel has an initrd before you reboot.
6. Creates or updates the cluster PCI mapping `GPU` as the whole card.
7. Optionally sets the VM's `hostpci0`, q35, OVMF and no-balloon options.

It never reboots by itself.

## How to run

Run it on the Proxmox host as root. You can open a root shell from the web UI under node > Shell.

```bash
bash setup-gpu-passthrough.sh --check    # read-only report, changes nothing
bash setup-gpu-passthrough.sh            # interactive, asks before each change
bash setup-gpu-passthrough.sh --vm 102   # also attach the GPU to VM 102
GPU_SLOT=0000:01:00 bash setup-gpu-passthrough.sh   # pick a GPU by PCI slot
bash setup-gpu-passthrough.sh --help     # show the header notes
```

Other options are `--map-id <name>` (the default is `GPU`) and `VM_MEM=<MB>` (the default is 4096). A passthrough VM pins all of its RAM, so leave the host enough memory.

## Notes

- Pass the whole card, using the path without `.0`. Passing only the `.0` function caused "GPU has fallen off the bus".
- The host has no iGPU, so the monitor goes blank after "Loading initial ramdisk". That's normal; use the web UI.
- Install the NVIDIA driver inside the guest (`ubuntu-drivers install`), not on the host.
