# Queue locking, runspace lifecycle and batch coordination.
# One job per product image + review image pair (a run starts only when every product image has its review images).
# A link with a single pair keeps its plain item.
function Expand-SceneJobs($Items) {
    foreach ($item in $Items) {
        $entry = @($script:Config.ManualReferences.entries | Where-Object product_url -eq $item.Url)
        $products = @(if ($entry.Count) { Get-ManualProducts $entry[0] })
        $jobs = @(foreach ($product in $products) {
                $scenes = @($product.scenes)
                if (-not $scenes.Count) { [pscustomobject]@{ Url = $item.Url; Handle = $item.Handle; Product = $product } }
                foreach ($scene in $scenes) { [pscustomobject]@{ Url = $item.Url; Handle = $item.Handle; Product = $product; Scene = $scene } }
            })
        if ($products.Count -le 1 -and $jobs.Count -le 1) { $item; continue }
        $jobs
    }
}

function Invoke-BatchWorkflow([string]$ProjectRoot, [string]$List, [string]$OutDir, [int]$ThrottleLimit, [string[]]$ModuleFiles) {
    $script:Batch = @{}
    # Workers get independent objects; context enrichment must not mutate shared samples.
    $configSnapshot = [Management.Automation.PSSerializer]::Serialize($script:Config, 20)
    # Worker body, run in its own runspace: load the libraries, then build one product image.
    $workerScript = {
        param($ModuleFiles, $ConfigSnapshot, $Batch, $Item, $ItemId)
        $ErrorActionPreference = 'Stop'
        foreach ($moduleFile in $ModuleFiles) { . $moduleFile }
        $script:Config = [Management.Automation.PSSerializer]::Deserialize($ConfigSnapshot)
        $script:Batch = $Batch
        $rows = @(Invoke-ProductItem $Item $ItemId)
        # Upload right after this image is done, in parallel with other threads.
        # A failed upload leaves photo_url empty; the coordinator then retries it.
        $row = @($rows | Where-Object { $_ -and $_.PSObject.Properties['photo_path'] })[-1]
        if ($row -and $script:Config.Drive -and $row.photo_url -notmatch '^https://') {
            try { $row = Complete-DriveDelivery $row }
            catch { Write-Warning "Upload Drive sẽ thử lại sau: $($_.Exception.Message)" }
        }
        $rows
    }

    # Lock the queue for the whole run. Finished URLs are checkpointed after every item.
    if (-not (Test-Path -LiteralPath $List)) { throw "URL list not found: $List" }
    $queueLock = [IO.File]::Open("$List.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $pool = $null
    try {
        $queue = Read-UrlQueue $List
        if (-not @($queue.Items).Count) { Write-Host "No product URLs to process. Add one URL per line to $List"; return }
        # One job per attached scene image, so a link with several images yields several results.
        $urls = @(Expand-SceneJobs @($queue.Items))
        $jobsPerUrl = @{}
        foreach ($item in $urls) { $jobsPerUrl[$item.Url] = 1 + [int]$jobsPerUrl[$item.Url] }

        $started = Get-Date
        $script:Batch = New-Batch $OutDir
        Write-Lines $script:Batch.InputUrls $queue.Lines
        $completed = New-Object System.Collections.Generic.List[string]
        $results = New-Object System.Collections.Generic.List[object]
        Save-BatchResults $results.ToArray() $script:Batch.Dir
        $threads = [Math]::Min($ThrottleLimit, $urls.Count)
        Write-Host "Starting: $($urls.Count) URLs" -ForegroundColor Cyan
        $rows = @(); $rowOf = @{}
        foreach ($item in $urls) { if (-not $rowOf.ContainsKey($item.Url)) { $rowOf[$item.Url] = $rowOf.Count + 1 }; $rows += $rowOf[$item.Url] }
        Write-Host "Rows: $($rows -join ',')" -ForegroundColor DarkGray
        Write-Host "Batch: $($script:Batch.Dir)" -ForegroundColor DarkGray
        Write-Host "Threads: $threads" -ForegroundColor DarkGray

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $threads)
        $pool.Open()
        $jobs = New-Object System.Collections.Generic.List[object]
        $index = 0
        foreach ($item in $urls) {
            $index++
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($workerScript).AddArgument($ModuleFiles).AddArgument($configSnapshot).AddArgument($script:Batch).AddArgument($item).AddArgument(('{0:D3}-{1}' -f $index, $item.Handle))
            $jobs.Add([pscustomobject]@{ Index = $index; Item = $item; PS = $ps; Async = $ps.BeginInvoke(); Seen = 0; SeenWarnings = 0; Announced = $false; Done = $false })
        }

        # Stream worker output as it arrives; commit each finished item in the main thread.
        # With several threads, every line is tagged (#n) so interleaved lines stay attributable.
        $tag = { param($job) if ($threads -gt 1) { "  (#$($job.Index))" } else { '' } }
        $pending = $jobs.Count
        while ($pending -gt 0) {
            foreach ($job in $jobs) {
                if ($job.Done) { continue }
                $info = $job.PS.Streams.Information
                while ($job.Seen -lt $info.Count) {
                    if (-not $job.Announced) {
                        Write-Host "`n[$($job.Index)/$($urls.Count)] $($job.Item.Handle)" -ForegroundColor Cyan
                        $job.Announced = $true
                    }
                    Write-Host ("$($info[$job.Seen].MessageData)" + (& $tag $job))
                    $job.Seen++
                }
                while($job.SeenWarnings -lt $job.PS.Streams.Warning.Count){
                    Write-Warning ("[ITEM $($job.Index)] "+$job.PS.Streams.Warning[$job.SeenWarnings].Message+(& $tag $job))
                    $job.SeenWarnings++
                }
                if (-not $job.Async.IsCompleted) { continue }
                $job.Done = $true; $pending--
                if (-not $job.Announced) { Write-Host "`n[$($job.Index)/$($urls.Count)] $($job.Item.Handle)" -ForegroundColor Cyan }
                try {
                    $result = @($job.PS.EndInvoke($job.Async) | Where-Object { $_ -and $_.PSObject.Properties['photo_path'] })[-1]
                    if (-not $result) { throw 'Worker returned no result.' }
                    $result=Complete-DriveDelivery $result $job.Index
                } catch {
                    $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
                $errorLog = Join-Path $script:Batch.Logs ('{0:D3}-{1}-error.txt' -f $job.Index, $job.Item.Handle)
                # The unwrapped message first: PowerShell 7 wraps Out-String error text mid-sentence.
                @($inner; $_ | Out-String; $_.ScriptStackTrace; $job.PS.Streams.Error | Format-List * -Force | Out-String) |
                    Set-Content -LiteralPath $errorLog -Encoding UTF8
                $causeTag = if ($inner -match '\[CAUSE:(DRIVE_CONFIG|DRIVE_AUTH|DRIVE_UPLOAD|BRIDGE|AUTH|QUOTA|NETWORK|AI_TIMEOUT|BUSY|PROCESS_ACTIVE|STORE_LOCKED|PRODUCT_TIMEOUT|PRODUCT_NETWORK|PRODUCT_ACCESS|PRODUCT_NOT_FOUND|PRODUCT_DOWNLOAD|OUTPUT_MISSING|OUTPUT_INVALID|TOOL_ERROR)\]') { $Matches[0] + ' ' } else { '' }
                # Warning formatting wraps long records, losing reset details in the UI's
                # line reader. Emit the same WARNING prefix as one unwrapped log line.
                Write-Host "WARNING: [ITEM $($job.Index)] Failed; ${causeTag}URL and source kept for retry. $inner" -ForegroundColor Yellow
                    continue
                } finally { $job.PS.Dispose() }

                # Commit outside the per-item catch: stop on storage errors to avoid consuming more input.
                # A link leaves the queue only after every one of its images succeeded.
                $jobsPerUrl[$job.Item.Url]--
                Save-ProductCheckpoint $results $result $completed $job.Item $List ($jobsPerUrl[$job.Item.Url] -le 0)
                Write-Host "  [OK] [ITEM $($job.Index)] $($result.photo_path -replace '/', '\')$(& $tag $job)" -ForegroundColor Green
            }
            if ($pending -gt 0) { Start-Sleep -Milliseconds 400 }
        }
        Complete-BatchExport $results (Join-Path $ProjectRoot 'data/names.txt')
        Write-Host "`nDone: $($results.Count)/$($urls.Count) exported in $([int]((Get-Date) - $started).TotalSeconds)s" -ForegroundColor Green
        Write-Host "Results: $($script:Batch.Dir)"
        Write-Host "Pending: $List" -ForegroundColor DarkGray
        if ($results.Count -lt $urls.Count) {
            throw "Batch incomplete: $($urls.Count - $results.Count) URL(s) failed and remain queued. See $($script:Batch.Logs)"
        }
    } finally {
        if ($pool) { $pool.Close(); $pool.Dispose() }
        $queueLock.Dispose()
    }

}
