import '../services/i18n.dart';

class DeviceModel {
  final int id;
  final int traccarId;
  final String name;
  final String imei;
  final String iccid;
  final String simPhone;
  final String deviceType;
  // الحقول الحيّة قابلة للتحديث من الـ WebSocket relay (مواقع لحظية)
  String status;
  double? lat;
  double? lng;
  double? speed;
  final double? battery;
  double? course;
  final bool powerConnected;
  bool ignition;
  /// المحرك يعمل والمركبة واقفة بلا حركة ≥ دقيقتين (يحسبها السيرفر) — ماركر أصفر
  bool idle;
  final bool charge;
  DateTime? lastUpdate;   // آخر حركة (للـ header «متوقف منذ»)
  DateTime? lastSeen;     // آخر إرسال بيانات حقيقي (أي packet، حتى وقوف)
  final DateTime? lastMove;
  final DateTime? lastIgnitionOff;
  final DateTime? lastIgnitionOn;
  final int? userId;
  final String? userName;
  final String? subscriptionType;
  final DateTime? subscriptionEnd;
  final DateTime? activatedAt;
  final bool isInventory;
  final String icon;
  // non-final: تُحدَّث فورياً (optimistic) بعد حفظ التنبيهات في _EditDeviceSheet
  // عشان إعادة فتح الشيت تعرض القيم الجديدة بدون انتظار loadDevices
  int alertEngineOn;
  int alertEngineOff;
  int alertOverspeed;
  int alertIdle;
  int alertNoSignal;
  int alertParking;
  int alertDoor;
  int alertPowerCut;
  int alertLowBattery;
  int alertSos;
  int alertGeofence;
  int alertTowing;
  int alertHarshBrake;
  int alertHarshAccel;
  int speedLimit;

  DeviceModel({
    required this.id, required this.traccarId, required this.name,
    required this.imei, this.iccid = '', this.simPhone = '',
    required this.deviceType, required this.status,
    this.lat, this.lng, this.speed, this.battery, this.course,
    this.powerConnected = false, this.ignition = false, this.idle = false, this.charge = false,
    this.lastUpdate, this.lastSeen, this.lastMove, this.lastIgnitionOff, this.lastIgnitionOn,
    this.userId, this.userName,
    this.subscriptionType, this.subscriptionEnd, this.activatedAt, this.isInventory = false,
    this.icon = 'car',
    this.alertEngineOn = 1, this.alertEngineOff = 1, this.alertOverspeed = 1,
    this.alertIdle = 0, this.alertNoSignal = 0, this.alertParking = 0,
    this.alertDoor = 0, this.alertPowerCut = 1, this.alertLowBattery = 0,
    this.alertSos = 1, this.alertGeofence = 0, this.alertTowing = 0,
    this.alertHarshBrake = 0, this.alertHarshAccel = 0, this.speedLimit = 100,
  });

  static final Map<int, bool> _ignCache = {};

