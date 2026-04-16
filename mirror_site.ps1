param(
  [Parameter(Mandatory=$true)][string]$StartUrl,
  [string]$OutputDir = "site-mirror",
  [int]$MaxPages = 3000
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web

function Normalize-Url {
  param([string]$BaseUrl, [string]$Candidate)

  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
  $cand = $Candidate.Trim()
  $cand = [System.Web.HttpUtility]::HtmlDecode($cand)
  if ($cand.StartsWith("mailto:") -or $cand.StartsWith("tel:") -or $cand.StartsWith("javascript:") -or $cand.StartsWith("data:")) { return $null }

  $parts = $cand.Split('#')
  $cand = $parts[0]
  if ([string]::IsNullOrWhiteSpace($cand)) { return $null }

  try {
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
      $u = [Uri]$cand
    } else {
      $baseUri = [Uri]$BaseUrl
      $u = New-Object System.Uri($baseUri, $cand)
    }
    if ($u.Scheme -ne "http" -and $u.Scheme -ne "https") { return $null }

    $builder = New-Object System.UriBuilder($u)
    $builder.Fragment = ""
    return $builder.Uri.AbsoluteUri
  } catch {
    return $null
  }
}

function Get-LocalPathForUrl {
  param([Uri]$Url, [string]$Root)

  $path = [Uri]::UnescapeDataString($Url.AbsolutePath)
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }
  if ($path.EndsWith('/')) { $path = $path + "index.html" }

  $leaf = [System.IO.Path]::GetFileName($path)
  if ([string]::IsNullOrEmpty([System.IO.Path]::GetExtension($leaf))) {
    $path = "$path.html"
  }

  if (-not [string]::IsNullOrWhiteSpace($Url.Query)) {
    $q = $Url.Query.TrimStart('?')
    $safeQ = [regex]::Replace($q, "[^a-zA-Z0-9._-]+", "_")
    if ($safeQ.Length -gt 80) { $safeQ = $safeQ.Substring(0,80) }
    $ext = [System.IO.Path]::GetExtension($path)
    $base = $path.Substring(0, $path.Length - $ext.Length)
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = ".html" }
    $path = "$base`__q_$safeQ$ext"
  }

  $rel = $path.TrimStart('/') -replace '/', '\\'
  $full = Join-Path (Join-Path $Root $Url.Host) $rel
  return $full
}

function Extract-LinksFromHtml {
  param([string]$Html)

  $links = @()
  $rx = [regex]'(?is)(?:href|src)\s*=\s*["'']([^"'']+)["'']'
  foreach ($m in $rx.Matches($Html)) {
    $links += $m.Groups[1].Value
  }
  return $links
}

function Extract-UrlsFromCss {
  param([string]$Css)

  $links = @()
  $rx = [regex]'(?is)url\(\s*["'']?([^"''\)]+)["'']?\s*\)'
  foreach ($m in $rx.Matches($Css)) {
    $links += $m.Groups[1].Value
  }
  return $links
}

$start = Normalize-Url -BaseUrl "" -Candidate $StartUrl
if (-not $start) { throw "Invalid start URL: $StartUrl" }

$origin = [Uri]$start
$root = (Resolve-Path ".").Path
$outRoot = Join-Path $root $OutputDir
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

$queue = [System.Collections.Generic.Queue[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue.Enqueue($start)

$downloaded = 0
$htmlCount = 0
$assetCount = 0
$errorCount = 0

while ($queue.Count -gt 0 -and $seen.Count -lt $MaxPages) {
  $url = $queue.Dequeue()
  if ($seen.Contains($url)) { continue }
  [void]$seen.Add($url)

  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -MaximumRedirection 5
    $bytes = $response.RawContentStream.ToArray()
    $contentType = ""
    if ($response.Headers["Content-Type"]) { $contentType = $response.Headers["Content-Type"] }

    $uri = [Uri]$url
    $localPath = Get-LocalPathForUrl -Url $uri -Root $outRoot
    $localDir = Split-Path -Path $localPath -Parent
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes($localPath, $bytes)

    $downloaded++

    $isHtml = $false
    if ($contentType.ToLower().Contains("text/html") -or $contentType.ToLower().Contains("application/xhtml+xml")) {
      $isHtml = $true
    } else {
      $head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(500, $bytes.Length)).ToLowerInvariant()
      if ($head.Contains("<html") -or $head.Contains("<!doctype html")) { $isHtml = $true }
    }

    $isCss = $contentType.ToLower().Contains("text/css") -or $uri.AbsolutePath.ToLowerInvariant().EndsWith(".css")

    $rawLinks = @()
    if ($isHtml) {
      $htmlCount++
      $text = $response.Content
      if (-not $text) { $text = [System.Text.Encoding]::UTF8.GetString($bytes) }
      $rawLinks += Extract-LinksFromHtml -Html $text
    }

    if ($isCss) {
      $text = $response.Content
      if (-not $text) { $text = [System.Text.Encoding]::UTF8.GetString($bytes) }
      $rawLinks += Extract-UrlsFromCss -Css $text
    }

    foreach ($raw in $rawLinks) {
      $normalized = Normalize-Url -BaseUrl $url -Candidate $raw
      if (-not $normalized) { continue }
      $nu = [Uri]$normalized
      if ($nu.Scheme -ne $origin.Scheme -or $nu.Host -ne $origin.Host) { continue }
      if (-not $seen.Contains($normalized)) {
        $queue.Enqueue($normalized)
      }
    }

    if (-not $isHtml) { $assetCount++ }
    Write-Host "[OK] $url -> $localPath"
  } catch {
    $errorCount++
    Write-Warning "Failed $url :: $($_.Exception.Message)"
  }
}

$summary = [ordered]@{
  startUrl = $start
  outputDir = $outRoot
  downloaded = $downloaded
  html = $htmlCount
  assets = $assetCount
  errors = $errorCount
  visited = $seen.Count
  maxPages = $MaxPages
}

$summaryPath = Join-Path $outRoot "mirror-summary.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Mirror complete"
Write-Host ($summary | ConvertTo-Json -Depth 5)
Write-Host "Summary: $summaryPath"
