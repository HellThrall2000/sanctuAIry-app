"""Sizes the KV cache by watching Native Heap grow as a conversation fills.

The repacked weights and the prefill activation buffer are allocated once at
model load and stay constant. The KV cache is not — `kv_increment_size: 16`
means it grows as tokens accumulate. So within a single process, growth in
Native Heap as the conversation lengthens *is* the KV cache.

peak - baseline  = KV cost of the context we actually reach (~2900 tokens,
                   where auto-compaction fires)
post-compact     = control. Compaction rebuilds the conversation on a trimmed
                   history, so if the growth really was KV, this drops back.
                   If it does not, the theory is wrong.

Samples only when idle, ~10s after a reply lands: activation buffers are
transient during generation and would otherwise show up as noise.
"""
import re
import subprocess
import sys
import time

ADB = r"C:/AndroidSDK/platform-tools/adb.exe"
PKG = "com.sanctuairy.app"

# Long enough to fill context quickly, varied enough not to trip the repeat
# guard (which would reseed and confound the measurement).
MESSAGES = [
    "I have been turning something over for weeks and I want to say it plainly "
    "for once instead of dancing around the edges of it every single time.",
    "The restructure at work left me doing the job of three people and I never "
    "once said out loud that it was too much for one person to carry.",
    "Evenings are the worst part now. The flat is silent and I sit there with "
    "my coat still on and cannot make myself do the smallest useful thing.",
    "I stopped climbing in March and stopped cooking properly in May and I "
    "cannot remember the last time I saw a friend outside of the office.",
    "Sleep goes wrong at three every morning without fail and I lie there "
    "cataloguing everything I got wrong that day until the light comes.",
    "My sister rang last week and I let it go to voicemail and I still have "
    "not rung her back because I did not want to be one more burden.",
    "Everyone from university seems to have worked out how to be an adult and "
    "I am thirty four and still improvising every single day of my life.",
    "What frightens me most is that it has stopped feeling like a phase and "
    "started feeling like the shape my life has simply taken now.",
    "I keep waiting for something to change on its own and I am beginning to "
    "understand that waiting is itself the thing that is not working.",
    "Is it possible to be tired in a way that sleeping does not touch at all "
    "because that is the only honest description I have found for it.",
]


def sh(cmd, timeout=180):
    return subprocess.run(
        [ADB, "shell", cmd], capture_output=True, text=True,
        timeout=timeout, encoding="utf-8", errors="replace",
    ).stdout or ""


def meminfo():
    """Native Heap and TOTAL Pss, in KB."""
    out = sh(f"dumpsys meminfo {PKG}")
    if "MEMINFO" not in out:
        return None, None
    native = re.search(r"^\s*Native Heap\s+(\d+)", out, re.M)
    total = re.search(r"^\s*TOTAL\s+(\d+)", out, re.M)
    return (int(native.group(1)) if native else 0,
            int(total.group(1)) if total else 0)


def replies():
    """Companion reply count, via the debug build's database."""
    try:
        with open("kv.db", "wb") as f:
            subprocess.run([ADB, "exec-out", f"run-as {PKG} cat "
                            "databases/sanctuary_secure_diaries.db"],
                           stdout=f, timeout=180)
        import sqlite3
        con = sqlite3.connect("kv.db")
        n = con.execute("select count(*) from chat_messages "
                        "where role='companion'").fetchone()[0]
        con.close()
        return n
    except Exception:
        return -1


def composer_tap():
    """Where the composer sits, derived from the device's own screen size.

    Hardcoding a coordinate broke a run: the phone detached mid-experiment, the
    tablet took its place, and taps meant for 1080x2392 landed in the middle of
    a 2800x1980 message list. Nothing was typed and the samples were noise.
    """
    # Taken from a screenshot, not from `wm size`. `wm size` reports the
    # *natural* orientation — 1980x2800 on this tablet — while the display is
    # actually landscape, so its numbers put the tap 700px off the bottom of
    # the screen. A screenshot is by definition the live coordinate space.
    png = subprocess.run([ADB, "exec-out", "screencap", "-p"],
                         capture_output=True, timeout=180).stdout
    if len(png) < 24 or png[1:4] != b"PNG":
        raise SystemExit("could not capture the screen")
    w = int.from_bytes(png[16:20], "big")
    h = int.from_bytes(png[20:24], "big")
    return int(w * 0.47), int(h * 0.96)


TAP = None


def send(text):
    global TAP
    if TAP is None:
        TAP = composer_tap()
        print(f"composer at {TAP} for this device\n")
    safe = text.replace("'", "").replace('"', "")
    sh(f"input tap {TAP[0]} {TAP[1]}")
    time.sleep(0.4)
    sh("input keyevent --longpress KEYCODE_DEL")
    for i in range(0, len(safe), 180):
        sh("input text '" + safe[i:i + 180].replace(" ", "%s") + "'")
    time.sleep(0.5)
    sh("input keyevent KEYCODE_ENTER")


def wait_for_reply(before, limit=420):
    # 240 was too short and cost a whole run. A cold start pays for the model
    # load on top of generation, and a long reply on this tablet's CPU backend
    # is ~5 minutes on its own.
    waited = 0
    while waited < limit:
        time.sleep(10)
        waited += 10
        if replies() > before:
            return True
    return False


def compaction_events():
    out = subprocess.run([ADB, "logcat", "-d"], capture_output=True, text=True,
                         timeout=180, encoding="utf-8",
                         errors="replace").stdout or ""
    return len(re.findall(r"Context full", out))


def main():
    subprocess.run([ADB, "logcat", "-c"], timeout=60)
    print("Sampling only when idle, ~10s after each reply settles.\n")
    print(f"{'turn':>5}  {'NativeHeap':>11}  {'delta':>9}  {'TotalPss':>9}  note")
    print("-" * 58)

    baseline = None
    peak = 0
    compactions = 0

    for i, msg in enumerate(MESSAGES, 1):
        before = replies()
        send(msg)
        if not wait_for_reply(before):
            print(f"{i:>5}  (no reply — stopping)")
            break

        # Let activations settle so we measure steady state, not generation.
        time.sleep(10)
        native, total = meminfo()
        if native is None:
            print(f"{i:>5}  (app not running — stopping)")
            break

        now = compaction_events()
        note = ""
        if now > compactions:
            note = "<< COMPACTION FIRED"
            compactions = now
        if baseline is None:
            baseline = native
            note = note or "<< baseline"
        peak = max(peak, native)

        delta = native - (baseline or native)
        print(f"{i:>5}  {native/1024:8.0f} MB  {delta/1024:+7.0f} MB  "
              f"{total/1024:6.0f} MB  {note}")

    if baseline is None:
        sys.exit("Nothing sampled.")

    print("\nRESULT")
    print(f"  baseline Native Heap   {baseline/1024:.0f} MB")
    print(f"  peak Native Heap       {peak/1024:.0f} MB")
    print(f"  growth (= KV cache)    {(peak-baseline)/1024:.0f} MB "
          f"for the context reached")
    print(f"  compactions observed   {compactions}")
    print()
    grown = (peak - baseline) / 1024
    if grown < 30:
        print("  VERDICT: KV cache is small. cache_length=2048 would save"
              " almost nothing —")
        print("           do NOT re-export on the cache argument alone.")
    else:
        full = grown * (4096 / 2900)
        print(f"  VERDICT: extrapolated to a full 4096-token cache ~"
              f"{full:.0f} MB;")
        print(f"           halving it should save roughly {full/2:.0f} MB.")


if __name__ == "__main__":
    main()
