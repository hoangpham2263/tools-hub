# What a post may contain and how it is laid out for each platform: no AI is called.
. (Join-Path $PSScriptRoot 'helpers.ps1')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/bootstrap.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$words = { param($n) (@(1..$n | ForEach-Object { 'chu' }) -join ' ') + '.' }
$grenheim = Get-BrandPack 'GRENHEIM'
$link = 'https://shop.test/p/1'
$tags = @('#BanTraGo', '#GRENHEIM', '#NoiThatGo', '#KhongGianSong')
$fb = Get-PostPlatform 'facebook'; $ig = Get-PostPlatform 'instagram'; $th = Get-PostPlatform 'threads'; $tt = Get-PostPlatform 'tiktok'

# Layout: fences and quotes go, links stay only where they work, hashtags are capped, the AI's own come first.
$raw = "``````text`n`"Buoi toi, ngoi xuong.`n`nMot ngay nua.`n`n#Rieng #BanTraGo`"`n``````"
$facebook = Format-PostText $raw $fb $link $tags
Assert ($facebook -notmatch '```|"' -and $facebook -match '(?s)^Buoi toi.*Mot ngay nua\.\n\n' + [regex]::Escape($link) + '\n\n#Rieng #BanTraGo #GRENHEIM #NoiThatGo #KhongGianSong$') 'Facebook: body, then the link on its own line, then at most 5 hashtags with the AI''s first.'
$instagram = Format-PostText "Mot cau.`nXem tai $link nhe.`n#a" $ig $link $tags
Assert ($instagram -notmatch 'http' -and $instagram -match '#a #BanTraGo') 'Instagram: no link in the caption, hashtags kept.'
$threads = Format-PostText 'Mot y nghi.' $th $link $tags
Assert ($threads -match "Mot y nghi\.\n\n$([regex]::Escape($link))\n\n#BanTraGo$" -and ([regex]::Matches($threads, '#')).Count -eq 1) 'Threads: the link, and one hashtag at most.'
$tiktok = Format-PostText "Dong mot dong hai." $tt $link $tags
Assert ($tiktok -notmatch "`n" -and $tiktok -notmatch 'http' -and $tiktok.EndsWith('#BanTraGo #GRENHEIM #NoiThatGo #KhongGianSong')) 'TikTok: one line, no link.'
Assert ((Format-PostText 'Chi co chu.' $fb '' @()) -eq 'Chi co chu.') 'No link and no tags must add nothing.'
# A hashtag the AI wrote before the link must not come back a second time.
$before = Format-PostText "Mot y nghi.`n#BanTraGo`n`n$link" $th $link $tags
Assert (([regex]::Matches($before, '#BanTraGo')).Count -eq 1 -and ([regex]::Matches($before, [regex]::Escape($link))).Count -eq 1 -and $before.EndsWith('#BanTraGo')) 'A hashtag before the link was duplicated.'

Assert ((Format-PostText 'a' $fb $link @('BanTraGo')) -match '#BanTraGo$') 'A tag given without # gets one.'

# Checks on a draft.
Assert (-not (Get-PostIssue (& $words 90) $fb $grenheim)) 'A plain post of the right length must pass.'
foreach ($case in @(
    @{ n = 'exclamation'; t = ((& $words 90) + ' Dep qua!') },
    @{ n = 'dash'; t = ((& $words 90) + ' Mot - hai') -replace ' - ', ([string][char]0x2014) },
    @{ n = 'emoji'; t = ((& $words 90) + ' ' + [char]::ConvertFromUtf32(0x1F60A)) },
    @{ n = 'polished'; t = ((& $words 90) + ' It is stunning.') },
    @{ n = 'machine'; t = ((& $words 90) + ' It is not just a table but a place.') },
    @{ n = 'summing up'; t = ((& $words 90) + ' Overall a good table.') },
    @{ n = 'too short'; t = (& $words 10) },
    @{ n = 'too long'; t = (& $words 400) },
    @{ n = 'empty'; t = ' ' })) { Assert ([bool](Get-PostIssue $case.t $fb $grenheim)) "A $($case.n) post passed." }
Assert ([bool](Get-PostIssue ((& $words 30) + (' ' * 1) + ('x' * 600)) $th $null)) 'A Threads post over 500 characters must be flagged.'
# The brand's own tagline has a dash and is not the AI's mistake.
Assert (-not (Get-PostIssue ((& $words 90) + "`n`n" + $grenheim.tagline) $fb $grenheim)) 'The brand tagline must not count as a dash.'
Assert ((Get-PostWordCount "chu chu #tag https://x.test/y $($grenheim.tagline)" $grenheim) -eq 2) 'Hashtags, links and the tagline are not words.'
Write-Host 'PASS: layout per platform, link and hashtag rules, wording and length checks.' -ForegroundColor Green
