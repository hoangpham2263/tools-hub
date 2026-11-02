# Test fixtures live in the tool's own workspace/tests (Git ignores it). New-TestPng is Product Review's helper: a real PNG without an imaging library.
$TestWorkspaceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'workspace/tests'
New-Item -ItemType Directory -Force -Path $TestWorkspaceRoot | Out-Null

# Write a real solid-colour PNG without an imaging library, so suites run on Windows and macOS.
function New-TestPng([string]$Path, [int]$Width = 2, [int]$Height = 2, [byte[]]$Rgb = @(128, 128, 128)) {
    [long]$mask = 4294967295
    $table = [long[]]::new(256)
    for ($n = 0; $n -lt 256; $n++) { [long]$c = $n; for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = 3988292384 -bxor ($c -shr 1) } else { $c = $c -shr 1 } }; $table[$n] = $c }
    $crc = { param([byte[]]$data) [long]$c = $mask; foreach ($b in $data) { $c = $table[($c -bxor $b) -band 255] -bxor ($c -shr 8) }; $c -bxor $mask }
    $be = { param([long]$v) [byte[]]@((($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)) }
    $chunk = { param([string]$type, [byte[]]$data) [byte[]]$body = [Text.Encoding]::ASCII.GetBytes($type) + $data; [byte[]]((& $be $data.Length) + $body + (& $be (& $crc $body))) }
    $raw = New-Object IO.MemoryStream
    for ($y = 0; $y -lt $Height; $y++) { $raw.WriteByte(0); for ($x = 0; $x -lt $Width; $x++) { $raw.Write($Rgb, 0, 3) } }
    $rawBytes = $raw.ToArray()
    $deflated = New-Object IO.MemoryStream
    $deflate = New-Object IO.Compression.DeflateStream($deflated, [IO.Compression.CompressionMode]::Compress, $true)
    $deflate.Write($rawBytes, 0, $rawBytes.Length); $deflate.Dispose()
    [long]$a = 1; [long]$b = 0; foreach ($byte in $rawBytes) { $a = ($a + $byte) % 65521; $b = ($b + $a) % 65521 }
    [byte[]]$zlib = [byte[]]@(120, 156) + $deflated.ToArray() + (& $be (($b -shl 16) -bor $a))
    [byte[]]$ihdr = (& $be $Width) + (& $be $Height) + [byte[]]@(8, 2, 0, 0, 0)
    [byte[]]$png = [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10) + (& $chunk 'IHDR' $ihdr) + (& $chunk 'IDAT' $zlib) + (& $chunk 'IEND' ([byte[]]@()))
    [IO.File]::WriteAllBytes($Path, $png)
}
