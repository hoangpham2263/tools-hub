# The camera angles one product photo can be shot from: the library in hub/image/angles.json, shared with Grok Video (the 24 presets of GRENHEIM's
# camera-angle library, plus "as photo"). A shot is asked for by its id, in the order the user picked them.

function Get-ContentAngleLibrary { Read-JsonFile (Join-Path (Get-ToolRoot) '../../hub/image/angles.json') }

# The angles for these ids, in this order. An unknown id, a repeat or an empty list stops the job.
function Get-ContentAngles([string[]]$Ids) {
    $library = @((Get-ContentAngleLibrary).angles)
    $Ids = @($Ids | Where-Object { $_ })
    if (-not $Ids.Count) { throw 'Choose at least one camera angle.' }
    if ($Ids.Count -gt $library.Count) { throw "At most $($library.Count) angles per photo, not $($Ids.Count)." }
    if (@($Ids | Select-Object -Unique).Count -ne $Ids.Count) { throw 'Each camera angle can be chosen once per photo.' }
    @($Ids | ForEach-Object {
        $id = $_
        $angle = $library | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $angle) { throw "Unknown camera angle: $id." }
        $angle
    })
}
