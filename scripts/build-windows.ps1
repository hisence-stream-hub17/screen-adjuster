# ساخت نسخهٔ ویندوز (Universal Media Server) + فایل نصبی هوشمند setup.exe
# اجرا: powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
# پارامترها:
#   -SkipInstaller     فقط پوشهٔ اجرایی بسازد (بدون setup.exe)
#   -RefreshDeps       ffmpeg/ffprobe/yt-dlp را دوباره و تازه دانلود کند
#   -Version 1.2.0     نسخه را روی package.json و setup.exe و بستهٔ Electron ست کند

param(
  [switch]$SkipInstaller,
  [switch]$RefreshDeps,
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

$AppName = "UniversalMediaServer"
$Root = Get-Location
$ResourcesDir = Join-Path $Root "resources"
$PackDir = Join-Path $Root "electron-release\$AppName-win32-x64"

function Get-Pkg { Get-Content (Join-Path $Root "package.json") -Raw | ConvertFrom-Json }

# ---------------------------------------------------------------------------
# 0/7 نسخه‌گذاری هوشمند: نسخه در package.json، بستهٔ Electron و setup.exe یکی می‌شود
# (نصب‌کننده با همین نسخه تصمیم می‌گیرد نسخهٔ قبلی را حذف/بروزرسانی کند)
# ---------------------------------------------------------------------------
Write-Host "== 0/7 تعیین نسخه ==" -ForegroundColor Yellow
$pkg = Get-Pkg
if ($Version -ne "") {
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "قالب نسخه باید x.y.z باشد" }
  $raw = Get-Content (Join-Path $Root "package.json") -Raw
  $raw = $raw -replace '("version"\s*:\s*")[^"]+(")', "`${1}$Version`${2}"
  # Windows PowerShell 5.1 writes a BOM with `Set-Content -Encoding UTF8`.
  # package.json must remain BOM-free for Node/Electron JSON.parse.
  [IO.File]::WriteAllText(
    (Join-Path $Root "package.json"),
    $raw,
    (New-Object Text.UTF8Encoding($false))
  )
  $pkg = Get-Pkg
}
$AppVersion = $pkg.version
Write-Host "نسخه: $AppVersion" -ForegroundColor Green

Write-Host "== 1/7 نصب پکیج‌ها ==" -ForegroundColor Yellow
$NodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($NodeMajor -lt 18) { throw "Node.js 18 یا جدیدتر لازم است." }
npm install
if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

Write-Host "== 2/7 بیلد وب (node-server) ==" -ForegroundColor Yellow
$env:NITRO_PRESET = "node-server"
npm run build
if ($LASTEXITCODE -ne 0) { throw "build failed" }
if ((-not (Test-Path ".output/server/index.mjs")) -and (-not (Test-Path "dist/server/index.mjs"))) {
  throw "Server bundle not found in .output/server or dist/server."
}

# ---------------------------------------------------------------------------
# 3/7 وابستگی‌های اجرایی
#   ffmpeg  : اشتراک صفحه، تبدیل IPTV، اصلاح لب‌سینک  (بدون آن تصویر سیاه)
#   ffprobe : تشخیص کدک/رزولوشن استریم ورودی (probe.cjs)
#   yt-dlp  : تبدیل لینک صفحات وب به استریم مستقیم + دانلود
#   Setup.Screen.Capturer.Recorder : دستگاه virtual-audio-capturer برای صدای دسکتاپ
# ---------------------------------------------------------------------------
Write-Host "== 3/7 آماده‌سازی وابستگی‌ها (ffmpeg/ffprobe/yt-dlp/درایور صدا) ==" -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $ResourcesDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$FfmpegExe = Join-Path $ResourcesDir "ffmpeg.exe"
$FfprobeExe = Join-Path $ResourcesDir "ffprobe.exe"
if ($RefreshDeps) { Remove-Item $FfmpegExe, $FfprobeExe -Force -ErrorAction SilentlyContinue }

