# H.TRACK — Flutter App
## خطوات التشغيل من الصفر

---

## 1. المتطلبات

| الأداة | الإصدار |
|--------|---------|
| Flutter | 3.19+ |
| Dart | 3.3+ |
| JDK | 17 |
| Android Studio | Hedgehog+ |
| Android SDK | API 21+ |

---

## 2. خطوة واحدة — الطريقة السريعة

```bash
cd himaya_flutter
chmod +x build.sh
./build.sh
```

السكريبت هيعمل:
- ✅ فحص Flutter
- ✅ تحميل Cairo Font
- ✅ `flutter pub get`
- ✅ `flutter build apk --release`

---

## 3. يدوياً خطوة بخطوة

```bash
# 1. روح للمجلد
cd himaya_flutter

# 2. حمّل الـ packages
flutter pub get

# 3. حط Google Maps Key في:
# android/app/src/main/AndroidManifest.xml
# غيّر: YOUR_GOOGLE_MAPS_API_KEY_HERE

# 4. حمّل Cairo font وحطها في assets/fonts/
# Cairo-Regular.ttf
# Cairo-Medium.ttf
# Cairo-SemiBold.ttf
# Cairo-Bold.ttf
# من: https://fonts.google.com/specimen/Cairo

# 5. ابني الـ APK
flutter build apk --release

# 6. الـ APK هيكون في:
# build/app/outputs/flutter-apk/app-release.apk
```

---

## 4. الـ API

```
Base URL: https://himaya-track.com/api.php
Auth: Bearer token (في Header)
```

الـ token بيتحفظ تلقائياً في SharedPreferences.

---

## 5. هيكل الملفات

```
lib/
├── main.dart                 # Entry point + Theme
├── models/
│   └── models.dart           # DeviceModel, UserModel, CardBalance...
├── providers/
│   └── app_provider.dart     # State management (ChangeNotifier)
├── services/
│   └── api_service.dart      # كل الـ API calls
└── screens/
    ├── main_shell.dart        # Bottom nav + routing by role
    ├── dashboard_screen.dart  # الداشبورد بيانات حية
    ├── map_screen.dart        # الخريطة + 3 modals
    └── all_screens.dart       # Devices, Clients, Messages, Account, Login, Splash
```

---

## 6. الـ Google Maps Key

روح: https://console.cloud.google.com
- اعمل project جديد
- فعّل "Maps SDK for Android"
- اعمل API Key
- حطه في `AndroidManifest.xml`

---

## 7. مشاكل شائعة

**Gradle build failed:**
```bash
flutter clean
flutter pub get
flutter build apk --release
```

**Java version:**
```bash
java -version   # لازم يكون 17
```

**SDK not found:**
```bash
flutter doctor
```
