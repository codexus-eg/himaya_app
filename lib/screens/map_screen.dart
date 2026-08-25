import 'dart:math' as Math;
import 'package:location/location.dart' as loc;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:provider/provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../providers/app_provider.dart';
import '../models/models.dart';
import '../services/notification_state.dart';
import '../services/api_service.dart';
import '../services/i18n.dart';
import 'all_screens.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// ─── Capability-aware (protocol) ───────────────────────────────────────────
// أجهزة gps103/Coban (TK103/TK303/TK305/TK306...) بتبعت موقع+سرعة فقط — مفيش
// بطارية/كهرباء، وأوامرها النصية مختلفة عن GT06. نخفي البيانات/الأوامر غير المدعومة.
bool isGps103Model(String model) {
  final m = model.trim().toUpperCase();
  return m.startsWith('TK') || m.contains('GPS103') || m.contains('COBAN');
}

// يفتح خرائط Google على نقطة بعينها. الوجهة وحدها تُحدَّد ونقطة البداية
// يستنتجها Google من موقع المستخدم — نفس صيغة زر التنقّل في نافذة الجهاز.
// مستوى أعلى لأن شاشتَي الخريطة وعرض المسار كلتيهما تستعملانه.
void navigateToPoint(double lat, double lng) {
  launchUrl(
    Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving'),
    mode: LaunchMode.externalApplication,
  );
}

class MapScreen extends StatefulWidget {
  final List<DeviceModel>? initialDevices;
  // لما تكون الخريطة لعميل معيّن (view_as) — id العميل المعروض.
  // لو set: التحديث يجيب أجهزة العميل ده فقط، ولا يلمس أجهزة الحساب الحالي إطلاقاً.
  final int? viewAsUserId;
  const MapScreen({super.key, this.initialDevices, this.viewAsUserId});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  /// إظهار حالة «محرك يعمل والمركبة واقفة» بالأصفر — إعداد الحساب `idleEngine`،
  /// ونفسه يسري على الويب. من أطفأه يرى السلوك القديم تمامًا.
  bool get _idleOn => context.read<AppProvider>().idleMarkerEnabled;

  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  bool _cameraMoving = false;       // الكاميرا بتتحرك حاليًا (تفاعل مستخدم أو حركة برمجية)
  bool _progCam = false;            // آخر حركة كاميرا كانت برمجية (متابعة) — مش تفاعل مستخدم
  DateTime? _lastCamGesture;        // آخر مرة المستخدم حرّك/زوّم الخريطة بإيده (grace للتتبع)
  final Map<int, LatLng> _lastMarkerPos = {};    // آخر موقع معروض لكل جهاز (forward-only ضد التذبذب)
  final Map<int, DateTime> _lastMarkerTime = {}; // وقت آخر موقع معروض
  MapType _mapType = MapType.normal;
  bool _showPopup = false;
  bool _measuringDistance = false;
  bool _myLocationEnabled = false;
  bool _showNames = false; // إظهار أسماء الأجهزة فوق الماركرات (زر T)
  // آخر اتجاه (course) معروف لكل جهاز — يفضّل الماركر عليه حتى بعد التوقف (زي iTrack)
  final Map<int, double> _lastHeading = {};
  final List<LatLng> _measurePoints = [];
  DeviceModel? _popupDevice;
  List<DeviceModel> _devices = [];
  int _selectedIndex = 0;

  static const _defaultCameraPos = CameraPosition(
    target: LatLng(30.0444, 31.2357), // Cairo
    zoom: 11,
  );

  void _onPendingNotification() {
    if (!mounted) return;
    _showDeviceFromNotification();
  }

