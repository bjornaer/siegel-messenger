#!/usr/bin/env python3
"""Emulator smoke test: real app, real Rust core, local server.

Registers through every onboarding screen, then enables app lock, backgrounds the app,
checks it locks and unlocks with the device PIN, and turns on screen security.

Setup (once): an AVD with a screen-lock PIN of 1111 (adb shell locksettings set-pin 1111).
Run:
  docker compose up -d
  flutter build apk --debug --dart-define=SIEGEL_SERVER=http://10.0.2.2:58080
  adb install -r build/app/outputs/flutter-apk/app-debug.apk
  python3 tool/emulator_smoke.py <screenshot dir>
The OTP is read from the local database, since the dev server stubs SMS.
"""
import os, random, re, shutil, subprocess, sys, time
ADB = os.environ.get("ADB") or shutil.which("adb") or "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
DOCKER = os.environ.get("DOCKER") or shutil.which("docker") or "/Applications/Docker.app/Contents/Resources/bin/docker"
S = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
def adb(*a): return subprocess.run([ADB, *a], capture_output=True, text=True).stdout
def find(label, cls=None, wait=15):
    for _ in range(wait):
        adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
        xml = adb("shell", "cat", "/sdcard/ui.xml")
        for n in re.findall(r"<node [^>]*/?>", xml):
            t = (re.search(r'text="([^"]*)"', n) or [None, ""])[1] + " " + (re.search(r'content-desc="([^"]*)"', n) or [None, ""])[1] + " " + (re.search(r'hint="([^"]*)"', n) or [None, ""])[1]
            c = re.search(r'class="([^"]*)"', n)[1]
            b = list(map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n).groups()))
            if label.lower() in t.lower() and (cls is None or cls in c):
                return ((b[0]+b[2])//2, (b[1]+b[3])//2)
        time.sleep(1)
    shot("missing"); sys.exit(f"not found: {label}")
def tap(label, cls=None):
    x, y = find(label, cls); adb("shell", "input", "tap", str(x), str(y)); time.sleep(1)
def type_into(label, text):
    tap(label, "EditText"); adb("shell", "input", "text", text); adb("shell", "input", "keyevent", "111"); time.sleep(1)
def shot(name):
    open(f"{S}/{name}.png", "wb").write(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout)
def otp():
    return subprocess.run([DOCKER, "compose", "-f", os.path.join(os.path.dirname(__file__), "../../compose.yaml"), "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "siegel", "-tAc",
        "SELECT code FROM otps ORDER BY expires_at DESC LIMIT 1"], capture_output=True, text=True).stdout.strip()


def has(label):
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml"); return label.lower() in adb("shell", "cat", "/sdcard/ui.xml").lower()
def pin():
    time.sleep(3); adb("shell", "input", "keyevent", "8", "8", "8", "8"); time.sleep(1); adb("shell", "input", "keyevent", "66"); time.sleep(3)
def lock_flow():
    if not has("Lock after"): tap("App lock", "Switch"); pin()
    find("Lock after"); adb("shell", "input", "tap", "220", "399"); time.sleep(1); tap("Immediately"); shot("settings")
    adb("shell", "input", "keyevent", "3"); time.sleep(2)            # home button
    adb("shell", "am", "start", "-n", "in.schlk.siegel/.MainActivity"); time.sleep(3)
    shot("locked"); find("Siegel is locked"); print("locked after background")
    pin(); find("You are @"); print("unlocked with device PIN")
    tap("Screen security", "Switch"); time.sleep(1); shot("secure"); print("screen security on")
def register():
    adb("shell", "am", "force-stop", "in.schlk.siegel"); adb("shell", "am", "start", "-n", "in.schlk.siegel/.MainActivity"); time.sleep(4)
    tap("Continue")
    phone = "+346" + "".join(random.choice("0123456789") for _ in range(8))
    type_into("Your phone number", phone)
    tap("years old"); shot("phone")
    tap("Send code")
    find("Enter the 6-digit code")
    type_into("Code", otp()); tap("Verify")
    user = "emu" + "".join(random.choice("abcdefghij") for _ in range(6))
    type_into("@username", user); type_into("Display name", "Emu"); shot("profile")
    tap("Save")
    type_into("4-digit PIN", "1234"); tap("Set PIN")
    find(f"You are @{user}"); shot("home"); print("registered", user)

if __name__ == "__main__":
    register(); lock_flow()
