# Step 4: rating, author, email and date. Local only; runs after every image/review worker has finished.
function Get-SampleReviewRating([ValidateRange(0, 99)][int]$Draw = (Get-Random -Maximum 100)) {
    if ($Draw -lt 55) { return 5 }
    return 4
}

function Complete-ReviewMetadata([object[]]$Rows, [string]$NamesPath) {
    if (-not $Rows.Count) { return }
    $names = @(if (Test-Path -LiteralPath $NamesPath) {
        Get-Content -LiteralPath $NamesPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    })
    $names = @($names | Select-Object -Unique)
    if (-not $names.Count) { $names = @('Adam B.', 'Emma C.', 'James F.', 'Olivia R.', 'Henry B.', 'Amelia P.') }
    $names = @($names | Get-Random -Count $names.Count)
    $now = [DateTime]::UtcNow
    $yearStart = [DateTime]::new($now.Year, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $maxSeconds = [long][Math]::Floor(($now - $yearStart).TotalSeconds) + 1
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $row = $Rows[$i]
        $row.rating = Get-SampleReviewRating
        if ($i -gt 0 -and ($i % $names.Count) -eq 0) {
            $previousAuthor = $Rows[$i - 1].author
            $names = @($names | Get-Random -Count $names.Count)
            if ($names.Count -gt 1 -and $names[0] -eq $previousAuthor) {
                $names[0], $names[1] = $names[1], $names[0]
            }
        }
        $row.author = $names[$i % $names.Count]
        $emailName = (($row.author.ToLowerInvariant() -replace '[^a-z0-9 ]', '').Trim() -replace ' +', '.')
        if (-not $emailName) { $emailName = 'reviewer' + ($i + 1) }
        $row.email = $emailName + '@int'
        $seconds = Get-Random -Minimum 0 -Maximum $maxSeconds
        $row.created_at = $yearStart.AddSeconds($seconds).ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
        $row.verified_purchase = 'true'
    }
}
