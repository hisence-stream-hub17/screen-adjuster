# ساخت کاملاً خودکار APK Android با Capacitor
param([string]$AppUrl='', [string]$Version='', [switch]$Release, [switch]$Sign, [switch]$Install, [switch]$Clean, [switch]$InternalWorkspace, [string]$OriginalRoot='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'build-common.ps1')
Enter-AsciiBuildWorkspace -ScriptName 'build-android.ps1' -ForwardArguments @() -InternalWorkspace:$InternalWorkspace -OriginalRoot $OriginalRoot | Out-Null
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path; Set-Location -LiteralPath $Root; if(-not $OriginalRoot){$OriginalRoot=$Root}

function Get-JavaMajor([string]$JavaExe) {
  if (-not (Test-Path -LiteralPath $JavaExe)) { return 0 }
  try {
    $out = (& $JavaExe -version 2>&1 | Out-String)
    if ($out -match 'version "(\d+)(?:\.(\d+))?') {
      $first = [int]$Matches[1]
      if ($first -eq 1 -and $Matches.ContainsKey(2)) { return [int]$Matches[2] }
      return $first
    }
  } catch { return 0 }
  return 0
}

function Get-JdkCandidates {
  $paths = New-Object System.Collections.Generic.List[string]
  function Add-Candidate([string]$p) { if ($p) { $paths.Add($p) } }

  # 1) JAVA_HOME and PATH
  if ($env:JAVA_HOME) { Add-Candidate (Join-Path $env:JAVA_HOME 'bin\java.exe') }
  $onPath = Get-Command java.exe -ErrorAction SilentlyContinue
  if ($onPath) { Add-Candidate $onPath.Source }

  # 2) Registry (Temurin / Adoptium / Oracle / Microsoft / Zulu / Semeru)
  $keys = @(
    'HKLM:\SOFTWARE\JavaSoft\JDK','HKLM:\SOFTWARE\JavaSoft\Java Development Kit',
    'HKLM:\SOFTWARE\Eclipse Adoptium\JDK','HKLM:\SOFTWARE\Eclipse Foundation\JDK',
    'HKLM:\SOFTWARE\Microsoft\JDK','HKLM:\SOFTWARE\Azul Systems\Zulu',
    'HKLM:\SOFTWARE\Semeru\JDK','HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK'
  )
  foreach ($key in $keys) {
    Get-ChildItem $key -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
      $home = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).JavaHome
      if ($home) { Add-Candidate (Join-Path $home 'bin\java.exe') }
    }
  }

  # 3) Well-known install directories, including Android Studio's bundled JBR
  $roots = @(
    "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Eclipse Foundation",
    "$env:ProgramFiles\Java", "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Zulu",
    "$env:ProgramFiles\Amazon Corretto", "$env:ProgramFiles\BellSoft",
    "${env:ProgramFiles(x86)}\Eclipse Adoptium", "${env:ProgramFiles(x86)}\Java",
    "$env:LOCALAPPDATA\Programs\Eclipse Adoptium", "$env:LOCALAPPDATA\Programs\Java",
    "$env:ProgramData\chocolatey\lib", "$env:USERPROFILE\scoop\apps",
    "$env:LOCALAPPDATA\Android\Sdk\jbr", "$env:ProgramFiles\Android\Android Studio\jbr",
    "$env:ProgramFiles\Android\Android Studio\jre", "C:\Java", "C:\jdk", "C:\tools"
  )
  foreach ($root in $roots) {
    if (-not $root) { continue }
    Add-Candidate (Join-Path $root 'bin\java.exe')
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      Add-Candidate (Join-Path $_.FullName 'bin\java.exe')
      Add-Candidate (Join-Path $_.FullName 'jdk\bin\java.exe')
      Add-Candidate (Join-Path $_.FullName 'tools\bin\java.exe')
    }
  }

  # 4) Local build cache (portable JDK downloaded by this script)
  Add-Candidate (Join-Path $Root '.buildtmp\jdk\bin\java.exe')
  Get-ChildItem -LiteralPath (Join-Path $Root '.buildtmp\jdk') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Add-Candidate (Join-Path $_.FullName 'bin\java.exe')
  }

  return ($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Select-Jdk {
  # Gradle for Capacitor 8 works with JDK 17-24; prefer the highest usable one.
  $best = $null; $bestMajor = 0
  foreach ($candidate in Get-JdkCandidates) {
    $major = Get-JavaMajor $candidate
    if ($major -ge 17 -and $major -le 24) {
      $javac = Join-Path (Split-Path $candidate -Parent) 'javac.exe'
      $score = $major
      if (Test-Path -LiteralPath $javac) { $score += 100 }   # a real JDK beats a JRE
      if ($major -eq 21) { $score += 50 }                    # 21 is the validated version
      if ($score -gt $bestMajor) { $bestMajor = $score; $best = $candidate }
    }
  }
  if (-not $best) { return $false }
  $home = Split-Path (Split-Path $best -Parent) -Parent
  $env:JAVA_HOME = $home
  $env:Path = "$home\bin;$env:Path"
  $env:JAVA_TOOL_OPTIONS = '-Dfile.encoding=UTF-8'
  return $true
}

function Install-PortableJdk {
  # Admin-free fallback: extract Temurin 21 into .buildtmp and use it in-place.
  $target = Join-Path $Root '.buildtmp\jdk'
  $zip = Join-Path $Root '.buildtmp\temurin21.zip'
  New-Item -ItemType Directory -Force -Path (Split-Path $zip -Parent) | Out-Null
  if (-not (Test-Path -LiteralPath $zip)) {
    Invoke-Download -Uri @(
      'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk',
      'https://github.com/adoptium/temurin21-binaries/releases/latest/download/OpenJDK21U-jdk_x64_windows_hotspot.zip'
    ) -OutFile $zip -TimeoutSec 900
  }
  Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Write-Host 'Extracting portable JDK 21...'
  Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
}

function Ensure-Jdk {
  if (Select-Jdk) { }
  else {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
      # winget returns non-zero even for "already installed" / "no upgrade found";
      # its exit code is never trusted - java itself is re-probed afterwards.
      Write-Host 'Installing JDK 21 via winget (this may take a few minutes)...'
      & $winget.Source install --id EclipseAdoptium.Temurin.21.JDK -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Host $_ }
      Write-Host "winget exit code: $LASTEXITCODE (ignored; verifying java directly)"
      Update-ProcessPath
      Start-Sleep -Seconds 3
    }
  }
  if (-not (Select-Jdk)) {
    Write-Warning 'No usable JDK 17-24 was detected on this machine. Falling back to a portable JDK 21 inside the project.'
    Install-PortableJdk
    Update-ProcessPath
  }
  if (-not (Select-Jdk)) { throw 'JDK 17-24 could not be located or installed automatically. Check network access to api.adoptium.net and rerun.' }
  Write-Host "Java: $(& java -version 2>&1 | Select-Object -First 1)"
  Write-Host "JAVA_HOME: $env:JAVA_HOME"
}