  Future<void> _showDeviceFromNotification() async {
    final tid = PendingNotification.traccarId;
    final did = PendingNotification.deviceId;
    if (tid == null && did == null) return;
    debugPrint('[MAP] showDeviceFromNotif tid=$tid did=$did devices=${_devices.length}');

    // Force load devices إذا فاضي
    if (_devices.isEmpty) {
      final provider = context.read<AppProvider>();
      await provider.loadDevices();
      if (!mounted) return;
      final user = provider.currentUser;
      _devices = (user?.isDealer == true || user?.isSubDealer == true)
          ? provider.inventory : provider.devices;
    }

    int retries = 0;
    while (_devices.isEmpty && retries < 30 && mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
      retries++;
    }
    if (!mounted) return;
    if (_devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('map_devices_not_loaded'), style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: Color(0xFFC41E3A),
      ));
      return;
    }

    DeviceModel? target;
    for (final d in _devices) {
      if (tid != null && (d.id == tid || d.traccarId == tid)) { target = d; break; }
    }
    debugPrint('[MAP] target found=${target != null} name=${target?.name} ids=${_devices.map((d)=>"${d.id}/${d.traccarId}").toList()}');

    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('map_device_not_found', {'id': '$tid'}), style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: const Color(0xFFC41E3A),
      ));
      PendingNotification.clear();
      return;
    }

    setState(() {
      _popupDevice = target;
      _showPopup = true;
      final idx = _devices.indexOf(target!);
      if (idx >= 0) _selectedIndex = idx;
    });
    if (target.lat != null && target.lng != null && _mapController != null) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(target.lat!, target.lng!), 15),
      );
    }
    PendingNotification.clear();
  }

  @override
  void initState() {
    super.initState();
    // ابدأ من قيمة الـ provider الحالية عشان مانعملش recenter زائف أول build
    _lastResumeSeq = context.read<AppProvider>().resumeSeq;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPositions());
    // listen for notification taps
    PendingNotification.tick.addListener(_onPendingNotification);
    // handle pending notification on screen init (terminated state)
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDeviceFromNotification());
    // الـ provider هو المسؤول عن جلب البيانات كل 10 ثواني (مربوط بالعد التنازلي).
    // هذا الـ timer يقرأ أحدث بيانات الـ provider فقط (بدون جلب مكرر) ويعيد بناء
    // الـ markers + يزامن الـ popup — لضمان تحديث مواقع الأجهزة المتحركة كل دورة.
    // عداد كل ثانية: يحدّث نص "متوقف/مغلق منذ ..." في الموديل ليعد بالثواني فوراً
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // خريطة العميل (view_as): نعيد البناء كل ثانية عشان العدّاد يعدّ + نكشف وصوله لـ0
      // (التحديث مربوط بالعد زي الخريطة الرئيسية). الرئيسية بتعيد البناء عبر watch.
      // الـ popup لتحديث نص «متوقف/مغلق منذ ...».
      if (widget.initialDevices != null || (_showPopup && _popupDevice != null)) setState(() {});
    });
    // ملاحظة: بناء الماركر ومزامنة الـ popup يتمّان في مسار build() (عند تغيّر
    // مرجع قائمة الـ provider = لحظة وصول البيانات الجديدة بالظبط). كان فيه
    // إعادة بناء مكرّرة هنا بمؤقت مستقل بدأ في وقت مختلف عن مؤقت الـ provider،
    // فينتج فرق طور (~٥ث) يخلّي الماركر يتحرك في منتصف العدّ بدل انتهائه. أُزيلت
    // ليتحرك الماركر لحظة وصول البيانات (انتهاء العدّ) فقط. يبقى هنا fallback التنبيه.
    _mapTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      // ملاحظة: تحديث أجهزة view_as بقى مربوطاً بوصول العدّاد لـ0 في build (مزامنة مع
      // الخريطة الرئيسية — الماركر يتحرك عند نهاية العد بالظبط)، مش على هذا المؤقت المستقل.
      // fallback: استهلك أي PendingNotification معلّق
      if (PendingNotification.traccarId != null || PendingNotification.deviceId != null) {
        _showDeviceFromNotification();
      }
    });
  }

  @override
  void dispose() {
    PendingNotification.tick.removeListener(_onPendingNotification);
    _mapTimer?.cancel();
    _tickTimer?.cancel();
    _playbackTimer?.cancel();
    _zoomAnimTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPositions() async {
    if (widget.initialDevices != null) {
      // أول ظهور لخريطة العميل (view_as): اعرض الـ snapshot (جاي طازج من getDevices(viewAs)
      // وقت فتح البروفايل → lastUpdate/lastIgnition صح)، ثم _refreshScopedDevices يحدّث فورًا.
      // ⚠️ مانستخدمش provider.devices (بتاعة الديلر) — الميتاداتا فيها (آخر حركة/آخر تشغيل محرك)
      // قديمة على خريطة العميل لأن الـ WS بيحدّث الموقع بس مش الميتاداتا.
      _devices = widget.initialDevices!;
      _buildMarkers(_devices);
      _scheduleFitBounds();
      if (widget.viewAsUserId != null) _refreshScopedDevices();
      return;
    }
    final provider = context.read<AppProvider>();

    // 1) اعرض ما هو موجود في provider فوراً (cached من init/splash)
    final user = provider.currentUser;
    final cached = (user?.isDealer == true || user?.isSubDealer == true)
        ? provider.inventory : provider.devices;
    if (cached.isNotEmpty) {
      _devices = cached;
      _buildMarkers(_devices);
      _scheduleFitBounds();
    }

    // 2) شغّل تحديث في الخلفية (مش بنستنى عليه قبل ما الخريطة تظهر)
    provider.loadDevices().then((_) {
      if (!mounted) return;
      final u = provider.currentUser;
      final fresh = (u?.isDealer == true || u?.isSubDealer == true)
          ? provider.inventory : provider.devices;
      if (fresh.isNotEmpty) {
        _devices = fresh;
        _buildMarkers(fresh);
        if (cached.isEmpty) _scheduleFitBounds();
      }
    });
  }

  // تحديث أجهزة العميل المعروض فقط (view_as) — مفلتر على السيرفر بـ view_as.
  // يُستخدم في خريطة بروفايل العميل بدل سحب أجهزة الحساب الحالي (اللي بيسرّب
  // أجهزة حسابات تانية للأدمن لأنه بيشوف الكل).
  Future<void> _refreshScopedDevices() async {
    if (widget.viewAsUserId == null) return;
    try {
      final result = await ApiService.getDevices(viewAs: widget.viewAsUserId);
      // ⚠️ لو فشل الاستدعاء raw=null → سيب القايمة القديمة (ماتفضّيش الخريطة).
      final raw = result['data'] ?? result['devices'] ?? result['items'];
      if (!mounted || raw is! List) return;
      final fresh = raw.map((d) => DeviceModel.fromJson(d as Map<String, dynamic>)).toList();
      if (fresh.isEmpty) return; // العميل مالوش أجهزة → سيب اللي معروض (نادر)
      _devices = fresh;
      // زامن الموديل المفتوح مع البيانات الجديدة
      if (_showPopup && _popupDevice != null) {
        final match = fresh.where((d) => d.id == _popupDevice!.id);
        if (match.isNotEmpty && !identical(match.first, _popupDevice)) {
          setState(() => _popupDevice = match.first);
        } else if (match.isEmpty) {
          setState(() { _showPopup = false; _popupDevice = null; });
        }
      }
      _buildMarkers(fresh);
    } catch (_) {}
  }

  bool _didFitBounds = false;
  void _scheduleFitBounds() {
    if (_didFitBounds) return;
    _didFitBounds = true;
    // fire ASAP مع أول جهاز متاح (مش 800ms delay)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBoundsToDevices();
    });
  }

  final Map<String, BitmapDescriptor> _iconCache = {};
  final Map<int, String> _iconOverrides = {}; // deviceId ? vehicleType
  Set<Polyline> _polylines = {};

  // Playback state
  List<Map<String, dynamic>> _playbackPositions = [];
  int _playbackIdx = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  Timer? _playbackTimer;
  Timer? _mapTimer;
  Timer? _tickTimer;
  bool _showPlayback = false;

  void _buildMarkers(List<DeviceModel> devices) {
    _buildMarkersAsync(devices);
  }

  Future<BitmapDescriptor> _getCarIcon(String name, String deviceName) async {
    final cacheKey = '$name-$deviceName';
    if (_iconCache.containsKey(cacheKey)) return _iconCache[cacheKey]!;
    try {
      final url = 'https://himaya-track.com/$name';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        // رسم صورة السيارة + اسم الجهاز تحتها
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const imgSize = 96.0;
        const labelHeight = 24.0;
        const totalHeight = imgSize + labelHeight;
        const totalWidth = imgSize;

        // رسم صورة السيارة
        final codec = await ui.instantiateImageCodec(
          response.bodyBytes, targetWidth: imgSize.toInt(), targetHeight: imgSize.toInt(),
        );
        final frame = await codec.getNextFrame();
        canvas.drawImage(frame.image, Offset.zero, Paint());

        // رسم خلفية الاسم
        final bgPaint = Paint()..color = const Color(0xD0141414);
        final bgRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, imgSize, totalWidth, labelHeight),
          const Radius.circular(4),
        );
        canvas.drawRRect(bgRect, bgPaint);

        // رسم اسم الجهاز
        final tp = TextPainter(
          text: TextSpan(
            text: deviceName,
            style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.rtl,
        );
        tp.layout(maxWidth: totalWidth);
        tp.paint(canvas, Offset((totalWidth - tp.width) / 2, imgSize + (labelHeight - tp.height) / 2));

        final picture = recorder.endRecording();
        final img = await picture.toImage(totalWidth.toInt(), totalHeight.toInt());
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        if (data != null) {
          final icon = BitmapDescriptor.fromBytes(data.buffer.asUint8List());
          _iconCache[cacheKey] = icon;
          return icon;
        }
      }
    } catch (_) {}
    return BitmapDescriptor.defaultMarker;
  }

  // موقع افتراضي للأجهزة بدون موقع GPS (مركز مصر)
  static const _defaultLat = 26.8206;
  static const _defaultLng = 30.8025;
  // الأجهزة اللي «تحتاج تنشيط» (بلا موقع GPS) تتحط في البحر المتوسط (واضح إنه مكان مؤقت)
  // بدل وسط مصر، ومتباعدة ~5م عن بعض عشان تبقى واضحة عند الزوم (مش فوق بعض).
  static const _noPosBaseLat = 32.6;   // البحر المتوسط شمال مصر
  static const _noPosBaseLng = 29.5;
  static const _noPosGapDeg = 0.000045; // ~5 متر في خط العرض

  // موقع العرض للجهاز على الخريطة = الموقع الحقيقي، أو fallback مركز مصر
  // لو مفيش GPS. التنقّل والزوم يستخدموه ليشملوا كل الأجهزة (حتى بدون موقع).
  LatLng _dispPos(DeviceModel d) {
    // الكاميرا والتنقّل يتبعوا موقع الماركر المرسوم فعلاً (_lastMarkerPos = forward-only)
    // مش d.lat/lng الخام — عشان مايحصلش تضارب «الماركر اتحرك بس الكاميرا في مكان قديم».
    final mp = _lastMarkerPos[d.id];
    if (mp != null) return mp;
    if (d.lat != null && d.lng != null) return LatLng(d.lat!, d.lng!);
    // بدون GPS: الكاميرا تتبع نفس مكان الماركر (البحر) مش مركز مصر القديم
    // (يعالج التوقيت لو الكاميرا اشتغلت قبل ما _buildMarkers يحفظ _lastMarkerPos)
    return const LatLng(_noPosBaseLat, _noPosBaseLng);
  }

  Future<void> _buildMarkersAsync(List<DeviceModel> devices) async {
    if (devices.isEmpty) return;

    // الأجهزة بلا موقع («تحتاج تنشيط») تتوزّع في البحر بفارق ~5م بينها — ترتيب ثابت
    // (index) عشان كل واحد ياخد نقطة مختلفة ويبقوا واضحين عند الزوم بدل ما يتراكموا.
    int _npIdx = 0;
    final noPosOrder = <int, int>{};
    for (final d in devices) {
      if (d.lat == null || d.lng == null) noPosOrder[d.id] = _npIdx++;
    }

    // بناء الماركرات بالتوازي (بدل التسلسل) لتسريع أول رسم بعد الـ cold start
    final futures = devices.map((device) async {
      final bool hasPosition = device.lat != null && device.lng != null;
      // حد السرعة الخاص بكل جهاز (مش ثابت 100) — عشان الماركر يبقى أحمر عند تجاوز
      // الحد المضبوط للجهاز فعلاً، مطابقًا لتنبيه تجاوز السرعة.
      final speedLimit = device.speedLimit > 0 ? device.speedLimit.toDouble() : 100.0;
      final isOverSpeed = device.isMoving && (device.speed ?? 0) > speedLimit;

      // Status color — بدون موقع = رمادي دائماً
      final Color statusColor;
      if (!hasPosition)            statusColor = const Color(0xFF9E9E9E);
      else if (device.isInactive)  statusColor = const Color(0xFF9E9E9E);
      else if (isOverSpeed)        statusColor = const Color(0xFFC41E3A);
      else if (device.isMoving)    statusColor = const Color(0xFF6BA539);
      // محرك يعمل والمركبة واقفة ≥ دقيقتين (يحسبها السيرفر) — يحترم إعداد الحساب
      else if (device.idle && _idleOn) statusColor = const Color(0xFFFFC107);
      else if (device.isOnline)    statusColor = const Color(0xFF2196F3);
      else                         statusColor = const Color(0xFF9E9E9E);

      final String vehicleType = _iconOverrides[device.id]
          ?? (device.icon?.isNotEmpty == true ? device.icon! : 'car');
      final isOffline = device.isOffline || device.isInactive;
      // cacheKey يميّز الأجهزة "بدون موقع" بـ suffix خاص
      final cacheKey = '${vehicleType}_${statusColor.value}_${isOffline ? 'off' : 'on'}${hasPosition ? '' : '_nopos'}';

      BitmapDescriptor icon;
      if (_iconCache.containsKey(cacheKey)) {
        icon = _iconCache[cacheKey]!;
      } else {
        icon = await _buildVehicleMarker(vehicleType, statusColor, device.name,
            isOffline: isOffline, noPosition: !hasPosition);
        _iconCache[cacheKey] = icon;
      }

      final bool isSelected = _showPopup && _popupDevice?.id == device.id;
      // موقع الماركر — بلا GPS («تحتاج تنشيط») → البحر بفارق ~5م لكل جهاز (توزيع في صف)
      final int _np = noPosOrder[device.id] ?? 0;
      LatLng pos = hasPosition
          ? LatLng(device.lat!, device.lng!)
          : LatLng(_noPosBaseLat + _np * _noPosGapDeg, _noPosBaseLng + (_np % 2) * _noPosGapDeg);
      // ⚠️ forward-only: تجاهل أي موقع **أقدم** من المعروض. كاش السيرفر (poll) بيرجّع
      // أحيانًا موقع أقدم من الـ WS → الماركر كان يقفز للخلف نص المسافة (التذبذب).
      // نعرض الأحدث فقط بمقارنة وقت آخر إرسال (lastSeen).
      if (hasPosition) {
        final t = device.lastSeen ?? device.lastUpdate;
        final prevT = _lastMarkerTime[device.id];
        if (t != null && prevT != null && !t.isAfter(prevT) && _lastMarkerPos.containsKey(device.id)) {
          pos = _lastMarkerPos[device.id]!; // الموقع الجديد أقدم → أبقِ على المعروض
        } else {
          _lastMarkerPos[device.id] = pos;
          if (t != null) _lastMarkerTime[device.id] = t;
        }
      }

      // اتجاه الماركر: خزّن أي اتجاه حقيقي (course > 0) واستخدم آخر واحد معروف —
      // فالماركر يفضّل على آخر اتجاه وقف عليه بدل ما يرجع لفوق (زي iTrack).
      final course = (device.course ?? 0).toDouble();
      if (course > 0) _lastHeading[device.id] = course;
      final heading = _lastHeading[device.id] ?? course;

      final markers = <Marker>[
        Marker(
          markerId: MarkerId(device.id.toString()),
          position: pos,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          rotation: heading,
          zIndex: isSelected ? 1000 : 0,
          onTap: () => _onMarkerTap(device),
        ),
      ];

      // زر T: ماركر منفصل يعرض اسم الجهاز فوق العربية (لكل الأجهزة — حتى اللي «يحتاج تنشيط»
      // بلا موقع، بيظهر عند مركز الخريطة مع اسمه فوقه زي باقي الأجهزة).
      if (_showNames && device.name.trim().isNotEmpty) {
        final lbl = await _buildNameLabel(device.name.trim());
        markers.add(Marker(
          markerId: MarkerId('lbl_${device.id}'),
          position: pos,
          icon: lbl,
          // الذيل (أسفل الكارت) يلامس أعلى العربية → الاسم ملاصق زي iTrack
          // (قيمة أصغر = الاسم أقرب/أنزل على العربية، أكبر = أبعد لفوق)
          anchor: const Offset(0.5, 1.35),
          zIndex: isSelected ? 1001 : 1,
          onTap: () => _onMarkerTap(device),
        ));
      }
      return markers;
    });

    final built = (await Future.wait(futures)).expand((m) => m).toList();
    if (mounted) setState(() => _markers..clear()..addAll(built));
  }

  // بناء ماركر اسم الجهاز — كارت أبيض بذيل صغير لأسفل (callout) ملاصق للعربية (زي iTrack)
  Future<BitmapDescriptor> _buildNameLabel(String name) async {
    final ck = 'namelbl2_$name';
    final cached = _iconCache[ck];
    if (cached != null) return cached;
    const scale = 4.0, fontSize = 12.0, padH = 9.0, padV = 5.0;
    const tailW = 12.0, tailH = 7.0, radius = 7.0;
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: const TextStyle(color: Color(0xFF12203A), fontSize: fontSize,
            fontWeight: FontWeight.w700, fontFamily: 'Cairo', height: 1.15),
      ),
      textDirection: ui.TextDirection.rtl,
      maxLines: 1, ellipsis: '…',
    )..layout(maxWidth: 150);
    final pillW = tp.width + padH * 2, pillH = tp.height + padV * 2;
    final w = pillW, h = pillH + tailH;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w * scale, h * scale));
    c.scale(scale);
    final body = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, pillW, pillH), const Radius.circular(radius));
    final border = Paint()
      ..color = const Color(0x33000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    // ذيل مثلث لأسفل في المنتصف يشير للعربية
    final tail = Path()
      ..moveTo(pillW / 2 - tailW / 2, pillH - 0.5)
      ..lineTo(pillW / 2 + tailW / 2, pillH - 0.5)
      ..lineTo(pillW / 2, pillH + tailH)
      ..close();
    final fill = Paint()..color = Colors.white;
    c.drawPath(tail, fill);
    c.drawRRect(body, fill);
    c.drawPath(tail, border);
    c.drawRRect(body, border);
    tp.paint(c, const Offset(padH, padV));
    final img = await rec.endRecording().toImage((w * scale).toInt(), (h * scale).toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final icon = data != null
        ? BitmapDescriptor.bytes(data.buffer.asUint8List(), imagePixelRatio: scale)
        : BitmapDescriptor.defaultMarker;
    _iconCache[ck] = icon;
    return icon;
  }

  // أنواع لها sprite واقعي جاهز (PNG) في assets/markers — الباقي يرجع للرسم
  static const Set<String> _spriteTypes = {'car', 'sedan', 'bus', 'motorcycle', 'pickup', 'truck', 'tuk_tuk', 'van', 'boat', 'excavator'};

  // statusColor → اسم الحالة (يطابق ألوان الـ sprite المولّدة)
  String _spriteState(Color color, bool isOffline, bool noPosition) {
    if (noPosition || isOffline) return 'grey';
    switch (color.value) {
      case 0xFF6BA539: return 'green'; // moving
      case 0xFF2196F3: return 'blue';  // online/stopped
      case 0xFFFFC107: return 'yellow';// محرك يعمل والمركبة واقفة
      case 0xFFC41E3A: return 'red';   // overspeed
      default:         return 'grey';
    }
  }

  // حجم كل نوع (imagePixelRatio: أقل = أكبر على الشاشة). الافتراضي 6.0.
  // الشاحنة/التريلا (truck) والباص (bus) = مركبات كبيرة → أكبر من الافتراضي.
  // الكبيرة (تريلا/فان/باص) نزلت درجة، والباقي طلع درجة (الافتراضي 5.5 بدل 6.0)
  // الحفّار أطول من العربية، فيحتاج نسبة أصغر (= حجم أكبر على الخريطة) زي الباص
  static const Map<String, double> _spriteRatio = {'truck': 4.2, 'bus': 4.7, 'van': 4.7, 'excavator': 3.6};

  // تحميل sprite واقعي من الأصول، بدقة عالية (imagePixelRatio) + cache
  // النوع (car/bus/motorcycle...) يحدّد اسم الملف: assets/markers/${type}_${state}.png
  Future<BitmapDescriptor?> _spriteMarker(String type, String state) async {
    final key = 'sprite_${type}_$state';
    final cached = _iconCache[key];
    if (cached != null) return cached;
    try {
      final data = await rootBundle.load('assets/markers/${type}_$state.png');
      final icon = BitmapDescriptor.bytes(
          data.buffer.asUint8List(), imagePixelRatio: _spriteRatio[type] ?? 5.5);
      _iconCache[key] = icon;
      return icon;
    } catch (_) {
      return null;
    }
  }

  /// Draw vehicle marker: realistic PNG sprite (car) or drawn fallback + offline/no-position badge
  Future<BitmapDescriptor> _buildVehicleMarker(
      String type, Color color, String label,
      {bool isOffline = false, bool noPosition = false}) async {
    // sprite واقعي للسيدان/العربية
    final norm = type == 'sedan' ? 'car' : type;
    if (_spriteTypes.contains(norm)) {
      final sp = await _spriteMarker(norm, _spriteState(color, isOffline, noPosition));
      if (sp != null) return sp;
    }

    const iW = 64.0, iH = 110.0;
    const scale = 4.0; // supersample → crisp marker on 3x/4x screens (same on-screen size via imagePixelRatio)
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, iW * scale, iH * scale));
    c.scale(scale); // كل الرسم يفضل بإحداثيات logical، الكانفاس بيكبّر للدقة

    // Draw vehicle shape (dimmed if offline or no position)
    final drawColor = (isOffline || noPosition) ? color.withOpacity(0.45) : color;
    _drawVehicle(c, type, drawColor, const Rect.fromLTWH(4, 2, iW - 8, iH - 8));

    // No-position badge — برتقالي مع علامة "?"
    if (noPosition) {
      const bR = 13.0;
      const bX = iW / 2, bY = iH / 2;
      c.drawCircle(const Offset(bX, bY), bR,
          Paint()..color = const Color(0xCCFF9800)); // برتقالي
      // رسم "?"
      final tp = TextPainter(
        text: const TextSpan(
          text: '?',
          style: TextStyle(color: Colors.white, fontSize: 16,
              fontWeight: FontWeight.bold, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(bX - tp.width / 2, bY - tp.height / 2));
    }
    // Offline badge - red circle with X centered on car body
    else if (isOffline) {
      const bR = 12.0;
      const bX = iW / 2, bY = iH / 2;
      c.drawCircle(const Offset(bX, bY), bR,
          Paint()..color = const Color(0xCCEF5350));
      final xPaint = Paint()..color = Colors.white..strokeWidth = 2.5..strokeCap = StrokeCap.round;
      c.drawLine(Offset(bX - 7, bY - 7), Offset(bX + 7, bY + 7), xPaint);
      c.drawLine(Offset(bX + 7, bY - 7), Offset(bX - 7, bY + 7), xPaint);
    }

    final pic  = rec.endRecording();
    final img  = await pic.toImage((iW * scale).toInt(), (iH * scale).toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) {
      return BitmapDescriptor.bytes(data.buffer.asUint8List(),
          imagePixelRatio: scale);
    }
    return BitmapDescriptor.defaultMarker;
  }

  /// Draw vehicle silhouette based on type key
  /// Side-view vehicle silhouette - no visible wheels, clean flat shapes
  /// TOP-DOWN vehicle view - realistic overhead look, no visible tires
  void _drawVehicle(Canvas c, String type, Color color, Rect r) {
    _drawTopDown(c, type, color, r);
  }

  void _drawTopDown(Canvas c, String type, Color col, Rect r) {
    final x = r.left, y = r.top, w = r.width, h = r.height;
    // Body: تدرّج أفقي (حافة غامقة → مركز لامع → حافة غامقة) يحاكي انعكاس الضوء على سطح معدني منحني = شكل ثلاثي الأبعاد بدل المسطّح
    final body   = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(
        Offset(x, 0), Offset(x + w, 0),
        [
          Color.lerp(col, Colors.black, 0.22)!,
          Color.lerp(col, Colors.white, 0.20)!,
          col,
          Color.lerp(col, Colors.black, 0.26)!,
        ],
        const [0.0, 0.40, 0.62, 1.0],
      );
    // Roof: نفس فكرة التدرّج لكن أغمق (السقف أعلى من الجسم) مع لمعة في النص
    final roof   = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(
        Offset(x, 0), Offset(x + w, 0),
        [
          Color.lerp(col, Colors.black, 0.45)!,
          Color.lerp(col, Colors.black, 0.18)!,
          Color.lerp(col, Colors.black, 0.42)!,
        ],
        const [0.0, 0.5, 1.0],
      );
    final glass  = Paint()..color = const Color(0xCC90CAF9);
    final glare  = Paint()..color = Colors.white.withOpacity(0.22);
    final border = Paint()..color = Colors.black.withOpacity(0.45)
                           ..style = PaintingStyle.stroke..strokeWidth = 1.0;
    final hl     = Paint()..color = const Color(0xFFFFF9C4); // headlight
    final tl     = Paint()..color = const Color(0xFFEF5350); // tail light
    final mirror = Paint()..color = col.withOpacity(0.85);

    // Shadow
    c.drawOval(Rect.fromLTWH(x + w*0.1, y + h*0.88, w*0.8, h*0.12),
        Paint()..color = Colors.black.withOpacity(0.2)
               ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));

    switch (type) {

      // Sedan ??????????????????????????????????????????????????????
      case 'car':
        _topdownSedan(c, x, y, w, h, col, body, roof, glass, glare, border, hl, tl, mirror);
        break;

      // SUV (wider, taller roof) ???????????????????????????????????
      case 'suv':
        _topdownSUV(c, x, y, w, h, col, body, roof, glass, glare, border, hl, tl, mirror);
        break;

      // Pickup ?????????????????????????????????????????????????????
      case 'pickup':
        _topdownPickup(c, x, y, w, h, col, body, roof, glass, glare, border, hl, tl, mirror);
        break;

      // Van ????????????????????????????????????????????????????????
      case 'van':
        _topdownVan(c, x, y, w, h, col, body, roof, glass, glare, border, hl, tl);
        break;

      // Bus ????????????????????????????????????????????????????????
      case 'bus':
        _topdownBus(c, x, y, w, h, col, body, roof, glass, border, hl, tl);
        break;

      // Truck ??????????????????????????????????????????????????????
      case 'truck':
        _topdownTruck(c, x, y, w, h, col, body, roof, glass, border, hl, tl);
        break;

      // Motorcycle ?????????????????????????????????????????????????
      case 'motorcycle':
        _topdownMoto(c, x, y, w, h, col, body, border);
        break;

      // ?? Tuk-tuk ????????????????????????????????????????????????????
      case 'tuk_tuk':
        _topdownTukTuk(c, x, y, w, h, col, body, roof, glass, border, hl, tl);
        break;

      // ?? Tractor ????????????????????????????????????????????????????
      case 'tractor':
        _topdownTractor(c, x, y, w, h, col, body, roof, border);
        break;

      // ?? Boat ???????????????????????????????????????????????????????
      case 'boat':
        _topdownBoat(c, x, y, w, h, col, body, glass, border);
        break;

      // ?? Person ?????????????????????????????????????????????????????
      case 'person':
        c.drawCircle(Offset(x+w/2, y+h*0.35), w*0.32, body);
        c.drawOval(Rect.fromLTWH(x+w*0.18, y+h*0.6, w*0.64, h*0.35),
            Paint()..color = col.withOpacity(0.7));
        c.drawCircle(Offset(x+w/2, y+h*0.35), w*0.32, border);
        break;

      // ?? Arrow ??????????????????????????????????????????????????????
      case 'arrow':
        final arr = Path()
          ..moveTo(x+w/2, y)
          ..lineTo(x+w*0.88, y+h*0.55)
          ..lineTo(x+w*0.62, y+h*0.55)
          ..lineTo(x+w*0.62, y+h)
          ..lineTo(x+w*0.38, y+h)
          ..lineTo(x+w*0.38, y+h*0.55)
          ..lineTo(x+w*0.12, y+h*0.55)..close();
        c.drawPath(arr, body);
        c.drawPath(arr, border);
        break;

      // ?? Default (fallback to sedan) ????????????????????????????????
      default:
        _topdownSedan(c, x, y, w, h, col, body, roof, glass, glare, border, hl, tl, mirror);
        break;
    }
  }

  // ?? Top-down helpers ???????????????????????????????????????????????????????
  void _topdownSedan(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint glare,
      Paint border, Paint hl, Paint tl, Paint mirror) {
    // Body
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.05, w*0.88, h*0.9), 10, 10), body);
    // Roof/cabin
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.14, y+h*0.28, w*0.72, h*0.42), 6, 6), roof);
    // Front windshield
    c.drawPath(Path()
      ..moveTo(x+w*0.18, y+h*0.28)..lineTo(x+w*0.82, y+h*0.28)
      ..lineTo(x+w*0.76, y+h*0.12)..lineTo(x+w*0.24, y+h*0.12)..close(), glass);
    // Glare on windshield
    c.drawPath(Path()
      ..moveTo(x+w*0.22, y+h*0.26)..lineTo(x+w*0.4, y+h*0.26)
      ..lineTo(x+w*0.36, y+h*0.13)..lineTo(x+w*0.22, y+h*0.13)..close(), glare);
    // Rear windshield
    c.drawPath(Path()
      ..moveTo(x+w*0.2, y+h*0.7)..lineTo(x+w*0.8, y+h*0.7)
      ..lineTo(x+w*0.76, y+h*0.86)..lineTo(x+w*0.24, y+h*0.86)..close(),
        Paint()..color = const Color(0x9990CAF9));
    // Mirrors
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x, y+h*0.22, w*0.07, h*0.06), 1, 1), mirror);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.93, y+h*0.22, w*0.07, h*0.06), 1, 1), mirror);
    // Headlights
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.05, w*0.28, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.05, w*0.28, h*0.05), 1, 1), hl);
    // Tail lights
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.9, w*0.28, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.9, w*0.28, h*0.05), 1, 1), tl);
    // Outline
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.05, w*0.88, h*0.9), 10, 10), border);
  }

  void _topdownSUV(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint glare,
      Paint border, Paint hl, Paint tl, Paint mirror) {
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.04, w*0.92, h*0.92), 9, 9), body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.26, w*0.8, h*0.48), 6, 6), roof);
    c.drawPath(Path()
      ..moveTo(x+w*0.14, y+h*0.26)..lineTo(x+w*0.86, y+h*0.26)
      ..lineTo(x+w*0.82, y+h*0.1)..lineTo(x+w*0.18, y+h*0.1)..close(), glass);
    c.drawPath(Path()..moveTo(x+w*0.2,y+h*0.24)..lineTo(x+w*0.38,y+h*0.24)
        ..lineTo(x+w*0.35,y+h*0.11)..lineTo(x+w*0.2,y+h*0.11)..close(), glare);
    c.drawPath(Path()
      ..moveTo(x+w*0.14, y+h*0.74)..lineTo(x+w*0.86, y+h*0.74)
      ..lineTo(x+w*0.82, y+h*0.9)..lineTo(x+w*0.18, y+h*0.9)..close(),
        Paint()..color = const Color(0x9990CAF9));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x, y+h*0.2, w*0.05, h*0.08), 1, 1), mirror);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.95, y+h*0.2, w*0.05, h*0.08), 1, 1), mirror);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.04, w*0.3, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.04, w*0.3, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.91, w*0.3, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.91, w*0.3, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.04, w*0.92, h*0.92), 9, 9), border);
  }

  void _topdownPickup(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint glare,
      Paint border, Paint hl, Paint tl, Paint mirror) {
    // Full body
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.05, w*0.88, h*0.9), 8, 8), body);
    // Cab roof (front 55%)
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.12, y+h*0.26, w*0.76, h*0.28), 5, 5), roof);
    // Windshield
    c.drawPath(Path()
      ..moveTo(x+w*0.16, y+h*0.26)..lineTo(x+w*0.84, y+h*0.26)
      ..lineTo(x+w*0.8, y+h*0.12)..lineTo(x+w*0.2, y+h*0.12)..close(), glass);
    c.drawPath(Path()..moveTo(x+w*0.2,y+h*0.24)..lineTo(x+w*0.38,y+h*0.24)
        ..lineTo(x+w*0.35,y+h*0.13)..lineTo(x+w*0.2,y+h*0.13)..close(), glare);
    // Bed divider line
    c.drawLine(Offset(x+w*0.08, y+h*0.56), Offset(x+w*0.92, y+h*0.56),
        Paint()..color = Colors.black.withOpacity(0.25)..strokeWidth = 1.5);
    // Mirrors
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x, y+h*0.2, w*0.07, h*0.06), 1, 1), mirror);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.93, y+h*0.2, w*0.07, h*0.06), 1, 1), mirror);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.05, w*0.28, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.05, w*0.28, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.9, w*0.28, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.9, w*0.28, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.05, w*0.88, h*0.9), 8, 8), border);
  }

  void _topdownVan(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint glare, Paint border,
      Paint hl, Paint tl) {
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.04, w*0.92, h*0.92), 8, 8), body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.25, w*0.84, h*0.5), 5, 5), roof);
    // Front window (wider for van)
    c.drawPath(Path()
      ..moveTo(x+w*0.1, y+h*0.25)..lineTo(x+w*0.9, y+h*0.25)
      ..lineTo(x+w*0.88, y+h*0.1)..lineTo(x+w*0.12, y+h*0.1)..close(), glass);
    c.drawPath(Path()..moveTo(x+w*0.14,y+h*0.23)..lineTo(x+w*0.4,y+h*0.23)
        ..lineTo(x+w*0.38,y+h*0.11)..lineTo(x+w*0.14,y+h*0.11)..close(), glare);
    // Rear window
    c.drawPath(Path()
      ..moveTo(x+w*0.1, y+h*0.75)..lineTo(x+w*0.9, y+h*0.75)
      ..lineTo(x+w*0.88, y+h*0.9)..lineTo(x+w*0.12, y+h*0.9)..close(),
        Paint()..color = const Color(0x7790CAF9));
    // Side sliding door line
    c.drawLine(Offset(x+w*0.06, y+h*0.42), Offset(x+w*0.94, y+h*0.42),
        Paint()..color = Colors.black.withOpacity(0.18)..strokeWidth = 1.2);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.04, w*0.3, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.04, w*0.3, h*0.05), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.91, w*0.3, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.91, w*0.3, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.04, w*0.92, h*0.92), 8, 8), border);
  }

  void _topdownBus(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint border,
      Paint hl, Paint tl) {
    // Tall rectangle
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.02, w*0.92, h*0.96), 7, 7), body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.2, w*0.8, h*0.6), 4, 4), roof);
    // Front windshield
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.05, w*0.8, h*0.13), 3, 3), glass);
    // Rear window
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.82, w*0.8, h*0.13), 3, 3),
        Paint()..color = const Color(0x7790CAF9));
    // 3 top windows
    for (int i = 0; i < 3; i++) {
      c.drawRRect(RRect.fromRectXY(
          Rect.fromLTWH(x+w*0.12+i*w*0.28, y+h*0.22, w*0.22, h*0.14), 2, 2), glass);
    }
    // 3 bottom windows
    for (int i = 0; i < 3; i++) {
      c.drawRRect(RRect.fromRectXY(
          Rect.fromLTWH(x+w*0.12+i*w*0.28, y+h*0.64, w*0.22, h*0.14), 2, 2), glass);
    }
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.02, w*0.3, h*0.04), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.02, w*0.3, h*0.04), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.08, y+h*0.94, w*0.3, h*0.04), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.94, w*0.3, h*0.04), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.04, y+h*0.02, w*0.92, h*0.96), 7, 7), border);
  }

  void _topdownTruck(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint border,
      Paint hl, Paint tl) {
    // Cargo (rear 60%)
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.38, w*0.88, h*0.58), 5, 5), body);
    // Cargo roof lines
    c.drawLine(Offset(x+w*0.06, y+h*0.55), Offset(x+w*0.94, y+h*0.55),
        Paint()..color = Colors.black.withOpacity(0.12)..strokeWidth = 1);
    c.drawLine(Offset(x+w*0.06, y+h*0.72), Offset(x+w*0.94, y+h*0.72),
        Paint()..color = Colors.black.withOpacity(0.12)..strokeWidth = 1);
    // Cab (front 40%)
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.04, w*0.88, h*0.36), 8, 8), body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.12, y+h*0.2, w*0.76, h*0.18), 4, 4), roof);
    c.drawPath(Path()
      ..moveTo(x+w*0.14, y+h*0.2)..lineTo(x+w*0.86, y+h*0.2)
      ..lineTo(x+w*0.82, y+h*0.07)..lineTo(x+w*0.18, y+h*0.07)..close(), glass);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.04, w*0.28, h*0.04), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.04, w*0.28, h*0.04), 1, 1), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.92, w*0.28, h*0.04), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.62, y+h*0.92, w*0.28, h*0.04), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.06, y+h*0.04, w*0.88, h*0.58+0.34), 5, 5), border);
  }

  void _topdownMoto(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint border) {
    // Tank/frame - narrow elongated
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.3, y+h*0.06, w*0.4, h*0.7), 8, 8), body);
    // Handlebars
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.08, w*0.8, h*0.08), 3, 3), body);
    // Seat
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.32, y+h*0.42, w*0.36, h*0.28), 5, 5),
        Paint()..color = const Color(0xFF1A1A2E));
    // Headlight
    c.drawOval(Rect.fromLTWH(x+w*0.38, y+h*0.06, w*0.24, h*0.08),
        Paint()..color = const Color(0xFFFFF9C4));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.3, y+h*0.06, w*0.4, h*0.7), 8, 8), border);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.1, y+h*0.08, w*0.8, h*0.08), 3, 3), border);
  }

  void _topdownTukTuk(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint glass, Paint border,
      Paint hl, Paint tl) {
    // Triangular/rounded body (wider at back)
    final bd = Path()
      ..moveTo(x+w*0.5, y+h*0.04)      // front point
      ..quadraticBezierTo(x+w*0.72, y+h*0.04, x+w*0.9, y+h*0.2)
      ..lineTo(x+w*0.9, y+h*0.78)
      ..quadraticBezierTo(x+w*0.9, y+h*0.94, x+w*0.72, y+h*0.94)
      ..lineTo(x+w*0.28, y+h*0.94)
      ..quadraticBezierTo(x+w*0.1, y+h*0.94, x+w*0.1, y+h*0.78)
      ..lineTo(x+w*0.1, y+h*0.2)
      ..quadraticBezierTo(x+w*0.28, y+h*0.04, x+w*0.5, y+h*0.04)
      ..close();
    c.drawPath(bd, body);
    // Cabin roof
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.18, y+h*0.24, w*0.64, h*0.44), 6, 6), roof);
    // Front windshield (angled)
    c.drawPath(Path()
      ..moveTo(x+w*0.22, y+h*0.24)..lineTo(x+w*0.78, y+h*0.24)
      ..lineTo(x+w*0.68, y+h*0.1)..lineTo(x+w*0.32, y+h*0.1)..close(), glass);
    // Rear open sides (lines)
    c.drawLine(Offset(x+w*0.14, y+h*0.7), Offset(x+w*0.86, y+h*0.7),
        Paint()..color = Colors.black.withOpacity(0.2)..strokeWidth = 1.2);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.38, y+h*0.04, w*0.24, h*0.06), 2, 2), hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.2, y+h*0.88, w*0.22, h*0.05), 1, 1), tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.58, y+h*0.88, w*0.22, h*0.05), 1, 1), tl);
    c.drawPath(bd, border);
  }

  void _topdownTractor(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint roof, Paint border) {
    // Hood (front narrow)
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.28, y+h*0.04, w*0.44, h*0.32), 5, 5), body);
    // Cabin (middle)
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.2, y+h*0.3, w*0.6, h*0.28), 6, 6), body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.26, y+h*0.34, w*0.48, h*0.18), 4, 4), roof);
    // Rear axle body
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.22, y+h*0.55, w*0.56, h*0.36), 6, 6), body);
    // Exhaust pipe
    c.drawLine(Offset(x+w*0.42, y+h*0.04), Offset(x+w*0.42, y),
        Paint()..color = col..strokeWidth = w*0.06..strokeCap = StrokeCap.round);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.28, y+h*0.04, w*0.44, h*0.32), 5, 5), border);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.2, y+h*0.3, w*0.6, h*0.28), 6, 6), border);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.22, y+h*0.55, w*0.56, h*0.36), 6, 6), border);
  }

  void _topdownBoat(Canvas c, double x, double y, double w, double h,
      Color col, Paint body, Paint glass, Paint border) {
    // Hull teardrop
    final hull = Path()
      ..moveTo(x+w*0.5, y+h*0.04)
      ..quadraticBezierTo(x+w*0.96, y+h*0.04, x+w*0.96, y+h*0.5)
      ..quadraticBezierTo(x+w*0.96, y+h*0.88, x+w*0.5, y+h*0.96)
      ..quadraticBezierTo(x+w*0.04, y+h*0.88, x+w*0.04, y+h*0.5)
      ..quadraticBezierTo(x+w*0.04, y+h*0.04, x+w*0.5, y+h*0.04)
      ..close();
    c.drawPath(hull, body);
    // Windshield
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.2, y+h*0.12, w*0.6, h*0.2), 5, 5), glass);
    // Cabin line
    c.drawLine(Offset(x+w*0.1, y+h*0.38), Offset(x+w*0.9, y+h*0.38),
        Paint()..color = Colors.black.withOpacity(0.2)..strokeWidth = 1.2);
    // Motor hint
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*0.38, y+h*0.86, w*0.24, h*0.08), 3, 3),
        Paint()..color = Colors.black.withOpacity(0.35));
    c.drawPath(hull, border);
  }

  void _wheels4(Canvas c, double x, double y, double w, double h,
      Color col, Paint stroke) {
    // Intentionally empty - top-down view hides wheels
  }

  void _onMarkerTap(DeviceModel device) {
    final idx = _devices.indexOf(device);
    setState(() {
      _popupDevice = device;
      _showPopup = true;
      if (idx >= 0) _selectedIndex = idx;
    });
    _buildMarkers(_devices); // ليطفو ماركر الجهاز المختار فوق المتراكبين
    if (device.lat != null && device.lng != null) {
      _smoothZoomTo(_dispPos(device)); // يتبع موقع الماركر المرسوم فعلاً
    }
  }

  Timer? _zoomAnimTimer;
  // zoom تدريجي (سلوموشن) للوصول للزوم النهائي عند الضغط على الجهاز — بدل القفزة الفورية
  void _smoothZoomTo(LatLng target, {double targetZoom = 16}) {
    _zoomAnimTimer?.cancel();
    final ctrl = _mapController;
    if (ctrl == null) return;
    ctrl.getZoomLevel().then((startZoom) {
      if (!mounted || _mapController == null) return;
      const steps = 24;
      int i = 0;
      _zoomAnimTimer = Timer.periodic(const Duration(milliseconds: 48), (t) {
        i++;
        if (!mounted || _mapController == null || i > steps) { t.cancel(); return; }
        final eased = Curves.easeInOutCubic.transform(i / steps);
        final z = startZoom + (targetZoom - startZoom) * eased;
        _mapController!.moveCamera(CameraUpdate.newLatLngZoom(target, z));
      });
    });
  }

  // انتقال طائر ناعم بين جهازين: pan تدريجي للموقع + انخفاض زوم بسيط في المنتصف
  // (يزوّم أوت شوية ويرجع يزوّم إن) حسب البُعد — يدّي إحساس "طيران" سلس بين الأجهزة.
  void _flyBetween(LatLng from, LatLng to, {double targetZoom = 16}) {
    _zoomAnimTimer?.cancel();
    final ctrl = _mapController;
    if (ctrl == null) return;
    ctrl.getZoomLevel().then((startZoom) {
      if (!mounted || _mapController == null) return;
      final dLat = to.latitude - from.latitude;
      final dLng = to.longitude - from.longitude;
      final dist = math.sqrt(dLat * dLat + dLng * dLng); // مسافة بالدرجات (تقريبية)
      final dip = dist > 0.3 ? 3.0 : (dist > 0.03 ? 2.0 : 0.0); // زوم أوت حسب البُعد
      const steps = 24;
      int i = 0;
      _zoomAnimTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
        i++;
        if (!mounted || _mapController == null || i > steps) { t.cancel(); return; }
        final p = i / steps;
        final eased = Curves.easeInOut.transform(p);
        final lat = from.latitude + dLat * eased;
        final lng = from.longitude + dLng * eased;
        final zBase = startZoom + (targetZoom - startZoom) * eased;
        final z = zBase - dip * math.sin(p * math.pi); // منحنى: 0 عند الطرفين، أقصى في النص
        _mapController!.moveCamera(CameraUpdate.newLatLngZoom(LatLng(lat, lng), z));
      });
    });
  }

  List<DeviceModel> _lastDevices = [];
  int _lastRefreshCountdown = -1;
  int _lastResumeSeq = 0;

  // بعد الرجوع من الخلفية واكتمال التحديث: حرّك الكاميرا تلقائياً على المكان الجديد
  void _recenterAfterResume() {
    if (_showPopup && _popupDevice != null &&
        _popupDevice!.lat != null && _popupDevice!.lng != null) {
      // يتبع موقع الماركر المرسوم فعلاً (_dispPos) مش الخام — يضمن الكاميرا على الجديد
      _mapController?.animateCamera(
          CameraUpdate.newLatLng(_dispPos(_popupDevice!)));
      return;
    }
    _fitBoundsToDevices(); // جهاز واحد → zoom عليه، أكتر → إطار يشملهم (زي فتح التطبيق)
  }

  @override
  Widget build(BuildContext context) {
    // خريطة العميل المعروض (view_as / initialDevices) تدير بياناتها بنفسها عبر
    // _refreshScopedDevices (كل 10ث) → مش محتاجة تسمع بروفايدر الأدمن. الاستماع
    // (watch) كان بيعيد بناء الخريطة كل ثانية + مع كل تحديث WS لأجهزة الأدمن →
    // يقطع animateCamera (تهنيج + مفيش تنقل). read = تُبنى فقط عند setState الخاص بها.
    final provider = widget.initialDevices != null
        ? context.read<AppProvider>()
        : context.watch<AppProvider>();

    // Rebuild markers when:
    // 1. Device list reference changed
    // 2. Countdown just reset (refreshCountdown went back to high value = new fetch happened)
    final countdownJustReset = _lastRefreshCountdown <= 1 && provider.refreshCountdown > 7;
    // لو الخريطة الرئيسية مغطّاة براوت تاني (خريطة عميل/بروفايل مفتوحة فوقها) →
    // ماتعملش إعادة بناء ماركرات تقيلة مع كل تحديث WS. ده بيخنق الـ isolate ويخلي
    // كاميرا الخريطة اللي فوق تزحف. تتحدّث تلقائياً أول ما ترجع الراوت الحالي.
    final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    if (widget.initialDevices == null && isCurrentRoute &&
        (provider.devices != _lastDevices || provider.inventory != _lastDevices || countdownJustReset)) {
      final freshList = (provider.currentUser?.isDealer == true || provider.currentUser?.isSubDealer == true) ? provider.inventory : provider.devices;
      _lastDevices = freshList;
      _devices = freshList;
      // مزامنة الموديل المفتوح فوراً مع نفس دورة تحديث الماركر (بدل الانتظار 10ث على الـ timer)
      if (_showPopup && _popupDevice != null) {
        final match = freshList.where((d) => d.id == _popupDevice!.id);
        if (match.isNotEmpty && !identical(match.first, _popupDevice)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              final updated = match.first;
              setState(() => _popupDevice = updated);
              if (updated.lat != null && updated.lng != null) {
                _maybeRecenter(updated.lat!, updated.lng!);
              }
            }
          });
        } else if (match.isNotEmpty && match.first.lat != null && match.first.lng != null) {
          // نفس الكائن اتحدّث in-place (تحديث WS لحظي) → تابع الكاميرا لو خرج من الشاشة
          final lp = match.first;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _maybeRecenter(lp.lat!, lp.lng!);
          });
        } else if (match.isEmpty) {
          // الجهاز المعروض اتنقل أو اتحذف — أخفي الـ popup
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() { _showPopup = false; _popupDevice = null; });
          });
        }
      }
      // لا نمسح الـ cache في الـ refresh العادي - الأيقونات محفوظة بـ cache key يشمل الحالة
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _buildMarkers(freshList);
      });
    }
    // خريطة العميل (view_as): عند وصول العدّاد لـ0، اعرض أجهزة العميل من provider.devices
    // (المخزّنة من الـ WS buffer + poll — نفس مصدر الخريطة الرئيسية بالظبط) مفلترة بالـ
    // viewAsUserId. كده الماركر يتحرك عند 0 بالموقع الأحدث فورًا زي الرئيسية (مفيش fetch
    // منفصل بطيء ولا تذبذب). fallback للجلب المفلتر من السيرفر لو provider مفهوش أجهزة العميل.
    if (widget.initialDevices != null && widget.viewAsUserId != null && countdownJustReset) {
      // عند العد 0: جِب أجهزة العميل طازجة من السيرفر (getDevices(viewAs)) — positions +
      // lastUpdate/lastIgnition صح. مانستخدمش provider.devices (بتاعة الديلر) لأن الميتاداتا
      // فيها قديمة على خريطة العميل (الـ WS بيحدّث الموقع بس مش «آخر حركة/تشغيل محرك»).
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _refreshScopedDevices(); });
    }

    _lastRefreshCountdown = provider.refreshCountdown;

    // رجوع من الخلفية + البيانات الجديدة وصلت → حرّك الكاميرا على الماركر تلقائياً.
    // view_as: provider.devices طازج بعد جلب الرجوع (resumeSeq يزيد بعد _silentRefresh) →
    // اعرض أحدث أجهزة العميل من الـ WS buffer فورًا (بدل انتظار العد 0).
    if (provider.resumeSeq != _lastResumeSeq) {
      _lastResumeSeq = provider.resumeSeq;
      if (widget.initialDevices != null && widget.viewAsUserId != null) {
        // رجوع من الخلفية: جِب أجهزة العميل طازجة (positions + metadata صح) ثم حرّك الكاميرا.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _refreshScopedDevices().then((_) { if (mounted) _recenterAfterResume(); });
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _recenterAfterResume();
        });
      }
    }

    return Stack(
      children: [
        // Google Map
        GoogleMap(
          initialCameraPosition: _defaultCameraPos,
          mapType: _mapType,
          markers: _markers,
          polylines: _polylines,
          onMapCreated: (ctrl) {
            _mapController = ctrl;
            // Auto-zoom to devices after map is ready
            Future.delayed(const Duration(milliseconds: 500), _fitBoundsToDevices);
          },
          // نميّز حركة الكاميرا البرمجية (متابعة الجهاز) عن تفاعل المستخدم (زوم/سحب).
          // تفاعل المستخدم → نسجّل وقته عشان نوقف التتبع مؤقتًا (يستكشف بحرية).
          onCameraMoveStarted: () {
            _cameraMoving = true;
            if (_progCam) { _progCam = false; } else { _lastCamGesture = DateTime.now(); }
          },
          onCameraIdle: () { _cameraMoving = false; _progCam = false; },
          onTap: (pos) {
            if (_measuringDistance) {
              setState(() {
                _measurePoints.add(pos);
                if (_measurePoints.length >= 2) {
                  double total = 0;
                  for (int i = 1; i < _measurePoints.length; i++) {
                    final a = _measurePoints[i-1], b = _measurePoints[i];
                    final lat = (b.latitude - a.latitude) * math.pi / 180;
                    final lng = (b.longitude - a.longitude) * math.pi / 180;
                    final x = math.sin(lat/2)*math.sin(lat/2) + math.cos(a.latitude*math.pi/180)*math.cos(b.latitude*math.pi/180)*math.sin(lng/2)*math.sin(lng/2);
                    total += 6371 * 2 * math.atan2(math.sqrt(x), math.sqrt(1-x));
                  }
                  _polylines.removeWhere((p) => p.polylineId.value == 'measure');
                  _polylines.add(Polyline(
                    polylineId: const PolylineId('measure'),
                    points: _measurePoints,
                    color: const Color(0xFF2196F3),
                    width: 3,
                    patterns: [PatternItem.dash(20), PatternItem.gap(8)],
                  ));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(tr('map_distance', {'d': total.toStringAsFixed(2)}), style: const TextStyle(fontFamily: 'Cairo')),
                    duration: const Duration(seconds: 3),
                    backgroundColor: const Color(0xFF2196F3),
                    action: SnackBarAction(label: tr('clear'), textColor: Colors.white, onPressed: () {
                      setState(() { _measurePoints.clear(); _polylines.removeWhere((p) => p.polylineId.value == 'measure'); _measuringDistance = false; });
                    }),
                  ));
                }
              });
            } else {
              setState(() => _showPopup = false);
            }
          },
          zoomControlsEnabled: false,
          compassEnabled: false,
          mapToolbarEnabled: false,
          myLocationEnabled: _myLocationEnabled,
          myLocationButtonEnabled: false,
        ),
        // Hide Google logo (bottom-left)
        Positioned(
          bottom: 0, left: 0,
          width: 110, height: 26,
          child: Container(color: const Color(0xFFF5F6FA)),
        ),

        // Subtle refresh indicator at top — shows ONLY during background sync
        // (after cache load on cold start)
        if (provider.isRefreshing)
          const Positioned(
            top: 0, left: 0, right: 0,
            child: SizedBox(
              height: 2.5,
              child: LinearProgressIndicator(
                backgroundColor: Color(0x22000000),
                color: Color(0xFFC41E3A),
                minHeight: 2.5,
              ),
            ),
          ),

        // (أُزيلت رسالة «جاري تحديث البيانات» بطلب المستخدم — التحديث بيحصل بصمت
        // والكاميرا بتعمل زوم تلقائي على الأجهزة أول ما البيانات الجديدة توصل)

        // Top-left: زر الزوم اوت (يعرض كل الأجهزة على الخريطة)
        Positioned(
          top: 60,
          left: 10,
          child: _MapBtn(icon: Icons.zoom_out_map, onTap: () => _fitBoundsToDevices()),
        ),

        // Top-right: زر العدّاد التنازلي / التحديث اليدوي
        Positioned(
          top: 60,
          right: 10,
          child: _buildCountdownBtn(provider),
        ),


        // Left controls: zoom + map type + track
        Positioned(
          left: 10,
          top: _showPopup
              ? MediaQuery.of(context).size.height * 0.15
              : MediaQuery.of(context).size.height * 0.35,
          child: _buildLeftControls(),
        ),

        // Right controls: route + distance + alert + geofence
        Positioned(
          right: 10,
          top: _showPopup
              ? MediaQuery.of(context).size.height * 0.15
              : MediaQuery.of(context).size.height * 0.35,
          child: _buildRightControls(),
        ),

        // Playback controls overlay
        if (_showPlayback && _playbackPositions.isNotEmpty)
          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: _buildPlaybackControls(),
          ),

        // Navigation arrows
        if (_devices.isNotEmpty && !_showPlayback)
          Positioned(
            bottom: _showPopup ? 220 : 20,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _NavArrow(icon: Icons.chevron_right, onTap: () => _navigateDev(-1)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Text(
                    '${_selectedIndex + 1} / ${_devices.length}',
                    style: TextStyle(fontSize: 10, fontFamily: 'Cairo', color: Theme.of(context).colorScheme.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                _NavArrow(icon: Icons.chevron_left, onTap: () => _navigateDev(1)),
              ],
            ),
          ),

        // Device popup
        if (_showPopup && _popupDevice != null)
          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: _buildDevicePopup(_popupDevice!),
          ),

        // Hint
        if (!_showPopup)
          Positioned(
            top: 70,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  tr('map_tap_device'),
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Cairo'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCountdownBtn(AppProvider provider) {
    return GestureDetector(
      onTap: () async {
        // ⚠️ الضغط اليدوي = عرض فوري لأحدث مواقع الـ WS المخزّنة + إعادة العد لـ10.
        // بدون زوم اوت (بقى له زر منفصل) وبدون قفل الـ popup — يفضل على نفس العرض.
        if (widget.initialDevices != null) {
          // خريطة عميل معروض (view_as): طبّق الـ WS buffer فورًا — showLiveNow يحدّث
          // provider.devices من الـ WS + poll ويرجّع العد لـ10، ثم نعرض أجهزة العميل المفلترة.
          provider.showLiveNow();
          final scoped = [...provider.devices, ...provider.inventory]
              .where((d) => d.userId == widget.viewAsUserId).toList();
          if (scoped.isNotEmpty) {
            _devices = scoped;
            _iconCache.clear();
            _buildMarkers(scoped);
          } else if (widget.viewAsUserId != null) {
            await _refreshScopedDevices();
          }
          if (!mounted) return;
          return;
        }
        // الخريطة الرئيسية: اعرض أحدث مواقع الـ WS فورًا (بدون انتظار شبكة) + رجّع العد لـ10
        provider.showLiveNow();
        final user = provider.currentUser;
        final devices = (user?.isDealer == true || user?.isSubDealer == true)
            ? provider.inventory : provider.devices;
        if (devices.isNotEmpty) _devices = devices;
        _iconCache.clear();
        _lastDevices = []; // force rebuild on next build cycle
        _buildMarkers(_devices);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: const [BoxShadow(color: Color(0x19000000), blurRadius: 6)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh, size: 13, color: Theme.of(context).colorScheme.onSurface),
            const SizedBox(width: 4),
            Text(
              // نعرض 10 كحد أقصى (العدّاد الداخلي قد يصل 11 بسبب ثانية الـ buffer
              // لمزامنة إرسال الجهاز — نحتفظ بها للتوقيت لكن نعرض 10 نظيفة)
              '${provider.refreshCountdown > 10 ? 10 : provider.refreshCountdown}${tr('unit_sec_short')}',
              style: TextStyle(fontSize: 10, fontFamily: 'Cairo', color: Theme.of(context).colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      width: 150,
      height: 34,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: const [BoxShadow(color: Color(0x19000000), blurRadius: 6)],
      ),
      child: TextField(
        textAlign: I18n.isAr ? TextAlign.right : TextAlign.left,
        decoration: InputDecoration(
          hintText: tr('map_search'),
          border: InputBorder.none,
          filled: false,
          hintStyle: const TextStyle(color: Color(0xFF8892A4), fontSize: 11, fontFamily: 'Cairo'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _buildLeftControls() {
    return Column(
      children: [
        _MapBtn(icon: Icons.add, onTap: () => _mapController?.animateCamera(CameraUpdate.zoomIn())),
        const SizedBox(height: 5),
        _MapBtn(icon: Icons.remove, onTap: () => _mapController?.animateCamera(CameraUpdate.zoomOut())),
        const SizedBox(height: 10),
        Column(
          children: [
            _MapBtn(
              icon: Icons.map_outlined,
              onTap: _cycleMapType,
            ),
            Text(
              _mapTypeLabel,
              style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E)),
            ),
          ],
        ),
        const SizedBox(height: 5),
        // زر T — إظهار/إخفاء أسماء الأجهزة فوق الماركرات
        Column(children: [
          _MapBtn(icon: Icons.title, active: _showNames, onTap: _toggleNames),
          Text(tr('ctl_labels'), style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E))),
        ]),
        const SizedBox(height: 5),
        _MapBtn(
          icon: Icons.my_location,
          onTap: _goToMyLocation,
        ),
      ],
    );
  }

  void _toggleNames() {
    setState(() => _showNames = !_showNames);
    _buildMarkers(_devices);
  }

  Widget _buildRightControls() {
    return Column(
      children: [
        // مسار - عرض مسار الجهاز المختار
        Column(children: [
          _MapBtn(icon: Icons.route, onTap: () {
            // الجهاز يُعتبر مُختارًا فقط ما دامت نافذته ظاهرة — إغلاقها إلغاء للاختيار
            if (_showPopup && _popupDevice != null) {
              _openReplay(_popupDevice!);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr('map_select_first'), style: const TextStyle(fontFamily: 'Cairo')),
                duration: const Duration(seconds: 2),
                backgroundColor: const Color(0xFF1A1F2E),
              ));
            }
          }),
          Text(tr('ctl_route'), style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E))),
        ]),
        const SizedBox(height: 5),
        // مسافة - وضع قياس المسافة
        Column(children: [
          _MapBtn(
            icon: Icons.straighten,
            active: _measuringDistance,
            onTap: () => setState(() {
              _measuringDistance = !_measuringDistance;
              if (!_measuringDistance) {
                _measurePoints.clear();
                _polylines.removeWhere((p) => p.polylineId.value == 'measure');
              }
            }),
          ),
          Text(tr('ctl_distance'), style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E))),
        ]),
        const SizedBox(height: 5),
        // تنبيه - تنبيهات الجهاز المختار
        Column(children: [
          _MapBtn(icon: Icons.notifications_outlined, onTap: () {
            if (_showPopup && _popupDevice != null) {
              _openAlerts(_popupDevice!);
            } else {
              // بدون اختيار جهاز → كل تنبيهات الأجهزة المعروضة
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => DeviceAlertsScreen(allDevices: _devices),
              ));
            }
          }),
          Text(tr('ctl_alert'), style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E))),
        ]),
        const SizedBox(height: 5),
        // سياج - السياج الجغرافي
        Column(children: [
          _MapBtn(icon: Icons.fence, onTap: () {
            if (_showPopup && _popupDevice != null) {
              _openGeofence(_popupDevice!);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr('map_select_first'), style: const TextStyle(fontFamily: 'Cairo')),
                duration: const Duration(seconds: 2),
                backgroundColor: const Color(0xFF1A1F2E),
              ));
            }
          }),
          Text(tr('ctl_geofence'), style: const TextStyle(fontSize: 7, color: Color(0xFF555F6E))),
        ]),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    final p = _playbackPositions.isNotEmpty ? _playbackPositions[_playbackIdx] : null;
    final spd = p != null ? ((p['speed'] ?? 0) * 1.852).toStringAsFixed(1) : '0';
    final t = p?['fixTime'] != null ? _formatTime(DateTime.tryParse(p!['fixTime'])) : '';
    final total = _playbackPositions.length - 1;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E293B)),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Info row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$spd ${tr('unit_kmh')} | $t',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'Cairo')),
              GestureDetector(
                onTap: _stopPlayback,
                child: const Icon(Icons.close, color: Colors.white54, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: const Color(0xFFC41E3A),
              inactiveTrackColor: Colors.white24,
              thumbColor: const Color(0xFFC41E3A),
            ),
            child: Slider(
              value: _playbackIdx.toDouble(),
              min: 0,
              max: total.toDouble(),
              onChanged: (v) => _seekPlayback(v.toInt()),
            ),
          ),
          // Controls row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Speed buttons
              ...([0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 6.0, 8.0]).map((s) =>
                GestureDetector(
                  onTap: () {
                    setState(() => _playbackSpeed = s);
                    if (_isPlaying) { _playbackTimer?.cancel(); _togglePlay(); }
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                    decoration: BoxDecoration(
                      color: _playbackSpeed == s ? const Color(0xFF1565C0) : Colors.white12,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('x$s'.replaceAll('.0', ''),
                      style: const TextStyle(color: Colors.white, fontSize: 8, fontFamily: 'Cairo')),
                  ),
                )
              ),
              const SizedBox(width: 8),
              // Play/Pause
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 36, height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFFC41E3A), shape: BoxShape.circle,
                  ),
                  child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _navigateDev(int dir) {
    if (_devices.isEmpty) return;
    // ابدأ من الجهاز المعروض حالياً (لو متاح) حتى يكون التنقل متّسقاً مع البيانات الظاهرة
    final prev = _popupDevice; // الجهاز الحالي — منه يبدأ الانتقال الطائر
    int cur = _popupDevice != null ? _devices.indexOf(_popupDevice!) : _selectedIndex;
    if (cur < 0) cur = _selectedIndex;
    final n = _devices.length;
    cur = (cur + dir + n) % n;
    _selectedIndex = cur;
    final d = _devices[cur];
    setState(() {
      _popupDevice = d;
      _showPopup = true;
    });
    _buildMarkers(_devices); // أعد البناء ليطفو ماركر الجهاز المختار فوق المتراكبين
    // انتقال طائر ناعم (pan + زوم) من الجهاز الحالي للجديد — نفس أسلوب الضغط.
    if (prev != null) {
      _flyBetween(_dispPos(prev), _dispPos(d));
    } else {
      _smoothZoomTo(_dispPos(d));
    }
  }

  void _startPlayback(List<Map<String, dynamic>> positions) {
    setState(() {
      _playbackPositions = positions;
      _playbackIdx = 0;
      _isPlaying = false;
      _showPlayback = true;
    });
    _updatePlaybackMarker();
  }

  void _togglePlay() {
    if (_isPlaying) {
      _playbackTimer?.cancel();
      setState(() => _isPlaying = false);
    } else {
      setState(() => _isPlaying = true);
      _playbackTimer = Timer.periodic(
        Duration(milliseconds: (300 / _playbackSpeed).round()),
        (_) {
          if (_playbackIdx >= _playbackPositions.length - 1) {
            _playbackTimer?.cancel();
            setState(() => _isPlaying = false);
            return;
          }
          setState(() => _playbackIdx++);
          _updatePlaybackMarker();
        },
      );
    }
  }

  void _seekPlayback(int idx) {
    _playbackTimer?.cancel();
    setState(() { _playbackIdx = idx; _isPlaying = false; });
    _updatePlaybackMarker();
  }

  void _updatePlaybackMarker() {
    if (_playbackPositions.isEmpty) return;
    final p = _playbackPositions[_playbackIdx];
    final lat = double.tryParse(p['latitude']?.toString() ?? '0') ?? 0;
    final lng = double.tryParse(p['longitude']?.toString() ?? '0') ?? 0;
    if (lat == 0 && lng == 0) return;

    // حساب الاتجاه
    double angle = 0;
    if (_playbackIdx < _playbackPositions.length - 1) {
      final next = _playbackPositions[_playbackIdx + 1];
      final nLat = double.tryParse(next['latitude']?.toString() ?? '0') ?? 0;
      final nLng = double.tryParse(next['longitude']?.toString() ?? '0') ?? 0;
      angle = _calcBearing(lat, lng, nLat, nLng);
    }

    final spd = ((p['speed'] ?? 0) * 1.852).toStringAsFixed(1);
    final t = p['fixTime'] != null ? _formatTime(DateTime.tryParse(p['fixTime'])) : '';

    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'playback');
      _markers.add(Marker(
        markerId: const MarkerId('playback'),
        position: LatLng(lat, lng),
        rotation: angle,
        anchor: const Offset(0.5, 0.5),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: '$spd ${tr('unit_kmh')} | $t'),
      ));
    });
    _maybeRecenter(lat, lng);
  }

  // مثل iTrack: لا نحرّك الخريطة إلا عند اقتراب الماركر من حافة الشاشة
  Future<void> _maybeRecenter(double lat, double lng) async {
    final ctrl = _mapController;
    // ⚠️ لا تتدخّل أثناء حركة/زوم المستخدم (زوم بصباعين) — الـ animateCamera كان بيتصادم مع الإصبع فيهنّج.
    if (ctrl == null || _cameraMoving) return;
    // احترم تفاعل المستخدم: لو زوّم/سحب الخريطة بإيده مؤخرًا (4ث) ما نتابعش (يستكشف بحرية).
    if (_lastCamGesture != null && DateTime.now().difference(_lastCamGesture!) < const Duration(seconds: 4)) return;
    try {
      final b = await ctrl.getVisibleRegion();
      final sw = b.southwest, ne = b.northeast;
      // الماركر يتحرك على الخريطة عادي؛ لما يوصل لحافة الشاشة (خرج منها) → الكاميرا
      // ترجّعه للمنتصف في موقعه الجديد. (بدون هامش → مايرجعش بدري.)
      final inside = lat >= sw.latitude && lat <= ne.latitude &&
          lng >= sw.longitude && lng <= ne.longitude;
      if (!inside) { _progCam = true; ctrl.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng))); }
    } catch (_) {}
  }

  double _calcBearing(double lat1, double lng1, double lat2, double lng2) {
    final dLng = (lng2 - lng1) * (3.14159 / 180);
    final lat1R = lat1 * (3.14159 / 180);
    final lat2R = lat2 * (3.14159 / 180);
    final y = Math.sin(dLng) * Math.cos(lat2R);
    final x = Math.cos(lat1R) * Math.sin(lat2R) - Math.sin(lat1R) * Math.cos(lat2R) * Math.cos(dLng);
    return (Math.atan2(y, x) * (180 / 3.14159) + 360) % 360;
  }

  void _stopPlayback() {
    _playbackTimer?.cancel();
    setState(() {
      _showPlayback = false;
      _isPlaying = false;
      _playbackPositions = [];
      _playbackIdx = 0;
      _polylines = {};
      _markers.removeWhere((m) => m.markerId.value == 'playback' ||
          m.markerId.value == 'route_start' || m.markerId.value == 'route_end');
    });
  }

  void _fitBoundsToDevices() {
    if (_devices.isEmpty || _mapController == null) return;
    // فريم أجهزة الـ GPS الحقيقية فقط — الأجهزة بدون GPS (في البحر) متشملهاش عشان الكاميرا
    // ماتزوّمش برّه. التنقّل بالسهم يروح للبحر عادي عبر _dispPos.
    final gps = _devices.where((d) => d.lat != null && d.lng != null).toList();
    final pts = (gps.isNotEmpty ? gps : _devices).map(_dispPos).toList();
    if (pts.length == 1) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(pts[0], 15));
      return;
    }
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // كل النقاط متطابقة (مثلاً كلها بدون GPS في نفس النقطة) → bounds صفري
    // يخبط الكاميرا، فنستخدم zoom مباشر بدلاً منه.
    if ((maxLat - minLat) < 0.0005 && (maxLng - minLng) < 0.0005) {
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(pts[0], 15));
      return;
    }
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 80));
  }

  IconData _batteryIcon(String? batStr) {
    final pct = int.tryParse(batStr?.replaceAll(RegExp(r'[^0-9]'), '') ?? '') ?? 0;
    if (pct >= 90) return Icons.battery_full;
    if (pct >= 75) return Icons.battery_6_bar;
    if (pct >= 60) return Icons.battery_5_bar;
    if (pct >= 45) return Icons.battery_4_bar;
    if (pct >= 30) return Icons.battery_3_bar;
    if (pct >= 15) return Icons.battery_2_bar;
    if (pct > 0) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '-';
    final local = dt.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.isNegative) return tr('t_now');
    if (diff.inSeconds < 60) return tr('t_seconds', {'n': '${diff.inSeconds}'});
    if (diff.inMinutes < 60) return tr('t_min_sec', {'m': '${diff.inMinutes}', 's': '${diff.inSeconds % 60}'});
    if (diff.inHours < 24) return tr('t_hr_min', {'h': '${diff.inHours}', 'm': '${diff.inMinutes % 60}'});
    return tr('t_day_hr', {'d': '${diff.inDays}', 'h': '${diff.inHours % 24}'});
  }

  // الوقت والتاريخ الحي (الـ popup بيعمل rebuild كل ثانية من _tickTimer)
  String _liveClock() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}  ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  Widget _buildDevicePopup(DeviceModel device) {
    // «آخر تحديث» يقرأ النضارة الحيّة من الـ provider (الـ WS بيحدّث lastSeen لحظيًا) —
    // مايستنّاش العد 0. الماركر/الموقع يفضلوا من `device` (buffer عند العد 0). التيك (1ث)
    // يعيد بناء الـ popup فيتحدّث الرقم لحظيًا أول ما الجهاز يبعت.
    final _prov = context.read<AppProvider>();
    DeviceModel? _liveDev;
    for (final d in _prov.devices) { if (d.id == device.id) { _liveDev = d; break; } }
    if (_liveDev == null) {
      for (final d in _prov.inventory) { if (d.id == device.id) { _liveDev = d; break; } }
    }
    final _liveLastSeen = _liveDev?.lastSeen ?? _liveDev?.lastUpdate
        ?? device.lastSeen ?? device.lastUpdate;

    // ⚠️ الموديل يقرأ كل بياناته (سرعة/حالة/محرك/موقع) من الكائن الحي (provider، محدّث
    // WS+poll لحظيًا) عشان يطابق الماركر ويتجنّب «الكاش القديم» لو _popupDevice انفصل بعد
    // poll يستبدل القائمة. (view_as يفضل _popupDevice من _refreshScopedDevices — ميتاداتا
    // العميل الصح، لأن provider.devices بتاعة الديلر فيها ميتاداتا قديمة للعميل.)
    if (widget.viewAsUserId == null && _liveDev != null) device = _liveDev;

    final dotColor = device.isInactive ? const Color(0xFFF59E0B)
        : device.isMoving ? const Color(0xFF4CAF50)
        : device.isOnline ? const Color(0xFF2196F3)
        : const Color(0xFF757575);

    // «متوقف منذ» = آخر حركة (lastUpdate) فقط — حاجة منفصلة عن المحرك (ACC). زي الويب بالظبط.
    final st = device.isMoving
        ? tr('st_moving', {'s': device.speedKmh})
        : device.isInactive
            ? tr('st_needs_activation')
            : device.isOnline
                ? tr('st_online_stopped', {'t': _formatTime(device.lastUpdate)})
                : tr('st_offline_since', {'t': _formatTime(device.lastUpdate)});

    // حالة المحرك (مستقل تماماً عن الحركة)
    final String ignText;
    if (device.ignition == null) {
      ignText = tr('eng_unknown');
    } else if (device.ignition == true) {
      final since = _formatTime(device.lastIgnitionOn ?? device.lastUpdate);
      ignText = tr('eng_on_since', {'t': since});
    } else {
      final since = _formatTime(device.lastIgnitionOff ?? device.lastUpdate);
      ignText = tr('eng_off_since', {'t': since});
    }

    final surfaceColor = Theme.of(context).colorScheme.surface;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final divColor = Theme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: divColor),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 14, offset: Offset(0, 4))],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: onSurface, fontFamily: 'Cairo')),
                  Text(st, style: TextStyle(fontSize: 10, color: device.isMoving ? const Color(0xFF6BA539) : const Color(0xFF8892A4), fontWeight: device.isMoving ? FontWeight.w600 : FontWeight.normal, fontFamily: 'Cairo')),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${device.deviceType} - ${device.icon}', style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
                      const SizedBox(height: 2),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.access_time, size: 9, color: Color(0xFF8892A4)),
                        const SizedBox(width: 3),
                        Text(_liveClock(), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
                      ]),
                    ],
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _showPopup = false),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF8892A4)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Builder(builder: (_) {
            // capability-aware: البطارية تظهر لو الجهاز بيبعتها (battery != null)؛
            // الكهرباء تُخفى لأجهزة gps103 (TK — مابتبعتش power). المحرك يفضل (قابل للتحكم).
            final gps103 = isGps103Model(device.deviceType);
            final boxes = <Widget>[
              _InfoBox(label: tr('ib_speed'), value: device.speedKmh, valueColor: const Color(0xFF2196F3)),
            ];
            // العرض حسب الموديل: GT06N (وغير gps103) يعرض البطارية دايمًا (حتى لو «-»)؛ TK/gps103 يخفيها.
            if (!gps103) {
              boxes.add(_InfoBox(label: tr('ib_battery'), value: device.batteryDisplay, valueColor: const Color(0xFF6BA539), icon: _batteryIcon(device.batteryDisplay), iconColor: const Color(0xFF6BA539)));
            }
            if (!gps103) {
              boxes.add(_InfoBox(label: tr('ib_power'), value: (device.powerConnected || device.charge) ? tr('ib_connected') : tr('ib_disconnected'), icon: (device.powerConnected || device.charge) ? Icons.power : Icons.power_off, iconColor: (device.powerConnected || device.charge) ? const Color(0xFF6BA539) : const Color(0xFF8892A4)));
            }
            boxes.add(_InfoBox(label: tr('ib_engine'), value: ignText, dotColor: device.ignition == true ? Colors.blue : const Color(0xFF8892A4)));
            final children = <Widget>[];
            for (var i = 0; i < boxes.length; i++) {
              if (i > 0) children.add(const SizedBox(width: 6));
              children.add(boxes[i]);
            }
            return Row(children: children);
          }),
          if (device.lat != null && device.lng != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.location_on, size: 10, color: const Color(0xFF8892A4)),
              const SizedBox(width: 3),
              Expanded(child: _AsyncAddressText(
                key: ValueKey('addr_${device.id}'),
                lat: device.lat!, lng: device.lng!,
                style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo'),
              )),
              if (_liveLastSeen != null)
                Text(
                  tr('dev_last_update', {'t': _formatTime(_liveLastSeen)}),
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo'),
                ),
            ]),
          ] else ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.location_off, size: 10, color: Color(0xFFFF9800)),
              const SizedBox(width: 4),
              // الجهاز المتصل بدون GPS = "متصل، لسه مفيش GPS"؛ الجهاز اللي عمره ما بعت = "يحتاج تنشيط"
              Text(tr(device.isInactive ? 'st_needs_activation' : 'dev_no_gps_yet'),
                  style: const TextStyle(fontSize: 9, color: Color(0xFFFF9800), fontFamily: 'Cairo')),
            ]),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _openReplay(device),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC41E3A),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(tr('btn_show_route'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, fontFamily: 'Cairo')),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _openReports(device),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(tr('btn_reports'), style: TextStyle(fontSize: 11, fontFamily: 'Cairo', color: onSurface)),
                ),
              ),
              if (!context.read<AppProvider>().isViewOnly) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _openCommand(device),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(tr('btn_send_command'), style: TextStyle(fontSize: 9, fontFamily: 'Cairo', color: onSurface)),
                  ),
                ),
              ],
              if (device.lat != null && device.lng != null) ...[
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    final url = 'https://www.google.com/maps/dir/?api=1&destination=${device.lat},${device.lng}&travelmode=driving';
                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(tr('btn_navigate'), style: TextStyle(fontSize: 11, fontFamily: 'Cairo', color: onSurface)),
                ),
              ),
              ], // end if hasPosition (navigate button)
            ],
          ),
        ],
      ),
    );
  }

  // ?? Vehicle Icon Picker ??????????????????????????????????????????????????
  static const _vehicleIcons = [
    {'key': 'car',        'label': 'سيارة'},
    {'key': 'suv',        'label': 'SUV'},
    {'key': 'pickup',     'label': 'بيك أب'},
    {'key': 'van',        'label': 'فان'},
    {'key': 'bus',        'label': 'باص'},
    {'key': 'truck',      'label': 'شاحنة'},
    {'key': 'motorcycle', 'label': 'دراجة'},
    {'key': 'tuk_tuk',    'label': 'توك توك'},
    {'key': 'excavator',  'label': 'حفّار'},
    {'key': 'tractor',    'label': 'جرار'},
    {'key': 'boat',       'label': 'قارب'},
    {'key': 'person',     'label': 'شخص'},
    {'key': 'arrow',      'label': 'سهم'},
  ];

  // ?? My Location ??????????????????????????????????????????????????????????
  Future<void> _goToMyLocation() async {
    try {
      final location = loc.Location();

      // 1) check if location service enabled, request to enable if not
      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr('loc_enable_gps'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
              backgroundColor: const Color(0xFFC41E3A),
            ));
          }
          return;
        }
      }

      // 2) check permission, request if denied
      loc.PermissionStatus permission = await location.hasPermission();
      if (permission == loc.PermissionStatus.denied) {
        permission = await location.requestPermission();
        if (permission != loc.PermissionStatus.granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr('loc_denied'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
              backgroundColor: const Color(0xFFC41E3A),
            ));
          }
          return;
        }
      }

      // 3) enable blue dot on the map (force GoogleMap rebuild after permission granted)
      if (!_myLocationEnabled && mounted) {
        setState(() => _myLocationEnabled = true);
        await Future.delayed(const Duration(milliseconds: 300));
      }

      // 4) get current position
      final pos = await location.getLocation();
      if (pos.latitude == null || pos.longitude == null) return;

      // 5) animate camera to user position
      if (_mapController != null) {
        _mapController!.animateCamera(CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(pos.latitude!, pos.longitude!), zoom: 16),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('loc_error', {'e': '$e'}), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
          backgroundColor: const Color(0xFFC41E3A),
        ));
      }
    }
  }

  // ?? Alerts for device ????????????????????????????????????????????????????
  void _openAlerts(DeviceModel device) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DeviceAlertsScreen(device: device),
    ));
  }

  void _openGeofence(DeviceModel device) {
    openDeviceGeofence(context, device);
  }

  void _openIconPicker(DeviceModel device) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.white24,
                borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 12),
        Text(tr('icon_shape'),
            style: const TextStyle(color: Colors.white, fontFamily: 'Cairo',
                fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          child: GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: _vehicleIcons.map((v) {
              final isSelected = (device.icon ?? 'car') == v['key'];
              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  // تحديث فوري (optimistic): حدّث الأيقونة محلياً وأعد بناء الماركر
                  // على طول — بدون انتظار رد السيرفر (كان بياخد وقت يظهر).
                  final provider = context.read<AppProvider>();
                  _iconOverrides[device.id] = v['key']!;
                  _iconCache.removeWhere((k, _) => k.contains(device.name));
                  _buildMarkers(provider.devices);
                  // الحفظ على السيرفر في الخلفية (بدون await)
                  ApiService.request('update_device', {
                    'device_id': device.id,
                    'icon': v['key'],
                  }).catchError((_) => <String, dynamic>{});
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFC41E3A).withOpacity(0.15)
                        : const Color(0xFF0f1f35),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFFC41E3A)
                          : Colors.white.withOpacity(0.08),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(44, 30),
                        painter: _VehicleIconPainter(
                            v['key']!, const Color(0xFF2196F3)),
                      ),
                      const SizedBox(height: 4),
                      Text(v['key'] == 'suv' ? 'SUV' : tr('veh_${v['key']}'),
                          style: TextStyle(
                            color: isSelected ? const Color(0xFFC41E3A) : Colors.white60,
                            fontFamily: 'Cairo', fontSize: 9,
                          )),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ]),
    );
  }

  // Map type cycling
  int _mapTypeIndex = 0;
  final _mapTypes = [MapType.normal, MapType.satellite, MapType.hybrid];
  final _mapTypeLabels = ['mt_map', 'mt_satellite', 'mt_hybrid'];

  String get _mapTypeLabel => tr(_mapTypeLabels[_mapTypeIndex]);

  void _cycleMapType() {
    setState(() {
      _mapTypeIndex = (_mapTypeIndex + 1) % _mapTypes.length;
      _mapType = _mapTypes[_mapTypeIndex];
    });
  }

  // ??? Modals ???????????????????????????????????????????????????????????????

  void _openCommand(DeviceModel device) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommandModal(device: device),
    );
  }

  void _openReplay(DeviceModel device) {
    String selectedPeriod = 'today';
    final speedCtrl = TextEditingController(text: '120');
    DateTime customFrom = DateTime.now().copyWith(hour: 0, minute: 0, second: 0);
    DateTime customTo   = DateTime.now();
    String? distKm;            // total km for selected period (shown before viewing)
    bool distLoading = false;
    bool distStarted = false;

    String _fmtDt(DateTime dt) {
      String p(int n) => n.toString().padLeft(2, '0');
      return "${p(dt.day)}/${p(dt.month)}/${dt.year}  ${p(dt.hour)}:${p(dt.minute)}";
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1e293b),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> loadDist() async {
            if (ctx.mounted) setS(() { distLoading = true; });
            try {
              final range = selectedPeriod == 'custom'
                  ? {'from': customFrom.toUtc().toIso8601String(),
                     'to':   customTo.toUtc().toIso8601String()}
                  : ApiService.getDateRange(selectedPeriod);
              final r = await ApiService.getReportSummary(
                  deviceId: device.id, from: range['from']!, to: range['to']!);
              if (!ctx.mounted) return;
              setS(() { distKm = r['km'] == null ? null : '${r['km']}'; distLoading = false; });
            } catch (_) {
              if (ctx.mounted) setS(() { distLoading = false; });
            }
          }

          Future<void> pickDt(bool isFrom) async {
            final init = isFrom ? customFrom : customTo;
            final result = await showWheelDateTime(ctx, init);
            if (result == null) return;
            setS(() { if (isFrom) customFrom = result; else customTo = result; });
            loadDist();
          }

          if (!distStarted) {
            distStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) { loadDist(); });
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 14),
              Row(children: [
                const Icon(Icons.route, color: Color(0xFFC41E3A), size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('rv_title', {'name': device.name}),
                    style: const TextStyle(color: Colors.white, fontFamily: 'Cairo',
                        fontSize: 14, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 14),
              Text(tr('rv_period'),
                  style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 11)),
              const SizedBox(height: 8),
              Row(children: [
                for (final e in [
                  {'l': tr('pd_hour'),      'v': 'hour'},
                  {'l': tr('pd_today'),     'v': 'today'},
                  {'l': tr('pd_yesterday'), 'v': 'yesterday'},
                  {'l': tr('pd_custom'),    'v': 'custom'},
                ])
                  Expanded(child: GestureDetector(
                    onTap: () { setS(() => selectedPeriod = e['v']!); loadDist(); },
                    child: Container(
                      margin: const EdgeInsets.only(left: 5),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: selectedPeriod == e['v'] ? const Color(0xFFC41E3A) : const Color(0xFF0f3460),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: selectedPeriod == e['v']
                            ? const Color(0xFFC41E3A) : const Color(0xFF444444)),
                      ),
                      child: Text(e['l']!, textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 11)),
                    ),
                  )),
              ]),
              if (selectedPeriod == 'custom') ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => pickDt(true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0f1f35),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF444444)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.calendar_today, color: Color(0xFF6BA539), size: 16),
                      const SizedBox(width: 8),
                      Text(tr('lbl_from'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 12)),
                      Text(_fmtDt(customFrom), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 12)),
                    ]),
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => pickDt(false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0f1f35),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF444444)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.calendar_today, color: Color(0xFFC41E3A), size: 16),
                      const SizedBox(width: 8),
                      Text(tr('lbl_to'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 12)),
                      Text(_fmtDt(customTo), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 12)),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Text(tr('lbl_speed_limit'), style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12)),
                const SizedBox(width: 10),
                SizedBox(width: 70, child: TextField(
                  controller: speedCtrl, keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 13),
                  decoration: InputDecoration(isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    filled: true, fillColor: const Color(0xFF0f1f35),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF444444))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF444444)))),
                )),
                const SizedBox(width: 6),
                Text(tr('unit_kmh'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 11)),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f1f35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2a3a52)),
                ),
                child: Row(children: [
                  const Icon(Icons.straighten, color: Color(0xFF6BA539), size: 16),
                  const SizedBox(width: 8),
                  Text(tr('sm_distance'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 12)),
                  const Spacer(),
                  if (distLoading)
                    const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6BA539)))
                  else
                    Text('${distKm ?? '—'} ${tr('unit_km')}',
                        style: const TextStyle(color: Color(0xFF6BA539),
                            fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold)),
                ]),
              ),
              const SizedBox(height: 14),
              SizedBox(width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC41E3A),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.play_arrow, color: Colors.white),
                  label: Text(tr('rv_show_route'), style: const TextStyle(color: Colors.white,
                      fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    // التحقق من الفترة المخصصة: النهاية بعد البداية + حد أقصى 30 يوم
                    if (selectedPeriod == 'custom') {
                      if (!customTo.isAfter(customFrom)) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(tr('rv_invalid_range'), style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: const Color(0xFFC41E3A)));
                        return;
                      }
                      if (customTo.difference(customFrom).inDays > 30) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(tr('rv_max_30_days'), style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: const Color(0xFFC41E3A)));
                        return;
                      }
                    }
                    final lim = double.tryParse(speedCtrl.text) ?? 120;
                    Navigator.pop(ctx);
                    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                      builder: (_) => _RoutePlaybackScreen(
                        device: device,
                        initialPeriod: selectedPeriod,
                        speedLimit: lim,
                        customFrom: selectedPeriod == 'custom' ? customFrom : null,
                        customTo:   selectedPeriod == 'custom' ? customTo   : null,
                      ),
                    ));
                  },
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  void _openReports(DeviceModel device) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 1.0, minChildSize: 0.6, maxChildSize: 1.0, expand: false,
        builder: (_, sc) => _ReportsModal(device: device),
      ),
    );
  }
}

