function New-WorkflowConfiguration([string]$ProjectRoot, [string]$SourceDir, [string]$Model) {
    $workspace = Initialize-ProjectWorkspace $ProjectRoot
    $contexts = @(Get-ProductContexts (Join-Path $ProjectRoot 'data/product-contexts.json'))
    $catalog = Get-SourceCatalog $SourceDir
    return @{
        SourceDir = $SourceDir; Model = $Model
        ReviewSamples = @(Get-ReviewSamples (Join-Path $ProjectRoot 'data/review-samples.jsonl'))
        ProductContexts = $contexts
        SourceCatalog = $catalog
        AgentInstructionsPath = Join-Path $ProjectRoot 'AGENTS.md'
        FeedbackRoot = Join-Path $workspace.Root 'feedback'
        Drive = Get-DriveConfig $workspace.Root
        DeliveryRoot = Join-Path $workspace.Root 'delivery-pending'
        WritingStyle = Get-WritingStyle (Join-Path $ProjectRoot 'data/writing-style.json')
    }
}
