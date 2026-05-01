<#
.SYNOPSIS
    Passive Wi-Fi reconnect helper for Windows 11. Detects "no network"
    state and connects to the preferred SSID; intended to run on a
    scheduled task at a fixed interval.

.DESCRIPTION
    Four mutually-exclusive operating modes:

      (default) Check        Inspect adapter / connection state. If the
                             machine is in a "no working network" state and
                             the Wi-Fi adapter is enabled, issue a
                             "netsh wlan connect" to the preferred SSID.
                             If any working connection already exists -
                             Ethernet, the preferred Wi-Fi, or even an
                             unrelated test Wi-Fi - the script does nothing.
                             This is the action the scheduled task invokes.

      -Install               Register a Windows scheduled task that calls
                             this script in Check mode every -IntervalHours
                             hours (default 3). Requires Administrator.

      -Uninstall             Remove the scheduled task. Requires Administrator.
                             Does NOT delete the log folder; remove
                             %USERPROFILE%\WifiReconnect manually if desired.

      -Status                Report adapter state, current SSID, scheduled
                             task registration, last run result, and the
                             tail of the log file. Read-only.

    Detection logic in Check mode (short-circuit, top to bottom):

      1. Any non-Wi-Fi physical adapter (e.g. Ethernet) is Up with a
         non-APIPA IPv4  -> skip (you have wired connectivity).
      2. Wi-Fi adapter is Disabled                       -> skip (user
                                                            choice).
      3. Wi-Fi adapter is Up and associated to ANY SSID
         with a usable IPv4                              -> skip (you have
                                                            a working
                                                            Wi-Fi link;
                                                            this protects
                                                            in-progress
                                                            tests on
                                                            secondary
                                                            networks).
      4. Otherwise (Wi-Fi enabled but not associated, or
         associated without IP)                          -> reconnect to
                                                            preferred SSID.

    Why this is safe for your testing workflow:
      While you are connected to a test network, rule (3) fires and the
      script exits without doing anything. Only after you actively
      disconnect from the test network - leaving the machine in a true
      no-network state - will the next scheduled run reconnect you.

    Persistent system footprint:
      * One scheduled task at  \WifiReconnect\WifiReconnect-AutoCheck
      * One folder             %USERPROFILE%\WifiReconnect (log file)
      Nothing else. No registry edits, no services, no Wi-Fi profile
      modifications. Run -Uninstall and delete the folder for a full
      cleanup.

.PARAMETER Ssid
    [Check mode] SSID to reconnect to. If omitted, the script auto-selects
    the first profile (in current priority order) whose ConnectionMode is
    "auto". Pass this to -Install and it will be embedded into the task.

.PARAMETER TimeoutSec
    [Check mode] Seconds to wait for association + IPv4 assignment before
    declaring failure. Default: 25.

.PARAMETER Install
    [Install mode] Register the scheduled task.

.PARAMETER IntervalHours
    [Install mode] How often the scheduled task runs. Default: 3 hours.

.PARAMETER Uninstall
    [Uninstall mode] Remove the scheduled task.

.PARAMETER Status
    [Status mode] Print state and exit.

.EXAMPLE
    .\Reconnect-PreferredWifi.ps1
    Run a single check now. Reconnects only if there is no working network.

.EXAMPLE
    .\Reconnect-PreferredWifi.ps1 -Install
    (As Administrator) Register the scheduled task with the default 3-hour
    interval, using the auto-selected first auto-connect profile.

.EXAMPLE
    .\Reconnect-PreferredWifi.ps1 -Install -IntervalHours 1 -Ssid "MyHomeWifi"
    (As Administrator) Register the task to run every hour, pinning the
    target SSID to "MyHomeWifi" instead of auto-selecting.

.EXAMPLE
    .\Reconnect-PreferredWifi.ps1 -Status
    Show whether the task is registered, last and next run times, and the
    last 10 log lines.

.EXAMPLE
    .\Reconnect-PreferredWifi.ps1 -Uninstall
    (As Administrator) Remove the scheduled task. Log folder is preserved.

