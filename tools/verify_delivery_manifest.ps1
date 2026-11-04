$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ManifestPath = Join-Path $Root "package_manifest.json"
$SumsPath = Join-Path $Root "SHA256SUMS.txt"

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-RelPath([string]$Path) {
    return ([IO.Path]::GetFullPath($Path)).Substring($Root.Length + 1).Replace("\", "/")
}

$Manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
$Actual = @(Get-ChildItem $Root -Recurse -File -Force)
$ManifestScope = @(
    $Actual | Where-Object {
        $_.FullName -ne $ManifestPath -and $_.FullName -ne $SumsPath
    }
)
$Recorded = @{}
foreach ($entry in @($Manifest.files)) {
    if ($Recorded.ContainsKey($entry.path)) {
        throw "Duplicate package manifest path: $($entry.path)"
    }
    $Recorded[$entry.path] = $entry
}
if ($Recorded.Count -ne $ManifestScope.Count) {
    throw "package_manifest.json file coverage mismatch"
}
foreach ($file in $ManifestScope) {
    $relative = Get-RelPath $file.FullName
    if (-not $Recorded.ContainsKey($relative)) {
        throw "package manifest missing: $relative"
    }
    if ($Recorded[$relative].bytes -ne $file.Length) {
        throw "package manifest size mismatch: $relative"
    }
    if ($Recorded[$relative].sha256 -ne (Get-Sha256 $file.FullName)) {
        throw "package manifest hash mismatch: $relative"
    }
}

$Sums = @{}
foreach ($line in [IO.File]::ReadAllLines($SumsPath)) {
    if ($line -notmatch "^([0-9A-Fa-f]{64})  (.+)$") {
        throw "Malformed SHA256SUMS line: $line"
    }
    if ($Sums.ContainsKey($Matches[2])) {
        throw "Duplicate SHA256SUMS path: $($Matches[2])"
    }
    $Sums[$Matches[2]] = $Matches[1].ToUpperInvariant()
}
$SumsScope = @($Actual | Where-Object { $_.FullName -ne $SumsPath })
if ($Sums.Count -ne $SumsScope.Count) {
    throw "SHA256SUMS.txt file coverage mismatch"
}
foreach ($file in $SumsScope) {
    $relative = Get-RelPath $file.FullName
    if (-not $Sums.ContainsKey($relative)) {
        throw "SHA256SUMS missing: $relative"
    }
    if ($Sums[$relative] -ne (Get-Sha256 $file.FullName)) {
        throw "SHA256SUMS hash mismatch: $relative"
    }
}

[ordered]@{
    status = "PASS"
    actual_file_count = $Actual.Count
    total_bytes = ($Actual | Measure-Object Length -Sum).Sum
    manifest_entry_count = $Recorded.Count
    sha256sums_entry_count = $Sums.Count
    manifest_exclusions = @("package_manifest.json", "SHA256SUMS.txt")
    sha256sums_exclusion = @("SHA256SUMS.txt")
    all_manifest_entries_verified = $true
    all_sha256sums_verified = $true
    all_files_covered = $true
} | ConvertTo-Json -Depth 10