// ??? Map Control Button ???????????????????????????????????????????????????????

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  const _MapBtn({required this.icon, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2196F3) : Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? const Color(0xFF2196F3) : const Color(0xFFE8EAEF)),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 5)],
        ),
        child: Icon(icon, size: 16, color: active ? Colors.white : const Color(0xFF1A1F2E)),
      ),
    );
  }
}

// ??? Alert Toggle Row ?????????????????????????????????????????????????????????
class _AlertToggleRow extends StatefulWidget {
  final int deviceId;
  final String label;
  final String alertKey;
  final IconData icon;
  const _AlertToggleRow({required this.deviceId, required this.label, required this.alertKey, required this.icon, super.key});
  @override
  State<_AlertToggleRow> createState() => _AlertToggleRowState();
}

class _AlertToggleRowState extends State<_AlertToggleRow> {
  bool _enabled = true;
  final TextEditingController _speedCtrl = TextEditingController(text: '120');
  @override
  void dispose() { _speedCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: const Color(0xFF1A2236), borderRadius: BorderRadius.circular(8)),
            child: Icon(widget.icon, size: 16, color: _enabled ? const Color(0xFFF59E0B) : Colors.white38),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(widget.label,
              style: TextStyle(color: _enabled ? Colors.white : Colors.white38, fontFamily: 'Cairo', fontSize: 13))),
          Switch(
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            activeColor: const Color(0xFFF59E0B),
            inactiveTrackColor: Colors.white12,
          ),
        ]),
      ),
      if (widget.alertKey == 'overspeed' && _enabled)
        Padding(
          padding: const EdgeInsets.only(right: 44, bottom: 6),
          child: Row(children: [
            Text(tr('lbl_speed_limit'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 12)),
            SizedBox(width: 70, child: TextField(
              controller: _speedCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 13),
              decoration: InputDecoration(
                suffixText: tr('unit_kmh'),
                suffixStyle: const TextStyle(color: Colors.white38, fontFamily: 'Cairo', fontSize: 11),
                filled: true, fillColor: const Color(0xFF1A2236),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            )),
          ]),
        ),
    ]);
  }
}