function Ensure-AndroidSdk {
  $sdk=if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}elseif($env:ANDROID_HOME){$env:ANDROID_HOME}else{Join-Path $env:LOCALAPPDATA 'Android\Sdk'}
  $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
  if(-not(Test-Path $manager)){
    $zip=Join-Path $env:TEMP 'android-commandlinetools.zip';$tmp=Join-Path $env:TEMP 'android-commandlinetools'
    Invoke-Download -Uri @('https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip') -OutFile $zip -TimeoutSec 600
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue;Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path (Split-Path $manager -Parent)|Out-Null
    Copy-Item -Path (Join-Path $tmp 'cmdline-tools\*') -Destination (Split-Path $manager -Parent) -Recurse -Force
  }
  $env:ANDROID_SDK_ROOT=$sdk;$env:ANDROID_HOME=$sdk;$env:Path="$sdk\platform-tools;$sdk\cmdline-tools\latest\bin;$env:Path"
  return @($sdk,$manager)
}

try {
  Write-Step '1/7 Prerequisites, atomic dependencies and native health check'
  Ensure-Jdk; $sdkInfo=Ensure-AndroidSdk; $sdk=$sdkInfo[0]; $manager=$sdkInfo[1]; Install-NodeDependencies

  Write-Step '2/7 Version and Android SDK packages'
  $pkgPath=Join-Path $Root 'package.json'
  if($Version){if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Version format must be x.y.z.'};$raw=(Get-Content $pkgPath -Raw)-replace '("version"\s*:\s*")[^"]+("\s*,)',"`${1}$Version`${2}";[IO.File]::WriteAllText($pkgPath,$raw,(New-Object Text.UTF8Encoding($false)))}
  $VersionName=(Get-Content $pkgPath -Raw|ConvertFrom-Json).version;$v=$VersionName.Split('.');$VersionCode=[int]$v[0]*10000+[int]$v[1]*100+[int]$v[2]
  # Must match variables.gradle (Capacitor 8 template compiles against 36).
  $compile='36';$buildTools='36.0.0'
  $yesFile=Join-Path $env:TEMP 'android-licenses.txt';(1..200|ForEach-Object{'y'})|Set-Content $yesFile -Encoding ascii
  $licenseCommand="`"$manager`" --sdk_root=`"$sdk`" --licenses < `"$yesFile`""
  Invoke-Checked 'cmd.exe' @('/d','/s','/c',$licenseCommand) 'Android SDK license acceptance failed'
  Invoke-Checked $manager @("--sdk_root=$sdk",'platform-tools',"platforms;android-$compile","build-tools;$buildTools") 'Android SDK package installation failed'

  Write-Step '3/7 Screen-share source integrity and TanStack/Vite web build'
  foreach($rel in @('src\components\ScreenSyncPanel.tsx','src\components\AppLayout.tsx','electron\dlna-server.cjs')){if(-not(Test-Path (Join-Path $Root $rel))){throw "Screen sharing source file is missing: $rel"}}
  if((Get-Content (Join-Path $Root 'src\components\AppLayout.tsx') -Raw) -notmatch 'ScreenSyncPanel'){throw 'ScreenSyncPanel is not rendered in AppLayout.tsx.'}
  if((Get-Content (Join-Path $Root 'electron\dlna-server.cjs') -Raw) -notmatch '/anyview\.ts'){throw 'Anyview Stream route is missing from dlna-server.cjs.'}
  $env:NITRO_PRESET='node-server';Invoke-Checked 'npm.cmd' @('run','build') 'Web build failed'

  if(-not $AppUrl){$AppUrl=if($env:UMS_APP_URL){$env:UMS_APP_URL}else{'http://10.0.2.2:5001'};Write-Host "App URL was not supplied; using $AppUrl (override with -AppUrl or UMS_APP_URL)."}

  Write-Step '4/7 Capacitor configuration'
  $cfg=Get-Content 'capacitor.config.json' -Raw|ConvertFrom-Json
  $cfg|Add-Member server ([pscustomobject]@{url=$AppUrl;cleartext=$true}) -Force
  [IO.File]::WriteAllText((Join-Path $Root 'capacitor.config.json'),($cfg|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))

  Write-Step '5/7 Android synchronization'
  if($Clean -and (Test-Path 'android\app\build')){Remove-Item 'android\app\build' -Recurse -Force}
  if(-not(Test-Path 'android')){Invoke-Checked 'npx.cmd' @('--no-install','cap','add','android') 'Capacitor Android initialization failed'}
  Invoke-Checked 'npx.cmd' @('--no-install','capacitor-assets','generate','--android','--iconBackgroundColor','#0a1024','--splashBackgroundColor','#0a1024') 'Android asset generation failed'
  Invoke-Checked 'npx.cmd' @('--no-install','cap','sync','android') 'Capacitor synchronization failed'
  Invoke-Checked 'node' @('scripts\install-android-plugin.mjs') 'Native plugin installation failed'
  $gradle='android\app\build.gradle';$g=Get-Content $gradle -Raw;$g=$g-replace 'versionCode\s+\d+',"versionCode $VersionCode";$g=$g-replace 'versionName\s+"[^"]*"',"versionName `"$VersionName`"";[IO.File]::WriteAllText((Join-Path $Root $gradle),$g,(New-Object Text.UTF8Encoding($false)))

  Write-Step '6/7 APK compilation'
  Push-Location 'android';try{if($Clean){Invoke-Checked '.\gradlew.bat' @('clean','--no-daemon','--console=plain') 'Gradle clean failed'};$task=if($Release){'assembleRelease'}else{'assembleDebug'};Invoke-Checked '.\gradlew.bat' @($task,'--no-daemon','--console=plain','--stacktrace') 'Gradle build failed'}finally{Pop-Location}
  $apk=if($Release){Join-Path $Root 'android\app\build\outputs\apk\release\app-release-unsigned.apk'}else{Join-Path $Root 'android\app\build\outputs\apk\debug\app-debug.apk'}
  if($Release -and -not(Test-Path $apk)){$apk=Join-Path $Root 'android\app\build\outputs\apk\release\app-release.apk'}
  if(-not(Test-Path $apk)){throw "APK was not produced: $apk"}
  # Compatibility gate: the APK must install on Android 6.0 (API 23) and be a
  # single universal package with cleartext HTTP allowed.
  $vars=Get-Content (Join-Path $Root 'android\variables.gradle') -Raw
  if($vars -notmatch 'minSdkVersion\s*=\s*23'){throw 'minSdkVersion is not 23; the APK would not install on Android 6.'}
  $man=Get-Content (Join-Path $Root 'android\app\src\main\AndroidManifest.xml') -Raw
  foreach($needle in @('usesCleartextTraffic','networkSecurityConfig','hardwareAccelerated')){
    if($man -notmatch $needle){throw "AndroidManifest is missing $needle; release builds would show a blank screen."}
  }
  $aapt=Get-ChildItem "$sdk\build-tools" -Filter 'aapt2.exe' -Recurse -ErrorAction SilentlyContinue|Sort-Object FullName -Descending|Select-Object -First 1
  if($aapt){
    $dump=& $aapt.FullName dump badging $apk 2>&1
    $sdkLine=($dump|Select-String "sdkVersion:'(\d+)'").Matches.Groups[1].Value
    if($sdkLine -and [int]$sdkLine -gt 23){throw "APK minSdk is $sdkLine; Android 6 phones cannot install it."}
    Write-Ok "APK minSdk: $sdkLine (Android 6.0+)"
  }

  Write-Step '7/7 Signing, verification and artifact'
  if($Release -and $Sign){
    $ks=Join-Path $OriginalRoot 'release.keystore';$pass=if($env:UMS_KEYSTORE_PASSWORD){$env:UMS_KEYSTORE_PASSWORD}else{'umsrelease'}
    if(-not(Test-Path $ks)){Invoke-Checked 'keytool' @('-genkeypair','-noprompt','-keystore',$ks,'-alias','ums','-keyalg','RSA','-keysize','2048','-validity','10000','-storepass',$pass,'-keypass',$pass,'-dname','CN=UniversalMediaServer, O=UMS, C=IR') 'Keystore generation failed'}
    $signer=Get-ChildItem "$sdk\build-tools" -Filter 'apksigner.bat' -Recurse|Sort-Object FullName -Descending|Select-Object -First 1;if(-not $signer){throw 'apksigner was not found.'}
    $signed=Join-Path $Root 'app-release-signed.apk';Invoke-Checked $signer.FullName @('sign','--ks',$ks,'--ks-pass',"pass:$pass",'--key-pass',"pass:$pass",'--out',$signed,$apk) 'APK signing failed';Invoke-Checked $signer.FullName @('verify','--verbose',$signed) 'APK signature verification failed';$apk=$signed
  }
  $name="UniversalMediaServer-$VersionName"+$(if($Release){'-release.apk'}else{'-debug.apk'});$final=Copy-BuildArtifact $apk $OriginalRoot $name
  if($Install){$adb=Join-Path $sdk 'platform-tools\adb.exe';Invoke-Checked $adb @('install','-r','-d',$final) 'ADB installation failed'}
  Write-Host "`nBUILD SUCCESS" -ForegroundColor Green;Write-Ok "APK: $final"
} catch { Write-BuildFailure -Failure $_ -Root $Root; exit 1 }