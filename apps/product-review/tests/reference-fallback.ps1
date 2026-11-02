. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:Config = @{ AgentInstructionsPath=(Join-Path $root 'AGENTS.md') }
$script:Batch = @{ Images = $TestWorkspaceRoot; Logs = $TestWorkspaceRoot }
$context = [pscustomobject]@{ product = 'apron'; presentation = 'worn'; setting = 'cafe'; source_categories = @('aprons'); details = 'black apron'; branding = 'preserve logo'; reject = 'golf' }
# Object edits keep the attached review photo as the base.
function Test-ObjectEdit {
    $object = [pscustomobject]@{presentation='placed';product='dining table';source_categories=@('dining-tables')}
    $selected = @('attached-review.jpg')
    $tableRequest = New-ProductImageRequest 'product.jpg' 'one-room' $object $selected
    Assert ($tableRequest.Prompt -match 'Show the product without any brand name or logo' -and $tableRequest.Prompt -notmatch 'fictional brand|BRAND:') 'Object generation must show the product unbranded, inventing no brand.'
    Assert ($tableRequest.Prompt -match 'IMMUTABLE BASE PHOTO' -and $tableRequest.Prompt -match 'never return image 2 or its setting' -and $tableRequest.Prompt -match 'Do not relight, recolor') 'Object generation must directly deliver its edit of the base photo, never the product photo.'
    Assert ($tableRequest.Prompt -notmatch 'Appropriate context:|Reject:') 'Scene-picking context must not reach the prompt; the attached photo is the scene.'
    Assert ($tableRequest.Prompt -notmatch 'standing height|off-center framing|do not inherit its professional lighting') 'Old restyling instructions conflict with the locked room.'
    Assert ($tableRequest.Prompt -match 'Do not bleach, desaturate or restain') 'Direct furniture edits must preserve intrinsic wood color.'
    Assert ([regex]::Matches($tableRequest.Prompt, 'CORE PRODUCT RULES \(').Count -eq 1 -and $tableRequest.Prompt -match '2\. COLOR:.*part by part' -and $tableRequest.Prompt -match '3\. SHAPE:' -and $tableRequest.Prompt -notmatch 'wood tone|COLOR LOCK|SUPPORT FIDELITY') 'Core product rules must appear once, with no leftover per-case color or support rules.'
    Assert ($tableRequest.Prompt -match 'originally bare table bare') 'Generation must directly deliver the tool image and preserve originally empty surfaces.'
    Assert ($tableRequest.Prompt -match 'NO INVENTED PROPS' -and $tableRequest.Prompt -match 'Empty areas and bare surfaces must stay empty' -and $tableRequest.Prompt -match 'must not be transplanted into an empty room') 'Empty-room constraints must prevent newly staged props, including objects copied from the product photo.'
    Assert ($tableRequest.Prompt -match 'Ghế quanh bàn ăn.*chiều cao sử dụng' -and $tableRequest.Prompt -match 'bán cả bộ.*đúng ghế' -and $tableRequest.Prompt -match 'không coi ghế là hàng bán kèm') 'Table seating preference is missing or falsely claims sold components.'
    Assert ($tableRequest.Prompt -match 'DINING TABLE AND SEATING FIT' -and $tableRequest.Prompt -match 'UNDERSIDE' -and $tableRequest.Prompt -match 'thigh clearance, knee space and foot space' -and $tableRequest.Prompt -match 'does not lock incompatible chair placement or scale' -and $tableRequest.Prompt -match 'Do not lower, flatten, stretch or thicken' -and $tableRequest.Prompt -match 'do not invent or label exact measurements') 'Dining edits must reconcile seating clearance without deforming the product or inventing dimensions.'
    Assert ($tableRequest.Prompt -match 'LEVEL HORIZONTAL PLANE parallel to the room floor' -and $tableRequest.Prompt -match 'TOP OF THE SEAT CUSHION to the ACTUAL UNDERSIDE' -and $tableRequest.Prompt -match 'Remove the old table.s support geometry' -and $tableRequest.Prompt -match 'do not merely raise the top while stretching the supports') 'Dining fit must explicitly prevent tilted tops, cushion clearance mistakes and inherited old-table supports.'
    Assert ($tableRequest.Prompt -match 'crosswise roll and longitudinal pitch' -and $tableRequest.Prompt -match 'does not mean screen-horizontal edges' -and $tableRequest.Prompt -match 'Do not rotate the camera, room or whole photograph') 'Level-table correction must preserve room perspective rather than rotate or flatten the photograph.'
    $object.source_categories=@('coffee-table');$object.product='low oval coffee table'
    $coffeeRequest=New-ProductImageRequest 'product.jpg' 'coffee-room' $object $selected
    Assert ($coffeeRequest.Prompt -match 'Bàn trà thấp.*không giữ ghế ăn cao' -and $coffeeRequest.Prompt -match 'không tự thêm ghế hoặc đổi toàn bộ căn phòng') 'Coffee-table seating must fit the current product without adding seats or redesigning the room.'
    Assert ($coffeeRequest.Prompt -notmatch 'DINING TABLE AND SEATING FIT') 'Dining chair clearance must not override low coffee-table seating.'
    Assert ($coffeeRequest.Prompt -match 'LOW TABLE AND SEATING' -and $coffeeRequest.Prompt -match 'never remove a seat and never add one' -and $coffeeRequest.Prompt -match 'do not leave tall dining chairs') 'Coffee-table prompt must keep the seat count and restyle seats low.'
    $object.source_categories=@('lamps');$object.product='floor lamp'
    $lampRequest=New-ProductImageRequest 'product.jpg' 'lamp-room' $object $selected
    Assert ($lampRequest.Prompt -notmatch 'Ghế quanh bàn ăn|Bàn trà thấp') 'Table preference leaked into an unrelated product category.'
    Assert ($lampRequest.Prompt -notmatch 'DINING TABLE AND SEATING FIT|LOW TABLE AND SEATING') 'Seating instructions leaked into an unrelated object edit.'
}
Test-ObjectEdit
$request = New-ProductImageRequest 'actual.png' 'one-source' $context @('attached-person.png')
Assert ($request.Prompt -match 'Image 1 also supplies the real setting' -and $request.Prompt -match 'do not invent a different location') 'A worn product invented a new location.'
Write-Host 'PASS: object and worn prompts keep the attached review photo and its setting.'
