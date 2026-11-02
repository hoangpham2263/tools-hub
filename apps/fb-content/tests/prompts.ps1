# Prompts, angles, brand packs and job checks: no AI is called.
. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Block) { try { & $Block; $false } catch { $true } }

# The angle library: the 24 presets of GRENHEIM's camera-angle library plus "as photo", asked for by id.
$library = Get-ContentAngleLibrary
$ids = @($library.angles | ForEach-Object id)
Assert ($ids.Count -eq 25 -and @($ids | Select-Object -Unique).Count -eq 25 -and $ids -contains 'as-photo') 'The library must hold 25 distinct angles.'
Assert (@($library.angles | Where-Object { -not $_.label -or -not $_.label_en -or -not $_.text -or -not $_.description -or -not $_.group }).Count -eq 0) 'Every angle needs its names, description, group and prompt text.'
$groupCounts = @{}; foreach ($angle in $library.angles) { $groupCounts[$angle.group]++ }
Assert ($groupCounts.direction -eq 7 -and $groupCounts.elevation -eq 4 -and $groupCounts.framing -eq 5 -and $groupCounts.composition -eq 6 -and $groupCounts.application -eq 1 -and $groupCounts.role -eq 1 -and $groupCounts.base -eq 1) 'The groups must follow the library.'
Assert (@($library.angles | Where-Object { $_.group -notin @($library.groups | ForEach-Object id) }).Count -eq 0) 'Every angle must belong to a listed group.'
Assert ((@($library.angles | Where-Object hidden_side | ForEach-Object id) -join ',') -eq 'rear-three-quarter,rear') 'Only the rear views need data the photo cannot give.'
Assert (@($library.sets[0].angles | Where-Object { $_ -notin $ids }).Count -eq 0 -and $library.sets[0].angles.Count -eq 5 -and @($library.default | Where-Object { $_ -notin $ids }).Count -eq 0) 'The studio set and the default picks must use library ids.'
Assert (@($library.angles | Where-Object { $_.text -match 'photo' -and $_.id -ne 'as-photo' -and $_.text -notmatch 'existing|photo shows' -and $_.id -in @('foreground', 'frame-within-frame') }).Count -eq 0) 'Composition angles must use only what already exists.'

# Asking for angles: by id, in the order given; empty, unknown, repeated or too many stop the job.
$angles = Get-ContentAngles @('as-photo', 'three-quarter-left', 'detail')
Assert ($angles.Count -eq 3 -and $angles[0].id -eq 'as-photo' -and $angles[1].id -eq 'three-quarter-left' -and $angles[2].id -eq 'detail') 'Angles must come back by id, in order.'
Assert ((Get-ContentAngles $ids).Count -eq 25) 'All 25 angles can be asked for.'
Assert ((Throws { Get-ContentAngles @() }) -and (Throws { Get-ContentAngles @('front', 'orbit') }) -and (Throws { Get-ContentAngles @('front', 'front') }) -and (Throws { Get-ContentAngles ($ids + 'front') })) 'A bad angle list must stop the job.'

# Image prompt: one layout, the hub's content rules once, and only the camera line changes between shots.
$shot1 = New-ContentImagePrompt 'live-edge table' 'two root legs' $angles[0] 1 3
$shot2 = New-ContentImagePrompt 'live-edge table' 'two root legs' $angles[1] 2 3
foreach ($prompt in @($shot1, $shot2)) {
    foreach ($step in 'TASK:', 'STEP 1 - ROOM (image 1)', 'STEP 2 - PRODUCT', 'STEP 3 - CAMERA', 'STEP 4 - LIGHT, QUALITY AND OUTPUT') { Assert ($prompt.Contains($step)) "Image prompt lacks $step." }
    Assert ([regex]::Matches($prompt, 'CORE PRODUCT RULES \(image 1').Count -eq 1 -and $prompt -match 'two root legs') 'Product rules and details must appear once.'
    Assert ($prompt -match 'camera angle the task asks for' -and $prompt -notmatch 'noise locally') 'Content profile must not keep the photo noise.'
    Assert ($prompt -match 'Show the product without any brand name or logo' -and $prompt -match 'only the camera moves' -and $prompt -match 'Do not move to another room' -and $prompt -match 'professional interior photography' -and $prompt -match 'do not fall back to the original view') 'Brand rule, same-room rule, light block or framing rule missing.'
}
Assert ($shot1 -match 'shot 1 of 3, As photo' -and $shot1 -match 'same position, height, angle' -and $shot1 -notmatch 'different camera position') 'The as-photo shot keeps the photo angle.'
Assert ($shot2 -match 'shot 2 of 3, Left three-quarter view' -and $shot2 -match '45 degrees to the LEFT' -and $shot2 -match 'as seen by a person standing in front of the product' -and $shot2 -match 'different camera position') 'The second shot moves the camera, left as seen from the front.'
Assert ((New-ContentImagePrompt 'x' '' $angles[0] 1 1) -match 'none') 'No details must read as none.'
# A moved shot re-photographs the room and demands a different position; the as-photo shot stays an edit.
Assert ($shot2 -match 'RE-PHOTOGRAPH' -and $shot2 -match 'must not repeat its framing' -and $shot2 -match 'must visibly be taken from a different position') 'A moved shot must re-photograph and demand a different position.'
Assert ($shot1 -notmatch 'RE-PHOTOGRAPH|visibly be taken' -and $shot1 -match 'EDIT THE PHOTOGRAPH IN IMAGE 1') 'The as-photo shot stays an edit.'
Assert ($shot1 -notmatch 'STEP [0-9] - PLACE IT' -and $shot1 -match 'STEP 3 - CAMERA') 'A product photo that is its own scene has no placement step.'

