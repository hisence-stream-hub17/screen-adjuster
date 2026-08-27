# بازطراحی Build خودکار Windows و Android

## هدف
هر دو اسکریپت از یک checkout تمیز و بدون اتکا به `node_modules` قبلی، تنها با یک اجرا dependencyها را آماده کنند و خروجی Setup/APK بسازند؛ مسیر دارای فاصله نیز پشتیبانی شود.

## تغییرات
1. **قفل‌کردن dependencyهای build**
   - نسخه‌های Tailwind، Lightning CSS، Oxide، Electron و Capacitor را در `package.json`/`package-lock.json` صریح و سازگار می‌کنم.
   - bindingهای Windows x64 را به‌عنوان optional dependency واقعی ثبت می‌کنم و اختلاف Lightning CSS تو‌در‌تو را با override سازگار حذف می‌کنم تا lockfile شامل فایل‌های native لازم باشد.
   - نصب‌های موقت `npm install --no-save` را حذف می‌کنم؛ هر اجرا فقط یک نصب تمیز و deterministic از lockfile خواهد داشت.

2. **Bootstrap و Health Check مشترک**
   - `build-common.ps1` را به یک pipeline مرحله‌دار تبدیل می‌کنم: بررسی Windows/معماری، Node و npm، پاک‌سازی نصب قبلی، `npm ci --include=optional` و تست واقعی `require('lightningcss')` و `require('@tailwindcss/oxide')`.
   - اگر health check شکست خورد، اسکریپت یک بار نصب تمیز خودکار را با تنظیمات صریح Windows x64 بازسازی می‌کند؛ در صورت شکست مجدد Build متوقف می‌شود و هرگز به Vite نمی‌رسد.
   - مسیرها همگی resolve/quote می‌شوند؛ build در همان پروژه می‌ماند و فقط مسیر temp داخلی ASCII برای فایل‌های موقت استفاده می‌شود، بدون انتقال یا رهاکردن workspace.

3. **Windows build انتها‌به‌انتها**
   - مراحل Node/npm، web build، ابزارهای رسانه، Electron، اعتبارسنجی package، Inno Setup و Setup نهایی را بدون prompt و با خروجی مرحله‌ای اجرا می‌کنم.
   - دانلودها cache، retry، بررسی اندازه/اجرایی‌بودن و پیام روشن خواهند داشت.
   - خروجی نهایی دقیقاً در `installer` کپی و با پیام `BUILD SUCCESS` و مسیر کامل اعلام می‌شود.

4. **Android build انتها‌به‌انتها**
   - نصب جداگانه Capacitor را حذف و آن را وارد lockfile می‌کنم.
   - JDK 21، Android command-line tools، SDK packages/licenses، Gradle wrapper، sync و APK/signing به مراحل قابل‌ردیابی تبدیل می‌شوند.
   - debug APK بدون ورودی دستی ساخته می‌شود؛ release signing با keystore موجود/خودکار و بدون افشای رمز انجام می‌شود.

5. **گزارش خطای کامل و مستندات**
   - اجرای commandها stdout/stderr و exit code را حفظ می‌کند و هنگام خطا Stage، Command، project path، Node/npm، package versions و اقدام ترمیم انجام‌شده را چاپ می‌کند.
   - راهنماها فقط workflow تک‌دستوری را نشان می‌دهند و دستور تعمیر دستی dependency حذف می‌شود.

## اعتبارسنجی
- بررسی dependency tree و وجود bindingهای قفل‌شده.
- تست syntax اسکریپت‌های PowerShell و اجرای clean install + native health check در محیط موجود.
- اجرای build وب و dependency security scan؛ ساخت واقعی Setup/APK مختص Windows/Android SDK است و اسکریپت نتیجه را روی همان میزبان با کنترل artifact تأیید می‌کند.
