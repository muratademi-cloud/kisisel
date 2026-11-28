# Kişisel Takip (Flutter)

Bölümler: Araçlar (vergi/sigorta hatırlatma, bakım kayıtları), Aylık ödemeler, Hatırlatmalar (tarih+saat, telefon bildirimi), Günlük işler.

## APK almak (GitHub, kurulumsuz)
1. Bu klasördeki tüm dosyaları (.github ve tool klasörleri dahil) GitHub deposuna yükleyin.
2. Actions > "APK Derle" > Run workflow.
3. Bitince "kisisel-takip-apk" dosyasını indirin, zip içinden app-release.apk'yı telefona kurun.

## Bilgisayarda derleme
    flutter create --org com.kisisel --project-name kisisel_takip --platforms android .
    python3 tool/patch_android.py
    flutter pub get
    flutter build apk --release
