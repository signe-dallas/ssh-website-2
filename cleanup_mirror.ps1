param(
  [string]$MirrorRoot = ".\site-mirror\nacubo-ssh.agencyq.ai",
  [string]$Origin = "https://nacubo-ssh.agencyq.ai"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web

$root = (Resolve-Path $MirrorRoot).Path

function Ensure-ParentDirectory {
  param([string]$FilePath)
  $parent = Split-Path -Path $FilePath -Parent
  if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Copy-DequeryFiles {
  param([string]$BaseRoot)

  $copied = 0
  Get-ChildItem -Path $BaseRoot -Recurse -File | ForEach-Object {
    $name = $_.Name
    if ($name -match '^(?<base>.+?)__q_[^.]+(?<ext>\.[^.]+)$') {
      $plainName = "$($matches.base)$($matches.ext)"
      $plainPath = Join-Path $_.DirectoryName $plainName
      if (-not (Test-Path $plainPath)) {
        Copy-Item -LiteralPath $_.FullName -Destination $plainPath -Force
        $copied++
      }
    }
  }

  return $copied
}

function Normalize-AssetQueries {
  param([string]$Html)

  # Strip cache/query strings from static local assets.
  $pattern = '(?<=["''])\/(?!\/)(?<path>[^"''?]+\.(?:css|js|png|jpg|jpeg|webp|svg|ico|gif|mp4|webm|woff2?|ttf|otf))\?[^"''\s>]*'
  $Html = [regex]::Replace($Html, $pattern, {
    param($m)
    return "/$($m.Groups['path'].Value)"
  })

  # Rewrite Next image optimizer URLs to underlying image paths.
  $imgPattern = '\/_next\/image\?url=(?<url>[^&"''\s>]+)(?:&[^"''\s>]*)?'
  $Html = [regex]::Replace($Html, $imgPattern, {
    param($m)
    $decoded = [System.Web.HttpUtility]::UrlDecode($m.Groups['url'].Value)
    if ([string]::IsNullOrWhiteSpace($decoded)) { return $m.Value }
    return $decoded
  })

  # Convert route-style internal links to .html so local static hosting works.
  $Html = $Html -replace 'href=\"\/icon\.png\.html\"', 'href="/icon.png"'

  $hrefPattern = 'href=\"(?<route>\/(?!\/)(?!_next\/)(?!images\/)(?!videos\/)[^\"#?\.]*)\"'
  $Html = [regex]::Replace($Html, $hrefPattern, {
    param($m)
    $route = $m.Groups['route'].Value
    if ($route -eq '/') {
      return 'href="/index.html"'
    }
    return ('href="' + $route.TrimEnd('/') + '.html"')
  })

  return $Html
}

function Collect-ImagePaths {
  param([string]$Html)

  $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  $rx = [regex]'\/(images\/[^"''\s>]+)'
  foreach ($m in $rx.Matches($Html)) {
    [void]$set.Add('/' + $m.Groups[1].Value)
  }
  return $set
}

function Try-DownloadAsset {
  param(
    [string]$PathPart,
    [string]$BaseRoot,
    [string]$BaseOrigin
  )

  $rel = $PathPart.TrimStart('/') -replace '/', '\\'
  $dest = Join-Path $BaseRoot $rel
  if (Test-Path $dest) { return $true }

  Ensure-ParentDirectory -FilePath $dest

  $uri = "$BaseOrigin$PathPart"
  try {
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -MaximumRedirection 5
    [System.IO.File]::WriteAllBytes($dest, $response.RawContentStream.ToArray())
    return $true
  } catch {
    return $false
  }
}

function Light-FormatHtml {
  param([string]$Html)

  # Safe readability improvement: put tags on separate lines.
  $formatted = [regex]::Replace($Html, '>\s*<', ">`r`n<")

  # Collapse excessive blank lines.
  $formatted = [regex]::Replace($formatted, "(`r`n){3,}", "`r`n`r`n")
  return $formatted
}

$copiedFiles = Copy-DequeryFiles -BaseRoot $root

$htmlFiles = Get-ChildItem -Path $root -Recurse -File -Filter *.html |
  Where-Object { $_.FullName -notmatch '\\_next\\image__q_' }

$edited = 0
$downloadedImages = 0
$failedImages = 0
$imageWanted = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $htmlFiles) {
  $raw = Get-Content -LiteralPath $file.FullName -Raw
  $updated = Normalize-AssetQueries -Html $raw

  $imgSet = Collect-ImagePaths -Html $updated
  foreach ($img in $imgSet) {
    [void]$imageWanted.Add($img)
  }

  $pretty = Light-FormatHtml -Html $updated

  if ($pretty -ne $raw) {
    Set-Content -LiteralPath $file.FullName -Value $pretty -Encoding UTF8
    $edited++
  }
}

foreach ($imgPath in $imageWanted) {
  $ok = Try-DownloadAsset -PathPart $imgPath -BaseRoot $root -BaseOrigin $Origin
  if ($ok) { $downloadedImages++ } else { $failedImages++ }
}

$summary = [ordered]@{
  mirrorRoot = $root
  htmlFilesProcessed = $htmlFiles.Count
  htmlFilesEdited = $edited
  dequeryCopiesCreated = $copiedFiles
  imagePathsDiscovered = $imageWanted.Count
  imageFilesFetchedOrPresent = $downloadedImages
  imageFetchFailures = $failedImages
}

$summaryPath = Join-Path $root "cleanup-summary.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "Cleanup complete"
Write-Host ($summary | ConvertTo-Json -Depth 5)
Write-Host "Summary: $summaryPath"
