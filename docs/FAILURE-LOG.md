# Failure log — five classes, ~24 boot cycles

The first attempt used a different Windows port lineage and never completed. Rather than listing every
reboot, this is the taxonomy: the symptom, what it turned out to mean, and the conclusion that stuck.
Anyone debugging a similar board will recognise their own log here.

Context: firmware on this board **initialises the target GPU before the application runs** — entry
command register already `0x3`, attributes `0x300`, and one `BY_DRIVER` open on the PCI handle.

---

## Class 1 — Identity parsed as invalid (bus hardcoded)

**Symptom**

```
target BDF=0:4:0.0 checks=0 pm=0 pcie=0 msi=0 msix=0
CHECK stage=target status=0x8000000000000003
```

The configuration space dump was correct in every field, yet capability parsing returned nothing.

**Diagnosis** — capability parsing started with `Bus != 1 → return FALSE`. The card is on bus 4.

**Conclusion** — bus number is firmware-assigned and is not part of a card's identity. Constrain
segment/device/function, and let the "exactly one matching target" rule do the disambiguation.

**Traps** — the same assumption existed in *two* places (`checks.c` for preflight, `port.c` for the
post-release re-acquire). Fixing only the first one produces a much more confusing failure later.

---

## Class 2 — Ownership denied before anything runs

**Symptom**

```
admission={"reason":"upstream_bridge" / "owners_before", …, "owners":{"driver":1,…}}
```

**Diagnosis** — the firmware driver legitimately owns the device. Checking "no owners" as a gate can
never pass on this board.

**Conclusion** — the gate is wrong for this class of machine. The device must be *released*, which is a
different operation (see Class 3), not merely inspected.

---

## Class 3 — Disconnect hangs the firmware

**Symptom** — the screen stops immediately after the confirmation line. No further output, ever.

**Diagnosis** — `DisconnectController(handle, NULL, NULL)` disconnects *every* driver bound to the
handle, including the PCI bus binding. The firmware wedges.

**Conclusion** — disconnect only the agent that holds the `BY_DRIVER` open:

```c
Gu.bs->DisconnectController(handle, agent, NULL);
```

and do it under `RaiseTPL(TPL_NOTIFY)`, after setting `Gu.pci = NULL` so nothing dereferences the stale
protocol pointer during the teardown. With a targeted disconnect the call returns `status=0` on this
board — the same firmware that hangs on the NULL form.

**Note** — after this step the device handle may be destroyed. That is Class 7's problem.

---

## Class 4 — State gates pinned to the reference machine

**Symptom**

```
bar0 descriptor: … min=0xb1000000 max=0xb1ffffff length=0x1000000
CHECK stage=bar0 status=0x8000000000000003

live PROM view hash matched=0 expected=b5c287c6…   (an earlier, wrong guess)
```

**Diagnosis** — three separate constants: BAR base, BAR upper bound, and two firmware hashes. All four
belong to the reference card.

**Conclusion** — these are per-machine values. Read them out of your own log rather than guessing:

- `bar0 descriptor:` line gives min/max/length,
- `PROM verified view [0,0xd6c00) … SHA256=` gives the correct PROM hash when the check fails.

Do not iterate on guesses here; the program prints the value it computed.

---

## Class 5 — Transaction runs, engine refuses

**Symptom**

```
ARMED: one FWSEC/SEC2 transaction
FWSEC register: reg=0x110104 value=0xbadf5620 sentinel_like=1   (×13)
FWSEC result: scratch=0 expected_hi16=0
TRANSACTION OUTCOME: result=0 firmware_started=1 required_plm=1 all_plm=0
```

Selectors were written (`SS0=0x88888888`, `SS1=0x8`) but the performance path never opened; GEMM was
unchanged (91.93 TFLOPS).

**Diagnosis** — the engine was started while the device was still owned by firmware. Access was not
actually ours, so the engine's registers read back the sentinel pattern and nothing executed.

**Conclusion** — this is the same signature reported in `impacifist/Windows-GPU-UNLOCK#54`
("AD103: UEFI/DXE dies at FWSEC `0xbadf5620`, while the same sequence succeeds under Linux"). The
resolution here was not to weaken the transaction but to fix the release path: snapshot under TPL,
targeted disconnect, re-acquire `PciIo`, exclusive claim, restore only the cleared decode bits, then
re-run every preflight gate before arming.

---

## Class 6 (honest addendum) — post-release re-acquire

**Symptom**

```
driver release: status=0 refresh=0x8000000000000003 same_pci=0
CHECK stage=driver-release status=0x8000000000000003
FINAL … driver_release=1 clean=0 pci_available=0
```

**Diagnosis** — the disconnect worked; the handle was gone. `HandleProtocol` on the old handle cannot
succeed once the owning driver is removed.

**Conclusion** — re-enumerate `PciIo` handles and match the saved BDF. Detail in
[`PORT-NOTES.md`](PORT-NOTES.md#7--ownershipc-re-acquire-pciio-after-disconnect).

---

## What actually worked

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
all *-after-release checks   status=0
ARMED → PLM (WPR_CFG/WPR/FEAT matched, FBPA non-fatal) → SS0/SS1 matched
PCIe FLR → GOP reconnect → Windows handoff
FINAL status=0 stage=post-unlock-handoff
```

## Cost of getting here

About 24 boot cycles: ~14 on the first port (all ending in one of the classes above), ~10 more to
converge on the release path and the four per-machine values. Each cycle costs roughly five minutes of
wall time plus a power cycle.

If you are doing the same thing: read `docs/PORT-NOTES.md` before your first boot, and treat every
constant in the upstream source as a claim about *their* machine.