.NOTES
    Encoding : UTF-8 (ASCII-only content).
    Targets  : Windows 11 (22H2 / 23H2 / 24H2). Compatible with Windows 10.
    Run tip  : If execution policy blocks the script, launch with:
                 powershell -ExecutionPolicy Bypass -File .\Reconnect-PreferredWifi.ps1
#>

[CmdletBinding(DefaultParameterSetName='Check')]
param(
    # ---- Check (default) ----
    [Parameter(ParameterSetName='Check')]
    [string]$Ssid,

    [Parameter(ParameterSetName='Check')]
    [int]$TimeoutSec = 25,

    # ---- Install ----
    [Parameter(ParameterSetName='Install', Mandatory=$true)]
    [switch]$Install,

    [Parameter(ParameterSetName='Install')]
    [int]$IntervalHours = 3,

    [Parameter(ParameterSetName='Install')]
    [string]$InstallSsid,

    # ---- Uninstall ----
    [Parameter(ParameterSetName='Uninstall', Mandatory=$true)]
    [switch]$Uninstall,

    # ---- Status ----
    [Parameter(ParameterSetName='Status', Mandatory=$true)]
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

$Script:DataDir     = Join-Path $env:USERPROFILE 'WifiReconnect'
$Script:LogFile     = Join-Path $Script:DataDir 'reconnect.log'
$Script:LogMaxBytes = 1MB
$Script:TaskName    = 'WifiReconnect-AutoCheck'
$Script:TaskPath    = '\WifiReconnect\'

# ============================================================
#  console + log helpers (ASCII only)
# ============================================================

function Write-Console {
    param([string]$Level, [string]$Message)
    switch ($Level) {
        'OK'    { Write-Host "[+] $Message" -ForegroundColor Green }
        'INFO'  { Write-Host "[*] $Message" -ForegroundColor Cyan }
        'WARN'  { Write-Host "[!] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[x] $Message" -ForegroundColor Red }
        default { Write-Host "    $Message" }
    }
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $Script:LogFile)) { return }
    $sz = (Get-Item -LiteralPath $Script:LogFile).Length
    if ($sz -le $Script:LogMaxBytes) { return }
    $old = $Script:LogFile + '.old'
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Move-Item -LiteralPath $Script:LogFile -Destination $old
}

function Write-Log {
    param([string]$Level, [string]$Message)
    if (-not (Test-Path -LiteralPath $Script:DataDir)) {
        New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null
    }
    Rotate-LogIfNeeded
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1,-5}  {2}" -f (Get-Date), $Level, $Message
    try {
        Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8
    } catch {
        # Logging must never break the main flow.
    }
    Write-Console -Level $Level -Message $Message
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
#  adapter / Wi-Fi probing
# ============================================================