# A separate scene photo: image 1 is the product (always first), image 2 the room. The scene is fitted to the product: true size,
# a proper place, modest styling; only the architecture and the light stay fixed. Rules read image 1.
$placed1 = New-ContentImagePrompt 'live-edge table' 'two root legs' $angles[0] 1 3 $true
$placed2 = New-ContentImagePrompt 'live-edge table' 'two root legs' $angles[1] 2 3 $true
foreach ($prompt in @($placed1, $placed2)) {
    Assert ($prompt -match 'Only the Target product above is the product' -and $prompt -match 'chairs, benches, tableware' -and $prompt -match '- Replace: if the room already has an item of the same kind' -and $prompt -match 'Nothing of the old item may survive or blend into the product' -and $prompt -match 'never the product photo.s chairs') 'The named product alone is the product, and an old item of its kind is removed without blending.'
    foreach ($step in 'TASK:', 'STEP 1 - ROOM (image 2)', 'STEP 2 - PRODUCT', 'STEP 3 - FIT THE SCENE TO THE PRODUCT', 'STEP 4 - CAMERA', 'STEP 5 - LIGHT, QUALITY AND OUTPUT') { Assert ($prompt.Contains($step)) "Placed prompt lacks $step." }
    Assert ([regex]::Matches($prompt, 'CORE PRODUCT RULES \(image 1').Count -eq 1 -and $prompt -match 'IMAGE 1 IS THE ONLY AUTHORITY' -and $prompt -match 'never return image 1 or its setting') 'The product photo (image 1) must be the authority.'
    Assert ($prompt -match '- Scale:' -and $prompt -match '- Place:' -and $prompt -match '- Styling:' -and $prompt -match '- Fixed:' -and $prompt -match 'true real-world size' -and $prompt -match 'remove, move or replace whatever occupies it' -and $prompt -match 'rug is resized or moved') 'The scene must be fitted to the product: size, place, styling, what stays fixed.'
    Assert ($prompt -match 'Image 2 is the BASE PHOTO of the room' -and $prompt -match 'Do not generate a new (scene|room) or reuse the setting of any other image|Do not copy the product photo' -and $prompt -match 'Even in a close-up|comes from image 2.s room' -and $prompt -notmatch 'keep an empty surface empty|no new props') 'A placed shot keeps the room of image 2, may restyle it for the product, and never returns the product photo''s room.'
}
Assert ($placed1 -match 'with the product from image 1 placed in it' -and $placed1 -match 'EDIT THE PHOTOGRAPH IN IMAGE 2' -and $placed2 -match 'RE-PHOTOGRAPH the room in IMAGE 2' -and $placed2 -match '45 degrees to the LEFT') 'Placed shots: the as-photo one edits, the moved one re-photographs.'
# Brand packs: found by id, name or alias without regard to case, spaces or Vietnamese marks; unknown names get a plain one.
foreach ($name in 'grenheim', 'GRENHEIM', ' Grenheim ') { Assert ((Get-BrandPack $name).id -eq 'grenheim') "Brand not found: '$name'." }
$generic = Get-BrandPack 'Acme'
Assert ($generic.id -eq 'generic' -and $generic.name -eq 'Acme' -and -not $generic.tagline -and -not $generic.example) 'An unknown brand must get a plain pack.'
Assert ((Get-BrandPack '').id -eq 'generic') 'An empty brand must get a plain pack.'

