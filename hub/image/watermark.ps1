# A watermark on an image, for every tool that edits images: hub/image/watermark.mjs does the drawing in plain Node (the
# tools already need Node), so it behaves the same on Windows and macOS and needs nothing else installed. Images are PNG.
# Size is the visible watermark's width as a fraction of the image width, Margin its distance from the edge, also as a
# fraction of the width. ContentBox [x, y, width, height] is where the visible part sits inside the mark PNG (the rest
# is room for a shadow). The image itself is never written; the marked copy goes to Output.
$script:HubWatermarkScript = Join-Path $PSScriptRoot 'watermark.mjs'

function Add-HubImageWatermark(
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string]$Mark,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][int[]]$ContentBox,
    [ValidateSet('top-right', 'top-left', 'bottom-right', 'bottom-left', 'bottom-center')][string]$Position = 'top-right',
    [double]$Size = 0.16,
    [double]$Margin = 0.03
) {
    if ($ContentBox.Count -ne 4) { throw 'The watermark content box must be x, y, width, height.' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Chưa có Node.js nên chưa đóng dấu logo được.' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $arguments = @($script:HubWatermarkScript, '--image', $Image, '--mark', $Mark, '--out', $Output, '--box', ($ContentBox -join ','),
        '--position', $Position, '--size', $Size.ToString($inv), '--margin', $Margin.ToString($inv))
    $reply = & node @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($reply | ForEach-Object { "$_" }) -join ' ').Trim() }
    $Output
}