// ??? Info Box ?????????????????????????????????????????????????????????????????

class _InfoBox extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;
  final Color? iconColor;
  final Color? dotColor;
  const _InfoBox({required this.label, required this.value, this.valueColor, this.icon, this.iconColor, this.dotColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (dotColor != null) ...[
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
                  const SizedBox(width: 4),
                ],
                Text(label, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 9, fontFamily: 'Cairo')),
              ],
            ),
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 12, color: iconColor ?? const Color(0xFF8892A4)),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: valueColor ?? Theme.of(context).colorScheme.onSurface,
                      fontFamily: 'Cairo',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ??? Command Modal ????????????????????????????????????????????????????????????

class _CommandModal extends StatefulWidget {
  final DeviceModel device;
  const _CommandModal({required this.device});

  @override
  State<_CommandModal> createState() => _CommandModalState();
}

class _CommandModalState extends State<_CommandModal> {
  String _selectedCmd = 'getLocation';
  bool _loading = false;
  String? _result;

  /// هل يُطلب تأكيد كلمة المرور للأوامر الحسّاسة؟ إعداد الحساب نفسه
  /// («إعدادات الحساب ← CMD كلمة مرور»)، ونفسه يسري على الويب.
  bool get _cmdPwOn => context.read<AppProvider>().cmdPasswordRequired;

  final _pwCtrl = TextEditingController();
  final _customCtrl = TextEditingController();
  final _sos1 = TextEditingController();
  final _sos2 = TextEditingController();
  final _sos3 = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSavedSos();
  }

  Future<void> _loadSavedSos() async {
    try {
      final result = await ApiService.request('get_sos', {'deviceId': widget.device.id});
      if (result['success'] == true || result['phone1'] != null) {
        if (mounted) {
          setState(() {
            _sos1.text = result['phone1'] ?? '';
            _sos2.text = result['phone2'] ?? '';
            _sos3.text = result['phone3'] ?? '';
          });
        }
      }
    } catch (_) {}
  }

  static const _commands = [
    {'id': 'getLocation',   'label': 'cmd_location',     'desc': 'cmd_location_d',    'color': Color(0xFF2196F3),  'needsPw': false, 'isSos': false, 'isCustom': false},
    {'id': 'engineStop',    'label': 'cmd_engine_stop',  'desc': 'cmd_engine_stop_d', 'color': Color(0xFFEF5350),  'needsPw': true,  'isSos': false, 'isCustom': false},
    {'id': 'engineResume',  'label': 'cmd_engine_resume','desc': 'cmd_engine_resume_d','color': Color(0xFF4CAF50), 'needsPw': true,  'isSos': false, 'isCustom': false},
    {'id': 'sos',           'label': 'SOS',              'desc': 'cmd_sos_d',         'color': Color(0xFFF59E0B),  'needsPw': false, 'isSos': true,  'isCustom': false},
    {'id': 'deviceStatus',  'label': 'cmd_status',       'desc': 'cmd_status_d',      'color': Color(0xFF6BA539),  'needsPw': false, 'isSos': false, 'isCustom': false},
    {'id': 'getParams',     'label': 'cmd_params',       'desc': 'cmd_params_d',      'color': Color(0xFFA78BFA),  'needsPw': false, 'isSos': false, 'isCustom': false},
    {'id': 'setLocation',   'label': 'cmd_setloc',       'desc': 'cmd_setloc_d',      'color': Color(0xFF06B6D4),  'needsPw': false, 'isSos': false, 'isCustom': false},
    {'id': 'getVersion',    'label': 'cmd_version',      'desc': 'firmware',          'color': Color(0xFFFBBF24),  'needsPw': false, 'isSos': false, 'isCustom': false},
    {'id': 'factoryReset',  'label': 'cmd_reset',        'desc': 'Reset',             'color': Color(0xFFEF5350),  'needsPw': true,  'isSos': false, 'isCustom': false},
    {'id': 'custom',        'label': 'cmd_custom',       'desc': 'cmd_custom_d',      'color': Color(0xFF818CF8),  'needsPw': true,  'isSos': false, 'isCustom': true},
  ];

  Map get _current => _commands.firstWhere((c) => c['id'] == _selectedCmd);

  // capability-aware: أجهزة gps103 (TK) تدعم إيقاف/تشغيل المحرك + الموقع + أمر مخصص فقط.
  // (أوامر GT06 النصية STATUS#/PARAM#/VERSION#/GPRSSET#/RESET# وSOS مابتشتغلش عليها.)
  List get _visibleCommands {
    if (isGps103Model(widget.device.deviceType)) {
      const allowed = {'getLocation', 'engineStop', 'engineResume', 'custom'};
      return _commands.where((c) => allowed.contains(c['id'])).toList();
    }
    return _commands;
  }

  // يسجّل الأمر في تاريخ الأوامر (fire-and-forget، مايعطّلش الـ UI)
  void _logCmd(String cmdText, String status, String result) {
    ApiService.logCommand(deviceId: widget.device.id, cmdType: _selectedCmd, cmdText: cmdText, status: status, result: result).catchError((_) => <String, dynamic>{});
  }

  @override
  Widget build(BuildContext context) {
    final cmd = _current;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('btn_send_command'), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                  Text('${widget.device.name} - ${widget.device.deviceType}', style: const TextStyle(color: Color(0xFF8892A4), fontSize: 10, fontFamily: 'Cairo')),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommandHistoryScreen(device: widget.device))), child: Container(width: 26, height: 26, decoration: BoxDecoration(color: const Color(0x332196F3), shape: BoxShape.circle), child: const Icon(Icons.history, color: Color(0xFF2196F3), size: 15))),
                  const SizedBox(width: 8),
                  GestureDetector(onTap: () => Navigator.pop(context), child: Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), shape: BoxShape.circle), child: const Icon(Icons.close, color: Color(0xFF8892A4), size: 14))),
                ]),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              // padding سفلي ديناميكي يرفع الحقل وزر الإرسال فوق لوحة المفاتيح
              padding: EdgeInsets.fromLTRB(14, 0, 14, 16 + MediaQuery.of(context).viewInsets.bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('cmd_choose'), style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 9, letterSpacing: 0.5, fontFamily: 'Cairo')),
                  const SizedBox(height: 6),
                  GridView.count(
                    crossAxisCount: 2, shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 6, mainAxisSpacing: 6, childAspectRatio: 2.2,
                    children: _visibleCommands.map((c) {
                      final isSel = c['id'] == _selectedCmd;
                      return GestureDetector(
                        onTap: () => setState(() { _selectedCmd = c['id'] as String; _result = null; }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFFC41E3A).withOpacity(0.15) : Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isSel ? const Color(0xFFC41E3A) : Colors.white.withOpacity(0.09)),
                          ),
                          child: Row(
                            children: [
                              Container(width: 6, height: 6, decoration: BoxDecoration(color: c['color'] as Color, shape: BoxShape.circle)),
                              const SizedBox(width: 6),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text(tr(c['label'] as String), style: const TextStyle(color: Color(0xFFE8EAF0), fontSize: 10, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
                                Text(tr(c['desc'] as String), style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 8, fontFamily: 'Cairo')),
                              ])),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  if (cmd['isCustom'] == true) ...[
                    const SizedBox(height: 8),
                    Text(tr('cmd_text'), style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 9, fontFamily: 'Cairo')),
                    const SizedBox(height: 4),
                    _DarkInput(controller: _customCtrl, hint: tr('cmd_custom_hint'), textDirection: TextDirection.ltr),
                  ],
                  if (cmd['isSos'] == true) ...[
                    const SizedBox(height: 8),
                    Text(tr('cmd_emergency'), style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 9, fontFamily: 'Cairo')),
                    const SizedBox(height: 4),
                    _DarkInput(controller: _sos1, hint: tr('cmd_num1'), keyboardType: TextInputType.phone),
                    const SizedBox(height: 5),
                    _DarkInput(controller: _sos2, hint: tr('cmd_num2'), keyboardType: TextInputType.phone),
                    const SizedBox(height: 5),
                    _DarkInput(controller: _sos3, hint: tr('cmd_num3'), keyboardType: TextInputType.phone),
                  ],
                  if (cmd['needsPw'] == true && _cmdPwOn) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFC41E3A).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFC41E3A).withOpacity(0.25)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('cmd_needs_auth'), style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 10, fontFamily: 'Cairo')),
                        const SizedBox(height: 6),
                        _DarkInput(controller: _pwCtrl, hint: tr('cmd_password'), obscure: true),
                      ]),
                    ),
                  ],
                  if (_result != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: const Color(0xFFA5F3FC).withOpacity(0.07),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFA5F3FC).withOpacity(0.2)),
                      ),
                      child: Text(_result!, style: const TextStyle(color: Color(0xFFA5F3FC), fontSize: 11, fontFamily: 'Cairo'), textAlign: TextAlign.center),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC41E3A),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _loading
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text(tr('cmd_send'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final cmd = _current;
    setState(() { _loading = true; _result = null; });

    try {
      // getLocation - يفتح موديل داخل التطبيق (زي موديل الإشعارات): خريطة + العنوان بلغة التطبيق
      if (_selectedCmd == 'getLocation') {
        final d = widget.device;
        if (d.lat != null && d.lng != null) {
          setState(() { _loading = false; _result = null; });
          if (!mounted) return;
          final dt = d.lastSeen ?? d.lastUpdate ?? DateTime.now();
          final ts = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlertDetailScreen(
            alert: {'lat': d.lat, 'lng': d.lng, 'type': 'location'},
            device: d,
            label: I18n.isAr ? 'الموقع الحالي' : 'Current location',
            color: const Color(0xFF2196F3),
            icon: Icons.location_on_outlined,
            timeStr: ts,
          )));
        } else {
          setState(() { _result = tr('res_no_location'); _loading = false; });
        }
        return;
      }

      // (1) Offline Fast-Fail — لا نرسل أي أمر لجهاز غير متصل
      if (widget.device.isOffline) {
        setState(() { _result = tr('res_offline'); _loading = false; });
        return;
      }

      // SOS - إرسال أوامر مخصصة لكل رقم
      if (_selectedCmd == 'sos') {
        final n1 = _sos1.text.trim();
        if (n1.isEmpty) { setState(() { _result = tr('res_enter_one_num'); _loading = false; }); return; }
        // ⚠️ أمر واحد مدمج لا ثلاثة منفصلة: كل `SOS,A,<رقم>#` يكتب في الخانة
        // الأولى ويدوس على سابقه، فكان رقم واحد فقط هو ما يُحفظ. مُثبَت على جهاز
        // حقيقي: `SOS,A,n1,n2,n3#` يملأ الخانات الثلاث، والفراغات تُترك كما هي
        // لمن يملأ رقمًا أو رقمين. (و`A2`/`A3` يتجاهلهما الفيرموير.)
        final sosCmd = 'SOS,A,$n1,${_sos2.text.trim()},${_sos3.text.trim()}#';
        await ApiService.sendCommand(
          deviceId: widget.device.id, type: 'custom', customText: sosCmd,
        );
        // يُسجَّل كبقية الأوامر: مساره كان منفصلًا فلم يكن لأعطاله أي أثر يُفحص
        _logCmd(sosCmd, 'sent', '');
        // حفظ الأرقام في قاعدة البيانات
        await ApiService.request('save_sos', {
          'deviceId': widget.device.id,
          'phone1': n1,
          'phone2': _sos2.text.trim(),
          'phone3': _sos3.text.trim(),
        });
        setState(() { _result = tr('res_sos_saved'); _loading = false; });
        return;
      }

      // أوامر تحتاج كلمة مرور
      final needsPw = _cmdPwOn && ['engineStop', 'engineResume', 'factoryReset', 'custom'].contains(_selectedCmd);
      if (needsPw) {
        if (_pwCtrl.text.trim().isEmpty) { setState(() { _result = tr('res_enter_pw'); _loading = false; }); return; }
        final verify = await ApiService.verifyPassword(_pwCtrl.text.trim());
        if (verify['success'] != true) { setState(() { _result = tr('res_wrong_pw'); _loading = false; }); return; }
      }

      // خريطة الأوامر المخصصة
      final cmdMap = {
        'deviceStatus': 'STATUS#',
        'getParams': 'PARAM#',
        'getVersion': 'VERSION#',
        'setLocation': 'GPRSSET#',
        'factoryReset': 'RESET#',
      };

      String type = _selectedCmd;
      String? customText;

      if (cmdMap.containsKey(_selectedCmd)) {
        type = 'custom';
        customText = cmdMap[_selectedCmd];
      } else if (_selectedCmd == 'custom') {
        type = 'custom';
        customText = _customCtrl.text.trim();
      }

      // أوامر تحتاج انتظار رد من الجهاز
      final needsReply = ['deviceStatus', 'getParams', 'getVersion', 'setLocation', 'factoryReset', 'custom', 'engineStop', 'engineResume'].contains(_selectedCmd);

      // مفتاح فريد لكل حدث (id إن وُجد، وإلا وقت الحدث)
      String evKey(dynamic e) {
        final id = e['id'] ?? e['eventId'];
        if (id != null) return 'id:$id';
        return 't:${e['eventTime'] ?? e['serverTime'] ?? e['attributes']?['result'] ?? ''}';
      }
      Future<List<dynamic>> fetchEvents() async {
        final now = DateTime.now().toUtc();
        final from = now.subtract(const Duration(seconds: 120)).toIso8601String();
        final to = now.add(const Duration(seconds: 60)).toIso8601String();
        final evResult = await ApiService.request('get_events', {
          'deviceId': widget.device.id,
          'type': 'commandResult',
          'from': from, 'to': to, 'limit': 10,
          'nodedup': 1, // لا تدمج ردود الأوامر المتتالية (نفس النوع commandResult)
        });
        return List<dynamic>.from(evResult['data'] ?? evResult['events'] ?? (evResult is List ? evResult : []));
      }

      // ⚠️ خط الأساس يُلتقط قبل الإرسال — لتفادي ابتلاع رد سريع من الجهاز (1-2ث) ضمن خط الأساس
      final Set<String> baselineKeys = needsReply ? (await fetchEvents()).map(evKey).toSet() : <String>{};

      // مرحلة الإرسال: تعتمد على مهلة الشبكة الداخلية في ApiService (15ث).
      // مهلة "رد الجهاز" مطبّقة في حلقة الاستطلاع أدناه فقط.
      final result = await ApiService.sendCommand(
        deviceId: widget.device.id,
        type: type,
        customText: customText,
      );

      if (result['queued'] == true) {
        final msg = tr('res_speed_pending', {'s': '${result['speed']}'});
        _logCmd(customText ?? '', 'queued', msg);
        setState(() { _loading = false; _result = msg; });
        return;
      }

      if (result['success'] != true) {
        final msg = '${result['error'] ?? tr('res_error')}';
        _logCmd(customText ?? '', 'failed', msg);
        setState(() { _result = msg; _loading = false; });
        return;
      }

      if (needsReply) {
        setState(() => _result = tr('res_waiting'));
        // استجابة ديناميكية: نستطلع رد الجهاز كل ثانية حتى يصل، مع مهلة قصوى 20 ثانية.
        // خط الأساس (baselineKeys) و fetchEvents مُعرَّفان أعلاه قبل الإرسال.

        final deadline = DateTime.now().add(const Duration(seconds: 20));
        dynamic raw;
        bool gotReply = false;
        int wait = 700; // سريع أولًا حيث يصل الرد عادةً، ثم يتباطأ حتى 2s
        while (DateTime.now().isBefore(deadline)) {
          await Future.delayed(Duration(milliseconds: wait));
          if (wait < 2000) wait = wait + 300 > 2000 ? 2000 : wait + 300;
          if (!mounted) return;
          final events = await fetchEvents();
          // نقبل فقط حدثاً جديداً لم يكن في خط الأساس (رد أمرنا الحالي)
          dynamic fresh;
          for (final e in events) {
            if (!baselineKeys.contains(evKey(e))) { fresh = e; break; }
          }
          if (fresh != null) {
            raw = fresh['attributes']?['result'] ?? fresh['attributes']?['data'];
            gotReply = true;
            break;
          }
        }
        if (!mounted) return;
        if (gotReply) {
          final rawStr = (raw ?? '').toString();
          final rawUp = rawStr.toUpperCase();
          String shown;
          if (_selectedCmd == 'engineStop' || _selectedCmd == 'engineResume') {
            // الجهاز يرد بـ RELAY 1 OK (قطع المحرك) أو RELAY 0 OK (تشغيل المحرك)
            if (rawUp.contains('RELAY 1')) {
              shown = tr('res_engine_stopped');
            } else if (rawUp.contains('RELAY 0')) {
              shown = tr('res_engine_resumed');
            } else if (rawStr.isNotEmpty) {
              shown = rawStr;
            } else {
              shown = _selectedCmd == 'engineStop' ? tr('res_engine_stopped') : tr('res_engine_resumed');
            }
          } else {
            shown = rawStr.isNotEmpty ? rawStr : tr('res_done');
          }
          _logCmd(customText ?? '', 'success', shown);
          setState(() { _result = shown; _loading = false; });
        } else {
          _logCmd(customText ?? '', 'failed', tr('res_no_reply'));
          setState(() { _result = tr('res_no_reply'); _loading = false; });
        }
      } else {
        final msg = '${result['message'] ?? tr('res_sent_ok')}';
        _logCmd(customText ?? '', 'sent', msg);
        setState(() { _result = msg; _loading = false; });
      }
    } catch (e) {
      setState(() { _result = tr('res_error_e', {'e': '$e'}); _loading = false; });
    }
  }
}

// ??? Replay Modal ?????????????????????????????????????????????????????????????

class CommandHistoryScreen extends StatefulWidget {
  final DeviceModel device;
  const CommandHistoryScreen({super.key, required this.device});
  @override
  State<CommandHistoryScreen> createState() => _CommandHistoryScreenState();
}

class _CommandHistoryScreenState extends State<CommandHistoryScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load([int attempt = 0]) async {
    if (attempt == 0 && mounted) setState(() => _loading = true);
    try {
      final r = await ApiService.getCommandHistory(widget.device.id);
      final List raw = (r['data'] ?? r['items'] ?? []) as List;
      if (!mounted) return;
      setState(() { _items = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(); _loading = false; });
    } catch (_) {
      if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return _load(attempt + 1); }
      if (mounted) setState(() => _loading = false);
    }
  }

  String _cmdLabel(String t) {
    switch (t) {
      case 'deviceStatus': return I18n.isAr ? 'فحص الحالة' : 'Status check';
      case 'getParams':    return I18n.isAr ? 'عرض الإعدادات' : 'Get parameters';
      case 'getVersion':   return I18n.isAr ? 'نسخة الإصدار' : 'Version';
      case 'setLocation':  return I18n.isAr ? 'إعدادات تحديد الموقع' : 'Location settings';
      case 'factoryReset': return I18n.isAr ? 'إعادة الضبط' : 'Factory reset';
      case 'engineStop':   return I18n.isAr ? 'إيقاف المحرك' : 'Engine stop';
      case 'engineResume': return I18n.isAr ? 'تشغيل المحرك' : 'Engine resume';
      case 'getLocation':  return I18n.isAr ? 'الموقع الحالي' : 'Current location';
      case 'sos':          return 'SOS';
      case 'custom':       return I18n.isAr ? 'أمر مخصص' : 'Custom command';
      default:             return t;
    }
  }

  (String, Color) _statusStyle(String s) {
    switch (s) {
      case 'success': return (I18n.isAr ? 'تم بنجاح' : 'Success', const Color(0xFF4CAF50));
      case 'failed':  return (I18n.isAr ? 'فشل' : 'Failed', const Color(0xFFEF5350));
      case 'queued':  return (I18n.isAr ? 'في الانتظار' : 'Queued', const Color(0xFFF59E0B));
      default:        return (I18n.isAr ? 'تم الإرسال' : 'Sent', const Color(0xFF2196F3));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text('${I18n.isAr ? 'تاريخ الأوامر' : 'Command history'} - ${widget.device.name}', style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, color: Colors.white)),
          actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load())],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
            : _items.isEmpty
                ? Center(child: Text(I18n.isAr ? 'لا توجد أوامر بعد' : 'No commands yet', style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo')))
                : RefreshIndicator(
                    onRefresh: () => _load(),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final it = _items[i];
                        final st = _statusStyle((it['status'] ?? '').toString());
                        final txt = (it['result'] ?? '').toString();
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(10)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(_cmdLabel((it['cmd_type'] ?? '').toString()), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600))),
                              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: st.$2.withOpacity(0.15), borderRadius: BorderRadius.circular(6)), child: Text(st.$1, style: TextStyle(color: st.$2, fontFamily: 'Cairo', fontSize: 10, fontWeight: FontWeight.w600))),
                            ]),
                            if (txt.isNotEmpty && txt != st.$1) ...[const SizedBox(height: 4), Text(txt, style: const TextStyle(color: Color(0xFFB0B8C4), fontFamily: 'Cairo', fontSize: 11), textDirection: TextDirection.ltr)],
                            const SizedBox(height: 4),
                            Text((it['created_at'] ?? '').toString(), style: const TextStyle(color: Color(0xFF6B7280), fontFamily: 'Cairo', fontSize: 10), textDirection: TextDirection.ltr),
                          ]),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}

class _ReplayModal extends StatefulWidget {
  final DeviceModel device;
  final Function(Set<Polyline>, LatLngBounds, Set<Marker>)? onRouteLoaded;
  const _ReplayModal({required this.device, this.onRouteLoaded});

  @override
  State<_ReplayModal> createState() => _ReplayModalState();
}

class _ReplayModalState extends State<_ReplayModal> {
  String _period = 'today';
  bool _loading = false;
  bool _loaded = false;
  final _speedCtrl = TextEditingController(text: '120');
  DateTime? _customFrom;
  DateTime? _customTo;
  Map<String, dynamic>? _routeData;

  // Playback state
  List<Map<String, dynamic>> _positions = [];
  int _currentIdx = 0;
  bool _playing = false;
  double _speed = 1.0;
  Timer? _playTimer;

  final List<Map<String, dynamic>> _speeds = [
    {'label': 'x0.1', 'v': 0.1}, {'label': 'x0.25', 'v': 0.25},
    {'label': 'x0.5', 'v': 0.5}, {'label': 'x1', 'v': 1.0},
    {'label': 'x2', 'v': 2.0}, {'label': 'x4', 'v': 4.0},
    {'label': 'x6', 'v': 6.0}, {'label': 'x8', 'v': 8.0},
  ];

  @override
  void dispose() {
    _playTimer?.cancel();
    _speedCtrl.dispose();
    super.dispose();
  }

