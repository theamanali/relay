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
    4. Installs the Relay service (LocalSystem): it runs the host inside the signed-in
       session as SYSTEM, so the lock and login screens stream and the PC can boot
       headless. State lives in %ProgramData%Relay (migrated from your
       %LOCALAPPDATA%Relay on first install).

  -Driver parsec installs parsec-vdd instead (fallback: no GPU choice, at most five
  fixed modes given with -Resolutions).

  Run from an elevated PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass
    .\tools\install-host.ps1
    .\tools\install-host.ps1 -SkipDriver      # driver already there: refresh service + exe
    .\tools\install-host.ps1 -Uninstall
    .\tools\install-host.ps1 -Driver parsec -Resolutions "3024x1964@120","1512x982@120"

.PARAMETER Driver
  mtt (default) or parsec.
.PARAMETER Resolutions
  parsec only: up to five "WxH@Hz" modes to register. MTT modes are created on demand.
.PARAMETER Uninstall
  Stop and remove the service, the old tasks and %ProgramFiles%Relay. Keeps the
  driver and %ProgramData%Relay (identity and pairings).
.PARAMETER SkipDriver
  Don't (re)install the driver, only settings/firewall/service.
#>
[CmdletBinding()]
param(
    [ValidateSet("mtt", "parsec")]
    [string]$Driver = "mtt",
    [string[]]$Resolutions = @("3024x1964@120", "2268x1473@120", "1512x982@120"),
    [switch]$Uninstall,
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

if ($Uninstall) {
    $exe = Join-Path $env:ProgramFiles "Relay\relay-host.exe"
    if (Get-Service Relay -ErrorAction SilentlyContinue) {
        & $exe service uninstall
        if ($LASTEXITCODE -ne 0) { throw "relay-host service uninstall failed ($LASTEXITCODE)" }
        Write-Host "Relay service removed."
    }
    foreach ($old in "Relay display driver", "Relay host") {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $env:ProgramFiles "Relay") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $env:ProgramFilesRelay. Driver and $env:ProgramDataRelay (identity, pairings) kept."
    exit 0
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

function Set-RelayAcl([string]$Path, [string[]]$Grants) {
    # Repair installations made by an older installer that accidentally left
    # this directory without a usable Administrators/user ACE.
    & takeown.exe /F $Path /A /R /D Y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "takeown failed for $Path (exit $LASTEXITCODE)" }
    & icacls.exe $Path /reset /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls reset failed for $Path (exit $LASTEXITCODE)" }
    # Apply inheritable ACEs to the directory itself. Passing /T here would
    # apply the (OI)(CI) form directly to files, where it is inherit-only and
    # leaves the script with no effective read/execute permission.
    $arguments = @($Path, "/inheritance:r", "/grant:r") + $Grants
    & icacls.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls grant failed for $Path (exit $LASTEXITCODE)" }
}

function Remove-LockedHelper([string]$Path, [string]$InstallingUser) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & takeown.exe /F $Path /A | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "takeown failed for $Path (exit $LASTEXITCODE)" }
    # A previous installer could leave this individual file with no effective
    # Administrators ACE. Grant the known installing identity access long
    # enough to replace it; the final directory ACL below removes write access.
    & icacls.exe $Path /grant:r "${InstallingUser}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "temporary icacls grant failed for $Path (exit $LASTEXITCODE)" }
    Remove-Item -LiteralPath $Path -Force
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

    # --- 2. leftovers from the elevated-helper era -----------------------------
    # Device changes are done by the Relay service itself now (section 4);
    # the helper task, its script and the registry pointers are removed.
    foreach ($old in "Relay display driver", "Relay host",
                     "TravelDisplay display driver", "TravelDisplay display driver restart", "TravelDisplay host") {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -Path $regKey -Name HelperStatePath -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $regKey -Name HelperPrivateStatePath -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $vddDir "vdd-device.ps1") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:ProgramFiles "Relay\vdd-device.ps1") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:ProgramData "Relay\Requests") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:ProgramData "Relay\State") -Recurse -Force -ErrorAction SilentlyContinue

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

# --- 4. the Relay service ---------------------------------------------------
# Runs as LocalSystem and keeps the host alive inside the signed-in session
# (as SYSTEM too), which is what lets it stream the lock and login screens
# and flip device nodes without any helper. It runs a copy of the exe from
# %ProgramFiles%\Relay, so a cargo build never fights the running service.
$built = Join-Path $root "host\target\release\relay-host.exe"
if (-not (Test-Path $built)) {
    throw "build the release host first: cd host; cargo build --release"
}
$installDir = Join-Path $env:ProgramFiles "Relay"
$exe = Join-Path $installDir "relay-host.exe"
$stateDir = Join-Path $env:ProgramData "Relay"

# Retire the previous logon-task host before migrating its state or starting
# the service. Removing a scheduled task does not stop its already-running
# supervisor or child; either one can keep the single-instance mutex and make
# the new service worker treat startup as a clean "Quit until next sign-in".
Unregister-ScheduledTask -TaskName "Relay host" -Confirm:$false -ErrorAction SilentlyContinue
if (Get-Service Relay -ErrorAction SilentlyContinue) {
    Stop-Service Relay -Force -ErrorAction SilentlyContinue
}
$runningHosts = @(Get-Process relay-host -ErrorAction SilentlyContinue)
if ($runningHosts.Count -gt 0) {
    Write-Host "Stopping $($runningHosts.Count) previous Relay host process(es) ..."
    $runningHosts | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Get-Process relay-host -ErrorAction SilentlyContinue) {
        throw "could not stop every previous Relay host process"
    }
}

New-Item -ItemType Directory -Force $installDir, $stateDir | Out-Null

# State that used to be per user: the host's identity is what the Mac has
# paired with, so it must come along. Only when the machine-wide dir has none.
$oldState = Join-Path $env:LOCALAPPDATA "Relay"
if (-not (Test-Path (Join-Path $stateDir "identity.key")) -and (Test-Path (Join-Path $oldState "identity.key"))) {
    foreach ($f in "identity.key", "paired-clients.txt", "pin.txt", "display-snapshot.bin") {
        if (Test-Path (Join-Path $oldState $f)) { Copy-Item (Join-Path $oldState $f) $stateDir -Force }
    }
    Write-Host "Moved identity, pairings and PIN from $oldState to $stateDir"
}
# Everyone may read the PIN and the paired list (relay-host pin/paired work
# unelevated); only SYSTEM and administrators may read the identity key.
& icacls.exe $stateDir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F" "BUILTIN\Users:(OI)(CI)RX" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed for $stateDir (exit $LASTEXITCODE)" }
$identity = Join-Path $stateDir "identity.key"
if (Test-Path $identity) {
    & icacls.exe $identity /inheritance:r /grant:r "SYSTEM:F" "BUILTIN\Administrators:F" | Out-Null
}

# Install the service's own copy of the exe.
Copy-Item $built $exe -Force
& $exe service install
if ($LASTEXITCODE -ne 0) { throw "relay-host service install failed ($LASTEXITCODE)" }
Write-Host "Relay service installed and running ($exe). The tray icon appears in the signed-in session."

Write-Host ""
Write-Host "Done. Check: Get-Service Relay (Running), the Relay tray icon, then connect from the Mac."
