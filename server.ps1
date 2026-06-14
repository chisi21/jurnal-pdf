[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$port  = 8080
$root  = $PSScriptRoot
$model = 'gemini-2.5-flash'

# Baca config.json
$geminiKey  = ''
$configPath = Join-Path $root 'config.json'
if (Test-Path $configPath) {
  try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($cfg.geminiKey) { $geminiKey = [string]$cfg.geminiKey }
  } catch {
    Write-Host "  [WARN] Gagal baca config.json" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "  Server berjalan di: http://localhost:$port" -ForegroundColor Green
if ($geminiKey) {
  Write-Host "  Gemini AI : AKTIF ($model)" -ForegroundColor Cyan
} else {
  Write-Host "  Gemini AI : nonaktif - isi geminiKey di config.json lalu restart" -ForegroundColor Yellow
}
Write-Host "  Tekan Ctrl+C untuk menghentikan." -ForegroundColor DarkGray
Write-Host ""

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

Start-Process "http://localhost:$port"

$mimeMap = @{
  '.html' = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.png'  = 'image/png'
  '.ico'  = 'image/x-icon'
}

function Write-Res {
  param($Res, [int]$Code, [string]$Type, [byte[]]$Bytes)
  $Res.StatusCode      = $Code
  $Res.ContentType     = $Type
  $Res.ContentLength64 = $Bytes.Length
  $Res.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Res.OutputStream.Close()
}

function JsonBytes([string]$Json) {
  return [System.Text.Encoding]::UTF8.GetBytes($Json)
}

function ErrJson([string]$Msg) {
  $clean = $Msg -replace '"', "'"
  return JsonBytes "{""error"":""$clean""}"
}

# Panggil Gemini dengan retry (untuk error sementara 503/429/500) + fallback model
function Invoke-Gemini([string]$ReqBody, [string[]]$Models, [string]$Key) {
  $lastErr = $null
  foreach ($m in $Models) {
    $url = "https://generativelanguage.googleapis.com/v1beta/models/$($m):generateContent?key=$Key"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      try {
        return Invoke-WebRequest -Uri $url -Method POST -Body $ReqBody -ContentType 'application/json' -UseBasicParsing
      } catch {
        $lastErr = $_
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 503 -or $code -eq 429 -or $code -eq 500) {
          Write-Host "    [retry] $m percobaan $attempt gagal (HTTP $code), coba lagi..." -ForegroundColor DarkYellow
          Start-Sleep -Milliseconds (500 * $attempt)
          continue
        }
        throw   # error permanen (mis. key salah) -> hentikan
      }
    }
    Write-Host "    [fallback] $m tetap gagal, coba model lain..." -ForegroundColor DarkYellow
  }
  throw $lastErr
}

# ── Fungsi pencarian jurnal (sisi server, hindari CORS + rate limit) ──────────
function Search-Semantic([string]$q, [int]$limit) {
  $fields = 'title,year,abstract,openAccessPdf,authors,citationCount,externalIds'
  $url = "https://api.semanticscholar.org/graph/v1/paper/search?query=$([uri]::EscapeDataString($q))&fields=$fields&limit=$limit"
  for ($i = 1; $i -le 4; $i++) {
    try {
      $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
      $d = $r.Content | ConvertFrom-Json
      $out = @()
      foreach ($p in $d.data) {
        $pdf = $null; if ($p.openAccessPdf) { $pdf = $p.openAccessPdf.url }
        if ($p.externalIds -and $p.externalIds.DOI) { $page = "https://doi.org/$($p.externalIds.DOI)" } else { $page = "https://www.semanticscholar.org/paper/$($p.paperId)" }
        $auth = (@($p.authors) | Select-Object -First 3 | ForEach-Object { $_.name }) -join ', '
        $out += @{ source='Semantic Scholar'; title=$p.title; year=$p.year; authors=$auth; abstract=$p.abstract; pdfUrl=$pdf; pageUrl=$page; citations=$p.citationCount }
      }
      return $out
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      if ($code -eq 429) { Start-Sleep -Milliseconds (1200 * $i); continue }
      return @()
    }
  }
  return @()
}

