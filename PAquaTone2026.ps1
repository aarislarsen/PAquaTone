#
# PAquaTone.ps1
#
# USAGE:
#   Dot-source this file to load the function without executing it:
#       . .\PAquaTone.ps1
#
#   Then invoke:
#       Invoke-PAquaTone -StartIP 10.0.0.1 -EndIP 10.0.0.254 -OutDir C:\recon\out
#       Invoke-PAquaTone -IPList .\ips.txt -OutDir C:\recon\out -Ports "80,443,8080" -Threads 4
#       Invoke-PAquaTone -HostList .\hosts.txt -OutDir C:\recon\out -Ports "80,443" -Threads 8
#

function Invoke-PAquaTone {
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
        Comma-separated list of ports to screenshot. Default: 80,8080,443,8443,8090,10000,5601,8000,9090,9990,9993

    .PARAMETER Threads
        Number of concurrent threads. Default: 1 (single-threaded).

    .PARAMETER ChromeTimeout
        Milliseconds Chrome is allowed to load a page before self-terminating. Default: 10000

    .PARAMETER ProcessTimeout
        Milliseconds the script waits for a Chrome process to exit before force-killing it. Default: 15000

    .EXAMPLE
        Invoke-PAquaTone -StartIP 10.0.0.1 -EndIP 10.0.0.254 -OutDir C:\recon\out
        Invoke-PAquaTone -IPList .\ips.txt -OutDir C:\recon\out -Ports "80,443,8080" -Threads 4
        Invoke-PAquaTone -HostList .\hosts.txt -OutDir C:\recon\out -Ports "80,443" -Threads 8
    #>

    [CmdletBinding(DefaultParameterSetName = 'Range')]
    param(
        [Parameter(ParameterSetName = 'Range',    Mandatory = $true)]  [string]$StartIP,
        [Parameter(ParameterSetName = 'Range',    Mandatory = $true)]  [string]$EndIP,
        [Parameter(ParameterSetName = 'IPList',   Mandatory = $true)]  [string]$IPList,
        [Parameter(ParameterSetName = 'HostList', Mandatory = $true)]  [string]$HostList,

        [Parameter(Mandatory = $true)]  [string]$OutDir,
        [Parameter(Mandatory = $false)] [string]$Ports          = "80,8080,443,8443,8090,10000,5601,8000,9090,9990,9993",
        [Parameter(Mandatory = $false)] [int]   $Threads        = 1,
        [Parameter(Mandatory = $false)] [int]   $ChromeTimeout  = 10000,
        [Parameter(Mandatory = $false)] [int]   $ProcessTimeout = 15000
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'SilentlyContinue'

    # ---------------------------------------------------------------------------
    # Inner helper: Enumerate IPs in a range
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
    # Inner helper: Locate Chrome executable
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

        $fromPath = Get-Command chrome.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        if ($fromPath) { return $fromPath }

        foreach ($c in $candidates) {
            if (Test-Path $c) { return $c }
        }

        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
        if (Test-Path $regPath) {
            $val = (Get-ItemProperty $regPath).'(default)'
            if ($val -and (Test-Path $val)) { return $val }
        }

        return $null
    }

    # ---------------------------------------------------------------------------
    # Inner helper: Screenshot a single URL with hard process timeout
    # ---------------------------------------------------------------------------
    function Invoke-ChromeScreenshot {
        param(
            [string] $ChromePath,
            [string] $Url,
            [string] $OutFile,
            [int]    $ChromeTimeout,
            [int]    $ProcessTimeout
        )

        $argList = @(
            "--headless",
            "--disable-gpu",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--timeout=$ChromeTimeout",
            "--screenshot=`"$OutFile`"",
            "`"$Url`""
        )

        $proc = Start-Process -FilePath $ChromePath `
            -ArgumentList $argList `
            -PassThru -NoNewWindow

        if (-not $proc.WaitForExit($ProcessTimeout)) {
            Write-Host "  [!] Timeout — killing Chrome PID $($proc.Id) for $Url"
            $proc.Kill()
        }
    }

    # ---------------------------------------------------------------------------
    # Inner helper: Screenshot a single host across all ports
    # ---------------------------------------------------------------------------
    function Invoke-Screenshot {
        param(
            [string]  $FQDN,
            [int[]]   $PortList,
            [string]  $OutputDir,
            [string]  $ChromePath,
            [int]     $ChromeTimeout,
            [int]     $ProcessTimeout
        )

        $schemaPorts = @{
            443  = 'https'
            8443 = 'https'
        }

        foreach ($port in $PortList) {
            $scheme  = if ($schemaPorts.ContainsKey($port)) { $schemaPorts[$port] } else { 'http' }
            $url     = "${scheme}://${FQDN}:${port}"
            $safe    = $FQDN -replace '[\\/:*?"<>|]', '_'
            $outFile = Join-Path $OutputDir "${safe}-${port}.png"

            Write-Host "  -> $url"
            Invoke-ChromeScreenshot -ChromePath $ChromePath -Url $url -OutFile $outFile `
                -ChromeTimeout $ChromeTimeout -ProcessTimeout $ProcessTimeout
        }
    }

    # ---------------------------------------------------------------------------
    # Main execution
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
        return
    }
    Write-Host "[*] Using browser: $ChromeExe"

    # Parse ports
    [int[]]$PortList = $Ports -split ',' | ForEach-Object { [int]$_.Trim() }
    Write-Host "[*] Ports: $($PortList -join ', ')"
    Write-Host "[*] Threads: $Threads"
    Write-Host "[*] Chrome timeout: ${ChromeTimeout}ms / Process kill timeout: ${ProcessTimeout}ms"
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Phase 1: Build target list (hostnames)
    # ---------------------------------------------------------------------------
    $Targets = @()

    switch ($PSCmdlet.ParameterSetName) {

        'HostList' {
            Write-Host "[*] Loading hostnames from: $HostList"
            $Targets = Get-Content $HostList | Where-Object { $_ -match '\S' }
            Write-Host "[*] $($Targets.Count) hosts loaded"
        }

        default {
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
            Invoke-Screenshot -FQDN $fqdn -PortList $PortList -OutputDir $OutDir `
                -ChromePath $ChromeExe -ChromeTimeout $ChromeTimeout -ProcessTimeout $ProcessTimeout
        }
    } else {
        $Targets | ForEach-Object -ThrottleLimit $Threads -Parallel {
            $fqdn           = $_
            $PortList       = $using:PortList
            $OutDir         = $using:OutDir
            $ChromeExe      = $using:ChromeExe
            $ChromeTimeout  = $using:ChromeTimeout
            $ProcessTimeout = $using:ProcessTimeout

            $schemaPorts = @{ 443 = 'https'; 8443 = 'https' }

            foreach ($port in $PortList) {
                $scheme  = if ($schemaPorts.ContainsKey($port)) { $schemaPorts[$port] } else { 'http' }
                $url     = "${scheme}://${fqdn}:${port}"
                $safe    = $fqdn -replace '[\\/:*?"<>|]', '_'
                $outFile = Join-Path $OutDir "${safe}-${port}.png"

                $argList = @(
                    "--headless",
                    "--disable-gpu",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    "--timeout=$ChromeTimeout",
                    "--screenshot=`"$outFile`"",
                    "`"$url`""
                )

                $proc = Start-Process -FilePath $ChromeExe `
                    -ArgumentList $argList `
                    -PassThru -NoNewWindow

                if (-not $proc.WaitForExit($ProcessTimeout)) {
                    $proc.Kill()
                }
            }
            Write-Host "[>] Done: $fqdn"
        }
    }

    Write-Host ("-" * 60)
    Write-Host "[*] Screenshotting complete. Output: $OutDir"
}
