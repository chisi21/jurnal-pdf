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
    else {
      if ($path -eq '/') { $urlPath = '/index.html' } else { $urlPath = $path }
      $filePath = Join-Path $root ($urlPath.TrimStart('/'))

      if (Test-Path $filePath -PathType Leaf) {
        $ext  = [System.IO.Path]::GetExtension($filePath).ToLower()
        if ($mimeMap.ContainsKey($ext)) { $mime = $mimeMap[$ext] } else { $mime = 'application/octet-stream' }
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