  void _startPlayback() {
    _playTimer?.cancel();
    final intervalMs = (300 / _speed).round().clamp(30, 3000);
    _playTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!mounted) return;
      if (_currentIdx >= _positions.length - 1) {
        setState(() => _playing = false);
        _playTimer?.cancel();
        return;
      }
      setState(() => _currentIdx++);
      _updateMapPosition(_currentIdx);
    });
  }

  Future<BitmapDescriptor> _buildArrowIcon(double angleDeg, double speedKmh) async {
    final size = 56.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);

    // تحويل الزاوية
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angleDeg * math.pi / 180);
    canvas.translate(-center.dx, -center.dy);

    // ظل
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final path = Path();
    path.moveTo(size / 2, 4);
    path.lineTo(size - 8, size - 8);
    path.lineTo(size / 2, size - 14);
    path.lineTo(8, size - 8);
    path.close();
    canvas.drawPath(path.shift(const Offset(2, 2)), shadowPaint);

    // السهم الرئيسي
    final arrowColor = speedKmh > 100 ? const Color(0xFFC41E3A) : const Color(0xFF6BA539);
    final arrowPaint = Paint()..color = arrowColor;
    canvas.drawPath(path, arrowPaint);

    // حافة بيضاء
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path, borderPaint);

    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) return BitmapDescriptor.fromBytes(data.buffer.asUint8List());
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  double _calcBearing(double lat1, double lon1, double lat2, double lon2) {
    final toRad = (double d) => d * 3.14159265358979 / 180;
    final dLon = toRad(lon2 - lon1);
    final y = math.sin(dLon) * math.cos(toRad(lat2));
    final x = math.cos(toRad(lat1)) * math.sin(toRad(lat2)) -
              math.sin(toRad(lat1)) * math.cos(toRad(lat2)) * math.cos(dLon);
    return ((math.atan2(y, x) * 180 / 3.14159265358979) + 360) % 360;
  }

  Set<Polyline> _buildColoredRoute(List<Map<String, dynamic>> positions, double speedLimit) {
    final polylines = <Polyline>{};
    for (int i = 0; i < positions.length - 1; i++) {
      final p1 = positions[i];
      final p2 = positions[i + 1];
      final lat1 = double.tryParse(p1['latitude']?.toString() ?? '') ?? 0;
      final lng1 = double.tryParse(p1['longitude']?.toString() ?? '') ?? 0;
      final lat2 = double.tryParse(p2['latitude']?.toString() ?? '') ?? 0;
      final lng2 = double.tryParse(p2['longitude']?.toString() ?? '') ?? 0;
      if (lat1 == 0 || lat2 == 0) continue;
      final spd = ((p1['speed'] ?? 0) as num).toDouble() * 1.852;
      final color = spd > speedLimit ? const Color(0xFFC41E3A) : const Color(0xFF6BA539);
      polylines.add(Polyline(
        polylineId: PolylineId('seg_$i'),
        points: [LatLng(lat1, lng1), LatLng(lat2, lng2)],
        color: color,
        width: 5,
      ));
    }
    return polylines;
  }

  Set<Marker> _buildStopMarkers(List<Map<String, dynamic>> positions) {
    final markers = <Marker>{};
    const stopSpeed = 2.0;
    const stopTime = 60;
    int? stopStart;
    int stopIdx = 0;

    for (int i = 0; i < positions.length; i++) {
      final spd = ((positions[i]['speed'] ?? 0) as num).toDouble() * 1.852;
      if (spd < stopSpeed) {
        stopStart ??= i;
      } else {
        if (stopStart != null) {
          final t1 = DateTime.tryParse(positions[stopStart]['fixTime']?.toString() ?? '');
          final t2 = DateTime.tryParse(positions[i - 1]['fixTime']?.toString() ?? '');
          if (t1 != null && t2 != null) {
            final dur = t2.difference(t1).inSeconds;
            if (dur >= stopTime) {
              final p = positions[stopStart];
              final lat = double.tryParse(p['latitude']?.toString() ?? '') ?? 0;
              final lng = double.tryParse(p['longitude']?.toString() ?? '') ?? 0;
              if (lat != 0) {
                final mins = dur ~/ 60;
                markers.add(Marker(
                  markerId: MarkerId('stop_${stopIdx++}'),
                  position: LatLng(lat, lng),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                  infoWindow: InfoWindow(
                    title: tr('tm_stop'),
                    snippet: '${tr('tm_duration_min', {'n': '$mins'})}  •  ${tr('tm_tap_navigate')}',
                    onTap: () => navigateToPoint(lat, lng),
                  ),
                ));
              }
            }
          }
          stopStart = null;
        }
      }
    }
    return markers;
  }

  Future<void> _updateMapPosition(int idx) async {
    if (idx >= _positions.length || widget.onRouteLoaded == null) return;
    final p = _positions[idx];
    final lat = double.tryParse(p['latitude']?.toString() ?? '') ?? 0;
    final lng = double.tryParse(p['longitude']?.toString() ?? '') ?? 0;
    if (lat == 0 && lng == 0) return;

    final speedLimit = double.tryParse(_speedCtrl.text) ?? 120;

    // Full colored route
    final polylines = _buildColoredRoute(_positions, speedLimit);

    // All points for bounds
    final allPoints = _positions
        .where((pos) => pos['latitude'] != null && pos['longitude'] != null)
        .map((pos) => LatLng(
              double.tryParse(pos['latitude'].toString()) ?? 0,
              double.tryParse(pos['longitude'].toString()) ?? 0,
            ))
        .toList();

    if (allPoints.isEmpty) return;

    final bounds = LatLngBounds(
      southwest: LatLng(
        allPoints.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
        allPoints.map((p) => p.longitude).reduce((a, b) => a < b ? a : b),
      ),
      northeast: LatLng(
        allPoints.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
        allPoints.map((p) => p.longitude).reduce((a, b) => a > b ? a : b),
      ),
    );

    // حساب الاتجاه زي السيرفر
    double angle = 0;
    if (idx < _positions.length - 1) {
      final next = _positions[idx + 1];
      final lat2 = double.tryParse(next['latitude']?.toString() ?? '') ?? 0;
      final lng2 = double.tryParse(next['longitude']?.toString() ?? '') ?? 0;
      if (lat2 != 0) angle = _calcBearing(lat, lng, lat2, lng2);
    } else if (idx > 0) {
      final prev = _positions[idx - 1];
      final lat0 = double.tryParse(prev['latitude']?.toString() ?? '') ?? 0;
      final lng0 = double.tryParse(prev['longitude']?.toString() ?? '') ?? 0;
      if (lat0 != 0) angle = _calcBearing(lat0, lng0, lat, lng);
    }

    // رسم سهم متحرك مع الاتجاه
    final arrowIcon = await _buildArrowIcon(angle, _getSpeed(idx));

    // Stop markers
    final stopMarkers = _buildStopMarkers(_positions);

    // Playback marker
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('playback'),
        position: LatLng(lat, lng),
        icon: arrowIcon,
        anchor: const Offset(0.5, 0.5),
        zIndex: 10,
      ),
      Marker(
        markerId: const MarkerId('route_start'),
        position: allPoints.first,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: tr('tm_trip_start')),
      ),
      Marker(
        markerId: const MarkerId('route_end'),
        position: allPoints.last,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: tr('tm_trip_end')),
      ),
      ...stopMarkers,
    };

    widget.onRouteLoaded!(polylines, bounds, markers);
  }

  String _formatTime(String? isoTime) {
    if (isoTime == null) return '--:--';
    final dt = DateTime.tryParse(isoTime);
    if (dt == null) return '--:--';
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  double _getSpeed(int idx) {
    if (idx >= _positions.length) return 0;
    final s = _positions[idx]['speed'];
    return ((s ?? 0) as num).toDouble() * 1.852;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 10, bottom: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('rv_show_route'), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                Text(widget.device.name, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 10, fontFamily: 'Cairo')),
              ]),
              GestureDetector(onTap: () => Navigator.pop(context), child: Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), shape: BoxShape.circle), child: const Icon(Icons.close, color: Color(0xFF8892A4), size: 14))),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_positions.isEmpty) ...[
                  Text(tr('rv_choose_period'), style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 9, fontFamily: 'Cairo')),
                  const SizedBox(height: 6),
                  // Period buttons
                  GridView.count(
                    crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 6, mainAxisSpacing: 6, childAspectRatio: 3,
                    children: [
                      {'id': 'hour',      'label': tr('pd_hour_ago')},
                      {'id': 'today',     'label': tr('pd_today')},
                      {'id': 'yesterday', 'label': tr('pd_yesterday')},
                      {'id': 'custom',    'label': tr('pd_custom')},
                    ].map((p) {
                      final isSel = _period == p['id'];
                      return GestureDetector(
                        onTap: () => setState(() { _period = p['id']!; _loaded = false; }),
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFFC41E3A) : const Color(0xFF0F3460),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isSel ? const Color(0xFFC41E3A) : const Color(0xFF444444)),
                          ),
                          child: Text(p['label']!, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'Cairo')),
                        ),
                      );
                    }).toList(),
                  ),
                  if (_period == 'custom') ...[
                    const SizedBox(height: 8),
                    _dateTimeRow(tr('lbl_from2'), _customFrom, (dt) => setState(() => _customFrom = dt), const Color(0xFF6BA539)),
                    const SizedBox(height: 5),
                    _dateTimeRow(tr('lbl_to2'), _customTo, (dt) => setState(() => _customTo = dt), const Color(0xFFC41E3A)),
                  ],
                  ], // end of _positions.isEmpty
                  const SizedBox(height: 8),
                  // Speed limit
                  if (_positions.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withOpacity(0.07)),
                    ),
                    child: Row(children: [
                      Text(tr('lbl_speed_limit'), style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 11, fontFamily: 'Cairo')),
                      const SizedBox(width: 8),
                      SizedBox(width: 65, child: _DarkInput(controller: _speedCtrl, hint: '120', keyboardType: TextInputType.number)),
                      const SizedBox(width: 6),
                      Text(tr('unit_kmh'), style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 10, fontFamily: 'Cairo')),
                    ]),
                  ),
                  if (_loaded && _routeData != null) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      _TripStat(value: '${_routeData!['distance'] ?? 0} ${tr('unit_km')}', label: tr('ts_distance')),
                      const SizedBox(width: 5),
                      _TripStat(value: '${_routeData!['max_speed'] ?? 0} ${tr('unit_kmh')}', label: tr('ts_max_speed'), color: const Color(0xFFEF5350)),
                      const SizedBox(width: 5),
                      _TripStat(value: _routeData!['duration'] ?? '-', label: tr('ts_duration'), color: const Color(0xFFF59E0B)),
                    ]),
                  ],
                  if (_positions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    // Info bar
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(
                        _formatTime(_positions[_currentIdx]['fixTime']?.toString()),
                        style: const TextStyle(color: Color(0xFFA5F3FC), fontSize: 11, fontFamily: 'Cairo'),
                      ),
                      Text(
                        '${_getSpeed(_currentIdx).toStringAsFixed(1)} ${tr('unit_kmh')} | ${_currentIdx + 1}/${_positions.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'Cairo'),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    // Slider
                    SliderTheme(
                      data: SliderThemeData(
                        thumbColor: const Color(0xFFC41E3A),
                        activeTrackColor: const Color(0xFFC41E3A),
                        inactiveTrackColor: Colors.white.withOpacity(0.2),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: _currentIdx.toDouble(),
                        min: 0,
                        max: (_positions.length - 1).toDouble(),
                        onChanged: (v) {
                          setState(() => _currentIdx = v.toInt());
                          _updateMapPosition(_currentIdx);
                        },
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Play/Pause + Speed controls
                    Row(children: [
                      GestureDetector(
                        onTap: () {
                          if (_playing) {
                            _playTimer?.cancel();
                            setState(() => _playing = false);
                          } else {
                            setState(() => _playing = true);
                            _startPlayback();
                          }
                        },
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: const Color(0xFFC41E3A),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 20),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: _speeds.map((s) {
                            final isActive = _speed == s['v'];
                            return GestureDetector(
                              onTap: () {
                                setState(() => _speed = s['v'] as double);
                                if (_playing) { _playTimer?.cancel(); _startPlayback(); }
                              },
                              child: Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: isActive ? const Color(0xFF1565C0) : Colors.white.withOpacity(0.07),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: isActive ? const Color(0xFF1565C0) : Colors.white.withOpacity(0.1)),
                                ),
                                child: Text(s['label'] as String, style: TextStyle(
                                  color: isActive ? Colors.white : Colors.white60,
                                  fontSize: 10, fontFamily: 'Cairo',
                                )),
                              ),
                            );
                          }).toList()),
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 10),
                  if (_positions.isEmpty)
                  Row(children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _loading ? null : _loadRoute,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFC41E3A),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _loading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : Text(tr('rv_show_route'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      onPressed: () => setState(() { _loaded = false; _routeData = null; }),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                        side: BorderSide(color: Colors.white.withOpacity(0.09)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(tr('clear'), style: const TextStyle(color: Color(0xFFAAAAAA), fontFamily: 'Cairo', fontSize: 11)),
                    ),
                  ]),
                  if (_positions.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _playTimer?.cancel();
                        setState(() { _positions = []; _loaded = false; _routeData = null; _playing = false; });
                      },
                      icon: const Icon(Icons.clear, size: 14, color: Color(0xFFAAAAAA)),
                      label: Text('${tr('clear')} ${tr('ctl_route')}', style: const TextStyle(color: Color(0xFFAAAAAA), fontFamily: 'Cairo', fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                        side: BorderSide(color: Colors.white.withOpacity(0.09)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateTimeRow(String label, DateTime? value, Function(DateTime) onPick, Color color) {
    return Row(children: [
      Text(label, style: TextStyle(color: color, fontSize: 10, fontFamily: 'Cairo')),
      const SizedBox(width: 6),
      Expanded(
        child: GestureDetector(
          onTap: () async {
            final dt = await showWheelDateTime(context, value);
            if (dt != null) onPick(dt);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF2D3A4F),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: Text(
              value != null ? '${value.day}/${value.month}/${value.year} ${value.hour}:${value.minute.toString().padLeft(2,'0')}' : tr('pick_datetime'),
              style: TextStyle(color: value != null ? Colors.white : Colors.white.withOpacity(0.3), fontSize: 11, fontFamily: 'Cairo'),
            ),
          ),
        ),
      ),
    ]);
  }

  Future<DateTime?> showDateTimePicker(BuildContext context, DateTime? initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFFC41E3A))),
        child: child!,
      ),
    );
    if (date == null) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return date;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _loadRoute() async {
    setState(() { _loading = true; });
    final provider = context.read<AppProvider>();
    final result = await provider.getReplayRoute(
      deviceId: widget.device.id,
      period: _period,
      customFrom: _customFrom?.toUtc().toIso8601String(),
      customTo: _customTo?.toUtc().toIso8601String(),
    );
    setState(() {
      _loading = false;
      _loaded = result['success'] == true;
      if (_loaded) _routeData = result;
    });

    if (_loaded && result['data'] != null) {
      final filtered = List<Map<String, dynamic>>.from(
        (result['data'] as List)
            .where((p) => p['latitude'] != null && p['longitude'] != null)
            .map((p) => Map<String, dynamic>.from(p as Map))
      );
      if (filtered.isNotEmpty) {
        setState(() {
          _positions = filtered;
          _currentIdx = 0;
          _playing = false;
        });
        _updateMapPosition(0);
      }
    }
  }

}

// ??? Reports Modal ????????????????????????????????????????????????????????????

class _ReportsModal extends StatefulWidget {
  final DeviceModel device;
  const _ReportsModal({required this.device});

  @override
  State<_ReportsModal> createState() => _ReportsModalState();
}

class _ReportsModalState extends State<_ReportsModal> {
  String? _openReport;
  bool _loading = false;
  List<dynamic> _reportRows = []; Map<String, String> _reportSummary = {};
  String _fromDate = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
  String _toDate = DateTime.now().toIso8601String().substring(0, 10);
  late final TextEditingController _spdLimitCtrl = TextEditingController(
    text: (widget.device.speedLimit > 0 ? widget.device.speedLimit : 100).toStringAsFixed(0));

  @override
  void dispose() { _spdLimitCtrl.dispose(); super.dispose(); }

  // ── تصدير التقرير الحالي PDF (بدعم عربي عبر خط Cairo) ──
  bool _exportingPdf = false;
  Future<void> _exportReportPdf() async {
    if (_reportRows.isEmpty || _exportingPdf) return;
    setState(() => _exportingPdf = true);
    try {
      final reg  = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
      final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
      final rt = _openReport ?? '';
      final titleMap = {
        'trips': tr('rep_trips'), 'speed': tr('rep_speed'),
        'geofence': tr('rep_geofence'), 'ignition': tr('rep_ignition'),
        'alerts': tr('rep_alerts'),
      };
      final title = titleMap[rt] ?? tr('reports');

      // أعمدة + بيانات حسب نوع التقرير
      List<String> headers; List<List<String>> data;
      String s(dynamic v) => (v == null || '$v'.isEmpty) ? '-' : '$v';
      if (rt == 'trips') {
        headers = [tr('th_time'), tr('rs_drive')+'/'+tr('rs_stop'), tr('rt_duration'), tr('rt_distance'), tr('rt_max_speed'), tr('rt_start_point')];
        data = _reportRows.map((r) => [
          s(r['time']), (r['status']=='stop'?tr('rs_stop'):tr('rs_drive')),
          s(r['duration']), s(r['value']), s(r['maxSpeed']), s(r['address']),
        ]).toList();
      } else if (rt == 'speed') {
        headers = [tr('th_time'), tr('rt_duration'), tr('rt_min_speed'), tr('rt_max_speed'), tr('rt_distance'), tr('rt_start_point')];
        data = _reportRows.map((r) => [
          s(r['time']), s(r['duration']), s(r['minSpeed']), s(r['maxSpeed']), s(r['distance']), s(r['address']),
        ]).toList();
      } else {
        headers = [tr('th_time'), tr('th_value'), tr('th_location')];
        data = _reportRows.map((r) => [
          s(r['time'] ?? r['eventTime']), s(r['value'] ?? r['type']), s(r['address']),
        ]).toList();
      }

      final doc = pw.Document();
      final theme = pw.ThemeData.withFont(base: reg, bold: bold);
      doc.addPage(pw.MultiPage(
        theme: theme,
        textDirection: pw.TextDirection.rtl,
        margin: const pw.EdgeInsets.all(20),
        header: (ctx) => pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('$title — ${widget.device.name}', style: pw.TextStyle(font: bold, fontSize: 15, color: PdfColor.fromInt(0xFFC41E3A))),
            if (_reportSummary.isNotEmpty)
              pw.Text(_summaryLine(rt), style: pw.TextStyle(font: reg, fontSize: 9, color: PdfColors.grey700)),
            pw.SizedBox(height: 4),
            pw.Divider(color: PdfColors.grey400, thickness: 0.5),
          ]),
        ),
        footer: (ctx) => pw.Align(alignment: pw.Alignment.centerLeft,
          child: pw.Text('${ctx.pageNumber}/${ctx.pagesCount}  •  himaya-track.com', style: pw.TextStyle(font: reg, fontSize: 8, color: PdfColors.grey))),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            headerStyle: pw.TextStyle(font: bold, fontSize: 9, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF1E293B)),
            cellStyle: pw.TextStyle(font: reg, fontSize: 8),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF5F6F8)),
          ),
        ],
      ));
      await Printing.layoutPdf(onLayout: (format) => doc.save(), name: '${title}_${widget.device.name}');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('failed'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  String _summaryLine(String rt) {
    final sm = _reportSummary;
    if (rt == 'geofence') return '${tr('sm_enters')}: ${sm['enters'] ?? '0'}  |  ${tr('sm_exits')}: ${sm['exits'] ?? '0'}';
    final parts = <String>[];
    if (sm['dist'] != null)   parts.add('${tr('sm_distance')}: ${sm['dist']} ${tr('unit_km')}');
    if (sm['dur'] != null)    parts.add('${tr('sm_duration')}: ${sm['dur']}');
    if (sm['maxSpd'] != null) parts.add('${tr('sm_max_speed')}: ${sm['maxSpd']} ${tr('unit_kmh')}');
    if (sm['count'] != null)  parts.add('${rt == 'speed' ? tr('sm_overspeeds') : tr('sm_trips')}: ${sm['count']}');
    return parts.join('  |  ');
  }

  static const _reportTypes = [
    {'id': 'speed',     'label': 'rep_speed',    'sub': 'rep_speed_sub',    'color': Color(0xFFEF5350)},
    {'id': 'geofence',  'label': 'rep_geofence', 'sub': 'rep_geofence_sub', 'color': Color(0xFFA78BFA)},
    {'id': 'trips',     'label': 'rep_trips',    'sub': 'rep_trips_sub',    'color': Color(0xFF00BCD4)},
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(top: 10, bottom: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('rep_title'), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                Text(widget.device.name, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 10, fontFamily: 'Cairo')),
              ]),
              GestureDetector(onTap: () => Navigator.pop(context), child: Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), shape: BoxShape.circle), child: const Icon(Icons.close, color: Color(0xFF8892A4), size: 14))),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              child: Column(
                children: [
                  // Date range
                  Row(children: [
                    Expanded(child: GestureDetector(
                      onTap: () async {
                        final d = await showDatePicker(context: context, initialDate: DateTime.tryParse(_fromDate) ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now(), builder: (c,w) => Theme(data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFFC41E3A))), child: w!));
                        if (d != null) setState(() => _fromDate = d.toIso8601String().substring(0,10));
                      },
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), decoration: BoxDecoration(color: const Color(0xFF2D3A4F), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withOpacity(0.12))), child: Row(children: [const Icon(Icons.calendar_today, color: Color(0xFF6BA539), size: 14), const SizedBox(width: 6), Expanded(child: Text(tr('lbl_from') + _fromDate, style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 11)))])),
                    )),
                    const SizedBox(width: 6),
                    Expanded(child: GestureDetector(
                      onTap: () async {
                        final d = await showDatePicker(context: context, initialDate: DateTime.tryParse(_toDate) ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now(), builder: (c,w) => Theme(data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFFC41E3A))), child: w!));
                        if (d != null) setState(() => _toDate = d.toIso8601String().substring(0,10));
                      },
                      child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), decoration: BoxDecoration(color: const Color(0xFF2D3A4F), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withOpacity(0.12))), child: Row(children: [const Icon(Icons.calendar_today, color: Color(0xFFC41E3A), size: 14), const SizedBox(width: 6), Expanded(child: Text(tr('lbl_to') + _toDate, style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 11)))])),
                    )),
                  ]),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: ElevatedButton.icon(
                    onPressed: () => setState(() { _openReport = null; _reportRows = []; _reportSummary = {}; }),
                    icon: const Icon(Icons.search, size: 14),
                    label: Text(tr('rep_new_search'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0), padding: const EdgeInsets.symmetric(vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  )),
                  const SizedBox(height: 8),
                  // Report types
                  ..._reportTypes.map((rt) => Column(
                    children: [
                      GestureDetector(
                        onTap: () => _toggleReport(rt['id'] as String),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                          decoration: BoxDecoration(
                            color: _openReport == rt['id'] ? const Color(0xFFC41E3A).withOpacity(0.1) : Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _openReport == rt['id'] ? const Color(0xFFC41E3A).withOpacity(0.3) : Colors.white.withOpacity(0.07)),
                          ),
                          child: Row(children: [
                            Container(width: 8, height: 8, decoration: BoxDecoration(color: rt['color'] as Color, shape: BoxShape.circle)),
                            const SizedBox(width: 8),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(tr(rt['label'] as String), style: const TextStyle(color: Color(0xFFE8EAF0), fontSize: 11, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
                              Text(tr(rt['sub'] as String), style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 9, fontFamily: 'Cairo')),
                            ])),
                            if (rt['id'] == 'speed') ...[
                              GestureDetector(
                                onTap: () {},
                                child: SizedBox(
                                  width: 62,
                                  child: TextField(
                                    controller: _spdLimitCtrl,
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Color(0xFF1E293B), fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                                      filled: true,
                                      fillColor: Colors.white,
                                      hintText: tr('unit_kmh'),
                                      hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontFamily: 'Cairo', fontSize: 10),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC41E3A), width: 1.5)),
                                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC41E3A), width: 1.5)),
                                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC41E3A), width: 2)),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (_loading && _openReport == rt['id'])
                              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Color(0xFFC41E3A), strokeWidth: 2))
                            else
                              Text(_openReport == rt['id'] ? 'v' : '>', style: const TextStyle(color: Color(0x40FFFFFF), fontSize: 13)),
                          ]),
                        ),
                      ),
                      if (_openReport == rt['id'] && _reportRows.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: Colors.black.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
                          child: Column(
                            children: [
                              if (_openReport != 'trips' && _openReport != 'speed' && _openReport != 'geofence') Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                color: const Color(0xFF1E293B),
                                child: Row(children: [
                                  _TableHead(_openReport == 'trips' ? tr('th_start_time') : tr('th_time')), _TableHead(_openReport == 'trips' ? tr('th_distance') : tr('th_value')), _TableHead(tr('th_location')),
                                ]),
                              ),
                              if (_openReport == 'geofence' && _reportSummary.isNotEmpty) Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                decoration: BoxDecoration(color: const Color(0xFF0f1f35), borderRadius: BorderRadius.circular(8)),
                                child: Row(children: [
                                  _TripStat(value: _reportSummary['enters'] ?? '0', label: tr('sm_enters'), color: const Color(0xFF27AE60)),
                                  const SizedBox(width: 4),
                                  _TripStat(value: _reportSummary['exits'] ?? '0', label: tr('sm_exits'), color: const Color(0xFFEF5350)),
                                ]),
                              ),
                              if ((_openReport == 'trips' || _openReport == 'speed') && _reportSummary.isNotEmpty) Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                decoration: BoxDecoration(color: const Color(0xFF0f1f35), borderRadius: BorderRadius.circular(8)),
                                child: Row(children: [
                                  _TripStat(value: '${_reportSummary['dist']} ${tr('unit_km')}', label: tr('sm_distance'), color: const Color(0xFF6BA539)),
                                  const SizedBox(width: 4),
                                  _TripStat(value: _reportSummary['dur'] ?? '--', label: tr('sm_duration'), color: const Color(0xFF38bdf8)),
                                  const SizedBox(width: 4),
                                  _TripStat(value: '${_reportSummary['maxSpd']} ${tr('unit_kmh')}', label: tr('sm_max_speed'), color: const Color(0xFFC41E3A)),
                                  const SizedBox(width: 4),
                                  _TripStat(value: _reportSummary['count'] ?? '0', label: _openReport == 'speed' ? tr('sm_overspeeds') : tr('sm_trips')),
                                ]),
                              ),
                              if (_openReport != 'trips' && _openReport != 'speed' && _openReport != 'geofence') Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                color: const Color(0xFF1E293B),
                                child: Row(children: [
                                  _TableHead(tr('th_time')), _TableHead(tr('th_value')), _TableHead(tr('th_location')),
                                ]),
                              ),
                              if (_openReport == 'trips')
                                ..._reportRows.take(50).map((r) => Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: const Color(0xFF0f1f35), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withOpacity(0.08))),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                      Text(r['time'] ?? '--', style: const TextStyle(color: Color(0xFF38bdf8), fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: (r['status'] == 'stop' ? const Color(0xFFE67E22) : const Color(0xFF27AE60)).withOpacity(0.2), borderRadius: BorderRadius.circular(6)), child: Text(r['status'] == 'stop' ? tr('rs_stop') : tr('rs_drive'), style: TextStyle(color: r['status'] == 'stop' ? const Color(0xFFE67E22) : const Color(0xFF27AE60), fontSize: 11, fontFamily: 'Cairo'))),
                                    ]),
                                    const Divider(color: Colors.white12, height: 12),
                                    Row(children: [
                                      Expanded(child: _InfoTile(tr('rt_end'), r['endTime'] ?? '--', const Color(0xFFE8EAF0))),
                                      Expanded(child: _InfoTile(tr('rt_duration'), r['duration'] ?? '--', const Color(0xFF38bdf8))),
                                    ]),
                                    const SizedBox(height: 6),
                                    Row(children: [
                                      Expanded(child: _InfoTile(tr('rt_distance'), r['value'] ?? '--', Colors.white)),
                                      Expanded(child: _InfoTile(tr('rt_max_speed'), r['maxSpeed'] ?? '--', const Color(0xFFEF5350))),
                                    ]),
                                    const SizedBox(height: 6),
                                    _InfoTile(tr('rt_start_point'), r['address'] ?? '--', const Color(0xFF2196F3)),
                                    const SizedBox(height: 4),
                                    _InfoTile(tr('rt_end_point'), r['endAddress'] ?? '--', const Color(0xFF2196F3)),
                                  ]),
                                )).toList()
                              else if (_openReport == 'speed')
                                ..._reportRows.take(50).map((r) => Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: const Color(0xFF0f1f35), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFEF5350).withOpacity(0.2))),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                      Text(r['time'] ?? '--', style: const TextStyle(color: Color(0xFF38bdf8), fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: const Color(0xFFEF5350).withOpacity(0.2), borderRadius: BorderRadius.circular(6)), child: Text(tr('rs_overspeed'), style: const TextStyle(color: Color(0xFFEF5350), fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                                    ]),
                                    const Divider(color: Colors.white12, height: 12),
                                    Row(children: [
                                      Expanded(child: _InfoTile(tr('rt_end'), r['endTime'] ?? '--', const Color(0xFFE8EAF0))),
                                      Expanded(child: _InfoTile(tr('rt_duration'), r['duration'] ?? '--', const Color(0xFF38bdf8))),
                                    ]),
                                    const SizedBox(height: 6),
                                    Row(children: [
                                      Expanded(child: _InfoTile(tr('rt_min_speed'), r['minSpeed'] ?? '--', const Color(0xFFFF9800))),
                                      Expanded(child: _InfoTile(tr('rt_max_speed'), r['maxSpeed'] ?? '--', const Color(0xFFEF5350))),
                                    ]),
                                    const SizedBox(height: 6),
                                    Row(children: [
                                      Expanded(child: _InfoTile(tr('rt_distance'), r['distance'] ?? '--', Colors.white)),
                                      Expanded(child: _InfoTile(tr('rt_track_points'), r['points'] ?? '--', const Color(0xFFA5F3FC))),
                                    ]),
                                    const SizedBox(height: 6),
                                    _InfoTile(tr('rt_start_point'), r['address'] ?? '--', const Color(0xFF2196F3)),
                                    const SizedBox(height: 4),
                                    _InfoTile(tr('rt_end_point'), r['endAddress'] ?? '--', const Color(0xFF2196F3)),
                                  ]),
                                )).toList()
                              else if (_openReport == 'geofence')
                                ..._reportRows.take(50).map((r) {
                                  final isEnter = r['status'] == 'enter';
                                  final c = isEnter ? const Color(0xFF27AE60) : const Color(0xFFEF5350);
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: const Color(0xFF0f1f35), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.25))),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                        Text(r['time'] ?? '--', style: const TextStyle(color: Color(0xFF38bdf8), fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                                        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: c.withOpacity(0.2), borderRadius: BorderRadius.circular(6)), child: Text(isEnter ? '📍 ${r['value']}' : '📤 ${r['value']}', style: TextStyle(color: c, fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                                      ]),
                                      const Divider(color: Colors.white12, height: 12),
                                      _InfoTile(tr('rt_geofence'), r['geofenceName'] ?? '--', const Color(0xFFA78BFA)),
                                      const SizedBox(height: 4),
                                      _InfoTile(tr('th_location'), r['address'] ?? '--', const Color(0xFF2196F3)),
                                    ]),
                                  );
                                }).toList()
                              else
                                ..._reportRows.take(20).map((r) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                color: const Color(0xFF141824),
                                child: Row(children: [
                                  _TableCell(r['time'] ?? r['eventTime'] ?? '-'),
                                  _TableCell(r['value'] ?? r['type'] ?? '-', color: const Color(0xFFA5F3FC)),
                                  _TableCell(r['address'] ?? '-'),
                                ]),
                              )).toList(),
                              // Export buttons
                              Padding(
                                padding: const EdgeInsets.all(7),
                                child: Row(children: [
                                  Expanded(child: OutlinedButton(
                                    onPressed: _exportingPdf ? null : _exportReportPdf,
                                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 6), side: BorderSide(color: Colors.white.withOpacity(0.1)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
                                    child: Text(tr('rep_print'), style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Cairo')),
                                  )),
                                  const SizedBox(width: 5),
                                  Expanded(child: ElevatedButton(
                                    onPressed: _exportingPdf ? null : _exportReportPdf,
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC41E3A), padding: const EdgeInsets.symmetric(vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7))),
                                    child: _exportingPdf ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('PDF', style: TextStyle(fontSize: 10, fontFamily: 'Cairo')),
                                  )),
                                ]),
                              ),
                            ],
                          ),
                        ),
                    ],
                  )).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchAddresses() async {
    final cache = <String, String>{};
    for (int i = 0; i < _reportRows.length; i++) {
      if (!mounted) break;
      final r = Map<String, dynamic>.from(_reportRows[i] as Map);
      Future<String> resolve(String s) async {
        if (!s.contains(',')) return s;
        final p = s.split(',');
        final lat = double.tryParse(p[0].trim()) ?? 0;
        final lng = double.tryParse(p[1].trim()) ?? 0;
        if (lat == 0) return '--';
        final k = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
        if (cache.containsKey(k)) return cache[k]!;
        final a = await _getAddress(lat, lng);
        cache[k] = a;
        return a;
      }
      final addrStr = (r['address'] ?? '').toString();
      final isCoord = addrStr.contains(',') && double.tryParse(addrStr.split(',')[0].trim()) != null;
      if (isCoord) {
        final a = await resolve(addrStr);
        if (mounted) setState(() { _reportRows[i] = {...r, 'address': a}; });
        await Future.delayed(const Duration(milliseconds: 400));
      }
      if (!mounted) break;
      final endStr = ((_reportRows[i] as Map)['endAddress'] ?? '').toString();
      final isEndCoord = endStr.contains(',') && double.tryParse(endStr.split(',')[0].trim()) != null;
      if (isEndCoord) {
        final a2 = await resolve(endStr);
        if (mounted) setState(() { _reportRows[i] = {...(_reportRows[i] as Map<String, dynamic>), 'endAddress': a2}; });
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }
  }

  Future<String> _getAddress(double lat, double lng) async {
    if (lat == 0 && lng == 0) return '--';
    final k = _AsyncAddressText._cacheKey(lat, lng);
    if (_AsyncAddressText._cache.containsKey(k)) return _AsyncAddressText._cache[k]!;
    try {
      final r = await ApiService.request('reverse_geocode', {'lat': lat, 'lng': lng, 'lang': I18n.lang});
      final raw = (r['address'] ?? '').toString().trim();
      if (raw.isEmpty) return '--';
      final cleaned = _AsyncAddressText._clean(raw);
      final display = cleaned.isNotEmpty ? cleaned : raw;
      _AsyncAddressText._cache[k] = display;
      return display;
    } catch (_) {}
    return '--';
  }

  Future<void> _toggleReport(String reportId) async {
    if (_openReport == reportId) {
      setState(() { _openReport = null; _reportRows = []; });
      return;
    }
    setState(() { _openReport = reportId; _loading = true; _reportRows = []; });

    final from = '${_fromDate}T00:00:00+02:00';
    final to = '${_toDate}T23:59:59+02:00';
    final devId = widget.device.id;

    final fromDt = DateTime.tryParse(_fromDate);
    final toDt = DateTime.tryParse(_toDate);
    if (fromDt != null && toDt != null) {
      final diff = toDt.difference(fromDt).inDays;
      if (diff < 0) {
        setState(() { _loading = false; _openReport = null; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('rep_end_before_start'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
        return;
      }
      if (diff > 3) {
        setState(() { _loading = false; _openReport = null; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('rep_max_3_days'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
        return;
      }
    }

    try {
      Map<String, dynamic> result = {};

      switch (reportId) {
        case 'speed':
          final spResult = await ApiService.request('get_positions', {
            'deviceId': devId, 'from': from, 'to': to,
          });
          final allPos = List<dynamic>.from(spResult['data'] ?? spResult['events'] ?? []);
          final speedLimit = double.tryParse(_spdLimitCtrl.text.trim()) ?? (widget.device.speedLimit > 0 ? widget.device.speedLimit : 100);
          // group consecutive overspeed positions
          final spGroups = <Map<String, dynamic>>[];
          Map<String, dynamic>? spGrp;
          for (final p in allPos) {
            final spd = (((p['speed'] ?? 0) as num).toDouble() * 1.852).roundToDouble();
            // نجمّع القراءات "عند الحد أو أعلى" (>=) لضم لحظات الاقتراب مع القمة،
            // ثم نحتفظ فقط بالمجموعات اللي أقصى سرعتها تجاوزت الحد فعلاً (تحت).
            if (spd >= speedLimit) {
              if (spGrp == null) {
                spGrp = {'start': p, 'end': p, 'maxSpd': spd, 'minSpd': spd, 'positions': <dynamic>[p]};
              } else {
                spGrp['end'] = p;
                (spGrp['positions'] as List).add(p);
                if (spd > (spGrp['maxSpd'] as double)) spGrp['maxSpd'] = spd;
                if (spd < (spGrp['minSpd'] as double)) spGrp['minSpd'] = spd;
              }
            } else {
              if (spGrp != null) { spGroups.add(spGrp); spGrp = null; }
            }
          }
          if (spGrp != null) spGroups.add(spGrp);
          // احتفظ فقط بالمجموعات اللي تجاوزت الحد فعلاً (مش قيادة عند الحد بالظبط)
          spGroups.removeWhere((g) => (g['maxSpd'] as double) <= speedLimit);
          // فلتر التجاوزات اللحظية (نقطة واحدة = spike GPS معزول)
          spGroups.removeWhere((g) => (g['positions'] as List).length < 2);
          String fmtSpT(String s) { try { final dt = DateTime.parse(s).toLocal(); return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}'; } catch(_) { return '--'; } }
          String fmtDurSp(int s) { final h = s ~/ 3600; final m = (s % 3600) ~/ 60; final r = s % 60; return '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${r.toString().padLeft(2,'0')}'; }
          double spTotalDist = 0; int spTotalSec = 0; double spMaxSpd = 0;
          final mappedSpeed = spGroups.map((g) {
            final positions = g['positions'] as List;
            double dist = 0;
            for (int i = 1; i < positions.length; i++) {
              final lat1 = ((positions[i-1]['latitude'] ?? 0) as num).toDouble() * 3.14159265 / 180;
              final lon1 = ((positions[i-1]['longitude'] ?? 0) as num).toDouble() * 3.14159265 / 180;
              final lat2 = ((positions[i]['latitude'] ?? 0) as num).toDouble() * 3.14159265 / 180;
              final lon2 = ((positions[i]['longitude'] ?? 0) as num).toDouble() * 3.14159265 / 180;
              final dLat = lat2 - lat1; final dLon = lon2 - lon1;
              final a = (dLat/2)*(dLat/2) + math.cos(lat1)*math.cos(lat2)*(dLon/2)*(dLon/2);
              dist += 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a));
            }
            final startPos = g['start'] as Map;
            final endPos = g['end'] as Map;
            final st = (startPos['fixTime'] ?? startPos['serverTime'] ?? '').toString();
            final et = (endPos['fixTime'] ?? endPos['serverTime'] ?? '').toString();
            int durSec = 0;
            try { durSec = DateTime.parse(et).difference(DateTime.parse(st)).abs().inSeconds; } catch(_) {}
            spTotalDist += dist; spTotalSec += durSec;
            if ((g['maxSpd'] as double) > spMaxSpd) spMaxSpd = g['maxSpd'] as double;
            final sLat = (startPos['latitude'] ?? 0) as num;
            final sLon = (startPos['longitude'] ?? 0) as num;
            final eLat = (endPos['latitude'] ?? 0) as num;
            final eLon = (endPos['longitude'] ?? 0) as num;
            return <String, dynamic>{
              'time': fmtSpT(st), 'endTime': fmtSpT(et),
              'duration': fmtDurSp(durSec),
              'value': '${(g['maxSpd'] as double).toStringAsFixed(0)} ${tr('unit_kmh')}',
              'minSpeed': '${(g['minSpd'] as double).toStringAsFixed(0)} ${tr('unit_kmh')}',
              'maxSpeed': '${(g['maxSpd'] as double).toStringAsFixed(0)} ${tr('unit_kmh')}',
              'distance': '${dist.toStringAsFixed(3)} ${tr('unit_km')}',
              'points': positions.length.toString(),
              'address': sLat != 0 ? '${sLat.toStringAsFixed(5)}, ${sLon.toStringAsFixed(5)}' : '--',
              'endAddress': eLat != 0 ? '${eLat.toStringAsFixed(5)}, ${eLon.toStringAsFixed(5)}' : '--',
              'status': 'speed',
            };
          }).toList();
          final spHrs = spTotalSec ~/ 3600; final spMins = (spTotalSec % 3600) ~/ 60;
          _reportSummary = {
            'count': '${spGroups.length}',
            'dist': spTotalDist.toStringAsFixed(1),
            'maxSpd': spMaxSpd.toStringAsFixed(0),
            'dur': spHrs > 0 ? tr('dur_hm', {'h': '$spHrs', 'm': '$spMins'}) : tr('dur_min', {'m': '$spMins'}),
          };
          setState(() { _loading = false; _reportRows = List<dynamic>.from(mappedSpeed); });
          _fetchAddresses();
          return;

        case 'ignition':
          result = await ApiService.request('get_events', {
            'deviceId': devId, 'from': from, 'to': to,
            'type': 'ignitionOn,ignitionOff', 'limit': 500,
          });
          final ignRows = List<dynamic>.from(
            result['data'] ?? result['events'] ?? (result is List ? result : [])
          );
          setState(() { _loading = false; _reportRows = ignRows; });
          _fetchAddresses();
          return;

        case 'alerts':
          result = await ApiService.request('get_events', {
            'deviceId': devId, 'from': from, 'to': to, 'limit': 200,
          });
          break;

        case 'operation':
          // trips
          result = await ApiService.request('get_trips_mysql', {
            'deviceId': devId, 'from': from, 'to': to,
          });
          final trips = List<dynamic>.from(result['data'] ?? (result is List ? result : []));
          setState(() { _loading = false; _reportRows = trips; });
          return;

        case 'geofence':
          result = await ApiService.request('get_events', {
            'deviceId': devId, 'from': from, 'to': to,
            'type': 'geofenceEnter,geofenceExit', 'limit': 200,
          });
          final geoEvents = List<dynamic>.from(result['data'] ?? result['events'] ?? []);
          String fmtGeoTime(String s) { try { final dt = DateTime.parse(s).toLocal(); return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}'; } catch(_) { return '--'; } }
          geoEvents.sort((a, b) => (b['eventTime'] ?? '').toString().compareTo((a['eventTime'] ?? '').toString()));
          int gfEnters = 0; int gfExits = 0;
          final mappedGeo = geoEvents.map((e) {
            final lat = (e['lat'] ?? e['latitude'] ?? 0) as num;
            final lon = (e['lng'] ?? e['longitude'] ?? 0) as num;
            final isEnter = e['type'] == 'geofenceEnter';
            if (isEnter) gfEnters++; else gfExits++;
            return <String, dynamic>{
              'time': fmtGeoTime((e['eventTime'] ?? '').toString()),
              'geofenceName': (e['geofenceName'] ?? e['geofenceId'] ?? tr('rt_geofence')).toString(),
              'value': isEnter ? tr('rt_gf_enter') : tr('rt_gf_exit'),
              'status': isEnter ? 'enter' : 'exit',
              'address': lat != 0 ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}' : '--',
            };
          }).toList();
          _reportSummary = {'enters': '$gfEnters', 'exits': '$gfExits'};
          setState(() { _loading = false; _reportRows = List<dynamic>.from(mappedGeo); });
          _fetchAddresses();
          return;

        case 'trips':
          final traccarId = widget.device.traccarId > 0 ? widget.device.traccarId : devId;
          result = await ApiService.request('get_trips_mysql', {
            'deviceId': traccarId, 'from': from, 'to': to,
          });
          final tripsList = List<dynamic>.from(result['data'] ?? (result is List ? result : []));
          double totalDist = 0; double maxSpd = 0; int totalMs = 0;
          for (final r in tripsList) {
            if (r['status'] == 'moving' || r['status'] == null) {
              totalDist += (r['distance'] ?? 0) as num;
              totalMs += (r['driveTime'] ?? r['duration'] ?? 0) as int;
              final ms = (r['maxSpeed'] ?? 0) as num;
              if (ms > maxSpd) maxSpd = ms.toDouble();
            }
          }
          final totalKm = totalDist.toStringAsFixed(1);
          final hrs = totalMs ~/ 3600000; final mins = (totalMs % 3600000) ~/ 60000;
          final durStr = hrs > 0 ? tr('dur_hm', {'h': '$hrs', 'm': '$mins'}) : tr('dur_min', {'m': '$mins'});
          _reportSummary = {'dist': totalKm, 'dur': durStr, 'maxSpd': maxSpd.toStringAsFixed(0), 'count': '${tripsList.length}'};
          final mappedTrips = tripsList.map((r) {
            final isStop = r['status'] == 'stopped';
            final st = (r['startTime'] ?? '').toString();
            final et = (r['endTime'] ?? '').toString();
            String fmtT(String s) { if(s.length < 10) return '--'; try { final dt = DateTime.parse(s).toLocal(); return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}'; } catch(_) { return '--'; } }
            final dist = isStop ? '0.00 ${tr('unit_km')}' : ((r['distance'] ?? 0) as num).toStringAsFixed(2) + ' ${tr('unit_km')}';
            String calcDur() { try { final s = DateTime.parse(st); final e = DateTime.parse(et); final diff = e.difference(s).abs(); final h = diff.inHours; final m = diff.inMinutes % 60; final s2 = diff.inSeconds % 60; return '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${s2.toString().padLeft(2,'0')}'; } catch(_) { return '--'; } }
            final dur = calcDur();
            final maxSpd = isStop ? '0 ${tr('unit_kmh')}' : ((r['maxSpeed'] ?? 0) as num).toStringAsFixed(0) + ' ${tr('unit_kmh')}';
            final startLat = (r['startLat'] ?? 0) as num;
            final startLon = (r['startLon'] ?? 0) as num;
            final endLat = (r['endLat'] ?? 0) as num;
            final endLon = (r['endLon'] ?? 0) as num;
            return {
              'time': fmtT(st), 'endTime': fmtT(et), 'value': dist,
              'duration': dur, 'maxSpeed': maxSpd,
              'address': startLat != 0 ? '${startLat.toStringAsFixed(5)}, ${startLon.toStringAsFixed(5)}' : '--',
              'endAddress': isStop ? '—' : (endLat != 0 ? '${endLat.toStringAsFixed(5)}, ${endLon.toStringAsFixed(5)}' : '--'),
              'status': isStop ? 'stop' : 'drive',
              'points': (r['pointCount'] ?? r['positionCount'] ?? 0).toString(),
            };
          }).toList();
          setState(() { _loading = false; _reportRows = List<dynamic>.from(mappedTrips); });
          _fetchAddresses();
          return;

        default:
          result = {'success': false, 'error': tr('rep_unknown_type')};
      }

      final rawData = result['data'] ?? result['events'] ?? result;
      final rows = rawData is List ? List<dynamic>.from(rawData) : <dynamic>[];
      setState(() { _loading = false; _reportRows = rows; });

    } catch (e) {
      setState(() { _loading = false; _reportRows = []; });
    }
  }
}

// ??? Helper widgets ???????????????????????????????????????????????????????????

class _TripStat extends StatelessWidget {
  final String value, label;
  final Color? color;
  const _TripStat({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withOpacity(0.07))),
        child: Column(children: [
          Text(value, style: TextStyle(color: color ?? Colors.white, fontSize: 12, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
          Text(label, style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 8, fontFamily: 'Cairo')),
        ]),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label, value;
  final Color valueColor;
  const _InfoTile(this.label, this.value, this.valueColor);
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Color(0x60FFFFFF), fontSize: 9, fontFamily: 'Cairo')),
    Text(value, style: TextStyle(color: valueColor, fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
  ]);
}

class _TableHead extends StatelessWidget {
  final String text;
  const _TableHead(this.text);
  @override
  Widget build(BuildContext context) => Expanded(child: Text(text, style: const TextStyle(color: Color(0x70FFFFFF), fontSize: 9, fontFamily: 'Cairo')));
}

class _TableCell extends StatelessWidget {
  final String text;
  final Color? color;
  const _TableCell(this.text, {this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Text(text, style: TextStyle(color: color ?? const Color(0xBFFFFFFF), fontSize: 9, fontFamily: 'Cairo'), overflow: TextOverflow.ellipsis));
}

class _DarkInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final Function(String)? onChanged;
  final TextDirection? textDirection;

  const _DarkInput({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.onChanged,
    this.textDirection,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textDirection: textDirection ?? TextDirection.rtl,
      onChanged: onChanged,
      style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 12),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0x50FFFFFF), fontFamily: 'Cairo', fontSize: 11),
        filled: true,
        fillColor: const Color(0xFF2D3A4F),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.white.withOpacity(0.12))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.white.withOpacity(0.12))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC41E3A))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    );
  }
}

