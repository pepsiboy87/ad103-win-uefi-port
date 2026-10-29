# ad103-win-uefi-port — RTX 4080 16 GB (AD103) + ASRock Z390, Windows 11

A reproducible record of porting an existing UEFI tensor-rate unlock to a machine nobody had
documented: a retail **RTX 4080 16 GB (`10de:2704`)** on an **ASRock Z390 Taichi** running
**Windows 11**, with no iGPU and a second GPU providing the console.

> **This repository does not contain an unlock method of its own.** The unlock (permission-mask
> elevation, the four-PLM chain, the SS0/SS1 selector writes) is upstream work by
> [TOTORONG](https://huggingface.co/TOTORONG/AD103_win_unlocker),
> [JustAResearcher](https://github.com/JustAResearcher/gpu-unlock-ada) and
> [Zagitta](https://github.com/Zagitta/gpu-unlock).
> What is here: a port, a failure taxonomy, and measured numbers.

---

## Result

| Workload (torch, native Windows, 4096³, median of 3) | Stock | Unlocked | Delta |
|---|---:|---:|---:|
| FP32 GEMM | 35.49 TFLOPS | 35.48 TFLOPS | — |
| **FP16 → FP32 accumulate** | **91.93** | **174.35** | **+89.7%** |
| **BF16 → FP32 accumulate** | **91.94** | **176.20** | **+91.6%** |

```
cold  : FEAT_PLM=0xffffff8f  SS0=0x56114027  SS1=0x0  WPR2_HI=0
after : SS0=0x88888888       SS1=0x8        matched=1 (both), survived PCIe FLR
```

**What this does not speed up:** fp8 / int8 / GGUF quantised inference. Measured here: an fp8 video
workflow took 312.5 s warm versus 270.9–279.9 s before the unlock. The gain lives in bf16/fp16
compute-bound work — GEMM, LoRA training, LLM prefill.

---

## Environment

| Item | Value |
|---|---|
| GPU | RTX 4080 16 GB, `10de:2704`, subsystem `6688:2704` |
| Chip | `193000a1` |
| BDF | `0000:04:00.0` (second CPU PEG port, `00:01.1`) |
| BAR0 | `0xB1000000`, length `0x1000000` |
| Power limit | 340 W default (max 400 W) |
| CPU | 6-core / 12-thread Intel engineering sample, **no iGPU** |
| Board | ASRock Z390 Taichi, CSM disabled, primary graphics = PCIE |
| Console GPU | Radeon RX Vega (`1002:687f`) |
| OS / driver | Windows 11 (26100) / NVIDIA 617.42 |

Live PROM view (BAR0 + `0x300000`, `0xd6c00` bytes) measured on this card:

```
sha256 95cb1464e5312e03ffe904b73ce8ab33a1766520d0849b403aa595570670ed9f
```

That hash is a value to **measure**, not a value to copy. A different card will not match it and
should not try to.

---

## Why a naive port does not work here

See [`docs/FAILURE-LOG.md`](docs/FAILURE-LOG.md) for the full taxonomy. The short version:

firmware on this board initialises the target GPU and keeps its own driver bound to it. A port that
only relaxes admission checks runs the transaction but the engine returns `0xbadf5620` and `WPR2` is
never written — the same signature as `impacifist/Windows-GPU-UNLOCK#54`. What is required is a
**targeted release** of that binding, not a bypass of the check.

---

## The seven adaptations

Full detail with code in [`docs/PORT-NOTES.md`](docs/PORT-NOTES.md). Patch:
[`patches/all-7-adaptations.patch`](patches/all-7-adaptations.patch).

| # | File | Change |
|---|---|---|
| 1 | `port.h` | subsystem id → `0x27046688` |
| 2 | `checks.c` | drop `Bus == 1` |
| 3 | `port.c` | drop `B == 1` |
| 4 | `app.c` `BarCheck` | `AddrRangeMax` accepts `0xb1ffffff` |
| 5 | `app.c` `PromCheck` | firmware `RomImage` hash logged, not enforced |
| 6 | `prom_profile.h` | PROM view hash → measured value |
| 7 | `ownership.c` | re-acquire `PciIo` by BDF after disconnect |

Plus two MSVC build fixes (`__atomic_thread_fence`, `void *` arithmetic) documented in PORT-NOTES.

> These are **machine-specific**. Copying them blindly will either abort preflight or make a check
> pass that no longer means anything.

---

## Repository layout

```
docs/PORT-NOTES.md        the seven adaptations, with rationale and code
docs/FAILURE-LOG.md       five failure classes observed while getting there
build/Build-Unlock.ps1    MSVC build script (no Zig required)
patches/                  the patch against the upstream source tree
NOTICE.md                 licensing and provenance
```

Not included, deliberately: no EFI binaries, no NVIDIA firmware assets, no VBIOS/PROM dumps.

---

## Build

Requires the upstream source tree (clone `TOTORONG/AD103_win_unlocker`, or the tree your port is
based on) plus Visual Studio 2022 with the C++ workload.

```powershell
# from the repository root, with the upstream source in .\source
powershell -ExecutionPolicy Bypass -File .\build\Build-Unlock.ps1 -Root (Get-Location).Path
```

The script locates `vcvars64.bat` via `vswhere`, compiles the translation units with
`/std:c11 /O1 /GS- /GR-`, and links with
`/subsystem:efi_application /entry:EfiMain /nodefaultlib /machine:x64`.

The five firmware assets must be generated locally from the pinned driver package; they are not
distributed here.

---

## Limitations

- **Volatile.** Lost on power off; one UEFI run per cold boot (~1 minute).
- **Display cable must be on the target card during the run** — the display preflight requires exactly
  one GOP on the target. It can be moved back afterwards, returning 1–2 GB of VRAM.
- **Quantised inference gains little.** See the table above.
- **16 GB is the ceiling** for a 19.9 GB checkpoint; selectors do not fix offloading.
- Numbers versus the reference report (182.80 / 184.49): this machine measures 174.35 / 176.20
  (−4.6%), with a higher power limit, so the likely difference is measurement environment
  (WSL2 there, native Windows here). Same order, not a ranking.
- Long-run stability and thermal behaviour were not characterised.

---

## Risks

Experimental privileged firmware execution before any OS driver loads. It can hang the GPU or the
host, prevent boot, or corrupt state. Power off — do not reset — if it reports STOP.

---

## Provenance

Ported and measured by the repository owner with an AI agent (OpenClaw + DeepSeek) driving log
analysis, patch authoring and build orchestration; all physical operations were performed by hand.
Runtime accounting for the two days of work: 779 agent turns, 35.9 M new input tokens, 0.59 M output,
≈ US$10 of API usage, across roughly 24 boot cycles.

Every number in this repository was measured on the physical card.

---

## 中文简介

板卡：RTX 4080 16 GB（AD103，`10de:2704`，子系统 `6688:2704`，BDF `00:04:00.0`）
平台：华擎 Z390 Taichi + Windows 11（CSM 关闭，无核显，CPU 为 6C/12T 工程样品）
结果：FP16 91.93 → 174.35 TFLOPS（+89.7%），BF16 91.94 → 176.20（+91.6%），PCIe FLR 后仍保持

三点说明：

1. 解锁方法不是本项目原创，来自 TOTORONG / JustAResearcher / Zagitta 一系；本项目的贡献是在
   没人公开过的机器上跑通，以及"为什么朴素移植必然失败"的归因。
2. 七处改动是本机专属值，照抄到别的机器会失败，务必自己测量。
3. fp8 / int8 / GGUF 量化负载基本无收益；收益集中在 bf16/fp16 计算密集型任务。

代价：易失，每次冷启动需从 U 盘跑一次；解锁期间显示器线必须在目标卡上。
