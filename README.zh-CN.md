# ad103-win-uefi-port — RTX 4080 16 GB（AD103）+ 华擎 Z390，Windows 11

[English](README.md) | **简体中文**

把一套已有的 UEFI 张量算力解锁，移植到一台此前没有公开记录的机器上的完整记录：

**零售版 RTX 4080 16 GB（`10de:2704`）+ 华擎 Z390 Taichi + Windows 11**，无核显，由第二张显卡负责显示。

> **本仓库不包含任何原创的解锁方法。** 解锁本身（权限掩码提权、四段 PLM 链、SS0/SS1 选择器写入）
> 来自上游：[TOTORONG](https://huggingface.co/TOTORONG/AD103_win_unlocker)、
> [JustAResearcher](https://github.com/JustAResearcher/gpu-unlock-ada)、
> [Zagitta](https://github.com/Zagitta/gpu-unlock)。
> 这里提供的是：移植、失败归因、以及实测数据。

---

## 结果

| 负载（torch，原生 Windows，4096³，三次中位数） | 解锁前 | 解锁后 | 变化 |
|---|---:|---:|---:|
| FP32 GEMM | 35.49 TFLOPS | 35.48 TFLOPS | — |
| **FP16 → FP32 累加** | **91.93** | **174.35** | **+89.7%** |
| **BF16 → FP32 累加** | **91.94** | **176.20** | **+91.6%** |

```
冷态：FEAT_PLM=0xffffff8f  SS0=0x56114027  SS1=0x0  WPR2_HI=0
之后：SS0=0x88888888       SS1=0x8        两项均 matched=1，且通过 PCIe FLR 后保持
```

**什么不会变快：** fp8 / int8 / GGUF 量化推理。本机实测：fp8 视频工作流暖态 312.5 秒，
而解锁前同机记录是 270.9–279.9 秒。收益只落在 bf16/fp16 计算密集型任务上——GEMM、LoRA 训练、
LLM 预填充。

---

## 环境

| 项目 | 值 |
|---|---|
| 显卡 | RTX 4080 16 GB，`10de:2704`，子系统 `6688:2704` |
| 芯片 | `193000a1` |
| BDF | `0000:04:00.0`（CPU 第二条 PEG，`00:01.1`） |
| BAR0 | `0xB1000000`，长度 `0x1000000` |
| 功耗墙 | 默认 340 W（上限 400 W） |
| CPU | 6 核 12 线程 Intel 工程样品，**无核显** |
| 主板 | 华擎 Z390 Taichi，CSM 关闭，主显示 = PCIE |
| 显示卡 | Radeon RX Vega（`1002:687f`） |
| 系统 / 驱动 | Windows 11（26100）/ NVIDIA 617.42 |

本机实测的 PROM 视图（BAR0 + `0x300000`，`0xd6c00` 字节）：

```
sha256 95cb1464e5312e03ffe904b73ce8ab33a1766520d0849b403aa595570670ed9f
```

**这个哈希是需要你自行测量的值，不是可以照抄的值。**

---

## 为什么朴素移植在这块板上必然失败

完整分类见 [`docs/FAILURE-LOG.zh-CN.md`](docs/FAILURE-LOG.zh-CN.md)。简述：

本板固件会初始化目标显卡，并让自己的驱动一直绑定着它。只放宽准入检查的移植会"跑完事务"，
但引擎返回 `0xbadf5620`、`WPR2` 始终为 0——与 `impacifist/Windows-GPU-UNLOCK#54` 同一签名。
需要的是**定向释放**这个绑定，而不是绕过检查。

---

## 七处适配

详见 [`docs/PORT-NOTES.zh-CN.md`](docs/PORT-NOTES.zh-CN.md)。补丁：
[`patches/all-7-adaptations.patch`](patches/all-7-adaptations.patch)。

| # | 文件 | 改动 |
|---|---|---|
| 1 | `port.h` | 子系统 ID → `0x27046688` |
| 2 | `checks.c` | 去掉 `Bus == 1` |
| 3 | `port.c` | 去掉 `B == 1` |
| 4 | `app.c` `BarCheck` | `AddrRangeMax` 接受 `0xb1ffffff` |
| 5 | `app.c` `PromCheck` | 固件 `RomImage` 哈希仅记录不阻断 |
| 6 | `prom_profile.h` | PROM 视图哈希 → 实测值 |
| 7 | `ownership.c` | 断开后按 BDF 重新枚举并取回 `PciIo` |

另有两处 MSVC 编译修正（`__atomic_thread_fence`、`void *` 指针算术），见移植笔记。

> 这些都是**本机专属**值。照抄到别的机器，轻则准入失败，重则让某个检查"通过"但已失去原有意义。

---

## 仓库结构

```
README.md / README.zh-CN.md        英文 / 中文总览
docs/PORT-NOTES.md / .zh-CN.md      七处适配（含代码与理由）
docs/FAILURE-LOG.md / .zh-CN.md     五类失败归因
build/Build-Unlock.ps1              MSVC 构建脚本（不需要 Zig）
patches/                            对上游源码的补丁
NOTICE.md                           许可证与来源
```

刻意不包含的内容：EFI 二进制、NVIDIA 固件资产、任何 VBIOS/PROM 转储。

---

## 构建

需要上游源码树（`TOTORONG/AD103_win_unlocker` 或你所基于的版本），以及安装了 C++ 工作负载的
Visual Studio 2022。

```powershell
# 在仓库根目录，上游源码放在 .\source
powershell -ExecutionPolicy Bypass -File .\build\Build-Unlock.ps1 -Root (Get-Location).Path
```

脚本通过 `vswhere` 定位 `vcvars64.bat`，以 `/std:c11 /O1 /GS- /GR-` 编译，并用
`/subsystem:efi_application /entry:EfiMain /nodefaultlib /machine:x64` 链接。

五个固件资产必须由你在本地从固定版本的驱动包生成，本仓库不分发。

---

## 限制

- **易失**：断电即失效，每次冷启动需跑一次 UEFI 程序（约 1 分钟）。
- **运行期间显示器线必须在目标卡上**（显示预检要求目标卡上恰好有 1 个 GOP）。之后可挪回，
  能腾出 1–2 GB 显存。
- **量化推理基本无收益**，见上表。
- **16 GB 是硬天花板**：19.9 GB 的模型装不下，改选择器解决不了换入换出。
- 与参考报告的数字差异（182.80 / 184.49）：本机 174.35 / 176.20（−4.6%），且本机功耗墙更高，
  所以更可能是测量环境差异（对方 WSL2，本机原生 Windows）。同量级，不是排名。
- 长时稳定性与热行为未做表征。

---

## 风险

在任何操作系统驱动加载之前执行的特权固件代码。可能挂死显卡或整机、导致无法启动、损坏状态。
若出现 STOP，请断电，不要复位。

---

## 来源

由仓库作者在 AI agent（OpenClaw + DeepSeek）辅助下完成移植与测量：agent 负责日志分析、
补丁编写、构建编排；所有物理操作由人工完成。两天工作的运行时统计：779 轮、输入 3,590 万 token、
输出 59 万 token、约 10 美元 API 费用，累计约 24 次上电循环。

**本仓库所有数字均为实机测量，无模型生成内容。**
