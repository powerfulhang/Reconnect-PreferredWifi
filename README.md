# Reconnect-PreferredWifi

Passive Wi-Fi auto-reconnect helper for Windows 10/11. Detects "no network" state and reconnects to your preferred Wi-Fi — runs via a scheduled task at a configurable interval.

## Why

Windows occasionally drops Wi-Fi after resuming from sleep, roaming between access points, or during driver hiccups. If your machine is headless or you need to keep it online without babysitting, this script acts as a safety net: it notices you're disconnected and brings the Wi-Fi back.

## Requirements

- Windows 10 or Windows 11 (22H2 / 23H2 / 24H2)
- PowerShell 5.1 or later (built-in)
- Administrator rights (only for `-Install` and `-Uninstall`)

## Quick Start

### 1. Download

```powershell
git clone https://github.com/powerfulhang/Reconnect-PreferredWifi.git
cd Reconnect-PreferredWifi
```

Or just download `Reconnect-PreferredWifi.ps1` — it has no dependencies.

### 2. Install the scheduled task (as Administrator)

```powershell
# Auto-select the first auto-connect Wi-Fi profile, check every 3 hours
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1 -Install

# Or pin a specific SSID and interval
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1 -Install -InstallSsid "MyHomeWiFi" -IntervalHours 1
```

After installation, the first check runs 2 minutes later, then repeats on your chosen interval.

### 3. Check status

```powershell
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1 -Status
```

This shows adapter state, current SSID, task registration, last run result, and recent log entries.

### 4. Run a manual check (no admin required)

```powershell
# Auto-detect the preferred network
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1

# Or target a specific SSID
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1 -Ssid "MyHomeWiFi"
```

## Unicode SSID Support

The script works correctly with SSIDs containing Chinese, Japanese, Korean, emoji, and other non-ASCII characters. It uses `Get-NetConnectionProfile` (Network List Manager API) to read SSIDs via Windows' Unicode-native APIs instead of parsing `netsh` console output, which can mangle non-ASCII characters through the legacy code page (CP936/GBK).

If your SSID contains non-ASCII characters, specifying it with `-InstallSsid` during installation is recommended to bypass the auto-detection path, which still relies on `netsh` text output for profile enumeration.

## How It Works

The check mode follows a short-circuit detection logic — it exits as soon as it finds a reason **not** to reconnect:

1. **Wired connection is up** (non-APIPA IPv4 on any non-Wi-Fi physical adapter) → skip. You have Ethernet.
2. **Wi-Fi adapter is disabled** → skip. User deliberately turned it off.
3. **Already on any working Wi-Fi** (associated to any SSID with a usable IPv4) → skip. Protects your in-progress sessions on test or secondary networks.
4. **Otherwise** (Wi-Fi enabled but not associated, or associated without an IP) → reconnect to the preferred SSID.

### Safety for testing workflows

The script intentionally protects **any** working Wi-Fi connection — not just the preferred one. If you're on a test network, the script stays out of your way. Only after you actively disconnect and the machine enters a true no-network state will the next scheduled run reconnect you.

## Usage Reference

| Mode | Command | Description |
|------|---------|-------------|
| Check (default) | `.\Reconnect-PreferredWifi.ps1 [-Ssid "SSID"] [-TimeoutSec 25]` | One-shot check and reconnect. |
| Install | `.\Reconnect-PreferredWifi.ps1 -Install [-IntervalHours 3] [-InstallSsid "SSID"]` | Register the scheduled task. Needs admin. |
| Uninstall | `.\Reconnect-PreferredWifi.ps1 -Uninstall` | Remove the scheduled task. Needs admin. |
| Status | `.\Reconnect-PreferredWifi.ps1 -Status` | Show adapter state, task info, recent logs. |

### Parameters

| Parameter | Mode | Default | Description |
|-----------|------|---------|-------------|
| `-Ssid` | Check | auto-detect | SSID to connect to. Auto-selects the first auto-connect profile if omitted. |
| `-TimeoutSec` | Check | 25 | Seconds to wait for association and IPv4 assignment. |
| `-Install` | Install | — | Register the scheduled task. |
| `-IntervalHours` | Install | 3 | How often the task runs (1–24). |
| `-InstallSsid` | Install | auto-detect | SSID embedded into the scheduled task. |
| `-Uninstall` | Uninstall | — | Remove the scheduled task. |
| `-Status` | Status | — | Print diagnostics and exit. |

## Files and Footprint

| What | Where |
|------|-------|
| Scheduled task | `Task Scheduler → \WifiReconnect\WifiReconnect-AutoCheck` |
| Log file | `%USERPROFILE%\WifiReconnect\reconnect.log` (rotates at 1 MB) |

No registry edits. No services. No Wi-Fi profile modifications. No key material is ever read or stored in plaintext — the script checks profile `connectionMode` only.

## Uninstall

```powershell
# As Administrator
powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1 -Uninstall
```

Then optionally delete the log folder:

```powershell
Remove-Item -Recurse "$env:USERPROFILE\WifiReconnect"
```

## Troubleshooting

**"Running scripts is disabled on this system"**
Run with `-ExecutionPolicy Bypass` as shown above, or set your execution policy:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**"Install requires Administrator"**
Right-click PowerShell → **Run as administrator**, then re-run the `-Install` command.

**Script exits with code 3**
No auto-connect Wi-Fi profile found. Specify one with `-Ssid "YourNetworkName"`.

**Script exits with code 5**
The script attempted to connect to the target SSID but didn't associate within the timeout window. The network may be out of range, or the Wi-Fi profile may be misconfigured.

## License

MIT — see [LICENSE](LICENSE).
