<#
.SYNOPSIS
    Capture the Ventrilo 3.1.0 login handshake to vent.example.com:6085.
    Implements docs/HANDSHAKE-CAPTURE.md end-to-end.

.DESCRIPTION
    - Locates tshark (PATH or default Wireshark install dir).
    - Picks the capture interface (default: the "Ethernet" adapter carrying the
      default route to the game server; override with -Interface).
    - Records the Ventrilo build (version + SHA256) and polls its owned TCP/UDP
      sockets every 2s for the whole capture, so a short-lived auth socket is caught
      without precise timing.
    - Runs a full, unfiltered, time-bounded pcap on the selected interface.
    - Emits the fast-path triage dumps (udp hex, conv map, dns, tcp opens).

    MUST be run from an ELEVATED PowerShell (Npcap capture + Get-Net* need admin).

.PARAMETER Interface
    tshark interface: a number from `tshark -D`, a friendly name, or a device path.
    Default: auto-detect the adapter named "Ethernet".

.PARAMETER Duration
    Capture safety-stop in seconds (doc default 45).

.PARAMETER Narrow
    Use the narrower fallback capture filter ("host vent.example.com or udp")
    instead of a full unfiltered capture. Not recommended for the first run.

.EXAMPLE
    # from an elevated PowerShell, with Ventrilo open but NOT connected:
    .\Scripts\capture-handshake.ps1
#>
[CmdletBinding()]
param(
    [string]$Interface = 'Ethernet',
    [int]$Duration = 45,
    [switch]$Narrow
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
$outDir    = Join-Path $repoRoot 'captures'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- 0. Elevation check ---------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an ELEVATED PowerShell (Run as Administrator). ' +
          'Npcap capture and Get-Net* need admin.'
}

# --- 1. Locate tshark -----------------------------------------------------------
$tshark = (Get-Command tshark -ErrorAction SilentlyContinue).Source
if (-not $tshark) {
    foreach ($p in @("$env:ProgramFiles\Wireshark\tshark.exe",
                     "${env:ProgramFiles(x86)}\Wireshark\tshark.exe")) {
        if (Test-Path $p) { $tshark = $p; break }
    }
}
if (-not $tshark) {
    throw 'tshark not found. Install Wireshark first: ' +
          'winget install --id WiresharkFoundation.Wireshark ' +
          '--accept-package-agreements --accept-source-agreements (accept the Npcap driver).'
}
Write-Host "tshark: $tshark" -ForegroundColor Cyan

