# The brand pack's watermark on an image (the drawing is watermark.mjs beside this file, plain Node, the same on
# every OS). The watermark is a transparent PNG built once for the brand (white mark and name on a plate in the brand's
# main color, scripts/build-brand-watermark.mjs), so it looks the same on every image. The image AI never draws it: it
# would redraw the strokes, and Google Flow refuses prompts about brands. The original stays as it is.

# Writes the marked copy beside the image as <name>-logo.png and returns its path, or '' with the reason in
# $script:WatermarkNote (no watermark for the brand, no Node, or a failed draw): the plain image is then kept.
function Add-BrandWatermark([string]$Image, $Pack) {
    $script:WatermarkNote = ''
    $mark = $Pack.watermark
    if (-not $mark -or -not $Pack.dir) { $script:WatermarkNote = 'Thương hiệu này chưa có logo đóng dấu.'; return '' }
    $file = Join-Path $Pack.dir ([string]$mark.file)
    if (-not (Test-Path -LiteralPath $file)) { $script:WatermarkNote = "Không thấy file logo $($mark.file) của thương hiệu."; return '' }
    $output = [IO.Path]::ChangeExtension($Image, $null).TrimEnd('.') + '-logo.png'
    try {
        $position = if ($mark.position) { [string]$mark.position } else { 'top-right' }
        $size = if ($mark.size) { [double]$mark.size } else { 0.16 }
        $margin = if ($mark.margin) { [double]$mark.margin } else { 0.03 }
        return (Add-ImageWatermark $Image $file $output ([int[]]@($mark.content_box)) $position $size $margin)
    } catch {
        $script:WatermarkNote = "Chưa đóng dấu logo được: $($_.Exception.Message)"
        return ''
    }
}

# Images are PNG. Size is the visible watermark's width as a fraction of the image width, Margin its distance from the edge, also as a
# fraction of the width. ContentBox [x, y, width, height] is where the visible part sits inside the mark PNG (the rest is room for a
# shadow). The image itself is never written; the marked copy goes to Output.
$script:WatermarkScript = Join-Path $PSScriptRoot 'watermark.mjs'

function Add-ImageWatermark(
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
    $arguments = @($script:WatermarkScript, '--image', $Image, '--mark', $Mark, '--out', $Output, '--box', ($ContentBox -join ','),
        '--position', $Position, '--size', $Size.ToString($inv), '--margin', $Margin.ToString($inv))
    $reply = & node @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($reply | ForEach-Object { "$_" }) -join ' ').Trim() }
    $Output
}
