<#
Starts one application through the Windows elevation broker and waits for it.
Used by non-Steam shortcuts whose target genuinely needs administrator rights.
The script lives under Program Files, so an ordinary account cannot replace the
command Steam is asking Windows to elevate.
#>
param(
    [Parameter(Mandatory)] [string]$Executable,
    [string]$Arguments
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Executable -PathType Leaf)) {
    throw "Elevated application not found: $Executable"
}

$start = @{
    FilePath = $Executable
    Verb = 'RunAs'
    WorkingDirectory = (Split-Path $Executable -Parent)
    PassThru = $true
    Wait = $true
}
if ($Arguments) { $start.ArgumentList = $Arguments }

try {
    $process = Start-Process @start
    if ($process.ExitCode -ne 0) {
        Write-Warning "$([IO.Path]::GetFileName($Executable)) exited with code $($process.ExitCode)."
    }
} catch {
    Write-Warning "Could not start $Executable as administrator: $($_.Exception.Message)"
    Start-Sleep -Seconds 5
}
