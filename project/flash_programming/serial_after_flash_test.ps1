$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Ports

$work = $PSScriptRoot
$portName = "COM26"
$logPath = Join-Path $work "serial_queries.log"
$jsonPath = Join-Path $work "serial_results.json"
$script:testStats = @{
    crc_errors = 0
    unmatched_frames = 0
    timeouts = 0
}

function Get-Crc16Ccitt([byte[]]$bytes, [int]$offset, [int]$count) {
    [uint32]$crc = 0xFFFF
    for ($i = $offset; $i -lt ($offset + $count); $i++) {
        $crc = $crc -bxor ([uint32]$bytes[$i] -shl 8)
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 0x8000) -ne 0) {
                $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF
            }
            else {
                $crc = ($crc -shl 1) -band 0xFFFF
            }
        }
    }
    return [uint16]$crc
}

function New-BoardFrame([byte]$command, [byte]$sequence) {
    [byte[]]$frame = 0xA5, 0x5A, $command, $sequence, 0, 0, 0, 0, 0, 0
    $crc = Get-Crc16Ccitt $frame 2 6
    $frame[8] = [byte]($crc -band 0xFF)
    $frame[9] = [byte](($crc -shr 8) -band 0xFF)
    return $frame
}

function Read-BoardReply(
    [System.IO.Ports.SerialPort]$port,
    [byte]$command,
    [byte]$sequence,
    [int]$timeoutMs = 2600
) {
    $buffer = [System.Collections.Generic.List[byte]]::new()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $buffer.Add([byte]$port.ReadByte())
        }
        catch [System.TimeoutException] {
            continue
        }
        while ($buffer.Count -ge 10) {
            if ($buffer[0] -ne 0xA5) {
                $buffer.RemoveAt(0)
                continue
            }
            if ($buffer[1] -ne 0x5A) {
                $buffer.RemoveAt(0)
                continue
            }
            [byte[]]$candidate = $buffer.GetRange(0, 10).ToArray()
            $crc = Get-Crc16Ccitt $candidate 2 6
            $wireCrc = [uint16]($candidate[8] -bor ([uint16]$candidate[9] -shl 8))
            if ($crc -ne $wireCrc) {
                $script:testStats.crc_errors++
                $buffer.RemoveAt(0)
                continue
            }
            if (
                $candidate[2] -eq (($command -bor 0x80) -band 0xFF) -and
                $candidate[3] -eq $sequence
            ) {
                return $candidate
            }
            $script:testStats.unmatched_frames++
            $buffer.RemoveAt(0)
        }
    }
    $script:testStats.timeouts++
    return $null
}

function ConvertTo-Hex([byte[]]$bytes) {
    return (($bytes | ForEach-Object { $_.ToString("X2") }) -join " ")
}

$initialQueries = @(
    [ordered]@{ key = "version"; command = 0x02; label = "handshake_protocol_and_parameters" },
    [ordered]@{ key = "status"; command = 0x01; label = "media_summary_and_playback_status" },
    [ordered]@{ key = "fault_snapshot"; command = 0x03; label = "transaction_fault_snapshot" },
    [ordered]@{ key = "live_transaction"; command = 0x04; label = "live_transaction_snapshot" },
    [ordered]@{ key = "hdmi_progress"; command = 0x05; label = "hdmi_audio_video_progress" },
    [ordered]@{ key = "load_latency"; command = 0x06; label = "last_media_load_latency" },
    [ordered]@{ key = "recovery_record"; command = 0x07; label = "media_recovery_record" },
    [ordered]@{ key = "scheduler_stats"; command = 0x08; label = "scheduler_accept_counters" },
    [ordered]@{ key = "subtitle_status"; command = 0x09; label = "subtitle_and_pll_lock_status" },
    [ordered]@{ key = "prompt_status"; command = 0x0A; label = "image_prompt_snapshot" },
    [ordered]@{ key = "audio_mode"; command = 0x0F; label = "normal_playback_audio_mode" }
)
$pollQueries = @(
    [ordered]@{ key = "status"; command = 0x01; label = "media_summary_and_playback_status" },
    [ordered]@{ key = "hdmi_progress"; command = 0x05; label = "hdmi_audio_video_progress" },
    [ordered]@{ key = "scheduler_stats"; command = 0x08; label = "scheduler_accept_counters" },
    [ordered]@{ key = "load_latency"; command = 0x06; label = "last_media_load_latency" }
)

