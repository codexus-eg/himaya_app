import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'i18n.dart';

class ApiService {
  static const String baseUrl = 'https://himaya-track.com/api.php';
  static const int timeoutSeconds = 30;

  // Client مشترك = keep-alive: بيوفّر TCP+TLS handshake جديد (~200-500ms على
  // شبكة الموبايل) في كل طلب. الاتصال بيفضل دافي بين دورات الـ polling (10ث).
  static http.Client _client = http.Client();

  // يعيد إنشاء الـ HTTP client (يقفل اتصالات keep-alive القديمة). ضروري على الموبايل
  // لأن الاتصالات بتبوظ عند تبديل الشبكة/الرجوع من الخلفية فتسبّب تعليق الطلبات
  // لحد الـ timeout (تأخير 30ث-2د في تحديث الخريطة). reset = الطلب التالي اتصال جديد.
  static void resetClient() {
    try { _client.close(); } catch (_) {}
    _client = http.Client();
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  static Future<String?> getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('refresh_token');
  }

  static Future<void> saveTokens({required String token, required String refreshToken}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('refresh_token', refreshToken);
  }

  static Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('refresh_token');
    await prefs.remove('user_data');
  }

  // ─── Core Request ──────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _request({
    required String action,
    Map<String, dynamic>? body,
    bool requiresAuth = true,
    bool isRetry = false,
    int? timeout,
  }) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

      if (requiresAuth) {
        final token = await getToken();
        if (token == null) return {'success': false, 'error': tr('api_unauthorized'), 'code': 401};
        headers['Authorization'] = 'Bearer $token';
      }

      final payload = {'action': action, ...?body};
      final response = await _client
          .post(Uri.parse(baseUrl), headers: headers, body: jsonEncode(payload))
          .timeout(Duration(seconds: timeout ?? timeoutSeconds));

      // Handle raw List response - wrap it
      final decoded = jsonDecode(response.body);
      if (decoded is List) {
        return {'success': true, 'data': decoded};
      }
      final data = decoded as Map<String, dynamic>;

      // A 401 on an authenticated request = expired/invalid token → try refresh,
      // else session expired. But on a NON-auth request (login / verify_2fa /
      // refresh_token) a 401 means "wrong credentials" — pass the server's real
      // error through instead of the misleading "session expired" message.
      if (response.statusCode == 401 && requiresAuth && !isRetry) {
        final refreshed = await _refreshToken();
        if (refreshed) {
          return _request(action: action, body: body, requiresAuth: requiresAuth, isRetry: true, timeout: timeout);
        }
        await clearTokens();
        return {'success': false, 'error': tr('api_session_exp'), 'code': 401};
      }

      return data;
    } on SocketException {
      resetClient(); // اتصال ميت → اعمل client جديد للطلب التالي
      return {'success': false, 'error': tr('api_no_internet')};
    } on HttpException {
      return {'success': false, 'error': tr('api_server_err')};
    } on FormatException {
      return {'success': false, 'error': tr('api_format_err')};
    } on TimeoutException {
      resetClient(); // الطلب علّق على اتصال keep-alive بايظ → اقفل الـ pool
      return {'success': false, 'error': tr('api_timeout')};
    } catch (e) {
      debugPrint('API Error [$action]: $e');
      return {'success': false, 'error': tr('api_unexpected')};
    }
  }

  static Future<bool> _refreshToken() async {
    try {
      final refresh = await getRefreshToken();
      if (refresh == null) return false;
      final response = await _client.post(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'action': 'refresh_token', 'refresh_token': refresh}),
      ).timeout(const Duration(seconds: timeoutSeconds));
      final data = jsonDecode(response.body);
      if (data is Map && data['success'] == true && data['token'] != null) {
        await saveTokens(token: data['token'], refreshToken: data['refresh_token'] ?? refresh);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ─── Auth ──────────────────────────────────────────────────────────────────

  // طراز الهاتف كما يعرفه صاحبه — بدونه تظهر كل الجلسات باسم واحد فلا يميّز
  // صاحب الحساب أيّها جهازه. يُقرأ مرة واحدة ويُحفظ.
  static String? _deviceName;
  static Future<String> deviceName() async {
    if (_deviceName != null) return _deviceName!;
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        _deviceName = '${a.brand} ${a.model}'.trim();
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        _deviceName = i.name.isNotEmpty ? i.name : i.utsname.machine;
      }
    } catch (_) {}
    _deviceName ??= 'تطبيق الموبايل';
    return _deviceName!;
  }

  // معرّف ثابت لكل تثبيت — بدونه كل دخول يُسجَّل «جهازًا جديدًا» في قائمة الأجهزة
  // الداخلة، فيمتلئ حساب صاحبه بعشرات الصفوف وهي هاتف واحد. لا يُشتق من عتاد
  // الجهاز (لا نحتاجه ولا نريد تتبّعه) — رقم عشوائي يُولَّد مرة ويبقى مع التطبيق.
  static String? _deviceId;
  static Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('himaya_device_id');
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString('himaya_device_id', id);
    }
    _deviceId = id;
    return id;
  }

  static Future<Map<String, dynamic>> login({required String username, required String password}) async {
    final result = await _request(
      action: 'login',
      body: {
        'username': username,
        'password': password,
        'device_name': await deviceName(),
        'device_id': await deviceId(),
      },
      requiresAuth: false,
    );
    if (result['success'] == true) {
      await saveTokens(token: result['token'], refreshToken: result['refresh_token']);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_data', jsonEncode(result['user']));
    }
    return result;
  }

  // Two-factor (admin): verify the Telegram OTP and obtain the real token.
  static Future<Map<String, dynamic>> verifyTwoFactor({required String challenge, required String code}) async {
    final result = await _request(
      action: 'verify_2fa',
      body: {
        'challenge': challenge,
        'code': code,
        'device_name': await deviceName(),
        'device_id': await deviceId(),
      },
      requiresAuth: false,
    );
    if (result['success'] == true) {
      await saveTokens(token: result['token'], refreshToken: result['refresh_token']);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_data', jsonEncode(result['user']));
    }
    return result;
  }

  // تغيير كلمة المرور (يستخدم التوكن الحالي)
  static Future<Map<String, dynamic>> changePassword(String newPassword, {String? oldPassword}) async {
    return _request(action: 'change_password', body: {
      'newPassword': newPassword,
      if (oldPassword != null && oldPassword.isNotEmpty) 'oldPassword': oldPassword,
    });
  }

  // إعادة/تعيين كلمة مرور مستخدم تابع (الديلر = مزوّد الخدمة). بدون newPassword = افتراضي 123456.
  static Future<Map<String, dynamic>> resetPassword({required int userId, String? newPassword}) async {
    return _request(action: 'reset_password', body: {
      'userId': userId,
      if (newPassword != null && newPassword.isNotEmpty) 'newPassword': newPassword,
    });
  }

  // Public wrapper for any API action
  static Future<Map<String, dynamic>> request(String action, [Map<String, dynamic>? body]) async {
    return _request(action: action, body: body);
  }

  static Future<Map<String, dynamic>> verifyPassword(String password) async {
    return _request(action: 'verify_password', body: {'password': password});
  }

  static Future<Map<String, dynamic>> getMe() async => _request(action: 'me');
  static Future<Map<String, dynamic>> logout() async {
    // Send THIS device's FCM token so the server removes only this device's
    // token (multi-mobile push): logout on one phone must not stop push on the
    // user's other phones. Without it the server falls back to deleting ALL of
    // the user's tokens.
    String? fcmToken;
    try {
      fcmToken = await FirebaseMessaging.instance.getToken();
    } catch (_) {}
    final result = await _request(
      action: 'logout',
      body: (fcmToken != null) ? {'fcm_token': fcmToken} : null,
    );
    await clearTokens();
    return result;
  }
  static Future<Map<String, dynamic>> validateToken() async {
  final result = await _request(action: 'validate_token');
  // API returns {"valid": true/false} - normalize to {"success": true/false}
  if (result.containsKey('valid')) {
    return {'success': result['valid'] == true, ...result};
  }
  return result;
}

  // ─── Devices ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getDevices({int? viewAs}) async {
    // timeout قصير للبولينج المتكرر: لو الاتصال علّق (شبكة الموبايل)، يفشل بسرعة
    // ويعيد إنشاء الـ client، فالدورة التالية تلحق التحديث بدل انتظار 30ث.
    return _request(action: 'devices', body: viewAs != null ? {'view_as': viewAs} : null, timeout: 12);
  }

  static Future<Map<String, dynamic>> getDealerDevices() async => _request(action: 'get_dealer_devices');
  static Future<Map<String, dynamic>> getDeviceCount() async => _request(action: 'get_device_count');

  // ─── Command history ─────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> logCommand({required int deviceId, required String cmdType, String cmdText = '', required String status, String result = ''}) async {
    return _request(action: 'log_command', body: {'deviceId': deviceId, 'cmd_type': cmdType, 'cmd_text': cmdText, 'status': status, 'result': result});
  }
  static Future<Map<String, dynamic>> getCommandHistory(int deviceId) async {
    return _request(action: 'get_command_history', body: {'deviceId': deviceId});
  }

  static Future<Map<String, dynamic>> addDevice({
    required String imei,
    required String name,
    required String deviceType,
    required int userId,
    required String subscriptionType,
    String? notes,
  }) async {
    return _request(action: 'add_device', body: {
      'imei': imei, 'name': name, 'device_type': deviceType,
      'user_id': userId, 'subscription_type': subscriptionType,
      if (notes != null) 'notes': notes,
    });
  }

  static Future<Map<String, dynamic>> updateDevice({required int deviceId, required Map<String, dynamic> updates}) async {
    return _request(action: 'update_device', body: {'device_id': deviceId, ...updates});
  }

  static Future<Map<String, dynamic>> deleteDevice(int deviceId) async {
    return _request(action: 'delete_device', body: {'device_id': deviceId});
  }

  static Future<Map<String, dynamic>> changeImei({
    required String oldImei, required String newImei, required String deviceType,
  }) async {
    return _request(action: 'update_device', body: {
      'old_imei': oldImei, 'new_imei': newImei, 'device_type': deviceType,
    });
  }

  // ─── Positions ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getPositions({List<int>? deviceIds}) async {
    return _request(action: 'positions', body: deviceIds != null ? {'device_ids': deviceIds} : null);
  }

  // ─── Users ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getUsers({String? role}) async {
    return _request(action: 'get_users', body: role != null ? {'role': role} : null);
  }

  static Future<Map<String, dynamic>> addUser({
    required String username, required String password, required String fullName,
    required String accountType, String? timezone, String? phone, String? mobile,
    String? email, String? address, int? parentId,
  }) async {
    return _request(action: 'add_user', body: {
      'username': username, 'password': password, 'full_name': fullName,
      'account_type': accountType,
      if (timezone != null) 'timezone': timezone,
      if (phone != null) 'phone': phone,
      if (mobile != null) 'mobile': mobile,
      if (email != null) 'email': email,
      if (address != null) 'address': address,
      if (parentId != null) 'parent_id': parentId,
    });
  }

  static Future<Map<String, dynamic>> updateProfile({
    String? fullName, String? phone, String? mobile, String? email, String? address, String? avatar,
  }) async {
    return _request(action: 'update_profile', body: {
      if (fullName != null) 'full_name': fullName,
      if (phone != null) 'phone': phone,
      if (mobile != null) 'mobile': mobile,
      if (email != null) 'email': email,
      if (address != null) 'address': address,
      if (avatar != null) 'avatar': avatar,
    });
  }

  static Future<Map<String, dynamic>> updateUser({required int userId, required Map<String, dynamic> updates}) async {
    return _request(action: 'update_user', body: {'user_id': userId, ...updates});
  }

  static Future<Map<String, dynamic>> toggleUser(int userId) async {
    return _request(action: 'toggle_user', body: {'user_id': userId});
  }

  static Future<Map<String, dynamic>> deleteUser(int userId) async {
    return _request(action: 'delete_user', body: {'user_id': userId});
  }

  static Future<Map<String, dynamic>> transferAccount({required int deviceId, required int toUserId}) async {
    return _request(action: 'transfer_account', body: {'device_id': deviceId, 'to_user_id': toUserId});
  }

  // ─── Inventory ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getInventory() async => _request(action: 'get_inventory');

  static Future<Map<String, dynamic>> activateInventory({required int deviceId, required int userId}) async {
    return _request(action: 'activate_inventory', body: {'device_id': deviceId, 'user_id': userId});
  }

  // ─── Commands ─────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> sendCommand({
    required int deviceId, required String type,
    String? customText,
  }) async {
    final Map<String, dynamic> attributes = {};
    if (customText != null && customText.isNotEmpty) attributes['data'] = customText;

    final result = await _request(action: 'send_command', body: {
      'deviceId': deviceId,
      'type': type,
      if (attributes.isNotEmpty) 'attributes': attributes,
    });

    if (result['queued'] == true) {
      return {'success': true, 'queued': true, 'speed': result['speed'], 'message': result['message']};
    }
    if (result['id'] != null || result['type'] != null) {
      return {'success': true, 'message': tr('api_cmd_sent')};
    }
    return result;
  }

  static Future<Map<String, dynamic>> getSos(int deviceId) async {
    return _request(action: 'get_sos', body: {'deviceId': deviceId});
  }

  static Future<Map<String, dynamic>> saveSos({
    required int deviceId, required String phone1, String? phone2, String? phone3,
  }) async {
    return _request(action: 'save_sos', body: {
      'device_id': deviceId, 'phone1': phone1,
      if (phone2 != null) 'phone2': phone2,
      if (phone3 != null) 'phone3': phone3,
    });
  }

  // ─── Reports ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getReportTrips({
    required int deviceId, required String from, required String to, int? speedLimit,
  }) async {
    return _request(action: 'report_trips', body: {
      'device_id': deviceId, 'from': from, 'to': to,
      if (speedLimit != null) 'speed_limit': speedLimit,
    });
  }

  static Future<Map<String, dynamic>> getReportStops({
    required int deviceId, required String from, required String to,
  }) async {
    return _request(action: 'report_stops', body: {'device_id': deviceId, 'from': from, 'to': to});
  }

  static Future<Map<String, dynamic>> getReportSummary({
    required int deviceId, required String from, required String to,
  }) async {
    return _request(action: 'report_summary', body: {'device_id': deviceId, 'from': from, 'to': to});
  }

  static Future<Map<String, dynamic>> getReportEvents({
    required int deviceId, required String from, required String to, String? type,
  }) async {
    return _request(action: 'report_events', body: {
      'device_id': deviceId, 'from': from, 'to': to,
      if (type != null) 'type': type,
    });
  }

  static Future<Map<String, dynamic>> getReportRoute({
    required int deviceId, required String from, required String to,
  }) async {
    return _request(action: 'report_route', body: {'deviceId': deviceId, 'from': from, 'to': to}, timeout: 90);
  }

  // ─── Cards ────────────────────────────────────────────────────────────────

  static Future<void> saveFcmToken(String token) async {
    try {
      await _request(action: 'save_fcm_token', body: {
        'token': token,
        'device_info': 'Android',
      });
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> getCards() async => _request(action: 'get_cards');
  static Future<Map<String, dynamic>> getCardBalance({int? userId}) async => _request(action: 'get_card_balance', body: userId != null ? {'userId': userId} : null);

  static Future<Map<String, dynamic>> assignCards({
    required int toUserId,
    required String cardType,
    required int quantity,
  }) async {
    // Server expects: dealer_id, new_yearly, new_lifetime, renew_yearly, renew_lifetime
    final Map<String, String> typeMap = {
      'new_subscription': 'new_yearly',
      'new_lifetime': 'lifetime',
      'renew_annual': 'renew_yearly',
      'renew_lifetime': 'renew_lifetime',
    };
    final fieldName = typeMap[cardType] ?? cardType;
    return _request(action: 'assign_cards', body: {
      'dealer_id': toUserId,
      fieldName: quantity,
    });
  }

  static Future<Map<String, dynamic>> activateCard({required String cardCode, required int deviceId}) async {
    return _request(action: 'activate_card', body: {'card_code': cardCode, 'device_id': deviceId});
  }

  // ─── Geofences ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getGeofences() async => _request(action: 'geofences');

  static Future<Map<String, dynamic>> getDeviceGeofences(int deviceId) async {
    return _request(action: 'device_geofences', body: {'device_id': deviceId});
  }

  static Future<Map<String, dynamic>> addGeofence({required String name, required String area, String? color}) async {
    return _request(action: 'add_geofence', body: {'name': name, 'area': area, if (color != null) 'color': color});
  }

  static Future<Map<String, dynamic>> linkDeviceGeofence({required int deviceId, required int geofenceId}) async {
    return _request(action: 'link_device_geofence', body: {'device_id': deviceId, 'geofence_id': geofenceId});
  }

  static Future<Map<String, dynamic>> deleteGeofence(int geofenceId) async {
    return _request(action: 'delete_geofence', body: {'geofence_id': geofenceId});
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static Map<String, String> getDateRange(String period) {
    final now = DateTime.now();
    late DateTime from;
    late DateTime to;
    switch (period) {
      case 'hour':
        from = now.subtract(const Duration(hours: 1)); to = now;
        break;
      case 'today':
        from = DateTime(now.year, now.month, now.day); to = now;
        break;
      case 'yesterday':
        final y = now.subtract(const Duration(days: 1));
        from = DateTime(y.year, y.month, y.day);
        to = DateTime(y.year, y.month, y.day, 23, 59, 59);
        break;
      case 'week':
        from = now.subtract(const Duration(days: 7)); to = now;
        break;
      default:
        from = DateTime(now.year, now.month, now.day); to = now;
    }
    return {'from': from.toUtc().toIso8601String(), 'to': to.toUtc().toIso8601String()};
  }
}
