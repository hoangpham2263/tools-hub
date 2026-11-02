# Takes Google's sparkle out of the bottom right corner of a picture its web AI made (hub/image/unsparkle.mjs, plain Node, the
# same on every OS). The picture is changed in place; the untouched one is first copied to Backup when that is given.
# Returns $true when the sparkle was there and is gone, $false when the picture had none (it is left as it is).
$script:HubUnsparkleScript = Join-Path $PSScriptRoot 'unsparkle.mjs'

function Remove-HubImageSparkle([Parameter(Mandatory)][string]$Image, [string]$Backup = '') {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Chưa có Node.js nên chưa gỡ được dấu sao của Google.' }
    $clean = "$Image.clean.png"
    $reply = & node $script:HubUnsparkleScript '--image' $Image '--out' $clean 2>&1
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $clean -Force -ErrorAction SilentlyContinue; throw (($reply | ForEach-Object { "$_" }) -join ' ').Trim() }
    $applied = ((($reply | ForEach-Object { "$_" }) -join '') | ConvertFrom-Json).applied
    if ($applied -and $Backup) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Backup -Parent) | Out-Null
        Copy-Item -LiteralPath $Image -Destination $Backup -Force
    }
    if ($applied) { Move-Item -LiteralPath $clean -Destination $Image -Force } else { Remove-Item -LiteralPath $clean -Force -ErrorAction SilentlyContinue }
    [bool]$applied
}
