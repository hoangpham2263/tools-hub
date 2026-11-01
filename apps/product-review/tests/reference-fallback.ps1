. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:Config = @{ PhotosPerImage = 2; WritingStyle = [pscustomobject]@{ scene_rules = @() }; AgentInstructionsPath=(Join-Path $root 'AGENTS.md') }
$script:Batch = @{ Images = $TestWorkspaceRoot; Logs = $TestWorkspaceRoot }
# One verified real setting is sufficient when an optional second scene is absent.
$context = [pscustomobject]@{ product = 'apron'; presentation = 'worn'; setting = 'cafe'; source_categories = @('aprons'); details = 'black apron'; branding = 'preserve logo'; reject = 'golf' }
$script:MissingSubject = $false
function Select-Photo($Reference, $Handle, $ItemId, $Exclude, $Role, $Context, $SubjectPhoto) {
    if($Role -eq 'Scene'){throw 'Must not select a second review photo.'}
    if ($Role -eq 'Subject' -and -not $script:MissingSubject) { return 'checked-person-and-real-cafe.png' }
    throw 'No suitable source photo found after 2 checks.'
}
function Get-SourceCatalog { @{} }
# Object scene selection stops immediately after the first suitable room.
$script:SceneCalls = 0
function Test-ObjectSceneSelection {
    function Select-Photo { $script:SceneCalls++; return 'checked-dining-room.jpg' }
    $object = [pscustomobject]@{presentation='placed';product='dining table';source_categories=@('dining-tables')}
    $selected = @(Select-ProductReferences 'product.jpg' 'table' 'one-room' $object)
    Assert ($selected.Count -eq 1 -and $script:SceneCalls -eq 1) 'Optional second object scene must not trigger more AI calls.'
    $tableRequest = New-ProductImageRequest 'product.jpg' 'one-room' $object $selected ([Collections.ArrayList]::new())
    Assert ($tableRequest.Prompt -match 'A photo watermark is not a product logo' -and $tableRequest.Prompt -match 'Do not replace them with fictional branding' -and $tableRequest.Prompt -match 'unbranded table.*BRAND: none') 'Object generation must remove watermarks without inventing furniture branding.'
    Assert ($tableRequest.Prompt -match 'IMMUTABLE BASE PHOTO' -and $tableRequest.Prompt -match 'never return image 2 or its setting' -and $tableRequest.Prompt -match 'DIRECT IMAGE DELIVERY' -and $tableRequest.Prompt -match 'Do not relight, recolor' -and $tableRequest.SceneBase -eq $selected[0]) 'Object generation must directly deliver its edit of the base photo, never the product photo.'
    Assert ($tableRequest.Prompt -notmatch 'standing height|off-center framing|do not inherit its professional lighting') 'Old restyling instructions conflict with the locked room.'
    Assert ($tableRequest.Prompt -match 'Do not bleach, desaturate or restain') 'Direct furniture edits must preserve intrinsic wood color.'
    Assert ($tableRequest.Prompt -match 'without further image processing' -and $tableRequest.Prompt -match 'originally bare table bare') 'Generation must directly deliver the tool image and preserve originally empty surfaces.'
    Assert ($tableRequest.Prompt -match 'NO INVENTED PROPS' -and $tableRequest.Prompt -match 'Empty areas and bare surfaces must stay empty' -and $tableRequest.Prompt -match 'must not be transplanted into an empty room') 'Empty-room constraints must prevent newly staged props, including objects copied from the product photo.'
    Assert ($tableRequest.Prompt -match 'Ghế quanh bàn ăn.*chiều cao sử dụng' -and $tableRequest.Prompt -match 'bán cả bộ.*đúng ghế' -and $tableRequest.Prompt -match 'không coi ghế là hàng bán kèm') 'Table seating preference is missing or falsely claims sold components.'
    Assert ($tableRequest.Prompt -match 'DINING TABLE AND SEATING FIT' -and $tableRequest.Prompt -match 'UNDERSIDE' -and $tableRequest.Prompt -match 'thigh clearance, knee space and foot space' -and $tableRequest.Prompt -match 'does not lock incompatible chair placement or scale' -and $tableRequest.Prompt -match 'Do not lower, flatten, stretch or thicken' -and $tableRequest.Prompt -match 'do not invent or label exact measurements') 'Dining edits must reconcile seating clearance without deforming the product or inventing dimensions.'
    Assert ($tableRequest.Prompt -match 'LEVEL HORIZONTAL PLANE parallel to the room floor' -and $tableRequest.Prompt -match 'TOP OF THE SEAT CUSHION to the ACTUAL UNDERSIDE' -and $tableRequest.Prompt -match 'Remove the old table.s support geometry' -and $tableRequest.Prompt -match 'do not merely raise the top while stretching the supports') 'Dining fit must explicitly prevent tilted tops, cushion clearance mistakes and inherited old-table supports.'
    Assert ($tableRequest.Prompt -match 'crosswise roll and longitudinal pitch' -and $tableRequest.Prompt -match 'does not mean screen-horizontal edges' -and $tableRequest.Prompt -match 'Do not rotate the camera, room or whole photograph') 'Level-table correction must preserve room perspective rather than rotate or flatten the photograph.'
    $object.source_categories=@('coffee-table');$object.product='low oval coffee table'
    $coffeeRequest=New-ProductImageRequest 'product.jpg' 'coffee-room' $object $selected ([Collections.ArrayList]::new())
    Assert ($coffeeRequest.Prompt -match 'Bàn trà thấp.*không giữ ghế ăn cao' -and $coffeeRequest.Prompt -match 'không tự thêm ghế hoặc đổi toàn bộ căn phòng') 'Coffee-table seating must fit the current product without adding seats or redesigning the room.'
    Assert ($coffeeRequest.Prompt -notmatch 'DINING TABLE AND SEATING FIT') 'Dining chair clearance must not override low coffee-table seating.'
    $object.source_categories=@('lamps');$object.product='floor lamp'
    $lampRequest=New-ProductImageRequest 'product.jpg' 'lamp-room' $object $selected ([Collections.ArrayList]::new())
    Assert ($lampRequest.Prompt -notmatch 'Ghế quanh bàn ăn|Bàn trà thấp') 'Table preference leaked into an unrelated product category.'
    Assert ($lampRequest.Prompt -notmatch 'DINING TABLE AND SEATING FIT') 'Dining seating instructions leaked into an unrelated object edit.'
}
Test-ObjectSceneSelection
$picked = @(Select-ProductReferences 'actual.png' 'apron' 'one-source' $context)
Assert ($picked.Count -eq 1 -and $picked[0] -eq 'checked-person-and-real-cafe.png') 'Optional scene failure discarded a valid real setting.'
$request = New-ProductImageRequest 'actual.png' 'one-source' $context $picked ([Collections.ArrayList]::new())
Assert ($request.Prompt -match 'Image 1 also supplies the real setting' -and $request.Prompt -match 'do not invent a different location') 'Single-reference fallback invented a new location.'
$script:MissingSubject = $true
$failed = $false
try { Select-ProductReferences 'actual.png' 'apron' 'no-source' $context | Out-Null } catch { $failed = $true }
Assert $failed 'Missing all local references must block generation.'
# Missing sample data is recorded per product and summarized for the batch.
$batchDir = Join-Path $TestWorkspaceRoot ('missing-data-test-' + [Guid]::NewGuid().ToString('N'))
$script:Batch = @{ Dir = $batchDir; MissingData = Join-Path $batchDir 'missing-data' }
$product = Join-Path $TestWorkspaceRoot 'missing-product.jpg'
[IO.File]::WriteAllBytes($product, [byte[]](1,2,3))
Save-MissingData ([pscustomobject]@{ Url = 'https://example.test/p/lamp'; Handle = 'lamp' }) '001-lamp' $context $product 'No suitable source photo found after 0 checks.'
Write-MissingDataSummary $script:Batch
Assert (Test-Path (Join-Path $batchDir 'missing-data/001-lamp/product.jpg')) 'Missing-data product image not saved.'
$row = @(Import-Csv (Join-Path $batchDir 'missing-data.csv'))
Assert ($row.Count -eq 1 -and $row[0].product_url -eq 'https://example.test/p/lamp' -and $row[0].categories -eq 'aprons') 'Missing-data summary is incomplete.'
Remove-Item -LiteralPath $batchDir, $product -Recurse -Force
Write-Host 'PASS: missing sample data is recorded; optional second scene keeps a checked real setting; zero references block.'
