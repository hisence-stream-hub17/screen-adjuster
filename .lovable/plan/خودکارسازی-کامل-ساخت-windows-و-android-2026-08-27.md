# خودکارسازی کامل ساخت Windows و Android

## خلاصه

مخزن اصلی `hisence-stream-hub16/screen-share-speed-adjuster` جایگزین قالب فعلی می‌شود و دو فرمان موجود ساخت به فرایندهای یک‌دستوری، بدون prompt و مقاوم در برابر مسیرهای دارای فاصله/حروف غیرلاتین تبدیل می‌شوند. خروجی نهایی همیشه به پوشه `installer` در مسیر اصلی پروژه برمی‌گردد.

## تغییرات اجرایی

### 1. Bootstrap مشترک و workspace امن
- افزودن اسکریپت مشترک PowerShell برای تشخیص مسیر نامناسب و کپی سورس به workspace کوتاه و ASCII مانند `C:\ums-build\<project>-<hash>`.
- حذف پوشه‌های سنگین و خروجی (`node_modules`، خروجی وب، Electron، Android build و installer) هنگام کپی؛ عدم استفاده از Junction یا symlink.
- اجرای اسکریپت Windows/Android در workspace با علامت داخلی جلوگیری از recursion، انتقال artifactها به `installer` پروژه اصلی و پاک‌سازی امن workspace در پایان.
- مدیریت خطا با `try/finally`، حفظ exit code، timeout/retry برای دانلودها و پیام نهایی کوتاه و روشن.

### 2. Node/npm و وابستگی‌های native
- تشخیص Windows و معماری `x64`/`arm64` و بررسی Node.js LTS و npm.
- نصب بی‌صدای Node LTS ابتدا با `winget` و در صورت نیاز با MSI رسمی، سپس تازه‌سازی PATH همان نشست.
- نصب قابل‌تکرار با lockfile و سوییچ‌های `--include=optional --no-audit --no-fund --no-progress --yes`.
- بررسی واقعی load شدن `lightningcss` و Tailwind Oxide؛ نصب بسته‌های native متناظر معماری و در صورت باقی‌ماندن خرابی، حذف فقط `node_modules` و نصب مجدد بدون حذف `package-lock.json`.
- جلوگیری از تمام promptهای npm/npx و ثبت دستور مرحله‌ای که در صورت شکست قابل تکرار باشد.

### 3. ساخت Windows
- اجرای build وب فقط از workspace ASCII با preset فعلی node-server، سپس بررسی bundle سرور/کلاینت.
- دانلود و اعتبارسنجی FFmpeg/FFprobe، yt-dlp و وابستگی صدای مجازی با retry و timeout.
- بسته‌بندی Electron و کنترل کامل بودن ماژول‌ها و ابزارها.
- نصب/کشف بی‌صدای Inno Setup، اجرای ISCC و الزام ساخته‌شدن Setup؛ نبود installer دیگر به‌صورت موفقیت کاذب تمام نمی‌شود.
- کپی Setup ساده و نسخه‌دار به `installer` مسیر اصلی و چاپ فقط مسیرهای نهایی.

### 4. ساخت Android
- نصب/کشف بی‌صدای JDK سازگار و تنظیم `JAVA_HOME` در همان نشست.
- نصب Android command-line tools و platform-tools در مسیر محلی قابل‌کنترل، خواندن compile/target/build-tools از Gradle در صورت وجود و استفاده از پیش‌فرض سازگار در غیر این صورت.
- پذیرش خودکار licenseها و نصب platform/build-tools موردنیاز با `sdkmanager --sdk_root` بدون prompt.
- نصب Capacitor به‌صورت lockfile-friendly، تولید/sync پلتفرم، اجرای Gradle با `--no-daemon --console=plain` و متغیرهای محیطی صحیح.
- ساخت keystore بدون prompt، امضا/اعتبارسنجی release و کپی APK نسخه‌دار به `installer` مسیر اصلی؛ نصب ADB فقط در صورت درخواست `-Install`.

### 5. مستندات و نگهداری
- به‌روزرسانی راهنمای Windows و افزودن/تکمیل راهنمای Android با فرمان تک‌خطی، خروجی‌ها، رفتار نصب خودکار و رفع خطای روشن.
- توضیح صریح اینکه `PS C:\...>` فقط prompt پاورشل است و نباید تایپ یا paste شود؛ بین `cd` و فرمان بعدی باید Enter یا `;` باشد.
- حفظ UTF-8 BOM برای همه فایل‌های `.ps1` جهت سازگاری متن فارسی با Windows PowerShell 5.1؛ JSON و فایل‌های Node بدون BOM می‌مانند.
- اضافه‌کردن workspace و خروجی‌های محلی جدید به ignoreها بدون واردکردن SDK/JDK/binaryهای دانلودی به مخزن.

## جزئیات فنی

- اسکریپت مشترک توابع دانلود مقاوم، اجرای process با exit-code، کشف ابزار، bootstrap مسیر و repair وابستگی‌ها را ارائه می‌کند؛ دو build script فقط orchestration مخصوص پلتفرم را نگه می‌دارند.
- lockfile حذف نمی‌شود. مسیر repair نخست نصب lockfile را اجرا می‌کند، سپس bindingهای native را بر اساس معماری بررسی می‌کند و فقط در خرابی واقعی نصب را بازسازی می‌کند.
- رمز release Android به‌صورت argument تعاملی دریافت نمی‌شود؛ برای ساخت خودکار از secret محیطی در صورت وجود و در غیر این صورت مقدار پایدار فعلی پروژه استفاده می‌شود، بدون چاپ رمز در log.
- اجرای Linux فقط شاخه‌های مستقل از Windows را اعتبارسنجی می‌کند؛ installerهای Windows، JDK/SDK ویندوز و APK واقعی باید در Windows اجرا شوند.

## اعتبارسنجی

- بررسی parser/syntax هر دو PowerShell و اسکریپت مشترک (در صورت در دسترس بودن PowerShell)، BOM و metadata پکیج‌ها.
- اجرای نصب و build وب در محیط فعلی و بررسی artifactهای وب و جدیدترین گزارش build.
- اجرای تست‌های dry-run/شاخه‌ای برای محاسبه معماری، مسیر workspace، استخراج نسخه‌های Android و مقصد artifact بدون اجرای installer ویندوز در Linux.
- بررسی اینکه خطای مسیر `New folder16` دیگر به build اصلی نمی‌رسد و همه خروجی‌ها به `installer` ریشه اصلی بازگردانده می‌شوند.