  factory DeviceModel.fromJson(Map<String, dynamic> j) {
    final id = int.tryParse(j['id']?.toString() ?? '0') ?? 0;
    final rawIgn = j['ignition'];
    if (rawIgn != null) _ignCache[id] = rawIgn == true || rawIgn == 1;
    return DeviceModel(
      id: id,
      traccarId: int.tryParse(j['traccar_id']?.toString() ?? j['traccarId']?.toString() ?? '0') ?? 0,
      name: j['name'] ?? '',
      imei: j['imei'] ?? j['uniqueId'] ?? '',
      iccid: j['iccid'] ?? '',
      simPhone: j['sim_phone'] ?? j['phone'] ?? '',
      deviceType: j['device_type'] ?? j['deviceType'] ?? j['model'] ?? 'GT06N',
      status: j['status'] ?? 'offline',
      lat: j['lat'] != null ? double.tryParse(j['lat'].toString())
          : j['latitude'] != null ? double.tryParse(j['latitude'].toString()) : null,
      lng: j['lng'] != null ? double.tryParse(j['lng'].toString())
          : j['longitude'] != null ? double.tryParse(j['longitude'].toString()) : null,
      speed: j['speed'] != null ? double.tryParse(j['speed'].toString()) : null,
      course: j['course'] != null ? double.tryParse(j['course'].toString()) : null,
      battery: j['battery'] != null ? double.tryParse(j['battery'].toString()) : null,
      powerConnected: j['power_connected'] == true || j['power_connected'] == 1 ||
                      (j['power'] != null && (j['power'] is num) && (j['power'] as num) > 10),
      ignition: _ignCache[id] ?? false,
      idle: j['idle'] == true || j['idle'] == 1,
      charge: j['charge'] == true || j['charge'] == 1,
      lastUpdate: j['last_update'] != null ? DateTime.tryParse(j['last_update'])
          : j['lastUpdate'] != null ? DateTime.tryParse(j['lastUpdate']) : null,
      lastSeen: j['last_seen'] != null ? DateTime.tryParse(j['last_seen'])
          : j['lastSeen'] != null ? DateTime.tryParse(j['lastSeen']) : null,
      lastMove: j['last_move'] != null ? DateTime.tryParse(j['last_move']) : null,
      lastIgnitionOff: j['lastIgnitionOff'] != null ? DateTime.tryParse(j['lastIgnitionOff']) : null,
      lastIgnitionOn: j['lastIgnitionOn'] != null ? DateTime.tryParse(j['lastIgnitionOn']) : null,
      userId: j['user_id'] != null ? int.tryParse(j['user_id'].toString()) : null,
      userName: j['owner_name'] ?? j['user_name'] ?? j['username'],
      subscriptionType: j['card_type'] ?? j['subscription_type'],
      subscriptionEnd: j['expiry_date'] != null ? DateTime.tryParse(j['expiry_date']) : j['subscription_end'] != null ? DateTime.tryParse(j['subscription_end']) : null,
      activatedAt: j['activated_at'] != null ? DateTime.tryParse(j['activated_at']) : null,
      isInventory: j['user_id'] == null || j['user_id'] == 0 || j['is_inventory'] == true || j['is_inventory'] == 1,
      icon: j['icon'] ?? 'car',
      alertEngineOn: int.tryParse(j['alert_engine_on']?.toString() ?? '0') ?? 0,
      alertEngineOff: int.tryParse(j['alert_engine_off']?.toString() ?? '0') ?? 0,
      alertOverspeed: int.tryParse(j['alert_overspeed']?.toString() ?? '0') ?? 0,
      alertIdle: int.tryParse(j['alert_idle']?.toString() ?? '0') ?? 0,
      alertNoSignal: int.tryParse(j['alert_no_signal']?.toString() ?? '0') ?? 0,
      alertParking: int.tryParse(j['alert_parking']?.toString() ?? '0') ?? 0,
      alertDoor: int.tryParse(j['alert_door']?.toString() ?? '0') ?? 0,
      alertPowerCut: int.tryParse(j['alert_power_cut']?.toString() ?? '0') ?? 0,
      alertLowBattery: int.tryParse(j['alert_low_battery']?.toString() ?? '0') ?? 0,
      alertSos: int.tryParse(j['alert_sos']?.toString() ?? '0') ?? 0,
      alertGeofence: int.tryParse(j['alert_geofence']?.toString() ?? '0') ?? 0,
      alertTowing: int.tryParse(j['alert_towing']?.toString() ?? '0') ?? 0,
      alertHarshBrake: int.tryParse(j['alert_harsh_brake']?.toString() ?? '0') ?? 0,
      alertHarshAccel: int.tryParse(j['alert_harsh_accel']?.toString() ?? '0') ?? 0,
      speedLimit: int.tryParse(j['speed_limit']?.toString() ?? '100') ?? 100,
    );
  }

  bool get isOnline => status == 'online' || status == 'moving';
  bool get isMoving => status == 'moving' || (isOnline && (speed ?? 0) > 0.5);
  bool get isOffline => status == 'offline';
  bool get isInactive => status == 'inactive';

  String get speedKmh {
    if (speed == null) return '0 ${tr('m_kmh')}';
    // السيرفر بيبعت km/h مباشرة (بعد تحويل knots × 1.852)
    return '${speed!.toStringAsFixed(0)} ${tr('m_kmh')}';
  }

  String get batteryDisplay => battery == null ? '-' : '${battery!.toStringAsFixed(0)}%';

  String get statusAr {
    switch (status) {
      case 'moving': return tr('m_st_moving');
      case 'online': return tr('m_st_stopped');
      case 'inactive': return tr('m_st_inactive');
      default: return tr('m_st_offline');
    }
  }
}

class UserModel {
  final int id;
  final String username;
  final String fullName;
  final String accountType;
  final String? phone;
  final String? mobile;
  final String? email;
  final String? address;
  final String? avatar;
  final int? dealerId;
  final int? parentId;
  final int? traccarId;
  final bool isActive;
  final bool viewOnly;
  final int deviceCount;
  final int clientCount;
  final DateTime? createdAt;

