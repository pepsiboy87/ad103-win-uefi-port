# 移植笔记 — RTX 4080 16 GB / 华擎 Z390 / Windows 11

[English](PORT-NOTES.md) | **简体中文**

以下每一处改动，都是因为上游源码里的某个检查写的是"参考机器的属性"，而不是"显卡的属性"。
没有任何一处改变了破解逻辑。

> 这些值都是**本机专属**的，请对自己的硬件重新测量。照抄的后果：轻则准入失败，
> 重则让某个关卡"通过"，但它已经不再表达原来的含义。

---

## 1 — `port.h`：子系统 ID

```diff
-#define GU_BOARD_SUBSYSTEM 0x179510deU
+#define GU_BOARD_SUBSYSTEM 0x27046688U
```

`0x179510de` 是参考卡的子系统（`10de:1795`）。本机是 `6688:2704`，该值出现在配置空间
`0x2c` 与 `0x40` 两处。

---

## 2 — `checks.c` `GuCheckConfig`：总线约束

```diff
-  if (Config == NULL || Segment != 0 || Bus != 1 || Device != 0 || Function != 0)
+  if (Config == NULL || Segment != 0 || Device != 0 || Function != 0)
     return FALSE;
```

参考卡在总线 1；本机目标是固件分配的**总线 4**。总线号不是身份标识。段/设备/功能仍受约束，
且调用方仍要求"唯一匹配"，所以放宽总线不会选错卡。

---

## 3 — `port.c` `GuTargetConfig`：同样的总线约束

```diff
-  return C && !S && B==1 && !D && !F && C[0]==GU_BOARD_ID &&
+  return C && !S && !D && !F && C[0]==GU_BOARD_ID &&
     C[11]==GU_BOARD_SUBSYSTEM && (C[2]>>24)==3 && !((C[3]>>16)&0x7f);
```

**这处最容易漏**：它只在"释放驱动之后重新取设备"时被调用，不在准入阶段。漏掉它就会出现：

```
driver release: status=0 refresh=0x8000000000000003
```

断开明明成功了，却报失败——极具误导性，往往要浪费一个上电循环才能定位。

**如果你的日志里出现 `refresh=…3`，先查这一行。**

---

## 4 — `app.c` `BarCheck`：BAR 上界

```diff
-      r->AddrRangeMin!=0x80000000 || r->AddrLen!=0x1000000 || r->AddrTranslationOffset ||
+      r->AddrRangeMin!=0xB1000000 || r->AddrLen!=0x1000000 || r->AddrTranslationOffset ||
-      (r->AddrRangeMax!=0x80ffffff && r->AddrRangeMax!=0x00ffffff) ||
+      (r->AddrRangeMax!=0xb1ffffff && r->AddrRangeMax!=0x00ffffff) ||
```

`AddrRangeMin` 和 `AddrRangeMax` 都是固件分配的。保留 EDK2 的对齐形式（`0x00ffffff`），
因为 PciBusDxe 可能返回对齐值而不是包含式上界。

本机实测：

```
bar0 descriptor: type=0 granularity=32 min=0xb1000000 max=0xb1ffffff length=0x1000000 translation=0
```

---

## 5 — `app.c` `PromCheck`：固件 `RomImage` 关卡

```diff
-  if(!Gu.pci->RomImage || Gu.pci->RomSize!=0x24c00 ||
-     !GuHashMatches(Gu.pci->RomImage,0x24c00,"c2520432…"))return EFI_CRC_ERROR;
+  /* 固件缓存的 RomImage 是这块板自己的 VBIOS 切片 */
+  if(!Gu.pci->RomImage)GuLogText("PCI RomImage: unavailable; using live PROM only\n");
+  else if(Gu.pci->RomSize!=0x24c00 || !GuHashMatches(…)) {
+    GuLog("PCI RomImage: bytes=%u hash differs from reference (not enforced)\n",…);
+    LogHash("PCI RomImage",Gu.pci->RomImage,(UINTN)Gu.pci->RomSize);
+  }
```

