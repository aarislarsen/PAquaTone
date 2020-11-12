function New-IPRange($start, $end)
{
    $ip1 = ([System.Net.IPAddress]$start).GetAddressBytes()
    [Array]::Reverse($ip1)
    $ip1 = ([System.Net.IPAddress]($ip1 -join '.')).Address
    $ip2 = ([System.Net.IPAddress]$end).GetAddressBytes()
    [Array]::Reverse($ip2)
    $ip2 = ([System.Net.IPAddress]($ip2 -join '.')).Address
    for ($x=$ip1; $x -le $ip2; $x++) 
    {
        $ip = ([System.Net.IPAddress]$x).GetAddressBytes()
        [Array]::Reverse($ip)
        $ip -join '.'
    }
}

function PAquaTone
{
    param($pathToIPs, $OutDir, $StartIp, $EndIP)

    #$ListOfIPs=Get-content $pathToIPs
    $ListOfIPs = New-IPRange $StartIp $EndIP
    $ResultList = @()

    Write-Host "Starting reverse name resolution of IPs"
    Write-Host "-------------------------------------------------"

    foreach ($IP in $ListOfIPs)
    {
        $ErrorActionPreference = "silentlycontinue"
        $Result = $null

        write-host -NoNewline "Resolving $IP : "
        $result = [System.Net.Dns]::gethostentry($IP)

        If ($Result)
        {
            $ResultList += [string]$Result.HostName
        }
        Else
        {
            #$ResultList += "$IP,unresolved"
        }
        Write-Host $Result.HostName
    }

    $ResultList | Out-File .\resolved.txt

    Write-Host "-------------------------------------------------"
    write-host "Reverse name resolution completed"
    Write-Host ""

    

    write-host "Screenshotting on ports 80,443,8000,8080, 8443 and 10000"
    Write-Host "-------------------------------------------------"

    foreach ($fqdn in $ResultList)
    {
        Write-Host "Sreenshotting " $fqdn
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-80.png" "http://$fqdn"
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-443.png" "https://$fqdn"
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-8080.png" "http://$fqdn:8080"
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-8000.png" "http://$fqdn:8000"
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-8443.png" "https://$fqdn:8443"
        & "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" --headless --screenshot="$OutDir\$fqdn-10000.png" "http://$fqdn:10000"
    }

    Write-Host "-------------------------------------------------"
    write-host "Screenshotting complete! Chrome might continue to work in the background, so give it a few minutes."
    Write-Host ""
    Write-Host "Execution completed"
}
