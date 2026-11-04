param(
    [ValidateSet("Validate", "Rebuild", "Bitgen")]
    [string]$Mode = "Validate"
)

$ErrorActionPreference = "Stop"
$deliveryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$alias = "C:\Temp\HDMI_MULTIMEDIA_FINAL_SUBMISSION_PR2SEED3"

if (Test-Path -LiteralPath $alias) {
    $item = Get-Item -LiteralPath $alias -Force
    $actualTarget = [IO.Path]::GetFullPath([string]$item.Target)
    if ($actualTarget.TrimEnd('\') -ne $deliveryRoot.TrimEnd('\')) {
        throw "ASCII alias exists with a different target: $alias -> $actualTarget"
    }
}
else {
    New-Item -ItemType Directory -Path (Split-Path $alias -Parent) -Force | Out-Null
    New-Item -ItemType Junction -Path $alias -Target $deliveryRoot | Out-Null
}

$work = Join-Path $alias "project\hold_fix_pr2_seed3"
$td = "C:\Anlogic\TD_6.0.0\bin\td_commands_prompt.exe"
$fallbackTd = "C:\Anlogic\TD_5.6.5_SP3_151.449\bin\td_commands_prompt.exe"
if (-not (Test-Path -LiteralPath $td)) {
    $td = $fallbackTd
}
if (-not (Test-Path -LiteralPath $td)) {
    throw "Anlogic TD td_commands_prompt.exe was not found."
}

$commandFile = switch ($Mode) {
    "Validate" { "validate_delivery.tcl" }
    "Rebuild" { "rebuild_from_gate.tcl" }
    "Bitgen" { "bitgen_from_routed.tcl" }
}
$stem = "delivery_$($Mode.ToLowerInvariant())"
$process = Start-Process `
    -FilePath $td `
    -WorkingDirectory $work `
    -WindowStyle Hidden `
    -RedirectStandardInput (Join-Path $work $commandFile) `
    -RedirectStandardOutput (Join-Path $work "$stem.log") `
    -RedirectStandardError (Join-Path $work "$stem.stderr.log") `
    -PassThru
$process.WaitForExit()
Set-Content -LiteralPath (Join-Path $work "$stem.exit.txt") -Value $process.ExitCode -Encoding ASCII
exit $process.ExitCode
