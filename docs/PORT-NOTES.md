# Port notes — RTX 4080 16 GB on ASRock Z390, Windows 11

Every change below exists because a check in the upstream source encodes a property of the reference
machine, not a property of the card. Nothing here changes unlock logic.

> These values are **machine-specific**. Re-measure them for your own hardware. Copying them blindly
> will either abort preflight, or make a gate pass that no longer means what it was written to mean.

---

## 1 — `port.h`: subsystem id

```diff
-#define GU_BOARD_SUBSYSTEM 0x179510deU
+#define GU_BOARD_SUBSYSTEM 0x27046688U
```

`0x179510de` is the reference board's subsystem (`10de:1795`). This card reports `6688:2704`; the value
appears in config space at `0x2c` and again at `0x40`.

---

## 2 — `checks.c`: `GuCheckConfig` bus constraint

```diff
-  if (Config == NULL || Segment != 0 || Bus != 1 || Device != 0 || Function != 0)
+  if (Config == NULL || Segment != 0 || Device != 0 || Function != 0)
     return FALSE;
```

The reference card sits on PCI bus 1. Here the target is on **bus 4**, assigned by firmware. Bus number
is not an identity. Segment, device and function stay constrained, and the caller still requires exactly
one matching target, so an unconstrained bus cannot select the wrong GPU.

---

## 3 — `port.c`: `GuTargetConfig` bus constraint

```diff
-  return C && !S && B==1 && !D && !F && C[0]==GU_BOARD_ID &&
+  return C && !S && !D && !F && C[0]==GU_BOARD_ID &&
     C[11]==GU_BOARD_SUBSYSTEM && (C[2]>>24)==3 && !((C[3]>>16)&0x7f);
```

This function is easy to miss: it is used by the **post-release re-acquire**, not by preflight. With
`B==1` left in place, the run fails at `stage=driver-release` with `refresh=0x8000000000000003` even
though the disconnect itself succeeded — a misleading signature that costs a boot cycle to diagnose.

If you port this and see `driver release: status=0 refresh=…3`, check this line first.

---

## 4 — `app.c` `BarCheck`: BAR upper bound

```diff
-      r->AddrRangeMin!=0x80000000 || r->AddrLen!=0x1000000 || r->AddrTranslationOffset ||
+      r->AddrRangeMin!=0xB1000000 || r->AddrLen!=0x1000000 || r->AddrTranslationOffset ||
       /* UEFI describes an inclusive end; pinned EDK2 PciBusDxe instead returns
          PciBar.Alignment. Both representations describe this exact 16 MiB BAR. */
-      (r->AddrRangeMax!=0x80ffffff && r->AddrRangeMax!=0x00ffffff) ||
+      (r->AddrRangeMax!=0xb1ffffff && r->AddrRangeMax!=0x00ffffff) ||
```

Both `AddrRangeMin` and `AddrRangeMax` are firmware-assigned. Keep the EDK2 alignment form
(`0x00ffffff`) as the alternative, since PciBusDxe may return alignment instead of an inclusive end.

Observed on this machine:

```
bar0 descriptor: type=0 granularity=32 min=0xb1000000 max=0xb1ffffff length=0x1000000 translation=0
```

---

## 5 — `app.c` `PromCheck`: firmware `RomImage` gate

```diff
-  if(!Gu.pci->RomImage || Gu.pci->RomSize!=0x24c00 ||
-     !GuHashMatches(Gu.pci->RomImage,0x24c00,"c2520432…"))return EFI_CRC_ERROR;
+  /* the firmware-cached RomImage is this board's own VBIOS slice */
+  if(!Gu.pci->RomImage)GuLogText("PCI RomImage: unavailable; using live PROM only\n");
+  else if(Gu.pci->RomSize!=0x24c00 || !GuHashMatches(Gu.pci->RomImage,0x24c00,"c2520432…")) {
+    GuLog("PCI RomImage: bytes=%u hash differs from reference (not enforced)\n",…);
+    LogHash("PCI RomImage",Gu.pci->RomImage,(UINTN)Gu.pci->RomSize);
+  }
```