# Post prompt: TASK then STEPs 1 to 5 with the numbered rules; one brand's words never reach another's prompt.
$grenheim = Get-BrandPack 'GRENHEIM'
$product = [pscustomobject]@{ name = 'Ban tra goc cay'; link = 'https://shop.test/p/1'; tags = '#BanTraGo'; colors = @([pscustomobject]@{ name = 'Nau oc cho' }, [pscustomobject]@{ name = '' }, [pscustomobject]@{ name = 'Den' }) }
$fb = New-PostPrompt $product 'two root legs' $grenheim (Get-PostPlatform 'facebook') (Get-PostTone 'story') 'nhan manh buoi toi' @('#BanTraGo', '#GRENHEIM')
foreach ($step in 'TASK:', 'STEP 1 - PRODUCT', 'STEP 2 - BRAND', 'STEP 3 - PLATFORM (Facebook)', 'STEP 4 - TONE AND NOTE', 'STEP 5 - RULES') { Assert ($fb.Contains($step)) "Post prompt lacks $step." }
Assert ($fb -match 'GRENHEIM — Vẻ đẹp thiên nhiên' -and $fb -match 'Write the post in Vietnamese' -and $fb -match '1\. FACTS' -and $fb -match '6\. OUTPUT') 'Brand voice or numbered rules missing.'
Assert ($fb -match 'Colors shown in the photos: Nau oc cho, Den' -and $fb -notmatch 'highlights') 'The colors must reach the post prompt and no owner highlights remain.'
Assert ($fb -match 'https://shop.test/p/1' -and $fb -match 'nhan manh buoi toi' -and $fb -match 'at most 5' -and $fb -match 'never copy its wording') 'Product, note, hashtag limit or example guard missing.'
$acme = New-PostPrompt $product '' $generic (Get-PostPlatform 'instagram') (Get-PostTone 'short') '' @()
Assert ($acme -notmatch 'GRENHEIM|Vẻ đẹp thiên nhiên|memorial|father' -and $acme -match 'STEP 5 - RULES') 'One brand leaked into another brand''s prompt.'

# Job checks.
$png = Join-Path $TestWorkspaceRoot 'job-check.png'
New-TestPng $png 4 4
$good = [pscustomobject]@{ imageBackend = 'flow'; textBackend = 'gemini'; tone = 'story'; platforms = @('facebook'); products = @([pscustomobject]@{ id = 'a'; name = 'Ban'; colors = @(
    [pscustomobject]@{ name = 'Nau'; product = [pscustomobject]@{ name = 'p.png'; path = $png }; angles = @('as-photo', 'detail', 'high'); scenes = @() },
    [pscustomobject]@{ name = 'Den'; product = [pscustomobject]@{ name = 'q.png'; path = $png }; angles = @('as-photo'); scenes = @([pscustomobject]@{ name = 'room.png'; path = $png; angles = @('front', 'hero') }) }) }) }
Test-ContentJob $good
function Copy-Job($Job, [scriptblock]$Change) { $copy = $Job | ConvertTo-Json -Depth 8 | ConvertFrom-Json; & $Change $copy; $copy }
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.imageBackend = 'gemini' }) }) 'Gemini cannot make images.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.textBackend = 'flow' }) }) 'Flow cannot write posts.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.platforms = @('myspace') }) }) 'An unknown platform must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.tone = 'angry' }) }) 'An unknown tone must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].name = ' ' }) }) 'A product needs a name.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[0].angles = @('orbit') }) }) 'An unknown angle must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[0].angles = @() }) }) 'A photo with no angle must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[1].scenes[0].angles = @('high', 'high') }) }) 'A repeated angle must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[0].product.path = (Join-Path $TestWorkspaceRoot 'missing.png') }) }) 'A missing product photo must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[1].scenes[0].path = (Join-Path $TestWorkspaceRoot 'missing-room.png') }) }) 'A missing scene photo must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors = @() }) }) 'A product with no product photo must stop the job.'
Assert (Throws { Test-ContentJob (Copy-Job $good { param($j) $j.products[0].colors[1].scenes[0].angles = @('orbit') }) }) 'An unknown angle on a scene must stop the job.'
# Scenes of a color: its scene photos, or its own product photo when it has none.
$own = @(Get-ColorScenes $good.products[0].colors[0]); $separate = @(Get-ColorScenes $good.products[0].colors[1])
Assert ($own.Count -eq 1 -and $own[0].self -and $own[0].path -eq $png -and (@($own[0].angles) -join ',') -eq 'as-photo,detail,high' -and $separate.Count -eq 1 -and -not $separate[0].self -and (@($separate[0].angles) -join ',') -eq 'front,hero') 'A color without scenes uses its product photo as the scene; one with scenes uses them.'
Write-Host 'PASS: angle library, image and post prompts, brand packs without leaks, job checks.' -ForegroundColor Green
