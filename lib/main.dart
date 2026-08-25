import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'providers/app_provider.dart';
import 'screens/all_screens.dart';
import 'screens/main_shell.dart';
import 'services/api_service.dart';
import 'services/notification_state.dart';

// ─── Notification routing helpers ──────────────────────────
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

// Build a notif map (matching get_notifications shape) from FCM data + notification.
Map<String, dynamic> _notifMapFromData(Map<String, dynamic> data,
    {String? title, String? body}) {
  int? _i(dynamic v) => int.tryParse(v?.toString() ?? '');
  double? _d(dynamic v) => double.tryParse(v?.toString() ?? '');
  return {
    'type': data['type']?.toString(),
    'alarm_subtype': data['alarm_subtype']?.toString(),
    'device_name': data['device_name']?.toString(),
    'title': title ?? data['title']?.toString(),
    'body': body ?? data['body']?.toString(),
    'event_time': data['event_time']?.toString(),
    'created_at': data['event_time']?.toString(),
    'traccar_id': _i(data['traccar_id']),
    'device_id': _i(data['device_id']),
    'lat': _d(data['lat']),
    'lng': _d(data['lng']),
    'speed': _d(data['speed']),
  };
}

void _handleMessageClick(RemoteMessage message) {
  final data = Map<String, dynamic>.from(message.data);
  debugPrint('[NOTIF] tap data=$data');
  final n = _notifMapFromData(data,
      title: message.notification?.title, body: message.notification?.body);
  PendingNotification.setAlert(n);
}

// Background message handler
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ─── التنبيهات الحرجة ──────────────────────────────────────────
// سحب الشريحة أو قطع الكهرباء أو الاستغاثة ليست إشعارًا عاديًا يُقرأ لاحقًا —
// صاحب المركبة يحتاج أن يعرف الآن. فلها قناة منفصلة بصفّارة عالية على مستوى
// المنبّه (تتجاوز وضع الصامت) وأعلى أهمية، وفي المقدمة تتكرر حتى يُغلقها بنفسه.
//
// ⚠️ إعدادات قناة أندرويد ثابتة بعد إنشائها — أي تغيير في الصوت أو الأهمية
// يستلزم معرّف قناة جديدًا، وإلا بقيت الأجهزة القديمة على الإعداد الأول.
// v2: الصفّارة صارت ثلاث نوبات × 10 ثوانٍ بدل نغمة واحدة طويلة.
// تغيير الصوت يستلزم معرّفًا جديدًا وإلا بقيت الأجهزة المثبَّتة على القديم.
const String kCriticalChannelId = 'himaya_critical_v2';

const _criticalTypes = {'tamper', 'powerCut', 'sos'};
bool isCriticalAlert(Map<String, dynamic> data) =>
    data['critical']?.toString() == '1' ||
    _criticalTypes.contains(data['alarm_subtype']?.toString());

final AndroidNotificationChannel kCriticalChannel = AndroidNotificationChannel(
  kCriticalChannelId,
  'تنبيهات حرجة',
  description: 'سحب الشريحة، فصل الكهرباء، والاستغاثة',
  importance: Importance.max,
  playSound: true,
  sound: const RawResourceAndroidNotificationSound('himaya_siren'),
  audioAttributesUsage: AudioAttributesUsage.alarm, // يعلو على وضع الصامت
  enableVibration: true,
  vibrationPattern: Int64List.fromList(<int>[0, 800, 400, 800, 400, 800]),
  enableLights: true,
  ledColor: const Color(0xFFC41E3A),
);

