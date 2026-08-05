#Requires -RunAsAdministrator
<#
Creates a Hyper-V lab VM from a Windows 11 IoT Enterprise LTSC ISO to test
Consolize safely (shell replacement, autologon, power settings) without
touching the host. Gen 2 + Secure Boot + vTPM so Win11 installs cleanly.

Workflow:
  1. .\New-TestVm.ps1 -IsoPath "$env:USERPROFILE\Downloads\<ltsc>.iso"
  2. Start-VM consolize-lab; vmconnect.exe localhost consolize-lab
  3. Install Windows (IoT LTSC allows a local account, no MSA needed)
  4. Checkpoint-VM -Name consolize-lab -SnapshotName clean-install
  5. Break things at will, then:
     Restore-VMSnapshot -VMName consolize-lab -Name clean-install -Confirm:$false

Why a VM and not Docker: Windows containers have no interactive logon
session, no GUI and no Shell Launcher, so a shell replacement cannot be
exercised inside one. Hyper-V checkpoints give the same disposable-lab
ergonomics with a real session.
#>
param(
    [Parameter(Mandatory)] [string]$IsoPath,
    [string]$VmName = 'consolize-lab',
    [int]$MemoryGB = 8,
    [int]$CpuCount = 4,
    [int]$DiskGB = 80
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw @'
Hyper-V PowerShell module not found. Enable Hyper-V first (admin, then reboot):
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
'@
}
if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw "VM '$VmName' already exists." }

$vhdDir = Join-Path $env:PUBLIC 'Documents\Hyper-V\Virtual Hard Disks'
New-Item -ItemType Directory -Force -Path $vhdDir | Out-Null
$vhdPath = Join-Path $vhdDir "$VmName.vhdx"

Write-Host "Creating Gen 2 VM '$VmName' ($MemoryGB GB RAM, $CpuCount vCPU, $DiskGB GB disk)..."
New-VM -Name $VmName -Generation 2 `
    -MemoryStartupBytes ([int64]$MemoryGB * 1GB) `
    -NewVHDPath $vhdPath -NewVHDSizeBytes ([int64]$DiskGB * 1GB) | Out-Null
Set-VM -Name $VmName -ProcessorCount $CpuCount -CheckpointType Standard -AutomaticCheckpointsEnabled $false

Add-VMDvdDrive -VMName $VmName -Path $IsoPath
Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VMFirmware -VMName $VmName -FirstBootDevice (Get-VMDvdDrive -VMName $VmName)

# vTPM (Windows 11 requirement)
$guardian = Get-HgsGuardian UntrustedGuardian -ErrorAction SilentlyContinue
if (-not $guardian) { $guardian = New-HgsGuardian -Name UntrustedGuardian -GenerateCertificates }
$kp = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot
Set-VMKeyProtector -VMName $VmName -KeyProtector $kp.RawData
Enable-VMTPM -VMName $VmName

$switch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
if ($switch) { Get-VMNetworkAdapter -VMName $VmName | Connect-VMNetworkAdapter -SwitchName $switch.Name }

Write-Host ''
Write-Host "VM '$VmName' ready. Next:"
Write-Host "    Start-VM '$VmName'; vmconnect.exe localhost '$VmName'"
Write-Host "    (install Windows, then)  Checkpoint-VM -Name '$VmName' -SnapshotName clean-install"
Write-Host "    (to reset)               Restore-VMSnapshot -VMName '$VmName' -Name clean-install -Confirm:`$false"
