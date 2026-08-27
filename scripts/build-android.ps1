# ساخت خودکار APK Android با Capacitor
param(
 [string]$AppUrl='', [string]$Version='', [switch]$Release, [switch]$Sign,
 [switch]$Install, [switch]$Clean, [switch]$InternalWorkspace, [string]$OriginalRoot=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'build-common.ps1')
$forward=@(); foreach($item in @(@('AppUrl',$AppUrl),@('Version',$Version))){if($item[1]){$forward+=@("-$($item[0])",$item[1])}}; foreach($s in @('Release','Sign','Install','Clean')){if(Get-Variable $s -ValueOnly){$forward+="-$s"}}
Enter-AsciiBuildWorkspace -ScriptName 'build-android.ps1' -ForwardArguments $forward -InternalWorkspace:$InternalWorkspace -OriginalRoot $OriginalRoot | Out-Null
Set-Location (Split-Path $PSScriptRoot -Parent); $Root=(Get-Location).Path; if(-not $OriginalRoot){$OriginalRoot=$Root}

function Ensure-Jdk {
 $java=Get-Command java -ErrorAction SilentlyContinue
 if(-not $java){
  $winget=Get-Command winget -ErrorAction SilentlyContinue
  if($winget){& $winget.Source install --id EclipseAdoptium.Temurin.21.JDK -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements | Out-Null; Update-ProcessPath}
 }
 if(-not(Get-Command java -ErrorAction SilentlyContinue)){throw 'نصب خودکار JDK 21 ممکن نشد. اتصال اینترنت/winget را بررسی کنید.'}
 $javaPath=(Get-Command java).Source; $env:JAVA_HOME=(Split-Path (Split-Path $javaPath -Parent) -Parent); $env:Path="$env:JAVA_HOME\bin;$env:Path"
}
function Ensure-AndroidSdk {
 $sdk=if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}elseif($env:ANDROID_HOME){$env:ANDROID_HOME}else{Join-Path $env:LOCALAPPDATA 'Android\Sdk'}
 $manager=Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
 if(-not(Test-Path $manager)){
  $zip=Join-Path $env:TEMP 'android-commandlinetools.zip'; $tmp=Join-Path $env:TEMP 'android-commandlinetools'
  Invoke-Download -Uri @('https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip') -OutFile $zip -TimeoutSec 600
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive $zip $tmp -Force
  New-Item -ItemType Directory -Force (Split-Path $manager -Parent) | Out-Null
  Copy-Item (Join-Path $tmp 'cmdline-tools\*') (Split-Path $manager -Parent) -Recurse -Force
 }
 $env:ANDROID_SDK_ROOT=$sdk; $env:ANDROID_HOME=$sdk; $env:Path="$sdk\platform-tools;$sdk\cmdline-tools\latest\bin;$env:Path"
 return @($sdk,$manager)
}
try {
 Write-Step '1/7 پیش‌نیازها و پکیج‌ها'; Ensure-Jdk; $sdkInfo=Ensure-AndroidSdk; $sdk=$sdkInfo[0]; $manager=$sdkInfo[1]; Install-NodeDependencies
 Invoke-Checked npm.cmd @('install','--no-save','--include=optional','--no-audit','--no-fund','--no-progress','--yes','@capacitor/core','@capacitor/cli','@capacitor/android','@capacitor/splash-screen','@capacitor/assets') 'Capacitor install failed'

 Write-Step '2/7 تعیین نسخه و Android SDK'
 $pkgPath=Join-Path $Root 'package.json'; if($Version){if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'قالب نسخه باید x.y.z باشد'}; $raw=(Get-Content $pkgPath -Raw)-replace '("version"\s*:\s*")[^"]+("\s*,)',"`${1}$Version`${2}"; [IO.File]::WriteAllText($pkgPath,$raw,(New-Object Text.UTF8Encoding($false)))}
 $VersionName=(Get-Content $pkgPath -Raw|ConvertFrom-Json).version; $v=$VersionName.Split('.'); $VersionCode=[int]$v[0]*10000+[int]$v[1]*100+[int]$v[2]
 $gradleFiles=Get-ChildItem -Path @('android','node_modules\@capacitor\android') -Filter '*.gradle' -Recurse -ErrorAction SilentlyContinue
 $text=($gradleFiles|ForEach-Object{Get-Content $_.FullName -Raw})-join "`n"
 $compile=if($text -match 'compileSdk(?:Version)?\s*[=:]?\s*(\d+)'){$Matches[1]}else{'35'}; $buildTools=if($text -match 'buildToolsVersion\s*[=:]?\s*["'']([^"'']+)'){$Matches[1]}else{'35.0.0'}
 $yesFile=Join-Path $env:TEMP 'android-licenses.txt'; (1..200|ForEach-Object{'y'})|Set-Content $yesFile -Encoding ascii
 cmd.exe /c "`"$manager`" --sdk_root=`"$sdk`" --licenses < `"$yesFile`" >nul"; if($LASTEXITCODE -ne 0){throw 'پذیرش licenseهای Android ناموفق بود.'}
 Invoke-Checked $manager @("--sdk_root=$sdk",'platform-tools',"platforms;android-$compile","build-tools;$buildTools") 'Android SDK package installation failed'

 Write-Step '3/7 بیلد وب'; $env:NITRO_PRESET='node-server'; Invoke-Checked npm.cmd @('run','build') 'Web build failed'
 if((-not(Test-Path '.output/public/index.html')) -and (-not $AppUrl)){throw 'پروژه SSR است؛ برای APK قابل استفاده پارامتر -AppUrl را با نشانی سرور Windows وارد کنید.'}

 Write-Step '4/7 تنظیم Capacitor'; $cfg=Get-Content capacitor.config.json -Raw|ConvertFrom-Json
 if($AppUrl){$cfg|Add-Member server ([pscustomobject]@{url=$AppUrl;cleartext=$true}) -Force}elseif($cfg.PSObject.Properties.Name -contains 'server'){$cfg.PSObject.Properties.Remove('server')}
 [IO.File]::WriteAllText((Join-Path $Root 'capacitor.config.json'),($cfg|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))

 Write-Step '5/7 همگام‌سازی Android'; if($Clean -and (Test-Path 'android\app\build')){Remove-Item 'android\app\build' -Recurse -Force}; if(-not(Test-Path android)){Invoke-Checked npx.cmd @('--yes','cap','add','android') 'Capacitor Android add failed'}
 Invoke-Checked npx.cmd @('--yes','@capacitor/assets','generate','--android','--iconBackgroundColor','#0a1024','--splashBackgroundColor','#0a1024') 'Asset generation failed'; Invoke-Checked npx.cmd @('--yes','cap','sync','android') 'Capacitor sync failed'; Invoke-Checked node @('scripts\install-android-plugin.mjs') 'Native plugin install failed'
 $gradle='android\app\build.gradle'; $g=Get-Content $gradle -Raw; $g=$g-replace 'versionCode\s+\d+',"versionCode $VersionCode"; $g=$g-replace 'versionName\s+"[^"]*"',"versionName `"$VersionName`""; [IO.File]::WriteAllText((Join-Path $Root $gradle),$g,(New-Object Text.UTF8Encoding($false)))

 Write-Step '6/7 ساخت APK'; Push-Location android; try {if($Clean){Invoke-Checked '.\gradlew.bat' @('clean','--no-daemon','--console=plain') 'Gradle clean failed'}; $task=if($Release){'assembleRelease'}else{'assembleDebug'}; Invoke-Checked '.\gradlew.bat' @($task,'--no-daemon','--console=plain','--stacktrace') 'Gradle build failed'}finally{Pop-Location}
 $apk=if($Release){Join-Path $Root 'android\app\build\outputs\apk\release\app-release-unsigned.apk'}else{Join-Path $Root 'android\app\build\outputs\apk\debug\app-debug.apk'}; if($Release -and -not(Test-Path $apk)){$apk=Join-Path $Root 'android\app\build\outputs\apk\release\app-release.apk'}; if(-not(Test-Path $apk)){throw "APK پیدا نشد: $apk"}

 if($Release -and $Sign){
  $ks=Join-Path $OriginalRoot 'release.keystore'; $pass=if($env:UMS_KEYSTORE_PASSWORD){$env:UMS_KEYSTORE_PASSWORD}else{'umsrelease'}
  if(-not(Test-Path $ks)){Invoke-Checked keytool @('-genkeypair','-noprompt','-keystore',$ks,'-alias','ums','-keyalg','RSA','-keysize','2048','-validity','10000','-storepass',$pass,'-keypass',$pass,'-dname','CN=UniversalMediaServer, O=UMS, C=IR') 'keytool failed'}
  $signer=Get-ChildItem "$sdk\build-tools" -Filter apksigner.bat -Recurse|Sort-Object FullName -Descending|Select-Object -First 1; if(-not $signer){throw 'apksigner پیدا نشد.'}; $signed=Join-Path $Root 'app-release-signed.apk'; Invoke-Checked $signer.FullName @('sign','--ks',$ks,'--ks-pass',"pass:$pass",'--key-pass',"pass:$pass",'--out',$signed,$apk) 'APK signing failed'; Invoke-Checked $signer.FullName @('verify','--verbose',$signed) 'APK signature verification failed'; $apk=$signed
 }
 $name="UniversalMediaServer-$VersionName" + $(if($Release){'-release.apk'}else{'-debug.apk'}); $final=Copy-BuildArtifact $apk $OriginalRoot $name
 Write-Step '7/7 پایان'; if($Install){$adb=Join-Path $sdk 'platform-tools\adb.exe'; Invoke-Checked $adb @('install','-r','-d',$final) 'ADB install failed'}; Write-Ok "APK: $final"
} catch {Write-Error "ساخت Android متوقف شد: $($_.Exception.Message)"; exit 1}