The cached `RomImage` is the board's own VBIOS (150,528 bytes here), so a hash pinned to the reference
image can never match. Record it and keep the **live PROM view** hash as the binding check — that one is
computed from the hardware at run time and is the check that actually proves identity.

---

## 6 — `prom_profile.h`: PROM view hash

```diff
-#define GU_PROM_VIEW_SHA256 "603baffe…"
+#define GU_PROM_VIEW_SHA256 "95cb1464e5312e03ffe904b73ce8ab33a1766520d0849b403aa595570670ed9f"
```

Measured over `GU_PROM_VIEW_BYTES` (`0xd6c00`) at `BAR0 + 0x300000`.

**Do not reuse this value.** It is a fingerprint of one card's firmware. If it does not match, the
program prints both the expected and the actual hash:

```
live PROM view hash matched=0 bar_offset=0x300000 bytes=0xd6c00 expected=…
PROM verified view [0,0xd6c00) bytes=879616 SHA256=…
```

Take the `PROM verified view` line from your own failed run and use it. That is how this value was
obtained.

---

## 7 — `ownership.c`: re-acquire `PciIo` after disconnect

The single most important change. After a successful `DisconnectController`, the device handle may be
destroyed or replaced, so `HandleProtocol(Gu.handle, &PciGuid, …)` on the old handle fails:

```
driver release: status=0 refresh=0x8000000000000003 same_pci=0
```

(`status=0` means the disconnect worked. The failure is the re-acquire.)

The patch records the target's BDF during the ownership snapshot, then:

1. retries `HandleProtocol` on the original handle (the firmware may reinstall it),
2. if that fails, enumerates every `PciIo` handle with `LocateHandleBuffer`,
3. matches segment/bus/device/function against the saved BDF,
4. adopts the new handle and continues with the existing config validation.

```c
/* saved during GuFindReleaseOwner */
if(Gu.pci && Gu.pci->GetLocation) { …SavedSeg=a;SavedBus=b;SavedDev=c;SavedFn=d;SavedBdf=TRUE; }

/* in GuRefreshTargetPci, on HandleProtocol failure */
for(UINTN r=0;r<10;r++) { fresh=NULL; if(!EFI_ERROR(Gu.bs->HandleProtocol(…)&&…))break; GuStall(50000); }
if(!fresh && SavedBdf && Gu.bs->LocateHandleBuffer) {
  … for each handle: GetLocation, compare to Saved*, adopt on match …
}
```

Identity is still enforced afterwards by the config checks (`vendor/device`, subsystem, class), so an
unconstrained bus cannot turn this into "pick any GPU".

---

## MSVC build fixes

The upstream build expects Zig. Visual Studio works with two changes:

**`compat.c`** — MSVC has no `__atomic_thread_fence`:

```c
#if defined(_MSC_VER)
  _ReadWriteBarrier();
  __faststorefence();
#else
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
```

**`vendor/unlock_610.c`** — MSVC rejects `void *` arithmetic:

```diff
-	void __iomem *bar;
+	u8 *bar; /* MSVC: pointer arithmetic needs a sized type */
```

Link line used (see `build/Build-Unlock.ps1`):

```
link /nologo /subsystem:efi_application /entry:EfiMain /nodefaultlib /machine:x64 /debug:none
```

---

## Operating rules learned the hard way

- The display cable must be on the **target** card during the run (`GOP physical=1 target=1`). With the
  console on another GPU, preflight stops at `stage=display`.
- `FBPA` not reaching its requested value is expected and non-fatal; it is documented upstream.
- The screen may go black after the confirmation key. That is the display driver being released, not a
  crash. It recovers on handoff.
- If the run reports STOP, power off — do not reset.