  const UserModel({
    required this.id, required this.username, required this.fullName,
    required this.accountType, this.phone, this.mobile, this.email,
    this.address, this.avatar, this.dealerId, this.parentId, this.traccarId,
    this.isActive = true, this.viewOnly = false,
    this.deviceCount = 0, this.clientCount = 0, this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> j) {
    return UserModel(
      id: int.tryParse(j['id']?.toString() ?? '0') ?? 0,
      // API returns 'name' not 'username' in login response
      username: j['username'] ?? j['name'] ?? '',
      fullName: j['full_name'] ?? j['name'] ?? '',
      accountType: j['account_type'] ?? j['role'] ?? 'client',
      phone: j['phone'],
      mobile: j['mobile'],
      email: j['email_contact'] ?? j['email'],
      address: j['address'],
      avatar: j['avatar'],
      dealerId: j['dealer_id'] != null ? int.tryParse(j['dealer_id'].toString()) : null,
      parentId: j['parent_id'] != null ? int.tryParse(j['parent_id'].toString()) : null,
      traccarId: j['traccar_id'] != null ? int.tryParse(j['traccar_id'].toString()) : null,
      isActive: j['status'] == 'active' || j['is_active'] == 1 || j['administrator'] == true,
      viewOnly: j['view_only'] == 1 || j['view_only'] == true,
      deviceCount: int.tryParse(j['device_count']?.toString() ?? '0') ?? 0,
clientCount: int.tryParse(j['client_count']?.toString() ?? '0') ?? 0,
      createdAt: (j['createdAt'] ?? j['created_at']) != null ? DateTime.tryParse((j['createdAt'] ?? j['created_at']).toString()) : null,
    );
  }

  bool get isAdmin => accountType == 'admin';
  bool get isDealer => accountType == 'dealer';
  bool get isSubDealer => accountType == 'sub_dealer';
  bool get isClient => accountType == 'client';

  String get accountTypeAr {
    switch (accountType) {
      case 'admin': return tr('role_admin');
      case 'dealer': return tr('tab_dealer');
      case 'sub_dealer': return tr('tab_subdealer');
      default: return tr('tab_client');
    }
  }

  String get initials {
    if (fullName.isEmpty) return username.isNotEmpty ? username[0].toUpperCase() : 'U';
    final parts = fullName.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return fullName[0].toUpperCase();
  }

  // حرف واحد فقط (للأفاتار في قائمة العملاء لو مفيش صورة)
  String get firstLetter {
    final n = fullName.trim();
    if (n.isNotEmpty) return n[0].toUpperCase();
    if (username.isNotEmpty) return username[0].toUpperCase();
    return 'U';
  }

  // Avatar full URL
  String? get avatarUrl {
    if (avatar == null || avatar!.isEmpty) return null;
    if (avatar!.startsWith('http')) return avatar;
    return 'https://himaya-track.com$avatar';
  }
}

class PositionModel {
  final int id;
  final int deviceId;
  final double lat;
  final double lng;
  final double speed;
  final double? course;
  final bool valid;
  final DateTime fixTime;
  final DateTime serverTime;
  final Map<String, dynamic> attributes;

  const PositionModel({
    required this.id, required this.deviceId, required this.lat, required this.lng,
    required this.speed, this.course, required this.valid,
    required this.fixTime, required this.serverTime, this.attributes = const {},
  });

  factory PositionModel.fromJson(Map<String, dynamic> j) {
    return PositionModel(
      id: int.tryParse(j['id']?.toString() ?? '0') ?? 0,
      deviceId: j['deviceId'] ?? j['device_id'] ?? 0,
      lat: double.tryParse(j['latitude']?.toString() ?? '0') ?? 0,
      lng: double.tryParse(j['longitude']?.toString() ?? '0') ?? 0,
      speed: double.tryParse(j['speed']?.toString() ?? '0') ?? 0,
      course: j['course'] != null ? double.tryParse(j['course'].toString()) : null,
      valid: j['valid'] == true || j['valid'] == 1,
      fixTime: DateTime.tryParse(j['fixTime'] ?? '') ?? DateTime.now(),
      serverTime: DateTime.tryParse(j['serverTime'] ?? '') ?? DateTime.now(),
      attributes: j['attributes'] is Map ? Map<String, dynamic>.from(j['attributes']) : {},
    );
  }

  double get speedKmh => speed * 1.852;
  bool get ignition => attributes['ignition'] == true;
  bool get powerConnected => (attributes['power'] as num? ?? 0) > 10;
}

class CardBalance {
  final int newLifetime;
  final int newSubscription;
  final int renewLifetime;
  final int renewAnnual;

  const CardBalance({
    this.newLifetime = 0, this.newSubscription = 0,
    this.renewLifetime = 0, this.renewAnnual = 0,
  });

  factory CardBalance.fromJson(Map<String, dynamic> j) {
    final b = j['balance'] ?? j;
    // السيرفر (get_card_balance) بيرجّع new_yearly/renew_yearly — نقبل الاسمين
    return CardBalance(
      newLifetime: b['new_lifetime'] ?? 0,
      newSubscription: b['new_yearly'] ?? b['new_subscription'] ?? 0,
      renewLifetime: b['renew_lifetime'] ?? 0,
      renewAnnual: b['renew_yearly'] ?? b['renew_annual'] ?? 0,
    );
  }