if ((-not (Test-Path $FfmpegExe)) -or (-not (Test-Path $FfprobeExe))) {
  $Zip = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
  try {
    Write-Host "دانلود ffmpeg…"
    Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $Zip -UseBasicParsing
    $Tmp = Join-Path $env:TEMP "ffmpeg-extract"
    if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force }
    Expand-Archive -Path $Zip -DestinationPath $Tmp -Force
    foreach ($n in @("ffmpeg.exe", "ffprobe.exe")) {
      $hit = Get-ChildItem -Path $Tmp -Filter $n -Recurse | Select-Object -First 1
      if ($hit) { Copy-Item $hit.FullName (Join-Path $ResourcesDir $n) -Force }
    }
  } catch {
    Write-Warning "دانلود ffmpeg ناموفق بود؛ ffmpeg.exe را دستی در .\resources\ بگذارید."
  }
}
if (-not (Test-Path $FfmpegExe)) {
  throw "resources\ffmpeg.exe موجود نیست. بدون آن اشتراک صفحه و تبدیل IPTV کار نمی‌کند."
}
# سلامت ffmpeg: باید بتواند gdigrab (تصویر دسکتاپ) و libx264 را باز کند
$FfBanner = (& $FfmpegExe -hide_banner -version 2>&1 | Select-Object -First 1)
$FfMuxers = (& $FfmpegExe -hide_banner -devices 2>&1) -join "`n"
$FfEncoders = (& $FfmpegExe -hide_banner -encoders 2>&1) -join "`n"
if ($FfMuxers -notmatch "gdigrab") { throw "این ffmpeg بدون gdigrab است؛ اشتراک صفحه ممکن نیست (بیلد essentials ویندوز لازم است)." }
if ($FfEncoders -notmatch "libx264") { throw "این ffmpeg بدون libx264 است؛ استریم به تلویزیون کار نمی‌کند." }
if ($FfEncoders -notmatch "dshow" -and $FfMuxers -notmatch "dshow") { Write-Warning "dshow پیدا نشد؛ صدای دسکتاپ منتقل نمی‌شود." }
Write-Host "ffmpeg آماده: $FfBanner" -ForegroundColor Green
if (-not (Test-Path $FfprobeExe)) { Write-Warning "ffprobe.exe نیست؛ تشخیص خودکار کیفیت استریم محدود می‌شود." }

$Prereqs = @(
  @{ File = "Setup.Screen.Capturer.Recorder.exe"; Url = "https://github.com/rdp/screen-capture-recorder-to-video-windows-free/releases/download/v0.13.3/Setup.Screen.Capturer.Recorder.v0.13.3.exe"; Required = $false },
  @{ File = "yt-dlp.exe"; Url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"; Required = $false }
)
foreach ($p in $Prereqs) {
  $Dest = Join-Path $ResourcesDir $p.File
  if ($RefreshDeps) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue }
  if (Test-Path $Dest) { continue }
  try {
    Write-Host ("دانلود " + $p.File + "…")
    Invoke-WebRequest -Uri $p.Url -OutFile $Dest -UseBasicParsing
  } catch {
    Write-Warning ("دانلود " + $p.File + " ناموفق بود؛ نصب‌کننده از آن عبور می‌کند.")
  }
}

Write-Host "== 4/7 بسته‌بندی اپ ویندوز ==" -ForegroundColor Yellow
node .\scripts\package-electron.mjs --platform win32 --arch x64 --version $AppVersion
if ($LASTEXITCODE -ne 0) { throw "packaging failed" }

# ---------------------------------------------------------------------------
# 5/7 بازبینی کامل بودن خروجی: همهٔ کاربردهای نرم‌افزار باید در بسته باشند
# (اگر یکی از ماژول‌های electron یا خروجی وب جا بماند، آن قابلیت در نسخهٔ
#  نصب‌شده بی‌صدا از کار می‌افتد — مثلاً پخش روی تلویزیون یا دانلود.)
# ---------------------------------------------------------------------------
Write-Host "== 5/7 بازبینی کامل بودن بسته ==" -ForegroundColor Yellow
$Exe = Join-Path $PackDir "$AppName.exe"
if (-not (Test-Path $Exe)) { throw "خروجی بسته پیدا نشد: $Exe" }
$AppRoot = Join-Path $PackDir "resources\app"

