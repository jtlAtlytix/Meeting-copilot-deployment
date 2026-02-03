Param(
  [Parameter(Mandatory=$true)][string]$AppDisplayName,
  [Parameter(Mandatory=$true)][string]$WebRedirectUri, # fx https://<app>.azurewebsites.net/.auth/login/aad/callback
  [Parameter(Mandatory=$true)][string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\helpers.ps1"

# ------------------------------------------------------------
# Graph constants
$GraphAppId = "00000003-0000-0000-c000-000000000000"

# Desired permissions (match screenshot/list)
$GraphAppRoles = @(
  "Mail.Send",
  "OnlineMeetings.Read.All",
  "OnlineMeetingTranscript.Read.All"
)

# Delegated scopes (typisk kun User.Read)
$GraphDelegatedScopes = @(
  "User.Read"
)
# ------------------------------------------------------------

function Invoke-AzCliText {
  param(
    [Parameter(Mandatory=$true)][string[]]$AzCliArgs,
    [Parameter(Mandatory=$false)][string]$FriendlyName = "az"
  )

  Write-Info ("az " + ($AzCliArgs -join " "))

  $raw = & az @AzCliArgs 2>&1
  $txt = ($raw | Out-String).Trim()

  if ($LASTEXITCODE -ne 0) {
    Write-Fail "$FriendlyName fejlede (exit=$LASTEXITCODE). Output:`n$txt"
  }

  return $txt
}

function Get-JsonFromText {
  param([Parameter(Mandatory=$true)][string]$Text)

  # Find første JSON object/array start og returnér substring derfra
  $idxObj = $Text.IndexOf('{')
  $idxArr = $Text.IndexOf('[')

  if ($idxObj -lt 0 -and $idxArr -lt 0) { return $null }

  $start = $idxObj
  if ($idxArr -ge 0 -and ($idxObj -lt 0 -or $idxArr -lt $idxObj)) { $start = $idxArr }

  return $Text.Substring($start).Trim()
}

function Invoke-AzCliJson {
  param(
    [Parameter(Mandatory=$true)][string[]]$AzCliArgs,
    [Parameter(Mandatory=$false)][string]$FriendlyName = "az"
  )

  $cliArgs = @($AzCliArgs)

  if (-not ($cliArgs -contains "-o") -and -not ($cliArgs -contains "--output")) {
    $cliArgs += @("-o","json")
  }
  if (-not ($cliArgs -contains "--only-show-errors")) {
    $cliArgs += @("--only-show-errors")
  }

  $txt = Invoke-AzCliText -AzCliArgs $cliArgs -FriendlyName $FriendlyName

  # Azure CLI kan skrive warnings før JSON. Udtræk ren JSON-del.
  $jsonText = Get-JsonFromText -Text $txt
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    Write-Fail "$FriendlyName returnerede ikke JSON. Raw output:`n$txt"
  }

  try {
    return ($jsonText | ConvertFrom-Json)
  } catch {
    Write-Fail "$FriendlyName returnerede ikke valid JSON (kunne ikke parse). Raw output:`n$txt"
  }
}

function Get-GraphSpObject {
  return Invoke-AzCliJson -AzCliArgs @("ad","sp","show","--id",$GraphAppId) -FriendlyName "az ad sp show (Graph)"
}

function Get-GraphAppRoleId {
  param(
    [Parameter(Mandatory=$true)]$graphSp,
    [Parameter(Mandatory=$true)][string]$roleValue
  )

  $role = $graphSp.appRoles | Where-Object {
    $_.value -eq $roleValue -and ($_.allowedMemberTypes -contains "Application")
  } | Select-Object -First 1

  if (-not $role) { return $null }
  return $role.id
}

function Get-GraphScopeId {
  param(
    [Parameter(Mandatory=$true)]$graphSp,
    [Parameter(Mandatory=$true)][string]$scopeValue
  )

  $scope = $graphSp.oauth2PermissionScopes | Where-Object {
    $_.value -eq $scopeValue
  } | Select-Object -First 1

  if (-not $scope) { return $null }
  return $scope.id
}

# 1) Ensure logged in
Assert-Command -Name az
try {
  Invoke-AzCliText -AzCliArgs @("account","show","-o","none","--only-show-errors") -FriendlyName "az account show" | Out-Null
} catch {
  Write-Info "Du er ikke logget ind. Kører az login..."
  & az login | Out-Null
}

Write-Info "TenantId: $TenantId"

# 2) Create App Registration (web redirect)
Write-Info "Opretter App Registration: $AppDisplayName"
$app = Invoke-AzCliJson -AzCliArgs @(
  "ad","app","create",
  "--display-name",$AppDisplayName,
  "--web-redirect-uris",$WebRedirectUri,
  "--sign-in-audience","AzureADMyOrg"
) -FriendlyName "az ad app create"

$clientId = $app.appId
if ([string]::IsNullOrWhiteSpace($clientId)) {
  Write-Fail "Kunne ikke læse appId (clientId) fra az ad app create output."
}
Write-Ok "clientId (appId): $clientId"

# 2a) Find objectId (Graph endpoint PATCH kræver objectId)
Write-Info "Finder objectId for app..."
$appFull = Invoke-AzCliJson -AzCliArgs @("ad","app","show","--id",$clientId) -FriendlyName "az ad app show"
$objectId = $appFull.id
if ([string]::IsNullOrWhiteSpace($objectId)) {
  Write-Fail "Kunne ikke læse objectId (id) fra az ad app show output."
}
Write-Ok "objectId: $objectId"

# 2b) ✅ PERMANENT: Enable implicit grant for ID tokens (og Access tokens valgfrit)
# VIGTIGT: Body skal sendes som GYLDIG JSON-string (ConvertTo-Json), ellers får du "Unable to read JSON request payload".
$patchBodyObj = @{
  web = @{
    implicitGrantSettings = @{
      enableIdTokenIssuance     = $true
      enableAccessTokenIssuance = $true
    }
  }
}
$patchBodyJson = ($patchBodyObj | ConvertTo-Json -Depth 10 -Compress)

Write-Info "Aktiverer implicit grant (ID token + Access token) via Microsoft Graph PATCH..."
Invoke-AzCliText -AzCliArgs @(
  "rest",
  "--method","PATCH",
  "--uri","https://graph.microsoft.com/v1.0/applications/$objectId",
  "--headers","Content-Type=application/json",
  "--body",$patchBodyJson,
  "-o","none",
  "--only-show-errors"
) -FriendlyName "az rest PATCH applications (implicit grant)" | Out-Null

Write-Ok "Implicit grant er slået til (ID token + Access token)."

# 3) Create service principal (enterprise app)
Write-Info "Opretter Service Principal..."
Invoke-AzCliText -AzCliArgs @(
  "ad","sp","create","--id",$clientId,
  "-o","none","--only-show-errors"
) -FriendlyName "az ad sp create" | Out-Null

# 4) Fetch Graph SP definition for role/scope IDs
$graphSp = Get-GraphSpObject

# 5) Add Graph Application permissions (App Roles)
Write-Info "Tilføjer Graph application permissions..."
foreach ($r in $GraphAppRoles) {
  $roleId = Get-GraphAppRoleId -graphSp $graphSp -roleValue $r
  if (-not $roleId) {
    Write-Warn "Kunne ikke finde Graph appRole '$r' (springer over)."
    continue
  }

  Invoke-AzCliText -AzCliArgs @(
    "ad","app","permission","add",
    "--id",$clientId,
    "--api",$GraphAppId,
    "--api-permissions","$roleId=Role",
    "-o","none",
    "--only-show-errors"
  ) -FriendlyName "az ad app permission add (Role:$r)" | Out-Null

  Write-Ok "Tilføjet (App): $r"
}

# 6) Add Graph Delegated permissions (Scopes)
Write-Info "Tilføjer Graph delegated permissions..."
foreach ($s in $GraphDelegatedScopes) {
  $scopeId = Get-GraphScopeId -graphSp $graphSp -scopeValue $s
  if (-not $scopeId) {
    Write-Warn "Kunne ikke finde Graph scope '$s' (springer over)."
    continue
  }

  Invoke-AzCliText -AzCliArgs @(
    "ad","app","permission","add",
    "--id",$clientId,
    "--api",$GraphAppId,
    "--api-permissions","$scopeId=Scope",
    "-o","none",
    "--only-show-errors"
  ) -FriendlyName "az ad app permission add (Scope:$s)" | Out-Null

  Write-Ok "Tilføjet (Delegated): $s"
}

# 7) Admin consent URL
$encodedRedirect = [System.Uri]::EscapeDataString($WebRedirectUri)
$consentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$clientId&redirect_uri=$encodedRedirect"

Write-Host ""
Write-Warn "Admin consent URL (åbn som Global Admin):"
Write-Host $consentUrl -ForegroundColor Yellow

# 8) Create client secret
Write-Info "Opretter client secret..."
$secret = Invoke-AzCliJson -AzCliArgs @(
  "ad","app","credential","reset",
  "--id",$clientId,
  "--append",
  "--display-name","meetingcopilot-secret",
  "--years","2"
) -FriendlyName "az ad app credential reset"

$clientSecret = $secret.password
if ([string]::IsNullOrWhiteSpace($clientSecret)) {
  Write-Fail "Kunne ikke læse clientSecret fra credential reset output."
}
Write-Ok "Client secret oprettet."

# 9) Return JSON to deploy.ps1
@{
  tenantId        = $TenantId
  clientId        = $clientId
  clientSecret    = $clientSecret
  adminConsentUrl = $consentUrl
} | ConvertTo-Json -Depth 10