function Get-WifiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PhysicalMediaType    -match '802\.11|Wireless' -or
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11'
        } |
        Sort-Object `
            @{ Expression = { $_.Status -eq 'Up' };       Descending = $true },
            @{ Expression = { $_.Status -ne 'Disabled' }; Descending = $true } |
        Select-Object -First 1
}

function Get-CurrentSsid {
    # Locale-safe parse: the acronym SSID is preserved in netsh output even
    # on localized Windows; BSSID lines start with B, so anchoring on
    # "^\s*SSID\s+:" only matches the desired line.
    $lines = (& netsh wlan show interfaces) 2>$null
    foreach ($line in $lines) {
        if ($line -match '^\s*SSID\s+:\s*(.+?)\s*$') {
            return $Matches[1]
        }
    }
    return $null
}

function Get-FirstAutoConnectSsid {
    # Iterate profiles in netsh-priority order; export each XML; return the
    # first whose connectionMode is "auto". key=clear is intentionally NOT
    # used so the WPA passphrase stays in the secure store.
    $lines = (& netsh wlan show profiles) 2>$null
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^\s+\S.*\s:\s+(.+?)\s*$') {
            $val = $Matches[1].Trim()
            if ($val -and $val -ne '<None>' -and $val -notmatch '^-+$') {
                if (-not $names.Contains($val)) { $names.Add($val) | Out-Null }
            }
        }
    }
    foreach ($n in $names) {
        $tmpDir = Join-Path $env:TEMP ("wlanp_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            & netsh wlan export profile name="$n" folder="$tmpDir" 2>$null | Out-Null
            $file = Get-ChildItem -Path $tmpDir -Filter '*.xml' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($file) {
                [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
                $cm = [string]$xml.WLANProfile.connectionMode
                if ($cm -and $cm.ToLowerInvariant() -eq 'auto') {
                    return $n
                }
            }
        } catch {
            # Ignore unreadable profiles.
        } finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Has-UsableIpv4 {
    param([Parameter(Mandatory=$true)][int]$IfIndex)
    $ip = Get-NetIPAddress -InterfaceIndex $IfIndex `
                           -AddressFamily IPv4 `
                           -ErrorAction SilentlyContinue |
          Where-Object {
              $_.IPAddress -notmatch '^169\.254\.' -and
              $_.IPAddress -ne '0.0.0.0'
          }
    if ($ip) { return $ip[0].IPAddress } else { return $null }
}

function Wait-ForConnection {
    param(
        [Parameter(Mandatory=$true)][string]$TargetSsid,
        [Parameter(Mandatory=$true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $cur = Get-CurrentSsid
        if ($cur -and $cur -eq $TargetSsid) {
            $a = Get-WifiAdapter
            if ($a) {
                $ip = Has-UsableIpv4 -IfIndex $a.ifIndex
                if ($ip) { return $ip }
            }
        }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

# ============================================================
#  Check mode (the body of work, called by the scheduled task)
# ============================================================

function Test-ShouldReconnect {
    # Returns @{ Should=$true|$false; Reason=<string> }

    # Rule 1: any non-Wi-Fi physical adapter with usable IPv4 -> skip.
    $others = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'Up' -and
            $_.PhysicalMediaType    -notmatch '802\.11|Wireless' -and
            $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless'
        }
    foreach ($a in $others) {
        $ip = Has-UsableIpv4 -IfIndex $a.ifIndex
        if ($ip) {
            return @{
                Should = $false
                Reason = "non-Wi-Fi adapter '$($a.Name)' is up with IP $ip"
            }
        }
    }

    # Rule 2: no Wi-Fi adapter -> nothing we can do.
    $wifi = Get-WifiAdapter
    if (-not $wifi) {
        return @{ Should = $false; Reason = 'no Wi-Fi adapter present' }
    }

    # Rule 3: Wi-Fi disabled by the user -> respect that.
    if ($wifi.Status -eq 'Disabled') {
        return @{ Should = $false; Reason = "Wi-Fi adapter '$($wifi.Name)' is Disabled by user" }
    }

    # Rule 4: Wi-Fi associated to ANY SSID with a usable IP -> skip.
    # This intentionally protects in-progress sessions on test/secondary
    # networks: as long as you are on some Wi-Fi, the script stays out.
    if ($wifi.Status -eq 'Up') {
        $ssid = Get-CurrentSsid
        if ($ssid) {
            $ip = Has-UsableIpv4 -IfIndex $wifi.ifIndex
            if ($ip) {
                return @{
                    Should = $false
                    Reason = "already connected to '$ssid' with IP $ip"
                }
            }
            return @{
                Should = $true
                Reason = "associated to '$ssid' but no usable IPv4 (DHCP stuck)"
            }
        }
    }

    return @{
        Should = $true
        Reason = "Wi-Fi adapter status=$($wifi.Status), not associated to any SSID"
    }
}

function Invoke-Check {
    Write-Log INFO ('Check started. Triggered context: ' + `
        $(if ([System.Environment]::UserInteractive) { 'interactive' } else { 'non-interactive' }))

    $decision = Test-ShouldReconnect
    if (-not $decision.Should) {
        Write-Log INFO ("Skip: " + $decision.Reason)
        exit 0
    }
    Write-Log WARN ("Reconnect needed: " + $decision.Reason)

    # Pick target SSID
    $target = $Ssid
    if (-not $target) {
        $target = Get-FirstAutoConnectSsid
        if (-not $target) {
            Write-Log ERROR 'No -Ssid given and no auto-connect profile found. Aborting.'
            exit 3
        }
        Write-Log INFO "Auto-selected target SSID: '$target'"
    } else {
        Write-Log INFO "Target SSID (user-specified): '$target'"
    }

    $wifi = Get-WifiAdapter
    if (-not $wifi) {
        Write-Log ERROR 'Lost Wi-Fi adapter between checks. Aborting.'
        exit 2
    }

    Write-Log INFO 'Disconnecting any current association...'
    & netsh wlan disconnect interface="$($wifi.Name)" 2>$null | Out-Null
    Start-Sleep -Seconds 1

    Write-Log INFO ("Issuing: netsh wlan connect name=`"$target`" interface=`"$($wifi.Name)`"")
    & netsh wlan connect name="$target" ssid="$target" interface="$($wifi.Name)" | Out-Null

    Write-Log INFO "Waiting up to $TimeoutSec s for association and IPv4..."
    $ip = Wait-ForConnection -TargetSsid $target -Timeout $TimeoutSec
    if ($ip) {
        Write-Log OK "Connected to '$target' with IP $ip."
        exit 0
    } else {
        Write-Log ERROR "Did not associate to '$target' within $TimeoutSec s."
        exit 5
    }
}

