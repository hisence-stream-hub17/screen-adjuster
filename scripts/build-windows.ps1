# ساخت خودکار نسخه Windows و Setup
param(
  [switch]$SkipInstaller,
  [switch]$RefreshDeps,
  [string]$Version = "",
  [switch]$InternalWorkspace,
  [string]$OriginalRoot = ""
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'build-common.ps1')
$forward=@(); if($SkipInstaller){$forward+='-SkipInstaller'}; if($RefreshDeps){$forward+='-RefreshDeps'}; if($Version){$forward+=@('-Version',$Version)}
Enter-AsciiBuildWorkspace -ScriptName 'build-windows.ps1' -ForwardArguments $forward -InternalWorkspace:$InternalWorkspace -OriginalRoot $OriginalRoot | Out-Null
Set-Location (Split-Path $PSScriptRoot -Parent)
$Root=(Get-Location).Path; if(-not $OriginalRoot){$OriginalRoot=$Root}
$AppName='UniversalMediaServer'; $ResourcesDir=Join-Path $Root 'resources'; $PackDir=Join-Path $Root "electron-release\$AppName-win32-x64"

try {
  Write-Step '0/7 تعیین نسخه'
  $pkgPath=Join-Path $Root 'package.json'
  if($Version){
    if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'قالب نسخه باید x.y.z باشد'}
    $raw=(Get-Content $pkgPath -Raw) -replace '("version"\s*:\s*")[^"]+("             )',"`${1}$Version`${2}"
    # جایگزینی دوم برای JSON معمولی؛ فایل JSON باید بدون BOM بماند.
    $raw=$raw -replace '("version"\s*:\s*")[^"]+("\s*,)',"`${1}$Version`${2}"
    [IO.File]::WriteAllText($pkgPath,$raw,(New-Object Text.UTF8Encoding($false)))
  }
  $AppVersion=(Get-Content $pkgPath -Raw | ConvertFrom-Json).version

  Write-Step '1/7 نصب تمیز پکیج‌ها'
  Install-NodeDependencies

  Write-Step '2/7 بیلد وب'
  $env:NITRO_PRESET='node-server'
  Invoke-Checked npm.cmd @('run','build','--','--configLoader','runner') 'Web build failed'
  if((-not(Test-Path '.output/server/index.mjs')) -and (-not(Test-Path 'dist/server/index.mjs'))){throw 'Server bundle ساخته نشد.'}

  Write-Step '3/7 آماده‌سازی FFmpeg و yt-dlp'
  New-Item -ItemType Directory -Force $ResourcesDir | Out-Null
  $ffZip=Join-Path $env:TEMP 'ums-ffmpeg.zip'; $ffTmp=Join-Path $env:TEMP 'ums-ffmpeg'
  if($RefreshDeps){Remove-Item (Join-Path $ResourcesDir 'ffmpeg.exe'),(Join-Path $ResourcesDir 'ffprobe.exe'),(Join-Path $ResourcesDir 'yt-dlp.exe') -Force -ErrorAction SilentlyContinue}
  if((-not(Test-Path (Join-Path $ResourcesDir 'ffmpeg.exe'))) -or (-not(Test-Path (Join-Path $ResourcesDir 'ffprobe.exe')))){
    Invoke-Download -Uri @('https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip','https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip') -OutFile $ffZip -TimeoutSec 600
    Remove-Item $ffTmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive $ffZip $ffTmp -Force
    foreach($name in @('ffmpeg.exe','ffprobe.exe')){$hit=Get-ChildItem $ffTmp -Recurse -Filter $name | Select-Object -First 1; if(-not $hit){throw "$name در archive پیدا نشد."}; Copy-Item $hit.FullName (Join-Path $ResourcesDir $name) -Force}
  }
  $ff=Join-Path $ResourcesDir 'ffmpeg.exe'; $fp=Join-Path $ResourcesDir 'ffprobe.exe'
  Invoke-Checked $ff @('-hide_banner','-version') 'ffmpeg invalid'; Invoke-Checked $fp @('-hide_banner','-version') 'ffprobe invalid'
  $features=((& $ff -hide_banner -devices 2>&1) -join "`n") + ((& $ff -hide_banner -encoders 2>&1) -join "`n")
  if($features -notmatch 'gdigrab' -or $features -notmatch 'libx264'){throw 'ffmpeg دانلودشده فاقد gdigrab یا libx264 است.'}
  $ytdlp=Join-Path $ResourcesDir 'yt-dlp.exe'; if(-not(Test-Path $ytdlp)){Invoke-Download -Uri @('https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe') -OutFile $ytdlp -TimeoutSec 300}; Invoke-Checked $ytdlp @('--version') 'yt-dlp invalid'
  $audio=Join-Path $ResourcesDir 'Setup.Screen.Capturer.Recorder.exe'; if(-not(Test-Path $audio)){Invoke-Download -Uri @('https://github.com/rdp/screen-capture-recorder-to-video-windows-free/releases/download/v0.13.3/Setup.Screen.Capturer.Recorder.v0.13.3.exe') -OutFile $audio -TimeoutSec 300}

  Write-Step '4/7 بسته‌بندی Electron'
  $env:ELECTRON_GET_USE_PROXY='true'
  Invoke-Checked node @('.\scripts\package-electron.mjs','--platform','win32','--arch','x64','--version',$AppVersion) 'Electron packaging failed'

  Write-Step '5/7 بازبینی بسته'
  $exe=Join-Path $PackDir "$AppName.exe"; if(-not(Test-Path $exe)){throw "خروجی Electron پیدا نشد: $exe"}
  $appRoot=Join-Path $PackDir 'resources\app'; $required=@('.output\server\index.mjs','.output\public','electron','package.json')
  foreach($rel in $required){if(-not(Test-Path (Join-Path $appRoot $rel))){throw "بسته ناقص است: $rel"}}
  foreach($name in @('ffmpeg.exe','ffprobe.exe','yt-dlp.exe')){Copy-Item (Join-Path $ResourcesDir $name) (Join-Path $PackDir "resources\$name") -Force}
  if($SkipInstaller){Write-Ok "App: $exe"; exit 0}

  Write-Step '6/7 نصب/کشف Inno Setup'
  function Find-Iscc { @( "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object {Test-Path $_} | Select-Object -First 1 }
  $iscc=Find-Iscc
  if(-not $iscc){
    $winget=Get-Command winget -ErrorAction SilentlyContinue
    if($winget){& $winget.Source install --id JRSoftware.InnoSetup -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements | Out-Null}
    $iscc=Find-Iscc
  }
  if(-not $iscc){$inno=Join-Path $env:TEMP 'innosetup.exe'; Invoke-Download -Uri @('https://jrsoftware.org/download.php/is.exe') -OutFile $inno -TimeoutSec 300; $p=Start-Process $inno -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru; if($p.ExitCode -ne 0){throw "Inno Setup install failed ($($p.ExitCode))"}; $iscc=Find-Iscc}
  if(-not $iscc){throw 'Inno Setup پس از نصب پیدا نشد.'}

  Write-Step '7/7 ساخت Setup'
  Invoke-Checked $iscc @("/DAppVersion=$AppVersion",'scripts\installer.iss') 'Installer build failed'
  $setup=Join-Path $Root 'installer\UniversalMediaServer-Setup.exe'
  $final=Copy-BuildArtifact $setup $OriginalRoot 'UniversalMediaServer-Setup.exe'
  $versioned=Copy-BuildArtifact $setup $OriginalRoot "UniversalMediaServer-Setup-$AppVersion.exe"
  Write-Ok "Setup: $final"; Write-Ok "Setup versioned: $versioned"
} catch {
  Write-Error "ساخت Windows متوقف شد: $($_.Exception.Message)"; exit 1
}