// ??? Nav Arrow Button ?????????????????????????????????????????????????????????
class _NavArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _NavArrow({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.95),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE8EAEF)),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 5)],
        ),
        child: Icon(icon, size: 20, color: const Color(0xFF1A1F2E)),
      ),
    );
  }
}

// ??? Full Screen Route Playback ???????????????????????????????????????????????

// ????????????????????????????????????????????????????????????????????????????
// ROUTE PLAYBACK SCREEN - منطق مطابق للسيرفر بالظبط
// ????????????????????????????????????????????????????????????????????????????
class _RoutePlaybackScreen extends StatefulWidget {
  final DeviceModel device;
  final String      initialPeriod;
  final double      speedLimit;
  final DateTime?   customFrom;
  final DateTime?   customTo;
  const _RoutePlaybackScreen({
    required this.device,
    this.initialPeriod = 'today',
    this.speedLimit    = 120,
    this.customFrom,
    this.customTo,
  });
  @override
  State<_RoutePlaybackScreen> createState() => _RoutePlaybackScreenState();
}

class _RoutePlaybackScreenState extends State<_RoutePlaybackScreen> {
  GoogleMapController? _ctrl;

  // ?? Static layers (built once, never change) ?????????????????????????????
  Set<Polyline> _polylines  = {};
  Set<Marker>   _baseMarkers = {}; // edge + stop markers
  // نافذة خرايط جوجل الافتراضية بلا زر إغلاق: تُغلق بضغطة على الخريطة، ولو كان
  // ثمّة ماركر مجاور التقطت الضغطةُ ذاك الماركر بدل الإغلاق. فنعرض بطاقة خاصة
  // فيها زر تنقّل حقيقي وزر إغلاق — كما في الويب.
  Map<String, dynamic>? _selectedStop;

  // ?? Dynamic (only car marker changes) ????????????????????????????????????
  Set<Marker>   _markers = {};

  // ?? Positions ????????????????????????????????????????????????????????????
  List<Map<String, dynamic>> _positions = []; // original GPS points
  // Interpolated: {lat, lng, speed, origIdx}
  List<Map<String, dynamic>> _interp = [];

  // ?? Playback state ????????????????????????????????????????????????????????
  int    _origIdx   = 0;   // maps to _positions (for slider display)
  int    _interpIdx = 0;   // maps to _interp (animation cursor)
  bool   _playing   = false;
  double _speed     = 1.0;
  Timer? _timer;
  int    _frame     = 0;   // throttle: icon & camera update every 10 frames

  // ?? Car images (downloaded once) ?????????????????????????????????????????
  ui.Image? _imgGreen;
  ui.Image? _imgRed;
  // Pre-cached icons: 'car_false_0' ... 'car_true_355' (72×2 = 144 entries)
  final Map<String, BitmapDescriptor> _iconCache = {};
  BitmapDescriptor? _carIcon; // current icon (updated every 10 frames)
  double _carAngle  = 0;

  // ?? UI state ??????????????????????????????????????????????????????????????
  bool      _loading  = false;
  bool      _loaded   = false;
  String    _period   = 'today';
  MapType   _mapType  = MapType.normal;
  DateTime? _customFrom;
  DateTime? _customTo;

  // Info bar (updated every 10 frames - same as web)
  String _infoTime = '--:--:--';
  String _infoSpd  = '0.0';

  // Stop indices (original positions)
  final List<int> _stopIndices = [];

  // Speed options (same as web: 0.1 ? 8)
  final _speeds = [
    {'l': 'x0.1', 'v': 0.1}, {'l': 'x0.25', 'v': 0.25},
    {'l': 'x0.5', 'v': 0.5}, {'l': 'x1',   'v': 1.0},
    {'l': 'x2',   'v': 2.0}, {'l': 'x4',   'v': 4.0},
    {'l': 'x6',   'v': 6.0}, {'l': 'x8',   'v': 8.0},
  ];

  // ????????????????????????????????????????????????????????????????????????
  @override
  void initState() {
    super.initState();
    _period     = widget.initialPeriod;
    _customFrom = widget.customFrom;
    _customTo   = widget.customTo;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  // ?? Entry point ??????????????????????????????????????????????????????????
  Future<void> _init() async {
    setState(() { _loading = true; _loaded = false; _positions = []; _interp = []; });
    await _preloadImages();
    await _loadRoute();
  }

  // ?? Pre-render arrow icons matching server SVG exactly ???????????????????
  // Server SVG: <polygon points="12,0 20,24 12,18 4,24" fill="#c41e3a" stroke="#fff" stroke-width="1.5"/>
  /// Load realistic car sprites once (normal + overspeed). Rotation is done by
  /// Marker.rotation — no need to pre-render 144 rotated bitmaps (was slow).
  Future<void> _preloadImages() async {
    for (final e in const {'norm': 'blue', 'over': 'red'}.entries) {
      final key = 'sprite_${e.key}';
      if (_iconCache.containsKey(key)) continue;
      try {
        final data = await rootBundle.load('assets/markers/car_${e.value}.png');
        _iconCache[key] = BitmapDescriptor.bytes(
            data.buffer.asUint8List(), imagePixelRatio: 6.0);
      } catch (_) {}
    }
    await _buildDirArrowIcon();
  }

  /// Realistic top-down car - only roof visible (like actual aerial photo)
  Future<BitmapDescriptor> _renderCarIcon(bool isOver, double angleDeg) async {
    // Square canvas with generous padding for rotation
    const SZ  = 180.0;
    const CX  = SZ / 2, CY = SZ / 2;
    const scale = 3.0; // supersample → crisp playback car on high-DPI screens

    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, SZ * scale, SZ * scale));
    c.scale(scale);

    c.save();
    c.translate(CX, CY);
    c.rotate(angleDeg * math.pi / 180);
    c.translate(-CX, -CY);

    // ?? Car body dimensions (pointing UP = North) ??????????????????
    // Width 26, Height 52 - typical sedan proportions
    const bW = 46.0, bH = 92.0;
    const bL = (SZ - bW) / 2; // left edge
    const bT = (SZ - bH) / 2; // top edge

    final bodyColor = isOver ? const Color(0xFFB03A2E) : const Color(0xFF1A5276);