function Search-CORE([string]$q, [int]$limit, [string]$mode) {
  try {
    if ($mode -eq 'indonesia') { $query = "$q language:Indonesian" } else { $query = $q }
    $r = Invoke-WebRequest -Uri "https://api.core.ac.uk/v3/search/works?q=$([uri]::EscapeDataString($query))&limit=$limit" -UseBasicParsing -TimeoutSec 20
    $d = $r.Content | ConvertFrom-Json
    $out = @()
    foreach ($p in $d.results) {
      $pdf = $p.downloadUrl
      if (-not $pdf -and $p.links) { $dl = $p.links | Where-Object { $_.type -eq 'download' } | Select-Object -First 1; if ($dl) { $pdf = $dl.url } }
      if ($p.sourceFulltextUrls -and $p.sourceFulltextUrls.Count -gt 0) { $page = $p.sourceFulltextUrls[0] } else { $page = "https://core.ac.uk/works/$($p.id)" }
      $auth = (@($p.authors) | Select-Object -First 3 | ForEach-Object { $_.name }) -join ', '
      $out += @{ source='CORE'; title=$p.title; year=$p.yearPublished; authors=$auth; abstract=$p.abstract; pdfUrl=$pdf; pageUrl=$page; citations=$null }
    }
    return $out
  } catch { return @() }
}

function Search-Arxiv([string]$q, [int]$limit) {
  try {
    $r = Invoke-WebRequest -Uri "https://export.arxiv.org/api/query?search_query=all:$([uri]::EscapeDataString($q))&start=0&max_results=$limit" -UseBasicParsing -TimeoutSec 20
    [xml]$xml = $r.Content
    $out = @()
    foreach ($e in $xml.feed.entry) {
      if (-not $e) { continue }
      $id = ($e.id -replace 'https?://arxiv\.org/abs/', '')
      $yr = '—'; if ($e.published) { try { $yr = ([datetime]$e.published).Year } catch {} }
      $names = (@($e.author) | Select-Object -First 3 | ForEach-Object { $_.name }) -join ', '
      $title = ($e.title -replace '\s+', ' ').Trim()
      $abs = ($e.summary -replace '\s+', ' ').Trim()
      $out += @{ source='arXiv'; title=$title; year=$yr; authors=$names; abstract=$abs; pdfUrl="https://arxiv.org/pdf/$id"; pageUrl="https://arxiv.org/abs/$id"; citations=$null }
    }
    return $out
  } catch { return @() }
}

function Search-OpenAlex([string]$q, [int]$limit) {
  try {
    $sel = "id,doi,display_name,publication_year,authorships,open_access,primary_location,best_oa_location,cited_by_count"
    $url = "https://api.openalex.org/works?search=$([uri]::EscapeDataString($q))&per_page=$limit&select=$sel&mailto=jurnalfinder@example.com"
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
    $d = $r.Content | ConvertFrom-Json
    $out = @()
    foreach ($p in $d.results) {
      $pdf = $null
      if ($p.best_oa_location -and $p.best_oa_location.pdf_url) { $pdf = $p.best_oa_location.pdf_url }
      elseif ($p.primary_location -and $p.primary_location.pdf_url) { $pdf = $p.primary_location.pdf_url }
      elseif ($p.open_access -and $p.open_access.oa_url) { $pdf = $p.open_access.oa_url }
      $page = $p.doi
      if (-not $page -and $p.primary_location) { $page = $p.primary_location.landing_page_url }
      if (-not $page) { $page = $p.id }
      $auth = (@($p.authorships) | Select-Object -First 3 | ForEach-Object { $_.author.display_name }) -join ', '
      $out += @{ source='OpenAlex'; title=$p.display_name; year=$p.publication_year; authors=$auth; abstract=''; pdfUrl=$pdf; pageUrl=$page; citations=$p.cited_by_count }
    }
    return $out
  } catch { return @() }
}

function Search-Crossref([string]$q, [int]$limit) {
  try {
    $url = "https://api.crossref.org/works?query=$([uri]::EscapeDataString($q))&rows=$limit&mailto=jurnalfinder@example.com"
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
    $d = $r.Content | ConvertFrom-Json
    $out = @()
    foreach ($p in $d.message.items) {
      $pdf = $null
      if ($p.link) { $lp = $p.link | Where-Object { $_.'content-type' -eq 'application/pdf' } | Select-Object -First 1; if ($lp) { $pdf = $lp.URL } }
      $yr = '—'; if ($p.issued -and $p.issued.'date-parts') { try { $yr = $p.issued.'date-parts'[0][0] } catch {} }
      if ($p.title) { $title = $p.title[0] } else { $title = '(tanpa judul)' }
      $auth = (@($p.author) | Select-Object -First 3 | ForEach-Object { (($_.given, $_.family) -join ' ').Trim() }) -join ', '
      $abs = ''; if ($p.abstract) { $abs = ($p.abstract -replace '<[^>]+>','').Trim() }
      $page = $null; if ($p.DOI) { $page = "https://doi.org/$($p.DOI)" }
      $out += @{ source='Crossref'; title=$title; year=$yr; authors=$auth; abstract=$abs; pdfUrl=$pdf; pageUrl=$page; citations=$p.'is-referenced-by-count' }
    }
    return $out
  } catch { return @() }
}

