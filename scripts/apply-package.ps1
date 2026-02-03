Param(
  [Parameter(Mandatory=$true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory=$true)]
  [string]$FunctionAppName,

  [Parameter(Mandatory=$true)]
  [string]$PackageUrl,

  [Parameter(Mandatory=$false)]
  [string]$HealthUrl = "",

  # Default: vi sætter Classic settings.
  # Brug -SkipClassicSettings hvis du IKKE vil sætte dem.
  [Parameter(Mandatory=$false)]
  [switch]$SkipClassicSettings
)

$ErrorActionPreference = "Stop"

function Fail($msg) {
  Write-Host "❌ $msg" -ForegroundColor Red
  throw $msg
}

Write-Host "== Apply Run-From-Package (Classic) ==" -ForegroundColor Cyan
Write-Host "RG:        $ResourceGroup"
Write-Host "Function:  $FunctionAppName"
Write-Host "PackageUrl: (hidden)"
Write-Host ""

# IMPORTANT (Windows PowerShell + az):
# az kan gå via cmd.exe hvor '&' splitter kommandoer.
# Escape '&' til '^&' så URL behandles som én streng.
$pkgForAz = $PackageUrl -replace '&', '^&'
$settingRunFromPkg = "WEBSITE_RUN_FROM_PACKAGE=$pkgForAz"

if (-not $SkipClassicSettings) {
  Write-Host "Ensuring Classic required app settings..." -ForegroundColor Yellow

  az functionapp config appsettings set `
    -g $ResourceGroup -n $FunctionAppName `
    --settings `
      "FUNCTIONS_WORKER_RUNTIME=dotnet-isolated" `
      "FUNCTIONS_EXTENSION_VERSION=~4" `
      "AzureWebJobsFeatureFlags=EnableWorkerIndexing" `
    --output none
} else {
  Write-Host "Skipping Classic settings (per -SkipClassicSettings)" -ForegroundColor DarkYellow
}

Write-Host "Setting WEBSITE_RUN_FROM_PACKAGE..." -ForegroundColor Yellow
az functionapp config appsettings set `
  -g $ResourceGroup -n $FunctionAppName `
  --settings "$settingRunFromPkg" `
  --output none

Write-Host "Restarting Function App..." -ForegroundColor Yellow
az functionapp restart -g $ResourceGroup -n $FunctionAppName | Out-Null

Write-Host "Verifying WEBSITE_RUN_FROM_PACKAGE..." -ForegroundColor Yellow
$w = az functionapp config appsettings list `
  -g $ResourceGroup -n $FunctionAppName `
  --query "[?name=='WEBSITE_RUN_FROM_PACKAGE'].value | [0]" -o tsv

if ([string]::IsNullOrWhiteSpace($w)) { Fail "WEBSITE_RUN_FROM_PACKAGE not set (empty)." }
Write-Host "WEBSITE_RUN_FROM_PACKAGE = $w"

Write-Host ""
Write-Host "Listing functions (kan tage 10-60 sek efter restart)..." -ForegroundColor Yellow
try {
  az functionapp function list -g $ResourceGroup -n $FunctionAppName -o table
} catch {
  Write-Host "Function list fejlede (ofte transient lige efter restart). Prøv igen om 30 sek." -ForegroundColor DarkYellow
}

if (![string]::IsNullOrWhiteSpace($HealthUrl)) {
  Write-Host ""
  Write-Host "Health check: $HealthUrl" -ForegroundColor Yellow
  $r = Invoke-RestMethod -Uri $HealthUrl -Method Get
  $r | ConvertTo-Json -Depth 10
  Write-Host "✅ Health OK" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
