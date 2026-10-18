# proxmox-gpu-passthrough

Private backup of the GPU passthrough setup that worked on Jeffrey's Proxmox host (RTX 2060 SUPER → Ubuntu 26.04 VM "jex-server").

## Files

- `setup-gpu-passthrough.sh` — Interactive host setup / rebuild script. Run with `--check` first.
- `SETUP-GUIDE.md` — Full step-by-step guide to replicate the working configuration after a clean install, including the exact VM hardware settings from the screenshots and all lessons learned.

## Quick start

On a fresh Proxmox install (or to re-apply):

```bash
bash setup-gpu-passthrough.sh --check
bash setup-gpu-passthrough.sh --vm 102
```

Then follow the guest steps in SETUP-GUIDE.md.

See the script header and the guide for BIOS requirements, why the whole card must be passed, why the host must have no NVIDIA packages, and the kernel/initrd pitfalls we hit.
