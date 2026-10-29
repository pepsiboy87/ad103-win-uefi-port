# 失败归因 — 五类问题，约 24 次上电

[English](FAILURE-LOG.md) | **简体中文**

第一次尝试用的是另一套 Windows 移植版本，始终没能跑通。这里不复述每次重启，而是把失败归类：
现象是什么、最终意味着什么、得出的结论是什么。调试类似主板的同学应该能在自己的日志里对上号。

背景：本板固件会在程序运行前就**初始化目标显卡**——入口命令寄存器已经是 `0x3`，属性 `0x300`，
PCI 句柄上挂着一个 `BY_DRIVER`。

---

## 第 1 类 — 身份解析被判为无效（总线写死）

**现象**

```
target BDF=0:4:0.0 checks=0 pm=0 pcie=0 msi=0 msix=0
CHECK stage=target status=0x8000000000000003
```

配置空间每一个字段都是对的，能力解析却返回空。

**诊断** — 能力解析的第一行是 `Bus != 1 → return FALSE`，而本卡在总线 4。

**结论** — 总线号是固件分配的，不属于显卡身份。约束段/设备/功能即可，歧义交给"唯一匹配"规则。

**坑** — 同一个假设存在于**两处**（`checks.c` 用于预检，`port.c` 用于释放后重取）。
只改第一处，会在后面产生更难懂的失败。

---

## 第 2 类 — 还没开始就被占用检查拦下

**现象**

```
admission={"reason":"owners_before", …, "owners":{"driver":1,…}}
```

**诊断** — 固件驱动合法地占着这个设备。把"无占用"当关卡，在这块板上永远过不去。

**结论** — 这类机器的关卡设计本身就不对。设备需要被**释放**（见第 3 类），而不只是被检查。

---

## 第 3 类 — 断开驱动把固件挂死

**现象** — 屏幕停在确认提示之后，再无任何输出。

**诊断** — `DisconnectController(handle, NULL, NULL)` 会断开绑定在该句柄上的**所有**驱动，
包括 PCI 总线绑定。固件随即挂死。

**结论** — 只断开持有 `BY_DRIVER` 的那个 agent：

```c
Gu.bs->DisconnectController(handle, agent, NULL);
```

并且要在 `RaiseTPL(TPL_NOTIFY)` 下进行，先把 `Gu.pci = NULL`，避免拆卸过程中解引用失效的协议指针。
定向断开在这块板上返回 `status=0`——同一个固件，NULL 形式会挂死。

**注意** — 这一步之后设备句柄可能被销毁，那是第 7 类要解决的问题。

---

## 第 4 类 — 状态关卡钉在参考机器上

**现象**

```
bar0 descriptor: … min=0xb1000000 max=0xb1ffffff length=0x1000000
CHECK stage=bar0 status=0x8000000000000003

live PROM view hash matched=0 expected=b5c287c6…   （早期一次错误猜测）
```

**诊断** — 四个常量：BAR 基址、BAR 上界、两个固件哈希。全部属于参考卡。

**结论** — 这些都是每台机器各不相同的值，应当从自己的日志里**读出**而不是猜：

- `bar0 descriptor:` 一行给出 min/max/length；
- 校验失败时的 `PROM verified view [0,0xd6c00) … SHA256=` 给出正确的 PROM 哈希。

不要在这里反复猜，程序会把算出来的值打印给你。

---

## 第 5 类 — 事务跑了，引擎不认

**现象**

```
ARMED: one FWSEC/SEC2 transaction
FWSEC register: reg=0x110104 value=0xbadf5620 sentinel_like=1   （连续 13 个）
FWSEC result: scratch=0 expected_hi16=0
TRANSACTION OUTCOME: result=0 firmware_started=1 required_plm=1 all_plm=0
```

选择器写进去了（`SS0=0x88888888`、`SS1=0x8`），但性能通道没有打开，GEMM 仍然是 91.93 TFLOPS。

**诊断** — 引擎启动时设备仍被固件占用，访问权并不真正属于我们，于是寄存器读回哨兵值，什么都没执行。

**结论** — 这与 `impacifist/Windows-GPU-UNLOCK#54` 报的签名相同
（"AD103：UEFI/DXE 在 FWSEC 处挂 0xbadf5620，而同一序列在 Linux 下成功"）。
本机的解法不是削弱事务，而是修好释放路径：TPL 下快照 → 定向断开 → 重取 `PciIo` →
独占接管 → 只恢复被清掉的解码位 → 再跑一遍全部预检 → 才开始。

---

## 第 6 类（补充）— 释放后的重新取回

**现象**

```
driver release: status=0 refresh=0x8000000000000003 same_pci=0
CHECK stage=driver-release status=0x8000000000000003
FINAL … driver_release=1 clean=0 pci_available=0
```

**诊断** — 断开是成功的；句柄没了。驱动被移除后，对旧句柄调用 `HandleProtocol` 不可能成功。

**结论** — 重新枚举 `PciIo` 句柄并匹配记录的 BDF。细节见
[`PORT-NOTES.zh-CN.md`](PORT-NOTES.zh-CN.md#7--ownershipc断开后重新取回-pciio)。

---

## 最终走通的链路

```
CHECK stage=target           status=0
CHECK stage=display          status=0    GOP physical=1 target=1
CHECK stage=ownership        status=0
CHECK stage=config-recheck   status=0
CHECK stage=bar0             status=0
CHECK stage=cold-state       status=0
CHECK stage=prom             status=0
CHECK stage=assets           status=0
CHECK stage=windows-preload  status=0
driver release: status=0 refresh=0 same_pci=1
全部 *-after-release 检查      status=0
ARMED → PLM（WPR_CFG/WPR/FEAT 匹配，FBPA 非致命）→ SS0/SS1 匹配
PCIe FLR → GOP 重连 → 交接给 Windows
FINAL status=0 stage=post-unlock-handoff
```

## 走到这里的代价

约 24 次上电循环：约 14 次花在第一套移植上（全部落在上面某一类），另外约 10 次用于收敛释放路径
和四个每机不同的值。每次循环约 5 分钟实际时间，外加一次断电。

如果你也要做同样的事：第一次开机之前先读 `docs/PORT-NOTES.zh-CN.md`，
并且把上游源码里的每一个常量都当成"关于他们那台机器的断言"。