$queryRuns = [System.Collections.Generic.List[object]]::new()
foreach ($query in $initialQueries) {
    $queryRuns.Add([ordered]@{
        cycle = 1
        key = $query.key
        command = $query.command
        label = $query.label
    })
}
foreach ($cycle in 2..3) {
    Start-Sleep -Milliseconds 500
    foreach ($query in $pollQueries) {
        $queryRuns.Add([ordered]@{
            cycle = $cycle
            key = $query.key
            command = $query.command
            label = $query.label
        })
    }
}

$port = [System.IO.Ports.SerialPort]::new(
    $portName,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$port.ReadTimeout = 200
$port.WriteTimeout = 1000
$port.DtrEnable = $false
$port.RtsEnable = $false

$started = [DateTime]::UtcNow
$results = [System.Collections.Generic.List[object]]::new()
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("BOARD_SERIAL_READONLY_BEGIN port=$portName timestamp_utc=$($started.ToString('yyyy-MM-ddTHH:mm:ssZ'))")

try {
    $port.Open()
    Start-Sleep -Milliseconds 250
    $port.DiscardInBuffer()

    [byte]$sequence = 0
    foreach ($query in $queryRuns) {
        $sequence = [byte]($sequence + 1)
        [byte[]]$frame = New-BoardFrame $query.command $sequence
        $lines.Add(
            "TX cycle=$($query.cycle) key=$($query.key) cmd=0x$('{0:X2}' -f $query.command) seq=$sequence frame=$(ConvertTo-Hex $frame)"
        )
        $port.Write($frame, 0, $frame.Length)
        [byte[]]$reply = Read-BoardReply $port $query.command $sequence
        if ($null -eq $reply) {
            $lines.Add("RX cycle=$($query.cycle) key=$($query.key) TIMEOUT")
            $results.Add([ordered]@{
                cycle = $query.cycle
                key = $query.key
                label = $query.label
                command = "0x{0:X2}" -f $query.command
                ok = $false
                error = "timeout"
                tx = ConvertTo-Hex $frame
                timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            })
            continue
        }

        $lines.Add("RX cycle=$($query.cycle) key=$($query.key) frame=$(ConvertTo-Hex $reply)")
        $decoded = [ordered]@{}
        switch ($query.key) {
            "version" {
                $decoded.protocol_version = [int]$reply[7]
                $decoded.error_code = [int]$reply[6]
                $decoded.brightness = [int]$reply[4]
                $decoded.speed_step = [int]$reply[5]
            }
            "status" {
                $decoded.image_index_zero_based = [int]$reply[4]
                $decoded.image_count = [int]$reply[5]
                $decoded.volume = [int]($reply[6] -band 0x1F)
                $decoded.fsm_state = [int](($reply[6] -shr 5) -band 0x07)
                $decoded.playing = (($reply[7] -band 0x01) -ne 0)
                $decoded.paused = (($reply[7] -band 0x02) -ne 0)
                $decoded.media_busy = (($reply[7] -band 0x04) -ne 0)
                $decoded.error_flag = (($reply[7] -band 0x08) -ne 0)
                $decoded.program_mode = (($reply[7] -band 0x10) -ne 0)
                $decoded.subtitle_visible = (($reply[7] -band 0x20) -ne 0)
                $decoded.emergency_notice = (($reply[7] -band 0x40) -ne 0)
            }
            "hdmi_progress" {
                $decoded.sample_count = [int]$reply[4]
                $decoded.nonzero_sample_count = [int]$reply[5]
                $decoded.acr_observation = [int]$reply[6]
                $decoded.asp_observation = [int]$reply[7]
            }
            "load_latency" {
                $decoded.load_cycles_50mhz = [uint32](
                    [uint32]$reply[4] -bor
                    ([uint32]$reply[5] -shl 8) -bor
                    ([uint32]$reply[6] -shl 16) -bor
                    ([uint32]$reply[7] -shl 24)
                )
            }
            "scheduler_stats" {
                $decoded.audio_sectors_accepted = [int](($reply[4] -shl 8) -bor $reply[5])
                $decoded.image_sectors_accepted = [int](($reply[6] -shl 8) -bor $reply[7])
            }
            "subtitle_status" {
                $decoded.source_bits = [int](($reply[4] -shr 6) -band 0x03)
                $decoded.builtin_message = [int](($reply[4] -shr 4) -band 0x03)
                $decoded.normal_override_valid = (($reply[4] -band 0x08) -ne 0)
                $decoded.urgent_valid = (($reply[4] -band 0x04) -ne 0)
                $decoded.video_pll_lock = (($reply[4] -band 0x02) -ne 0)
                $decoded.reference_pll_lock = (($reply[4] -band 0x01) -ne 0)
            }
            "prompt_status" {
                $decoded.enabled = (($reply[4] -band 0x01) -ne 0)
                $decoded.playing_prompt = (($reply[4] -band 0x04) -ne 0)
                $decoded.capability_magic = "0x{0:X2}" -f $reply[7]
            }
            "audio_mode" {
                $decoded.mode = [int]$reply[4]
                $decoded.mode_name = if ($reply[4] -eq 0) { "uniform" } elseif ($reply[4] -eq 1) { "per_image" } else { "unknown" }
                $decoded.capability_marker = "0x{0:X2}" -f $reply[7]
            }
            default {
                $decoded.raw_a0 = [int]$reply[4]
                $decoded.raw_a1 = [int]$reply[5]
                $decoded.raw_d0 = [int]$reply[6]
                $decoded.raw_d1 = [int]$reply[7]
            }
        }
        $results.Add([ordered]@{
            cycle = $query.cycle
            key = $query.key
            label = $query.label
            command = "0x{0:X2}" -f $query.command
            ok = $true
            tx = ConvertTo-Hex $frame
            rx = ConvertTo-Hex $reply
            decoded = $decoded
            timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        })
    }
}
finally {
    if ($port.IsOpen) {
        $port.Close()
    }
    $port.Dispose()
    $completed = [DateTime]::UtcNow
    $lines.Add("BOARD_SERIAL_READONLY_END timestamp_utc=$($completed.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    [IO.File]::WriteAllLines($logPath, $lines, [Text.UTF8Encoding]::new($false))
}

$version = $results | Where-Object { $_.key -eq "version" } | Select-Object -First 1
$status = $results | Where-Object { $_.key -eq "status" } | Select-Object -First 1
$subtitle = $results | Where-Object { $_.key -eq "subtitle_status" } | Select-Object -First 1
$statusSamples = @($results | Where-Object { $_.key -eq "status" -and $_.ok })
$hdmiSamples = @($results | Where-Object { $_.key -eq "hdmi_progress" -and $_.ok })
$schedulerSamples = @($results | Where-Object { $_.key -eq "scheduler_stats" -and $_.ok })
$loadSamples = @($results | Where-Object { $_.key -eq "load_latency" -and $_.ok })
$multipleCycleEvidence = [ordered]@{
    status_samples = $statusSamples.Count
    hdmi_samples = $hdmiSamples.Count
    scheduler_samples = $schedulerSamples.Count
    load_latency_samples = $loadSamples.Count
    hdmi_sample_counts = @($hdmiSamples | ForEach-Object { $_.decoded.sample_count })
    hdmi_nonzero_sample_counts = @($hdmiSamples | ForEach-Object { $_.decoded.nonzero_sample_count })
    audio_sectors_accepted = @($schedulerSamples | ForEach-Object { $_.decoded.audio_sectors_accepted })
    image_sectors_accepted = @($schedulerSamples | ForEach-Object { $_.decoded.image_sectors_accepted })
    load_cycles_50mhz = @($loadSamples | ForEach-Object { $_.decoded.load_cycles_50mhz })
}
$summary = [ordered]@{
    port = $portName
    baud = 115200
    data_bits = 8
    parity = "none"
    stop_bits = "one"
    flow_control = "none"
    commands_sent = $results.Count
    requests_total = $queryRuns.Count
    replies_received = @($results | Where-Object { $_.ok }).Count
    crc_errors = $script:testStats.crc_errors
    unmatched_frames = $script:testStats.unmatched_frames
    timeouts = $script:testStats.timeouts
    protocol_version = if ($version -and $version.ok) { $version.decoded.protocol_version } else { $null }
    handshake_pass = [bool]($version -and $version.ok -and $version.decoded.protocol_version -eq 4)
    image_count = if ($status -and $status.ok) { $status.decoded.image_count } else { $null }
    playback_state = if ($status -and $status.ok) { $status.decoded } else { $null }
    pll_status = if ($subtitle -and $subtitle.ok) { $subtitle.decoded } else { $null }
    multiple_cycle_evidence = $multipleCycleEvidence
    dedicated_self_test_available = $false
    note = "Protocol 4 exposes read-only snapshots but no filename-list or dedicated self-test command."
    results = $results
}
$summary |
    ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8

if (-not $summary.handshake_pass) {
    exit 2
}
exit 0