NotificationDetails _criticalDetails() => NotificationDetails(
      android: AndroidNotificationDetails(
        kCriticalChannelId, 'تنبيهات حرجة',
        channelDescription: 'سحب الشريحة، فصل الكهرباء، والاستغاثة',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        // بلا fullScreenIntent — انظر الملاحظة في AndroidManifest
        sound: const RawResourceAndroidNotificationSound('himaya_siren'),
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 800, 400, 800, 400, 800]),
        // بلا FLAG_INSISTENT: التكرار مبنيّ داخل ملف الصوت (ثلاث نوبات)، فيتطابق
        // سلوك المقدمة مع الخلفية. والعلم كان سيجعلها تعيد بلا نهاية.
        color: const Color(0xFFC41E3A),
        colorized: true,
        icon: '@mipmap/ic_launcher',
      ),
    );

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Local notifications setup
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: androidSettings),
    onDidReceiveNotificationResponse: (NotificationResponse resp) {
      // foreground local notification tap → payload contains FCM data JSON
      if (resp.payload == null || resp.payload!.isEmpty) return;
      try {
        final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
        PendingNotification.setAlert(_notifMapFromData(data));
      } catch (_) {}
    },
  );

  // قناة التنبيهات الحرجة — تُنشأ صراحةً كي يستخدمها النظام حين تصل
  // الإشعارات والتطبيق مغلق (يعرضها النظام لا التطبيق).
  final androidNotif =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidNotif?.createNotificationChannel(kCriticalChannel);
  // إزالة القناة السابقة كي لا تبقى معلّقة بلا استعمال في إعدادات الهاتف
  await androidNotif?.deleteNotificationChannel('himaya_critical_v1');

  // Request permission
  await FirebaseMessaging.instance
      .requestPermission(alert: true, badge: true, sound: true);

  // Save FCM token
  String? token = await FirebaseMessaging.instance.getToken();
  if (token != null) {
    ApiService.saveFcmToken(token);
  }

  // Re-save token whenever Firebase rotates it (reinstall/update/restore).
  // This is critical: a rotated token left unsaved means the server keeps a
  // dead token and push notifications silently stop arriving.
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    ApiService.saveFcmToken(newToken);
  });

  // App opened from terminated state via notification tap
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    // delay handling until after first frame
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _handleMessageClick(initialMessage));
  }

  // App opened from background via notification tap
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageClick);

  // Foreground notifications
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    RemoteNotification? notification = message.notification;
    if (notification != null) {
      final critical = isCriticalAlert(Map<String, dynamic>.from(message.data));
      flutterLocalNotificationsPlugin.show(
        notification.hashCode,
        notification.title,
        notification.body,
        critical
            ? _criticalDetails()
            : const NotificationDetails(
                android: AndroidNotificationDetails(
                  'himaya_channel',
                  'H.Track Alerts',
                  channelDescription: 'تنبيهات التتبع',
                  importance: Importance.high,
                  priority: Priority.high,
                  icon: '@mipmap/ic_launcher',
                ),
              ),
        payload: jsonEncode({
          ...message.data,
          'title': notification.title,
          'body': notification.body,
        }),
      );
    }
  });

  // Force RTL
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: const HimayaApp(),
    ),
  );
}

class HimayaApp extends StatelessWidget {
  const HimayaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final locale = provider.locale;
    final isRtl = locale.languageCode == 'ar';
    return MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'H.TRACK',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: const [Locale('ar', 'EG'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: provider.themeMode,
      home: const SplashScreen(),
      routes: {
        '/login': (_) => const LoginScreen(),
        '/main': (_) => const MainShell(),
      },
    );
  }

  ThemeData _buildLightTheme() {
    const red = Color(0xFFC41E3A);
    const green = Color(0xFF6BA539);
    const bg = Color(0xFFF5F6FA);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: 'Cairo',
      colorScheme: ColorScheme.fromSeed(
        seedColor: red,
        brightness: Brightness.light,
        primary: red,
        secondary: green,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1A1F2E),
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Color(0xFF1A1F2E),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: red,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          textStyle:
              const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE8EAEF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE8EAEF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: red),
        ),
        hintStyle:
            const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo'),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE8EAEF)),
        ),
      ),
      dividerColor: const Color(0xFFE8EAEF),
      dividerTheme: const DividerThemeData(color: Color(0xFFE8EAEF)),
    );
  }

  ThemeData _buildDarkTheme() {
    const red = Color(0xFFE53E5A);
    const green = Color(0xFF7DC44A);
    const bg = Color(0xFF0F1117);
    const surface = Color(0xFF1A1F2E);
    const card = Color(0xFF222840);
    const border = Color(0xFF2E3650);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Cairo',
      colorScheme: ColorScheme.fromSeed(
        seedColor: red,
        brightness: Brightness.dark,
        primary: red,
        secondary: green,
        surface: surface,
      ),
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: red,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          textStyle:
              const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: red),
        ),
        hintStyle:
            const TextStyle(color: Color(0xFF6B7280), fontFamily: 'Cairo'),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: border),
        ),
      ),
      dividerColor: border,
      dividerTheme: const DividerThemeData(color: border),
      listTileTheme: const ListTileThemeData(
        textColor: Colors.white,
        iconColor: Color(0xFFB0B8C8),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white),
        contentTextStyle: const TextStyle(
            fontFamily: 'Cairo', fontSize: 13, color: Color(0xFFB0B8C8)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: TextStyle(fontFamily: 'Cairo', color: Colors.white),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontFamily: 'Cairo', color: Colors.white),
        bodyMedium: TextStyle(fontFamily: 'Cairo', color: Colors.white),
        bodySmall: TextStyle(fontFamily: 'Cairo', color: Color(0xFFB0B8C8)),
        titleMedium: TextStyle(
            fontFamily: 'Cairo',
            color: Colors.white,
            fontWeight: FontWeight.w600),
        titleSmall: TextStyle(fontFamily: 'Cairo', color: Color(0xFFB0B8C8)),
        labelSmall: TextStyle(fontFamily: 'Cairo', color: Color(0xFFB0B8C8)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontFamily: 'Cairo', color: Colors.white),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? red : const Color(0xFF6B7280)),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? const Color(0x55E53E5A)
                : border),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? red : Colors.transparent),
        side: const BorderSide(color: Color(0xFF6B7280)),
      ),
    );
  }
}
