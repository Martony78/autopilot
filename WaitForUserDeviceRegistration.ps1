# WaitForUserDeviceRegistration.ps1
#
# Version 1.7
#
# Steve Prentice, 2020
#
# Contributor : Mathieu Ait Azzouzene Nov. 2024 (Test domain connectivity using DNS and port 389)
#
# Used to pause device ESP during Autopilot Hybrid Join to wait for
# the device to sucesfully register into AzureAD before continuing.
#
# Use IntuneWinAppUtil to wrap and deploy as a Windows app (Win32).
# See ReadMe.md for more information.
#
# Tip: Win32 apps only work as tracked apps in device ESP from 1903.
#
# Exits with return code 3010 to indicate a soft reboot is needed,
# which in theory it isn't, but it suited my purposes.

$DomainName = 'Contoso.com'

function Test-DomainConnectivity {
    Param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$DomainName,
        [Parameter(Position = 1, Mandatory = $false)]
        [switch]$TestAllDCs
    )

    # Resolve domain controllers
    $DCs = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$DomainName"

    if ($DCs) {
        $Connectivity = $false
        foreach ($DC in $DCs) {
            Write-Output "Testing connection to $($DC.Target)"
            
            # Test ping
            $pingResult = Test-Connection -ComputerName $DC.Target -Count 4
                        
            # Test LDAP port connectivity
            $netResult = Test-NetConnection -ComputerName $DC.Target -Port 389

            if ($pingResult.StatusCode -eq 0 -and $netResult.TcpTestSucceeded) {
                Write-Output "Connection to $($DC.Target) is successful."
                $Connectivity = $true
                #If not testing All DCs, return immediately $true
                if (-not $TestAllDCs) {
                    return $true
                }

            }
            else {
                Write-Output "Connection to $($DC.Target) failed."
            }
        }

        return $Connectivity
    }
    else {
        Write-Output "No domain controllers found for $DomainName."
        return $false
    }
}

# Create a tag file just so Intune knows this was installed
If (-Not (Test-Path "$($env:ProgramData)\DeviceRegistration\WaitForUserDeviceRegistration"))
{
    Mkdir "$($env:ProgramData)\DeviceRegistration\WaitForUserDeviceRegistration"
}
Set-Content -Path "$($env:ProgramData)\DeviceRegistration\WaitForUserDeviceRegistration\WaitForUserDeviceRegistration.ps1.tag" -Value "Installed"

# Start logging
Start-Transcript "$($env:ProgramData)\DeviceRegistration\WaitForUserDeviceRegistration\WaitForUserDeviceRegistration.log"

$filter304 = @{
  LogName = 'Microsoft-Windows-User Device Registration/Admin'
  Id = '304' # Automatic registration failed at join phase
}

$filter306 = @{
  LogName = 'Microsoft-Windows-User Device Registration/Admin'
  Id = '306' # Automatic registration Succeeded
}

$filter334 = @{
  LogName = 'Microsoft-Windows-User Device Registration/Admin'
  Id = '334' # Automatic device join pre-check tasks completed. The device can NOT be joined because a domain controller could not be located.
}

$filter335 = @{
  LogName = 'Microsoft-Windows-User Device Registration/Admin'
  Id = '335' # Automatic device join pre-check tasks completed. The device is already joined.
}

# Wait for up to 60 minutes, re-checking once a minute...
While (($counter++ -lt 60) -and (!$exitWhile)) {
    # Let's get some events...
    $events304   = Get-WinEvent -FilterHashtable $filter304   -MaxEvents 1 -EA SilentlyContinue
    $events306   = Get-WinEvent -FilterHashtable $filter306   -MaxEvents 1 -EA SilentlyContinue
    $events334   = Get-WinEvent -FilterHashtable $filter334   -MaxEvents 1 -EA SilentlyContinue
    $events335   = Get-WinEvent -FilterHashtable $filter335   -MaxEvents 1 -EA SilentlyContinue

    If ($events335) { $exitWhile = "True" }

    ElseIf ($events306) { $exitWhile = "True" }

    ElseIf ((Test-DomainConnectivity -DomainName $DomainName) -And $events334 -And !$events304) {
        Write-Host "RRAS dialled sucesfully. Trying Automatic-Device-Join task to create userCertificate..."
        Start-ScheduledTask "\Microsoft\Windows\Workplace Join\Automatic-Device-Join"
        Write-Host "Sleeping for 60s..."
        Start-Sleep -Seconds 60
    }

    Else {
        Write-Host "No events indicating successful device registration with Azure AD."
        Write-Host "Sleeping for 60s..."
        Start-Sleep -Seconds 60
        If ($events304) {
            Write-Host "Trying Automatic-Device-Join task again..."
            Start-ScheduledTask "\Microsoft\Windows\Workplace Join\Automatic-Device-Join"
            Write-Host "Sleeping for 5s..."
            Start-Sleep -Seconds 5
        }
    }
}

If ($events306) { 
    Write-Host $events306.Message
    Write-Host "Exiting with return code 3010 to indicate a soft reboot is needed."
    Stop-Transcript
    Exit 3010
}

If ($events335) { Write-Host $events335.Message }

Write-Host "Script complete, exiting."

Stop-Transcript
