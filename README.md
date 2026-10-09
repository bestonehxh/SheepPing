<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepPing app icon">
</p>

# 🐑 SheepPing

**A native macOS app that pings many hosts at once and shows live status, latency, and loss — with per-host logs and CSV export.**

SheepPing is the "is it up yet?" tool for network engineers: paste in a list of IPs or
hostnames, and watch every one of them get pinged continuously in a color-coded table.
Built with SwiftUI (Swift 6), it drives the system `ping`/`ping6` — one long-lived
process per host, streamed line by line.

## ⬇️ Download

[![Download SheepPing for macOS](https://img.shields.io/badge/Download-SheepPing_1.1_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepPing/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepPing/releases/latest)** — download the `.zip`, unzip, and drag **SheepPing.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepPing.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.

## The Sheep family 🐑

SheepPing is one of a few small native macOS apps for network engineers:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTerm"> | **[SheepTerm](https://github.com/bestonehxh/SheepTerm)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTerm/releases/latest) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="48" height="48" alt="SheepText"> | **[SheepText](https://github.com/bestonehxh/SheepText)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepText/releases/latest) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="48" height="48" alt="SheepDrop"> | **[SheepDrop](https://github.com/bestonehxh/SheepDrop)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepDrop/releases/latest) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTap"> | **[SheepTap](https://github.com/bestonehxh/SheepTap)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTap/releases/latest) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="48" height="48" alt="SheepPing"> | **[SheepPing](https://github.com/bestonehxh/SheepPing)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepPing/releases/latest) | Continuous multi-host ping monitor with per-host logs and CSV export |

## The Lab family 🧪

The servers and hypervisor control a network lab needs, native on the Mac:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDC/main/.github/icon.png?v=2" width="48" height="48" alt="LabDC"> | **[LabDC](https://github.com/bestonehxh/LabDC)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDC/releases/latest) | Active Directory–compatible domain controller with RADIUS for 802.1X and a lab CA |
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDock/main/.github/icon.png?v=1" width="48" height="48" alt="LabDock"> | **[LabDock](https://github.com/bestonehxh/LabDock)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDock/releases/latest) | VM control and console for standalone ESXi hosts — power, snapshots, guest files and scripts, no vCenter |

## Features

### Monitoring
- Ping **many hosts simultaneously**, IPv4 and IPv6, by IP or hostname
  (DNS is resolved automatically and the resolved IP is shown)
- **Bulk add** — paste a whole list, one host per line
- Auto-restart with backoff for hosts whose ping process dies (e.g. no route),
  and a watchdog timeout so IPv6 hosts still report lost packets
- Configurable **ping interval** (0.5–30 s) and **reply timeout** (0.5–15 s),
  applied live to running hosts

### Table
- Columns: Host, Resolved IP, Status, Latency, Success, Failed, Rate
- Latency color-coded (green < 30 ms, yellow < 120 ms, red above);
  success rate color-coded (green ≥ 95%, orange ≥ 75%, red below)
- Multi-select with ⌘-click / Shift-click, **copy rows as CSV** (⌘C)
- Toolbar: add / remove hosts, **Stop All**, **Resume** (keeps stats),
  **Restart All** (clears stats)

### Logs & export
- Live per-host packet log (timestamp, latency or timeout, raw ping message)
- Copy log to clipboard or **save as CSV**; multi-host combined CSV export
- Hosts and settings persist across launches — monitoring resumes on open

### Appearance
- System / Light / Dark theme
- No third-party dependencies — Apple frameworks only

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon

## Building

```bash
xcodebuild -project SheepPing.xcodeproj -scheme SheepPing -configuration Release build
```

Run the tests (57 unit + 12 UI tests):

```bash
xcodebuild -project SheepPing.xcodeproj -scheme SheepPing test
```

## License

[MIT](LICENSE) © 2026 bestonehxh
