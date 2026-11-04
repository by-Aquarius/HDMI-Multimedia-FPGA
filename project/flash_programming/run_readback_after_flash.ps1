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
    -RedirectStandardInput (Join-Path $work "readback_after_flash.tcl") `
    -RedirectStandardOutput (Join-Path $work "readback_after_flash.log") `
    -RedirectStandardError (Join-Path $work "readback_after_flash.stderr.log") `
    -PassThru
Set-Content -LiteralPath (Join-Path $work "readback_after_flash.pid.txt") -Value $p.Id -Encoding ASCII
$p.WaitForExit()
Set-Content -LiteralPath (Join-Path $work "readback_after_flash.exit.txt") -Value $p.ExitCode -Encoding ASCII
if ($p.ExitCode -eq 0) {
    $after = Join-Path $work "flash_after_16MiB.bin"
    if (-not (Test-Path -LiteralPath $after) -or (Get-Item $after).Length -ne 16777216) {
        throw "Post-program Flash readback is missing or has an unexpected size."
    }
    Get-FileHash -Algorithm SHA256 -LiteralPath $after |
        Format-List Path,Hash |
        Out-File -LiteralPath (Join-Path $work "flash_after_16MiB.sha256.txt") -Encoding utf8
}
exit $p.ExitCode
