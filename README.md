<div align="center">

# timer-res-asm

**A tiny Windows tool that locks the system timer resolution to help with audio glitches, latency spikes, and video stutter.**

A simple app (with a tray icon and optional autostart) plus a command-line version.

[![build](https://github.com/ihor-drachuk/timer-res-asm/actions/workflows/build.yml/badge.svg)](https://github.com/ihor-drachuk/timer-res-asm/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-blue)](#)

</div>

> [!WARNING]
> **This is alpha software — it has not been thoroughly tested and may not behave as expected.**
> It changes the system timer resolution and (optionally) adds an autostart entry to your user
> registry. The effect is reversible — choosing **Default** or closing the app restores normal
> behavior. Test it before relying on it.

---

## What it is

A small, free clone of Lucas Hale's **TimerResolution.exe**. It shows the timer
resolution Windows is currently using and lets you lock it to a finer value.

The app (`timer-res.exe`) is a small window showing Min / Max / Current
resolution, with **Maximum / 1 ms / Default** buttons, a system-tray icon, and a
"Run at Windows startup" checkbox.

## Why timer resolution?

By default Windows ticks its scheduler timer about every **15.625 ms**. For some
workloads that coarse granularity causes **audio glitches, latency spikes, and
visual "trails" / stutter** in media apps. Locking the timer at **0.5–1 ms** often
makes those problems disappear.

On Windows 10 (2004+) and Windows 11 the timer resolution is **per-process** — it
is released as soon as the program that set it exits. That's why the app stays in
the tray, and why the command-line tool has a `hold` command (a one-shot `set`
does not persist).

See also: [Microsoft — high-resolution timers](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps)
and the original [TimerResolution by Lucas Hale](https://vvvv.org/contribution/windows-system-timer-tool).

## Download

Grab **`timer-res.exe`** from the [latest release](https://github.com/ihor-drachuk/timer-res-asm/releases/latest)
and run it — no installer, nothing else to install. (A smaller `timer-res-noicon.exe`
build, identical but without the embedded window icon, is also attached. Prefer to
build it yourself? See [Build](#build).)

> The `.exe` isn't code-signed, so Windows SmartScreen may warn on first run —
> click **More info → Run anyway**, or build it from source yourself.

## Requirements

- Windows 10 (version 2004 / May 2020) or newer, 64-bit.
- **No admin rights, no install, no runtime** — just the `.exe`.
- Footprint: the app is about **24 KB** (a 6.6 KB icon-less build is also provided).

The only change it makes outside its own process is the **optional** "Run at
startup" registry entry, which is easy to undo (see [Removing autostart](#removing-autostart-manually)).

## Usage

Click **Maximum** (finest the system supports, often 0.5 ms), **1 ms**, or
**Default** (release). Tick **Run at Windows startup** to launch on logon. The X
button minimizes to the tray; right-click the tray icon for **Show / Exit**.

## Build

You need [flat assembler (FASM) 1.73.35](https://flatassembler.net/download.php).

1. Download `fasmw17335.zip` and either set the `FASM_DIR` environment variable to
   the extracted folder, or drop the extracted FASM distro into a `fasm\` subfolder.
2. Run `build.cmd`.

This produces `timer-res.exe`, `timer-res-noicon.exe` (a smaller build with no
embedded icon), and `timer-res-test-tool.exe` — a small console tool used to
exercise the backend (`query` / `set` / `hold` / `autostart`); it is not part of
the release.

## Removing autostart manually

```bat
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v TimerRes /f
```

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Ihor Drachuk.

There is also a C++ implementation: **[timer-res-cpp](https://github.com/ihor-drachuk/timer-res-cpp)**.

## Author

**Ihor Drachuk** · [ihor-drachuk-libs@pm.me](mailto:ihor-drachuk-libs@pm.me) · [GitHub](https://github.com/ihor-drachuk)