    // ?? Drop shadow ????????????????????????????????????????????????
    c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(bL + 3, bT + 4, bW, bH), const Radius.circular(6)),
      Paint()
        ..color = Colors.black.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // ?? Hood (front lower section) ?????????????????????????????????
    final hoodPath = Path()
      ..moveTo(bL + 3, bT + bH * 0.0)
      ..lineTo(bL + bW - 3, bT + bH * 0.0)
      ..lineTo(bL + bW, bT + bH * 0.12)
      ..lineTo(bL, bT + bH * 0.12)
      ..close();
    c.drawPath(hoodPath,
        Paint()..color = bodyColor.withRed((bodyColor.red * 1.15).clamp(0, 255).toInt()));

    // ?? Trunk (rear lower section) ?????????????????????????????????
    final trunkPath = Path()
      ..moveTo(bL, bT + bH * 0.88)
      ..lineTo(bL + bW, bT + bH * 0.88)
      ..lineTo(bL + bW - 3, bT + bH)
      ..lineTo(bL + 3, bT + bH)
      ..close();
    c.drawPath(trunkPath,
        Paint()..color = bodyColor.withRed((bodyColor.red * 0.85).clamp(0, 255).toInt()));

    // ?? Main roof body ?????????????????????????????????????????????
    c.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(bL, bT, bW, bH), 6, 6),
      Paint()
        ..isAntiAlias = true
        ..shader = ui.Gradient.linear(
          Offset(bL, 0), Offset(bL + bW, 0),
          [
            Color.lerp(bodyColor, Colors.black, 0.22)!,
            Color.lerp(bodyColor, Colors.white, 0.18)!,
            bodyColor,
            Color.lerp(bodyColor, Colors.black, 0.26)!,
          ],
          const [0.0, 0.40, 0.62, 1.0],
        ),
    );

    // ?? Roof panel (slightly lighter center) ???????????????????????
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + 3, bT + bH * 0.28, bW - 6, bH * 0.44), 4, 4),
      Paint()..color = bodyColor.withOpacity(0.7),
    );

    // ?? Front windshield ???????????????????????????????????????????
    final wfPath = Path()
      ..moveTo(bL + 2, bT + bH * 0.12)
      ..lineTo(bL + bW - 2, bT + bH * 0.12)
      ..lineTo(bL + bW - 4, bT + bH * 0.28)
      ..lineTo(bL + 4, bT + bH * 0.28)
      ..close();
    c.drawPath(wfPath,
        Paint()..color = const Color(0xCC90CAF9));

    // Windshield glare
    final glarePath = Path()
      ..moveTo(bL + 4, bT + bH * 0.13)
      ..lineTo(bL + bW * 0.4, bT + bH * 0.13)
      ..lineTo(bL + bW * 0.35, bT + bH * 0.27)
      ..lineTo(bL + 5, bT + bH * 0.27)
      ..close();
    c.drawPath(glarePath, Paint()..color = Colors.white.withOpacity(0.35));

    // ?? Rear windshield ????????????????????????????????????????????
    final wrPath = Path()
      ..moveTo(bL + 4, bT + bH * 0.72)
      ..lineTo(bL + bW - 4, bT + bH * 0.72)
      ..lineTo(bL + bW - 2, bT + bH * 0.88)
      ..lineTo(bL + 2, bT + bH * 0.88)
      ..close();
    c.drawPath(wrPath,
        Paint()..color = const Color(0x9990CAF9));

    // ?? Side mirrors (tiny - realistic) ???????????????????????????
    // Left mirror
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL - 4, bT + bH * 0.2, 5, 4), 1, 1),
      Paint()..color = bodyColor.withOpacity(0.9),
    );
    // Right mirror
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + bW - 1, bT + bH * 0.2, 5, 4), 1, 1),
      Paint()..color = bodyColor.withOpacity(0.9),
    );

    // ?? Hood crease line ???????????????????????????????????????????
    c.drawLine(
      Offset(CX, bT + bH * 0.0),
      Offset(CX, bT + bH * 0.12),
      Paint()..color = Colors.black.withOpacity(0.15)..strokeWidth = 0.8,
    );

    // ?? Headlights (bright yellow-white) ??????????????????????????
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + 1, bT + 1, 7, 3), 1, 1),
      Paint()..color = const Color(0xFFFFEE88),
    );
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + bW - 8, bT + 1, 7, 3), 1, 1),
      Paint()..color = const Color(0xFFFFEE88),
    );

    // ?? Tail lights (red) ??????????????????????????????????????????
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + 1, bT + bH - 4, 7, 3), 1, 1),
      Paint()..color = const Color(0xFFEF5350),
    );
    c.drawRRect(
      RRect.fromRectXY(
          Rect.fromLTWH(bL + bW - 8, bT + bH - 4, 7, 3), 1, 1),
      Paint()..color = const Color(0xFFEF5350),
    );

    // ?? Body outline ???????????????????????????????????????????????
    c.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(bL, bT, bW, bH), 6, 6),
      Paint()
        ..color = Colors.black.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    c.restore();

    final pic  = rec.endRecording();
    final img  = await pic.toImage((SZ * scale).toInt(), (SZ * scale).toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) {
      return BitmapDescriptor.bytes(data.buffer.asUint8List(),
          imagePixelRatio: scale);
    }
    return BitmapDescriptor.defaultMarkerWithHue(
        isOver ? BitmapDescriptor.hueRed : BitmapDescriptor.hueBlue);
  }

  // قص النقاط الثابتة (سرعة ~0) من بداية ونهاية المسار فقط. الجهاز يسجّل نقاطاً
  // بسرعة 0 بعد ركن المركبة حتى نهاية نطاق البحث، مما يجعل المشغل والملخص يحسبان
  // وقتاً فارغاً. نُبقي التوقفات الوسطية (بين حركتين) كما هي.
  List<Map<String, dynamic>> _trimIdleEnds(List<Map<String, dynamic>> pts) {
    if (pts.length < 3) return pts;
    const moveKmh = 3.0;
    double kmh(Map<String, dynamic> p) =>
        ((p['speed'] ?? 0) as num).toDouble() * 1.852;
    int firstMove = -1, lastMove = -1;
    for (int i = 0; i < pts.length; i++) {
      if (kmh(pts[i]) > moveKmh) { firstMove = i; break; }
    }
    if (firstMove == -1) return pts; // لم تتحرك المركبة إطلاقاً — أبقِ كما هو
    for (int i = pts.length - 1; i >= 0; i--) {
      if (kmh(pts[i]) > moveKmh) { lastMove = i; break; }
    }
    // أبقِ نقطة واحدة بعد آخر حركة لإظهار مكان الوصول/الرسو النهائي
    final start = firstMove;
    final end   = (lastMove + 1).clamp(0, pts.length - 1);
    return pts.sublist(start, end + 1);
  }

  // إغلاق شاشة المسار وعرض رسالة عند عدم وجود حركة فعلية في الفترة المختارة
  void _exitNoMovement([String? msg]) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(
      content: Text(msg ?? tr('rep_no_movement'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
      backgroundColor: const Color(0xFFC41E3A),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
    ));
  }

  // قراءة دفاعية للسرعة (قد تصل رقماً أو نصاً أو null)
  static double _spd(Map p) {
    final v = p['speed'];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  // ?? 2. Load route from API ???????????????????????????????????????????????
  Future<void> _loadRoute() async {
    final provider = context.read<AppProvider>();
    final result   = await provider.getReplayRoute(
        deviceId:   widget.device.id,
        period:     _period,
        customFrom: _customFrom?.toUtc().toIso8601String(),
        customTo:   _customTo?.toUtc().toIso8601String());
    setState(() => _loading = false);

    // فشل الطلب نفسه (شبكة/مهلة/توكن) ≠ عدم وجود حركة. نُظهر الخطأ الحقيقي
    // بدل رسالة "لا حركة" المضلِّلة حتى لا نخفي سبب العطل.
    final dataRaw = result['data'];
    if (result['success'] == false || dataRaw is! List) {
      final err = (result['error'] ?? '').toString();
      _exitNoMovement(err.isNotEmpty ? err : tr('rep_no_movement'));
      return;
    }

    final raw = List<Map<String, dynamic>>.from(
      dataRaw
          .where((p) => p['latitude'] != null && p['longitude'] != null)
          .map((p) => Map<String, dynamic>.from(p as Map)),
    );

    // تحقق من وجود حركة فعلية: إما سرعة فوق الحد، أو إزاحة جغرافية حقيقية بين
    // النقاط (احتياطي لو وصلت السرعة بصيغة غير متوقعة). قراءة السرعة دفاعية.
    const moveKmh = 3.0;
    bool hasMovement = raw.any((p) => _spd(p) * 1.852 > moveKmh);
    if (!hasMovement && raw.length >= 2) {
      final f = raw.first, l = raw.last;
      final dLat = ((double.tryParse('${l['latitude']}') ?? 0) - (double.tryParse('${f['latitude']}') ?? 0)).abs();
      final dLng = ((double.tryParse('${l['longitude']}') ?? 0) - (double.tryParse('${f['longitude']}') ?? 0)).abs();
      if (dLat > 0.0005 || dLng > 0.0005) hasMovement = true; // ~50م
    }
    if (!hasMovement) {
      _exitNoMovement();
      return;
    }

    // قص النقاط الثابتة في بداية/نهاية المصفوفة — الجهاز يستمر في تسجيل نقاط
    // بسرعة 0 بعد التوقف حتى نهاية نطاق البحث، فيظل المشغل والعدّاد يزحفان على
    // وقت فارغ. نربط المشغل والملخص بأول وآخر حركة فعلية (مع إبقاء التوقفات الوسطية).
    _positions = _trimIdleEnds(raw);

    // Build everything
    _buildInterp();
    _buildPolylines();
    await _buildStopMarkers();
    _buildEdgeMarkers();
    _baseMarkers = {..._stopMarkersSet, ..._edgeMarkersSet, ..._buildDirArrows()};

    _origIdx   = 0;
    _interpIdx = 0;
    _loaded    = true;

    // Initial car icon
    _carIcon = _getIcon(0, 0);

    setState(() {
      _polylines = _staticPolylines;
      _markers   = _buildCarMarker(0, 0, _carIcon!);
    });

    // Fit camera to full route
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());
  }

  // ?? 3. Interpolation - exact copy of web logic ???????????????????????????
  // web: skip if p1.speed<2 AND p2.speed<2, 10 steps between each pair
  void _buildInterp() {
    _interp = [];
    const steps = 8;
    for (int i = 0; i < _positions.length - 1; i++) {
      final p1  = _positions[i];
      final p2  = _positions[i + 1];
      final lat1 = double.tryParse(p1['latitude'].toString())  ?? 0;
      final lng1 = double.tryParse(p1['longitude'].toString()) ?? 0;
      final lat2 = double.tryParse(p2['latitude'].toString())  ?? 0;
      final lng2 = double.tryParse(p2['longitude'].toString()) ?? 0;
      if (lat1 == 0 || lat2 == 0) continue;
      final spd1 = ((p1['speed'] ?? 0) as num).toDouble() * 1.852;
      final spd2 = ((p2['speed'] ?? 0) as num).toDouble() * 1.852;
      // وقفة وسطية (كلا النقطتين شبه ثابتة) → لا نملأها بإطارات تشغيل، نضيف نقطة
      // واحدة فقط بدل 8، فيمر الماركر سريعاً دون أن يقف وقتاً طويلاً عند التوقفات.
      const stopKmh = 3.0;
      final isStop  = spd1 <= stopKmh && spd2 <= stopKmh;
      final n = isStop ? 1 : steps;
      for (int s = 0; s < n; s++) {
        final t = s / steps;
        _interp.add({
          'lat':     lat1 + (lat2 - lat1) * t,
          'lng':     lng1 + (lng2 - lng1) * t,
          'speed':   spd1 + (spd2 - spd1) * t,
          'fixTime': p1['fixTime'],
          'origIdx': i,
        });
      }
    }
    if (_positions.isNotEmpty) {
      final last = _positions.last;
      _interp.add({
        'lat':     double.tryParse(last['latitude'].toString())  ?? 0,
        'lng':     double.tryParse(last['longitude'].toString()) ?? 0,
        'speed':   ((last['speed'] ?? 0) as num).toDouble() * 1.852,
        'fixTime': last['fixTime'],
        'origIdx': _positions.length - 1,
      });
    }
  }

  // ?? 4. Polylines - grouped by color (few objects, clean rendering) ????????
  // ?? Direction arrow icon (white, small - like server) ????????????????????
  BitmapDescriptor? _dirArrowIcon;
  Future<void> _buildDirArrowIcon() async {
    const sz = 26.0;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, sz, sz));
    final path = Path()
      ..moveTo(sz/2,   2)
      ..lineTo(sz-3,   sz-3)
      ..lineTo(sz/2,   sz-8)
      ..lineTo(3,      sz-3)
      ..close();
    c.drawPath(path, Paint()..color = Colors.white.withOpacity(0.95));
    c.drawPath(path,
        Paint()..color = Colors.black.withOpacity(0.3)..style = PaintingStyle.stroke..strokeWidth = 1.2);
    final pic  = rec.endRecording();
    final img  = await pic.toImage(sz.toInt(), sz.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) _dirArrowIcon = BitmapDescriptor.fromBytes(data.buffer.asUint8List());
  }

  /// Build direction arrow markers every ~15 points along route (like server)
  Set<Marker> _buildDirArrows() {
    final markers = <Marker>{};
    if (_dirArrowIcon == null) return markers;
    int idx = 0;
    // أداء: نوسّع المسافة بين الأسهم مع كبر البيانات (مسار شهر) حتى لا تتضخّم
    // مجموعة الماركرات وتسبّب رفرفة الماركر عند إعادة الرسم كل فريم
    final n = _positions.length;
    final step = n > 8000 ? 60 : (n > 3000 ? 25 : (n > 1000 ? 10 : 5));
    for (int i = 3; i < _positions.length - 1; i += step) {
      final p1  = _positions[i];
      final p2  = _positions[i + 1];
      final lat1 = double.tryParse(p1['latitude'].toString())  ?? 0;
      final lng1 = double.tryParse(p1['longitude'].toString()) ?? 0;
      final lat2 = double.tryParse(p2['latitude'].toString())  ?? 0;
      final lng2 = double.tryParse(p2['longitude'].toString()) ?? 0;
      if (lat1 == 0 || lat2 == 0) continue;
      final spd = ((p1['speed'] ?? 0) as num).toDouble() * 1.852;
      if (spd < 1) continue; // skip stopped
      final angle = _calcBearing(lat1, lng1, lat2, lng2);
      markers.add(Marker(
        markerId: MarkerId('dir_${idx++}'),
        position: LatLng(lat1, lng1),
        icon: _dirArrowIcon!,
        anchor: const Offset(0.5, 0.5),
        rotation: angle,
        flat: true,
        zIndex: 3,
        consumeTapEvents: false,
      ));
    }
    return markers;
  }

  Set<Polyline> _staticPolylines = {};
  void _buildPolylines() {
    final lim = widget.speedLimit;
    final result = <Polyline>{};
    final List<LatLng> pts   = [];
    Color               col  = const Color(0xFF6BA539);
    int                 gIdx = 0;

    void flush() {
      if (pts.length >= 2) {
        result.add(Polyline(
          polylineId: PolylineId('g$gIdx'),
          points:     List.from(pts),
          color:      col,
          width:      5,
          jointType:  JointType.round,
          endCap:     Cap.roundCap,
          startCap:   Cap.roundCap,
        ));
        gIdx++;
      }
    }

    for (final p in _positions) {
      final lat  = double.tryParse(p['latitude'].toString())  ?? 0;
      final lng  = double.tryParse(p['longitude'].toString()) ?? 0;
      if (lat == 0) continue;
      final spd  = ((p['speed'] ?? 0) as num).toDouble() * 1.852;
      final newCol = spd > lim ? const Color(0xFFC41E3A) : const Color(0xFF6BA539);
      if (newCol != col && pts.isNotEmpty) {
        pts.add(LatLng(lat, lng)); // share last point for smooth join
        flush(); pts.clear(); col = newCol;
      }
      pts.add(LatLng(lat, lng));
    }
    flush();
    _staticPolylines = result;
  }

  // ?? 5. P stop icon ???????????????????????????????????????????????????????
  BitmapDescriptor? _pIcon;
  Future<void> _buildPIcon() async {
    const sz = 44.0;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, sz, sz));
    c.drawCircle(const Offset(sz/2, sz/2), sz/2 - 1,
        Paint()..color = const Color(0xFFFF6F00));
    c.drawCircle(const Offset(sz/2, sz/2), sz/2 - 1,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3);
    final tp = TextPainter(
      text: const TextSpan(text: 'P',
          style: TextStyle(color: Colors.white, fontSize: 30,
              fontWeight: FontWeight.bold, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset((sz - tp.width)/2, (sz - tp.height)/2));
    final pic  = rec.endRecording();
    final img  = await pic.toImage(sz.toInt(), sz.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) _pIcon = BitmapDescriptor.fromBytes(data.buffer.asUint8List());
    _pIcon ??= BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
  }

  // numbered stop PIN (1,2,3…) — small orange teardrop whose tip points to the
  // route line, white number on top. anchor (0.5,1.0). cached per number.
  final Map<int, BitmapDescriptor> _numIconCache = {};
  Future<BitmapDescriptor> _numStopIcon(int n) async {
    final cached = _numIconCache[n];
    if (cached != null) return cached;
    const r = 16.0, w = 36.0, h = 44.0, scale = 4.0;
    const cx = w / 2, cy = r + 2;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, w * scale, h * scale));
    c.scale(scale);
    final orange = Paint()..color = const Color(0xFFFF6F00);
    // pointer tail down to the route point
    final tail = Path()
      ..moveTo(cx - r * 0.6, cy + r * 0.55)
      ..lineTo(cx, h)
      ..lineTo(cx + r * 0.6, cy + r * 0.55)
      ..close();
    c.drawPath(tail, orange);
    // circle + white ring
    c.drawCircle(const Offset(cx, cy), r, orange);
    c.drawCircle(const Offset(cx, cy), r,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.5);
    final tp = TextPainter(
      text: TextSpan(text: '$n',
          style: const TextStyle(color: Colors.white, fontSize: 20,
              fontWeight: FontWeight.bold, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(cx - tp.width / 2, cy - tp.height / 2));
    final pic  = rec.endRecording();
    final img  = await pic.toImage((w * scale).toInt(), (h * scale).toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final icon = data != null
        ? BitmapDescriptor.bytes(data.buffer.asUint8List(), imagePixelRatio: 6.0)
        : BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    _numIconCache[n] = icon;
    return icon;
  }

  // format a stop duration: minutes only under 1h, else "Xh Ym" (hours after 60min)
  String _fmtDur(int mins) {
    if (mins < 60) {
      return I18n.isAr ? 'المدة: $mins دقيقة' : 'Duration: $mins min';
    }
    final h = mins ~/ 60, m = mins % 60;
    if (I18n.isAr) {
      return m > 0 ? 'المدة: $h ساعة و $m دقيقة' : 'المدة: $h ساعة';
    }
    return m > 0 ? 'Duration: ${h}h ${m}m' : 'Duration: ${h}h';
  }

  // ?? 6. Stop markers ???????????????????????????????????????????????????????
  Set<Marker> _stopMarkersSet = {};
  Future<void> _buildStopMarkers() async {
    _stopMarkersSet = {};
    _stopIndices.clear();
    const stopSpd = 2.0;
    const stopSec = 60;
    int? start;
    int  idx = 0;

    for (int i = 0; i < _positions.length; i++) {
      final spd = ((_positions[i]['speed'] ?? 0) as num).toDouble() * 1.852;
      if (spd < stopSpd) {
        start ??= i;
      } else if (start != null) {
        final t1 = DateTime.tryParse(_positions[start]['fixTime']?.toString() ?? '');
        final t2 = DateTime.tryParse(_positions[i-1]['fixTime']?.toString() ?? '');
        if (t1 != null && t2 != null && t2.difference(t1).inSeconds >= stopSec) {
          final p   = _positions[start];
          final lat = double.tryParse(p['latitude'].toString())  ?? 0;
          final lng = double.tryParse(p['longitude'].toString()) ?? 0;
          if (lat != 0) {
            final mins = t2.difference(t1).inSeconds ~/ 60;
            final st   = _fmt(t1.toLocal());
            final et   = _fmt(t2.toLocal());
            final stopNo = idx + 1; // 1-based sequential number
            _stopMarkersSet.add(Marker(
              markerId: MarkerId('stop_$idx'),
              position: LatLng(lat, lng),
              icon: await _numStopIcon(stopNo),
              anchor: const Offset(0.5, 1.0), // tip points to the route point
              onTap: () => setState(() => _selectedStop = {
                    'no': stopNo, 'dur': _fmtDur(mins),
                    'from': st, 'to': et, 'lat': lat, 'lng': lng,
                    // التاريخ ضروري: عرض المسار قد يمتدّ أيامًا فلا يكفي الوقت وحده
                    'date': '${t1.toLocal().year}-${t1.toLocal().month.toString().padLeft(2, '0')}'
                        '-${t1.toLocal().day.toString().padLeft(2, '0')}',
                  }),
              zIndex: 5,
            ));
            _stopIndices.add(start);
            idx++;
          }
        }
        start = null;
      }
    }
  }

  // ?? 7. Edge markers ???????????????????????????????????????????????????????
  Set<Marker> _edgeMarkersSet = {};
  void _buildEdgeMarkers() {
    _edgeMarkersSet = {};
    if (_positions.isEmpty) return;
    final f   = _positions.first;
    final l   = _positions.last;
    final flt = double.tryParse(f['latitude'].toString())  ?? 0;
    final fln = double.tryParse(f['longitude'].toString()) ?? 0;
    final llt = double.tryParse(l['latitude'].toString())  ?? 0;
    final lln = double.tryParse(l['longitude'].toString()) ?? 0;
    if (flt != 0) _edgeMarkersSet.add(Marker(
      markerId: const MarkerId('start'),
      position: LatLng(flt, fln),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      infoWindow: InfoWindow(title: tr('tm_trip_start')),
    ));
    if (llt != 0) _edgeMarkersSet.add(Marker(
      markerId: const MarkerId('end'),
      position: LatLng(llt, lln),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: InfoWindow(title: tr('tm_trip_end')),
    ));
  }

  // ?? Helpers ???????????????????????????????????????????????????????????????
  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';

  String _fmtIso(String? iso) {
    final dt = DateTime.tryParse(iso ?? '')?.toLocal();
    if (dt == null) return '--/--/-- --:--:--';
    final d = '${dt.year}/${dt.month.toString().padLeft(2,'0')}/${dt.day.toString().padLeft(2,'0')}';
    return '$d ${_fmt(dt)}';
  }

  double _calcBearing(double la1, double lo1, double la2, double lo2) {
    final dLon = (lo2 - lo1) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(la2 * math.pi / 180);
    final x = math.cos(la1 * math.pi / 180) * math.sin(la2 * math.pi / 180)
            - math.sin(la1 * math.pi / 180) * math.cos(la2 * math.pi / 180) * math.cos(dLon);
    return ((math.atan2(y, x) * 180 / math.pi) + 360) % 360;
  }

  BitmapDescriptor _getIcon(double angle, double spd) {
    final isOver = spd > widget.speedLimit;
    return _iconCache[isOver ? 'sprite_over' : 'sprite_norm']
        ?? BitmapDescriptor.defaultMarkerWithHue(
            isOver ? BitmapDescriptor.hueRed : BitmapDescriptor.hueAzure);
  }

  Set<Marker> _buildCarMarker(double lat, double lng, BitmapDescriptor icon) => {
    Marker(
      markerId: const MarkerId('car'),
      position: LatLng(lat, lng),
      icon:     icon,
      anchor:   const Offset(0.5, 0.5), // centered sprite
      rotation: _carAngle,              // heading (sprite front = north)
      flat:     true,
      zIndex:   10,
    ),
    ..._baseMarkers,
  };

  void _fitBounds() {
    if (_positions.isEmpty || _ctrl == null) return;
    final lats = _positions.map((p) => double.tryParse(p['latitude'].toString())  ?? 0).where((v) => v != 0);
    final lngs = _positions.map((p) => double.tryParse(p['longitude'].toString()) ?? 0).where((v) => v != 0);
    if (lats.isEmpty) return;
    _ctrl!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(lats.reduce(math.min), lngs.reduce(math.min)),
        northeast: LatLng(lats.reduce(math.max), lngs.reduce(math.max)),
      ),
      60,
    ));
  }

  // مثل iTrack: لا نحرّك الخريطة إلا عند اقتراب الماركر من حافة الشاشة
  Future<void> _maybeRecenter(double lat, double lng) async {
    final c = _ctrl;
    if (c == null) return;
    try {
      final b = await c.getVisibleRegion();
      final sw = b.southwest, ne = b.northeast;
      final latM = (ne.latitude - sw.latitude) * 0.05;
      final lngM = (ne.longitude - sw.longitude) * 0.05;
      final inside = lat >= sw.latitude + latM && lat <= ne.latitude - latM &&
          lng >= sw.longitude + lngM && lng <= ne.longitude - lngM;
      if (!inside) c.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
    } catch (_) {}
  }

  // ?? Playback - exact copy of web step() logic ?????????????????????????????
  // web: delay = Math.max(1, Math.round(16 / speed))
  // web: setLatLng every step, updatePlaybackInfo every 10 steps
  void _startPlay() {
    _timer?.cancel();
    final ms = (16 / _speed).round().clamp(1, 2000);
    _frame = 0;
    _timer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (!mounted) { _timer?.cancel(); return; }
      if (_interpIdx >= _interp.length - 1) {
        _timer?.cancel();
        setState(() { _playing = false; _origIdx = _positions.length - 1; });
        _showSummary();
        return;
      }
      _interpIdx++;
      _frame++;

      final ipos = _interp[_interpIdx];
      final lat  = ipos['lat'] as double;
      final lng  = ipos['lng'] as double;
      final spd  = ipos['speed'] as double;
      final orig = ipos['origIdx'] as int;

      // Every 10 frames: update icon, camera, slider, info (like web)
      if (_frame % 10 == 0) {
        // heading = bearing to a point ~6 steps ahead (smooths single-point GPS
        // jitter that used to flip the car backward), and only when actually moving
        final look = (_interpIdx + 6 < _interp.length)
            ? _interpIdx + 6 : _interp.length - 1;
        if (look > _interpIdx) {
          final nlat = _interp[look]['lat'] as double;
          final nlng = _interp[look]['lng'] as double;
          if ((nlat - lat).abs() + (nlng - lng).abs() > 0.00003) {
            _carAngle = _calcBearing(lat, lng, nlat, nlng);
          }
        }
        final angle = _carAngle;
        _carIcon  = _getIcon(angle, spd);
        _origIdx  = orig;
        _infoSpd  = spd.toStringAsFixed(1);
        _infoTime = _fmtIso(_positions[orig]['fixTime']?.toString());
        setState(() {
          _markers = _buildCarMarker(lat, lng, _carIcon!);
        });
        _maybeRecenter(lat, lng);
      } else {
        // Other frames: update position only, reuse current icon
        setState(() {
          _markers = _buildCarMarker(lat, lng, _carIcon ?? _getIcon(0, spd));
        });
      }
    });
  }

  void _stopPlay()   { _timer?.cancel(); }
  void _togglePlay() {
    if (_playing) {
      _stopPlay();
      setState(() => _playing = false);
    } else {
      setState(() => _playing = true);
      _startPlay();
    }
  }

  void _seekTo(int origIdx) {
    _stopPlay();
    _origIdx   = origIdx.clamp(0, _positions.length - 1);
    _interpIdx = 0;
    // Find closest interp point to this origIdx
    for (int i = 0; i < _interp.length; i++) {
      if ((_interp[i]['origIdx'] as int) >= _origIdx) { _interpIdx = i; break; }
    }
    final ipos = _interp.isNotEmpty ? _interp[_interpIdx] : null;
    final lat  = ipos?['lat'] as double? ?? 0;
    final lng  = ipos?['lng'] as double? ?? 0;
    final spd  = ipos?['speed'] as double? ?? 0;
    _carIcon   = _getIcon(_carAngle, spd);
    _infoTime  = _fmtIso(_positions[_origIdx]['fixTime']?.toString());
    _infoSpd   = spd.toStringAsFixed(1);
    setState(() {
      _playing = false;
      _markers = _buildCarMarker(lat, lng, _carIcon!);
    });
    if (lat != 0) _ctrl?.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
  }

  void _skipForward() {
    final next = _stopIndices.where((i) => i > _origIdx).toList();
    _seekTo(next.isNotEmpty ? next.first : (_origIdx + _positions.length ~/ 10).clamp(0, _positions.length - 1));
  }

  void _skipBackward() {
    final prev = _stopIndices.where((i) => i < _origIdx - 2).toList();
    _seekTo(prev.isNotEmpty ? prev.last : (_origIdx - _positions.length ~/ 10).clamp(0, _positions.length - 1));
  }

  // ?? Summary modal at end (like web) ??????????????????????????????????????
  void _showSummary() {
    if (_positions.isEmpty) return;
    final first = _positions.first;
    final last  = _positions.last;
    final t1    = DateTime.tryParse(first['fixTime']?.toString() ?? '')?.toLocal();
    final t2    = DateTime.tryParse(last['fixTime']?.toString() ?? '')?.toLocal();
    final durMin = t1 != null && t2 != null ? t2.difference(t1).inMinutes : 0;
    final hrs    = durMin ~/ 60;
    final mins   = durMin % 60;
    final durStr = hrs > 0 ? tr('dur_hm', {'h': '$hrs', 'm': '$mins'}) : tr('dur_min', {'m': '$mins'});
    // المسافة من عدّاد الكيلومترات (odometer/totalDistance) — دقيق ومناعة ضد
    // تشويش الـ GPS وهو واقف (جمع haversine كان يضخّم المسافة من التشويش)
    double? odoOf(Map p) { final a = p['attributes']; if (a is Map && a['totalDistance'] is num) return (a['totalDistance'] as num).toDouble(); return null; }
    final firstOdo = _positions.isNotEmpty ? odoOf(_positions.first) : null;
    final lastOdo  = _positions.isNotEmpty ? odoOf(_positions.last)  : null;
    double distKm = 0;
    if (firstOdo != null && lastOdo != null && lastOdo >= firstOdo) {
      distKm = (lastOdo - firstOdo) / 1000.0;
    } else {
      // fallback: haversine مع فلتر (تجاهل القفزات >2كم والتشويش <15م)
      for (int i = 1; i < _positions.length; i++) {
        final p1 = _positions[i - 1], p2 = _positions[i];
        final la1 = double.tryParse(p1['latitude'].toString())  ?? 0;
        final lo1 = double.tryParse(p1['longitude'].toString()) ?? 0;
        final la2 = double.tryParse(p2['latitude'].toString())  ?? 0;
        final lo2 = double.tryParse(p2['longitude'].toString()) ?? 0;
        if (la1 == 0 || la2 == 0) continue;
        final dLat = (la2 - la1) * math.pi / 180;
        final dLon = (lo2 - lo1) * math.pi / 180;
        final a = math.sin(dLat/2)*math.sin(dLat/2) +
            math.cos(la1*math.pi/180)*math.cos(la2*math.pi/180)*
            math.sin(dLon/2)*math.sin(dLon/2);
        final d = 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a));
        if (d >= 0.015 && d < 2) distKm += d;
      }
    }
    final distStr = distKm.toStringAsFixed(1);
    final maxSpd = _positions
        .map((p) => ((p['speed'] ?? 0) as num).toDouble() * 1.852)
        .reduce(math.max)
        .toStringAsFixed(1);
    final dateStr = t1 != null
        ? '${t1.day}/${t1.month}/${t1.year}'
        : '-';
    final fromT = t1 != null ? _fmt(t1) : '-';
    final toT   = t2 != null ? _fmt(t2) : '-';

    showDialog(
      context: context,
      // نستخدم context الحوار نفسه للإغلاق. الشاشة تُعاد بناؤها كل ثانية (عدّاد
      // التحديث)، فالإغلاق بـ context الشاشة قد يصادف لحظة إعادة بناء فيتأخر أو يضيع.
      builder: (dialogCtx) => Dialog(
        backgroundColor: const Color(0xFF1e293b),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFC41E3A), width: 1)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('trip_summary'),
                style: const TextStyle(color: Colors.white, fontFamily: 'Cairo',
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(children: [
              _SummaryCard(tr('ts_distance'),    distStr, tr('unit_km'),     const Color(0xFF6BA539)),
              const SizedBox(width: 8),
              _SummaryCard(tr('ts_duration'),      durStr,  '',       const Color(0xFF38bdf8)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _SummaryCard(tr('ts_max_speed'), maxSpd,  tr('unit_kmh'),  const Color(0xFFC41E3A)),
              const SizedBox(width: 8),
              _SummaryCard(tr('ts_points'),      '${_positions.length}', '', const Color(0xFFFBBF24)),
            ]),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFF0f1f35),
                  borderRadius: BorderRadius.circular(10)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$dateStr',
                    style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12)),
                const SizedBox(height: 4),
                Text(tr('ts_from_to', {'f': fromT, 't': toT}),
                    style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo', fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC41E3A),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: () => Navigator.pop(dialogCtx),
                child: Text(tr('close'),
                    style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ????????????????????????????????????????????????????????????????????????
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // ?? Map ????????????????????????????????????????????????????????????
        GoogleMap(
          initialCameraPosition:
              const CameraPosition(target: LatLng(30.0444, 31.2357), zoom: 13),
          markers:               _markers,
          polylines:             _polylines,
          mapType:               _mapType,
          zoomControlsEnabled:   false,
          compassEnabled:        false,
          mapToolbarEnabled:     false,
          myLocationButtonEnabled: false,
          onTap: (_) {
            if (_selectedStop != null) setState(() => _selectedStop = null);
          },
          onMapCreated: (c) {
            _ctrl = c;
            if (_loaded) _fitBounds();
          },
        ),

        // ── بطاقة نقطة التوقف ───────────────────────────────────────────────
        if (_selectedStop != null)
          Positioned(
            top: 100, left: 12, right: 12,
            child: Directionality(
              textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFF6F00).withOpacity(.6)),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 4))],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Container(
                        width: 26, height: 26, alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Color(0xFFFF6F00), shape: BoxShape.circle),
                        child: Text('${_selectedStop!['no']}',
                            style: const TextStyle(fontFamily: 'Cairo', color: Colors.white,
                                fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('${tr('tm_stop')} · ${_selectedStop!['dur']}',
                            style: const TextStyle(fontFamily: 'Cairo', color: Colors.white,
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _selectedStop = null),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, color: Colors.white70, size: 20),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.calendar_today_outlined, color: Colors.white54, size: 14),
                      const SizedBox(width: 6),
                      Text('${_selectedStop!['date']}',
                          style: const TextStyle(fontFamily: 'Cairo', color: Colors.white70, fontSize: 12),
                          textDirection: TextDirection.ltr),
                    ]),
                    const SizedBox(height: 5),
                    Row(children: [
                      const Icon(Icons.schedule, color: Colors.white54, size: 15),
                      const SizedBox(width: 6),
                      // اتجاه صريح: في الواجهة العربية ينقلب ترتيب الوقتين فيبدو
                      // كأن نهاية التوقف قبل بدايته
                      Text('${_selectedStop!['from']} - ${_selectedStop!['to']}',
                          style: const TextStyle(fontFamily: 'Cairo', color: Colors.white70, fontSize: 12),
                          textDirection: TextDirection.ltr),
                    ]),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity, height: 38,
                      child: ElevatedButton.icon(
                        onPressed: () => navigateToPoint(
                            (_selectedStop!['lat'] as num).toDouble(),
                            (_selectedStop!['lng'] as num).toDouble()),
                        icon: const Icon(Icons.navigation_outlined, size: 17),
                        label: Text(tr('btn_navigate'),
                            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A6B3C),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),

        // ?? Top bar ????????????????????????????????????????????????????????
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.device.name,
                    style: const TextStyle(color: Colors.white,
                        fontFamily: 'Cairo', fontWeight: FontWeight.w600))),
                if (_loading) const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                if (!_loaded && !_loading) ...[
                  _PBtn(tr('pd_today'), _period == 'today',
                      () { setState(() => _period = 'today');     _init(); }),
                  const SizedBox(width: 4),
                  _PBtn(tr('pd_yesterday'),   _period == 'yesterday',
                      () { setState(() => _period = 'yesterday'); _init(); }),
                  const SizedBox(width: 4),
                  _PBtn(tr('pd_hour'),    _period == 'hour',
                      () { setState(() => _period = 'hour');      _init(); }),
                ],
              ]),
            ),
          ),
        ),

        // ?? Bottom controls ????????????????????????????????????????????????
        if (_positions.isNotEmpty)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            color: Colors.black87,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [

              // Map type tabs
              Row(children: [
                for (final e in {
                  tr('mt_map'): MapType.normal, tr('mt_satellite'): MapType.satellite,
                  tr('mt_hybrid'): MapType.hybrid,
                }.entries)
                  Expanded(child: GestureDetector(
                    onTap: () => setState(() => _mapType = e.value),
                    child: Container(
                      margin: const EdgeInsets.only(right: 3),
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        color: _mapType == e.value
                            ? const Color(0xFFC41E3A) : Colors.white10,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(e.key, textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _mapType == e.value ? Colors.white : Colors.white54,
                            fontSize: 10, fontFamily: 'Cairo',
                          )),
                    ),
                  )),
              ]),
              const SizedBox(height: 6),

              // Info bar
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_infoTime,
                    style: const TextStyle(color: Color(0xFFA5F3FC),
                        fontFamily: 'Cairo', fontSize: 11)),
                Text('$_infoSpd ${tr('unit_kmh')}',
                    style: const TextStyle(color: Colors.white,
                        fontFamily: 'Cairo', fontSize: 11)),
              ]),
              const SizedBox(height: 4),

              // Slider
              SliderTheme(
                data: SliderThemeData(
                  thumbColor:         Colors.white,
                  activeTrackColor:   const Color(0xFF6BA539),
                  inactiveTrackColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  trackHeight: 3,
                ),
                child: Slider(
                  value: _origIdx.toDouble(),
                  min:   0,
                  max:   (_positions.length - 1).toDouble(),
                  onChanged: (v) => _seekTo(v.toInt()),
                ),
              ),

              // Play row
              Row(children: [
                _CBtn(icon: Icons.skip_previous, onTap: _skipBackward),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    width: 48, height: 48,
                    decoration: const BoxDecoration(
                        color: Color(0xFFC41E3A), shape: BoxShape.circle),
                    child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white, size: 26),
                  ),
                ),
                const SizedBox(width: 6),
                _CBtn(icon: Icons.skip_next, onTap: _skipForward),
                const SizedBox(width: 8),
                Expanded(child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: _speeds.map((s) {
                    final active = _speed == s['v'];
                    return GestureDetector(
                      onTap: () {
                        setState(() => _speed = s['v'] as double);
                        if (_playing) { _stopPlay(); _startPlay(); }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 5),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFF1565C0) : Colors.white12,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(s['l'] as String,
                            style: TextStyle(
                              color: active ? Colors.white : Colors.white60,
                              fontSize: 11, fontFamily: 'Cairo',
                            )),
                      ),
                    );
                  }).toList()),
                )),
              ]),
            ]),
          ),
        ),

        if (_loading)
          const _CinematicLoader(),
      ]),
    );
  }
}

// ?? Helper widgets ????????????????????????????????????????????????????????????
class _SummaryCard extends StatelessWidget {
  final String label, value, unit;
  final Color valueColor;
  const _SummaryCard(this.label, this.value, this.unit, this.valueColor);
  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: const Color(0xFF0f1f35),
          borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Text(label, style: const TextStyle(color: Colors.white54,
            fontFamily: 'Cairo', fontSize: 11)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: valueColor, fontFamily: 'Cairo',
            fontSize: 20, fontWeight: FontWeight.bold)),
        if (unit.isNotEmpty)
          Text(unit, style: const TextStyle(color: Colors.white38,
              fontFamily: 'Cairo', fontSize: 10)),
      ]),
    ),
  );
}

class _CBtn extends StatelessWidget {
  final IconData icon; final VoidCallback onTap;
  const _CBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 38, height: 38,
      decoration: BoxDecoration(color: Colors.white12,
          borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, color: Colors.white70, size: 22),
    ),
  );
}

// ?? Cinematic loading screen ?????????????????????????????????????????????????
// ?? Vehicle icon painter for picker grid ??????????????????????????????????????
class _VehicleIconPainter extends CustomPainter {
  final String type;
  final Color  color;
  const _VehicleIconPainter(this.type, this.color);

  @override
  void paint(Canvas c, Size s) {
    // Reuse same top-down helpers as the map marker
    final r    = Rect.fromLTWH(2, 2, s.width - 4, s.height - 4);
    final body  = Paint()..color = color;
    final roof  = Paint()..color = Color.fromARGB(255,
        (color.red * 0.75).round(), (color.green * 0.75).round(), (color.blue * 0.75).round());
    final glass = Paint()..color = const Color(0xCC90CAF9);
    final glare = Paint()..color = Colors.white.withOpacity(0.22);
    final bdr   = Paint()..color = Colors.black.withOpacity(0.45)
                          ..style = PaintingStyle.stroke..strokeWidth = 1.0;
    final hl    = Paint()..color = const Color(0xFFFFF9C4);
    final tl    = Paint()..color = const Color(0xFFEF5350);
    final mir   = Paint()..color = color.withOpacity(0.85);
    final x = r.left, y = r.top, w = r.width, h = r.height;

    switch (type) {
      case 'car':      _s(c,x,y,w,h,color,body,roof,glass,glare,bdr,hl,tl,mir); break;
      case 'suv':      _suv(c,x,y,w,h,color,body,roof,glass,glare,bdr,hl,tl,mir); break;
      case 'pickup':   _pu(c,x,y,w,h,color,body,roof,glass,glare,bdr,hl,tl,mir); break;
      case 'van':      _van(c,x,y,w,h,color,body,roof,glass,glare,bdr,hl,tl); break;
      case 'bus':      _bus(c,x,y,w,h,color,body,roof,glass,bdr,hl,tl); break;
      case 'truck':    _trk(c,x,y,w,h,color,body,roof,glass,bdr,hl,tl); break;
      case 'motorcycle': _moto(c,x,y,w,h,color,body,bdr); break;
      case 'tuk_tuk':  _tuk(c,x,y,w,h,color,body,roof,glass,bdr,hl,tl); break;
      case 'excavator': _exc(c,x,y,w,h,body,roof,bdr); break;
      case 'tractor':  _trac(c,x,y,w,h,color,body,roof,bdr); break;
      case 'boat':     _boat(c,x,y,w,h,color,body,glass,bdr); break;
      case 'person':
        c.drawCircle(Offset(x+w/2,y+h*0.35),w*0.3,body);
        c.drawOval(Rect.fromLTWH(x+w*0.2,y+h*0.6,w*0.6,h*0.33),Paint()..color=color.withOpacity(0.7));
        c.drawCircle(Offset(x+w/2,y+h*0.35),w*0.3,bdr);
        break;
      case 'arrow':
        final arr = Path()..moveTo(x+w/2,y)..lineTo(x+w*0.88,y+h*0.55)
            ..lineTo(x+w*0.62,y+h*0.55)..lineTo(x+w*0.62,y+h)
            ..lineTo(x+w*0.38,y+h)..lineTo(x+w*0.38,y+h*0.55)
            ..lineTo(x+w*0.12,y+h*0.55)..close();
        c.drawPath(arr,body); c.drawPath(arr,bdr);
        break;
      default: _s(c,x,y,w,h,color,body,roof,glass,glare,bdr,hl,tl,mir); break;
    }
  }

