<#
.SYNOPSIS
  One-time, elevated setup for the Relay host on this PC.

.DESCRIPTION
  Default (-Driver mtt): installs MikeTheTech's Virtual Display Driver, the open-source
  signed IddCx driver whose render GPU and modes the host controls at runtime:
    1. Creates C:\VirtualDisplayDriver\vdd_settings.xml from tools\vdd_settings.template.xml,
       points the driver at it (HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH) and
       grants your user write access so the unelevated host can rewrite it per session.
    2. Downloads nefcon + the driver-only release zip, trusts the driver's certificate,
       creates the Root\MttVDD device node and installs the INF.
    3. Opens the firewall for the host's TCP port and for mDNS.
    4. Optionally registers a logon task so the host starts automatically (-AutoStart),
       which matters when the PC runs headless and the Mac is its only display.

  -Driver parsec installs parsec-vdd instead (fallback: no GPU choice, at most five
  fixed modes given with -Resolutions).

  Run from an elevated PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass
    .\tools\install-host.ps1
    .\tools\install-host.ps1 -AutoStart
    .\tools\install-host.ps1 -Driver parsec -Resolutions "3024x1964@120","1512x982@120"

.PARAMETER Driver
  mtt (default) or parsec.
.PARAMETER Resolutions
  parsec only: up to five "WxH@Hz" modes to register. MTT modes are created on demand.
.PARAMETER AutoStart
  Register a scheduled task that runs the release host binary at logon.
.PARAMETER SkipDriver
  Don't (re)install the driver, only settings/firewall/task.
#>
[CmdletBinding()]
param(
    [ValidateSet("mtt", "parsec")]
    [string]$Driver = "mtt",
    [string[]]$Resolutions = @("3024x1964@120", "2268x1473@120", "1512x982@120"),
    [switch]$AutoStart,
    [switch]$SkipDriver,
    [int]$Port = 8468
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$downloads = Join-Path $root "tools\downloads"
New-Item -ItemType Directory -Force $downloads | Out-Null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this from an elevated (Administrator) PowerShell."
}

function Get-Download($Url, $Name) {
    $path = Join-Path $downloads $Name
    if (-not (Test-Path $path)) {
        Write-Host "Downloading $Url ..."
        Invoke-WebRequest -Uri $Url -OutFile $path
    }
    return $path
}

function Get-DeviceByHardwareId($HardwareId) {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains $HardwareId } | Select-Object -First 1
}

# The user that will run the host (not the elevated admin identity, if they differ).
$hostUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }

