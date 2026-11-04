$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BuildRoot = "D:\Users\ASUS\Desktop\FPGAANLU\task1_system\_codex_audit_national_award\left_hud_modes_r298"
$OriginalSource = "D:\Users\ASUS\Desktop\FPGAANLU\task1_system\baseline\video\H43_LEFT_HUD_MODES_R298_20261103"
$ExpectedSdcHash = "9F840A2ECFAD5A63F0FA10E7654E01D9167E04597F44FBAD442D72BBA3BB9084"
$ExpectedBitHash = "0031BECB9873F3F91C53D642F76F1701F75A064799E07F27D22B2F89EDAD0812"
$ExpectedDbHash = "27EF5C3B7822C9F694A564F5698143414AAA353DCFBE87D7C99D30071A9B48CA"
$ExpectedOldBitHash = "666EC4267A6B2A9CFBCC580818BA02D14DF70D9F9FEC235D668B4A491FF89564"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Generated = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-RelPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return $full.Substring($Root.Length + 1).Replace("\", "/")
}

function Write-JsonFile([string]$Path, [object]$Value) {
    $json = ($Value | ConvertTo-Json -Depth 100) + "`n"
    [IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Normalize-SourceText([string]$Path) {
    $text = [IO.File]::ReadAllText(
        $Path,
        [Text.Encoding]::GetEncoding(28591)
    )
    $initEvaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $name = [IO.Path]::GetFileName($match.Groups[2].Value.Replace("\", "/"))
        return $match.Groups[1].Value + $name + $match.Groups[3].Value
    }
    $text = [regex]::Replace(
        $text,
        '(?i)(\.INIT_FILE\s*\(\s*")([^"]+)(")',
        $initEvaluator
    )
    $readmemEvaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $name = [IO.Path]::GetFileName($match.Groups[2].Value.Replace("\", "/"))
        return $match.Groups[1].Value + $name + $match.Groups[3].Value
    }
    $text = [regex]::Replace(
        $text,
        '(?i)(\$readmem[hb]\s*\(\s*")([^"]+)(")',
        $readmemEvaluator
    )
    $includeEvaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $name = [IO.Path]::GetFileName($match.Groups[2].Value.Replace("\", "/"))
        return $match.Groups[1].Value + $name + $match.Groups[3].Value
    }
    $text = [regex]::Replace(
        $text,
        '(?i)(`include\s+")([^"]+)(")',
        $includeEvaluator
    )
    return $text
}

$Sdc = Join-Path $Root "constraints\media_terminal_top.sdc"
$Adc = Join-Path $Root "constraints\media_terminal_top.adc"
$Bit = Join-Path $Root "bitstream\HDMI_MULTIMEDIA_FINAL_1280x720_60.bit"
$OldBit = Join-Path $Root "bitstream\backup\FAILED_KNOWN_2HOLD\HDMI_MULTIMEDIA_FINAL_1280x720_60_OLD_FAILED_2HOLD.bit"
$ProjectAl = Join-Path $Root "project\HDMI_MULTIMEDIA_FINAL.al"
$RoutedDb = Join-Path $Root "project\hold_fix_pr2_seed3\r298_pr2_seed3_routed.db"
$GateDb = Join-Path $Root "project\hold_fix_pr2_seed3\r298_gate.db"
$PlaceDb = Join-Path $Root "project\hold_fix_pr2_seed3\r298_pr2_seed3_place.db"
$ReportRoot = Join-Path $Root "reports\pr2_seed3"
$RouteLog = Join-Path $ReportRoot "pr2_seed3_r298_stdout.log"
$BitgenLog = Join-Path $ReportRoot "pr2_seed3_bitgen_stdout.log"
$PostTiming = Join-Path $ReportRoot "post_bitgen_timing_simple.rpt"
$PostException = Join-Path $ReportRoot "post_bitgen_timing_exception.rpt"
$PostIgnored = Join-Path $ReportRoot "post_bitgen_timing_ignored.rpt"
$DeliveryValidationDir = Join-Path $ReportRoot "delivery_validation"
$DeliveryValidationLog = Join-Path $DeliveryValidationDir "delivery_validate.log"
$DeliveryValidationExit = Join-Path $DeliveryValidationDir "delivery_validate.exit.txt"
$DeliveryValidationTiming = Join-Path $DeliveryValidationDir "timing_simple.rpt"
$ArchiveDir = Join-Path $Root "reports\archive\OLD_R298_KNOWN_2HOLD"
$FlashRoot = Join-Path $Root "reports\flash_programming"
$FlashProgramLog = Join-Path $FlashRoot "program_flash.log"
$FlashProgramExit = Join-Path $FlashRoot "program_flash.exit.txt"
$FlashReloadLog = Join-Path $FlashRoot "reload_from_flash.log"
$FlashReloadExit = Join-Path $FlashRoot "reload_from_flash.exit.txt"
$FlashReadbackLog = Join-Path $FlashRoot "readback_after_flash.log"
$FlashReadbackExit = Join-Path $FlashRoot "readback_after_flash.exit.txt"
$FlashCompare = Join-Path $FlashRoot "flash_compare.json"
$FlashSlots = Join-Path $FlashRoot "flash_slot_analysis.json"
$PostFlashSerial = Join-Path $FlashRoot "serial_results.json"
$PostFlashSerialLog = Join-Path $FlashRoot "serial_queries.log"
$BoardSramReport = Join-Path $Root "reports\pr2_seed3\board_test\BOARD_TEST_REPORT.json"

foreach ($path in @(
    $Sdc, $Adc, $Bit, $OldBit, $ProjectAl, $RoutedDb, $GateDb, $PlaceDb,
    $RouteLog, $BitgenLog, $PostTiming, $PostException, $PostIgnored,
    $DeliveryValidationLog, $DeliveryValidationExit, $DeliveryValidationTiming,
    $FlashProgramLog, $FlashProgramExit, $FlashReloadLog, $FlashReloadExit,
    $FlashReadbackLog, $FlashReadbackExit, $FlashCompare, $FlashSlots,
    $PostFlashSerial, $PostFlashSerialLog, $BoardSramReport
)) {
    Require (Test-Path -LiteralPath $path) "Required delivery file is missing: $path"
}

$SdcHash = Get-Sha256 $Sdc
$BitHash = Get-Sha256 $Bit
$DbHash = Get-Sha256 $RoutedDb
$OldBitHash = Get-Sha256 $OldBit
Require ($SdcHash -eq $ExpectedSdcHash) "Unexpected SDC hash: $SdcHash"
Require ($BitHash -eq $ExpectedBitHash) "Unexpected bitstream hash: $BitHash"
Require ($DbHash -eq $ExpectedDbHash) "Unexpected routed DB hash: $DbHash"
Require ($OldBitHash -eq $ExpectedOldBitHash) "Unexpected archived bitstream hash: $OldBitHash"

$PostTimingText = [IO.File]::ReadAllText($PostTiming)
Require ($PostTimingText.Contains("Timing violations: 0 setup errors, and 0 hold errors.")) "Post-bitgen timing is not 0/0"
Require ($PostTimingText.Contains("Minimal setup slack: 0.173, minimal hold slack: 0.026")) "Post-bitgen slack mismatch"
Require (([regex]::Matches($PostTimingText, "0 errors detected :")).Count -ge 6) "Not all clock groups are clean"

$BitgenText = [IO.File]::ReadAllText($BitgenLog)
Require ($BitgenText.Contains("R298_BITGEN_CODE=0")) "Native bitgen did not return 0"
Require ($BitgenText.Contains("Generate bits file HDMI_MULTIMEDIA_FINAL_1280x720_60_PR2SEED3.bit.")) "Missing bitgen completion marker"
Require (-not [regex]::IsMatch($BitgenText, "(?i)\bfatal\b")) "Bitgen log contains FATAL"
Require ([regex]::IsMatch($BitgenText, "Map sdc constraints, there are 85 constraints in total")) "Bitgen did not map 85 SDC constraints"

$RouteText = [IO.File]::ReadAllText($RouteLog)
Require ($RouteText.Contains("R298_PR2_SEED3_ROUTE_CODE=0")) "Primary route did not return 0"
Require ($RouteText.Contains("Routed, final wirelength")) "Final route marker is missing"
Require ($RouteText.Contains("No hold violation.")) "Final route hold-fix marker is missing"
Require ([regex]::IsMatch($RouteText, "over cnt = 0\(0%\), over = 0, worst = 0")) "No final zero-overflow marker"

$DeliveryValidationExitText = [IO.File]::ReadAllText($DeliveryValidationExit).Trim()
$DeliveryValidationTimingText = [IO.File]::ReadAllText($DeliveryValidationTiming)
$DeliveryValidationLogText = [IO.File]::ReadAllText($DeliveryValidationLog)
Require ($DeliveryValidationExitText -eq "0") "Delivery validation exit is not 0"
Require ($DeliveryValidationTimingText.Contains("Timing violations: 0 setup errors, and 0 hold errors.")) "Delivery validation is not 0/0"
Require ($DeliveryValidationTimingText.Contains("Minimal setup slack: 0.173, minimal hold slack: 0.026")) "Delivery validation slack mismatch"
Require ($DeliveryValidationLogText.Contains("Map sdc constraints, there are 85 constraints in total")) "Delivery validation did not map 85 constraints"
Require (-not $DeliveryValidationLogText.Contains("Project manager: failed to process")) "Delivery project open had an error"

$FlashProgramExitText = [IO.File]::ReadAllText($FlashProgramExit).Trim()
$FlashReloadExitText = [IO.File]::ReadAllText($FlashReloadExit).Trim()
$FlashReadbackExitText = [IO.File]::ReadAllText($FlashReadbackExit).Trim()
$FlashProgramText = [IO.File]::ReadAllText($FlashProgramLog)
$FlashReloadText = [IO.File]::ReadAllText($FlashReloadLog)
$FlashReadbackText = [IO.File]::ReadAllText($FlashReadbackLog)
$PostFlashSerialData = Get-Content -Raw $PostFlashSerial | ConvertFrom-Json
$FlashCompareData = Get-Content -Raw $FlashCompare | ConvertFrom-Json
$FlashSlotData = Get-Content -Raw $FlashSlots | ConvertFrom-Json
Require ($FlashProgramExitText -eq "0") "Flash program exit is not 0"
Require ($FlashReloadExitText -eq "0") "Flash reload exit is not 0"
Require ($FlashReadbackExitText -eq "0") "Post-program Flash readback exit is not 0"
Require ($FlashProgramText.Contains("HDMI_PR2SEED3_FLASH_PROGRAM_COMPLETED")) "Flash program completion marker is missing"
Require ($FlashProgramText.Contains("PRG-2014 : Chip validation success: EAGLE_S20_BG256")) "Flash chip validation failed or is missing"
Require ($FlashProgramText.Contains("SPI Flash ID is:  c8")) "Expected GigaDevice Flash ID was not reported"
Require ($FlashProgramText.Contains("program_spi -cable 0 -spd 7")) "program_spi command is missing"
Require ($FlashProgramText.Contains("bit_to_vec")) "bit_to_vec conversion is missing"
Require ($FlashProgramText.Contains("-m verify_spi")) "Integrated verify_spi command is missing"
Require ($FlashReloadText.Contains("program -r -cable 0 -spd 7")) "Flash refresh/reconfigure command is missing"
Require ($FlashReloadText.Contains("HDMI_PR2SEED3_FLASH_RELOAD_CODE=0")) "Flash refresh/reconfigure did not return 0"
Require ($FlashReadbackText.Contains("HDMI_PR2SEED3_FLASH_READBACK_CODE=0")) "Post-program Flash readback did not return 0"
Require ([int]$PostFlashSerialData.replies_received -eq 19) "Post-Flash serial response count is not 19"
Require ([int]$PostFlashSerialData.crc_errors -eq 0) "Post-Flash serial CRC errors detected"
Require ([int]$PostFlashSerialData.timeouts -eq 0) "Post-Flash serial timeouts detected"
Require ([int]$PostFlashSerialData.protocol_version -eq 4) "Post-Flash protocol version is not 4"
Require ([int]$PostFlashSerialData.image_count -eq 4) "Post-Flash media count is not 4"
Require ($PostFlashSerialData.pll_status.video_pll_lock -eq $true) "Post-Flash video PLL is not locked"
Require ($PostFlashSerialData.pll_status.reference_pll_lock -eq $true) "Post-Flash reference PLL is not locked"
Require ([int]$FlashCompareData.after_size -eq 16777216) "Post-program Flash image size is not 16 MiB"
Require ([int]$FlashSlotData.after_unique_slot_hashes -eq 1) "Post-program Flash slots are not identical"
$BoardSramData = Get-Content -Raw $BoardSramReport | ConvertFrom-Json
Require ($BoardSramData.serial_readonly.replies_received -eq 19) "SRAM board-test evidence is incomplete"

$ProjectText = [IO.File]::ReadAllText($ProjectAl)
$SourceRefs = @(
    [regex]::Matches($ProjectText, '<File\s+Path="([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
)
Require ($SourceRefs.Count -eq 89) "Expected 89 project source references"
Require (-not ($SourceRefs | Where-Object { $_ -match "(?i)H49_|H50_" })) "H49/H50 reference found in project"

$ProjectDir = Join-Path $Root "project"
$SourcesDir = [IO.Path]::GetFullPath((Join-Path $Root "sources"))
$MissingRefs = @()
$RawMismatches = @()
$NormalizedMismatches = @()
$ExtensionCounts = @{}
foreach ($sourceRef in $SourceRefs) {
    $delivered = [IO.Path]::GetFullPath((Join-Path $ProjectDir $sourceRef))
    if (-not (Test-Path -LiteralPath $delivered)) {
        $MissingRefs += $sourceRef
        continue
    }
    $relative = $delivered.Substring($SourcesDir.Length + 1)
    $original = Join-Path $OriginalSource $relative
    if (-not (Test-Path -LiteralPath $original)) {
        $RawMismatches += $sourceRef
        $NormalizedMismatches += $sourceRef
        continue
    }
    $extension = [IO.Path]::GetExtension($delivered).ToLowerInvariant()
    if (-not $ExtensionCounts.ContainsKey($extension)) {
        $ExtensionCounts[$extension] = 0
    }
    $ExtensionCounts[$extension]++
    if ((Get-Sha256 $delivered) -ne (Get-Sha256 $original)) {
        $RawMismatches += $relative.Replace("\", "/")
    }
    if ((Normalize-SourceText $delivered) -ne (Normalize-SourceText $original)) {
        $NormalizedMismatches += $relative.Replace("\", "/")
    }
}
Require ($MissingRefs.Count -eq 0) "Missing project source references"
Require ($NormalizedMismatches.Count -eq 0) "H43 source content differs beyond asset path relocation"
$AllowedRawChanges = @(
    "rtl/video/font_rom_ascii.v",
    "rtl/host/fixed_subtitle_font.v",
    "rtl/audio/image_voice_prompt.v"
)
$UnexpectedRawChanges = @($RawMismatches | Where-Object { $AllowedRawChanges -notcontains $_ })
Require ($UnexpectedRawChanges.Count -eq 0) "Unexpected H43 source byte changes"

$HostManifestPath = Join-Path $Root "HOST_UI_SHA256.json"
$HostManifest = @(Get-Content -Raw $HostManifestPath | ConvertFrom-Json)
$HostFailures = @()
foreach ($item in $HostManifest) {
    $hostPath = [string]$item.path
    if (-not (Test-Path -LiteralPath $hostPath) -or (Get-Sha256 $hostPath) -ne ([string]$item.sha256).ToUpperInvariant()) {
        $HostFailures += $hostPath
    }
}
$HostFiles = @(Get-ChildItem (Join-Path $Root "host") -Recurse -File)
Require ($HostFiles.Count -eq 17) "Expected 17 host files"
Require ($HostFailures.Count -eq 0) "Host manifest hash failures"
Require (Test-Path (Join-Path $Root "host\MediaControl.exe")) "Host EXE missing"
Require (Test-Path (Join-Path $Root "host\MediaControl.cs")) "Host source missing"

foreach ($path in @(
    (Join-Path $ArchiveDir "README.md"),
    (Join-Path $ArchiveDir "native\optimized_timing.rpt"),
    (Join-Path $ArchiveDir "native\bitgen_experimental.log"),
    (Join-Path $ArchiveDir "program_binding\README.md")
)) {
    Require (Test-Path -LiteralPath $path) "Old-result archive is incomplete: $path"
}

$Preservation = [ordered]@{
    status = "PASS"
    project_source_entries = $SourceRefs.Count
    project_source_entries_expected = 89
    project_source_references_exist = ($MissingRefs.Count -eq 0)
    source_extensions = $ExtensionCounts
    h49_h50_project_references = 0
    raw_byte_changes = $RawMismatches
    raw_changes_allowed = $AllowedRawChanges
    normalized_content_mismatches = $NormalizedMismatches
    normalized_h43_rtl_match = ($NormalizedMismatches.Count -eq 0)
    host_files = $HostFiles.Count
    host_files_expected = 17
    host_manifest_hash_failures = $HostFailures
    host_exe_present = $true
    host_source_present = $true
    original_sdc_sha256 = $SdcHash
    sdc_matches_original = ($SdcHash -eq $ExpectedSdcHash)
}
$PreservationPath = Join-Path $ReportRoot "preservation_validation.json"
Write-JsonFile $PreservationPath $Preservation

$Clocks = [ordered]@{}
foreach ($clock in @("SYS_CLK", "pclk", "sclk5", "ctrl_clk", "sdram_ctrl_clk", "sdram_device_clk")) {
    $Clocks[$clock] = [ordered]@{ setup_errors = 0; hold_errors = 0 }
}

$TimingStatus = [ordered]@{
    format = "hdmi-multimedia-final-timing-status/v2"
    generated_utc = $Generated
    evidence_class = "native-td-post-route-and-post-bitgen"
    timing_pass = $true
    timing_signoff = $true
    delivery_gate = "TIMING_SIGNOFF_PASS"
    setup_errors = 0
    hold_errors = 0
    setup_wns_ns = 0.173
    hold_wns_ns = 0.026
    raw_summary_match = "Timing violations: 0 setup errors, and 0 hold errors."
    raw_slack_match = "Minimal setup slack: 0.173, minimal hold slack: 0.026"
    clocks = $Clocks
    constraints = [ordered]@{
        file = "constraints/media_terminal_top.sdc"
        sha256 = $SdcHash
        matches_original_h43 = $true
        mapped_constraint_count = 85
        clock_count = 6
        additional_mcp_smd_sfp = $false
        post_bitgen_exception_report = (Get-RelPath $PostException)
        post_bitgen_ignored_report = (Get-RelPath $PostIgnored)
    }
    route = [ordered]@{
        exit_code = 0
        final_overflow = 0
        final_wirelength = 3320890
        no_hold_violation_marker = $true
        log = (Get-RelPath $RouteLog)
        log_sha256 = (Get-Sha256 $RouteLog)
    }
    routed_db = [ordered]@{
        path = (Get-RelPath $RoutedDb)
        bytes = (Get-Item $RoutedDb).Length
        sha256 = $DbHash
    }
    bitgen = [ordered]@{
        exit_code = 0
        fatal_present = $false
        source_routed_db_sha256 = $DbHash
        packaged = (Get-RelPath $Bit)
        bytes = (Get-Item $Bit).Length
        sha256 = $BitHash
        log = (Get-RelPath $BitgenLog)
        log_sha256 = (Get-Sha256 $BitgenLog)
        post_bitgen_timing_unchanged = $true
    }
    delivery_validation = [ordered]@{
        exit_code = 0
        setup_errors = 0
        hold_errors = 0
        setup_wns_ns = 0.173
        hold_wns_ns = 0.026
        mapped_constraint_count = 85
        timing_report = (Get-RelPath $DeliveryValidationTiming)
        timing_report_sha256 = (Get-Sha256 $DeliveryValidationTiming)
        log = (Get-RelPath $DeliveryValidationLog)
        log_sha256 = (Get-Sha256 $DeliveryValidationLog)
    }
    archive_only = [ordered]@{
        directory = (Get-RelPath $ArchiveDir)
        old_bitstream = (Get-RelPath $OldBit)
        old_bitstream_sha256 = $OldBitHash
        old_setup_errors = 0
        old_hold_errors = 2
        old_worst_hold_slack_ns = -0.020
    }
    hardware_validation = [ordered]@{
        board_operation_performed = $true
        tf_operation_performed = $false
        flash_operation_performed = $true
        programmer = "Anlogic AL-Link Mini"
        cable = 0
        uart = "COM26"
        flash_manufacturer_id = "0xc8"
        flash_manufacturer = "GigaDevice"
        flash_capacity_mbit = 128
        flash_capacity_mib = 16
        flash_layout = "Eight identical 2 MiB configuration images"
        flash_before_sha256 = "F6C03FC7C2940C42C5BCB593F683BDE0ED082B11868119201DCB07880B859D13"
        flash_after_sha256 = "080ACF35A507AC9849CFCBA47DC2AD83E01B75663A516279C8B9D243B719643E"
        program_spi_exit_code = 0
        integrated_verify_spi_pass = $true
        reload_exit_code = 0
        reload_command = "program -r -cable 0 -spd 7"
        readback_after_exit_code = 0
        post_reload_serial = [ordered]@{
            requests = 19
            replies = 19
            crc_errors = 0
            timeouts = 0
            protocol_version = 4
            media_count = 4
            video_pll_lock = $true
            reference_pll_lock = $true
            audio_mode = "uniform"
        }
        user_observed_before_flash = "Picture, menu, and sound were normal."
        post_flash_physical_audio_video_independently_observed = $false
        cold_boot_after_power_cycle_verified = $false
    }
    board_operation_performed = $true
    tf_or_flash_operation_performed = $true
}
$TimingStatusPath = Join-Path $Root "reports\TIMING_STATUS.json"
Write-JsonFile $TimingStatusPath $TimingStatus

$EvidencePaths = @(
    $RouteLog,
    $BitgenLog,
    (Join-Path $ReportRoot "pre_bitgen_timing_simple.rpt"),
    $PostTiming,
    $PostException,
    $PostIgnored,
    (Join-Path $ReportRoot "post_bitgen_clock_intersection.rpt"),
    (Join-Path $ReportRoot "post_bitgen_io.rpt"),
    (Join-Path $ReportRoot "post_bitgen_area.rpt"),
    $DeliveryValidationLog,
    $DeliveryValidationExit,
    $DeliveryValidationTiming,
    $PreservationPath,
    $Sdc,
    $Adc,
    $GateDb,
    $PlaceDb,
    $RoutedDb,
    $Bit,
    $OldBit,
    (Join-Path $ArchiveDir "README.md"),
    (Join-Path $Root "project\hold_fix_pr2_seed3\rebuild_from_gate.tcl"),
    (Join-Path $Root "project\hold_fix_pr2_seed3\bitgen_from_routed.tcl"),
    (Join-Path $Root "project\hold_fix_pr2_seed3\validate_delivery.tcl"),
    $FlashProgramLog,
    $FlashProgramExit,
    $FlashReloadLog,
    $FlashReloadExit,
    $FlashReadbackLog,
    $FlashReadbackExit,
    $FlashCompare,
    $FlashSlots,
    $PostFlashSerial,
    $PostFlashSerialLog,
    (Join-Path $FlashRoot "FLASH_PROGRAM_REPORT.json"),
    (Join-Path $FlashRoot "README.md"),
    (Join-Path $Root "project\flash_programming\program_flash.tcl"),
    (Join-Path $Root "project\flash_programming\run_program_flash.ps1"),
    (Join-Path $Root "project\flash_programming\reload_from_flash.tcl"),
    (Join-Path $Root "project\flash_programming\run_reload_flash.ps1"),
    (Join-Path $Root "project\flash_programming\readback_after_flash.tcl"),
    (Join-Path $Root "project\flash_programming\run_readback_after_flash.ps1"),
    (Join-Path $Root "project\flash_programming\serial_after_flash_test.ps1")
)
$EvidenceFiles = @(
    foreach ($path in $EvidencePaths) {
        [ordered]@{
            path = (Get-RelPath $path)
            bytes = (Get-Item $path).Length
            sha256 = (Get-Sha256 $path)
        }
    }
)
$EvidenceManifest = [ordered]@{
    format = "hdmi-multimedia-final-evidence-manifest/v2"
    generated_utc = $Generated
    timing_signoff = $true
    setup_errors = 0
    hold_errors = 0
    setup_wns_ns = 0.173
    hold_wns_ns = 0.026
    archive_policy = "Old 0-setup/2-hold native reports and their bitstream are archive-only and not current signoff."
    files = $EvidenceFiles
}
$EvidenceManifestPath = Join-Path $Root "reports\evidence_manifest.json"
Write-JsonFile $EvidenceManifestPath $EvidenceManifest

$FinalVerification = [ordered]@{
    format = "hdmi-multimedia-final-verification/v2"
    generated_utc = $Generated
    delivery_gate = "TIMING_SIGNOFF_PASS"
    timing_signoff = $true
    setup_errors = 0
    hold_errors = 0
    setup_wns_ns = 0.173
    hold_wns_ns = 0.026
    bitstream = $TimingStatus.bitgen
    routed_db = $TimingStatus.routed_db
    constraints = $TimingStatus.constraints
    route = $TimingStatus.route
    delivery_directory_validation = $TimingStatus.delivery_validation
    hardware_validation = $TimingStatus.hardware_validation
    source_and_host_preservation = $Preservation
    archive_only_old_result = $TimingStatus.archive_only
    h49_h50_candidate_merged = $false
    rtl_change_for_timing_repair = $false
    physical_change = "place seed 3 only relative to the original successful pr_strategy=2 baseline"
    board_operation_performed = $true
    tf_operation_performed = $false
    flash_operation_performed = $true
    tf_or_flash_operation_performed = $true
    strict_style_overall_signoff_claimed = $false
    cdc_overall_signoff_claimed = $false
    manifest_verification = [ordered]@{
        status = "PASS"
        manifest_exclusions = @("package_manifest.json", "SHA256SUMS.txt")
        sha256sums_self_exclusion = "SHA256SUMS.txt"
    }
}
$FinalVerificationPath = Join-Path $Root "FINAL_VERIFICATION.json"
Write-JsonFile $FinalVerificationPath $FinalVerification

$ManifestPath = Join-Path $Root "package_manifest.json"
$SumsPath = Join-Path $Root "SHA256SUMS.txt"
$ManifestFiles = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object {
            $_.FullName -ne $ManifestPath -and
            $_.FullName -ne $SumsPath
        } |
        Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                path = (Get-RelPath $_.FullName)
                bytes = $_.Length
                sha256 = (Get-Sha256 $_.FullName)
            }
        }
)
$PackageManifest = [ordered]@{
    format = "HDMI_Multimedia_Final_package"
    version = "2.0.0"
    generated_utc = $Generated
    project = [ordered]@{
        name = "HDMI_MULTIMEDIA_FINAL"
        top = "media_terminal_top"
        family = "EG4"
        device = "EG4S20BG256"
        package = "EG4S20BG256"
        functional_source_count = 89
    }
    delivery_gate = "TIMING_SIGNOFF_PASS"
    timing_signoff = $true
    setup_errors = 0
    hold_errors = 0
    setup_wns_ns = 0.173
    hold_wns_ns = 0.026
    bitstream = $TimingStatus.bitgen
    archive_only = $TimingStatus.archive_only
    manifest_scope = [ordered]@{
        included = "Every regular file below the delivery root except the two self-referential manifest files."
        excluded = @("package_manifest.json", "SHA256SUMS.txt")
        reason = "Prevents recursive self-hashing. SHA256SUMS.txt separately authenticates package_manifest.json."
    }
    files = $ManifestFiles
}
Write-JsonFile $ManifestPath $PackageManifest

$SumsFiles = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $SumsPath } |
        Sort-Object FullName
)
$SumsLines = @(
    foreach ($file in $SumsFiles) {
        "$(Get-Sha256 $file.FullName)  $(Get-RelPath $file.FullName)"
    }
)
[IO.File]::WriteAllText($SumsPath, (($SumsLines -join "`n") + "`n"), $Utf8NoBom)

$ActualAfterSums = @(
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $SumsPath } |
        Sort-Object FullName
)
$ManifestScope = @(
    $ActualAfterSums |
        Where-Object {
            $_.FullName -ne $ManifestPath -and
            $_.FullName -ne $SumsPath
        }
)
$RecordedManifest = @($PackageManifest.files)
Require ($RecordedManifest.Count -eq $ManifestScope.Count) "Manifest entry count mismatch"
for ($index = 0; $index -lt $ManifestScope.Count; $index++) {
    $relative = Get-RelPath $ManifestScope[$index].FullName
    Require ($RecordedManifest[$index].path -eq $relative) "Manifest path order mismatch"
    Require ($RecordedManifest[$index].bytes -eq $ManifestScope[$index].Length) "Manifest size mismatch: $relative"
    Require ($RecordedManifest[$index].sha256 -eq (Get-Sha256 $ManifestScope[$index].FullName)) "Manifest hash mismatch: $relative"
}

$ParsedSums = @{}
foreach ($line in [IO.File]::ReadAllLines($SumsPath)) {
    if ($line -notmatch "^([0-9A-Fa-f]{64})  (.+)$") {
        throw "Malformed SHA256SUMS line: $line"
    }
    $ParsedSums[$Matches[2]] = $Matches[1].ToUpperInvariant()
}
Require ($ParsedSums.Count -eq $ActualAfterSums.Count) "SHA256SUMS entry count mismatch"
foreach ($file in $ActualAfterSums) {
    $relative = Get-RelPath $file.FullName
    Require ($ParsedSums.ContainsKey($relative)) "SHA256SUMS missing: $relative"
    Require ($ParsedSums[$relative] -eq (Get-Sha256 $file.FullName)) "SHA256SUMS mismatch: $relative"
}

$TotalFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force).Count
$TotalBytes = (Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Measure-Object Length -Sum).Sum
[ordered]@{
    status = "PASS"
    total_files = $TotalFiles
    total_bytes = $TotalBytes
    manifest_entry_count = $RecordedManifest.Count
    sha256sums_entry_count = $ParsedSums.Count
    manifest_exclusions = @("package_manifest.json", "SHA256SUMS.txt")
    sha256sums_exclusion = @("SHA256SUMS.txt")
    bitstream_sha256 = $BitHash
    source_count = $SourceRefs.Count
    host_file_count = $HostFiles.Count
} | ConvertTo-Json -Depth 10
