# Finding 6 A/B: a --no-vdd dev host killed without an mDNS goodbye and
# restarted after 5 s, while the Mac's picker is open. Run elevated from the
# repo root:  .\tools\finding6-check.ps1 -Build old   (installed exe)
#             .\tools\finding6-check.ps1 -Build new   (this build)
# No virtual display, no topology change. Starts the Relay service again at
# the end, even on failure.
param([ValidateSet('old', 'new')][string]$Build = 'new', [int]$Gap = 5, [int]$Watch = 75, [int]$Before = 20)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$exe = if ($Build -eq 'old') { "$env:ProgramFiles\Relay\relay-host.exe" } else { "$repo\host\target\release\relay-host.exe" }
$browse = "$repo\host\target\release\browse.exe"
$out = "$env:TEMP\finding6-$Build"
"exe $exe  sha256 $((Get-FileHash $exe).Hash)"

function Stamp($msg) { "{0:HH:mm:ss}  {1}" -f (Get-Date), $msg }
function Kill-DevHost { Get-Process relay-host -ErrorAction SilentlyContinue | Where-Object Path -eq $exe | Stop-Process -Force }

Stop-Service Relay
try {
    # The worker quits on the service's stop event; never kill it here.
    for ($i = 0; $i -lt 50 -and (Get-CimInstance Win32_Process -Filter "name='relay-host.exe'" | Where-Object CommandLine -match ' worker'); $i++) { Start-Sleep -Milliseconds 200 }
    if (Get-CimInstance Win32_Process -Filter "name='relay-host.exe'" | Where-Object CommandLine -match ' worker') { throw 'the worker is still running' }
    Kill-DevHost
    Start-Process $exe '--no-vdd -v' -RedirectStandardError "$out-1.log" -NoNewWindow
    Stamp 'host 1 started. On the Mac: the PC should be listed as Paired.'
    Start-Sleep $Before
    Kill-DevHost
    Stamp 'host 1 KILLED (no goodbye). On the Mac: select the PC and click Connect NOW (it should fail).'
    Start-Sleep $Gap
    Start-Process $exe '--no-vdd -v' -RedirectStandardError "$out-2.log" -NoNewWindow
    $t0 = Get-Date
    Stamp "host 2 started. Note when the Mac's row comes back (if it does)."
    Start-Process $browse "--seconds $Watch" -RedirectStandardOutput "$out-browse.txt" -NoNewWindow
    for ($i = 5; $i -le $Watch; $i += 5) { Start-Sleep 5; Stamp ("+{0} s since host 2 started" -f [int]((Get-Date) - $t0).TotalSeconds) }
}
finally {
    Kill-DevHost
    Start-Service Relay
    Stamp "Relay service: $((Get-Service Relay).Status)"
    "--- host 2 mDNS lines"
    Select-String -Path "$out-2.log" -Pattern 'advertising|re-announc|client connected|ended' | ForEach-Object Line
    "--- browse (PC side)"
    Get-Content "$out-browse.txt" -ErrorAction SilentlyContinue | Select-String 'port|gone'
    "logs: $out-*.log"
}
