# A whole run with every AI call mocked: one photo, several angles, a post per platform, repairs, retries and stops.
. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$temp = Join-Path $TestWorkspaceRoot ('content-run-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

$script:Events = @()
function Send-Event([hashtable]$Event) { $script:Events += [pscustomobject]$Event }
$script:Calls = @()
# Drive is mocked: a login that is there by default, every file sent is recorded, and a path can be made to fail.
$script:FakeDrive = @{ ApiUrl = 'https://drive.test'; AdminKey = 'k' }
$script:DriveSent = @()
$script:DriveFail = ''
function Get-ContentDrive { $script:FakeDrive }
function Send-DriveToolFile($Drive, [string]$Tool, [string]$RelativePath, [string]$File) {
    if ($script:DriveFail -and $RelativePath -like $script:DriveFail) { throw 'HTTP 500 simulated' }
    $script:DriveSent += [pscustomobject]@{ Tool = $Tool; Path = $RelativePath; Bytes = (Get-Item -LiteralPath $File).Length }
}
$script:Behavior = @{}
function ConvertTo-Plain([int]$Words) { (@(1..$Words | ForEach-Object { 'chu' }) -join ' ') + '.' }
function Invoke-HubAI {
    param([string]$Kind, [string]$Ai, [string]$Prompt, [string[]]$Images, [string]$Output, [hashtable]$Options)
    $script:Calls += [pscustomobject]@{ Kind = $Kind; Ai = $Ai; Prompt = $Prompt; Images = $Images }
    if ($Kind -eq 'image') {
        $n = @($script:Calls | Where-Object Kind -eq 'image').Count
        if ($script:Behavior.ImageFail -and $script:Behavior.ImageFail[$n]) { throw $script:Behavior.ImageFail[$n] }
        New-TestPng $Output 8 6
        return [pscustomobject]@{ source = 'mock'; bytes = 100 }
    }
    if ($Prompt -match '"has_item"') { $script:RoomChecks++; $reply = if ($script:Behavior.RoomHasItemTimes -ge $script:RoomChecks) { '{"has_item": true, "what": "a table"}' } else { '{"has_item": false, "what": "an empty rug"}' } }
    elseif ($Prompt -match '"same_product"') { $script:ShotChecks++; $reply = if ($script:Behavior.MismatchTimes -ge $script:ShotChecks) { '{"same_product": false, "why": "the base is a ring, not a twisted ribbon"}' } else { '{"same_product": true, "why": ""}' } }
    elseif ($Prompt -match '"old_items"') { $reply = if ($script:Behavior.NoOldItems) { '{"old_items":"none"}' } else { '{"old_items":"A kidney-shaped dark wood table with a ring-shaped base and two rattan chairs."}' } }
    elseif ($Prompt -match 'identify the actual product') { $reply = '{"product":"table","details":"two forked root legs; medium orange-leaning top"}' }
    else {
        $platform = [regex]::Match($Prompt, 'write one (\w+) post').Groups[1].Value
        $same = @($script:Calls | Where-Object { $_.Kind -eq 'text' -and $_.Prompt -match "write one $platform post" }).Count
        $reply = switch ($platform) {
            'Facebook' { if ($script:Behavior.FacebookExclaims -and $same -eq 1) { (ConvertTo-Plain 90) + ' Dep qua!' } else { "``````" + "`n" + (ConvertTo-Plain 90) + "`n`n#Rieng #A #B #C #D #E`n" + "``````" } }
            'Instagram' { (ConvertTo-Plain 60) + " Xem tai https://leak.test/x nhe." }
            'Threads' { ConvertTo-Plain 30 }
            'TikTok' { ConvertTo-Plain 15 }
        }
    }
    [IO.File]::WriteAllText($Output, $reply)
    return $reply
}

$photo = Join-Path $temp 'photo.png'
New-TestPng $photo 8 6
function New-TestJob([int]$Products = 1, [int]$Angles = 3) {
    $pick = @('as-photo', 'three-quarter-left', 'three-quarter-right', 'high') | Select-Object -First $Angles
    [pscustomobject]@{
        imageBackend = 'flow'; textBackend = 'gemini'; tone = 'story'; note = 'nhan manh buoi toi'; verify = 'false'; sceneMode = 'named'
        platforms = @('facebook', 'instagram', 'threads', 'tiktok')
        products = @(1..$Products | ForEach-Object {
            [pscustomobject]@{ id = "p$_"; name = "Ban tra goc cay $_"; brand = 'GRENHEIM'; link = 'https://shop.test/p/1'; tags = '#BanTraGo'
                colors = @([pscustomobject]@{ name = 'Nau'; product = [pscustomobject]@{ name = 'photo.png'; path = $photo }; angles = @($pick); scenes = @() }) }
        })
    }
}
function Reset-Run { $script:Events = @(); $script:Calls = @(); $script:Behavior = @{}; $script:RoomChecks = 0; $script:ShotChecks = 0 }

# 1. One photo, three angles, four platforms.
Reset-Run
$out = Join-Path $temp 'out1'
$code = Invoke-ContentRun (New-TestJob 1 3) $out
$run = @(Get-ChildItem $out -Directory)[0]
$product = @(Get-ChildItem $run.FullName -Directory)[0]
Assert ($code -eq 0 -and $product.Name -eq '01-ban-tra-goc-cay-1') 'A good run must exit 0 and name the folder from the product.'
$kinds = @($script:Events | ForEach-Object kind)
Assert ($kinds[0] -eq 'start' -and $kinds -contains 'product' -and @($kinds | Where-Object { $_ -eq 'image' }).Count -eq 3 -and @($kinds | Where-Object { $_ -eq 'post' }).Count -eq 4 -and $kinds[-1] -eq 'done') 'Events must run start, product, 3 images, 4 posts, done.'
Assert (@($script:Events | Where-Object { $_.kind -eq 'image' -and -not $_.ok }).Count -eq 0 -and ($script:Events | Where-Object kind -eq 'done').ok -eq 1) 'Every shot and the product must be ok.'
foreach ($name in 'anh-1-1-1-as-photo', 'anh-1-1-2-three-quarter-left', 'anh-1-1-3-three-quarter-right') { Assert (Test-ImageFile (Join-Path $product.FullName "$name.png")) "$name was not saved as an image." }
$imageCalls = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($imageCalls.Count -eq 3 -and @($imageCalls | Where-Object { $_.Images.Count -eq 1 -and $_.Images[0] -eq $photo }).Count -eq 3 -and $imageCalls[0].Ai -eq 'flow') 'Each shot sends the one photo to the chosen image AI.'
Assert ($imageCalls[0].Prompt -match 'same position, height, angle' -and $imageCalls[1].Prompt -match '45 degrees to the LEFT' -and $imageCalls[2].Prompt -match '45 degrees to the RIGHT') 'The shots must use the camera lines of the angles picked.'
Assert ($imageCalls[1].Prompt -match 'two forked root legs' -and $imageCalls[1].Prompt -match 'shot 2 of 3') 'The product note and the shot number must reach the prompt.'
$textCalls = @($script:Calls | Where-Object Kind -eq 'text')
Assert ($textCalls.Count -eq 5 -and @($textCalls | Where-Object { $_.Ai -eq 'gemini' }).Count -eq 5) 'One description and four posts, all by the chosen text AI.'
Assert ($imageCalls[0].Prompt -match 'EDIT THE PHOTOGRAPH' -and $imageCalls[1].Prompt -match 'RE-PHOTOGRAPH' -and $imageCalls[2].Prompt -match 'must visibly be taken from a different position') 'Only the moved shots re-photograph the room.'
$fbText = [IO.File]::ReadAllText((Join-Path $product.FullName 'bai-facebook.txt'), [Text.Encoding]::UTF8)
$igText = [IO.File]::ReadAllText((Join-Path $product.FullName 'bai-instagram.txt'), [Text.Encoding]::UTF8)
$thText = [IO.File]::ReadAllText((Join-Path $product.FullName 'bai-threads.txt'), [Text.Encoding]::UTF8)
$ttText = [IO.File]::ReadAllText((Join-Path $product.FullName 'bai-tiktok.txt'), [Text.Encoding]::UTF8)
Assert ($fbText -notmatch '```' -and $fbText -match 'https://shop.test/p/1' -and @([regex]::Matches($fbText, '#\w+')).Count -le 5 -and $fbText -match '#Rieng #A #B #C #D') 'Facebook: no fence, the link, at most 5 hashtags, the AI''s first.'
Assert ($igText -notmatch 'http' -and $igText -match '#BanTraGo') 'Instagram: the stray link is removed.'
Assert ($thText -match 'https://shop.test/p/1' -and @([regex]::Matches($thText, '#\w+')).Count -eq 1 -and $thText.Length -le 500) 'Threads: link, one hashtag, within 500 characters.'
Assert ($ttText -notmatch "`n" -and $ttText -notmatch 'http') 'TikTok: one line without a link.'
$snapshot = Get-Content (Join-Path $product.FullName 'snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($snapshot.colors[0].product.sha256 -eq (Get-FileSha256 $photo) -and (@($snapshot.colors[0].scenes[0].angles) -join ',') -eq 'as-photo,three-quarter-left,three-quarter-right' -and $snapshot.colors[0].scenes[0].self -and $snapshot.colors[0].details -match 'forked root legs' -and $snapshot.tone -eq 'story') 'The snapshot must keep the photo hash, angles, details and tone.'
$results = @(Get-Content (Join-Path $run.FullName 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
Assert ($results.Count -eq 1 -and $results[0].ok -and @($results[0].images).Count -eq 3 -and (Test-Path (Join-Path $product.FullName 'logs/anh-1-1-2-prompt.txt')) -and @($results[0].images | ForEach-Object angle_id).Count -eq 3) 'results.json and the saved prompts must exist.'

# 2. A first Facebook draft with an exclamation is sent back once, with the draft in the request.
Reset-Run; $script:Behavior = @{ FacebookExclaims = $true }
$code = Invoke-ContentRun (New-TestJob 1 1) (Join-Path $temp 'out2')
$facebookCalls = @($script:Calls | Where-Object { $_.Kind -eq 'text' -and $_.Prompt -match 'write one Facebook post' })
$facebookPost = $script:Events | Where-Object { $_.kind -eq 'post' -and $_.platform -eq 'facebook' }
Assert ($facebookCalls.Count -eq 2 -and $facebookCalls[1].Prompt -match 'Your previous draft' -and $facebookCalls[1].Prompt -match 'exclamation mark' -and $facebookPost.text -notmatch '!') 'An exclamation must be repaired once, and the repair carries the draft.'

# 3. A busy service delivers on the second request; the shot is not lost.
Reset-Run; $script:Behavior = @{ ImageFail = @{ 1 = 'Flow is busy. [CAUSE:BUSY]' } }
$code = Invoke-ContentRun (New-TestJob 1 1) (Join-Path $temp 'out3')
Assert (@($script:Calls | Where-Object Kind -eq 'image').Count -eq 2 -and @($script:Events | Where-Object { $_.kind -eq 'image' -and $_.ok }).Count -eq 1) 'A busy service must be retried once.'

# 4. A quota stop ends the run: no more shots, no next product, the posts of this product are still written.
Reset-Run; $script:Behavior = @{ ImageFail = @{ 2 = 'You hit the limit. [CAUSE:QUOTA]' } }
$code = Invoke-ContentRun (New-TestJob 2 3) (Join-Path $temp 'out4')
$images = @($script:Events | Where-Object kind -eq 'image')
$done = $script:Events | Where-Object kind -eq 'done'
Assert ($images.Count -eq 2 -and $images[0].ok -and -not $images[1].ok -and @($script:Calls | Where-Object Kind -eq 'image').Count -eq 2) 'After a quota stop no further shot may be asked for.'
Assert (@($script:Events | Where-Object kind -eq 'product').Count -eq 1 -and $done.aborted -and $done.ok -eq 1 -and $done.failed -eq 1) 'The second product must not start after a quota stop.'
Assert (@($script:Events | Where-Object { $_.kind -eq 'post' -and $_.text }).Count -eq 4) 'The first product''s posts are still written.'

# 5. A refused shot costs only that shot (policy), a missing description is a warning, not a stop.
Reset-Run; $script:Behavior = @{ ImageFail = @{ 1 = '[CAUSE:POLICY] Flow refused.' } }
$code = Invoke-ContentRun (New-TestJob 1 2) (Join-Path $temp 'out5')
Assert (@($script:Events | Where-Object { $_.kind -eq 'image' }).Count -eq 2 -and @($script:Events | Where-Object { $_.kind -eq 'image' -and $_.ok }).Count -eq 1 -and -not ($script:Events | Where-Object kind -eq 'done').aborted) 'A policy refusal must only cost that shot.'
# 6. Two colors: one shot in its own photo, one in a separate scene photo. Every shot of the scene gets the REAL product photo
# (image 1) and the REAL scene photo (image 2); a generated picture is never the input of another shot, so one wrong shot cannot
# make the others wrong. No base shot is added: only the angles that were picked are made.
Reset-Run
$scenePhoto = Join-Path $temp 'room.png'; New-TestPng $scenePhoto 10 8
$colorPhoto = Join-Path $temp 'black.png'; New-TestPng $colorPhoto 6 6
function New-SceneJob {
    $job = New-TestJob 1 1
    $job.products[0].colors = @(
        [pscustomobject]@{ name = 'Nau'; product = [pscustomobject]@{ name = 'photo.png'; path = $photo }; angles = @('as-photo'); scenes = @() },
        [pscustomobject]@{ name = 'Den'; product = [pscustomobject]@{ name = 'black.png'; path = $colorPhoto }; angles = @('as-photo'); scenes = @([pscustomobject]@{ name = 'room.png'; path = $scenePhoto; angles = @('front', 'detail') }) })
    $job.platforms = @('tiktok')
    $job
}
$code = Invoke-ContentRun (New-SceneJob) (Join-Path $temp 'out6')
$run6 = @(Get-ChildItem (Join-Path $temp 'out6') -Directory)[0]; $product6 = @(Get-ChildItem $run6.FullName -Directory)[0]
$calls6 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($code -eq 0 -and $calls6.Count -eq 3) 'One own-photo shot plus the two picked angles of the scene make three shots, with no extra base shot.'
Assert ($calls6[0].Images.Count -eq 1 -and $calls6[0].Images[0] -eq $photo) 'A color with no scene goes alone.'
foreach ($i in 1, 2) {
    Assert ($calls6[$i].Images.Count -eq 2 -and $calls6[$i].Images[0] -eq $colorPhoto -and $calls6[$i].Images[1] -eq $scenePhoto) "Shot $i of the scene must get the real product photo (image 1) and the real scene photo (image 2), nothing generated."
    Assert ($calls6[$i].Prompt -match 'STEP 3 - FIT THE SCENE TO THE PRODUCT' -and $calls6[$i].Prompt -match 'CORE PRODUCT RULES \(image 1' -and $calls6[$i].Prompt -match 'forked root legs' -and $calls6[$i].Prompt -notmatch 'already shows a version') "Shot $i of the scene needs the fit step, the rules on image 1 and the color's product note."
}
Assert ($calls6[1].Prompt -match 'RE-PHOTOGRAPH the room in IMAGE 2' -and $calls6[1].Prompt -match 'STEP 1 - ROOM \(image 2\)') 'An angle re-photographs the room of image 2.'
Assert (@($script:Calls | Where-Object { $_.Kind -eq 'image' } | ForEach-Object { $_.Images } | Where-Object { $_ -like '*anh-*' }).Count -eq 0) 'No generated picture (anh-*.png) is ever sent as an input.'
foreach ($name in 'anh-1-1-1-as-photo', 'anh-2-1-1-front', 'anh-2-1-2-detail') { Assert (Test-ImageFile (Join-Path $product6.FullName "$name.png")) "$name was not saved." }
Assert (-not (Test-Path -LiteralPath (Join-Path $product6.FullName 'anh-2-1-1-as-photo.png'))) 'The scene must not get a base shot that was not asked for.'
$descriptions = @($script:Calls | Where-Object { $_.Kind -eq 'text' -and $_.Prompt -match 'identify the actual product' })
Assert ($descriptions.Count -eq 2 -and $descriptions[0].Images[0] -eq $photo -and $descriptions[1].Images[0] -eq $colorPhoto) 'Each color''s product photo is described on its own.'
$event6 = @($script:Events | Where-Object kind -eq 'image')
Assert ((($event6 | ForEach-Object { "$($_.color)-$($_.scene)-$($_.angle)" }) -join ',') -eq '1-1-1,2-1-1,2-1-2') 'Shot events must say which color, scene and angle they are.'

# 7. A shot that fails costs only that shot: the next angle of the scene is still made from the real photos.
Reset-Run; $script:Behavior = @{ ImageFail = @{ 2 = '[CAUSE:POLICY] Flow refused.' } }
$code = Invoke-ContentRun (New-SceneJob) (Join-Path $temp 'out7')
$events7 = @($script:Events | Where-Object { $_.kind -eq 'image' -and $_.color -eq 2 })
Assert (@($script:Calls | Where-Object Kind -eq 'image').Count -eq 3 -and $events7.Count -eq 2 -and @($events7 | Where-Object ok).Count -eq 1 -and -not $events7[0].ok -and $events7[1].ok) 'A failed shot must not stop the other angles of the scene.'

# 8. With the watermark switch on: every shot gets a -logo copy and the window is shown that copy; the plain image stays.
Reset-Run
$job = New-SceneJob
$job | Add-Member -NotePropertyName watermark -NotePropertyValue $true -Force
$code = Invoke-ContentRun $job (Join-Path $temp 'out8')
$run8 = @(Get-ChildItem (Join-Path $temp 'out8') -Directory)[0]; $product8 = @(Get-ChildItem $run8.FullName -Directory)[0]
$events8 = @($script:Events | Where-Object kind -eq 'image')
Assert ($code -eq 0 -and $events8.Count -eq 3 -and @($events8 | Where-Object { $_.file -like '*-logo.png' -and $_.original -notlike '*-logo.png' -and $_.original -like '*.png' }).Count -eq 3) 'Every shot must show its -logo copy and keep the plain original.'
foreach ($name in 'anh-1-1-1-as-photo', 'anh-2-1-1-front', 'anh-2-1-2-detail') {
    Assert ((Test-ImageFile (Join-Path $product8.FullName "$name.png")) -and (Test-ImageFile (Join-Path $product8.FullName "$name-logo.png"))) "$name needs both the plain image and its -logo copy."
}
$calls8 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($calls8[1].Images[0] -eq $colorPhoto -and $calls8[1].Images[1] -eq $scenePhoto -and $calls8[2].Images[1] -eq $scenePhoto) 'Shots are made from the real photos, never from a marked or generated picture.'
Assert (@($script:Events | Where-Object kind -eq 'warning').Count -eq 0) 'A brand with a logo needs no warning.'

# 9. A brand with no logo: the plain images are kept and one warning says why.
Reset-Run
$job = New-TestJob 1 2
$job | Add-Member -NotePropertyName watermark -NotePropertyValue $true -Force
$job.products[0].brand = 'Acme'
$job.platforms = @('tiktok')
$code = Invoke-ContentRun $job (Join-Path $temp 'out9')
$events9 = @($script:Events | Where-Object kind -eq 'image')
Assert ($code -eq 0 -and $events9.Count -eq 2 -and @($events9 | Where-Object { $_.file -like '*-logo.png' }).Count -eq 0 -and @($script:Events | Where-Object kind -eq 'warning').Count -eq 1 -and ($script:Events | Where-Object kind -eq 'warning').message -match 'chưa có logo') 'Without a brand logo the plain images are kept, with a single warning.'
# 10. Results go to Drive with the folders of the machine; a failing file is reported and the rest still go; no login means a warning.
Reset-Run
$script:DriveSent = @()
$job = New-TestJob 2 1
$job.platforms = @('tiktok')
$code = Invoke-ContentRun $job (Join-Path $temp 'out10')
$run10 = (Get-ChildItem (Join-Path $temp 'out10') -Directory)[0].Name
$paths10 = @($script:DriveSent | ForEach-Object Path)
Assert ($code -eq 0 -and @($script:DriveSent | Where-Object Tool -ne 'Content MXH').Count -eq 0) 'Everything goes under the Content MXH tool folder on Drive.'
Assert (@($paths10 | Where-Object { $_ -match "^$run10/0[12]-[a-z0-9-]+/(anh-.*.png|bai-tiktok.txt|snapshot.json)$" }).Count -eq $paths10.Count - 1 -and $paths10 -contains "$run10/results.json") 'Pictures, posts and the snapshot keep the run/product folders; results.json sits in the run folder.'
Assert (@($paths10 | Where-Object { $_ -match '/logs/' }).Count -eq 0) 'Logs stay on the machine.'
Reset-Run
$script:DriveSent = @(); $script:DriveFail = '*snapshot.json'
$code = Invoke-ContentRun (New-TestJob 1 1) (Join-Path $temp 'out10b')
$done10 = $script:Events | Where-Object kind -eq 'product-done' | Select-Object -First 1
Assert ($code -eq 0 -and $done10.ok -and (@($done10.errors) -join ' ') -match 'Drive: 1 file' -and @($script:DriveSent | Where-Object Path -like '*.png').Count -ge 1) 'A file Drive refuses is reported and the other files are still sent.'
Reset-Run
$script:DriveFail = ''; $script:FakeDrive = $null; $script:DriveSent = @()
$code = Invoke-ContentRun (New-TestJob 1 1) (Join-Path $temp 'out10c')
Assert ($code -eq 0 -and $script:DriveSent.Count -eq 0 -and (($script:Events | Where-Object kind -eq 'warning').message -match 'Google Drive')) 'Without a Drive login nothing is sent and one warning says so.'
# 11. Drive refuses (403: the Worker has no results route yet): said once in words, the rest of the run does not try again.
Reset-Run
$script:DriveSent = @(); $script:DriveFail = ''; $script:FakeDrive = @{ ApiUrl = 'https://drive.test'; AdminKey = 'k' }
$script:DriveRefuse = $true
function Send-DriveToolFile($Drive, [string]$Tool, [string]$RelativePath, [string]$File) {
    if ($script:DriveRefuse) { $script:DriveTries++; throw 'HTTP 403 The remote server returned an error: (403) Forbidden.' }
    if ($script:DriveFail -and $RelativePath -like $script:DriveFail) { throw 'HTTP 500 simulated' }
    $script:DriveSent += [pscustomobject]@{ Tool = $Tool; Path = $RelativePath; Bytes = (Get-Item -LiteralPath $File).Length }
}
$script:DriveTries = 0
$code = Invoke-ContentRun (New-TestJob 2 1) (Join-Path $temp 'out11')
$done11 = @($script:Events | Where-Object kind -eq 'product-done')
Assert ($code -eq 0 -and $script:DriveTries -eq 1) 'After Drive refuses, no further file is sent in this run.'
Assert ($done11.Count -eq 2 -and $done11[0].ok -and (@($done11[0].errors) -join ' ') -match 'máy chủ Drive chưa được cập nhật' -and (@($done11[1].errors) -join ' ') -notmatch 'Drive') 'The refusal is explained once, on the first product only, and the products stay successful.'
$script:DriveRefuse = $false
# 12. The old item of the scene is named in every shot of the scene (default mode); in the clean mode it is first taken out of the real
# scene photo once, and the angles then start from that clean copy and the product photo; a room without such an item is left alone.
Reset-Run
$code = Invoke-ContentRun (New-SceneJob) (Join-Path $temp 'out12')
$calls12 = @($script:Calls | Where-Object Kind -eq 'image')
$sceneReads = @($script:Calls | Where-Object { $_.Kind -eq 'text' -and $_.Prompt -match '"old_items"' })
Assert ($code -eq 0 -and $calls12.Count -eq 3 -and $sceneReads.Count -eq 1 -and $sceneReads[0].Images[0] -eq $scenePhoto) 'The scene photo is read once to name its old item.'
foreach ($i in 1, 2) { Assert ($calls12[$i].Images[1] -eq $scenePhoto -and $calls12[$i].Prompt -match 'In image 2 the old item is: A kidney-shaped dark wood table' -and $calls12[$i].Prompt -match 'Delete exactly that item') "Shot $i must name the old item and still use the real scene photo." }
Reset-Run; $script:Behavior = @{ NoOldItems = $true }
$code = Invoke-ContentRun (New-SceneJob) (Join-Path $temp 'out12b')
Assert ($code -eq 0 -and @($script:Calls | Where-Object { $_.Kind -eq 'image' -and $_.Prompt -match 'the old item is:' }).Count -eq 0) 'A room with no item of the product''s kind adds no named item.'
Reset-Run
$job = New-SceneJob
$job | Add-Member -NotePropertyName sceneMode -NotePropertyValue 'clean' -Force
$code = Invoke-ContentRun $job (Join-Path $temp 'out12c')
$run12 = @(Get-ChildItem (Join-Path $temp 'out12c') -Directory)[0]; $product12 = @(Get-ChildItem $run12.FullName -Directory)[0]
$calls12 = @($script:Calls | Where-Object Kind -eq 'image')
$cleanFile = Join-Path $product12.FullName 'logs/canh-1-sach.png'
Assert ($code -eq 0 -and $calls12.Count -eq 4 -and $calls12[1].Images.Count -eq 1 -and $calls12[1].Images[0] -eq $scenePhoto -and $calls12[1].Prompt -match 'Remove completely: A kidney-shaped dark wood table' -and (Test-ImageFile $cleanFile)) 'The clean mode first removes the old item from the real scene photo, once.'
foreach ($i in 2, 3) { Assert ($calls12[$i].Images[0] -eq $colorPhoto -and $calls12[$i].Images[1] -eq $cleanFile -and $calls12[$i].Prompt -notmatch 'the old item is:') "Shot $i of the clean mode starts from the product photo and the clean copy of the scene." }
Reset-Run
# 13. The fresh mode: a short photo brief written for this tool (no Product Review rule list), product as image 1, setting as image 2.
Reset-Run
$job = New-SceneJob
$job | Add-Member -NotePropertyName sceneMode -NotePropertyValue 'fresh' -Force
$code = Invoke-ContentRun $job (Join-Path $temp 'out13')
$calls13 = @($script:Calls | Where-Object Kind -eq 'image')
foreach ($i in 1, 2) { Assert ($calls13[$i].Images[0] -eq $colorPhoto -and $calls13[$i].Images[1] -eq $scenePhoto -and $calls13[$i].Prompt -match 'THE PRODUCT \(reference image 1\)' -and $calls13[$i].Prompt -match 'THE SETTING \(reference image 2\)' -and $calls13[$i].Prompt -match 'THE SHOT' -and $calls13[$i].Prompt -match 'forked root legs' -and $calls13[$i].Prompt -match 'kidney-shaped dark wood table' -and $calls13[$i].Prompt -notmatch 'CORE PRODUCT RULES|BASE PHOTO|IMMUTABLE') "Fresh shot $i must be the short brief with the product as image 1 and the setting as image 2." }
Assert ($code -eq 0 -and $calls13.Count -eq 3) 'The fresh mode makes the same shots.'
Reset-Run
# 14. The default: the scene's own table is taken out first, checked until the room is empty, and every picture is checked against
# the product photo and made again once when it is not the same product.
Reset-Run
$job = New-SceneJob
$job.sceneMode = 'clean'; $job.verify = 'true'
$code = Invoke-ContentRun $job (Join-Path $temp 'out14')
$calls14 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($code -eq 0 -and $calls14.Count -eq 4 -and $script:RoomChecks -eq 1 -and $script:ShotChecks -eq 3) 'A room that is empty at once is made once and checked once; every shot of the run is checked once.'
Assert (@($script:Events | Where-Object kind -eq 'warning').Count -eq 0) 'Nothing to warn about when every check passes.'
# the room still has the table after the first two tries: made three times, the third one is accepted when it is empty
Reset-Run; $script:Behavior = @{ RoomHasItemTimes = 2 }
$code = Invoke-ContentRun $job (Join-Path $temp 'out14b')
$calls14 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($code -eq 0 -and @($calls14 | Where-Object { $_.Prompt -match 'Remove ALL tables' }).Count -eq 1 -and @($calls14 | Where-Object { $_.Prompt -match 'Make the middle of the room EMPTY' }).Count -eq 1 -and $script:RoomChecks -eq 3) 'A room that still has the table is cleaned again, asking harder each time.'
# the room never gets empty: the real photo is used and one warning says why
Reset-Run; $script:Behavior = @{ RoomHasItemTimes = 9 }
$code = Invoke-ContentRun $job (Join-Path $temp 'out14c')
$calls14 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($code -eq 0 -and $calls14[-1].Images[1] -eq $scenePhoto -and (($script:Events | Where-Object kind -eq 'warning').message -join ' ') -match 'Chưa dọn được bàn cũ') 'A room that cannot be emptied falls back to the real photo with a warning.'
# a shot that is not the product is made again once, told why; a second mismatch is reported but kept
Reset-Run; $script:Behavior = @{ MismatchTimes = 1 }
$code = Invoke-ContentRun $job (Join-Path $temp 'out14d')
$calls14 = @($script:Calls | Where-Object Kind -eq 'image')
Assert ($code -eq 0 -and $calls14.Count -eq 5 -and $calls14[1].Prompt -match 'The previous attempt was rejected: the base is a ring, not a twisted ribbon' -and @($script:Events | Where-Object kind -eq 'warning').Count -eq 0) 'A shot that is not the product is made again once with the reason, and a good second try needs no warning.'
Reset-Run; $script:Behavior = @{ MismatchTimes = 99 }
$code = Invoke-ContentRun $job (Join-Path $temp 'out14e')
Assert ($code -eq 0 -and @($script:Events | Where-Object { $_.kind -eq 'warning' -and $_.message -match 'chưa đúng sản phẩm gốc' }).Count -ge 1 -and @($script:Events | Where-Object { $_.kind -eq 'image' -and $_.ok }).Count -eq 3) 'A shot that stays wrong is kept and reported, never dropped.'
Reset-Run
Write-Host 'PASS: angles per photo, scenes with a base shot, watermark copies, posts per platform, repair, retry, quota stop and policy refusal.' -ForegroundColor Green