function Search-DOAJ([string]$q, [int]$limit) {
  try {
    $url = "https://doaj.org/api/search/articles/$([uri]::EscapeDataString($q))?pageSize=$limit"
    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
    $d = $r.Content | ConvertFrom-Json
    $out = @()
    foreach ($item in $d.results) {
      $b = $item.bibjson
      if (-not $b) { continue }
      $pdf = $null; $page = $null
      foreach ($l in @($b.link)) {
        if ($l.type -eq 'fulltext') {
          if (($l.content_type -and $l.content_type -match 'pdf') -or ($l.url -match '\.pdf')) { $pdf = $l.url }
          if (-not $page) { $page = $l.url }
        }
      }
      $auth = (@($b.author) | Select-Object -First 3 | ForEach-Object { $_.name }) -join ', '
      $out += @{ source='DOAJ'; title=$b.title; year=$b.year; authors=$auth; abstract=$b.abstract; pdfUrl=$pdf; pageUrl=$page; citations=$null }
    }
    return $out
  } catch { return @() }
}

function Invoke-JournalSearch($payload) {
  $topics   = @($payload.topics) | Select-Object -First 2
  $category = if ($payload.category) { [string]$payload.category } else { 'mixed' }
  $sources  = @($payload.sources); if (-not $sources -or $sources.Count -eq 0) { $sources = @('semantic','core','arxiv','openalex','crossref','doaj') }
  $limit    = 20; if ($payload.limit) { $limit = [int]$payload.limit }
  if ($limit -lt 5) { $limit = 5 }; if ($limit -gt 30) { $limit = 30 }
  $perTopic = [Math]::Max(6, [Math]::Floor($limit / [Math]::Max(1, $topics.Count)))

  $all = @()
  foreach ($t in $topics) {
    $q = [string]$t.query
    $qId = if ($t.queryId) { [string]$t.queryId } else { $q }
    if (-not $q -and -not $qId) { continue }

    if ($category -eq 'indonesia') {
      if ($sources -contains 'openalex') { $all += Search-OpenAlex $qId $perTopic }
      if ($sources -contains 'crossref') { $all += Search-Crossref $qId $perTopic }
      if ($sources -contains 'core')     { $all += Search-CORE $qId $perTopic 'international' }
      if ($sources -contains 'doaj')     { $all += Search-DOAJ $qId $perTopic }
      if ($sources -contains 'semantic') { $all += Search-Semantic $qId $perTopic; Start-Sleep -Milliseconds 300 }
    } elseif ($category -eq 'international') {
      if ($sources -contains 'openalex') { $all += Search-OpenAlex $q $perTopic }
      if ($sources -contains 'crossref') { $all += Search-Crossref $q $perTopic }
      if ($sources -contains 'core')     { $all += Search-CORE $q $perTopic 'international' }
      if ($sources -contains 'arxiv')    { $all += Search-Arxiv $q $perTopic }
      if ($sources -contains 'doaj')     { $all += Search-DOAJ $q $perTopic }
      if ($sources -contains 'semantic') { $all += Search-Semantic $q $perTopic; Start-Sleep -Milliseconds 300 }
    } else {
      if ($sources -contains 'openalex') { $all += Search-OpenAlex $q $perTopic; if ($qId -ne $q) { $all += Search-OpenAlex $qId $perTopic } }
      if ($sources -contains 'crossref') { $all += Search-Crossref $q $perTopic; if ($qId -ne $q) { $all += Search-Crossref $qId $perTopic } }
      if ($sources -contains 'core')     { $all += Search-CORE $q $perTopic 'international' }
      if ($sources -contains 'arxiv')    { $all += Search-Arxiv $q $perTopic }
      if ($sources -contains 'doaj')     { if ($qId -ne $q) { $all += Search-DOAJ $qId $perTopic } else { $all += Search-DOAJ $q $perTopic } }
      if ($sources -contains 'semantic') { $all += Search-Semantic $q $perTopic; Start-Sleep -Milliseconds 300 }
    }
  }

  # Deduplikasi
  $seen = @{}; $dedup = @()
  foreach ($r in $all) {
    $k = ([string]$r.title).ToLower() -replace '\s+', ' '
    $k = $k.Trim()
    if (-not $k -or $seen.ContainsKey($k)) { continue }
    $seen[$k] = $true; $dedup += $r
  }
  # Urutkan: PDF dulu, lalu tahun terbaru
  $sorted = $dedup | Sort-Object @{ Expression = { if ($_.pdfUrl) { 0 } else { 1 } } }, @{ Expression = { [int]($_.year) } ; Descending = $true }

  return @{ results = @($sorted) } | ConvertTo-Json -Depth 10 -Compress
}

