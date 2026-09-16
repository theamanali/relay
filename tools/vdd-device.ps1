# Elevated helper for the Relay host.
#
# Started through the scheduled task "Relay display driver", which runs with
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
#   lock-physical <pid>
#                  remember and disable every currently enabled physical monitor
#                  device so a fullscreen game cannot reactivate its display path.
#                  The enable watcher restores them if the host heartbeat is
#                  stale for 10 seconds, including when the host is still alive.
#   unlock-physical <pid>
#                  re-enable exactly the devices recorded for that session.
#   unlock-stale   restore devices recorded by any abandoned session.
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

function Physical-StateFile($hostPid) {
    Join-Path $dir "physical-$hostPid.txt"
}

function Physical-ReadyFile($hostPid) {
    Join-Path $dir "physical-$hostPid.ready"
}

function Physical-HeartbeatFile($hostPid) {
    Join-Path $dir "physical-$hostPid.heartbeat"
}

function Restore-Physical($hostPid) {
    $state = Physical-StateFile $hostPid
    $ready = Physical-ReadyFile $hostPid
    $heartbeat = Physical-HeartbeatFile $hostPid
    if (Test-Path $state) {
        foreach ($instanceId in (Get-Content -LiteralPath $state -ErrorAction SilentlyContinue)) {
            if ($instanceId) {
                Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Continue
            }
        }
    }
    Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $heartbeat -Force -ErrorAction SilentlyContinue
    Log "physical monitor devices restored for host $hostPid"
}

function Lock-Physical($hostPid) {
    $state = Physical-StateFile $hostPid
    $ready = Physical-ReadyFile $hostPid
    $heartbeat = Physical-HeartbeatFile $hostPid
    Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $heartbeat -Force -ErrorAction SilentlyContinue
    $physical = Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq 'OK' -and
            -not ($_.HardwareID -contains 'MONITOR\MTT1337')
        }
    @($physical | ForEach-Object { $_.InstanceId }) | Set-Content -LiteralPath $state
    foreach ($monitor in $physical) {
        $monitor | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
    }
    New-Item -ItemType File -Path $heartbeat -Force | Out-Null
    New-Item -ItemType File -Path $ready -Force | Out-Null
    Log "locked $(@($physical).Count) physical monitor device(s) for host $hostPid"
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
                $physicalReady = Physical-ReadyFile $hostPid
                if (Test-Path $physicalReady) {
                    $heartbeat = Physical-HeartbeatFile $hostPid
                    $heartbeatAge = if (Test-Path $heartbeat) {
                        ((Get-Date) - (Get-Item -LiteralPath $heartbeat).LastWriteTime).TotalSeconds
                    } else {
                        [double]::PositiveInfinity
                    }
                    if ($heartbeatAge -gt 10) {
                        Log "host $hostPid display heartbeat stale ($([math]::Round($heartbeatAge, 1))s): restoring physical monitors and disabling device"
                        Remove-Item $guard -Force -ErrorAction SilentlyContinue
                        Restore-Physical $hostPid
                        $device = Get-VddDevice
                        if ($device) { Disable-Vdd $device }
                        exit 0
                    }
                }
                Start-Sleep -Seconds 1
            }
            if (Test-Path $guard) {
                Log "host $hostPid died: restoring physical monitors and disabling device"
                Remove-Item $guard -Force -ErrorAction SilentlyContinue
                Restore-Physical $hostPid
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
    "lock-physical" {
        if ($parts.Count -lt 2) { Log "lock-physical missing pid"; exit 4 }
        Lock-Physical ([int]$parts[1])
    }
    "unlock-physical" {
        if ($parts.Count -lt 2) { Log "unlock-physical missing pid"; exit 4 }
        Restore-Physical ([int]$parts[1])
    }
    "unlock-stale" {
        Get-ChildItem -LiteralPath $dir -Filter 'physical-*.txt' -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.BaseName -match '^physical-(\d+)$') {
                    Restore-Physical ([int]$Matches[1])
                }
            }
    }
    default {
        Log "unknown action '$action'"
        exit 3
    }
}
