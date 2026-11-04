$ErrorActionPreference = "Stop"
$work = $PSScriptRoot
$td = "C:\Anlogic\TD_5.6.5_SP3_151.449\bin\td_commands_prompt.exe"
if (@(Get-Process -Name td_commands_prompt -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Another td_commands_prompt process is already running."
}
$p = Start-Process `
    -FilePath $td `
    -WorkingDirectory $work `
    -WindowStyle Hidden `
    -RedirectStandardInput (Join-Path $work "reload_from_flash.tcl") `
    -RedirectStandardOutput (Join-Path $work "reload_from_flash.log") `
    -RedirectStandardError (Join-Path $work "reload_from_flash.stderr.log") `
    -PassThru
Set-Content -LiteralPath (Join-Path $work "reload_from_flash.pid.txt") -Value $p.Id -Encoding ASCII
$p.WaitForExit()
Set-Content -LiteralPath (Join-Path $work "reload_from_flash.exit.txt") -Value $p.ExitCode -Encoding ASCII
exit $p.ExitCode