# --- 2. Resolve capture interface to a tshark -D index --------------------------
# Prefer an explicit number; otherwise match the friendly name in `tshark -D`.
$ifaceArg = $Interface
if ($Interface -notmatch '^\d+$') {
    $devList = & $tshark -D 2>&1
    $match = $devList | Where-Object { $_ -match "\($([regex]::Escape($Interface))\)" } | Select-Object -First 1
    if ($match -and $match -match '^(\d+)\.') {
        $ifaceArg = $Matches[1]
        Write-Host "interface: '$Interface' -> tshark index $ifaceArg  [$($match.Trim())]" -ForegroundColor Cyan
    } else {
        Write-Warning "Could not map '$Interface' to a tshark -D index. Passing it through as-is."
        Write-Host   "`ntshark -D says:`n$($devList -join "`n")"
    }
} else {
    Write-Host "interface: index $ifaceArg" -ForegroundColor Cyan
}

# --- 3. Timestamped output paths ------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$pcap    = Join-Path $outDir "vent-login-$stamp.pcapng"
$snapLog = Join-Path $outDir "vent-snapshot-$stamp.txt"

# --- 4. Ventrilo build snapshot (doc step 3) ------------------------------------
function Get-VentProc {
    Get-Process | Where-Object ProcessName -Like 'ventrilo*' | Select-Object -First 1
}
$vent = Get-VentProc
if (-not $vent) {
    Write-Warning 'Ventrilo is not running. Open it (but do NOT connect yet), then re-run.'
    throw 'Ventrilo process not found.'
}
"=== Ventrilo build ($stamp) ==="                         | Tee-Object $snapLog
$vent | Select-Object Id,ProcessName,Path | Format-List   | Tee-Object $snapLog -Append
(Get-Item $vent.Path).VersionInfo |
    Select-Object FileVersion,ProductVersion | Format-List | Tee-Object $snapLog -Append
Get-FileHash $vent.Path -Algorithm SHA256 |
    Select-Object Hash | Format-List                       | Tee-Object $snapLog -Append

Write-Host "`nVentrilo open but NOT connected? Snapshot + capture start on Enter." -ForegroundColor Yellow
Read-Host 'Press Enter to begin' | Out-Null

# --- 5. Start the capture (unfiltered, time-bounded) ----------------------------
$tsArgs = @('-i', $ifaceArg, '-a', "duration:$Duration", '-w', $pcap)
if ($Narrow) { $tsArgs += @('-f', 'host vent.example.com or udp') }
Write-Host "`nCAPTURE RUNNING ($Duration s) -> $pcap" -ForegroundColor Green
Write-Host '>>> NOW: click Connect in Ventrilo. Stay in a channel ~10s, then disconnect.' -ForegroundColor Green
$proc = Start-Process -FilePath $tshark -ArgumentList $tsArgs -NoNewWindow -PassThru

# --- 6. Poll Ventrilo sockets every 2s for the whole capture --------------------
"`n=== socket poll (every 2s while capturing) ===" | Add-Content $snapLog
$deadline = (Get-Date).AddSeconds($Duration)
while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    $v = Get-VentProc
    if ($v) {
        $t = Get-Date -Format 'HH:mm:ss.fff'
        Add-Content $snapLog "`n--- $t  pid $($v.Id) ---"
        $tcp = Get-NetTCPConnection -OwningProcess $v.Id -ErrorAction SilentlyContinue |
               Select-Object State,LocalAddress,LocalPort,RemoteAddress,RemotePort
        $udp = Get-NetUDPEndpoint  -OwningProcess $v.Id -ErrorAction SilentlyContinue |
               Select-Object LocalAddress,LocalPort
        if ($tcp) { ($tcp | Format-Table -AutoSize | Out-String).TrimEnd() | Add-Content $snapLog }
        if ($udp) { ('UDP: ' + (($udp | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', ')) | Add-Content $snapLog }
    }
    Start-Sleep -Seconds 2
}
if (-not $proc.HasExited) { $proc.WaitForExit() }
Write-Host "Capture finished: $pcap" -ForegroundColor Green

# --- 7. Sanity check + fast-path triage dumps (doc) -----------------------------
Write-Host "`n=== conversation sanity check ===" -ForegroundColor Cyan
& $tshark -r $pcap -q -z conv,udp
& $tshark -r $pcap -q -z conv,tcp

$udpTxt  = Join-Path $outDir "vent-udp-$stamp.txt"
$convTxt = Join-Path $outDir "vent-convos-$stamp.txt"
$dnsTxt  = Join-Path $outDir "vent-dns-$stamp.txt"
$synTxt  = Join-Path $outDir "vent-tcp-opens-$stamp.txt"

& $tshark -r $pcap -Y 'udp' -x | Out-File -Encoding ascii $udpTxt
& $tshark -r $pcap -q -z conv,udp -z conv,tcp | Out-File -Encoding ascii $convTxt
& $tshark -r $pcap -Y 'dns.qry.name || dns.a || dns.aaaa' -T fields `
    -e frame.time_relative -e dns.qry.name -e dns.a -e dns.aaaa | Out-File -Encoding ascii $dnsTxt
& $tshark -r $pcap -Y 'tcp.flags.syn == 1 && tcp.flags.ack == 0 && !tcp.analysis.retransmission' `
    -T fields -e frame.time_relative -e ip.src -e ipv6.src -e ip.dst -e ipv6.dst -e tcp.dstport |
    Out-File -Encoding ascii $synTxt

Write-Host "`nWrote:" -ForegroundColor Cyan
Write-Host "  $pcap        (raw capture — hand this back)"
Write-Host "  $snapLog     (build + socket poll)"
Write-Host "  $udpTxt      (all UDP w/ hex)"
Write-Host "  $convTxt     (conversation map)"
Write-Host "  $dnsTxt      (DNS names resolved)"
Write-Host "  $synTxt      (TCP connection-attempt SYNs)"
Write-Host "`nSensitive: may contain creds/session/key material. Do not commit or post publicly." -ForegroundColor Yellow
