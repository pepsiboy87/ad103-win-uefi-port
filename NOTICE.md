# NOTICE — provenance and licensing

## What this repository is

A port report and patch set for running an existing UEFI tensor-rate unlock on one specific machine:

- GPU: RTX 4080 16 GB, `10de:2704`, subsystem `6688:2704`
- Board: ASRock Z390 Taichi
- OS: Windows 11 (26100), NVIDIA 617.42
- CPU: 6-core/12-thread Intel engineering sample (no iGPU)

It does not introduce a new unlock method.

## Upstream work

| Project | Role | License |
|---|---|---|
| [`TOTORONG/AD103_win_unlocker`](https://huggingface.co/TOTORONG/AD103_win_unlocker) | AD103 UEFI implementation, payload research, debug-booter analysis | code GPL-2.0; narrative docs CC BY-NC 4.0 |
| [`JustAResearcher/gpu-unlock-ada`](https://github.com/JustAResearcher/gpu-unlock-ada) | AD102 evidence, pinned firmware generators | see upstream |
| [`Zagitta/gpu-unlock`](https://github.com/Zagitta/gpu-unlock) | transaction lineage (V67/PLM technique) | GPL-2.0 |
| [`impacifist/Windows-GPU-UNLOCK`](https://github.com/impacifist/Windows-GPU-UNLOCK) | UEFI→Windows handoff reference, `0xbadf5620` signature | see upstream |
| [`Goldlionren/gpu-unlock-4080s`](https://github.com/Goldlionren/gpu-unlock-4080s) | signing/db enrollment reference | see upstream |

The analysis in `docs/` was written independently for this port. No upstream narrative documentation
or disassembly excerpt is copied here.

## What is deliberately not distributed

- EFI binaries (`BOOTX64.EFI` or any build output)
- NVIDIA firmware assets (`v67-*.bin`, `gsp_*.bin`, `booter_load_*.bin`)
- VBIOS or PROM dumps of any card
- Full run logs (only trimmed excerpts appear in the docs)

The five firmware assets must be generated locally from the pinned driver package using the upstream
tooling. The PROM hash in `docs/PORT-NOTES.md` is a measured value that identifies one card's firmware;
it is documentation, not a distributable artifact.

## Patches

`patches/all-7-adaptations.patch` is a diff against the upstream source tree and is provided under the
same license as that tree (GPL-2.0 for the UEFI code). Retain upstream notices when redistributing.

## Trademarks and compliance

NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation. This repository is unaffiliated with
NVIDIA. Modifying firmware-level behaviour may conflict with NVIDIA's terms of service; that risk is
the operator's. Nothing here is offered as a service, and no warranty of any kind is given.

## Measured, not generated

All performance numbers in this repository were measured on the physical card described above. The
AI-assisted workflow used to get there is documented in the README for transparency, but no result in
this repository is model-generated.
