function New-Batch([string]$OutDir) {
    $localTime = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'SE Asia Standard Time')
    # One clean name per run, the same stamp as the error files: 2026-10-29_22h40m37s (-2, -3… if two start in one second).
    $stamp = $localTime.ToString("yyyy-MM-dd_HH'h'mm'm'ss's'"); $id = $stamp
    for ($n = 2; Test-Path -LiteralPath (Join-Path $OutDir $id); $n++) { $id = "$stamp-$n" }
    $dir = Join-Path $OutDir $id
    $batch = @{
        Id      = $id
        Dir     = $dir
        InputUrls = Join-Path $dir 'urls.input.txt'
        CompletedUrls = Join-Path $dir 'urls.completed.txt'
        Images  = Join-Path $dir 'images'
        Logs    = Join-Path $dir 'logs'
        Refs    = Join-Path $dir 'refs'
        Csv     = Join-Path $dir 'loox_import.csv'
    }
    # URL history belongs to the output batch; source photos remain reusable.
    New-Item -ItemType Directory -Force $batch.Images, $batch.Logs, $batch.Refs | Out-Null
    return $batch
}