  // حفّار من أعلى: جنزيران غامقان على الجانبين، جسم في الوسط، ذراع لأعلى ينتهي بجاروف
  void _exc(Canvas c,double x,double y,double w,double h,Paint body,Paint roof,Paint bdr){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.05,y+h*.40,w*.17,h*.56),3,3),roof);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.78,y+h*.40,w*.17,h*.56),3,3),roof);
    final hull = RRect.fromRectXY(Rect.fromLTWH(x+w*.23,y+h*.46,w*.54,h*.48),5,5);
    c.drawRRect(hull,body); c.drawRRect(hull,bdr);
    final arm = RRect.fromRectXY(Rect.fromLTWH(x+w*.43,y+h*.15,w*.14,h*.34),3,3);
    c.drawRRect(arm,body); c.drawRRect(arm,bdr);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.33,y+h*.02,w*.34,h*.15),3,3),roof);
  }

  // Sedan
  void _s(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint glare,Paint bdr,Paint hl,Paint tl,Paint mir){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.05,w*.88,h*.9),10,10),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.14,y+h*.28,w*.72,h*.42),6,6),roof);
    c.drawPath(Path()..moveTo(x+w*.18,y+h*.28)..lineTo(x+w*.82,y+h*.28)..lineTo(x+w*.76,y+h*.12)..lineTo(x+w*.24,y+h*.12)..close(),glass);
    c.drawPath(Path()..moveTo(x+w*.22,y+h*.26)..lineTo(x+w*.4,y+h*.26)..lineTo(x+w*.36,y+h*.13)..lineTo(x+w*.22,y+h*.13)..close(),glare);
    c.drawPath(Path()..moveTo(x+w*.2,y+h*.7)..lineTo(x+w*.8,y+h*.7)..lineTo(x+w*.76,y+h*.86)..lineTo(x+w*.24,y+h*.86)..close(),Paint()..color=const Color(0x9990CAF9));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x,y+h*.22,w*.07,h*.06),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.93,y+h*.22,w*.07,h*.06),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.05,w*.28,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.05,w*.28,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.9,w*.28,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.9,w*.28,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.05,w*.88,h*.9),10,10),bdr);
  }
  void _suv(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint glare,Paint bdr,Paint hl,Paint tl,Paint mir){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.04,w*.92,h*.92),9,9),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.26,w*.8,h*.48),6,6),roof);
    c.drawPath(Path()..moveTo(x+w*.14,y+h*.26)..lineTo(x+w*.86,y+h*.26)..lineTo(x+w*.82,y+h*.1)..lineTo(x+w*.18,y+h*.1)..close(),glass);
    c.drawPath(Path()..moveTo(x+w*.2,y+h*.24)..lineTo(x+w*.38,y+h*.24)..lineTo(x+w*.35,y+h*.11)..lineTo(x+w*.2,y+h*.11)..close(),glare);
    c.drawPath(Path()..moveTo(x+w*.14,y+h*.74)..lineTo(x+w*.86,y+h*.74)..lineTo(x+w*.82,y+h*.9)..lineTo(x+w*.18,y+h*.9)..close(),Paint()..color=const Color(0x9990CAF9));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x,y+h*.2,w*.05,h*.08),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.95,y+h*.2,w*.05,h*.08),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.04,w*.3,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.04,w*.3,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.91,w*.3,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.91,w*.3,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.04,w*.92,h*.92),9,9),bdr);
  }
  void _pu(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint glare,Paint bdr,Paint hl,Paint tl,Paint mir){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.05,w*.88,h*.9),8,8),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.12,y+h*.26,w*.76,h*.28),5,5),roof);
    c.drawPath(Path()..moveTo(x+w*.16,y+h*.26)..lineTo(x+w*.84,y+h*.26)..lineTo(x+w*.8,y+h*.12)..lineTo(x+w*.2,y+h*.12)..close(),glass);
    c.drawLine(Offset(x+w*.08,y+h*.56),Offset(x+w*.92,y+h*.56),Paint()..color=Colors.black.withOpacity(.25)..strokeWidth=1.5);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x,y+h*.2,w*.07,h*.06),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.93,y+h*.2,w*.07,h*.06),1,1),mir);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.05,w*.28,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.05,w*.28,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.9,w*.28,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.9,w*.28,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.05,w*.88,h*.9),8,8),bdr);
  }
  void _van(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint glare,Paint bdr,Paint hl,Paint tl){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.04,w*.92,h*.92),8,8),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.25,w*.84,h*.5),5,5),roof);
    c.drawPath(Path()..moveTo(x+w*.1,y+h*.25)..lineTo(x+w*.9,y+h*.25)..lineTo(x+w*.88,y+h*.1)..lineTo(x+w*.12,y+h*.1)..close(),glass);
    c.drawPath(Path()..moveTo(x+w*.1,y+h*.75)..lineTo(x+w*.9,y+h*.75)..lineTo(x+w*.88,y+h*.9)..lineTo(x+w*.12,y+h*.9)..close(),Paint()..color=const Color(0x7790CAF9));
    c.drawLine(Offset(x+w*.06,y+h*.42),Offset(x+w*.94,y+h*.42),Paint()..color=Colors.black.withOpacity(.18)..strokeWidth=1.2);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.04,w*.3,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.04,w*.3,h*.05),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.91,w*.3,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.91,w*.3,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.04,w*.92,h*.92),8,8),bdr);
  }
  void _bus(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint bdr,Paint hl,Paint tl){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.02,w*.92,h*.96),7,7),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.2,w*.8,h*.6),4,4),roof);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.05,w*.8,h*.13),3,3),glass);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.82,w*.8,h*.13),3,3),Paint()..color=const Color(0x7790CAF9));
    for(int i=0;i<3;i++){c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.12+i*w*.28,y+h*.22,w*.22,h*.14),2,2),glass);}
    for(int i=0;i<3;i++){c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.12+i*w*.28,y+h*.64,w*.22,h*.14),2,2),glass);}
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.02,w*.3,h*.04),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.02,w*.3,h*.04),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.08,y+h*.94,w*.3,h*.04),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.94,w*.3,h*.04),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.04,y+h*.02,w*.92,h*.96),7,7),bdr);
  }
  void _trk(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint bdr,Paint hl,Paint tl){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.38,w*.88,h*.58),5,5),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.04,w*.88,h*.36),8,8),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.12,y+h*.2,w*.76,h*.18),4,4),roof);
    c.drawPath(Path()..moveTo(x+w*.14,y+h*.2)..lineTo(x+w*.86,y+h*.2)..lineTo(x+w*.82,y+h*.07)..lineTo(x+w*.18,y+h*.07)..close(),glass);
    c.drawLine(Offset(x+w*.06,y+h*.55),Offset(x+w*.94,y+h*.55),Paint()..color=Colors.black.withOpacity(.12)..strokeWidth=1);
    c.drawLine(Offset(x+w*.06,y+h*.72),Offset(x+w*.94,y+h*.72),Paint()..color=Colors.black.withOpacity(.12)..strokeWidth=1);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.04,w*.28,h*.04),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.04,w*.28,h*.04),1,1),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.92,w*.28,h*.04),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.62,y+h*.92,w*.28,h*.04),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.06,y+h*.04,w*.88,h*.92),5,5),bdr);
  }
  void _moto(Canvas c,double x,double y,double w,double h,Color col,Paint body,Paint bdr){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.3,y+h*.06,w*.4,h*.7),8,8),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.1,y+h*.08,w*.8,h*.08),3,3),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.32,y+h*.42,w*.36,h*.28),5,5),Paint()..color=const Color(0xFF1A1A2E));
    c.drawOval(Rect.fromLTWH(x+w*.38,y+h*.06,w*.24,h*.08),Paint()..color=const Color(0xFFFFF9C4));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.3,y+h*.06,w*.4,h*.7),8,8),bdr);
  }
  void _tuk(Canvas c,double x,double y,double w,double h,Color col,
      Paint body,Paint roof,Paint glass,Paint bdr,Paint hl,Paint tl){
    final bd=Path()..moveTo(x+w*.5,y+h*.04)
        ..quadraticBezierTo(x+w*.72,y+h*.04,x+w*.9,y+h*.2)
        ..lineTo(x+w*.9,y+h*.78)..quadraticBezierTo(x+w*.9,y+h*.94,x+w*.72,y+h*.94)
        ..lineTo(x+w*.28,y+h*.94)..quadraticBezierTo(x+w*.1,y+h*.94,x+w*.1,y+h*.78)
        ..lineTo(x+w*.1,y+h*.2)..quadraticBezierTo(x+w*.28,y+h*.04,x+w*.5,y+h*.04)..close();
    c.drawPath(bd,body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.18,y+h*.24,w*.64,h*.44),6,6),roof);
    c.drawPath(Path()..moveTo(x+w*.22,y+h*.24)..lineTo(x+w*.78,y+h*.24)..lineTo(x+w*.68,y+h*.1)..lineTo(x+w*.32,y+h*.1)..close(),glass);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.38,y+h*.04,w*.24,h*.06),2,2),hl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.2,y+h*.88,w*.22,h*.05),1,1),tl);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.58,y+h*.88,w*.22,h*.05),1,1),tl);
    c.drawPath(bd,bdr);
  }
  void _trac(Canvas c,double x,double y,double w,double h,Color col,Paint body,Paint roof,Paint bdr){
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.28,y+h*.04,w*.44,h*.32),5,5),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.2,y+h*.3,w*.6,h*.28),6,6),body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.26,y+h*.34,w*.48,h*.18),4,4),roof);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.22,y+h*.55,w*.56,h*.36),6,6),body);
    c.drawLine(Offset(x+w*.42,y+h*.04),Offset(x+w*.42,y),Paint()..color=col..strokeWidth=w*.06..strokeCap=StrokeCap.round);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.28,y+h*.04,w*.44,h*.32),5,5),bdr);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.2,y+h*.3,w*.6,h*.28),6,6),bdr);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.22,y+h*.55,w*.56,h*.36),6,6),bdr);
  }
  void _boat(Canvas c,double x,double y,double w,double h,Color col,Paint body,Paint glass,Paint bdr){
    final hull=Path()..moveTo(x+w*.5,y+h*.04)
        ..quadraticBezierTo(x+w*.96,y+h*.04,x+w*.96,y+h*.5)
        ..quadraticBezierTo(x+w*.96,y+h*.88,x+w*.5,y+h*.96)
        ..quadraticBezierTo(x+w*.04,y+h*.88,x+w*.04,y+h*.5)
        ..quadraticBezierTo(x+w*.04,y+h*.04,x+w*.5,y+h*.04)..close();
    c.drawPath(hull,body);
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(x+w*.2,y+h*.12,w*.6,h*.2),5,5),glass);
    c.drawLine(Offset(x+w*.1,y+h*.38),Offset(x+w*.9,y+h*.38),Paint()..color=Colors.black.withOpacity(.2)..strokeWidth=1.2);
    c.drawPath(hull,bdr);
  }

  @override
  bool shouldRepaint(_) => false;
}


class _CinematicLoader extends StatefulWidget {
  const _CinematicLoader();
  @override
  State<_CinematicLoader> createState() => _CinematicLoaderState();
}

class _CinematicLoaderState extends State<_CinematicLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _carX;
  late Animation<double>   _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _carX = Tween<double>(begin: -0.6, end: 0.6).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    _fade = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Container(
      color: Colors.black.withOpacity(0.82),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Road
          Container(
            width: w * 0.75, height: 3,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 0),
          // Car moving on road
          SizedBox(
            width: w * 0.75, height: 80,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Stack(
                alignment: Alignment.center,
                children: [
                  // Dashed road lines
                  Row(mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(7, (i) => Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      width: 20, height: 2,
                      color: Colors.white.withOpacity(0.15),
                    ))),
                  // Car - faces direction of movement (rotated 90° to face right)
                  Transform.translate(
                    offset: Offset(_carX.value * w * 0.32, 0),
                    child: Opacity(
                      opacity: _fade.value,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.rotationZ(math.pi / 2),
                        child: CustomPaint(
                          size: const Size(38, 68),
                          painter: _TopCarPainter(false),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: w * 0.75, height: 3,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Text(tr('loading_route'),
              style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo',
                  fontSize: 13)),
          const SizedBox(height: 10),
          SizedBox(
            width: 140,
            child: LinearProgressIndicator(
              color: const Color(0xFFC41E3A),
              backgroundColor: Colors.white12,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ]),
      ),
    );
  }
}

class _TopCarPainter extends CustomPainter {
  final bool isOver;
  const _TopCarPainter(this.isOver);

  @override
  void paint(Canvas c, Size s) {
    final body  = isOver ? const Color(0xFFB03A2E) : const Color(0xFF1A5276);
    final roof  = isOver ? const Color(0xFF7B241C) : const Color(0xFF154360);
    const glass = Color(0xCC90CAF9);

    // Shadow
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(3, 4, s.width - 4, s.height - 2),
          const Radius.circular(6)),
      Paint()..color = Colors.black.withOpacity(0.3)
             ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Body
    c.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(2, 2, s.width - 4, s.height - 4), 6, 6),
      Paint()..color = body,
    );
    // Roof
    final rL = s.width * 0.18, rT = s.height * 0.3;
    final rW = s.width * 0.64, rH = s.height * 0.38;
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(rL, rT, rW, rH), 4, 4),
        Paint()..color = roof);
    // Front windshield
    c.drawPath(Path()
      ..moveTo(s.width * 0.15, s.height * 0.3)
      ..lineTo(s.width * 0.85, s.height * 0.3)
      ..lineTo(s.width * 0.78, s.height * 0.14)
      ..lineTo(s.width * 0.22, s.height * 0.14)
      ..close(), Paint()..color = glass);
    // Rear windshield
    c.drawPath(Path()
      ..moveTo(s.width * 0.18, s.height * 0.68)
      ..lineTo(s.width * 0.82, s.height * 0.68)
      ..lineTo(s.width * 0.76, s.height * 0.84)
      ..lineTo(s.width * 0.24, s.height * 0.84)
      ..close(), Paint()..color = glass.withOpacity(0.6));
    // Headlights
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(4, 3, 9, 3), 1, 1),
        Paint()..color = const Color(0xFFFFF9C4));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(s.width - 13, 3, 9, 3), 1, 1),
        Paint()..color = const Color(0xFFFFF9C4));
    // Tail lights
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(4, s.height - 6, 9, 3), 1, 1),
        Paint()..color = const Color(0xFFEF5350));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(s.width - 13, s.height - 6, 9, 3), 1, 1),
        Paint()..color = const Color(0xFFEF5350));
    // Mirrors
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(-2, s.height * 0.22, 5, 3), 1, 1),
        Paint()..color = body.withOpacity(0.8));
    c.drawRRect(RRect.fromRectXY(Rect.fromLTWH(s.width - 3, s.height * 0.22, 5, 3), 1, 1),
        Paint()..color = body.withOpacity(0.8));
    // Outline
    c.drawRRect(
      RRect.fromRectXY(Rect.fromLTWH(2, 2, s.width - 4, s.height - 4), 6, 6),
      Paint()..color = Colors.black.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}

class _PBtn extends StatelessWidget {
  final String label; final bool active; final VoidCallback onTap;
  const _PBtn(this.label, this.active, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFC41E3A) : Colors.white24,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white,
          fontSize: 10, fontFamily: 'Cairo')),
    ),
  );
}








// ============================================================
// DeviceAlertsScreen - شاشة التنبيهات الواردة للجهاز
// ============================================================
class DeviceAlertsScreen extends StatefulWidget {
  final DeviceModel? device;                // جهاز واحد
  final List<DeviceModel>? allDevices;      // أو كل الأجهزة (لو device=null)
  const DeviceAlertsScreen({super.key, this.device, this.allDevices});
  @override
  State<DeviceAlertsScreen> createState() => _DeviceAlertsScreenState();
}

class _DeviceAlertsScreenState extends State<DeviceAlertsScreen> {
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;

  static const Map<String, IconData> _icons = {
    'ignitionOn': Icons.speed,
    'ignitionOff': Icons.power_off_outlined,
    'deviceOverspeed': Icons.warning_amber_outlined,
    'alarm': Icons.emergency_outlined,
    'deviceOffline': Icons.signal_wifi_off_outlined,
    'deviceOnline': Icons.wifi,
    'geofenceEnter': Icons.fence,
    'geofenceExit': Icons.fence,
    'deviceStopped': Icons.pause_circle_outline,
    'deviceMoving': Icons.directions_car_outlined,
  };

  static const Map<String, Color> _colors = {
    'ignitionOn': Color(0xFF6BA539),
    'ignitionOff': Color(0xFF8892A4),
    'deviceOverspeed': Color(0xFFF59E0B),
    'alarm': Color(0xFFC41E3A),
    'deviceOffline': Color(0xFFEF5350),
    'deviceOnline': Color(0xFF6BA539),
    'geofenceEnter': Color(0xFF2196F3),
    'geofenceExit': Color(0xFF9C27B0),
    'deviceStopped': Color(0xFF8892A4),
    'deviceMoving': Color(0xFF2196F3),
  };

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  Future<void> _loadAlerts() async {
    setState(() => _loading = true);
    try {
      if (widget.device != null) {
        final r = await ApiService.request('get_device_alerts', {
          'traccar_id': widget.device!.traccarId,
          'limit': 100,
        });
        if (mounted && r['success'] == true) {
          final list = (r['alerts'] as List).cast<Map<String, dynamic>>();
          for (final a in list) { a['_dev'] = widget.device; }
          setState(() => _alerts = list);
        }
      } else if (widget.allDevices != null) {
        // كل الأجهزة في نداء واحد. كان نداءً منفصلًا لكل جهاز بالتوازي، أي ٣٢ طلبًا
        // متزامنًا من ضغطة واحدة — بطيء (~٥ ثوانٍ) ويشغّل عاملًا على السيرفر لكل طلب.
        // السيرفر يرتّب ويدمج ويحترم نطاق صلاحية الحساب.
        final byTid = <int, DeviceModel>{
          for (final d in widget.allDevices!) d.traccarId: d
        };
        final r = await ApiService.request('get_device_alerts', {
          'traccar_id': 0,
          'all': 1,
          'limit': 200,
        });
        if (mounted && r['success'] == true) {
          final merged = <Map<String, dynamic>>[];
          for (final a in (r['alerts'] as List).cast<Map<String, dynamic>>()) {
            final raw = a['deviceId'];
            final tid = raw is num ? raw.toInt() : int.tryParse('$raw') ?? -1;
            final dev = byTid[tid];
            if (dev == null) continue; // جهاز خارج المعروض على الخريطة
            a['_dev'] = dev;
            merged.add(a);
          }
          setState(() => _alerts = merged);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _formatDateTime(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1F2E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1F2E),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 18),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(tr('alerts_title'), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
          actions: [
            IconButton(icon: const Icon(Icons.refresh, color: Color(0xFFF59E0B)), onPressed: _loadAlerts),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(color: Colors.white10, height: 1)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFF59E0B)))
            : _alerts.isEmpty
                ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.notifications_none_outlined, size: 64, color: Colors.white24),
                    const SizedBox(height: 12),
                    Text(tr('alerts_empty'), style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 14)),
                    const SizedBox(height: 8),
                    TextButton.icon(onPressed: _loadAlerts, icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFF59E0B)), label: Text(tr('refresh'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFFF59E0B)))),
                  ]))
                : RefreshIndicator(
                    color: const Color(0xFFF59E0B),
                    onRefresh: _loadAlerts,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _alerts.length,
                      itemBuilder: (_, i) {
                        final a = _alerts[i];
                        final type = a['type'] as String? ?? '';
                        final subtype = (a['alarm_subtype'] ?? a['subtype'])?.toString();
                        // alarm → لون/أيقونة حسب الـ subtype (فرملة/تسارع/كهرباء...) مش العام
                        final color = type == 'alarm' ? notifColorForType(type, subtype) : (_colors[type] ?? const Color(0xFF8892A4));
                        final icon = type == 'alarm' ? notifIconForType(type, subtype) : (_icons[type] ?? Icons.notifications_outlined);
                        // العربي: label السيرفر كما هو (صفر تغيير). الإنجليزي: معرّب من النوع
                        final label = I18n.isAr
                            ? (a['label'] as String? ?? type)
                            : notifTypeLabel(type, subtype);
                        final timeStr = _formatDateTime(a['eventTime']);
                        return InkWell(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => AlertDetailScreen(
                              alert: a,
                              device: a['_dev'] as DeviceModel,
                              label: label,
                              color: color,
                              icon: icon,
                              timeStr: timeStr,
                            ),
                          )),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Colors.white10)),
                            ),
                            child: Row(children: [
                              Container(
                                width: 40, height: 40,
                                decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
                                child: Icon(icon, size: 20, color: color),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white, fontFamily: 'Cairo')),
                                const SizedBox(height: 3),
                                Text((a['_dev'] as DeviceModel).name, style: const TextStyle(fontSize: 11, color: Colors.white38, fontFamily: 'Cairo')),
                                const SizedBox(height: 2),
                                Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.white54, fontFamily: 'Cairo')),
                              ])),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
                                child: Text(label, style: TextStyle(fontSize: 10, color: color, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.chevron_left, color: Colors.white24, size: 18),
                            ]),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}

// ============================================================
// منتقي التاريخ/الوقت بعجلات سكرول (بدل موديل التقويم)
// ============================================================
Future<DateTime?> showWheelDateTime(BuildContext context, DateTime? initial) {
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: const Color(0xFF14233B),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _WheelDateTimePicker(initial: initial ?? DateTime.now()),
  );
}

class _WheelDateTimePicker extends StatefulWidget {
  final DateTime initial;
  const _WheelDateTimePicker({required this.initial});
  @override
  State<_WheelDateTimePicker> createState() => _WheelDateTimePickerState();
}

class _WheelDateTimePickerState extends State<_WheelDateTimePicker> {
  late int _year, _month, _day, _hour, _minute;
  late final int _minYear, _maxYear;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _maxYear = now.year;
    _minYear = now.year - 5;
    _year = widget.initial.year.clamp(_minYear, _maxYear);
    _month = widget.initial.month;
    _day = widget.initial.day;
    _hour = widget.initial.hour;
    _minute = widget.initial.minute;
  }

  int get _daysInMonth => DateTime(_year, _month + 1, 0).day;

  Widget _wheel({
    required String label,
    required int count,
    required int selected,
    required String Function(int) text,
    required ValueChanged<int> onChanged,
  }) {
    return Expanded(
      child: Column(children: [
        Text(label, style: const TextStyle(color: Color(0xFF8FA8C8), fontSize: 11, fontFamily: 'Cairo')),
        const SizedBox(height: 4),
        SizedBox(
          height: 150,
          child: CupertinoPicker(
            scrollController: FixedExtentScrollController(initialItem: selected),
            itemExtent: 36,
            magnification: 1.1,
            squeeze: 1.1,
            useMagnifier: true,
            selectionOverlay: Container(
              decoration: BoxDecoration(
                border: Border.symmetric(
                    horizontal: BorderSide(color: Colors.white.withOpacity(0.15))),
              ),
            ),
            onSelectedItemChanged: onChanged,
            children: List.generate(count, (i) => Center(
              child: Text(text(i),
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontFamily: 'Cairo')),
            )),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ضبط اليوم لو تجاوز عدد أيام الشهر
    if (_day > _daysInMonth) _day = _daysInMonth;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Text(tr('pick_datetime'),
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
          const SizedBox(height: 10),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(children: [
              _wheel(label: tr('wp_year'), count: _maxYear - _minYear + 1, selected: _year - _minYear,
                  text: (i) => '${_minYear + i}', onChanged: (i) => setState(() => _year = _minYear + i)),
              _wheel(label: tr('wp_month'), count: 12, selected: _month - 1,
                  text: (i) => '${i + 1}', onChanged: (i) => setState(() => _month = i + 1)),
              _wheel(label: tr('wp_day'), count: _daysInMonth, selected: (_day - 1).clamp(0, _daysInMonth - 1),
                  text: (i) => '${i + 1}', onChanged: (i) => setState(() => _day = i + 1)),
              _wheel(label: tr('wp_hour'), count: 24, selected: _hour,
                  text: (i) => i.toString().padLeft(2, '0'), onChanged: (i) => setState(() => _hour = i)),
              _wheel(label: tr('wp_minute'), count: 60, selected: _minute,
                  text: (i) => i.toString().padLeft(2, '0'), onChanged: (i) => setState(() => _minute = i)),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: Text(tr('cancel'),
                  style: const TextStyle(color: Colors.white70, fontFamily: 'Cairo')),
            )),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(
              onPressed: () {
                final d = _day.clamp(1, _daysInMonth);
                Navigator.pop(context, DateTime(_year, _month, d, _hour, _minute));
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC41E3A),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: Text(tr('done'),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Cairo')),
            )),
          ]),
        ]),
      ),
    );
  }
}

// ============================================================
// AlertDetailScreen - تفاصيل التنبيه
// ============================================================
class AlertDetailScreen extends StatefulWidget {
  final Map<String, dynamic> alert;
  final DeviceModel device;
  final String label;
  final Color color;
  final IconData icon;
  final String timeStr;

  const AlertDetailScreen({
    super.key,
    required this.alert,
    required this.device,
    required this.label,
    required this.color,
    required this.icon,
    required this.timeStr,
  });

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  String _locationStr = '';

  @override
  void initState() {
    super.initState();
    final lat = widget.alert['lat'] != null ? (widget.alert['lat'] as num).toDouble() : widget.device.lat;
    final lng = widget.alert['lng'] != null ? (widget.alert['lng'] as num).toDouble() : widget.device.lng;
    if (lat != null && lng != null) {
      _locationStr = '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
      _fetchAddress(lat, lng);
    }
  }

  Future<void> _fetchAddress(double lat, double lng) async {
    final k = _AsyncAddressText._cacheKey(lat, lng);
    if (_AsyncAddressText._cache.containsKey(k)) {
      if (mounted) setState(() => _locationStr = _AsyncAddressText._cache[k]!);
      return;
    }
    try {
      final r = await ApiService.request('reverse_geocode', {'lat': lat, 'lng': lng, 'lang': I18n.lang});
      final raw = (r['address'] ?? '').toString().trim();
      if (raw.isEmpty) return;
      final cleaned = _AsyncAddressText._clean(raw);
      final display = cleaned.isNotEmpty ? cleaned : raw;
      _AsyncAddressText._cache[k] = display;
      if (mounted) setState(() => _locationStr = display);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final lat = widget.alert['lat'] != null ? (widget.alert['lat'] as num).toDouble() : widget.device.lat;
    final lng = widget.alert['lng'] != null ? (widget.alert['lng'] as num).toDouble() : widget.device.lng;

    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1F2E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1F2E),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 18),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(tr('alert_detail'), style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        body: Column(children: [
          // Map
          if (lat != null && lng != null)
            SizedBox(
              height: 250,
              child: GoogleMap(
                initialCameraPosition: CameraPosition(target: LatLng(lat, lng), zoom: 16),
                markers: {
                  Marker(
                    markerId: const MarkerId('alert'),
                    position: LatLng(lat, lng),
                    infoWindow: InfoWindow(title: widget.label, snippet: widget.timeStr),
                  ),
                },
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
              ),
            ),
          // Details
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  _DetailRow(icon: widget.icon, color: widget.color, label: tr('ad_type'), value: widget.label),
                  const Divider(color: Colors.white10),
                  _DetailRow(icon: Icons.directions_car_outlined, color: const Color(0xFF8892A4), label: tr('ad_device'), value: widget.device.name),
                  const Divider(color: Colors.white10),
                  _DetailRow(icon: Icons.access_time, color: const Color(0xFF8892A4), label: tr('ad_time'), value: widget.timeStr),
                  if (widget.alert['type'] == 'deviceOverspeed' && widget.alert['speed'] != null) ...[
                    const Divider(color: Colors.white10),
                    _DetailRow(icon: Icons.speed, color: const Color(0xFFC41E3A), label: tr('ad_recorded_speed'), value: '${(widget.alert['speed'] as num).round()} ${tr('unit_kmh')}'),
                    if (widget.alert['speedLimit'] != null) ...[
                      const Divider(color: Colors.white10),
                      _DetailRow(icon: Icons.shield_outlined, color: const Color(0xFF6BA539), label: tr('ad_allowed'), value: '${(widget.alert['speedLimit'] as num).round()} ${tr('unit_kmh')}'),
                    ],
                  ],
                  if (lat != null && lng != null) ...[
                    const Divider(color: Colors.white10),
                    _DetailRow(icon: Icons.location_on_outlined, color: const Color(0xFF8892A4), label: tr('ad_location'), value: _locationStr),
                  ],
                ]),
              ),
            ]),
          )),
        ]),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white54, fontFamily: 'Cairo', fontSize: 12)),
        const Spacer(),
        Flexible(child: Text(value, style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w500), textAlign: TextAlign.end)),
      ]),
    );
  }
}

// ── widget يعرض الإحداثيات أولاً ثم يستبدلها بالعنوان العربي ──
class _AsyncAddressText extends StatefulWidget {
  // cache على مستوى الـ class — يبقى طول عمر الـ app
  static final Map<String, String> _cache = {};

  static String _cacheKey(double lat, double lng) =>
      '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

  static String _clean(String a) =>
      a.replaceFirst(RegExp(r'^[0-9A-Z]{4,8}\+[0-9A-Z]{2,3}[,،\.\s]*', caseSensitive: false), '').trim();

  // أقل مسافة (متر) تستدعي جلب عنوان جديد. تحت هذه المسافة نُبقي العنوان المعروض:
  // العنوان لا يتغيّر فعليًا خلال 200م، وكل جلب جديد استدعاء مدفوع.
  static const double _minMoveMeters = 200;

  static double _metersBetween(double aLat, double aLng, double bLat, double bLng) {
    const rad = math.pi / 180, earth = 6371000.0;
    final dLat = (bLat - aLat) * rad, dLng = (bLng - aLng) * rad;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(aLat * rad) * math.cos(bLat * rad) *
            math.sin(dLng / 2) * math.sin(dLng / 2);
    return earth * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  final double lat, lng;
  final TextStyle? style;
  const _AsyncAddressText({super.key, required this.lat, required this.lng, this.style});
  @override
  State<_AsyncAddressText> createState() => _AsyncAddressTextState();
}

class _AsyncAddressTextState extends State<_AsyncAddressText> {
  late String _text;
  String _key = '';
  // النقطة التي يخصّها العنوان المعروض — أساس قياس مسافة الحركة
  double? _shownLat, _shownLng;

  @override
  void initState() {
    super.initState();
    _key = _AsyncAddressText._cacheKey(widget.lat, widget.lng);
    _applyKey();
  }

  // الجهاز اتحرك (إحداثيات جديدة) → أعد جلب العنوان (كان بيفضل على القديم/الإحداثيات)
  @override
  void didUpdateWidget(covariant _AsyncAddressText old) {
    super.didUpdateWidget(old);
    final nk = _AsyncAddressText._cacheKey(widget.lat, widget.lng);
    if (nk == _key) return;

    // العنوان محفوظ محليًا للنقطة الجديدة → استخدمه فورًا (بلا استدعاء)
    if (_AsyncAddressText._cache.containsKey(nk)) {
      _key = nk;
      setState(() {
        _text = _AsyncAddressText._cache[nk]!;
        _shownLat = widget.lat;
        _shownLng = widget.lng;
      });
      return;
    }

    // حركة أقل من 200م ولدينا عنوان معروض → أبقِه بدل استدعاء مدفوع جديد
    if (_shownLat != null &&
        _AsyncAddressText._metersBetween(
                _shownLat!, _shownLng!, widget.lat, widget.lng) <
            _AsyncAddressText._minMoveMeters) {
      _key = nk;
      return;
    }

    _key = nk;
    setState(_applyKey);
  }

  void _applyKey() {
    if (_AsyncAddressText._cache.containsKey(_key)) {
      _text = _AsyncAddressText._cache[_key]!;
      _shownLat = widget.lat;
      _shownLng = widget.lng;
    } else {
      _text = '${widget.lat.toStringAsFixed(4)}, ${widget.lng.toStringAsFixed(4)}';
      _fetch(_key, widget.lat, widget.lng);
    }
  }

  Future<void> _fetch(String k, double lat, double lng, [int attempt = 0]) async {
    try {
      final r = await ApiService.request('reverse_geocode', {'lat': lat, 'lng': lng, 'lang': I18n.lang});
      final raw = (r['address'] ?? '').toString().trim();
      if (raw.isEmpty) throw Exception('empty');
      final cleaned = _AsyncAddressText._clean(raw);
      final display = cleaned.isNotEmpty ? cleaned : raw;
      _AsyncAddressText._cache[k] = display;
      if (mounted && _key == k) {
        setState(() {
          _text = display;
          _shownLat = lat;
          _shownLng = lng;
        });
      }
    } catch (_) {
      // فشل عابر (rate-limit جيوكودر/شبكة) → أعد المحاولة بدل ترك الإحداثيات للأبد
      if (attempt < 3 && mounted && _key == k) {
        await Future.delayed(Duration(seconds: 2 + attempt * 3));
        if (mounted && _key == k) return _fetch(k, lat, lng, attempt + 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Text(_text, style: widget.style, overflow: TextOverflow.ellipsis);
}
