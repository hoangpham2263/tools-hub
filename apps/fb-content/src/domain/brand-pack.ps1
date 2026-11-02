# A brand's voice and facts live in data/brands/<id>/brand.json, never in code: the engine is the same for every brand.
# The brand is found by the name typed in Thương hiệu (folder id, name or alias, ignoring case, spaces and Vietnamese
# marks). A name with no pack gets a plain generic one, so the tool still runs.

function ConvertTo-BrandKey([string]$Text) {
    (($Text.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace 'đ', 'd' -replace 'Đ', 'D' -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Get-BrandPack([string]$Name) {
    $key = ConvertTo-BrandKey $Name
    $dir = Join-Path (Get-ToolRoot) 'data/brands'
    if ($key -and (Test-Path -LiteralPath $dir)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter brand.json -Recurse -File)) {
            $pack = Read-JsonFile $file.FullName
            Add-Member -InputObject $pack -NotePropertyName dir -NotePropertyValue (Split-Path $file.FullName -Parent) -Force
            $names = @($pack.id, $pack.name) + @($pack.aliases)
            if (@($names | Where-Object { $_ -and (ConvertTo-BrandKey ([string]$_)) -eq $key }).Count) { return $pack }
        }
    }
    [pscustomobject]@{
        id = 'generic'; name = $Name; language = 'Vietnamese'; about = ''; tagline = ''
        voice = @('Warm, plain and natural. Place the product in a lived moment instead of listing its features.')
        facts = @(); avoid = @(); hashtags = @(); example = ''
    }
}

# The brand part of a post prompt: who the brand is, how it speaks, what it must never claim.
function Get-BrandPromptBlock($Pack) {
    $lines = @()
    if ($Pack.name) { $lines += "Brand: $($Pack.name). Write the post in $($Pack.language)." }
    if ($Pack.about) { $lines += "About the brand: $($Pack.about)" }
    if ($Pack.tagline) { $lines += "Tagline: $($Pack.tagline)" }
    if (@($Pack.voice).Count) { $lines += 'Voice:'; $lines += @($Pack.voice | ForEach-Object { "- $_" }) }
    if (@($Pack.facts).Count) { $lines += 'Facts to respect:'; $lines += @($Pack.facts | ForEach-Object { "- $_" }) }
    if (@($Pack.avoid).Count) { $lines += 'Avoid:'; $lines += @($Pack.avoid | ForEach-Object { "- $_" }) }
    if ($Pack.example) { $lines += "An approved post, for tone and rhythm only (never copy its wording, opening or structure): $(ConvertTo-Json -InputObject ([string]$Pack.example) -Compress)" }
    $lines -join [Environment]::NewLine
}
