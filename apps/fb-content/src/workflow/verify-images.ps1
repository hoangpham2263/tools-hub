# Checks of the pictures made, done by the text AI with the pictures in front of it, so that a picture that is plainly wrong is
# made again before it is shown. A check that cannot be read (the AI failed, no JSON) never blocks: the picture is kept.

function Read-JsonReply([string]$Raw) {
    $json = [regex]::Match([string]$Raw, '\{[\s\S]*\}').Value
    if (-not $json) { return $null }
    try { $json | ConvertFrom-Json } catch { $null }
}

# Does the room photo still have furniture of the product's kind? $true, $false, or $null when it could not be told.
function Test-RoomHasItem($Product, [string]$Image, [string]$Folder, [string]$Tag) {
    $prompt = @"
TASK: Look at the room photograph in image 1.
Is there any "$([string]$Product.name)" in it, or any other furniture of the same kind (a table of any shape, with or without chairs)?
Reply with JSON only: {"has_item": true or false, "what": "what you see, in one sentence"}
"@
    try {
        $reply = Read-JsonReply (Invoke-AI $prompt @($Image) (Join-Path $Folder "logs/check-$Tag-room.txt"))
        if ($null -eq $reply -or $null -eq $reply.has_item) { return $null }
        return [bool]$reply.has_item
    } catch { Write-Host "  [CHECK] Room check skipped: $($_.Exception.Message)" -ForegroundColor Yellow; return $null }
}

# Is the product in the made picture the product of its photo? Returns @{ ok; why }; ok is $true when it could not be told.
function Test-ShotMatches($Product, [string]$ProductImage, [string]$Result, [string]$Folder, [string]$Tag) {
    $prompt = @"
TASK: Image 1 is the product photo of a "$([string]$Product.name)". Image 2 is a new photograph that was made to show the same product in a room.
Compare the product in image 2 with the product in image 1 only (ignore chairs, tableware, the room and the camera angle).
STEP 1 - Is the shape of the top (outline, thickness) the same?
STEP 2 - Is the base or legs the same (shape, number of parts, how it meets the floor)?
STEP 3 - Is the wood color and grain the same?
STEP 4 - Is there a second table or a different table in image 2, or is the product in image 2 a different piece of furniture?
Reply with JSON only: {"same_product": true or false, "why": "if false: what differs, in one sentence"}
"@
    try {
        $reply = Read-JsonReply (Invoke-AI $prompt @($ProductImage, $Result) (Join-Path $Folder "logs/check-$Tag-match.txt"))
        if ($null -eq $reply -or $null -eq $reply.same_product) { return @{ ok = $true; why = '' } }
        return @{ ok = [bool]$reply.same_product; why = [string]$reply.why }
    } catch { Write-Host "  [CHECK] Product check skipped: $($_.Exception.Message)" -ForegroundColor Yellow; return @{ ok = $true; why = '' } }
}

# The real scene photo with its furniture of the product's kind taken out, made again (up to 3 times, each asking harder) until
# the text AI sees none. Returns the path of the clean copy, or '' when none could be made (the real photo is then used).
function New-CleanRoom($Product, $Scene, [string]$OldItems, [int]$SceneNo, [string]$Folder) {
    $asks = @(
        "Remove completely: $OldItems",
        "The previous attempt still left furniture of that kind. Remove ALL tables, desks and chairs, the whole set, leaving an EMPTY floor and rug: $OldItems",
        "Make the middle of the room EMPTY: no table, no desk, no chairs and no tabletop objects at all, only the floor and the rug continuing underneath. Previously there was: $OldItems"
    )
    for ($attempt = 1; $attempt -le $asks.Count; $attempt++) {
        $file = Join-Path $Folder "logs/canh-$SceneNo-sach.png"
        $prompt = "EDIT THE PHOTOGRAPH IN IMAGE 1 into ONE photorealistic photograph of the same room with that furniture removed. $($asks[$attempt - 1]) Where it stood, show the floor and rug continuing naturally. The room itself (walls, windows, floor, rug, plants, light, view, decoration, the other objects) stays exactly as it is, from the same camera position. Add nothing. One image only, no text."
        try {
            Write-Host "  [SCENE] Making room $SceneNo empty, try $attempt/$($asks.Count)..." -ForegroundColor Cyan
            Invoke-ImageAI $prompt @([string]$Scene.path) $file (Join-Path $Folder "logs/canh-$SceneNo-sach-image.txt")
            if ($script:Config.ImageBackend -eq 'flow') { try { Remove-HubImageSparkle $file | Out-Null } catch { Write-Host "  [WARN] Sparkle not removed: $($_.Exception.Message)" -ForegroundColor Yellow } }
        } catch {
            Write-Host "  [SCENE] Cleaning the room failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ((Get-ErrorCause $_.Exception.Message) -in @('QUOTA', 'AUTH', 'BRIDGE')) { $script:Run.Abort = $true }
            return ''
        }
        $has = Test-RoomHasItem $Product $file $Folder "$SceneNo-$attempt"
        if ($has -ne $true) { return $file }
    }
    ''
}
