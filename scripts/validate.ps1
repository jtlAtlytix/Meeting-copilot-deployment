Param(
  [Parameter(Mandatory=$true)][string]$FunctionBaseUrl,  # https://<app>.azurewebsites.net
  [Parameter(Mandatory=$false)][string]$ExcludedWebhookPath = "/api/GraphTranscriptWebhook",
  [Parameter(Mandatory=$false)][string]$HealthPath = "/api/health",
  [Parameter(Mandatory=$false)][string]$ProtectedPath = "/"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\helpers.ps1"

function Get-Status([System.Exception]$ex) {
  try {
    $resp = $ex.Response
    if ($resp -and $resp.StatusCode) { return [int]$resp.StatusCode }
  } catch {}

  try {
    $wex = $ex -as [System.Net.WebException]
    if ($wex -and $wex.Response) { return [int]([System.Net.HttpWebResponse]$wex.Response).StatusCode }
  } catch {}

  return -1
}

function Get-HeaderValue($headers, [string]$name) {
  if (-not $headers) { return "" }
  try {
    # case-insensitive lookup
    foreach ($k in $headers.Keys) {
      if ("$k".ToLowerInvariant() -eq $name.ToLowerInvariant()) {
        return "$($headers[$k])"
      }
    }
  } catch {}
  return ""
}

function Get-Location([System.Exception]$ex) {
  # PS7
  try {
    $resp = $ex.Response
    if ($resp -and $resp.Headers) {
      $loc = Get-HeaderValue $resp.Headers "Location"
      if ($loc) { return $loc }
    }
  } catch {}

  # PS5
  try {
    $wex = $ex -as [System.Net.WebException]
    if ($wex -and $wex.Response) {
      $hdrs = ([System.Net.HttpWebResponse]$wex.Response).Headers
      $loc = Get-HeaderValue $hdrs "Location"
      if ($loc) { return $loc }
    }
  } catch {}

  return ""
}

function Test-Http([string]$url) {
  try {
    $resp = Invoke-WebRequest -Uri $url -Method GET -MaximumRedirection 0 -TimeoutSec 25
    $loc = ""
    try { $loc = Get-HeaderValue $resp.Headers "Location" } catch { $loc = "" }

    return @{
      ok = $true
      status = [int]$resp.StatusCode
      location = ($loc ?? "")
      content = ($resp.Content ?? "")
    }
  } catch {
    $code = Get-Status $_.Exception
    $loc  = Get-Location $_.Exception
    return @{
      ok = ($code -ge 200 -and $code -lt 300)
      status = $code
      location = ($loc ?? "")
      content = ""
    }
  }
}

function Row($name, $status, $detail) {
  [pscustomobject]@{ Check=$name; Status=$status; Detail=$detail }
}

$base = $FunctionBaseUrl.TrimEnd("/")
$results = @()

# 1) health
$healthUrl = "$base$HealthPath"
$r = Test-Http $healthUrl
if ($r.status -eq 200) {
  $results += Row "health" "GREEN" "200 OK"
} else {
  $results += Row "health" "RED" "status=$($r.status)"
}

# 2) webhook validationToken (FIX: ${} så '?' ikke bliver en del af variabelnavnet)
$webhookUrl = "$base${ExcludedWebhookPath}?validationToken=hello"
try {
  $text = Invoke-RestMethod -Uri $webhookUrl -Method GET -TimeoutSec 25
  if ("$text" -eq "hello") {
    $results += Row "GraphTranscriptWebhook validation" "GREEN" "returns 'hello'"
  } else {
    $results += Row "GraphTranscriptWebhook validation" "YELLOW" "returned '$text'"
  }
} catch {
  $code = Get-Status $_.Exception
  $results += Row "GraphTranscriptWebhook validation" "RED" "status=$code msg=$($_.Exception.Message)"
}

# 3) EasyAuth protection (ProtectedPath må IKKE være excluded)
$protUrl = "$base$ProtectedPath"
$r = Test-Http $protUrl

if ($r.status -eq 302) {
  if ([string]::IsNullOrWhiteSpace($r.location)) {
    # stadig et tegn på at den beskytter – men vi kunne ikke læse Location
    $results += Row "EasyAuth protection" "GREEN" "302 redirect (Location header not captured)"
  } elseif ($r.location -like "*login.microsoftonline.com*" -or $r.location -like "*\.auth*") {
    $results += Row "EasyAuth protection" "GREEN" "302 redirect to login"
  } else {
    $results += Row "EasyAuth protection" "YELLOW" "302 but Location looks odd: $($r.location)"
  }
} elseif ($r.status -eq 401 -or $r.status -eq 403) {
  $results += Row "EasyAuth protection" "GREEN" "status=$($r.status) (protected)"
} elseif ($r.status -eq 200) {
  $results += Row "EasyAuth protection" "YELLOW" "200 OK (maybe not protected?)"
} else {
  $results += Row "EasyAuth protection" "YELLOW" "status=$($r.status) location=$($r.location)"
}

$results | Format-Table -AutoSize

# FIX: wrap i @() så .Count altid findes i PS5/PS7
$greens  = @($results | Where-Object Status -eq "GREEN").Count
$reds    = @($results | Where-Object Status -eq "RED").Count
$yellows = @($results | Where-Object Status -eq "YELLOW").Count

Write-Host ""
Write-Host "Summary: GREEN=$greens YELLOW=$yellows RED=$reds" -ForegroundColor Cyan

if ($reds -gt 0) { exit 2 }
exit 0
