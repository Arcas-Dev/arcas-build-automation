$ErrorActionPreference = "Stop"
$tag = Get-Date -Format "yyyy-MM-dd_HH-mm"
Write-Host "Submitting Cloud Build with tag: $tag"
Write-Host "This uploads ~1.5 GB and builds the Docker image..."

gcloud builds submit "C:\A\Builds\LinuxServer\" `
  --config="C:\A\Builds\LinuxServer\cloudbuild.yaml" `
  --substitutions="_TAG=$tag" `
  --project=arcas-champions `
  --region=europe-west6

if ($LASTEXITCODE -eq 0) {
    Write-Host "SUCCESS: Image pushed as registry.edgegap.com/arcas-champions-n3tkvcfhbvhf/arcastest6:$tag"
    "CLOUD_BUILD_SUCCESS:$tag" | Out-File -FilePath "C:\A\status.txt" -Encoding ascii
} else {
    Write-Host "FAILED: Cloud Build returned exit code $LASTEXITCODE"
    "CLOUD_BUILD_FAILED" | Out-File -FilePath "C:\A\status.txt" -Encoding ascii
}