  int get total => newLifetime + newSubscription + renewLifetime + renewAnnual;
}

class DashboardStats {
  final int totalDevices;
  final int onlineDevices;
  final int movingDevices;
  final int offlineDevices;
  final int expiredDevices;
  final int needsActivation;
  final int totalClients;
  final int inventoryCount;
  final int inventoryOnline;
  final int inventoryOffline;
  final CardBalance cardBalance;

  const DashboardStats({
    this.totalDevices = 0, this.onlineDevices = 0, this.movingDevices = 0,
    this.offlineDevices = 0, this.expiredDevices = 0, this.needsActivation = 0,
    this.totalClients = 0, this.inventoryCount = 0, this.inventoryOnline = 0,
    this.inventoryOffline = 0, this.cardBalance = const CardBalance(),
  });

  factory DashboardStats.fromDevices(
    List<DeviceModel> devices, List<DeviceModel> inventory,
    List<UserModel> users, CardBalance cards,
  ) {
    return DashboardStats(
      totalDevices: devices.length,
      // «متصل» = كل جهاز على اتصال بالسيرفر بما فيه المتحرك، و«متحرك» عدّاد فرعي منه.
      // كانت تستثني المتحرك وحدها، بينما الفلتر الذي تفتحه وعدّاد تاب الأجهزة
      // وبروفايل الحساب كلها تعدّه — فكان الرقم يخالف القائمة التي يفتحها.
      onlineDevices: devices.where((d) => d.isOnline).length,
      movingDevices: devices.where((d) => d.isMoving).length,
      offlineDevices: devices.where((d) => d.isOffline).length,
      needsActivation: devices.where((d) => d.status == 'inactive').length,
      totalClients: users.where((u) => u.isClient || u.isSubDealer || u.isDealer).length,
      inventoryCount: inventory.length,
      inventoryOnline: inventory.where((d) => d.isOnline).length,
      inventoryOffline: inventory.where((d) => d.isOffline).length,
      cardBalance: cards,
    );
  }
}

class TripReport {
  final DateTime startTime;
  final DateTime endTime;
  final double distanceKm;
  final double maxSpeedKmh;
  final double avgSpeedKmh;
  final String startAddress;
  final String endAddress;

  const TripReport({
    required this.startTime, required this.endTime, required this.distanceKm,
    required this.maxSpeedKmh, required this.avgSpeedKmh,
    required this.startAddress, required this.endAddress,
  });

  factory TripReport.fromJson(Map<String, dynamic> j) {
    return TripReport(
      startTime: DateTime.tryParse(j['startTime'] ?? '') ?? DateTime.now(),
      endTime: DateTime.tryParse(j['endTime'] ?? '') ?? DateTime.now(),
      distanceKm: (double.tryParse(j['distance']?.toString() ?? '0') ?? 0) / 1000,
      maxSpeedKmh: (double.tryParse(j['maxSpeed']?.toString() ?? '0') ?? 0) * 1.852,
      avgSpeedKmh: (double.tryParse(j['averageSpeed']?.toString() ?? '0') ?? 0) * 1.852,
      startAddress: j['startAddress'] ?? '-',
      endAddress: j['endAddress'] ?? '-',
    );
  }

  Duration get duration => endTime.difference(startTime);
}

class EventReport {
  final String type;
  final DateTime time;
  final double lat;
  final double lng;
  final Map<String, dynamic> attributes;

  const EventReport({
    required this.type, required this.time, required this.lat, required this.lng,
    this.attributes = const {},
  });

  factory EventReport.fromJson(Map<String, dynamic> j) {
    return EventReport(
      type: j['type'] ?? '',
      time: DateTime.tryParse(j['eventTime'] ?? '') ?? DateTime.now(),
      lat: double.tryParse(j['lat']?.toString() ?? '0') ?? 0,
      lng: double.tryParse(j['lng']?.toString() ?? '0') ?? 0,
      attributes: j['attributes'] is Map ? Map<String, dynamic>.from(j['attributes']) : {},
    );
  }

  String get typeAr {
    switch (type) {
      case 'deviceOverspeed': return tr('m_ev_overspeed');
      case 'geofenceEnter': return tr('m_ev_gf_enter');
      case 'geofenceExit': return tr('m_ev_gf_exit');
      case 'ignitionOn': return tr('m_ev_ign_on');
      case 'ignitionOff': return tr('m_ev_ign_off');
      case 'deviceMoving': return tr('m_ev_moving');
      case 'deviceStopped': return tr('m_ev_stopped');
      default: return type;
    }
  }
}