# ============================================================
#  Install / Uninstall (scheduled task lifecycle)
# ============================================================

function Get-RegisteredTask {
    Get-ScheduledTask -TaskName $Script:TaskName `
                      -TaskPath $Script:TaskPath `
                      -ErrorAction SilentlyContinue
}

function Invoke-Install {
    if (-not (Test-IsAdmin)) {
        Write-Console ERROR 'Install requires Administrator. Re-run an elevated PowerShell:'
        Write-Console INFO  '  Right-click PowerShell -> "Run as administrator", then re-invoke -Install.'
        exit 7
    }

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
        Write-Console ERROR 'Cannot resolve this script''s own path. Aborting.'
        exit 8
    }
    $scriptPath = (Resolve-Path -LiteralPath $scriptPath).Path

    if ($IntervalHours -lt 1 -or $IntervalHours -gt 24) {
        Write-Console ERROR "IntervalHours must be between 1 and 24 (got $IntervalHours)."
        exit 9
    }

    Write-Console INFO "Script path     : $scriptPath"
    Write-Console INFO "Task name       : $Script:TaskPath$Script:TaskName"
    Write-Console INFO "Interval        : every $IntervalHours hour(s)"
    if ($InstallSsid) {
        Write-Console INFO "Pinned SSID     : '$InstallSsid'"
    } else {
        Write-Console INFO 'Pinned SSID     : (none - auto-select first auto-connect profile)'
    }

    # Idempotent: drop any prior registration first.
    if (Get-RegisteredTask) {
        Write-Console INFO 'Removing existing task before re-registering...'
        Unregister-ScheduledTask -TaskName $Script:TaskName `
                                 -TaskPath $Script:TaskPath `
                                 -Confirm:$false `
                                 -ErrorAction SilentlyContinue
    }

    # Build the action: hidden powershell that calls this script in Check mode.
    $argLine = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    if ($InstallSsid) {
        # Quote the SSID for the command line; double-quote inside the outer
        # quoted argument string by escaping with backtick-quote.
        $argLine = $argLine + " -Ssid `"$InstallSsid`""
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine

    # Trigger: first run in 2 minutes, then every IntervalHours.
    # NOTE: -RepetitionDuration must be set explicitly; on some Windows
    # versions the -Once + -RepetitionInterval combo without a duration
    # will only fire twice. A 20-year span is effectively forever.
    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
        -RepetitionDuration (New-TimeSpan -Days (365 * 20))

    # Run as the current interactive user, no elevation needed at run time.
    $userId = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $description = "Auto-reconnect Wi-Fi to preferred network when disconnected. " +
                   "Runs every $IntervalHours hour(s). Idempotent: does nothing if a working " +
                   "connection already exists. Logs to $Script:LogFile."

    Register-ScheduledTask `
        -TaskName  $Script:TaskName `
        -TaskPath  $Script:TaskPath `
        -Action    $action `
        -Trigger   $trigger `
        -Principal $principal `
        -Settings  $settings `
        -Description $description | Out-Null

    Write-Console OK ("Scheduled task registered: $Script:TaskPath$Script:TaskName")
    Write-Console INFO ("First run at: " + (Get-Date).AddMinutes(2).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Console INFO ("Logs: $Script:LogFile")
    Write-Console INFO 'Run with -Status at any time to see task health and recent log entries.'
    exit 0
}

function Invoke-Uninstall {
    if (-not (Test-IsAdmin)) {
        Write-Console ERROR 'Uninstall requires Administrator.'
        exit 7
    }
    if (Get-RegisteredTask) {
        Unregister-ScheduledTask -TaskName $Script:TaskName `
                                 -TaskPath $Script:TaskPath `
                                 -Confirm:$false
        Write-Console OK ("Removed scheduled task: $Script:TaskPath$Script:TaskName")
    } else {
        Write-Console INFO 'No scheduled task registered (already clean).'
    }
    Write-Console INFO ("Log folder NOT removed: $Script:DataDir")
    Write-Console INFO '       Delete it manually if you want a fully clean state.'
    exit 0
}

# ============================================================
#  Status mode
# ============================================================

function Invoke-Status {
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host 'Wi-Fi Auto-Reconnect Helper - Status' -ForegroundColor Magenta
    Write-Host ('-' * 64) -ForegroundColor DarkGray

    $wifi = Get-WifiAdapter
    if ($wifi) {
        Write-Console INFO "Wi-Fi adapter   : $($wifi.Name)  ($($wifi.InterfaceDescription))"
        Write-Console INFO "Adapter status  : $($wifi.Status)"
        $ip = Has-UsableIpv4 -IfIndex $wifi.ifIndex
        Write-Console INFO ("Wi-Fi IPv4      : " + $(if ($ip) { $ip } else { '(none)' }))
    } else {
        Write-Console ERROR 'No Wi-Fi adapter found.'
    }
    Write-Console INFO ("Current SSID    : " + $(if (Get-CurrentSsid) { Get-CurrentSsid } else { '(disconnected)' }))

    $auto = Get-FirstAutoConnectSsid
    Write-Console INFO ("Preferred SSID  : " + $(if ($auto) { $auto } else { '(no auto-connect profile)' }))
    Write-Console INFO "Data folder     : $Script:DataDir"

    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host 'Scheduled task' -ForegroundColor Magenta
    Write-Host ('-' * 64) -ForegroundColor DarkGray

    $task = Get-RegisteredTask
    if ($task) {
        Write-Console OK ("Registered      : $Script:TaskPath$Script:TaskName")
        Write-Console INFO "State           : $($task.State)"
        try {
            $info = Get-ScheduledTaskInfo -TaskName $Script:TaskName -TaskPath $Script:TaskPath
            Write-Console INFO "Last run        : $($info.LastRunTime)"
            Write-Console INFO ("Last result     : 0x{0:X8}" -f $info.LastTaskResult)
            Write-Console INFO "Next run        : $($info.NextRunTime)"
        } catch {
            Write-Console WARN ("Could not read task info: " + $_.Exception.Message)
        }
    } else {
        Write-Console WARN 'Not registered. Run with -Install (as Administrator) to enable auto-check.'
    }

    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host 'Recent log (last 10 lines)' -ForegroundColor Magenta
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    if (Test-Path -LiteralPath $Script:LogFile) {
        Get-Content -LiteralPath $Script:LogFile -Tail 10
    } else {
        Write-Console INFO '(no log file yet)'
    }
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    exit 0
}

# ============================================================
#  dispatch
# ============================================================

switch ($PSCmdlet.ParameterSetName) {
    'Check'     { Invoke-Check     }
    'Install'   { Invoke-Install   }
    'Uninstall' { Invoke-Uninstall }
    'Status'    { Invoke-Status    }
}
