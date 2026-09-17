# Elevated helper for the Relay host.
#
# Started through the scheduled task "Relay display driver", which runs with
# highest privileges and is owned by the user, so the unprivileged host can start it
# without a UAC prompt. schtasks cannot pass arguments, so the host writes its order
# into the configured request directory first:
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
# Logs and privileged device records live in the protected state directory.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestDir,
    [Parameter(Mandatory = $true)]
    [string]$StateDir
)

$ErrorActionPreference = "Stop"
$actionFile = Join-Path $RequestDir "action.txt"
$logFile = Join-Path $StateDir "vdd-device.log"

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
    Join-Path $StateDir "physical-$hostPid.txt"
}

function Physical-ReadyFile($hostPid) {
    Join-Path $StateDir "physical-$hostPid.ready"
}

function Physical-HeartbeatFile($hostPid) {
    Join-Path $RequestDir "physical-$hostPid.heartbeat"
}

function Restore-Physical($hostPid) {
    $state = Physical-StateFile $hostPid
    $ready = Physical-ReadyFile $hostPid
    $heartbeat = Physical-HeartbeatFile $hostPid
    $remaining = @()
    foreach ($instanceId in @(Get-Content -LiteralPath $state -ErrorAction SilentlyContinue)) {
        if (-not $instanceId) { continue }
        try {
            Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            $remaining += $instanceId
            Log "failed to restore physical monitor '$instanceId' for host ${hostPid}: $($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $heartbeat -Force -ErrorAction SilentlyContinue
    if ($remaining.Count -gt 0) {
        $remaining | Set-Content -LiteralPath $state
        return $false
    }
    Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
    Log "physical monitor devices restored for host $hostPid"
    return $true
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

switch ($action) {
    "enable" {
        $device = Get-VddDevice
        if (-not $device) { Log "device Root\MttVDD not found"; exit 2 }
        Log "enable (status $($device.Status), problem $($device.Problem))"
        Enable-Vdd $device
        if ($parts.Count -ge 2) {
            $hostPid = [int]$parts[1]
            $guard = Join-Path $RequestDir "guard-$hostPid.txt"
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
                        $restored = Restore-Physical $hostPid
                        $device = Get-VddDevice
                        if ($device) { Disable-Vdd $device }
                        if ($restored) { exit 0 } else { exit 5 }
                    }
                }
                Start-Sleep -Seconds 1
            }
            if (Test-Path $guard) {
                Log "host $hostPid died: restoring physical monitors and disabling device"
                Remove-Item $guard -Force -ErrorAction SilentlyContinue
                $restored = Restore-Physical $hostPid
                $device = Get-VddDevice
                if ($device) { Disable-Vdd $device }
                if (-not $restored) { exit 5 }
            } else {
                Log "host $hostPid released the device normally"
            }
        }
    }
    "disable" {
        $device = Get-VddDevice
        if (-not $device) { Log "device Root\MttVDD not found"; exit 2 }
        Log "disable (status $($device.Status), problem $($device.Problem))"
        Disable-Vdd $device
    }
    "restart" {
        $device = Get-VddDevice
        if (-not $device) { Log "device Root\MttVDD not found"; exit 2 }
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
        if (-not (Restore-Physical ([int]$parts[1]))) { exit 5 }
    }
    "unlock-stale" {
        $failed = $false
        foreach ($stateFile in @(Get-ChildItem -LiteralPath $StateDir -Filter 'physical-*.txt' -ErrorAction SilentlyContinue)) {
            if ($stateFile.BaseName -match '^physical-(\d+)$') {
                if (-not (Restore-Physical ([int]$Matches[1]))) { $failed = $true }
            }
        }
        if ($failed) { exit 5 }
    }
    default {
        Log "unknown action '$action'"
        exit 3
    }
}