$Missing = @()
# همهٔ ماژول‌های الکترون پروژه باید داخل بسته باشند
Get-ChildItem (Join-Path $Root "electron") -Filter *.cjs | ForEach-Object {
  if (-not (Test-Path (Join-Path $AppRoot ("electron\" + $_.Name)))) { $Missing += "electron\$($_.Name)" }
}
# خروجی وب (رابط کاربری + سرور رسانه)
# نکته: در حالت SSR فایل index.html ایستا ساخته نمی‌شود و صفحه توسط سرور نیترو
# رندر می‌شود؛ پس وجود پوشهٔ .output\public (دارایی‌های کلاینت) کافی است.
foreach ($rel in @(".output\server\index.mjs", "package.json")) {
  if (-not (Test-Path (Join-Path $AppRoot $rel))) { $Missing += $rel }
}
$PublicAssets = Join-Path $AppRoot ".output\public"
if ((-not (Test-Path $PublicAssets)) -or
    (-not (Get-ChildItem $PublicAssets -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1))) {
  $Missing += ".output\public\ (دارایی‌های رابط کاربری)"
}
# افزونه‌ها/پلاگین‌ها و دارایی‌ها
foreach ($dir in @("plugins-src", "extension", "resources", "public")) {
  if ((Test-Path (Join-Path $Root $dir)) -and -not (Test-Path (Join-Path $AppRoot $dir))) { $Missing += "$dir\" }
}
if ($Missing.Count -gt 0) {
  Write-Warning ("این موارد در بسته نیستند: " + ($Missing -join ", "))
  throw "بسته ناقص است؛ ignore list در scripts\package-electron.mjs را بررسی کنید."
}

# ffmpeg باید کنار برنامه باشد (مسیرهایی که tools.cjs جست‌وجو می‌کند)
$PackedResources = Join-Path $PackDir "resources"
foreach ($n in @("ffmpeg.exe", "ffprobe.exe", "yt-dlp.exe")) {
  $src = Join-Path $ResourcesDir $n
  $dst = Join-Path $PackedResources $n
  if ((Test-Path $src) -and (-not (Test-Path $dst))) { Copy-Item $src $dst -Force }
}
if (-not (Test-Path (Join-Path $PackedResources "ffmpeg.exe"))) { throw "ffmpeg.exe در بستهٔ نهایی نیست." }
Write-Host "بسته کامل است (ماژول‌ها، رابط کاربری، سرور، ffmpeg)." -ForegroundColor Green

if ($SkipInstaller) {
  Write-Host "== پایان (بدون setup.exe) ==" -ForegroundColor Green
  Write-Host "App: $Exe"
  exit 0
}

Write-Host "== 6/7 آماده‌سازی Inno Setup ==" -ForegroundColor Yellow
function Resolve-Iscc {
  $cmd = Get-Command iscc -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return @(
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$Iscc = Resolve-Iscc
if (-not $Iscc) {
  Write-Host "Inno Setup پیدا نشد - نصب خودکار…" -ForegroundColor Yellow
  try {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install --id JRSoftware.InnoSetup -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
    }
  } catch { Write-Warning "winget ناموفق بود، دانلود مستقیم…" }
  $Iscc = Resolve-Iscc
  if (-not $Iscc) {
    try {
      $Setup = Join-Path $env:TEMP "innosetup-6.exe"
      Invoke-WebRequest -Uri "https://jrsoftware.org/download.php/is.exe" -OutFile $Setup -UseBasicParsing
      Start-Process -FilePath $Setup -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
    } catch { Write-Warning "دانلود Inno Setup ناموفق بود: $($_.Exception.Message)" }
    $Iscc = Resolve-Iscc
  }
}

Write-Host "== 7/7 ساخت setup.exe هوشمند (حذف/بروزرسانی نسخهٔ قبل) ==" -ForegroundColor Yellow
if ($Iscc) {
  & $Iscc "/DAppVersion=$AppVersion" "scripts\installer.iss"
  if ($LASTEXITCODE -ne 0) { throw "installer build failed" }
  $SetupPath = Join-Path $Root "installer\UniversalMediaServer-Setup.exe"
  if (-not (Test-Path $SetupPath)) { throw "setup.exe ساخته نشد" }
  $VersionedSetup = Join-Path $Root ("installer\UniversalMediaServer-Setup-" + $AppVersion + ".exe")
  Copy-Item $SetupPath $VersionedSetup -Force
  Write-Host "Setup: $SetupPath" -ForegroundColor Green
  Write-Host "Setup (نسخه‌دار): $VersionedSetup" -ForegroundColor Green
} else {
  Write-Warning "Inno Setup نصب نشد. از https://jrsoftware.org/isdl.php نصب کنید و سپس: iscc /DAppVersion=$AppVersion scripts\installer.iss"
}

Write-Host "== پایان ==" -ForegroundColor Green
Write-Host "App:   $Exe"
Write-Host "نکته: برای انتخاب بهترین نسخهٔ وابستگی‌ها روی این سیستم اجرا کنید:" -ForegroundColor Cyan
Write-Host "      powershell -ExecutionPolicy Bypass -File .\scripts\benchmark-deps.ps1" -ForegroundColor Cyan
