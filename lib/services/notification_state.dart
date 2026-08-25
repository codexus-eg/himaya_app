import 'package:flutter/foundation.dart';

// State مشترك لتمرير بيانات الإشعار من main.dart للشاشات
class PendingNotification {
  static int? traccarId;
  static int? deviceId;
  static String? type;
  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  static void set({int? traccar, int? device, String? type}) {
    PendingNotification.traccarId = traccar;
    PendingNotification.deviceId = device;
    PendingNotification.type = type;
    tick.value = tick.value + 1;
    debugPrint('[PendingNotif] SET tid=$traccar did=$device tick=${tick.value}');
  }

  static void clear() {
    traccarId = null;
    deviceId = null;
    type = null;
  }

  static bool get hasPending => traccarId != null || deviceId != null;

  // ── Alert detail modal routing (FCM tap → same modal as in-app) ──
  static Map<String, dynamic>? alertData;
  static final ValueNotifier<int> alertTick = ValueNotifier<int>(0);

  static void setAlert(Map<String, dynamic> data) {
    alertData = data;
    alertTick.value = alertTick.value + 1;
    debugPrint('[PendingNotif] SET ALERT ${data['type']} tick=${alertTick.value}');
  }

  static void clearAlert() => alertData = null;
}

// ── طلب الانتقال لتاب الأجهزة من الداشبورد (ون-كلك على بطاقات الحالة) ──
class TabNav {
  // الفلتر المطلوب تطبيقه على شاشة الأجهزة: all/on/off/moving/inactive
  static String? requestedDeviceFilter;
  static final ValueNotifier<int> goDevicesTick = ValueNotifier<int>(0);

  static void goDevices(String filter) {
    requestedDeviceFilter = filter;
    goDevicesTick.value = goDevicesTick.value + 1;
    debugPrint('[TabNav] goDevices filter=$filter tick=${goDevicesTick.value}');
  }

  // الفلتر المطلوب على شاشة الحسابات: all/dealer/sub/client
  static String? requestedClientFilter;
  static final ValueNotifier<int> goClientsTick = ValueNotifier<int>(0);

  static void goClients(String filter) {
    requestedClientFilter = filter;
    goClientsTick.value = goClientsTick.value + 1;
    debugPrint('[TabNav] goClients filter=$filter tick=${goClientsTick.value}');
  }

  // طلب تحديث تاب التنبيهات عند الضغط عليه (يُعيد تحميل قائمة التنبيهات)
  static final ValueNotifier<int> notifTabTick = ValueNotifier<int>(0);

  static void refreshNotifTab() {
    notifTabTick.value = notifTabTick.value + 1;
  }
}
