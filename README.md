# proxmox-gpu-passthrough

Private backup of the GPU passthrough setup that worked on Jeffrey's Proxmox host (RTX 2060 SUPER → Ubuntu 26.04 VM).

**Always run the checks first** (especially before recording a video or after a clean install):

```bash
bash setup-gpu-passthrough.sh --check     # full read-only verification, exits if critical checks fail
bash setup-gpu-passthrough.sh             # checks, then asks before every change
bash setup-gpu-passthrough.sh --vm 102    # same + configure a VM
```

Critical checks that will stop the script:
- IOMMU must already be active (VT-d / AMD-Vi enabled in BIOS + kernel parameter)
- NVIDIA GPU must be present
- No NVIDIA packages installed on the host

Use `--force` only if you know why a check failed.

See `SETUP-GUIDE.md` for the full manual steps and lessons learned.
