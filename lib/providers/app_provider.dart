import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/api_service.dart';
import '../services/i18n.dart';
import '../models/models.dart';
import '../main.dart' show navigatorKey;
import 'dart:ui' show Locale;

class AppProvider extends ChangeNotifier with WidgetsBindingObserver {
  AppProvider() {
    WidgetsBinding.instance.addObserver(this);
    loadLocale();
    loadThemeMode();
  }
  // ─── Auth ──────────────────────────────────────────────────────────────────
  UserModel? _currentUser;
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _error;

  UserModel? get currentUser => _currentUser;
  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAdmin => _currentUser?.isAdmin ?? false;
  bool get isDealer => _currentUser?.isDealer ?? false;
  bool get isViewOnly => _currentUser?.viewOnly ?? false;

  // ─── Locale ────────────────────────────────────────────────────────────────
  Locale _locale = const Locale('ar', 'EG');
  Locale get locale => _locale;

  Future<void> loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final lang = prefs.getString('app_locale') ?? 'ar';
    I18n.lang = lang == 'en' ? 'en' : 'ar';
    _locale = lang == 'en' ? const Locale('en', 'US') : const Locale('ar', 'EG');
    notifyListeners();
  }

  Future<void> setLocale(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_locale', lang);
    I18n.lang = lang == 'en' ? 'en' : 'ar';
    _locale = lang == 'en' ? const Locale('en', 'US') : const Locale('ar', 'EG');
    notifyListeners();
  }

  /// Toggle between Arabic and English.
  Future<void> toggleLocale() async =>
      setLocale(_locale.languageCode == 'ar' ? 'en' : 'ar');

  // ─── Theme Mode ─────────────────────────────────────────────────────────────
  // system = تلقائي (حسب الموبايل)، light = فاتح، dark = داكن
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  Future<void> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_theme') ?? 'system';
    _themeMode = saved == 'dark' ? ThemeMode.dark
        : saved == 'light' ? ThemeMode.light
        : ThemeMode.system;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final key = mode == ThemeMode.dark ? 'dark'
        : mode == ThemeMode.light ? 'light' : 'system';
    await prefs.setString('app_theme', key);
    _themeMode = mode;
    notifyListeners();
  }

  // ─── Dashboard ─────────────────────────────────────────────────────────────
  DashboardStats _dashStats = const DashboardStats();
  DashboardStats get dashStats => _dashStats;

  // ─── Devices ───────────────────────────────────────────────────────────────
  List<DeviceModel> _devices = [];
  List<DeviceModel> _inventory = [];
  bool _devicesLoading = false;
  String _deviceFilter = 'all';

  List<DeviceModel> get devices => _devices;
  List<DeviceModel> get inventory => _inventory;
  bool get devicesLoading => _devicesLoading;
  String get deviceFilter => _deviceFilter;

  // قائمة تاب الأجهزة الرئيسي:
  //  - العميل يرى أجهزته فقط.
  //  - الديلر/الموزع يرون المخزون فقط (الأجهزة اللي عندهم وغير مسندة لعميل) — أجهزة العملاء لا تظهر.
  //  - الأدمن يرى الكل (مسند + مخزون).
  List<DeviceModel> get tabDevices {
    if (_currentUser?.isClient == true) return _devices;
    // أدمن + ديلر + موزع: المخزون فقط (الأجهزة المباشرة تحت الحساب، مش أجهزة العملاء)
    return _inventory;
  }

  List<DeviceModel> get filteredDevices {
    final base = tabDevices;
    switch (_deviceFilter) {
      case 'on': return base.where((d) => d.isOnline).toList();
      case 'moving': return base.where((d) => d.isMoving).toList();
      case 'inactive': return base.where((d) => d.isInactive).toList();
      case 'off': return base.where((d) => d.isOffline || d.isInactive).toList();
      default: return base;
    }
  }

  // ─── Users ─────────────────────────────────────────────────────────────────
  List<UserModel> _users = [];
  bool _usersLoading = false;
  String _clientFilter = 'all';

  List<UserModel> get users => _users;
  bool get usersLoading => _usersLoading;
  String get clientFilter => _clientFilter;

  List<UserModel> get filteredClients {
    switch (_clientFilter) {
      case 'dealer': return _users.where((u) => u.isDealer).toList();
      case 'sub': return _users.where((u) => u.isSubDealer).toList();
      case 'client': return _users.where((u) => u.isClient).toList();
      default: return _users;
    }
  }

  // ─── Cards ─────────────────────────────────────────────────────────────────
  CardBalance _cardBalance = const CardBalance();
  CardBalance get cardBalance => _cardBalance;

  // ─── Map / Refresh ─────────────────────────────────────────────────────────
  DeviceModel? _selectedDevice;
  Timer? _refreshTimer;
  int _refreshCountdown = 5;

  DeviceModel? get selectedDevice => _selectedDevice;
  int get refreshCountdown => _refreshCountdown;

  // ─── Background refresh indicator ──────────────────────────────────────────
  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  // علامة تحميل واضحة تظهر لحظة رجوع التطبيق من الخلفية حتى وصول أول بيانات جديدة
  bool _resuming = false;
  bool get isResuming => _resuming;

  // ─── Init ──────────────────────────────────────────────────────────────────

  /// Fast session-only init. Returns true if we have a saved session (token+user).
  /// Caller navigates to /main immediately, then calls
  /// [validateAndRefreshInBackground] to fetch FRESH devices from the server.
  /// ⚠️ قرار المستخدم: القفل النهائي (cold start) = بيانات طازجة دايمًا — مانحفظش/نعرض
  /// مواقع أجهزة قديمة. الأجهزة تتجاب من السيرفر بعد التنقّل. (الخلفية/الرجوع = الـ process
  /// حي فيحتفظ بآخر صفحة وبياناتها، والتحديث عبر _refreshOnResume.)
  Future<bool> initFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('user_data');
      final token    = prefs.getString('auth_token');
      if (userJson == null || token == null) {
        _isLoggedIn = false;
        return false;
      }
      _currentUser = UserModel.fromJson(jsonDecode(userJson));
      _isLoggedIn = true;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('initFromCache error: $e');
      return false;
    }
  }

  /// Runs after navigating to /main. Validates the token and refreshes
  /// devices/users/cards in the background. Sets [isRefreshing] = true
  /// while running so UI can show a subtle indicator.
  Future<void> validateAndRefreshInBackground() async {
    _isRefreshing = true;
    _connectLiveWs(); // وصّل الـ WS من أول لحظة — المواقع الحيّة تتدفق أثناء تحميل الباقي
    notifyListeners();
    try {
      // ابدأ loadDevices و validateToken بالتوازي — عشان الأجهزة تتحدث فوراً
      // بدل ماننتظر token validation الأول ثم devices
      final tokenFuture  = ApiService.validateToken();
      final deviceFuture = loadDevices();
      // الداشبورد يعرض بطاقات الحسابات من users، وكانت تبدأ بعد اكتمال الأجهزة
      // بلا سبب — لا اعتماد بينهما (السيرفر يحدّد النطاق من التوكن). نبدأها معها.
      final usersFuture = loadUsers().catchError((_) {});

      final result = await tokenFuture;
      if (result['success'] != true) {
        await logout();
        return;
      }
      if (result['user'] != null) {
        final prefs = await SharedPreferences.getInstance();
        _currentUser = UserModel.fromJson(result['user']);
        await prefs.setString('user_data', jsonEncode(result['user']));
        notifyListeners();
      }
      await deviceFuture; // انتظر لو لسه شغّالة (غالباً خلصت قبل كده)
      // أول بيانات طازجة بعد الفتح البارد وصلت → الخريطة تعمل زوم تلقائي على
      // الأجهزة (بدل الثبات على مكان الكاش القديم لو الجهاز اتحرك)
      _resumeSeq++;
      notifyListeners();
      // secondary data في الخلفية — لا ننتظرها (users بدأت مع الأجهزة أعلاه)
      usersFuture.whenComplete(() { if (_users.isNotEmpty) notifyListeners(); });
      loadCardBalance().catchError((_) {});
      _startRefreshTimer();
    } catch (e) {
      debugPrint('validateAndRefreshInBackground error: $e');
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Legacy: blocking init (kept for backwards compatibility but not used by SplashScreen now).
  Future<bool> init() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final userJson = prefs.getString('user_data');
      if (userJson != null) {
        _currentUser = UserModel.fromJson(jsonDecode(userJson));
      }

      final result = await ApiService.validateToken();
      if (result['success'] == true) {
        _isLoggedIn = true;
        if (result['user'] != null) {
          _currentUser = UserModel.fromJson(result['user']);
          await prefs.setString('user_data', jsonEncode(result['user']));
        }
        await _loadInitialData();
        _startRefreshTimer();
      } else {
        _isLoggedIn = false;
        _currentUser = null;
      }
    } catch (e, stack) {
  debugPrint('Init error: $e');
  debugPrint('Stack: $stack');
  _isLoggedIn = false;
}

    _isLoading = false;
    notifyListeners();
    return _isLoggedIn;
  }

  // ─── Auth Actions ──────────────────────────────────────────────────────────

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final result = await ApiService.login(username: username, password: password);

    // Admin two-factor: server withholds the token until the Telegram OTP is verified.
    if (result['needs_2fa'] == true) {
      _twoFactorChallenge = result['challenge'] ?? '';
      _isLoading = false;
      notifyListeners();
      return false;
    }

    if (result['success'] == true) {
      if (_requiresPwChange(result)) { _pwChangeResult = result; _isLoading = false; notifyListeners(); return false; }
      await _completeLogin(result);
    } else {
      _error = result['error'] ?? tr('login_error');
    }

    _isLoading = false;
    notifyListeners();
    return _isLoggedIn;
  }

  // Two-factor challenge state (admin only). Non-null => awaiting OTP entry.
  String? _twoFactorChallenge;
  bool get needsTwoFactor => _twoFactorChallenge != null;
  void cancelTwoFactor() { _twoFactorChallenge = null; _error = null; notifyListeners(); }

  // إجبار تغيير كلمة المرور عند أول دخول (الباسورد الافتراضي 123456)
  Map<String, dynamic>? _pwChangeResult;
  bool get needsPasswordChange => _pwChangeResult != null;
  bool _requiresPwChange(Map<String, dynamic> r) {
    final u = r['user'];
    if (u is! Map) return false;
    final v = u['must_change_password'];
    return v == 1 || v == '1' || v == true;
  }
  void cancelPasswordChange() { _pwChangeResult = null; _error = null; notifyListeners(); }
  Future<bool> submitNewPassword(String newPass) async {
    if (_pwChangeResult == null) return false;
    _isLoading = true; _error = null; notifyListeners();
    final r = await ApiService.changePassword(newPass);
    if (r['success'] == true) {
      final res = _pwChangeResult!;
      _pwChangeResult = null;
      await _completeLogin(res);
    } else {
      _error = r['message'] ?? r['error'] ?? tr('failed');
    }
    _isLoading = false; notifyListeners();
    return _isLoggedIn;
  }

  Future<bool> verifyTwoFactor(String code) async {
    if (_twoFactorChallenge == null) return false;
    _isLoading = true;
    _error = null;
    notifyListeners();

    final result = await ApiService.verifyTwoFactor(challenge: _twoFactorChallenge!, code: code);

    if (result['success'] == true) {
      _twoFactorChallenge = null;
      if (_requiresPwChange(result)) { _pwChangeResult = result; _isLoading = false; notifyListeners(); return false; }
      await _completeLogin(result);
    } else {
      _error = result['error'] ?? tr('login_error');
      if (result['expired'] == true) _twoFactorChallenge = null; // force restart of login
    }

    _isLoading = false;
    notifyListeners();
    return _isLoggedIn;
  }

  Future<void> _completeLogin(Map<String, dynamic> result) async {
    _currentUser = UserModel.fromJson(result['user']);
    _isLoggedIn = true;
    await _loadInitialData();   // يرجّع فورًا (تحميل في الخلفية)
    _startRefreshTimer();
    // FCM في الخلفية — مايأخّرش فتح الحساب (getToken ممكن يكون بطيء على الشبكة). يعيد ربط
    // التوكن بالمستخدم المُصادَق (حفظ الإقلاع ممكن يفشل قبل التوكن، أو التوكن لمستخدم سابق).
    FirebaseMessaging.instance.getToken().then((t) {
      if (t != null) ApiService.saveFcmToken(t);
    }).catchError((_) {});
  }

  Future<void> logout() async {
    _stopRefreshTimer();
    _disconnectLiveWs();
    try { await ApiService.logout(); } catch (_) {}
    _currentUser = null;
    _isLoggedIn = false;
    _devices = [];
    _users = [];
    _inventory = [];
    _dashStats = const DashboardStats();
    _cardBalance = const CardBalance();
    _isRefreshing = false;

    // نظّف أي كاش أجهزة قديم متبقّي من نسخة سابقة (مبقناش نحفظه — cold start = طازج)
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cached_devices_v2');
      await prefs.remove('cached_devices_time');
    } catch (_) {}

    notifyListeners();

    // Safe redirect to login WITHOUT requiring a BuildContext
    // (useful when logout is triggered from background refresh)
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  Future<bool> updateProfile({
    String? fullName, String? phone, String? mobile, String? email, String? address, String? avatar,
  }) async {
    final result = await ApiService.updateProfile(
      fullName: fullName, phone: phone, mobile: mobile,
      email: email, address: address, avatar: avatar,
    );
    if (result['success'] == true) {
      await refreshUser();
      return true;
    }
    _error = result['error'];
    notifyListeners();
    return false;
  }

  // ─── Data Loading ──────────────────────────────────────────────────────────

  // كلمة مرور الأوامر الحسّاسة (إيقاف/تشغيل المحرك، إعادة ضبط، أمر مخصص):
  // إعداد الحساب نفسه من «إعدادات الحساب ← CMD كلمة مرور».
  // الافتراضي true — فالحساب الذي لم يُحفظ له إعداد يبقى محميًا كما هو.
  bool _cmdPasswordRequired = true;
  bool get cmdPasswordRequired => _cmdPasswordRequired;

  /// إظهار ماركر أصفر للمركبة الواقفة ومحرّكها يعمل («IDLE محرك» في إعدادات الحساب).
  bool _idleMarkerEnabled = true;
  bool get idleMarkerEnabled => _idleMarkerEnabled;

  /// نداء واحد يقرأ إعدادات الحساب المؤثّرة على الواجهة.
  Future<void> _loadCmdPasswordPref() async {
    try {
      final r = await ApiService.request('get_settings');
      final s = r['settings'];
      if (r['success'] != true || s is! Map) return;
      bool? flag(String k) {
        final v = s[k];
        if (v == null) return null;
        return v == true || v == 1 || v == '1';
      }
      _cmdPasswordRequired = flag('cmdPassword') ?? _cmdPasswordRequired;
      _idleMarkerEnabled = flag('idleEngine') ?? _idleMarkerEnabled;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadInitialData() async {
    // ⚠️ مانستناش الجلب قبل ما نفتح الحساب — تسجيل الدخول يفتح **فورًا**، والأجهزة تتحمّل في
    // الخلفية (loadDevices بيرفع _devicesLoading فالخريطة/الداشبورد تعرض مؤشر تحميل ثم
    // البيانات الطازة خلال ~ثانية). كان بيستنى loadDevices كامل قبل الفتح = بطء ملحوظ.
    loadDevices().catchError((_) {});
    _loadCmdPasswordPref();   // خفيف، ولا يؤخّر فتح الحساب
    Future.wait([loadUsers(), loadCardBalance()]).then((_) {
      notifyListeners();
    }).catchError((_) {});
  }

  Future<void> loadDevices() async {
    _devicesLoading = true;
    notifyListeners();

    // مكالمة API واحدة فقط لكل الأجهزة + فلترة محلية
    final result = await ApiService.getDevices();
    // ⚠️ لو الاستدعاء فشل (نت/timeout/401) الـ _request بيرجّع {success:false} بدون data.
    // في الحالة دي `raw` = null → ماتمسحش القايمة الموجودة (كان بيفضّيها → «لا توجد أجهزة»).
    final raw = result['data'] ?? result['devices'];
    if (raw is List) {
      final rawMaps = raw.cast<Map<String, dynamic>>();
      final all = rawMaps.map((d) => DeviceModel.fromJson(d)).toList();
      _devices   = all.where((d) => !d.isInventory).toList();
      _inventory = all.where((d) =>  d.isInventory).toList();
      _updateDashStats();
    }

    // إشعار فوري بأول دفعة بيانات (الخريطة تقدر تعرضها)
    _devicesLoading = false;
    notifyListeners();
  }

  Future<void> loadInventory() async {
    // نفس البيانات — نستدعي loadDevices لو محتاجين تحديث
    await loadDevices();
  }

  Future<void> loadUsers() async {
    // ⚠️ الـ spinner يظهر **فقط أول تحميل** (مفيش بيانات). التحديث الدوري الخلفي مايخليش
    // usersLoading=true — عشان مايستبدلش الـ ListView بـ spinner ويرجّع السكرول لفوق وانت
    // بتتصفّح العملاء.
    final firstLoad = _users.isEmpty;
    if (firstLoad) { _usersLoading = true; notifyListeners(); }

    final result = await ApiService.getUsers();
    // ⚠️ لو فشل الاستدعاء → raw=null → ماتمسحش قايمة العملاء (كان بيفضّيها → «لا يوجد عملاء»).
    final raw = result['data'] ?? result['users'];
    if (raw is List) {
      _users = raw.map((u) => UserModel.fromJson(u as Map<String, dynamic>)).toList();
      _updateDashStats();
    }

    if (firstLoad) { _usersLoading = false; notifyListeners(); }
  }

  Future<void> loadCardBalance() async {
    // clients don't have card balance
    if (_currentUser?.isClient == true) return;
    final result = await ApiService.getCardBalance();
    if (result['success'] == true) {
      _cardBalance = CardBalance.fromJson(result);
      _updateDashStats();
      notifyListeners();
    }
  }

  void _updateDashStats() {
    _dashStats = DashboardStats.fromDevices(_devices, _inventory, _users, _cardBalance);
  }

  // ─── Filters ───────────────────────────────────────────────────────────────

  void setDeviceFilter(String filter) { _deviceFilter = filter; notifyListeners(); }
  void setClientFilter(String filter) { _clientFilter = filter; notifyListeners(); }
  void selectDevice(DeviceModel? device) { _selectedDevice = device; notifyListeners(); }

  // ─── Actions ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> addDevice({
    required String imei, required String name, required String deviceType,
    required int userId, required String subscriptionType, String? notes,
  }) async {
    final result = await ApiService.addDevice(
      imei: imei, name: name, deviceType: deviceType,
      userId: userId, subscriptionType: subscriptionType, notes: notes,
    );
    if (result['success'] == true) await loadDevices();
    return result;
  }

  Future<Map<String, dynamic>> updateUser({required int userId, required Map<String, dynamic> updates}) async {
    final result = await ApiService.updateUser(userId: userId, updates: updates);
    if (result['success'] == true) await loadUsers();
    return result;
  }

  Future<Map<String, dynamic>> addUser({
    required String username, required String password, required String fullName,
    required String accountType, String? timezone, String? phone, String? mobile,
    String? email, String? address, int? parentId,
  }) async {
    final result = await ApiService.addUser(
      username: username, password: password, fullName: fullName,
      accountType: accountType, timezone: timezone, phone: phone,
      mobile: mobile, email: email, address: address, parentId: parentId,
    );
    if (result['success'] == true) await loadUsers();
    return result;
  }

  Future<Map<String, dynamic>> changeImei({
    required String oldImei, required String newImei, required String deviceType,
  }) async {
    final result = await ApiService.changeImei(oldImei: oldImei, newImei: newImei, deviceType: deviceType);
    if (result['success'] == true) await loadDevices();
    return result;
  }

  Future<Map<String, dynamic>> sendCommand({
    required int deviceId, required String type, String? password,
    String? customText, String? sosPhone1, String? sosPhone2, String? sosPhone3,
  }) async {
    return ApiService.sendCommand(
      deviceId: deviceId, type: type, customText: customText,
    );
  }

  Future<Map<String, dynamic>> getReport({
    required String reportType, required int deviceId, required String period,
    String? customFrom, String? customTo, int? speedLimit,
  }) async {
    final range = period == 'custom'
        ? {'from': customFrom!, 'to': customTo!}
        : ApiService.getDateRange(period);

    switch (reportType) {
      case 'speed':
        return ApiService.getReportEvents(deviceId: deviceId, from: range['from']!, to: range['to']!, type: 'deviceOverspeed');
      case 'ignition':
        return ApiService.getReportEvents(deviceId: deviceId, from: range['from']!, to: range['to']!, type: 'ignition');
      case 'alerts':
        return ApiService.getReportEvents(deviceId: deviceId, from: range['from']!, to: range['to']!);
      case 'operation':
        return ApiService.getReportSummary(deviceId: deviceId, from: range['from']!, to: range['to']!);
      case 'geofence':
        return ApiService.getReportEvents(deviceId: deviceId, from: range['from']!, to: range['to']!, type: 'geofence');
      default:
        return {'success': false, 'error': tr('rep_unknown_type')};
    }
  }

  Future<Map<String, dynamic>> getReplayRoute({
    required int deviceId, required String period, String? customFrom, String? customTo,
  }) async {
    final range = period == 'custom'
        ? {'from': customFrom!, 'to': customTo!}
        : ApiService.getDateRange(period);
    return ApiService.getReportRoute(deviceId: deviceId, from: range['from']!, to: range['to']!);
  }

  Future<Map<String, dynamic>> assignCards({
    required int toUserId, required String cardType, required int quantity,
  }) async {
    final result = await ApiService.assignCards(toUserId: toUserId, cardType: cardType, quantity: quantity);
    if (result['success'] == true) await loadCardBalance();
    return result;
  }

  // ─── Auto Refresh ──────────────────────────────────────────────────────────

  // يحسب الثواني حتى الإرسال التالي للجهاز (دورة 10 ثواني) + ثانية buffer
  int _calcSyncedCountdown() {
    DateTime? latest;
    for (final d in [..._devices, ..._inventory]) {
      if (d.lastUpdate != null &&
          (latest == null || d.lastUpdate!.isAfter(latest))) {
        latest = d.lastUpdate;
      }
    }
    if (latest == null) return 10;
    final elapsed = DateTime.now().difference(latest).inSeconds.abs() % 10;
    final untilNext = (10 - elapsed) + 1; // ثانية بعد الإرسال المتوقع
    return untilNext.clamp(2, 11);
  }

  void _startRefreshTimer() {
    _stopRefreshTimer();
    _refreshCountdown = 10; // عدّاد نظيف يبدأ من 10 دايماً
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshCountdown--;
      if (_refreshCountdown == 0) {
        // عند الصفر بالظبط: اعرض أحدث مواقع الـ WS المخزّنة على الخريطة (حركة منتظمة
        // عند 0 — تبديل مرجع القوائم يعيد بناء الماركرات على الموقع الأحدث فورًا)،
        // + اجلب الحالة الكاملة من السيرفر (بطارية/حالة/إلخ) كـ fallback ولتأكيد البيانات.
        _devices = List.of(_devices);
        _inventory = List.of(_inventory);
        _silentRefresh();
      } else if (_refreshCountdown < 0) {
        // بعد عرض 0 ثانية واحدة: أعد الضبط لـ 10 (عدّاد نظيف 10→0 كل دورة).
        _refreshCountdown = 10;
      }
      notifyListeners();
    });
    _connectLiveWs(); // مواقع لحظية عبر WebSocket (الـ polling يفضل fallback)
  }

  // ─── Live WebSocket (مواقع لحظية من Traccar عبر الـ relay) ──────────────────
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  Timer? _wsReconnectTimer;
  bool _wsWanted = false; // true طالما مسجّل دخول والتطبيق في المقدمة
  int _wsRetry = 0;
  // تحديث العرض الحي من الـ WS + debounce التوقف
  DateTime? _lastWsRefresh;                       // throttle إعادة بناء العرض من الـ WS

  void _connectLiveWs() {
    _wsWanted = true;
    if (_wsChannel != null) return; // متصل/بيتصل بالفعل
    _openLiveWs();
  }

  Future<void> _openLiveWs() async {
    if (!_wsWanted || _wsChannel != null) return;
    try {
      final token = await ApiService.getToken();
      if (token == null || !_wsWanted) return;
      final ch = WebSocketChannel.connect(Uri.parse('wss://himaya-track.com/ws'));
      _wsChannel = ch;
      ch.sink.add(jsonEncode({'token': token}));
      _wsSub = ch.stream.listen(_onWsData,
          onDone: _onWsClosed, onError: (_) => _onWsClosed(), cancelOnError: true);
    } catch (_) {
      _wsChannel = null;
      _scheduleWsReconnect();
    }
  }

  void _onWsData(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      if (msg is! Map) return;
      if (msg['type'] == 'ready') { _wsRetry = 0; return; }
      final positions = msg['positions'];
      if (positions is! List) return;
      // الـ WS يحدّث كائنات الأجهزة (موقع/سرعة/حالة) ثم يحدّث العرض (ماركر + موديل سوا)
      // من نفس الكائنات الحيّة → متطابقين + فريش (≤~1.5ث). throttle عشان مايرهقش الرسم مع
      // أساطيل كبيرة. الحركة ناعمة (forward-only في _buildMarkers).
      bool changed = false;
      for (final p in positions) {
        if (p is Map && _applyLivePosition(p.cast<String, dynamic>())) changed = true;
      }
      if (changed) {
        final now = DateTime.now();
        if (_lastWsRefresh == null ||
            now.difference(_lastWsRefresh!).inMilliseconds >= 1500) {
          _lastWsRefresh = now;
          _devices = List.of(_devices);
          _inventory = List.of(_inventory);
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  bool _applyLivePosition(Map<String, dynamic> p) {
    final devId = p['deviceId'] is int
        ? p['deviceId'] as int
        : int.tryParse('${p['deviceId']}') ?? 0;
    if (devId == 0) return false;
    DeviceModel? dev;
    for (final d in _devices) { if (d.traccarId == devId) { dev = d; break; } }
    if (dev == null) {
      for (final d in _inventory) { if (d.traccarId == devId) { dev = d; break; } }
    }
    if (dev == null) return false;
    final lat = (p['latitude'] as num?)?.toDouble();
    final lng = (p['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null || (lat == 0 && lng == 0)) return false;
    final spdKmh = ((p['speed'] as num?)?.toDouble() ?? 0) * 1.852;
    dev.lat = lat;
    dev.lng = lng;
    final course = (p['course'] as num?)?.toDouble();
    if (course != null) dev.course = course;
    final attrs = p['attributes'];
    if (attrs is Map && attrs['ignition'] is bool) dev.ignition = attrs['ignition'] as bool;
    final pktTime = DateTime.tryParse('${p['serverTime'] ?? p['fixTime'] ?? ''}') ?? DateTime.now();
    dev.lastSeen = pktTime;                       // أي packet = آخر إرسال بيانات
    if (spdKmh > 2) dev.lastUpdate = pktTime;     // آخر حركة فقط لو متحرك (يحافظ على «متوقف منذ»)
    // السرعة والحالة **الحقيقية مباشرة** — بدون debounce. الـ debounce (5ث) كان بيعرض سرعة
    // وهمية ويأخّر الوقوف من غير ما يحل الوميض فعليًا (GT06 بيبعت كل ~10ث فالمهلة بتخلص قبل
    // الرسالة اللي بعدها). العرض الحقيقي أبسط وأدق ومتّسق مع السيرفر والويب.
    dev.speed = spdKmh;
    if (dev.status != 'inactive') {
      if (spdKmh > 2) {
        dev.status = 'moving';
        // تحرّكت ⇒ لم تعد واقفة بمحرك يعمل. (العكس — بداية الوقوف — يقرّره
        // السيرفر لأنه يحتاج مرور دقيقتين، فلا نرفعها هنا.)
        dev.idle = false;
      } else if (dev.status == 'moving' || dev.status == 'offline') {
        dev.status = 'online';
      }
    }
    return true;
  }

  void _onWsClosed() {
    _wsSub?.cancel();
    _wsSub = null;
    _wsChannel = null;
    if (_wsWanted) _scheduleWsReconnect();
  }

  void _scheduleWsReconnect() {
    _wsReconnectTimer?.cancel();
    const delays = [2, 4, 8, 15, 30];
    final delay = Duration(seconds: delays[_wsRetry.clamp(0, delays.length - 1)]);
    if (_wsRetry < 10) _wsRetry++;
    _wsReconnectTimer = Timer(delay, () { if (_wsWanted) _openLiveWs(); });
  }

  void _disconnectLiveWs() {
    _wsWanted = false;
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    try { _wsChannel?.sink.close(); } catch (_) {}
    _wsChannel = null;
    _wsRetry = 0;
  }

  void _stopRefreshTimer() { _refreshTimer?.cancel(); _refreshTimer = null; }

  int _userRefreshCounter = 0;

  Future<void> _silentRefresh() async {
    try {
      final result = await ApiService.getDevices();
      final List raw = result['data'] ?? result['devices'] ?? [];
      final rawMaps = raw.cast<Map<String, dynamic>>();
      final all  = rawMaps.map((d) => DeviceModel.fromJson(d)).toList();
      final devs = all.where((d) => !d.isInventory).toList();
      final inv  = all.where((d) =>  d.isInventory).toList();

      // تحديث كامل: الأجهزة + المخزون (مهم للديلر) + cache دافئ
      if (all.isNotEmpty) {
        _devices   = devs;
        _inventory = inv;
        if (_selectedDevice != null) {
          final match = _devices.where((d) => d.id == _selectedDevice!.id);
          if (match.isNotEmpty) _selectedDevice = match.first;
        }
        _updateDashStats();
        // ملاحظة: لا نلمس العدّاد هنا — الـ timer هو المتحكّم الوحيد فيه (يمنع
        // قفز العدّاد لو تأخّر الجلب). هنا نحدّث البيانات والموقع فقط عند وصولها.
        notifyListeners();
      }

      // refresh user data every 5 minutes (30 cycles × 10s)
      _userRefreshCounter++;
      if (_userRefreshCounter >= 30) {
        _userRefreshCounter = 0;
        await refreshUser();
      }
      // مزامنة قائمة العملاء دورياً (كل ~20ث) — عشان تغييرات الويب على العملاء
      // تظهر على الموبايل بدون إعادة فتح التاب (للمزوّدين فقط). يحدّث القائمة فقط
      // (شاشة تفاصيل العميل تستخدم نسخة widget.user فلا تتأثر).
      _clientsRefreshCounter++;
      if (_clientsRefreshCounter >= 2 && _currentUser?.isClient != true) {
        _clientsRefreshCounter = 0;
        unawaited(loadUsers());
      }
    } catch (_) {
      // silent
    }
  }

  int _clientsRefreshCounter = 0;

  Future<void> refreshUser() async {
    try {
      final result = await ApiService.request('get_profile', {});
      if (result['success'] == true && result['user'] != null) {
        _currentUser = UserModel.fromJson(result['user'] as Map<String, dynamic>);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_data', jsonEncode(result['user']));
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> manualRefresh() async {
    _refreshCountdown = 10;
    // تحديث شامل: الأجهزة + المخزون + إحصائيات الداشبورد (مش silent فقط)
    await loadDevices();
  }

  // عرض فوري لأحدث مواقع الـ WS المخزّنة (الضغط اليدوي على زر العدّاد) + إعادة العدّاد لـ10.
  // ⚠️ مفيش نداء شبكة — الـ WS بالفعل خازن أحدث المواقع في كائنات الأجهزة؛ إحنا بس
  // بنعيد بناء الماركرات دلوقتي (تبديل مرجع القوائم) بدل انتظار العد 0. فوري تمامًا.
  void showLiveNow() {
    _devices = List.of(_devices);
    _inventory = List.of(_inventory);
    _refreshCountdown = 10;
    notifyListeners();
    // + جلب أطزج بيانات من السيرفر في الخلفية (لو الـ WS متأخر/مفصول) — يتعرض أول ما يوصل
    _silentRefresh();
  }

  // إعادة العدّاد لـ10 فقط (لخريطة view_as — الضغط اليدوي يرجّع العد بدون لمس أجهزة الحساب الرئيسي)
  void resetCountdown() {
    _refreshCountdown = 10;
    notifyListeners();
  }

  // ─── App Lifecycle ─────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isLoggedIn) {
        _refreshOnResume();
      }
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive) {
      // App going to background - stop timer + live socket to save battery
      _stopRefreshTimer();
      _disconnectLiveWs();
    }
  }

  // عند رجوع التطبيق من الخلفية: اعرض علامة تحميل واضحة (isResuming) واجلب بيانات
  // جديدة فوراً بدل عرض الكاش القديم حتى الدورة التالية. يُطفأ الـ flag عند وصول
  // البيانات (أو فشل الجلب) فتظهر البيانات الحقيقية.
  // يزيد بعد اكتمال تحديث الرجوع من الخلفية — الخريطة تسمعه وتحرّك الكاميرا
  // تلقائياً على مكان الماركر الجديد (popup مفتوح → جهازه، غير كده → كل الأجهزة)
  int _resumeSeq = 0;
  int get resumeSeq => _resumeSeq;

  Future<void> _refreshOnResume() async {
    _resuming = true;
    ApiService.resetClient(); // اقفل اتصالات keep-alive اللي بوظت أثناء الخلفية → الجلب التالي اتصال جديد (يمنع تعليق 30ث)
    _connectLiveWs(); // وصّل الـ WS فوراً بالتوازي مع الجلب — المواقع الحيّة تبدأ أبكر
    notifyListeners();
    try {
      await _silentRefresh();       // يجلب أحدث الأجهزة ويحدّث الخريطة (السريع/المهم)
    } finally {
      _resuming = false;            // اطفِ علامة التحميل بمجرد وصول بيانات الأجهزة
      _resumeSeq++;                 // أعلن اكتمال تحديث الرجوع → الكاميرا تتبع الماركر
      notifyListeners();
    }
    // بيانات المستخدم ثانوية — تشتغل في الخلفية بدون ما تأخّر علامة التحميل
    refreshUser();
    _startRefreshTimer();
  }

  void clearError() { _error = null; notifyListeners(); }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRefreshTimer();
    _disconnectLiveWs();
    super.dispose();
  }
}
