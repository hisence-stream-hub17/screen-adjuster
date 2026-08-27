# ساخت خروجی اندروید (APK) با Capacitor — نصب هوشمند/بروزرسانی روی نسخهٔ قبلی
#
# اجرا (اتصال به سرور ویندوزی در شبکه):
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-android.ps1 -AppUrl "http://192.168.1.10:8080"
# اجرا (بدون سرور، فقط رابط کاربری آفلاین):
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-android.ps1
# نسخهٔ انتشار امضاشده + نصب مستقیم روی گوشی وصل‌شده:
#   ... -Release -Install
#
# پارامترها:
#   -Version 1.2.0   نسخهٔ نمایش‌داده‌شده (پیش‌فرض: package.json)
#   -Release         خروجی release
#   -Sign            امضای APK با keystore (اگر نبود، ساخته می‌شود)
#   -Install         نصب روی گوشی متصل؛ اگر نسخهٔ قبلی امضای متفاوت داشت، حذف و نصب تازه
#   -Clean           پاک‌سازی کش gradle و خروجی‌های قبلی

param(
  [string]$AppUrl = "",
  [string]$Version = "",
  [switch]$Release,
  [switch]$Sign,
  [switch]$Install,
  [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$Root = Get-Location

Write-Host "== 1/7 نصب Capacitor ==" -ForegroundColor Yellow
npm install @capacitor/core @capacitor/cli @capacitor/android @capacitor/splash-screen
if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

# ---------------------------------------------------------------------------
# نسخه‌گذاری هوشمند: versionName از package.json و versionCode عددی صعودی
# (بدون versionCode بالاتر، اندروید نصب بروزرسانی را رد می‌کند)
# ---------------------------------------------------------------------------
Write-Host "== 2/7 تعیین نسخه ==" -ForegroundColor Yellow
$pkgPath = Join-Path $Root "package.json"
if ($Version -ne "") {
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "قالب نسخه باید x.y.z باشد" }
  $raw = Get-Content $pkgPath -Raw
  $raw = $raw -replace '("version"\s*:\s*")[^"]+(")', "`${1}$Version`${2}"
  [IO.File]::WriteAllText($pkgPath, $raw, (New-Object Text.UTF8Encoding($false)))
}
$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
$VersionName = $pkg.version
$p = $VersionName.Split('.')
$VersionCode = [int]$p[0] * 10000 + [int]$p[1] * 100 + [int]$p[2]
Write-Host "versionName=$VersionName versionCode=$VersionCode" -ForegroundColor Green

Write-Host "== 3/7 بیلد وب ==" -ForegroundColor Yellow
$env:NITRO_PRESET = "node-server"
npm run build
if ($LASTEXITCODE -ne 0) { throw "build failed" }
if (-not (Test-Path ".output/public/index.html")) {
  if ($AppUrl -eq "") {
    throw "این پروژه SSR است و index.html ایستا ندارد. برای جلوگیری از صفحه سفید/سیاه، build-android.ps1 را با -AppUrl و آدرس سرور ویندوز اجرا کنید."
  }
  Write-Host "خروجی SSR شناسایی شد؛ برنامه Android از سرور $AppUrl استفاده می‌کند." -ForegroundColor Cyan
}

Write-Host "== 4/7 تنظیم capacitor.config.json ==" -ForegroundColor Yellow
$cfg = Get-Content capacitor.config.json -Raw | ConvertFrom-Json
if ($AppUrl -ne "") {
  $cfg | Add-Member -NotePropertyName server -NotePropertyValue ([pscustomobject]@{ url = $AppUrl; cleartext = $true }) -Force
} else {
  if ($cfg.PSObject.Properties.Name -contains "server") { $cfg.PSObject.Properties.Remove("server") }
}
[IO.File]::WriteAllText(
  (Join-Path $Root "capacitor.config.json"),
  ($cfg | ConvertTo-Json -Depth 10),
  (New-Object Text.UTF8Encoding($false))
)

Write-Host "== 5/7 پلتفرم، آیکن/اسپلش، همگام‌سازی ==" -ForegroundColor Yellow
if ($Clean -and (Test-Path "android\app\build")) { Remove-Item "android\app\build" -Recurse -Force }
if (-not (Test-Path "android")) { npx cap add android }
npx @capacitor/assets generate --android --iconBackgroundColor "#0a1024" --splashBackgroundColor "#0a1024"
if ($LASTEXITCODE -ne 0) { throw "Capacitor asset generation failed" }
npx cap sync android
if ($LASTEXITCODE -ne 0) { throw "cap sync failed" }

Write-Host "== نصب پلاگین بومی SSDP/AVTransport ==" -ForegroundColor Yellow
node scripts/install-android-plugin.mjs
if ($LASTEXITCODE -ne 0) { throw "native plugin install failed" }

# نوشتن نسخه در build.gradle تا بروزرسانی روی نسخهٔ قبلی پذیرفته شود
$gradle = "android\app\build.gradle"
if (Test-Path $gradle) {
  $g = Get-Content $gradle -Raw
  $g = $g -replace 'versionCode\s+\d+', "versionCode $VersionCode"
  $g = $g -replace 'versionName\s+"[^"]*"', "versionName `"$VersionName`""
  [IO.File]::WriteAllText((Join-Path $Root $gradle), $g, (New-Object Text.UTF8Encoding($false)))
  Write-Host "build.gradle بروزرسانی شد." -ForegroundColor Green
}

Write-Host "== 6/7 ساخت APK ==" -ForegroundColor Yellow
Push-Location android
try {
  if ($Clean) { .\gradlew.bat clean }
  if ($Release) {
    .\gradlew.bat assembleRelease
    if ($LASTEXITCODE -ne 0) { throw "gradle build failed" }
    $Apk = Join-Path $Root "android\app\build\outputs\apk\release\app-release-unsigned.apk"
    if (-not (Test-Path $Apk)) {
      $Apk = Join-Path $Root "android\app\build\outputs\apk\release\app-release.apk"
    }
  } else {
    .\gradlew.bat assembleDebug
    if ($LASTEXITCODE -ne 0) { throw "gradle build failed" }
    $Apk = Join-Path $Root "android\app\build\outputs\apk\debug\app-debug.apk"
  }
} finally {
  Pop-Location
}
if (-not (Test-Path $Apk)) { throw "APK پیدا نشد: $Apk" }

# ---------------------------------------------------------------------------
# امضا: اگر با هر بیلد کلید عوض شود، اندروید بروزرسانی را رد می‌کند. پس یک
# keystore پایدار در ریشهٔ پروژه ساخته و همیشه همان استفاده می‌شود.
# ---------------------------------------------------------------------------
$SignedApk = Join-Path $Root ("installer\UniversalMediaServer-" + $VersionName + ".apk")
New-Item -ItemType Directory -Force -Path (Join-Path $Root "installer") | Out-Null
if ($Release -and $Sign) {
  Write-Host "== امضای APK ==" -ForegroundColor Yellow
  $Ks = Join-Path $Root "release.keystore"
  $KsPass = "umsrelease"
  if (-not (Test-Path $Ks)) {
    Write-Host "ساخت keystore پایدار (release.keystore) — آن را نگه دارید!" -ForegroundColor Cyan
    & keytool -genkeypair -v -keystore $Ks -alias ums -keyalg RSA -keysize 2048 -validity 10000 `
      -storepass $KsPass -keypass $KsPass -dname "CN=UniversalMediaServer, O=UMS, C=IR"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed (JDK نصب است؟)" }
  }
  $apksigner = Get-Command apksigner -ErrorAction SilentlyContinue
  if (-not $apksigner -and $env:ANDROID_HOME) {
    $apksigner = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Filter "apksigner.bat" -Recurse -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending | Select-Object -First 1
  }
  if (-not $apksigner) { throw "apksigner پیدا نشد (Android build-tools لازم است)" }
  $signerPath = if ($apksigner.Source) { $apksigner.Source } else { $apksigner.FullName }
  & $signerPath sign --ks $Ks --ks-pass "pass:$KsPass" --key-pass "pass:$KsPass" --out $SignedApk $Apk
  if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }
  $Apk = $SignedApk
} else {
  Copy-Item $Apk $SignedApk -Force
  $Apk = $SignedApk
}
Write-Host "خروجی: $Apk" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 7/7 نصب هوشمند روی گوشی: ابتدا بروزرسانی روی نسخهٔ قبل (-r). اگر امضا یا
# نسخه ناسازگار بود، نسخهٔ قدیمی حذف و نصب تازه انجام می‌شود (داده پاک می‌شود).
# ---------------------------------------------------------------------------
if ($Install) {
  Write-Host "== 7/7 نصب روی گوشی ==" -ForegroundColor Yellow
  $adb = (Get-Command adb -ErrorAction SilentlyContinue)
  if (-not $adb) { throw "adb پیدا نشد؛ Android Platform-Tools را نصب کنید." }
  $AppId = $cfg.appId
  $out = (& adb install -r -d "$Apk" 2>&1) -join "`n"
  Write-Host $out
  if ($out -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE|INSTALL_FAILED_VERSION_DOWNGRADE|signatures do not match") {
    Write-Host "نسخهٔ قدیمی ناسازگار بود؛ حذف و نصب تازه…" -ForegroundColor Yellow
    & adb uninstall $AppId | Out-Null
    & adb install "$Apk"
    if ($LASTEXITCODE -ne 0) { throw "adb install failed" }
  }
  Write-Host "نصب کامل شد ($AppId نسخه $VersionName)." -ForegroundColor Green
}

if ($Release -and -not $Sign) {
  Write-Host "برای نصب/بروزرسانی روی گوشی، APK باید امضا شود: پارامتر -Sign را اضافه کنید." -ForegroundColor Yellow
}
