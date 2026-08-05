"""Measures what the companion actually costs in memory, on a real device.

Run it, then send a message in the app. It samples until the model has loaded
and generation is under way, and reports the numbers that matter.

    python tool/measure_memory.py

**Read Native Heap, not RSS.** RSS counts the memory-mapped model file, which is
file-backed and clean — the kernel evicts it under pressure and re-reads it from
disk, so it is not what gets an app killed. Native Heap is the anonymous
allocation: weights repacked by XNNPACK, the KV cache, and activation buffers.
That is the figure a re-export can actually move.

Baseline on a Nothing A059P (Android 16, 11.7 GB) with the current export:

    Native Heap    790 MB     <- target for improvement
    Private Dirty  880 MB
    Private Clean  829 MB     <- evictable, mostly the model mmap
    RSS Total     1818 MB
    PSS Total     1761 MB     <- Google's published E2B figure is 1733 MB

If a re-export with bounded prefill and a smaller cache is working, Native Heap
falls. If only RSS moves, nothing real changed.
"""
import re
import subprocess
import sys
import time

ADB = r"C:/AndroidSDK/platform-tools/adb.exe"
PKG = "com.sanctuairy.app"
SAMPLES = 20
INTERVAL = 10


def sh(cmd, timeout=120):
    return subprocess.run(
        [ADB, "shell", cmd], capture_output=True, text=True,
        timeout=timeout, encoding="utf-8", errors="replace",
    ).stdout or ""


def field(text, label):
    """Pulls one row out of `dumpsys meminfo` output."""
    m = re.search(rf"^\s*{re.escape(label)}\s+(\d+)", text, re.M)
    return int(m.group(1)) if m else 0


def main():
    print("Send a message in the app now; sampling while it loads and replies.\n")
    print(f"{'t':>5}  {'NativeHeap':>11}  {'PrivDirty':>10}  "
          f"{'PrivClean':>10}  {'RSS':>8}  {'PSS':>8}")
    print("-" * 62)

    peak = {}
    for i in range(SAMPLES):
        time.sleep(INTERVAL)
        out = sh(f"dumpsys meminfo {PKG}")
        if "MEMINFO" not in out:
            print(f"{(i+1)*INTERVAL:>4}s  (app not running)")
            continue

        native = field(out, "Native Heap")
        total = re.search(
            r"^\s*TOTAL\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", out, re.M)
        pss = int(total.group(1)) if total else 0
        dirty = int(total.group(2)) if total else 0
        clean = int(total.group(3)) if total else 0
        rss = int(total.group(5)) if total else 0

        mb = lambda kb: f"{kb / 1024:.0f} MB"
        print(f"{(i+1)*INTERVAL:>4}s  {mb(native):>11}  {mb(dirty):>10}  "
              f"{mb(clean):>10}  {mb(rss):>8}  {mb(pss):>8}")

        for k, v in (("native", native), ("dirty", dirty), ("rss", rss),
                     ("pss", pss)):
            peak[k] = max(peak.get(k, 0), v)

    if not peak:
        sys.exit("Nothing sampled — is the app running and the device attached?")

    print("\nPEAK")
    print(f"  Native Heap    {peak['native'] / 1024:.0f} MB   "
          f"<- the number a re-export moves")
    print(f"  Private Dirty  {peak['dirty'] / 1024:.0f} MB   "
          f"<- real pressure; what gets you killed")
    print(f"  RSS Total      {peak['rss'] / 1024:.0f} MB   "
          f"<- includes evictable file mmap; misleading on its own")
    print(f"  PSS Total      {peak['pss'] / 1024:.0f} MB   "
          f"<- compare to Google's published 1733 MB for E2B")


if __name__ == "__main__":
    main()
