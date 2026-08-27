# توابع مشترک ساخت Windows و Android - سازگار با Windows PowerShell 5.1
Set-StrictMode -Version 2.0

function Write-Step([string]$Text) { Write-Host "== $Text ==" -ForegroundColor Yellow }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }

function Invoke-Checked {
  param([Parameter(Mandatory=$true)][string]$FilePath, [string[]]$ArgumentList=@(), [string]$FailureMessage="Command failed")
  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)" }
}

function Invoke-Download {
  param([Parameter(Mandatory=$true)][string[]]$Uri, [Parameter(Mandatory=$true)][string]$OutFile, [int]$Retries=3, [int]$TimeoutSec=180)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $parent = Split-Path $OutFile -Parent
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  foreach ($url in $Uri) {
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
      try {
        Remove-Item "$OutFile.part" -Force -ErrorAction SilentlyContinue
        $request = [Net.HttpWebRequest]::Create($url)
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $request.UserAgent = "UMS-Build/1.0"
        $response = $request.GetResponse()
        try {
          $input = $response.GetResponseStream()
          $output = [IO.File]::OpenWrite("$OutFile.part")
          try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        } finally { $response.Dispose() }
        if ((Get-Item "$OutFile.part").Length -lt 1024) { throw "Downloaded file is unexpectedly small" }
        Move-Item "$OutFile.part" $OutFile -Force
        return
      } catch {
        Remove-Item "$OutFile.part" -Force -ErrorAction SilentlyContinue
        if ($attempt -eq $Retries) { Write-Warning "Download failed: $url ($($_.Exception.Message))" }
        else { Start-Sleep -Seconds ([Math]::Min(2*$attempt, 6)) }
      }
    }
  }
  throw "دانلود خودکار ناموفق بود: $OutFile"
}

function Update-ProcessPath {
  $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
  $user = [Environment]::GetEnvironmentVariable('Path','User')
  $env:Path = "$machine;$user;$env:Path"
}

function Get-WindowsArch {
  $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  if ($arch -eq 'arm64') { return 'arm64' }
  if ($arch -eq 'x64') { return 'x64' }
  throw "معماری Windows پشتیبانی نمی‌شود: $arch"
}

function Ensure-NodeLts {
  $node = Get-Command node -ErrorAction SilentlyContinue
  $valid = $false
  if ($node) {
    try { $valid = ([int]((& node --version).TrimStart('v').Split('.')[0]) -ge 20) } catch { $valid = $false }
  }
  if (-not $valid) {
    Write-Host "Node.js LTS پیدا نشد؛ نصب بی‌صدا…"
    $installed = $false
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
      & $winget.Source install --id OpenJS.NodeJS.LTS -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
      $installed = ($LASTEXITCODE -eq 0)
    }
    Update-ProcessPath
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
      $arch = Get-WindowsArch
      $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60
      $release = $index | Where-Object { $_.lts -and ([int]$_.version.TrimStart('v').Split('.')[0] -ge 20) } | Select-Object -First 1
      if (-not $release) { throw "نسخه LTS مناسب Node.js پیدا نشد." }
      $msi = Join-Path $env:TEMP "node-$($release.version)-$arch.msi"
      Invoke-Download -Uri @("https://nodejs.org/dist/$($release.version)/node-$($release.version)-$arch.msi") -OutFile $msi
      $p = Start-Process msiexec.exe -ArgumentList '/i', $msi, '/qn', '/norestart' -Wait -PassThru
      if ($p.ExitCode -ne 0) { throw "نصب Node.js ناموفق بود (exit code $($p.ExitCode))." }
      Update-ProcessPath
    }
  }
  if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw "npm پس از نصب Node.js در دسترس نیست." }
  $env:npm_config_yes='true'; $env:npm_config_audit='false'; $env:npm_config_fund='false'; $env:npm_config_progress='false'
}

function Test-NativeBindings {
  & node -e "require('lightningcss');require('@tailwindcss/oxide');" 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Install-NodeDependencies {
  Ensure-NodeLts
  $npmArgs = @('ci','--include=optional','--no-audit','--no-fund','--no-progress','--yes')
  & npm.cmd @npmArgs
  $firstExit = $LASTEXITCODE
  if (($firstExit -eq 0) -and (Test-NativeBindings)) { return }

  Write-Warning "وابستگی‌های native ناقص‌اند؛ ترمیم متناسب با معماری…"
  $arch = Get-WindowsArch
  $lcVersion = (& node -p "require('./node_modules/lightningcss/package.json').version" 2>$null)
  $oxideVersion = (& node -p "require('./node_modules/@tailwindcss/oxide/package.json').version" 2>$null)
  if ($lcVersion -and $oxideVersion) {
    Invoke-Checked npm.cmd @('install','--no-save','--include=optional','--no-audit','--no-fund','--no-progress','--yes',"lightningcss-win32-$arch-msvc@$lcVersion","@tailwindcss/oxide-win32-$arch-msvc@$oxideVersion") 'Native dependency repair failed'
  }
  if (Test-NativeBindings) { return }

  Write-Warning "ترمیم مستقیم کافی نبود؛ node_modules بازسازی می‌شود (lockfile حفظ می‌شود)."
  Remove-Item node_modules -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-Checked npm.cmd $npmArgs 'npm clean install failed'
  if (-not (Test-NativeBindings)) { throw "bindingهای lightningcss/Tailwind Oxide بارگذاری نشدند. آنتی‌ویروس و معماری Node.js را بررسی کنید." }
}

function Enter-AsciiBuildWorkspace {
  param([string]$ScriptName, [string[]]$ForwardArguments, [switch]$InternalWorkspace, [string]$OriginalRoot)
  if ($InternalWorkspace) { return $false }
  if ($env:OS -ne 'Windows_NT') { throw "این اسکریپت باید در Windows اجرا شود." }
  $source = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($source))
  $hash = ([BitConverter]::ToString($hashBytes)).Replace('-','').Substring(0,10).ToLowerInvariant()
  $base = if ($env:UMS_BUILD_ROOT) { $env:UMS_BUILD_ROOT } else { 'C:\ums-build' }
  $workspace = Join-Path $base "screen-share-$hash"
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  if (Test-Path $workspace) { Remove-Item $workspace -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
  Write-Host "کپی پروژه به مسیر امن ساخت: $workspace"
  $excludeDirs = @('node_modules','.git','.output','dist','electron-release','installer','.workspace','.lovable','build')
  $roboArgs = @($source,$workspace,'/E','/COPY:DAT','/R:2','/W:2','/NFL','/NDL','/NJH','/NJS','/NP','/XD') + $excludeDirs
  & robocopy.exe @roboArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "کپی workspace ناموفق بود (robocopy exit $LASTEXITCODE)." }
  $childArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $workspace "scripts\$ScriptName"),'-InternalWorkspace','-OriginalRoot',$source) + $ForwardArguments
  try {
    & powershell.exe @childArgs
    $code = $LASTEXITCODE
  } finally {
    Set-Location $source
    Remove-Item $workspace -Recurse -Force -ErrorAction SilentlyContinue
  }
  exit $code
}

function Copy-BuildArtifact {
  param([string]$Source, [string]$OriginalRoot, [string]$Name)
  if (-not (Test-Path $Source)) { throw "خروجی ساخته نشد: $Source" }
  $destinationRoot = Join-Path $OriginalRoot 'installer'
  New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
  $destination = Join-Path $destinationRoot $Name
  Copy-Item $Source $destination -Force
  return $destination
}
