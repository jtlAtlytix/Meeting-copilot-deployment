Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----------------------------
# Console helpers
# ----------------------------
function Write-Info([string]$Message) { Write-Host "ℹ️  $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "⚠️  $Message" -ForegroundColor Yellow }
function Write-Ok  ([string]$Message) { Write-Host "✅ $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "❌ $Message" -ForegroundColor Red; throw $Message }

# ----------------------------
# Command / environment checks
# ----------------------------
function Confirm-Command([Parameter(Mandatory=$true)][string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Fail "Mangler '$Name'. Installér/tilføj til PATH først."
  }
}

function Connect-AzCli {
  Confirm-Command -Name "az"

  try {
    $null = & az account show --only-show-errors 2>$null
  } catch {
    Write-Info "Du er ikke logget ind i az. Starter 'az login'..."
    & az login | Out-Null
  }
}

function Set-AzSubscription([string]$SubscriptionId) {
  if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { return }
  & az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

function Get-TenantIdFromAz {
  ((& az account show --query tenantId -o tsv --only-show-errors) | Out-String).Trim()
}

function Get-SubIdFromAz {
  ((& az account show --query id -o tsv --only-show-errors) | Out-String).Trim()
}

function Get-AzSignedInUser {
  # Returnerer UPN hvis muligt (kan være tom afhængigt af miljø)
  try {
    $u = (& az account show --query user.name -o tsv --only-show-errors) 2>$null
    return ("$u").Trim()
  } catch {
    return ""
  }
}

function Get-AzSubscriptionName {
  try {
    $n = (& az account show --query name -o tsv --only-show-errors) 2>$null
    return ("$n").Trim()
  } catch {
    return ""
  }
}

# ----------------------------
# Random / naming helpers
# ----------------------------
function New-RandomLowerAlphaNum([int]$Length = 6) {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  -join (1..$Length | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
}

function ConvertTo-CustomerCode([string]$InputString) {
  $x = ($InputString ?? "").Trim().ToLowerInvariant()
  $x = $x -replace "[^a-z0-9-]", ""
  if ([string]::IsNullOrWhiteSpace($x)) { Write-Fail "customerCode er tom/ugyldig." }
  return $x
}

function New-StorageAccountName([string]$CustomerCode) {
  # storage account: 3-24 chars, lowercase letters+numbers
  $base = ($CustomerCode -replace "[^a-z0-9]", "")
  if ($base.Length -gt 12) { $base = $base.Substring(0,12) }

  $suffix = New-RandomLowerAlphaNum -Length 8
  $name = "$base" + "mcpsa" + "$suffix"

  if ($name.Length -gt 24) { $name = $name.Substring(0,24) }
  if ($name.Length -lt 3)  { $name = ("mcpsa" + $suffix).Substring(0,3) }

  return $name
}

function New-FunctionAppName([string]$CustomerCode) {
  $suffix = New-RandomLowerAlphaNum -Length 4
  return "$CustomerCode-ai-meetingcopilot-func-$suffix"
}

function New-StrongSecret([int]$Bytes = 32) {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $buf = New-Object byte[] $Bytes
  $rng.GetBytes($buf)
  [Convert]::ToBase64String($buf)
}

# ----------------------------
# Robust AZ CLI wrappers
# ----------------------------
function Invoke-AzCliText {
  param(
    [Parameter(Mandatory=$true)][string[]]$AzCliArgs,
    [Parameter(Mandatory=$false)][string]$FriendlyName = "az"
  )

  Confirm-Command -Name "az"

  Write-Info ("az " + ($AzCliArgs -join " "))
  $out = & az @AzCliArgs 2>&1

  if ($LASTEXITCODE -ne 0) {
    Write-Fail ("$FriendlyName fejlede (exit=$LASTEXITCODE):`n" + ($out | Out-String))
  }

  return ($out | Out-String)
}

function Get-JsonFromText {
  param([Parameter(Mandatory=$true)][string]$Text)

  $idxObj = $Text.IndexOf('{')
  $idxArr = $Text.IndexOf('[')

  if ($idxObj -lt 0 -and $idxArr -lt 0) { return $null }

  $start = $idxObj
  if ($idxArr -ge 0 -and ($idxObj -lt 0 -or $idxArr -lt $idxObj)) {
    $start = $idxArr
  }

  $candidate = $Text.Substring($start).Trim()

  # 1) Prøv hele rest-teksten
  try {
    $null = $candidate | ConvertFrom-Json
    return $candidate
  } catch {}

  # 2) Ellers: klip til sidste } eller ]
  $lastObj = $candidate.LastIndexOf('}')
  $lastArr = $candidate.LastIndexOf(']')

  $end = $lastObj
  if ($lastArr -gt $end) { $end = $lastArr }

  if ($end -gt 0) {
    $candidate2 = $candidate.Substring(0, $end + 1).Trim()
    try {
      $null = $candidate2 | ConvertFrom-Json
      return $candidate2
    } catch {}
  }

  return $null
}

function Invoke-AzCliJson {
  param(
    [Parameter(Mandatory=$true)][string[]]$AzCliArgs,
    [Parameter(Mandatory=$false)][string]$FriendlyName = "az"
  )

  # Undgå $args (automatic variable) – brug et andet navn
  $cliArgs = @($AzCliArgs)

  if (-not ($cliArgs -contains "-o") -and -not ($cliArgs -contains "--output")) {
    $cliArgs += @("-o","json")
  }
  if (-not ($cliArgs -contains "--only-show-errors")) {
    $cliArgs += @("--only-show-errors")
  }

  $txt = Invoke-AzCliText -AzCliArgs $cliArgs -FriendlyName $FriendlyName

  $jsonText = Get-JsonFromText -Text $txt
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    Write-Fail "$FriendlyName returnerede ikke JSON. Raw output:`n$txt"
  }

  try {
    return ($jsonText | ConvertFrom-Json)
  } catch {
    Write-Fail "$FriendlyName returnerede ikke valid JSON (selv efter udtræk). Raw output:`n$txt"
  }
}

function Test-AzCli {
  param([Parameter(Mandatory=$true)][string[]]$AzCliArgs)

  Confirm-Command -Name "az"

  Write-Info ("az " + ($AzCliArgs -join " "))
  $out = & az @AzCliArgs 2>&1
  $code = $LASTEXITCODE

  return [pscustomobject]@{
    ExitCode = $code
    Output   = ($out | Out-String)
  }
}

# ----------------------------
# Backwards compatibility aliases (old names)
# (Aliases triggerer ikke PSUseApprovedVerbs som functions gør)
# ----------------------------
Set-Alias -Name Assert-Command -Value Confirm-Command -Scope Global -Force
Set-Alias -Name Require-Command -Value Confirm-Command -Scope Global -Force

Set-Alias -Name Normalize-CustomerCode -Value ConvertTo-CustomerCode -Scope Global -Force
Set-Alias -Name Ensure-AzLogin -Value Connect-AzCli -Scope Global -Force

# Hvis du tidligere brugte "Extract-JsonFromText"
Set-Alias -Name Extract-JsonFromText -Value Get-JsonFromText -Scope Global -Force

# Hvis du havde "Try-AzArgs"/"Invoke-AzArgs"-varianter før
Set-Alias -Name Try-AzArgs -Value Test-AzCli -Scope Global -Force
Set-Alias -Name Invoke-AzArgs -Value Invoke-AzCliText -Scope Global -Force