try {
  while ($listener.IsListening) {
    $ctx  = $listener.GetContext()
    $req  = $ctx.Request
    $res  = $ctx.Response
    $path = $req.Url.AbsolutePath

    if ($path -eq '/api/status') {
      if ($geminiKey) { $ready = 'true' } else { $ready = 'false' }
      Write-Res $res 200 'application/json; charset=utf-8' (JsonBytes "{""aiReady"":$ready}")
    }
    elseif ($path -eq '/api/ai' -and $req.HttpMethod -eq 'POST') {
      if (-not $geminiKey) {
        Write-Res $res 403 'application/json; charset=utf-8' (ErrJson 'Gemini belum dikonfigurasi. Isi geminiKey di config.json lalu restart server.')
      }
      else {
        Write-Host "  [AI] Request masuk..." -ForegroundColor Cyan
        try {
          $sr   = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
          $body = $sr.ReadToEnd()
          $sr.Dispose()
          $pl   = $body | ConvertFrom-Json

          # Gabungkan semua pesan jadi satu teks untuk Gemini
          $userText = ($pl.messages | ForEach-Object { $_.content }) -join "`n"

          $reqBody = @{
            contents         = @(@{ parts = @(@{ text = $userText }) })
            generationConfig = @{ maxOutputTokens = 1500; temperature = 0.4 }
          } | ConvertTo-Json -Depth 10 -Compress

          $apiRes = Invoke-Gemini $reqBody @($model, 'gemini-flash-latest') $geminiKey

          # Ubah respon Gemini ke bentuk { content: [ { text: ... } ] }
          $parsed = $apiRes.Content | ConvertFrom-Json
          $text   = $parsed.candidates[0].content.parts[0].text
          if (-not $text) { $text = '' }

          $outBody = @{ content = @(@{ text = $text }) } | ConvertTo-Json -Depth 10 -Compress
          Write-Res $res 200 'application/json; charset=utf-8' (JsonBytes $outBody)
          Write-Host "  [AI] OK" -ForegroundColor Green
        }
        catch {
          $errMsg = $_.Exception.Message
          Write-Host "  [AI] Error: $errMsg" -ForegroundColor Red
          $errBytes = $null
          try {
            $st  = $_.Exception.Response.GetResponseStream()
            $rd  = [System.IO.StreamReader]::new($st)
            $raw = $rd.ReadToEnd()
            $rd.Dispose()
            $errBytes = JsonBytes $raw
          } catch {}
          if ($errBytes) {
            Write-Res $res 500 'application/json; charset=utf-8' $errBytes
          } else {
            Write-Res $res 500 'application/json; charset=utf-8' (ErrJson $errMsg)
          }
        }
      }
    }
    elseif ($path -eq '/api/search' -and $req.HttpMethod -eq 'POST') {
      Write-Host "  [SEARCH] Request masuk..." -ForegroundColor Cyan
      try {
        $sr   = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd()
        $sr.Dispose()
        $pl   = $body | ConvertFrom-Json
        $out  = Invoke-JournalSearch $pl
        Write-Res $res 200 'application/json; charset=utf-8' (JsonBytes $out)
        Write-Host "  [SEARCH] OK" -ForegroundColor Green
      } catch {
        Write-Host "  [SEARCH] Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Res $res 500 'application/json; charset=utf-8' (ErrJson $_.Exception.Message)
      }
    }
    else {
      if ($path -eq '/') { $urlPath = '/index.html' } else { $urlPath = $path }
      $filePath = Join-Path $root ($urlPath.TrimStart('/'))

      if (Test-Path $filePath -PathType Leaf) {
        $ext  = [System.IO.Path]::GetExtension($filePath).ToLower()
        if ($mimeMap.ContainsKey($ext)) { $mime = $mimeMap[$ext] } else { $mime = 'application/octet-stream' }
        try { $res.Headers.Add('Cache-Control', 'no-store, must-revalidate') } catch {}
        $fbytes = [System.IO.File]::ReadAllBytes($filePath)
        Write-Res $res 200 $mime $fbytes
      } else {
        Write-Res $res 404 'text/plain' (JsonBytes '404 Not Found')
      }
      Write-Host "  $($req.HttpMethod) $urlPath" -ForegroundColor DarkGray
    }
  }
}
finally {
  $listener.Stop()
  Write-Host "Server dihentikan." -ForegroundColor Red
}
