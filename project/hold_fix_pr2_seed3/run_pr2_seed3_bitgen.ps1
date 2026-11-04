$ErrorActionPreference = 'Stop'
$td = 'C:\Anlogic\TD_5.6.5_SP3_151.449\bin\td_commands_prompt.exe'
$work = $PSScriptRoot
$process = Start-Process `
    -FilePath $td `
    -WorkingDirectory $work `
    -WindowStyle Hidden `
    -RedirectStandardInput (Join-Path $work 'r298_pr2_seed3_bitgen.tcl') `
    -RedirectStandardOutput (Join-Path $work 'pr2_seed3_bitgen_stdout.log') `
    -RedirectStandardError (Join-Path $work 'pr2_seed3_bitgen_stderr.log') `
    -PassThru
Set-Content -LiteralPath (Join-Path $work 'pr2_seed3_bitgen_pid.txt') -Value $process.Id -Encoding ASCII
$process.WaitForExit()
Set-Content -LiteralPath (Join-Path $work 'pr2_seed3_bitgen_exit.txt') -Value $process.ExitCode -Encoding ASCII
exit $process.ExitCode
