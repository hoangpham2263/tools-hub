# Ordered module manifest, as Product Review's: the hub's AI core and image rules first, then this tool.
$script:WorkflowModuleFiles = @(
    '../../../hub/ai/ai.ps1'
    '../../../hub/image/product-rules.ps1'
    '../../../hub/image/product-details.ps1'
    '../../../hub/image/watermark.ps1'
    '../../../hub/image/unsparkle.ps1'
    'infrastructure/workspace.ps1'
    'infrastructure/ai.ps1'
    'infrastructure/watermark.ps1'
    'infrastructure/drive.ps1'
    'domain/angles.ps1'
    'domain/brand-pack.ps1'
    'domain/post-rules.ps1'
    'workflow/prepare-product.ps1'
    'workflow/verify-images.ps1'
    'workflow/create-images.ps1'
    'workflow/write-posts.ps1'
    'workflow/run-job.ps1'
) | ForEach-Object { Join-Path $PSScriptRoot $_ }
foreach ($moduleFile in $script:WorkflowModuleFiles) { . $moduleFile }