# =============================================================================
if ($Driver -eq "mtt") {
    $vddDir = "C:\VirtualDisplayDriver"
    $settings = Join-Path $vddDir "vdd_settings.xml"
    $regKey = "HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver"
    $template = Join-Path $root "tools\vdd_settings.template.xml"

    # --- 1. settings file + registry pointer, before the driver first starts ---
    New-Item -ItemType Directory -Force $vddDir | Out-Null
    if (Test-Path $settings) {
        Copy-Item $settings "$settings.previous" -Force
        Write-Host "Replaced $settings (previous copy kept as vdd_settings.xml.previous)"
    } else {
        Write-Host "Created $settings"
    }
    Copy-Item $template $settings -Force
    New-Item -Path $regKey -Force | Out-Null
    New-ItemProperty -Path $regKey -Name VDDPATH -PropertyType String -Value $vddDir -Force | Out-Null
    # The host runs unelevated and merges each Mac's panel size into the file.
    & icacls $vddDir /grant "${hostUser}:(OI)(CI)M" /T | Out-Null
    Write-Host "Granted $hostUser modify rights on $vddDir"

    # --- 2. elevated helper task: the only privileged thing the host ever needs
    # The driver reads its settings when its device starts, and its own reload
    # command crashes it, so the host enables/disables the device node instead
    # (which also makes the virtual monitor vanish completely between sessions).
    # A task that runs with highest privileges can be started by its owner
    # without a UAC prompt. Keep its executable script and device-state records
    # outside the host-writable request directory.
    $helperInstallDir = Join-Path $env:ProgramFiles "Relay"
    $helperScript = Join-Path $helperInstallDir "vdd-device.ps1"
    $helperRoot = Join-Path $env:ProgramData "Relay"
    $helperRequests = Join-Path $helperRoot "Requests"
    $helperState = Join-Path $helperRoot "State"
    New-Item -ItemType Directory -Force $helperInstallDir, $helperRequests, $helperState | Out-Null
    Copy-Item (Join-Path $root "tools\vdd-device.ps1") $helperScript -Force
    Remove-Item (Join-Path $vddDir "vdd-device.ps1") -Force -ErrorAction SilentlyContinue
    & icacls $helperInstallDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-11:(OI)(CI)RX" /T | Out-Null
    & icacls $helperRequests /grant "${hostUser}:(OI)(CI)M" /T | Out-Null
    & icacls $helperState /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${hostUser}:(OI)(CI)RX" /T | Out-Null
    New-ItemProperty -Path $regKey -Name HelperStatePath -PropertyType String -Value $helperRequests -Force | Out-Null
    New-ItemProperty -Path $regKey -Name HelperPrivateStatePath -PropertyType String -Value $helperState -Force | Out-Null
    $helperTask = "Relay display driver"
    $helperArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helperScript`" -RequestDir `"$helperRequests`" -StateDir `"$helperState`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $helperArgs
    $principal = New-ScheduledTaskPrincipal -UserId $hostUser -LogonType Interactive -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    Register-ScheduledTask -TaskName $helperTask -Action $action -Principal $principal -Settings $taskSettings -Force | Out-Null
    # Names from before the rename to Relay.
    foreach ($old in "TravelDisplay display driver", "TravelDisplay display driver restart", "TravelDisplay host") {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host "Scheduled task '$helperTask' registered (guards the virtual and physical monitor devices for the host)."

    # --- 3. driver ------------------------------------------------------------
    $device = Get-DeviceByHardwareId "Root\MttVDD"
    if ($SkipDriver) {
        Write-Host "Skipping driver install."
    } elseif ($device) {
        Write-Host "MTT Virtual Display Driver already present ($($device.Status))."
    } else {
        $release = "25.7.23"
        $driverZip = Get-Download "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/$release/VirtualDisplayDriver-x86.Driver.Only.zip" "VirtualDisplayDriver-$release-x64.zip"
        $nefconZip = Get-Download "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip" "nefcon_v1.14.0.zip"

        $work = Join-Path $downloads "mtt-$release"
        if (Test-Path $work) { Remove-Item -Recurse -Force $work }
        Expand-Archive -Path $driverZip -DestinationPath (Join-Path $work "driver") -Force
        Expand-Archive -Path $nefconZip -DestinationPath (Join-Path $work "nefcon") -Force

        $inf = Get-ChildItem -Path (Join-Path $work "driver") -Recurse -Filter "MttVDD.inf" | Select-Object -First 1
        $cat = Get-ChildItem -Path (Join-Path $work "driver") -Recurse -Filter "*.cat" | Select-Object -First 1
        $nefcon = Get-ChildItem -Path (Join-Path $work "nefcon") -Recurse -Filter "nefconc.exe" | Where-Object { $_.FullName -match "x64" } | Select-Object -First 1
        if (-not $inf -or -not $cat -or -not $nefcon) { throw "unexpected archive layout under $work" }

        # Trust the signer so the (signed) driver installs without a prompt.
        $signer = (Get-AuthenticodeSignature $cat.FullName).SignerCertificate
        if ($signer) {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
            $store.Open("ReadWrite"); $store.Add($signer); $store.Close()
            Write-Host "Trusted publisher: $($signer.Subject)"
        }

        Write-Host "Installing driver from $($inf.FullName) ..."
        & $nefcon.FullName install $inf.FullName "Root\MttVDD"
        if ($LASTEXITCODE -ne 0) { throw "nefcon exited with $LASTEXITCODE" }
        Start-Sleep -Seconds 3
        $device = Get-DeviceByHardwareId "Root\MttVDD"
        if (-not $device) { throw "driver installed but the Root\MttVDD device did not appear" }
        Write-Host "Driver installed: $($device.FriendlyName) ($($device.Status))"
    }

    # --- 4. leave the device disabled: the monitor exists only while a Mac is connected
    if ($device) {
        if ($device.Status -eq "OK" -or $device.Problem -ne 22) {
            $device | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
        $device = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains "Root\MttVDD" } | Select-Object -First 1
        Write-Host "Device status: $($device.Status) (disabled until the host needs it)"
    }
}
# =============================================================================
else {
    $driverUrl = "https://builds.parsec.app/vdd/parsec-vdd-0.45.0.0.exe"   # Windows 10 21H2+ / 11
    $device = Get-DeviceByHardwareId "Root\Parsec\VDA"
    if ($SkipDriver) {
        Write-Host "Skipping driver install."
    } elseif ($device) {
        Write-Host "Parsec Virtual Display Driver already present ($($device.Status))."
    } else {
        $installer = Get-Download $driverUrl "parsec-vdd-0.45.0.0.exe"
        Write-Host "Installing parsec-vdd (silent)..."
        $p = Start-Process -FilePath $installer -ArgumentList "/S" -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "driver installer exited with $($p.ExitCode)" }
        Start-Sleep -Seconds 2
        $device = Get-DeviceByHardwareId "Root\Parsec\VDA"
        if (-not $device) { throw "driver installed but the Root\Parsec\VDA device did not appear" }
        Write-Host "Driver installed: $($device.FriendlyName) ($($device.Status))"
    }

    # parsec-vdd only offers what is registered here (five slots).
    $key = "HKLM:\SOFTWARE\Parsec\vdd"
    New-Item -Path $key -Force | Out-Null
    Get-ChildItem $key -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    $slot = 0
    foreach ($r in $Resolutions | Select-Object -First 5) {
        if ($r -notmatch '^(\d+)x(\d+)@(\d+)$') { throw "bad resolution '$r' (want WxH@Hz)" }
        $sub = New-Item -Path (Join-Path $key $slot) -Force
        New-ItemProperty -Path $sub.PSPath -Name width  -PropertyType DWord -Value ([int]$Matches[1]) -Force | Out-Null
        New-ItemProperty -Path $sub.PSPath -Name height -PropertyType DWord -Value ([int]$Matches[2]) -Force | Out-Null
        New-ItemProperty -Path $sub.PSPath -Name hz     -PropertyType DWord -Value ([int]$Matches[3]) -Force | Out-Null
        Write-Host "Resolution slot $slot = $r"
        $slot++
    }
}

