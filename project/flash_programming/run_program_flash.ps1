$ErrorActionPreference = "Stop"
$work = $PSScriptRoot
$deliveryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$alias = "C:\Temp\HDMI_MULTIMEDIA_FINAL_SUBMISSION_PR2SEED3"
$bit = Join-Path $deliveryRoot "bitstream\HDMI_MULTIMEDIA_FINAL_1280x720_60.bit"
$expectedHash = "0031BECB9873F3F91C53D642F76F1701F75A064799E07F27D22B2F89EDAD0812"
$td = "C:\Anlogic\TD_5.6.5_SP3_151.449\bin\td_commands_prompt.exe"

if (-not (Test-Path -LiteralPath $alias)) {
    New-Item -ItemType Directory -Path (Split-Path $alias -Parent) -Force | Out-Null
    New-Item -ItemType Junction -Path $alias -Target $deliveryRoot | Out-Null
}
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $bit).Hash.ToUpperInvariant()
if ($actualHash -ne $expectedHash) {
    throw "Final bitstream hash mismatch before Flash programming: $actualHash"
}
$programmer = Get-PnpDevice -PresentOnly |
    Where-Object { $_.FriendlyName -eq "Anlogic AL-Link Mini" -and $_.Status -eq "OK" }
if (@($programmer).Count -ne 1) {
    throw "Expected exactly one healthy Anlogic AL-Link Mini programmer."
}
if (@(Get-Process -Name td_commands_prompt -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Another td_commands_prompt process is already running."
}

$preflight = [ordered]@{
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    bitstream = $bit
    bitstream_sha256 = $actualHash
    target_device = "EG4S20BG256"
    programmer = @($programmer | Select-Object Status, Class, FriendlyName, InstanceId)
    flash_capacity_mbit = 128
    flash_capacity_mib = 16
    flash_manufacturer_id_from_validated_same_board_log = "c8 (GigaDevice)"
    command = "download -bit <final.bit> -mode program_spi -v -spd 7 -sec 64 -cable 0 -flashsize 128"
    tf_or_flash_unrelated_data_write_requested = $false
}
$preflight | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $work "program_flash_preflight.json") -Encoding UTF8

$p = Start-Process `
    -FilePath $td `
    -WorkingDirectory $work `
    -WindowStyle Hidden `
    -RedirectStandardInput (Join-Path $work "program_flash.tcl") `
    -RedirectStandardOutput (Join-Path $work "program_flash.log") `
    -RedirectStandardError (Join-Path $work "program_flash.stderr.log") `
    -PassThru
Set-Content -LiteralPath (Join-Path $work "program_flash.pid.txt") -Value $p.Id -Encoding ASCII
$p.WaitForExit()
Set-Content -LiteralPath (Join-Path $work "program_flash.exit.txt") -Value $p.ExitCode -Encoding ASCII
exit $p.ExitCode