缓存的 `RomImage` 是本板的 VBIOS（本机 150,528 字节），与参考镜像的哈希永远不可能相同。
把它记录下来，但仍以**实时 PROM 视图哈希**作为身份绑定——那一个是在运行时从硬件算出来的，
才是真正证明"这是哪张卡"的检查。

---

## 6 — `prom_profile.h`：PROM 视图哈希

```diff
-#define GU_PROM_VIEW_SHA256 "603baffe…"
+#define GU_PROM_VIEW_SHA256 "95cb1464e5312e03ffe904b73ce8ab33a1766520d0849b403aa595570670ed9f"
```

对 `BAR0 + 0x300000` 处 `0xd6c00` 字节计算所得。

**不要复用这个值。** 它是某一张卡固件的指纹。不匹配时程序会同时打印期望值与实际值：

```
live PROM view hash matched=0 bar_offset=0x300000 bytes=0xd6c00 expected=…
PROM verified view [0,0xd6c00) bytes=879616 SHA256=…
```

把你自己失败日志里的 `PROM verified view` 那一行拿来用——本值就是这么得到的。

---

## 7 — `ownership.c`：断开后重新取回 `PciIo`

最重要的一处。`DisconnectController` 成功后，设备句柄可能被销毁或替换，
于是对旧句柄调用 `HandleProtocol(Gu.handle, &PciGuid, …)` 会失败：

```
driver release: status=0 refresh=0x8000000000000003 same_pci=0
```

（`status=0` 表示断开成功，失败的是"重新取回"。）

补丁的做法：在占用快照阶段记下目标的 BDF，然后

1. 对原句柄重试 `HandleProtocol`（固件可能重新装回协议）；
2. 仍失败则用 `LocateHandleBuffer` 枚举所有 `PciIo` 句柄；
3. 按段/总线/设备/功能与记录的 BDF 比对；
4. 采纳新句柄，继续走原有的配置校验。

```c
/* GuFindReleaseOwner 中记录 */
if(Gu.pci && Gu.pci->GetLocation) { …SavedSeg=a;SavedBus=b;SavedDev=c;SavedFn=d;SavedBdf=TRUE; }

/* GuRefreshTargetPci 中，HandleProtocol 失败后 */
for(UINTN r=0;r<10;r++) { fresh=NULL; if(!EFI_ERROR(Gu.bs->HandleProtocol(…)&&…))break; GuStall(50000); }
if(!fresh && SavedBdf && Gu.bs->LocateHandleBuffer) { …按 Saved* 匹配并采纳… }
```

身份仍由随后的配置校验（厂商/设备、子系统、类别）把关，所以这不是"随便抓一张卡"。

---

## MSVC 编译修正

上游用 Zig 构建，Visual Studio 需要两处改动：

**`compat.c`** — MSVC 没有 `__atomic_thread_fence`：

```c
#if defined(_MSC_VER)
  _ReadWriteBarrier();
  __faststorefence();
#else
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
```

**`vendor/unlock_610.c`** — MSVC 不允许 `void *` 指针算术：

```diff
-	void __iomem *bar;
+	u8 *bar; /* MSVC: pointer arithmetic needs a sized type */
```

链接参数（见 `build/Build-Unlock.ps1`）：

```
link /nologo /subsystem:efi_application /entry:EfiMain /nodefaultlib /machine:x64 /debug:none
```

---

## 踩出来的操作规则

- 运行期间显示器线必须在**目标卡**上（`GOP physical=1 target=1`）。显示挂在别的卡上，
  预检会停在 `stage=display`。
- `FBPA` 达不到期望值是预期行为，非致命，上游文档已说明。
- 按下确认键后屏幕可能变黑：那是显示驱动被释放，不是死机；交接时会恢复。
- 出现 STOP 就断电，不要复位。