# --- 3. firewall ------------------------------------------------------------
foreach ($rule in @(
    @{ Name = "Relay host (TCP $Port)"; Proto = "TCP"; Port = $Port },
    @{ Name = "Relay mDNS (UDP 5353)";  Proto = "UDP"; Port = 5353 }
)) {
    Remove-NetFirewallRule -DisplayName ($rule.Name -replace '^Relay', 'TravelDisplay') -ErrorAction SilentlyContinue
    if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol $rule.Proto -LocalPort $rule.Port -Action Allow -Profile Any | Out-Null
        Write-Host "Firewall rule added: $($rule.Name)"
    } else {
        Write-Host "Firewall rule present: $($rule.Name)"
    }
}

# --- 4. auto start ----------------------------------------------------------
if ($AutoStart) {
    $exe = Join-Path $root "host\target\release\relay-host.exe"
    if (-not (Test-Path $exe)) {
        throw "build the release host first: cd host; cargo build --release"
    }
    $taskName = "Relay host"
    $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory (Split-Path $exe)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited -Force | Out-Null
    Write-Host "Scheduled task '$taskName' registered (runs at logon, restarts if it exits)."
}

Write-Host ""
Write-Host "Done. Test the driver with:  host\target\release\relay-host.exe attach-test --width 3024 --height 1964 --hz 120"
