# xgm-diag.ps1 - Read-only XG Mobile / eGPU diagnostics for XGMDriver.
#
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File xgm-diag.ps1
# It writes xgm-diag-<date>.txt to the Desktop. Nothing on the system is
# changed. Run it once in each state you want to compare, for example right
# after logging in, and again after accepting the Armoury Crate prompt.

param([string]$OutFile)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = $OutFile
if (-not $out) { $out = Join-Path ([Environment]::GetFolderPath('Desktop')) "xgm-diag-$stamp.txt" }
$lines = New-Object System.Collections.Generic.List[string]

function Section($title) {
    $lines.Add('')
    $lines.Add("===== $title =====")
}

function Add($text) {
    if ($null -eq $text) { return }
    foreach ($l in ($text | Out-String -Width 250) -split "`r?`n") {
        $lines.Add($l.TrimEnd())
    }
}

function Try-Add($block) {
    try { Add (& $block) } catch { Add "ERROR: $($_.Exception.Message)" }
}

function Reg-Values($path) {
    if (-not (Test-Path $path)) { return "(missing) $path" }
    $p = Get-ItemProperty -Path $path
    $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } |
        ForEach-Object {
            $v = $_.Value
            if ($v -is [int] -or $v -is [long]) { $v = '{0} (0x{0:X})' -f $v }
            elseif ($v -is [byte[]]) { $v = ($v | ForEach-Object { $_.ToString('X2') }) -join ' ' }
            '{0} = {1}' -f $_.Name, $v
        }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Section 'System'
Add "Date: $(Get-Date -Format 's')"
Add "Elevated: $isAdmin"
Try-Add { Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Format-List }
Try-Add { Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemSKUNumber | Format-List }
Try-Add { Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate | Format-List }
Try-Add { "Last boot: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)" }

Section 'XGMDriver install'
Try-Add { Reg-Values 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\XGMDriver' }
Try-Add { Get-ChildItem "$env:ProgramFiles\XGMDriver" -ErrorAction Stop | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize }
Try-Add { "AsusXGDriverInst.exe interposer present: " + (Test-Path "$env:SystemDrive\eSupport\eDriver\Software\Peripherals\ExternalGraphics\AsusXGDriverInst.exe") }
Try-Add { Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Fake XGM Device Publisher*' | Select-Object Subject, Thumbprint, NotAfter | Format-List }

Section 'Fake XGM device'
$xgm = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { ($_.FriendlyName -like 'Fake XGM Device*') -or ($_.HardwareID -like 'Root\FakeXGMDevice*') })
if ($xgm.Count -eq 0) { Add 'No Fake XGM Device found (XGMDriver is not installed or the device was removed)' }
foreach ($d in $xgm) {
    Try-Add { $d | Select-Object FriendlyName, Status, Present, Problem, InstanceId, @{n='HardwareID';e={$_.HardwareID -join ', '}} | Format-List }
    Try-Add { Reg-Values "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters" }
    Try-Add { 'HID children: ' + ((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_Children -ErrorAction SilentlyContinue).Data -join '; ') }
}

Section 'Armoury Crate eGPU state'
Try-Add { Reg-Values 'HKLM:\SOFTWARE\ASUS\eGPU' }
Add '--- GPU Switch'
Try-Add { Reg-Values 'HKLM:\SOFTWARE\ASUS\ARMOURY CRATE Service\GPU Switch' }
foreach ($f in 'settings.ini', 'action.ini') {
    $p = "$env:ProgramData\ASUS\ARMOURY CRATE Service\GPUSwitch\$f"
    Add "--- $p"
    if (Test-Path $p) { Try-Add { Get-Content $p -ErrorAction Stop } } else { Add '(missing)' }
}

Section 'Armoury Crate SE'
Try-Add { Get-Service -Name 'ArmouryCrateSEService', 'ArmouryCrateService', 'ASUSOptimization', 'ASUSSystemAnalysis' -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize }
$acse = "$env:ProgramFiles\ASUS\ARMOURY CRATE SE Service"
Try-Add { Get-ChildItem $acse -Recurse -Include 'ArmouryCrateSE.Service.exe', 'GPUSwitchPlugin.dll', 'ExternalGPUConfigHelper2.dll', 'GPUSwitchDialog.exe' -ErrorAction Stop | ForEach-Object { '{0}  {1}' -f $_.VersionInfo.FileVersion, $_.FullName } }
$loadConf = "$acse\ThrottleMonitorPlugin\Load.conf"
Add "--- $loadConf"
if (Test-Path $loadConf) { Try-Add { Get-Content $loadConf -ErrorAction Stop } } else { Add '(missing)' }
Try-Add { Get-Process -Name 'GHelper', 'ArmouryCrate*', 'GPUSwitch*', 'GPUTrayIcon' -ErrorAction SilentlyContinue | Select-Object Name, Id, Path | Format-Table -AutoSize }

Section 'ASUS ACPI / ATK'
Try-Add { Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'ATK|ASUS System Control|ASUS Precision|ASUS.*Interface' } | Select-Object FriendlyName, Status, Problem, InstanceId | Format-Table -AutoSize }

Section 'Display adapters (including not present)'
Try-Add { Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Select-Object FriendlyName, Status, Present, Problem, InstanceId | Format-Table -AutoSize }
Try-Add { Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, Status, PNPDeviceID | Format-Table -AutoSize }

Section 'AMD PCI devices (VEN_1002, including not present)'
Try-Add { Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object InstanceId -like 'PCI\VEN_1002*' | Select-Object FriendlyName, Class, Status, Present, Problem, InstanceId | Format-Table -AutoSize }

Section 'PCI bridges and root ports'
Try-Add {
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' -and $_.FriendlyName -match 'Root Port|PCI-to-PCI|PCI Express' } |
        ForEach-Object {
            $loc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationInfo -ErrorAction SilentlyContinue).Data
            $kids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Children -ErrorAction SilentlyContinue).Data
            [pscustomobject]@{ Name = $_.FriendlyName; Status = $_.Status; Present = $_.Present; Location = $loc; Children = ($kids -join '; '); InstanceId = $_.InstanceId }
        } | Format-Table -AutoSize -Wrap
}

Section 'PCI devices with a problem'
Try-Add { Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' -and $_.Present -and $_.Status -ne 'OK' } | Select-Object FriendlyName, Status, Problem, InstanceId | Format-Table -AutoSize }

Section 'System events, last 3 days (WHEA, PnP, display, ACPI)'
Try-Add {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 4000 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'WHEA|Kernel-PnP|Display|amdkmdag|ACPI|pci|nvlddmkm|Kernel-Power|UserPnp' -and $_.Level -le 3 } |
        Select-Object -First 80 TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Message';e={ ($_.Message -split "`r?`n")[0] }} |
        Format-Table -AutoSize -Wrap
}

Section 'Application crashes, last 3 days (Armoury Crate, AMD)'
Try-Add {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddDays(-3); Id = 1000, 1026 } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Armoury|GPUSwitch|ASUS|amdadlx|atiadlx|ADLX|Radeon|amdkmd|atiumd' } |
        Select-Object -First 30 TimeCreated, Id, @{n='Message';e={ (($_.Message -split "`r?`n") | Select-Object -First 6) -join ' | ' }} |
        Format-List
}

$lines | Set-Content -Path $out -Encoding UTF8
Write-Host "Saved: $out"
if (-not $isAdmin) { Write-Host 'Not elevated: some sections may be incomplete. Run PowerShell as administrator.' }
