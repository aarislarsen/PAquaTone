<#
.SYNOPSIS
    PAquaTone - PowerShell web recon screenshot tool.

.DESCRIPTION
    Accepts IP ranges, IP lists, or hostname lists. Performs reverse DNS (for IPs),
    then screenshots each resolved host on specified ports using headless Chrome.

.PARAMETER StartIP
    Start of IP range (use with -EndIP).

.PARAMETER EndIP
    End of IP range (use with -StartIP).

.PARAMETER IPList
    Path to a file containing one IP address per line.

.PARAMETER HostList
    Path to a file containing one hostname/FQDN per line.

.PARAMETER OutDir
    Directory to save screenshots. Created if it does not exist.

.PARAMETER Ports
    Comma-separated list of ports to screenshot. Default: 80,443,8000,8080,8443,10000

.PARAMETER Threads
    Number of concurrent threads. Default: 1 (single-threaded).

.EXAMPLE
    .\PAquaTone.ps1 -StartIP 10.0.0.1 -EndIP 10.0.0.254 -OutDir C:\recon\out
    .\PAquaTone.ps1 -IPList .\ips.txt -OutDir C:\recon\out -Ports "80,443,8080" -Threads 4
    .\PAquaTone.ps1 -HostList .\hosts.txt -OutDir C:\recon\out -Ports "80,443" -Threads 8
#>

