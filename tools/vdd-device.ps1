# Elevated helper for the TravelDisplay host.
#
# Started through the scheduled task "TravelDisplay display driver", which runs with
# highest privileges and is owned by the user, so the unprivileged host can start it
# without a UAC prompt. schtasks cannot pass arguments, so the host writes its order
# into action.txt next to this script first:
#
#   enable <pid>   enable the driver's device node, then keep watching: while the host
#                  process <pid> is alive and guard-<pid>.txt exists, wait; if the host
#                  dies (guard file still there) disable the device so Windows falls
#                  back to the physical monitors. A normal disconnect deletes the guard
#                  file first, which ends the watch without touching the device.
#   disable        disable the device node (the monitor disappears completely).
#   restart        disable, then enable (also clears a Code 43).
#
# Everything is logged to vdd-device.log in the same folder.

$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$actionFile = Join-Path $dir "action.txt"
$logFile = Join-Path $dir "vdd-device.log"

function Log($msg) {
    Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg)
}

function Get-VddDevice {
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | Select-Object -First 1
}

function Enable-Vdd($device) {
    # Problem 22 = disabled; anything else non-OK (e.g. Code 43) needs a full cycle.
    if ($device.Status -eq "OK") { return }
    if ($device.Problem -ne 22) {
        $device | Disable-PnpDevice -Confirm:$false
        Start-Sleep -Seconds 1
    }
    $device | Enable-PnpDevice -Confirm:$false
}

function Disable-Vdd($device) {
    if ($device.Status -eq "OK" -or $device.Problem -ne 22) {
        $device | Disable-PnpDevice -Confirm:$false
    }
}

if (-not (Test-Path $actionFile)) { Log "no action file"; exit 1 }
$parts = ((Get-Content $actionFile -Raw).Trim() -split '\s+')
$action = $parts[0]
$device = Get-VddDevice
if (-not $device) { Log "device Root\MttVDD not found"; exit 2 }

switch ($action) {
    "enable" {
        Log "enable (status $($device.Status), problem $($device.Problem))"
        Enable-Vdd $device
        if ($parts.Count -ge 2) {
            $hostPid = [int]$parts[1]
            $guard = Join-Path $dir "guard-$hostPid.txt"
            Log "watching host pid $hostPid"
            while ((Get-Process -Id $hostPid -ErrorAction SilentlyContinue) -and (Test-Path $guard)) {
                Start-Sleep -Seconds 1
            }
            if (Test-Path $guard) {
                Log "host $hostPid died: disabling device"
                Remove-Item $guard -Force -ErrorAction SilentlyContinue
                $device = Get-VddDevice
                if ($device) { Disable-Vdd $device }
            } else {
                Log "host $hostPid released the device normally"
            }
        }
    }
    "disable" {
        Log "disable (status $($device.Status), problem $($device.Problem))"
        Disable-Vdd $device
    }
    "restart" {
        Log "restart"
        $device | Disable-PnpDevice -Confirm:$false
        Start-Sleep -Seconds 1
        $device | Enable-PnpDevice -Confirm:$false
    }
    default {
        Log "unknown action '$action'"
        exit 3
    }
}
