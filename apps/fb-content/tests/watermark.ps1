# The watermark as the tool uses it: the brand's settings and the PowerShell calls over src/infrastructure/watermark.mjs. The drawing
# itself (PNG reading and writing, scaling, where it lands) is tested in hub/tests/watermark.test.mjs, in plain Node.
. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Block) { try { & $Block; $false } catch { $true } }
$temp = Join-Path $TestWorkspaceRoot ('watermark-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

$pack = Get-BrandPack 'GRENHEIM'
$mark = Join-Path $pack.dir ([string]$pack.watermark.file)
Assert ($pack.watermark -and $pack.dir -and (Test-Path -LiteralPath $mark)) 'GRENHEIM must have a watermark file.'
Assert ($pack.watermark.position -eq 'top-right' -and [double]$pack.watermark.size -eq 0.13 -and $pack.colors.primary -eq '#103e2e') 'The brand watermark is small, in the top right corner, on the brand color.'
Assert (@($pack.watermark.content_box).Count -eq 4 -and (Test-Path -LiteralPath (Join-Path $pack.dir 'logo.svg'))) 'The watermark needs its content box and the logo it was built from.'
Assert (-not (Get-BrandPack 'Acme').watermark) 'An unknown brand has no watermark.'

$image = Join-Path $temp 'photo.png'
New-TestPng $image 800 600 ([byte[]](110, 110, 110))
$before = [IO.File]::ReadAllBytes($image)
$logo = Add-BrandWatermark $image $pack
Assert ($logo -eq (Join-Path $temp 'photo-logo.png') -and (Test-Path -LiteralPath $logo)) 'The marked copy must be written beside the image as <name>-logo.png.'
Assert ([Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]][IO.File]::ReadAllBytes($image))) 'The original image must not change.'
$size = Get-ImageSize ([IO.File]::ReadAllBytes($logo))
Assert ($size.Format -eq 'png' -and $size.Width -eq 800 -and $size.Height -eq 600) 'The marked copy is a PNG of the same size.'
Assert (-not [Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]][IO.File]::ReadAllBytes($logo))) 'The marked copy must differ from the image.'

# The same call with other settings goes through to the drawing.
$wide = Join-Path $temp 'wide.png'; New-TestPng $wide 1600 900 ([byte[]](110, 110, 110))
Add-ImageWatermark $wide $mark (Join-Path $temp 'wide-bl.png') ([int[]]$pack.watermark.content_box) 'bottom-left' 0.1 0.05 | Out-Null
Assert ((Get-ImageSize ([IO.File]::ReadAllBytes((Join-Path $temp 'wide-bl.png')))).Width -eq 1600) 'Other corners and sizes must work through the same call.'

# Reasons the plain image is kept, and refusals from the drawing.
$noBrand = Add-BrandWatermark $image (Get-BrandPack 'Acme')
Assert ($noBrand -eq '' -and $script:WatermarkNote -match 'chưa có logo') 'A brand without a logo gives no marked copy and says why.'
$text = Join-Path $temp 'notes.png'; Set-Content -LiteralPath $text 'not a picture'
$refused = Add-BrandWatermark $text $pack
Assert ($refused -eq '' -and $script:WatermarkNote -match 'Chưa đóng dấu logo được' -and $script:WatermarkNote -match 'PNG') 'A file that is not a PNG is kept as it is, with the reason.'
Assert (Throws { Add-ImageWatermark $image $mark (Join-Path $temp 'x.png') ([int[]]@(1, 2, 3)) }) 'A bad content box must be refused.'
Assert (Throws { Add-ImageWatermark $image $mark (Join-Path $temp 'x.png') ([int[]]$pack.watermark.content_box) 'top-right' 0.9 }) 'A watermark wider than half the image must be refused.'
Assert (Throws { Add-ImageWatermark (Join-Path $temp 'missing.png') $mark (Join-Path $temp 'x.png') ([int[]]$pack.watermark.content_box) }) 'A missing image must be refused.'
Write-Host 'PASS: brand watermark settings, marked copy beside the image, original untouched, reasons for no mark.' -ForegroundColor Green
