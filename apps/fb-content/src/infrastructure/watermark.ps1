# The brand pack's watermark on an image (the drawing itself is the hub's: hub/image/watermark.ps1, plain Node, the same on
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
        return (Add-HubImageWatermark $Image $file $output ([int[]]@($mark.content_box)) $position $size $margin)
    } catch {
        $script:WatermarkNote = "Chưa đóng dấu logo được: $($_.Exception.Message)"
        return ''
    }
}