[CmdletBinding(DefaultParameterSetName = 'Range')]
param(
    [Parameter(ParameterSetName = 'Range',  Mandatory = $true)]  [string]$StartIP,
    [Parameter(ParameterSetName = 'Range',  Mandatory = $true)]  [string]$EndIP,
    [Parameter(ParameterSetName = 'IPList', Mandatory = $true)]  [string]$IPList,
    [Parameter(ParameterSetName = 'HostList', Mandatory = $true)][string]$HostList,

    [Parameter(Mandatory = $true)]  [string]$OutDir,
    [Parameter(Mandatory = $false)] [string]$Ports   = "80,8080,443,8443,8090,10000,5601,8000,9090,9990,9993",
    [Parameter(Mandatory = $false)] [int]   $Threads = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helper: Enumerate IPs in a range
# ---------------------------------------------------------------------------
function Get-IPRange {
    param([string]$Start, [string]$End)

    function IP-ToInt ([string]$ip) {
        $bytes = ([System.Net.IPAddress]$ip).GetAddressBytes()
        [Array]::Reverse($bytes)
        [BitConverter]::ToUInt32($bytes, 0)
    }
    function Int-ToIP ([uint32]$n) {
        $bytes = [BitConverter]::GetBytes($n)
        [Array]::Reverse($bytes)
        $bytes -join '.'
    }

    $s = IP-ToInt $Start
    $e = IP-ToInt $End
    if ($s -gt $e) { throw "StartIP must be less than or equal to EndIP." }

    for ($i = $s; $i -le $e; $i++) { Int-ToIP ([uint32]$i) }
}

# ---------------------------------------------------------------------------
# Helper: Locate Chrome executable
# ---------------------------------------------------------------------------
function Find-Chrome {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Chromium\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Chromium\Application\chrome.exe",
        "$env:LocalAppData\Chromium\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )

    # Also check PATH
    $fromPath = Get-Command chrome.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if ($fromPath) { return $fromPath }

    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # Registry fallback
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    if (Test-Path $regPath) {
        $val = (Get-ItemProperty $regPath).'(default)'
        if ($val -and (Test-Path $val)) { return $val }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Helper: Screenshot a single host across all ports
# ---------------------------------------------------------------------------
function Invoke-Screenshot {
    param(
        [string]  $FQDN,
        [int[]]   $PortList,
        [string]  $OutputDir,
        [string]  $ChromePath
    )

    $schemaPorts = @{
        443  = 'https'
        8443 = 'https'
    }

    foreach ($port in $PortList) {
        $scheme = if ($schemaPorts.ContainsKey($port)) { $schemaPorts[$port] } else { 'http' }
        $url    = "${scheme}://${FQDN}:${port}"
        $safe   = $FQDN -replace '[\\/:*?"<>|]', '_'
        $outFile = Join-Path $OutputDir "${safe}-${port}.png"

        Write-Host "  -> $url"
        & $ChromePath --headless --disable-gpu --no-sandbox `
            --screenshot="$outFile" "$url" 2>$null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Validate output directory
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
    Write-Host "[*] Created output directory: $OutDir"
}

# Locate Chrome
$ChromeExe = Find-Chrome
if (-not $ChromeExe) {
    Write-Error "Could not locate Chrome, Chromium, or Edge. Install one or add it to PATH."
    exit 1
}
Write-Host "[*] Using browser: $ChromeExe"

# Parse ports
[int[]]$PortList = $Ports -split ',' | ForEach-Object { [int]$_.Trim() }
Write-Host "[*] Ports: $($PortList -join ', ')"
Write-Host "[*] Threads: $Threads"
Write-Host ""

# ---------------------------------------------------------------------------
# Phase 1: Build target list (hostnames)
# ---------------------------------------------------------------------------
$Targets = @()   # will hold FQDNs / hostnames

switch ($PSCmdlet.ParameterSetName) {

    'HostList' {
        Write-Host "[*] Loading hostnames from: $HostList"
        $Targets = Get-Content $HostList | Where-Object { $_ -match '\S' }
        Write-Host "[*] $($Targets.Count) hosts loaded"
    }

    default {
        # IP range or IP file — need reverse DNS
        $IPs = @()

        if ($PSCmdlet.ParameterSetName -eq 'Range') {
            Write-Host "[*] Enumerating range $StartIP - $EndIP"
            $IPs = @(Get-IPRange -Start $StartIP -End $EndIP)
            Write-Host "[*] $($IPs.Count) IPs in range"
        }
        else {
            Write-Host "[*] Loading IPs from: $IPList"
            $IPs = Get-Content $IPList | Where-Object { $_ -match '\S' }
            Write-Host "[*] $($IPs.Count) IPs loaded"
        }

        Write-Host ""
        Write-Host "[*] Starting reverse DNS resolution"
        Write-Host ("-" * 60)

        $ResolvedMap = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

        $resolveBlock = {
            param($IP)
            try {
                $entry = [System.Net.Dns]::GetHostEntry($IP)
                if ($entry.HostName) {
                    return [PSCustomObject]@{ IP = $IP; Host = $entry.HostName; OK = $true }
                }
            } catch {}
            return [PSCustomObject]@{ IP = $IP; Host = $null; OK = $false }
        }

        if ($Threads -le 1) {
            foreach ($ip in $IPs) {
                $r = & $resolveBlock $ip
                if ($r.OK) {
                    Write-Host "  $($r.IP) -> $($r.Host)"
                    $Targets += $r.Host
                } else {
                    Write-Host "  $($r.IP) -> [unresolved]"
                }
            }
        } else {
            $results = $IPs | ForEach-Object -ThrottleLimit $Threads -Parallel {
                $IP = $_
                try {
                    $entry = [System.Net.Dns]::GetHostEntry($IP)
                    if ($entry.HostName) {
                        [PSCustomObject]@{ IP = $IP; Host = $entry.HostName; OK = $true }
                        return
                    }
                } catch {}
                [PSCustomObject]@{ IP = $IP; Host = $null; OK = $false }
            }
            foreach ($r in $results) {
                if ($r.OK) {
                    Write-Host "  $($r.IP) -> $($r.Host)"
                    $Targets += $r.Host
                } else {
                    Write-Host "  $($r.IP) -> [unresolved]"
                }
            }
        }

        $Targets = $Targets | Sort-Object -Unique
        Write-Host ("-" * 60)
        Write-Host "[*] Resolved $($Targets.Count) unique hostnames"

        # Persist resolved list
        $resolvedFile = Join-Path $OutDir "resolved.txt"
        $Targets | Out-File $resolvedFile
        Write-Host "[*] Saved to: $resolvedFile"
    }
}

# ---------------------------------------------------------------------------
# Phase 2: Screenshot
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[*] Screenshotting $($Targets.Count) hosts on ports: $($PortList -join ', ')"
Write-Host ("-" * 60)

if ($Threads -le 1) {
    foreach ($fqdn in $Targets) {
        Write-Host "[>] $fqdn"
        Invoke-Screenshot -FQDN $fqdn -PortList $PortList -OutputDir $OutDir -ChromePath $ChromeExe
    }
} else {
    # Pass required variables into parallel scope explicitly
    $Targets | ForEach-Object -ThrottleLimit $Threads -Parallel {
        $fqdn      = $_
        $PortList  = $using:PortList
        $OutDir    = $using:OutDir
        $ChromeExe = $using:ChromeExe

        $schemaPorts = @{ 443 = 'https'; 8443 = 'https' }

        foreach ($port in $PortList) {
            $scheme  = if ($schemaPorts.ContainsKey($port)) { $schemaPorts[$port] } else { 'http' }
            $url     = "${scheme}://${fqdn}:${port}"
            $safe    = $fqdn -replace '[\\/:*?"<>|]', '_'
            $outFile = Join-Path $OutDir "${safe}-${port}.png"

            & $ChromeExe --headless --disable-gpu --no-sandbox `
                --screenshot="$outFile" "$url" 2>$null
        }
        Write-Host "[>] Done: $fqdn"
    }
}

Write-Host ("-" * 60)
Write-Host "[*] Screenshotting complete. Output: $OutDir"
Write-Host "[!] Chrome processes may linger — allow 30s for cleanup."
