import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../services/i18n.dart';
import '../services/notification_state.dart';
import '../models/models.dart';
import 'sessions_screen.dart';
import 'map_screen.dart';
import 'auto_engine_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../widgets/model_picker.dart';

// ترتيب طبيعي لأسماء الأجهزة: أرقام رقميًا (121 قبل 130 قبل 301)، حروف أبجديًا،
// ومختلط طبيعيًا (car5 قبل car12). يقسّم الاسم لأجزاء رقمية/نصية ويقارنها.
List<String> _natChunks(String s) =>
    RegExp(r'\d+|\D+').allMatches(s.toLowerCase()).map((m) => m.group(0)!).toList();

int naturalCompare(String a, String b) {
  final ra = _natChunks(a.trim());
  final rb = _natChunks(b.trim());
  final n = ra.length < rb.length ? ra.length : rb.length;
  for (int i = 0; i < n; i++) {
    final na = int.tryParse(ra[i]);
    final nb = int.tryParse(rb[i]);
    int cmp;
    if (na != null && nb != null) {
      cmp = na.compareTo(nb);
    } else {
      cmp = ra[i].compareTo(rb[i]);
    }
    if (cmp != 0) return cmp;
  }
  return ra.length.compareTo(rb.length);
}

// ============================================================
// DevicesScreen
// ============================================================

class DevicesScreen extends StatefulWidget {
  final String searchQuery;
  const DevicesScreen({super.key, this.searchQuery = ''});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String _localSearch = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
        context.read<AppProvider>().loadDevices());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final q = (_localSearch.isNotEmpty ? _localSearch : widget.searchQuery).toLowerCase();
    final devices = q.isEmpty ? provider.filteredDevices : provider.filteredDevices.where((d) =>
      d.name.toLowerCase().contains(q) || d.imei.toLowerCase().contains(q) ||
      (d.userName?.toLowerCase().contains(q) ?? false)).toList();
    return Column(
      children: [
        _FilterTabs(
          tabs: [_Tab('all', tr('filter_all')), _Tab('on', tr('filter_online')), _Tab('moving', tr('dash_moving')), _Tab('off', tr('filter_offline'))],
          current: provider.deviceFilter,
          onTap: provider.setDeviceFilter,
          counts: {
            'all': provider.tabDevices.length,
            'on': provider.tabDevices.where((d) => d.isOnline).length,
            'moving': provider.tabDevices.where((d) => d.isMoving).length,
            'off': provider.tabDevices.where((d) => d.isOffline || d.isInactive).length,
          },
        ),
        Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: _SearchField(hint: tr('search_device'), onChanged: (v) => setState(() => _localSearch = v))),
        Expanded(
          child: provider.devicesLoading && provider.devices.isEmpty
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
              : devices.isEmpty
                  ? Center(child: Text(tr('no_devices'), style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo')))
                  : RefreshIndicator(
                      color: const Color(0xFFC41E3A),
                      onRefresh: provider.loadDevices,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: devices.length,
                        itemBuilder: (_, i) => _DeviceRow(device: devices[i]),
                      ),
                    ),
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceModel device;
  const _DeviceRow({required this.device});

  @override
  Widget build(BuildContext context) {
    final dotColor = device.isMoving ? const Color(0xFF166534)
        : device.isInactive ? const Color(0xFFF59E0B)
        : device.isOnline ? const Color(0xFF1E40AF) : const Color(0xFFEF5350);
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _EditDeviceSheet(device: device, onSaved: () {}),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Row(
          children: [
            Container(width: 34, height: 34,
              decoration: BoxDecoration(color: dotColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.directions_car_outlined, color: dotColor, size: 16)),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo')),
              Text(device.isMoving ? '${tr('moving')} - ${device.speedKmh}' : '${device.statusAr}${_timeAgo(device.lastUpdate)}',
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
            ])),
            Container(width: 8, height: 8, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ClientsScreen
// ============================================================

class ClientsScreen extends StatefulWidget {
  final String searchQuery;
  const ClientsScreen({super.key, this.searchQuery = ''});
  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  String _localSearch = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
        context.read<AppProvider>().loadUsers());
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final user = provider.currentUser;
    final q = (_localSearch.isNotEmpty ? _localSearch : widget.searchQuery).toLowerCase();
    final allUsers = q.isEmpty ? provider.users : provider.users.where((u) =>
      u.fullName.toLowerCase().contains(q) || u.username.toLowerCase().contains(q) ||
      (u.phone?.toLowerCase().contains(q) ?? false)).toList();
    final filter = provider.clientFilter;

    // Build hierarchical list
    final dealers = allUsers.where((u) => u.isDealer).toList();
    final subDealers = allUsers.where((u) => u.isSubDealer).toList();
    final clients = allUsers.where((u) => u.isClient).toList();

    // flat list with hierarchy markers
    final List<_HierarchyItem> items = [];
    if (filter == 'all' || filter == 'dealer') {
      if (user?.isAdmin == true) {
        // أدمن: تسلسل هرمي كامل
        for (final dealer in dealers) {
          items.add(_HierarchyItem(user: dealer, level: 0));
          if (filter == 'all') {
            final subs = subDealers.where((s) => s.dealerId == dealer.id).toList();
            final subDealerIds = subs.map((s) => s.id).toSet();
            for (final sub in subs) {
              items.add(_HierarchyItem(user: sub, level: 1));
              final subClients = clients.where((c) => c.parentId == sub.id).toList();
              for (final cl in subClients) { items.add(_HierarchyItem(user: cl, level: 2)); }
            }
            final directClients = clients.where((c) =>
              c.dealerId == dealer.id &&
              (c.parentId == null || c.parentId == dealer.id || !subDealerIds.contains(c.parentId))
            ).toList();
            for (final cl in directClients) { items.add(_HierarchyItem(user: cl, level: 1)); }
          }
        }
        // حسابات مضافة تحت الأدمن مباشرة (بدون ديلر) — مالهاش مكان في الهرم فتُضاف هنا
        if (filter == 'all') {
          final addedIds = items.map((it) => it.user.id).toSet();
          for (final u in [...subDealers, ...clients]) {
            if (!addedIds.contains(u.id)) items.add(_HierarchyItem(user: u, level: 0));
          }
        }
      } else if (filter == 'all') {
        // ديلر/موزع: موزع ثم عملاؤه تحته، ثم العملاء المباشرون
        final subDealerIds = subDealers.map((s) => s.id).toSet();
        for (final sub in subDealers) {
          items.add(_HierarchyItem(user: sub, level: 0));
          final subClients = clients.where((c) => c.parentId == sub.id).toList();
          for (final cl in subClients) { items.add(_HierarchyItem(user: cl, level: 1)); }
        }
        final directClients = clients.where((c) =>
          c.parentId == null || !subDealerIds.contains(c.parentId)
        ).toList();
        for (final cl in directClients) { items.add(_HierarchyItem(user: cl, level: 0)); }
      }
    }
    if (filter == 'sub') {
      for (final sub in subDealers) {
        items.add(_HierarchyItem(user: sub, level: 0));
      }
    }
    if (filter == 'client') {
      for (final cl in clients) {
        items.add(_HierarchyItem(user: cl, level: 0));
      }
    }

    final tabs = user?.isAdmin == true
        ? [_Tab('all', tr('filter_all')), _Tab('dealer', tr('tab_dealer')), _Tab('sub', tr('tab_subdealer')), _Tab('client', tr('tab_client'))]
        : [_Tab('all', tr('filter_all')), _Tab('sub', tr('tab_subdealer')), _Tab('client', tr('tab_client'))];
    final counts = {
      'all': allUsers.length,
      'dealer': dealers.length,
      'sub': subDealers.length,
      'client': clients.length,
    };

    return Column(
      children: [
        _FilterTabs(tabs: tabs, current: filter, onTap: provider.setClientFilter, counts: counts),
        Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: _SearchField(hint: tr('search_client'), onChanged: (v) => setState(() => _localSearch = v))),
        Expanded(
          child: provider.usersLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
              : items.isEmpty
                  ? Center(child: Text(tr('no_clients'), style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo')))
                  : RefreshIndicator(
                      color: const Color(0xFFC41E3A),
                      onRefresh: provider.loadUsers,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _HierarchyRow(
                          item: items[i],
                          onTap: () => _showProfile(context, items[i].user),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  void _showProfile(BuildContext context, UserModel user) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => _UserProfilePage(user: user)),
    );
  }
}

// ============================================================
// User Profile Bottom Sheet
// ============================================================

class _UserProfileSheet extends StatefulWidget {
  final UserModel user;
  const _UserProfileSheet({required this.user});
  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

// Full-screen wrapper for nested navigation
class _UserProfilePage extends StatelessWidget {
  final UserModel user;
  const _UserProfilePage({required this.user});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 0, // hidden - back button inside red header
      ),
      body: LayoutBuilder(
        builder: (ctx, constraints) => _UserProfileSheet(user: user),
      ),
    );
  }
}

// نقطة دخول عامة لفتح بروفايل (داشبورد) عميل من أي شاشة (مثل بحث الداشبورد)
void openUserProfile(BuildContext context, UserModel user) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => _UserProfilePage(user: user)),
  );
}

class _UserProfileSheetState extends State<_UserProfileSheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _avatarOverride; // الصورة الجديدة بعد الرفع (الموديل المخزّن بيفضل على الرابط القديم)
  List<DeviceModel> _devices = [];
  List<UserModel> _subUsers = [];
  Map<String, int>? _cardBalance;
  bool _loadingDevices = false;
  bool _loadingUsers = false;
  bool _isAdmin = false;
  Map<String, dynamic> _settings = {};
  List<UserModel> _allUsers = [];

  @override
  void initState() {
    super.initState();
    // tabs: devices + sub(dealer/sub_dealer only) + info
    final tabCount = widget.user.isDealer || widget.user.isSubDealer ? 3 : 2;
    _tabController = TabController(length: tabCount, vsync: this);
    _loadDevices();
    if (widget.user.isDealer || widget.user.isSubDealer) {
      _loadSubUsers();
    }
    if (widget.user.isDealer || widget.user.isSubDealer) {
      _loadCardBalance();
    }
    // Detect admin + load users for transfer
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<AppProvider>();
      _isAdmin = provider.currentUser?.accountType == 'admin';
      _allUsers = provider.users;
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadDevices() async {
    if (_devices.isEmpty) {
      final providerDevices = context.read<AppProvider>().devices
          .where((d) => d.userId == widget.user.id).toList();
      if (providerDevices.isNotEmpty) {
        providerDevices.sort((a, b) => naturalCompare(a.name, b.name));
        setState(() => _devices = providerDevices);
      }
    }
    setState(() => _loadingDevices = true);
    try {
      final result = await ApiService.getDevices(viewAs: widget.user.id);
      // ⚠️ حدّث بس لو الاستدعاء نجح (رجّع List). لو فشل (نت/timeout) → raw=null →
      // سيب القايمة زي ما هي (كان بيمسحها → «لا توجد أجهزة» ويحتاج restart).
      final raw = result is List ? result
          : (result['data'] ?? result['devices'] ?? result['items']);
      if (raw is List) {
        final list = raw.map((d) => DeviceModel.fromJson(d as Map<String, dynamic>)).toList();
        list.sort((a, b) => naturalCompare(a.name, b.name)); // ترتيب طبيعي بالاسم
        _devices = list;
      }
    } catch (_) { /* فشل مؤقت → ماتمسحش القايمة الموجودة */ }
    if (mounted) setState(() => _loadingDevices = false);
  }

  // أجهزة الإحصائيات (العدّ + متصل/غير متصل) في هيدر البروفايل:
  // للديلر/الموزع = كل شجرة الحساب (المخزون + أجهزة كل العملاء تحته)، مطابق للويب.
  // للعميل = أجهزته فقط. القائمة تحت (تاب الأجهزة) تفضل المخزون المباشر (_devices).
  List<DeviceModel> get _statDevices {
    final u = widget.user;
    if (!(u.isDealer || u.isSubDealer)) return _devices;
    final provider = context.read<AppProvider>();
    final did = u.id;
    final ids = <int>{did};
    for (final x in provider.users) { if (x.dealerId == did || x.parentId == did) ids.add(x.id); }
    for (final x in provider.users) { if (x.parentId != null && ids.contains(x.parentId)) ids.add(x.id); }
    final all = <int, DeviceModel>{};
    for (final d in [...provider.devices, ...provider.inventory]) {
      if (d.userId != null && ids.contains(d.userId)) all[d.id] = d;
    }
    final list = all.values.toList();
    return list.isNotEmpty ? list : _devices; // fallback لو داتا الشجرة مش متاحة (viewer مش أدمن)
  }

  Future<void> _loadSubUsers() async {
    setState(() => _loadingUsers = true);
    try {
      final provider = context.read<AppProvider>();
      final allUsers = provider.users;
      if (widget.user.isSubDealer) {
        // الموزع: العملاء اللي parent_id بتاعهم = id الموزع
        _subUsers = allUsers.where((u) => u.parentId == widget.user.id).toList();
      } else {
        // الديلر: كل المستخدمين اللي dealer_id بتاعهم = id الديلر
        _subUsers = allUsers.where((u) => u.dealerId == widget.user.id).toList();
      }
    } catch (_) {
      _subUsers = [];
    }
    if (mounted) setState(() => _loadingUsers = false);
  }

  Future<void> _loadCardBalance() async {
    try {
      // get_card_balance with userId for admin viewing dealer balance
      final result = await ApiService.getCardBalance(userId: widget.user.id);
      if (result['success'] == true && result['balance'] != null) {
        final b = result['balance'] as Map<String, dynamic>;
        if (mounted) setState(() => _cardBalance = {
          'new_yearly': int.tryParse(b['new_yearly']?.toString() ?? '0') ?? 0,
          'new_lifetime': int.tryParse(b['new_lifetime']?.toString() ?? '0') ?? 0,
          'renew_yearly': int.tryParse(b['renew_yearly']?.toString() ?? '0') ?? 0,
          'renew_lifetime': int.tryParse(b['renew_lifetime']?.toString() ?? '0') ?? 0,
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final badgeColor = u.isDealer ? const Color(0xFFC41E3A)
        : u.isSubDealer ? const Color(0xFF7C3AED) : const Color(0xFF1565C0);
    final badgeLabel = u.isDealer ? tr('tab_dealer') : u.isSubDealer ? tr('tab_subdealer') : tr('tab_client');
    final tabs = [
      Tab(text: tr('cl_tab_devices')),
      if (u.isDealer || u.isSubDealer) Tab(text: tr('cl_tab_subacc')),
      Tab(text: tr('cl_tab_info')),
    ];

    return DraggableScrollableSheet(
      initialChildSize: 1.0,
      minChildSize: 0.6,
      maxChildSize: 1.0,
      expand: false,
      builder: (_, scrollController) => SizedBox.expand(
        child: Column(
        children: [
          // White padding at top + red card
          Container(
            color: Theme.of(context).colorScheme.surface,
            padding: EdgeInsets.fromLTRB(12, MediaQuery.of(context).padding.top + 6, 12, 0),
            child: Container(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFC41E3A), Color(0xFF8A0F22)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: const Color(0xFFC41E3A).withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Column(
              children: [
                // Handle bar + back button row
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, size: 18, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const Spacer(),
                    Center(child: Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.4), borderRadius: BorderRadius.circular(2)),
                    )),
                    const Spacer(),
                    const SizedBox(width: 32), // balance
                  ]),
                ),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => _changeUserAvatar(context, u),
                      child: Stack(children: [
                        _UserAvatar(
                          avatarUrl: _avatarOverride ?? u.avatarUrl,
                          initials: u.initials,
                          radius: 22,
                          bgColor: Colors.white.withOpacity(0.2),
                        ),
                        Positioned(bottom: 0, right: 0, child: Container(
                          width: 14, height: 14,
                          decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt, size: 9, color: Colors.white),
                        )),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(u.fullName, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(child: Text(u.username, style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 11, fontFamily: 'Cairo'), overflow: TextOverflow.ellipsis)),
                          if (u.username.trim().isNotEmpty)
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: u.username.trim()));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(tr('sp_copied'), style: const TextStyle(fontFamily: 'Cairo')),
                                  backgroundColor: const Color(0xFF6BA539),
                                  duration: const Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ));
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: const Padding(
                                padding: EdgeInsets.only(right: 6, left: 6, top: 2, bottom: 2),
                                child: Icon(Icons.copy, size: 14, color: Color(0xCCFFFFFF)),
                              ),
                            ),
                        ]),
                      ]),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
                      child: Text(badgeLabel, style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Cairo')),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(children: [
                  _HeaderStatTile(icon: Icons.directions_car_outlined, label: tr('cl_devices'), value: (u.isDealer || u.isSubDealer) ? _statDevices.length : (_loadingDevices ? u.deviceCount : _devices.length), color: const Color(0xFF6BA539), bg: const Color(0x336BA539)),
                  const SizedBox(width: 6),
                  _HeaderStatTile(icon: Icons.people_outline, label: tr('cl_clients'), value: u.clientCount, color: const Color(0xFF2196F3), bg: const Color(0x332196F3)),
                  if (_statDevices.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _HeaderStatTile(icon: Icons.wifi_outlined, label: tr('cl_online'), value: _statDevices.where((d) => d.isOnline || d.isMoving).length, color: const Color(0xFF4CAF50), bg: const Color(0x334CAF50)),
                    const SizedBox(width: 6),
                    _HeaderStatTile(icon: Icons.wifi_off_outlined, label: tr('cl_offline'), value: _statDevices.where((d) => d.isOffline).length, color: const Color(0xFFEF5350), bg: const Color(0x33EF5350)),
                  ],
                ]),
                if ((u.isDealer || u.isSubDealer) && _cardBalance != null) ...[ 
                  const SizedBox(height: 8),
                  Row(children: [
                    _ProfileBalTile(icon: Icons.credit_card_outlined, label: tr('cl_new_yearly'), value: _cardBalance!['new_yearly'] ?? 0, color: const Color(0xFF2196F3), bg: const Color(0xFFE3F2FD)),
                    const SizedBox(width: 6),
                    _ProfileBalTile(icon: Icons.all_inclusive_outlined, label: tr('cl_new_life'), value: _cardBalance!['new_lifetime'] ?? 0, color: const Color(0xFF7C3AED), bg: const Color(0xFFF3E8FF)),
                    const SizedBox(width: 6),
                    _ProfileBalTile(icon: Icons.autorenew_outlined, label: tr('cl_renew_yearly'), value: _cardBalance!['renew_yearly'] ?? 0, color: const Color(0xFF059669), bg: const Color(0xFFDCFCE7)),
                    const SizedBox(width: 6),
                    _ProfileBalTile(icon: Icons.loop_outlined, label: tr('cl_renew_life'), value: _cardBalance!['renew_lifetime'] ?? 0, color: const Color(0xFFD97706), bg: const Color(0xFFFEF3C7)),
                    if (_isAdmin) ...[ 
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _editCardBalance(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: const Color(0xFFF59E0B).withOpacity(0.2), borderRadius: BorderRadius.circular(6)),
                          child: const Icon(Icons.edit, size: 14, color: Color(0xFFF59E0B)),
                        ),
                      ),
                    ],
                  ]),
                ],
              ],
            ),
            ), // close red card Container
          ), // close white padding Container
          // Action buttons
          Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8, runSpacing: 8,
                children: [
                _ActionBtn(icon: Icons.message_outlined, label: tr('cl_act_msg'), color: const Color(0xFFC41E3A), onTap: () => _openMessages(context)),
                _ActionBtn(icon: Icons.edit_outlined, label: tr('cl_act_edit'), color: const Color(0xFF1565C0), onTap: () => _editUser(context)),
                _ActionBtn(icon: Icons.add_to_queue_outlined, label: tr('cl_act_device'), color: const Color(0xFF6BA539), onTap: () => _addDevice(context)),
                _ActionBtn(icon: Icons.lock_reset_outlined, label: tr('cl_act_password'), color: const Color(0xFFF59E0B), onTap: () => _resetPassword(context)),
                _ActionBtn(icon: Icons.settings_outlined, label: tr('cl_act_settings'), color: const Color(0xFF6B7280), onTap: () => _openSettings(context)),
                _ActionBtn(icon: Icons.schedule_outlined, label: tr('ae_title'), color: const Color(0xFFEF6C00), onTap: () => openAutoEngine(context, widget.user.id, subtitle: widget.user.fullName)),
                _ActionBtn(icon: Icons.swap_horiz_outlined, label: tr('cl_act_transfer'), color: const Color(0xFF7C3AED), onTap: () => _transferAccount(context)),
                _ActionBtn(icon: Icons.delete_outline, label: tr('cl_act_delete'), color: const Color(0xFFEF5350), onTap: () => _deleteAccount(context)),
                // زر الخريطة ثابت دايمًا (اتساق) — يفتح خريطة العميل/الديلر حتى لو مفيش أجهزة دلوقتي
                _ActionBtn(icon: Icons.map_outlined, label: tr('cl_act_map'), color: const Color(0xFF0891B2), onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => Material(child: MapScreen(initialDevices: _devices, viewAsUserId: widget.user.id))))),
                // إضافة حساب تحت هذا الحساب — يظهر فقط للمزوّد وفوق حساب يقبل حسابات فرعية
                if (_canAddUnder) _ActionBtn(icon: Icons.person_add_alt_1_outlined, label: tr('cl_act_add_user'), color: const Color(0xFF0D9488), onTap: () => _addUserUnder(context)),
                // مفتاح ربط لنظام العميل (تطبيق مدرسة، ERP…) — قراءة المواقع فقط.
                // للأدمن وحده: الميزة تُباع لعميل نهائي فلا تُترك بيد الوكيل بلا اتفاق.
                if (context.read<AppProvider>().currentUser?.accountType == 'admin')
                  _ActionBtn(icon: Icons.vpn_key_outlined, label: tr('cl_act_apikey'), color: const Color(0xFF475569), onTap: () => _apiKeyDialog(context)),
                // أجهزة العميل الداخلة — المزوّد يتصرّف نيابةً عنه حين يفقد هاتفًا
                _ActionBtn(icon: Icons.devices_outlined, label: tr('ses_title'), color: const Color(0xFF0D9488),
                    onTap: () => openSessions(context, userId: widget.user.id, subtitle: widget.user.fullName)),
              ],
            ),
          ),
          // Tabs
          Container(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              controller: _tabController,
              labelColor: const Color(0xFFC41E3A),
              unselectedLabelColor: const Color(0xFF8892A4),
              indicatorColor: const Color(0xFFC41E3A),
              labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w500),
              tabs: tabs,
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // Devices tab — لو فيه أجهزة optimistic (من provider) نعرضها فورًا
                // بدل السبنر؛ السبنر يظهر فقط لو مفيش أي بيانات لسه.
                (_loadingDevices && _devices.isEmpty)
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                    : _devices.isEmpty
                        ? Center(child: Text(tr('cl_no_devices'), style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo')))
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: _devices.length,
                            itemBuilder: (_, i) => _DeviceProfileRow(
                              device: _devices[i],
                              isAdmin: _isAdmin,
                              onEdit: () => _editDevice(context, _devices[i]),
                              onDelete: () => _deleteDevice(context, _devices[i]),
                              onTransfer: () => _transferDevice(context, _devices[i]),
                            ),
                          ),
                // Sub users tab (dealer/sub_dealer only)
                if (u.isDealer || u.isSubDealer)
                  _loadingUsers
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                      : _subUsers.isEmpty
                          ? Center(child: Text(tr('cl_no_subacc'), style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo')))
                          : ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: _subUsers.length,
                              itemBuilder: (_, i) => _SubUserRow(user: _subUsers[i]),
                            ),

                // Info tab
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _InfoCard(items: [
                        _InfoItem(label: tr('cl_username'), value: u.username, copyable: true),
                        _InfoItem(label: tr('cl_acc_type'), value: u.accountTypeAr),
                        _InfoItem(label: tr('cl_phone'), value: u.phone ?? '-'),
                        _InfoItem(label: tr('cl_mobile'), value: u.mobile ?? '-'),
                        _InfoItem(label: tr('cl_email'), value: u.email ?? '-'),
                        _InfoItem(label: tr('cl_address'), value: u.address ?? '-'),
                        _InfoItem(label: tr('cl_created'), value: u.createdAt != null ? '${u.createdAt!.year}-${u.createdAt!.month.toString().padLeft(2, '0')}-${u.createdAt!.day.toString().padLeft(2, '0')}' : '-', isLast: true),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _changeUserAvatar(BuildContext context, UserModel u) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
        if ((_avatarOverride ?? u.avatarUrl) != null)
          ListTile(leading: const Icon(Icons.image_outlined, color: Color(0xFF1565C0)), title: Text(tr('cl_view_photo'), style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () { Navigator.pop(ctx); showDialog(context: context, builder: (d) => Dialog(backgroundColor: Colors.transparent, child: GestureDetector(onTap: () => Navigator.pop(d), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.network((_avatarOverride ?? u.avatarUrl)!))))); }),
        ListTile(leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFFC41E3A)), title: Text(tr('cl_change_photo'), style: const TextStyle(fontFamily: 'Cairo')),
          onTap: () async {
            Navigator.pop(ctx);
            final picker = ImagePicker();
            final image = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 85);
            if (image == null || !mounted) return;
            try {
              final bytes = await image.readAsBytes();
              final r = await ApiService.request('upload_avatar', {'image': base64Encode(bytes), 'ext': image.path.split('.').last.toLowerCase(), 'userId': u.id});
              if (u.avatarUrl != null) NetworkImage(u.avatarUrl!).evict();
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();
              if (mounted) {
                setState(() {
                  // اعرض الرابط الجديد (بـ ?v= الجديدة) فوراً — الموديل المخزّن رابطه قديم
                  if (r['success'] == true && r['avatar'] != null) {
                    _avatarOverride = 'https://himaya-track.com${r['avatar']}';
                  }
                });
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['success']==true?tr('cl_photo_changed'):r['error']??tr('cl_fail'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: r['success']==true?const Color(0xFF6BA539):const Color(0xFFC41E3A)));
                // حدّث قائمة العملاء في الخلفية عشان الرابط الجديد يوصل للّيستة كمان
                if (r['success'] == true) context.read<AppProvider>().loadUsers();
              }
            } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('err_prefix')}: $e', style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A))); }
          }),
        const SizedBox(height: 8),
      ])),
    );
  }

  void _openMessages(BuildContext context) {
    final sendCtrl = TextEditingController();
    List<Map<String, dynamic>> msgs = [];
    bool loading = true, sending = false, started = false;

    Future<void> loadMsgs(StateSetter setS, [int attempt = 0]) async {
      setS(() => loading = true);
      try {
        // جيب الوارد + المُرسَل عشان تظهر رسائلي أنا كمان في الشات
        final inb = await ApiService.request('get_messages', {'box': 'inbox'});
        final snt = await ApiService.request('get_messages', {'box': 'sent'});
        final uid = widget.user.id.toString();
        final me = context.read<AppProvider>().currentUser?.id.toString();
        final all = <Map<String, dynamic>>[
          ...((inb['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
          ...((snt['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
        ];
        // خُد بس المحادثة بيني وبين العميل ده + إزالة التكرار بالـ id
        final seen = <String>{};
        final conv = <Map<String, dynamic>>[];
        for (final m in all) {
          final sid = m['sender_id']?.toString();
          final rid = m['receiver_id']?.toString();
          if (!((sid == uid && rid == me) || (sid == me && rid == uid))) continue;
          final k = (m['id'] ?? '${m['sender_id']}_${m['receiver_id']}_${m['created_at']}').toString();
          if (seen.add(k)) conv.add(m);
        }
        conv.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
        setS(() { msgs = conv.reversed.toList(); loading = false; });
      } catch (_) {
        if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return loadMsgs(setS, attempt + 1); }
        setS(() => loading = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!started) { started = true; WidgetsBinding.instance.addPostFrameCallback((_) => loadMsgs(setS)); }
        return DraggableScrollableSheet(
          initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
          builder: (_, sc) => Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(16,0,16,8), child: Row(children: [
                _UserAvatar(avatarUrl: widget.user.avatar, initials: widget.user.initials, radius: 16, bgColor: const Color(0xFFC41E3A)),
                const SizedBox(width: 10),
                Expanded(child: Text(tr('cl_msgs_title', {'name': widget.user.fullName}), style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ])),
              const Divider(height: 1),
              Expanded(child: loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                  : msgs.isEmpty
                      ? Center(child: Text(tr('cl_no_prev_msgs'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                      : ListView.builder(
                          controller: sc,
                          padding: const EdgeInsets.all(12),
                          reverse: true,
                          itemCount: msgs.length,
                          itemBuilder: (_, i) {
                            final m = msgs[i];
                            final isMe = m['sender_id']?.toString() == context.read<AppProvider>().currentUser?.id.toString();
                            return Align(
                              alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.75),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFFC41E3A) : Theme.of(context).scaffoldBackgroundColor,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(12), topRight: const Radius.circular(12),
                                    bottomLeft: Radius.circular(isMe ? 0 : 12), bottomRight: Radius.circular(isMe ? 12 : 0),
                                  ),
                                ),
                                child: Text(m['body'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface)),
                              ),
                            );
                          },
                        )),
              Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + MediaQuery.of(ctx).viewInsets.bottom),
                child: Row(children: [
                  Expanded(child: TextField(
                    controller: sendCtrl,
                    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: tr('cl_write_msg'), hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                      filled: true, fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  )),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: sending ? null : () async {
                      if (sendCtrl.text.trim().isEmpty) return;
                      setS(() => sending = true);
                      await ApiService.request('send_message', {
                        'receiver_id': widget.user.id,
                        'body': sendCtrl.text.trim(),
                      });
                      sendCtrl.clear();
                      setS(() => sending = false);
                      loadMsgs(setS);
                    },
                    child: Container(
                      width: 40, height: 40,
                      decoration: const BoxDecoration(color: Color(0xFFC41E3A), shape: BoxShape.circle),
                      child: sending
                          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)))
                          : const Icon(Icons.send, color: Colors.white, size: 18),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        );
      }),
    );
  }

  void _editUser(BuildContext context) {
    final nameCtrl = TextEditingController(text: widget.user.fullName);
    final phoneCtrl = TextEditingController(text: widget.user.phone ?? '');
    final mobileCtrl = TextEditingController(text: widget.user.mobile ?? '');
    final emailCtrl = TextEditingController(text: widget.user.email ?? '');
    final addressCtrl = TextEditingController(text: widget.user.address ?? '');
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(tr('cl_edit_title', {'name': widget.user.fullName}), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ]),
                const SizedBox(height: 12),
                TextField(controller: nameCtrl, textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr, decoration: InputDecoration(labelText: tr('cl_full_name'))),
                const SizedBox(height: 10),
                TextField(controller: phoneCtrl, decoration: InputDecoration(labelText: tr('cl_phone')), keyboardType: TextInputType.phone),
                const SizedBox(height: 10),
                TextField(controller: mobileCtrl, decoration: InputDecoration(labelText: tr('cl_mobile')), keyboardType: TextInputType.phone),
                const SizedBox(height: 10),
                TextField(controller: emailCtrl, decoration: InputDecoration(labelText: tr('cl_email')), keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 10),
                TextField(controller: addressCtrl, textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr, decoration: InputDecoration(labelText: tr('cl_address'))),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: saving ? null : () async {
                      setS(() => saving = true);
                      final result = await context.read<AppProvider>().updateUser(
                        userId: widget.user.id,
                        updates: {
                          'full_name': nameCtrl.text.trim(),
                          'phone': phoneCtrl.text.trim(),
                          'mobile': mobileCtrl.text.trim(),
                          'email': emailCtrl.text.trim(),
                          'address': addressCtrl.text.trim(),
                        },
                      );
                      setS(() => saving = false);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(result['success'] == true ? tr('cl_saved') : result['error'] ?? tr('cl_fail'), style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: result['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                        ));
                      }
                    },
                    child: saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(tr('save'), style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // أنواع الحسابات التي يجوز إنشاؤها تحت الحساب المعروض:
  // تقاطع ما يسمح به دور المُشاهد مع ما يقبله الحساب المعروض تحته.
  // العميل لا حسابات تحته، فلا يظهر الزر أصلًا.
  List<String> get _addableTypes {
    final viewer = context.read<AppProvider>().currentUser?.accountType;
    if (viewer == null || viewer == 'client') return const [];
    const byViewer = {
      'admin':      ['dealer', 'sub_dealer', 'client'],
      'dealer':     ['sub_dealer', 'client'],
      'sub_dealer': ['client'],
    };
    const underTarget = {
      'dealer':     ['sub_dealer', 'client'],
      'sub_dealer': ['client'],
    };
    final a = byViewer[viewer] ?? const [];
    final b = underTarget[widget.user.accountType] ?? const [];
    return a.where(b.contains).toList();
  }

  bool get _canAddUnder => _addableTypes.isNotEmpty;

  // مفتاح يقرأ به نظامُ العميل مواقع أجهزته وحدها — لا أوامر ولا كتابة.
  // منفصل عن توكن الحساب عمدًا: التوكن يملك إيقاف المحرك، وتسريبه من خادم
  // طرف ثالث يعني أن أحدًا قد يوقف مركبة.
  void _apiKeyDialog(BuildContext context) {
    String? key;
    bool busy = true;
    const cairo = TextStyle(fontFamily: 'Cairo');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> call(String action) async {
          setS(() => busy = true);
          final r = await ApiService.request(action, {'user_id': widget.user.id});
          if (!ctx.mounted) return;
          setS(() {
            busy = false;
            if (r['success'] == true) key = r['api_key']?.toString();
          });
        }

        if (busy && key == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted && busy) call('get_api_key');
          });
        }

        return AlertDialog(
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          title: Text(tr('cl_apikey_title'), style: cairo.copyWith(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(tr('cl_apikey_hint'), style: cairo.copyWith(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 14),
              if (busy)
                const Padding(padding: EdgeInsets.all(18), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
              else if (key == null || key!.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(.12), borderRadius: BorderRadius.circular(8)),
                  child: Text(tr('cl_apikey_none'), style: cairo.copyWith(fontSize: 13)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF0D9488).withOpacity(.4)),
                  ),
                  child: Row(children: [
                    Expanded(child: SelectableText(key!,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                        textDirection: TextDirection.ltr)),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: tr('cl_apikey_copied'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: key!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr('cl_apikey_copied'), style: cairo)),
                        );
                      },
                    ),
                  ]),
                ),
              if (!busy && key != null && key!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(tr('cl_apikey_warn'),
                    style: cairo.copyWith(fontSize: 11, color: const Color(0xFFF59E0B))),
              ],
            ]),
          ),
          actions: [
            if (!busy && key != null && key!.isNotEmpty)
              TextButton(
                onPressed: () => call('revoke_api_key'),
                child: Text(tr('cl_apikey_revoke'),
                    style: cairo.copyWith(color: const Color(0xFFEF5350))),
              ),
            TextButton(
              onPressed: busy ? null : () => call('generate_api_key'),
              child: Text(key == null || key!.isEmpty ? tr('cl_apikey_gen') : tr('cl_apikey_regen'),
                  style: cairo.copyWith(color: const Color(0xFF0D9488), fontWeight: FontWeight.bold)),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('close'), style: cairo)),
          ],
        );
      }),
    );
  }

  void _addUserUnder(BuildContext context) {
    final types = _addableTypes;
    if (types.isEmpty) return;
    final userCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    final pw2Ctrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String type = types.last;   // الأكثر شيوعًا: عميل
    bool busy = false;
    String? err;
    const cairo = TextStyle(fontFamily: 'Cairo');

    String label(String t) => t == 'dealer'
        ? tr('dash_dealer')
        : (t == 'sub_dealer' ? tr('dash_sub_dealer') : tr('dash_client'));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> save() async {
          final u = userCtrl.text.trim();
          final n = nameCtrl.text.trim();
          if (u.isEmpty || n.isEmpty || pwCtrl.text.isEmpty) {
            setS(() => err = tr('dash_fill_all'));
            return;
          }
          if (pwCtrl.text != pw2Ctrl.text) {
            setS(() => err = tr('dash_pw_mismatch'));
            return;
          }
          setS(() { busy = true; err = null; });
          final provider = context.read<AppProvider>();
          final r = await provider.addUser(
            username: u, password: pwCtrl.text, fullName: n,
            accountType: type, phone: phoneCtrl.text.trim(),
            parentId: widget.user.id,          // ← يُنشأ تحت الحساب المعروض
          );
          if (!ctx.mounted) return;
          if (r['success'] == true) {
            Navigator.pop(ctx);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr('dash_client_added'), style: cairo)),
            );
          } else {
            setS(() { busy = false; err = r['error']?.toString() ?? tr('dash_failed'); });
          }
        }

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: Colors.grey.withOpacity(.35),
                    borderRadius: BorderRadius.circular(2))),
              Text(tr('cl_add_user_under', {'name': widget.user.fullName}),
                  style: cairo.copyWith(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              if (types.length > 1) ...[
                Row(children: [
                  Text('${tr('dash_account_type')}:', style: cairo.copyWith(fontSize: 13)),
                  const SizedBox(width: 10),
                  Expanded(child: Wrap(spacing: 8, children: types.map((t) => ChoiceChip(
                    label: Text(label(t), style: cairo.copyWith(fontSize: 12)),
                    selected: type == t,
                    onSelected: busy ? null : (_) => setS(() => type = t),
                  )).toList())),
                ]),
                const SizedBox(height: 10),
              ],
              TextField(controller: userCtrl, decoration: InputDecoration(labelText: tr('dash_username'))),
              const SizedBox(height: 8),
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('dash_full_name'))),
              const SizedBox(height: 8),
              TextField(controller: phoneCtrl, keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: tr('dash_phone'))),
              const SizedBox(height: 8),
              TextField(controller: pwCtrl, obscureText: true,
                  decoration: InputDecoration(labelText: tr('dash_password'))),
              const SizedBox(height: 8),
              TextField(controller: pw2Ctrl, obscureText: true,
                  decoration: InputDecoration(labelText: tr('dash_confirm_password'))),
              if (err != null) ...[
                const SizedBox(height: 10),
                Text(err!, style: cairo.copyWith(color: const Color(0xFFEF5350), fontSize: 12)),
              ],
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, height: 46, child: ElevatedButton(
                onPressed: busy ? null : save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0D9488),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: busy
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(tr('dash_add'), style: cairo.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
              )),
            ]),
          ),
        );
      }),
    );
  }

  void _addDevice(BuildContext context) {
    final imeiCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String deviceType = 'GT06N';
    String subType = 'annual';
    bool saving = false;
    final provider = context.read<AppProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(tr('cl_add_dev_title', {'name': widget.user.fullName}), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ]),
                const SizedBox(height: 12),
                TextField(controller: imeiCtrl, decoration: InputDecoration(labelText: tr('cl_imei')), keyboardType: TextInputType.number),
                const SizedBox(height: 10),
                TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('cl_dev_name'))),
                const SizedBox(height: 10),
                ModelPickerField(
                  value: deviceType,
                  label: tr('cl_dev_type'),
                  onChanged: (v) => setS(() => deviceType = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: subType,
                  decoration: InputDecoration(labelText: tr('cl_sub_type')),
                  items: [
                    DropdownMenuItem(value: 'lifetime', child: Text(tr('cl_lifetime'))),
                    DropdownMenuItem(value: 'annual', child: Text(tr('cl_annual'))),
                  ],
                  onChanged: (v) => setS(() => subType = v!),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: saving ? null : () async {
                      if (imeiCtrl.text.isEmpty || nameCtrl.text.isEmpty) return;
                      setS(() => saving = true);
                      final result = await provider.addDevice(
                        imei: imeiCtrl.text.trim(),
                        name: nameCtrl.text.trim(),
                        deviceType: deviceType,
                        userId: widget.user.id,
                        subscriptionType: subType,
                      );
                      setS(() => saving = false);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(result['success'] == true ? tr('cl_dev_added') : result['error'] ?? tr('cl_fail'), style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: result['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                        ));
                        if (result['success'] == true) _loadDevices();
                      }
                    },
                    child: saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(tr('cl_add'), style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _resetPassword(BuildContext context) {
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool customMode = false;
    bool busy = false;
    String? err;
    const cairo = TextStyle(fontFamily: 'Cairo');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> apply({String? pw}) async {
          setS(() { busy = true; err = null; });
          final r = await ApiService.resetPassword(userId: widget.user.id, newPassword: pw);
          if (!ctx.mounted) return;
          if (r['success'] == true) {
            Navigator.pop(ctx);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(pw == null ? tr('cl_pw_reset') : tr('cl_pw_changed'), style: cairo),
                backgroundColor: const Color(0xFF6BA539)));
            }
          } else {
            setS(() { busy = false; err = r['error']?.toString() ?? tr('api_error'); });
          }
        }

        return AlertDialog(
          title: Text(tr('cl_pw_title', {'name': widget.user.fullName}),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
          content: customMode
              // تعديل: كلمة مرور جديدة + تأكيد (بدون الحالية — الديلر مزوّد الخدمة)
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: newCtrl, obscureText: true, style: cairo,
                      decoration: InputDecoration(labelText: tr('cl_pw_new'), labelStyle: cairo)),
                  const SizedBox(height: 8),
                  TextField(controller: confirmCtrl, obscureText: true, style: cairo,
                      decoration: InputDecoration(labelText: tr('cl_pw_confirm'), labelStyle: cairo)),
                  if (err != null) Padding(padding: const EdgeInsets.only(top: 8),
                      child: Text(err!, style: const TextStyle(color: Color(0xFFC41E3A), fontSize: 12, fontFamily: 'Cairo'))),
                ])
              // القائمة: خيارين
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.lock_reset, color: Color(0xFFF59E0B)),
                    title: Text(tr('cl_pw_reset_default'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: const Text('123456', style: TextStyle(fontFamily: 'Cairo', fontSize: 11)),
                    onTap: busy ? null : () => apply(),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.password_outlined, color: Color(0xFF2563EB)),
                    title: Text(tr('cl_pw_set_new'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                    onTap: () => setS(() { customMode = true; err = null; }),
                  ),
                  if (busy) const Padding(padding: EdgeInsets.only(top: 10),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFC41E3A)))),
                ]),
          actions: customMode
              ? [
                  TextButton(onPressed: busy ? null : () => setS(() { customMode = false; err = null; }),
                      child: Text(tr('cl_back'), style: cairo)),
                  ElevatedButton(
                    onPressed: busy ? null : () {
                      final p = newCtrl.text.trim();
                      if (p.length < 6) { setS(() => err = tr('cl_pw_too_short')); return; }
                      if (p != confirmCtrl.text.trim()) { setS(() => err = tr('cl_pw_mismatch')); return; }
                      apply(pw: p);
                    },
                    child: busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(tr('cl_confirm'), style: cairo),
                  ),
                ]
              : [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'), style: cairo))],
        );
      }),
    );
  }

  void _openSettings(BuildContext context) async {
    // Load existing settings
    final result = await ApiService.request('get_settings', {'id': widget.user.id});
    if (result['settings'] != null && result['settings'] is Map) {
      _settings = Map<String, dynamic>.from(result['settings'] as Map);
    }
    if (!mounted) return;

    // Determine who's calling (dealer / admin)
    final callerRole = context.read<AppProvider>().currentUser?.accountType ?? '';
    final canChangeRole = callerRole == 'dealer' || callerRole == 'sub_dealer' || callerRole == 'admin';

    final tzCtrl = TextEditingController(text: _settings['timezone'] ?? 'Africa/Cairo');
    String selectedRole = widget.user.accountType; // current account type
    bool viewOnly = (_settings['view_only'] == true || _settings['view_only'] == 1);
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
          child: SingleChildScrollView(
            child: Directionality(
              textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(tr('cl_settings_title', {'name': widget.user.fullName}),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ]),
                  const SizedBox(height: 8),

                  // ── Username row (display + copy) ──────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                    ),
                    child: Row(children: [
                      const Icon(Icons.person_outline, size: 18, color: Color(0xFF1565C0)),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('cl_username'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Color(0xFF6B7280))),
                        Text(widget.user.username, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                      ])),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: widget.user.username));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(tr('imei_copied'), style: const TextStyle(fontFamily: 'Cairo')),
                            duration: const Duration(seconds: 1), backgroundColor: const Color(0xFF6BA539),
                          ));
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(padding: EdgeInsets.all(6), child: Icon(Icons.copy, size: 18, color: Color(0xFF1565C0))),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),

                  // ── Account type (dealer/admin can change) ─────────────────
                  if (canChangeRole) ...[
                    Text(tr('cl_acc_type'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF6B7280))),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: selectedRole,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        prefixIcon: Icon(
                          selectedRole == 'dealer' ? Icons.storefront_outlined
                              : selectedRole == 'sub_dealer' ? Icons.supervisor_account_outlined
                              : Icons.person_outlined,
                          color: selectedRole == 'dealer' ? const Color(0xFFC41E3A)
                              : selectedRole == 'sub_dealer' ? const Color(0xFF7C3AED)
                              : const Color(0xFF1565C0),
                          size: 20,
                        ),
                      ),
                      // الأنواع المتاحة = ما يجوز للمُشاهد إنشاؤه (نفس حراسة السيرفر):
                      // أدمن ← ديلر/موزع/عميل · ديلر ← موزع/عميل · موزع ← عميل
                      items: [
                        DropdownMenuItem(value: 'client', child: Text(tr('tab_client'), style: const TextStyle(fontFamily: 'Cairo'))),
                        if (callerRole == 'admin' || callerRole == 'dealer')
                          DropdownMenuItem(value: 'sub_dealer', child: Text(tr('tab_subdealer'), style: const TextStyle(fontFamily: 'Cairo'))),
                        if (callerRole == 'admin')
                          DropdownMenuItem(value: 'dealer', child: Text(tr('tab_dealer'), style: const TextStyle(fontFamily: 'Cairo'))),
                      ],
                      onChanged: (v) => setS(() => selectedRole = v!),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── View-only toggle ───────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                    ),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(tr('cl_view_only'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                        Text(tr('cl_view_only_hint'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Color(0xFF6B7280))),
                      ])),
                      Switch(
                        value: viewOnly,
                        onChanged: (v) => setS(() => viewOnly = v),
                        activeColor: const Color(0xFFC41E3A),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),

                  // ── Timezone ───────────────────────────────────────────────
                  Text(tr('cl_timezone'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF6B7280))),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: tzCtrl.text,
                    decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                    items: [
                      DropdownMenuItem(value: 'Africa/Cairo', child: Text(tr('cl_tz_cairo'), style: const TextStyle(fontFamily: 'Cairo'))),
                      DropdownMenuItem(value: 'Asia/Riyadh', child: Text(tr('cl_tz_riyadh'), style: const TextStyle(fontFamily: 'Cairo'))),
                      DropdownMenuItem(value: 'Asia/Dubai', child: Text(tr('cl_tz_dubai'), style: const TextStyle(fontFamily: 'Cairo'))),
                      DropdownMenuItem(value: 'Europe/London', child: Text(tr('cl_tz_london'), style: const TextStyle(fontFamily: 'Cairo'))),
                    ],
                    onChanged: (v) => setS(() => tzCtrl.text = v!),
                  ),
                  const SizedBox(height: 16),

                  // ── Save button ────────────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC41E3A), padding: const EdgeInsets.symmetric(vertical: 13)),
                      onPressed: saving ? null : () async {
                        setS(() => saving = true);
                        _settings['timezone'] = tzCtrl.text;
                        _settings['view_only'] = viewOnly ? 1 : 0;

                        // Save settings
                        final r = await ApiService.request('save_settings', {
                          'id': widget.user.id,
                          'settings': _settings,
                        });

                        // Change account type if it changed
                        if (canChangeRole && selectedRole != widget.user.accountType) {
                          await ApiService.updateUser(
                            userId: widget.user.id,
                            updates: {'account_type': selectedRole},
                          );
                        }

                        setS(() => saving = false);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(r['success'] == true ? tr('cl_settings_saved') : r['error'] ?? tr('cl_fail'),
                                style: const TextStyle(fontFamily: 'Cairo')),
                            backgroundColor: r['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                          ));
                          // Reload users list to reflect role change
                          if (canChangeRole && selectedRole != widget.user.accountType) {
                            context.read<AppProvider>().loadUsers();
                          }
                        }
                      },
                      child: saving
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text(tr('cl_save_settings'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 14)),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _transferAccount(BuildContext context) async {
    // Build list of possible targets
    final provider = context.read<AppProvider>();
    final allUsers = _allUsers.isNotEmpty ? _allUsers : provider.users;
    final currentUser = provider.currentUser;
    final List<Map<String, dynamic>> targets = [];

    if (currentUser?.accountType == 'admin') {
      targets.add({'id': 0, 'name': tr('cl_no_dealer')});
      for (final u in allUsers) {
        if (u.accountType == 'dealer' && u.id != widget.user.id) {
          targets.add({'id': u.id, 'name': u.fullName});
        }
      }
    } else {
      // dealer can transfer to their sub_dealers
      targets.add({'id': currentUser?.id ?? 0, 'name': tr('cl_under_me')});
      for (final u in allUsers) {
        if (u.accountType == 'sub_dealer' && u.id != widget.user.id) {
          targets.add({'id': u.id, 'name': u.fullName});
        }
      }
    }

    if (targets.isEmpty || !mounted) return;
    int? selectedId = targets.first['id'] as int;
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(tr('cl_transfer_title', {'name': widget.user.fullName}), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ]),
              const SizedBox(height: 12),
              Text(tr('cl_choose_dealer'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: selectedId,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: targets.map((t) => DropdownMenuItem<int>(
                  value: t['id'] as int,
                  child: Text(t['name'] as String, style: const TextStyle(fontFamily: 'Cairo')),
                )).toList(),
                onChanged: (v) => setS(() => selectedId = v),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
                  onPressed: saving ? null : () async {
                    setS(() => saving = true);
                    // اصطلاح السيرفر: action = transfer_account والوجهة = newDealerId
                    final r = await ApiService.request('transfer_account', {
                      'userId': widget.user.id,
                      'newDealerId': selectedId ?? 0,
                    });
                    setS(() => saving = false);
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(r['success'] == true ? tr('cl_acc_transferred') : r['error'] ?? tr('cl_fail'),
                            style: const TextStyle(fontFamily: 'Cairo')),
                        backgroundColor: r['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                      ));
                      if (r['success'] == true) {
                        provider.loadUsers();
                      }
                    }
                  },
                  child: saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(tr('cl_transfer_acc_btn'), style: const TextStyle(fontFamily: 'Cairo')),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _deleteAccount(BuildContext context) async {
    // Client-side pre-check: an account holding devices cannot be deleted.
    if (_devices.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('cl_del_acc_has_devices'), style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: const Color(0xFFC41E3A),
      ));
      return;
    }
    final provider = context.read<AppProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('cl_del_acc_title'), style: const TextStyle(fontFamily: 'Cairo')),
        content: Text(tr('cl_del_acc_q', {'name': widget.user.fullName}), style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF5350)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('cl_delete'), style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final r = await ApiService.deleteUser(widget.user.id);
    if (!mounted) return;
    final ok = r['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? tr('cl_acc_deleted') : (r['error']?.toString() ?? tr('cl_fail')),
          style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: ok ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
    ));
    if (ok) {
      provider.loadUsers();
      Navigator.of(context).pop(); // close client-detail screen
    }
  }

  void _editDevice(BuildContext context, DeviceModel device) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _EditDeviceSheet(device: device, onSaved: _loadDevices));
  }

  void _deleteDevice(BuildContext context, DeviceModel device) async {
    final pwCtrl = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('cl_del_dev_title'), style: const TextStyle(fontFamily: 'Cairo')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('cl_del_dev_q', {'name': device.name}), style: const TextStyle(fontFamily: 'Cairo')),
          const SizedBox(height: 12),
          TextField(controller: pwCtrl, obscureText: true, decoration: InputDecoration(labelText: I18n.isAr ? 'كلمة المرور' : 'Password', labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12), border: const OutlineInputBorder(), isDense: true)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF5350)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('cl_delete'), style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      final r = await ApiService.request('delete_device', {'id': device.id, 'password': pwCtrl.text});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['success'] == true ? tr('cl_dev_deleted') : r['error'] ?? tr('cl_fail'),
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: r['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
        ));
        if (r['success'] == true) _loadDevices();
      }
    }
  }

  void _transferDevice(BuildContext context, DeviceModel device) async {
    final provider = context.read<AppProvider>();
    final me = provider.currentUser;
    final allUsers = _allUsers.isNotEmpty ? _allUsers : provider.users;
    // كل الحسابات ما عدا الحساب الحالي
    final targets = allUsers.where((u) => u.id != widget.user.id).toList();
    int? selectedId;
    bool myAccount = false; // نقل لحسابي (→ المخزون)
    bool saving = false;
    final searchCtrl = TextEditingController();
    List<UserModel> filtered = List.from(targets);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          void onSearch(String q) {
            setS(() {
              filtered = q.isEmpty
                  ? List.from(targets)
                  : targets.where((u) => u.fullName.toLowerCase().contains(q.toLowerCase())).toList();
              if (selectedId != null && !filtered.any((u) => u.id == selectedId)) selectedId = null;
            });
          }
          final surface = Theme.of(ctx).colorScheme.surface;
          final onSurface = Theme.of(ctx).colorScheme.onSurface;
          final divColor = Theme.of(ctx).dividerColor;
          return Container(
            decoration: BoxDecoration(color: surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(margin: const EdgeInsets.only(bottom: 12), width: 36, height: 4,
                    decoration: BoxDecoration(color: divColor, borderRadius: BorderRadius.circular(2))),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(tr('cl_transfer_dev_title', {'name': device.name}),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo', color: onSurface)),
                  IconButton(icon: Icon(Icons.close, color: onSurface), onPressed: () => Navigator.pop(ctx)),
                ]),
                const SizedBox(height: 10),
                // زر "حسابي" بجانب البحث
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: searchCtrl,
                      onChanged: (v) { onSearch(v); if (v.isNotEmpty) setS(() => myAccount = false); },
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: I18n.isAr ? 'بحث باسم الحساب...' : 'Search by name...',
                        hintStyle: const TextStyle(fontFamily: 'Cairo'),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searchCtrl.text.isNotEmpty
                            ? IconButton(icon: const Icon(Icons.clear), onPressed: () { searchCtrl.clear(); onSearch(''); })
                            : null,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setS(() { myAccount = !myAccount; if (myAccount) { selectedId = null; searchCtrl.clear(); filtered = List.from(targets); } }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: myAccount ? const Color(0xFFC41E3A) : divColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: myAccount ? const Color(0xFFC41E3A) : divColor),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.person_outlined, size: 18, color: myAccount ? Colors.white : onSurface),
                        const SizedBox(height: 2),
                        Text(I18n.isAr ? 'حسابي' : 'Mine',
                            style: TextStyle(fontSize: 10, fontFamily: 'Cairo', fontWeight: FontWeight.w600,
                                color: myAccount ? Colors.white : onSurface)),
                      ]),
                    ),
                  ),
                ]),
                // بطاقة "حسابي" المختارة
                if (myAccount && me != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: const Color(0xFFC41E3A).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFC41E3A).withOpacity(0.4))),
                    child: Row(children: [
                      const Icon(Icons.check_circle, size: 16, color: Color(0xFFC41E3A)),
                      const SizedBox(width: 8),
                      Text(me.fullName, style: const TextStyle(fontSize: 12, fontFamily: 'Cairo', fontWeight: FontWeight.w600, color: Color(0xFFC41E3A))),
                      const SizedBox(width: 6),
                      Text(I18n.isAr ? '(حسابي → مخزون)' : '(My account → inventory)',
                          style: const TextStyle(fontSize: 10, fontFamily: 'Cairo', color: Color(0xFF8892A4))),
                    ]),
                  ),
                ],
                const SizedBox(height: 10),
                // القائمة (مخفية لو اختار حسابي)
                if (!myAccount) ...[
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(I18n.isAr ? 'لا توجد نتائج' : 'No results',
                          style: TextStyle(fontFamily: 'Cairo', color: onSurface.withOpacity(0.4))),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 250),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final u = filtered[i];
                          final isSelected = selectedId == u.id;
                          final badgeColor = u.isDealer ? const Color(0xFF1565C0)
                              : u.isSubDealer ? const Color(0xFF7C3AED) : const Color(0xFF6BA539);
                          final badgeLabel = u.isDealer ? (I18n.isAr ? 'ديلر' : 'Dealer')
                              : u.isSubDealer ? (I18n.isAr ? 'موزع' : 'Sub') : (I18n.isAr ? 'عميل' : 'Client');
                          return ListTile(
                            dense: true,
                            selected: isSelected,
                            selectedTileColor: const Color(0xFF1565C0).withOpacity(0.12),
                            onTap: () => setS(() => selectedId = u.id),
                            leading: isSelected
                                ? const Icon(Icons.check_circle, color: Color(0xFF1565C0))
                                : Icon(Icons.radio_button_unchecked, color: onSurface.withOpacity(0.4)),
                            title: Text(u.fullName, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: onSurface)),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: badgeColor.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                              child: Text(badgeLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: badgeColor, fontWeight: FontWeight.bold)),
                            ),
                          );
                        },
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (myAccount || selectedId != null) ? const Color(0xFF1565C0) : Colors.grey,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: (saving || (!myAccount && selectedId == null)) ? null : () async {
                      setS(() => saving = true);
                      final targetId = myAccount ? me?.id : selectedId;
                      final r = await ApiService.request('transfer_device', {
                        'imei': device.imei,
                        'userId': targetId,
                      });
                      setS(() => saving = false);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(r['success'] == true ? tr('cl_dev_transferred') : r['error'] ?? tr('cl_fail'),
                              style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: r['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                        ));
                        if (r['success'] == true) { _loadDevices(); provider.loadDevices(); }
                      }
                    },
                    child: saving
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(tr('cl_transfer_dev_btn'), style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _editCardBalance(BuildContext context) {
    // القيم الحالية - المستخدم بيكتب القيمة النهائية المطلوبة
    final oldNy = _cardBalance?['new_yearly'] ?? 0;
    final oldNl = _cardBalance?['new_lifetime'] ?? 0;
    final oldRy = _cardBalance?['renew_yearly'] ?? 0;
    final oldRl = _cardBalance?['renew_lifetime'] ?? 0;

    final nyCtrl = TextEditingController(text: oldNy.toString());
    final nlCtrl = TextEditingController(text: oldNl.toString());
    final ryCtrl = TextEditingController(text: oldRy.toString());
    final rlCtrl = TextEditingController(text: oldRl.toString());
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(tr('cl_edit_cards'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ]),
                const SizedBox(height: 4),
                Text(tr('cl_cards_hint'), style: TextStyle(fontSize: 11, color: Colors.grey[600], fontFamily: 'Cairo')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: nyCtrl, decoration: InputDecoration(labelText: tr('cl_new_yearly_cur', {'n': '$oldNy'}), border: const OutlineInputBorder()), keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: nlCtrl, decoration: InputDecoration(labelText: tr('cl_new_life_cur', {'n': '$oldNl'}), border: const OutlineInputBorder()), keyboardType: TextInputType.number)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: ryCtrl, decoration: InputDecoration(labelText: tr('cl_renew_yearly_cur', {'n': '$oldRy'}), border: const OutlineInputBorder()), keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: rlCtrl, decoration: InputDecoration(labelText: tr('cl_renew_life_cur', {'n': '$oldRl'}), border: const OutlineInputBorder()), keyboardType: TextInputType.number)),
                ]),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
                    onPressed: saving ? null : () async {
                      setS(() => saving = true);

                      // القيم الجديدة المطلوبة
                      final newNy = int.tryParse(nyCtrl.text) ?? oldNy;
                      final newNl = int.tryParse(nlCtrl.text) ?? oldNl;
                      final newRy = int.tryParse(ryCtrl.text) ?? oldRy;
                      final newRl = int.tryParse(rlCtrl.text) ?? oldRl;

                      // حساب الفرق
                      final dNy = newNy - oldNy;
                      final dNl = newNl - oldNl;
                      final dRy = newRy - oldRy;
                      final dRl = newRl - oldRl;

                      // لو مفيش فرق خالص - مفيش داعي لأي request
                      if (dNy == 0 && dNl == 0 && dRy == 0 && dRl == 0) {
                        setS(() => saving = false);
                        if (ctx.mounted) Navigator.pop(ctx);
                        return;
                      }

                      // فصل الزيادات عن النقصان
                      final assigns = <String, dynamic>{'dealer_id': widget.user.id};
                      final deducts = <String, dynamic>{'dealer_id': widget.user.id};

                      if (dNy > 0) assigns['new_yearly'] = dNy;
                      if (dNl > 0) assigns['new_lifetime'] = dNl;
                      if (dRy > 0) assigns['renew_yearly'] = dRy;
                      if (dRl > 0) assigns['renew_lifetime'] = dRl;

                      if (dNy < 0) deducts['new_yearly'] = dNy.abs();
                      if (dNl < 0) deducts['new_lifetime'] = dNl.abs();
                      if (dRy < 0) deducts['renew_yearly'] = dRy.abs();
                      if (dRl < 0) deducts['renew_lifetime'] = dRl.abs();

                      Map<String, dynamic> r = {'success': true};

                      // assign لو في زيادة
                      if (assigns.length > 1) {
                        r = await ApiService.request('assign_cards', assigns);
                      }

                      // deduct لو في نقصان (بس لو الـ assign نجح أو مفيش assign)
                      if (r['success'] == true && deducts.length > 1) {
                        r = await ApiService.request('deduct_cards', deducts);
                      }

                      setS(() => saving = false);
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(r['success'] == true ? tr('cl_cards_saved') : r['error'] ?? tr('cl_fail'),
                              style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: r['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                        ));
                        if (r['success'] == true) _loadCardBalance();
                      }
                    },
                    child: saving
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(tr('save'), style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// Helper Widgets for Profile Sheet
// ============================================================

class _BalChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _BalChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
        child: Column(children: [
          Text(value.toString(), style: TextStyle(color: color == const Color(0xFF2196F3) ? Colors.white : Colors.white, fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 7, fontFamily: 'Cairo', height: 1.2)),
        ]),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
        Text(label, style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 9, fontFamily: 'Cairo')),
      ]),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}


// ─── Client Map View ─────────────────────────────────────────────────────────
class _ClientMapView extends StatefulWidget {
  final List<DeviceModel> devices;
  const _ClientMapView({required this.devices});
  @override
  State<_ClientMapView> createState() => _ClientMapViewState();
}

class _ClientMapViewState extends State<_ClientMapView> {
  GoogleMapController? _ctrl;
  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _buildMarkers();
  }

  void _buildMarkers() {
    final ms = <Marker>{};
    for (final d in widget.devices) {
      if (d.lat == null || d.lng == null) continue;
      final color = d.isMoving ? BitmapDescriptor.hueGreen
          : d.isInactive ? BitmapDescriptor.hueOrange
          : d.isOnline ? BitmapDescriptor.hueAzure
          : BitmapDescriptor.hueRed;
      ms.add(Marker(
        markerId: MarkerId(d.id.toString()),
        position: LatLng(d.lat!, d.lng!),
        icon: BitmapDescriptor.defaultMarkerWithHue(color),
        infoWindow: InfoWindow(title: d.name, snippet: d.statusAr),
      ));
    }
    if (mounted) setState(() => _markers..clear()..addAll(ms));
    // Auto-fit camera
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());
  }

  void _fitBounds() {
    final pts = widget.devices.where((d) => d.lat != null && d.lng != null).toList();
    if (pts.isEmpty || _ctrl == null) return;
    if (pts.length == 1) {
      _ctrl!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(pts.first.lat!, pts.first.lng!), 14));
      return;
    }
    double minLat = pts.first.lat!, maxLat = pts.first.lat!;
    double minLng = pts.first.lng!, maxLng = pts.first.lng!;
    for (final d in pts) {
      if (d.lat! < minLat) minLat = d.lat!;
      if (d.lat! > maxLat) maxLat = d.lat!;
      if (d.lng! < minLng) minLng = d.lng!;
      if (d.lng! > maxLng) maxLng = d.lng!;
    }
    _ctrl!.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)), 60));
  }

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: const CameraPosition(target: LatLng(30.0444, 31.2357), zoom: 10),
      markers: _markers,
      onMapCreated: (c) { _ctrl = c; _fitBounds(); },
      zoomControlsEnabled: false,
      myLocationButtonEnabled: false,
    );
  }
}

String _timeAgo(DateTime? dt) {
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return ' ${tr('cl_ago_sec', {'n': '${diff.inSeconds < 1 ? 1 : diff.inSeconds}'})}';
  if (diff.inMinutes < 60) return ' ${tr('cl_ago_min', {'n': '${diff.inMinutes}'})}';
  if (diff.inHours < 24) return ' ${tr('cl_ago_hr', {'n': '${diff.inHours}'})}';
  return ' ${tr('cl_ago_day', {'n': '${diff.inDays}'})}';
}

class _DeviceProfileRow extends StatelessWidget {
  final DeviceModel device;
  final bool isAdmin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onTransfer;
  const _DeviceProfileRow({
    required this.device,
    this.isAdmin = false,
    this.onEdit,
    this.onDelete,
    this.onTransfer,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = device.isMoving ? const Color(0xFF166634)
        : device.isInactive ? const Color(0xFFF59E0B)
        : device.isOnline ? const Color(0xFF1E40AF) : const Color(0xFFEF5350);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
            Text(device.imei, style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(device.deviceType, style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
            Text(
              device.isMoving
                ? tr('st_moving', {'s': device.speedKmh})
                : device.isInactive
                  ? tr('m_st_inactive')
                  : '${device.statusAr}${_timeAgo(device.lastUpdate)}',
              style: TextStyle(fontSize: 9, color: dotColor, fontFamily: 'Cairo'),
            ),
          ]),
        ]),
        if (onEdit != null || onDelete != null || onTransfer != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (onEdit != null)
              _MiniBtn(label: tr('cl_mini_edit'), icon: Icons.edit_outlined, color: const Color(0xFF1565C0), onTap: onEdit!),
            if (onTransfer != null) ...[
              const SizedBox(width: 6),
              _MiniBtn(label: tr('cl_mini_transfer'), icon: Icons.swap_horiz, color: const Color(0xFF059669), onTap: onTransfer!),
            ],
            if (isAdmin && onDelete != null) ...[
              const SizedBox(width: 6),
              _MiniBtn(label: tr('cl_mini_delete'), icon: Icons.delete_outline, color: const Color(0xFFEF5350), onTap: onDelete!),
            ],
          ]),
        ],
      ]),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _MiniBtn({required this.label, required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10, color: color, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

class _SubUserRow extends StatelessWidget {
  final UserModel user;
  const _SubUserRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final badgeColor = user.isDealer ? const Color(0xFFC41E3A)
        : user.isSubDealer ? const Color(0xFF7C3AED) : const Color(0xFF1565C0);
    final badgeLabel = user.isDealer ? tr('tab_dealer') : user.isSubDealer ? tr('tab_subdealer') : tr('tab_client');
    return GestureDetector(
      onTap: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => _UserProfilePage(user: user)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(children: [
          CircleAvatar(radius: 16, backgroundColor: badgeColor.withOpacity(0.15),
            child: Text(user.initials, style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.w600))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.fullName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
            Text(user.username, style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: badgeColor.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Text(badgeLabel, style: TextStyle(fontSize: 8, color: badgeColor, fontFamily: 'Cairo')),
          ),
        ]),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<_InfoItem> items;
  const _InfoCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(children: items),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String label, value;
  final bool isLast;
  /// يُظهر زر نسخ بجانب القيمة (اسم المستخدم، السيريال، وما يُنسخ عادةً)
  final bool copyable;
  const _InfoItem({required this.label, required this.value, this.isLast = false, this.copyable = false});

  @override
  Widget build(BuildContext context) {
    final canCopy = copyable && value.trim().isNotEmpty && value.trim() != '-';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(border: isLast ? null : Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4), fontFamily: 'Cairo', fontWeight: FontWeight.w500))),
        Expanded(child: Text(value, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo'), textDirection: TextDirection.rtl)),
        if (canCopy)
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value.trim()));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr('sp_copied'), style: const TextStyle(fontFamily: 'Cairo')),
                backgroundColor: const Color(0xFF6BA539),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ));
            },
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Icon(Icons.copy, size: 16, color: Color(0xFF1565C0)),
            ),
          ),
      ]),
    );
  }
}

// ============================================================
// _ClientRow
// ============================================================

class _HierarchyItem {
  final UserModel user;
  final int level; // 0=dealer, 1=sub/direct-client, 2=sub-client
  const _HierarchyItem({required this.user, required this.level});
}

class _HierarchyRow extends StatelessWidget {
  final _HierarchyItem item;
  final VoidCallback onTap;
  const _HierarchyRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final u = item.user;
    final level = item.level;
    final badgeColor = u.isDealer ? const Color(0xFFC41E3A)
        : u.isSubDealer ? const Color(0xFF7C3AED) : const Color(0xFF1565C0);
    final badgeLabel = u.isDealer ? tr('tab_dealer') : u.isSubDealer ? tr('tab_subdealer') : tr('tab_client');
    const colors = [Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFFFF9800), Color(0xFF2196F3), Color(0xFF009688)];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 4, right: level * 16.0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: level == 0 ? (Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface) : Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: level == 0 ? [const BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1))] : null,
        ),
        child: Row(children: [
          if (level > 0) ...[
            Container(width: 2, height: 30, color: badgeColor.withOpacity(0.3)),
            const SizedBox(width: 8),
          ],
          _UserAvatar(avatarUrl: u.avatarUrl, initials: u.firstLetter, radius: level == 0 ? 18 : 14, bgColor: colors[u.id % colors.length]),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(u.fullName, style: TextStyle(fontSize: level == 0 ? 12 : 11, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo')),
            Text(u.isSubDealer ? '${tr('cl_n_clients', {'n': '${u.clientCount}'})} - ${u.username}' : '${tr('cl_n_devices', {'n': '${u.deviceCount}'})} - ${u.username}',
                style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
          ])),
          const Icon(Icons.chevron_right, color: Color(0xFF8892A4), size: 14),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: badgeColor.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: Text(badgeLabel, style: TextStyle(fontSize: 8, color: badgeColor, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
          ),
        ]),
      ),
    );
  }
}

class _ClientRow extends StatelessWidget {
  final UserModel user;
  final VoidCallback onTap;
  const _ClientRow({required this.user, required this.onTap});
  static const _colors = [Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFFFF9800), Color(0xFF2196F3), Color(0xFF009688)];
  Color get _avatarColor => _colors[user.id % _colors.length];

  @override
  Widget build(BuildContext context) {
    final badgeColor = user.isDealer ? const Color(0xFFC41E3A)
        : user.isSubDealer ? const Color(0xFF7C3AED) : const Color(0xFF1565C0);
    final badgeLabel = user.isDealer ? tr('tab_dealer') : user.isSubDealer ? tr('tab_subdealer') : tr('tab_client');
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Row(
          children: [
            _UserAvatar(avatarUrl: user.avatarUrl, initials: user.firstLetter, radius: 18, bgColor: _avatarColor),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(user.fullName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo')),
              Text(user.isSubDealer ? tr('cl_n_client_sub', {'n': '${user.clientCount}'}) : tr('cl_n_devices', {'n': '${user.deviceCount}'}),
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
            ])),
            const Icon(Icons.chevron_right, color: Color(0xFF8892A4), size: 16),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: badgeColor.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
              child: Text(badgeLabel, style: TextStyle(fontSize: 8, color: badgeColor, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MessagesScreen
// ============================================================

// ─── Shared notification helpers (used by list + alert detail modal) ───
IconData notifIconForType(String type, String? subtype) {
  switch (type) {
    case 'ignitionOn':      return Icons.power_settings_new;
    case 'ignitionOff':     return Icons.power_off_outlined;
    case 'deviceOverspeed': return Icons.speed;
    case 'deviceOffline':   return Icons.signal_wifi_off;
    case 'deviceOnline':    return Icons.signal_wifi_4_bar;
    case 'deviceStopped':
    case 'alert_parking':   return Icons.local_parking;
    case 'alert_idle':      return Icons.timelapse;
    case 'deviceMoving':    return Icons.directions_car;
    case 'geofenceEnter':   return Icons.login;
    case 'geofenceExit':    return Icons.logout;
    case 'alarm':
      switch (subtype) {
        case 'powerCut':     return Icons.power_off;
        case 'lowBattery':   return Icons.battery_alert;
        case 'door':         return Icons.sensor_door_outlined;
        case 'braking':      return Icons.warning_amber;
        case 'acceleration': return Icons.trending_up;
        case 'tow':          return Icons.car_repair;
        case 'sos':          return Icons.sos;
        default:             return Icons.warning_outlined;
      }
    case 'message':         return Icons.forum_outlined;
    default: return Icons.notifications_outlined;
  }
}

Color notifColorForType(String type, String? subtype) {
  if (type == 'ignitionOn'  || type == 'geofenceEnter' || type == 'deviceOnline') return const Color(0xFF6BA539);
  if (type == 'ignitionOff' || type == 'geofenceExit'  || type == 'deviceStopped' || type == 'alert_parking') return const Color(0xFF6B7280);
  if (type == 'deviceOverspeed') return const Color(0xFFC41E3A);
  if (type == 'deviceOffline')   return const Color(0xFFD97706);
  if (type == 'alert_idle')      return const Color(0xFFD97706);
  if (type == 'alarm') {
    if (subtype == 'lowBattery' || subtype == 'door') return const Color(0xFFD97706);
    return const Color(0xFFC41E3A);
  }
  return const Color(0xFF2563EB);
}

String notifTypeLabel(String type, String? subtype) {
  switch (type) {
    case 'message':         return tr('an_message');
    case 'ignitionOn':      return tr('an_ign_on');
    case 'ignitionOff':     return tr('an_ign_off');
    case 'deviceOverspeed': return tr('an_overspeed');
    case 'deviceOffline':   return tr('an_offline');
    case 'deviceOnline':    return tr('an_online');
    case 'deviceStopped':   return tr('an_stopped');
    case 'alert_parking':   return tr('an_parking');
    case 'alert_idle':      return tr('an_idle');
    case 'deviceMoving':    return tr('an_moving');
    case 'geofenceEnter':   return tr('an_gf_enter');
    case 'geofenceExit':    return tr('an_gf_exit');
    case 'alarm':
      switch (subtype) {
        case 'powerCut':     return tr('an_power_cut');
        case 'lowBattery':   return tr('an_low_battery');
        case 'door':         return tr('an_door');
        case 'braking':      return tr('an_braking');
        case 'acceleration': return tr('an_accel');
        case 'tow':          return tr('an_tow');
        case 'sos':          return tr('an_sos');
        default:             return tr('an_alarm');
      }
    default: return tr('an_alert');
  }
}

// نص تفاصيل الإشعار: عربي = الـ body المخزّن كما هو (بدون أي تغيير)، إنجليزي = يُبنى من الحقول
String notifBodyText(Map<String, dynamic> n, String type, String? subtype) {
  final body = (n['body'] ?? '').toString();
  if (type == 'message') return body; // رسالة إدارية: نص المستخدم كما هو (لا يُترجَم)
  if (I18n.isAr) return body; // العربي: السلوك الحالي تماماً — صفر تغيير
  // الإنجليزي: ابنِ النص من الحقول المنظّمة (السرعة + الحد المقروء من الـ body العربي)
  final spdNum = n['speed'] is num ? (n['speed'] as num) : num.tryParse(n['speed']?.toString() ?? '');
  final spd = spdNum?.round();
  final timeStr = _fmtNotifTime((n['event_time'] ?? n['created_at'])?.toString());
  if (type == 'deviceOverspeed') {
    final m = RegExp(r'\(الحد[:\s]+(\d+)\)').firstMatch(body);
    final limit = m != null ? int.tryParse(m.group(1) ?? '') : null;
    if (spd != null && limit != null) return 'Overspeed $spd km/h (limit: $limit)';
    if (spd != null) return 'Overspeed $spd km/h';
    return timeStr;
  }
  if (type == 'alarm' && (subtype == 'braking' || subtype == 'harshBraking' || subtype == 'hardBraking')) {
    return spd != null ? 'Harsh braking $spd km/h' : timeStr;
  }
  if (type == 'alarm' && (subtype == 'acceleration' || subtype == 'harshAcceleration' || subtype == 'hardAcceleration')) {
    return spd != null ? 'Harsh acceleration $spd km/h' : timeStr;
  }
  // باقي الأنواع: العنوان معرّب + نعرض الوقت كتفصيل (زي ما العربي كان بيعمل)
  return timeStr;
}

String _fmtNotifTime(String? iso) {
  if (iso == null || iso.isEmpty) return '--';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  final l = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}  ${two(l.hour)}:${two(l.minute)}';
}

// ─── Unified alert detail opener (in-app list tap + FCM tap) ───
// يفتح نفس شاشة AlertDetailScreen المستخدمة في درج تنبيهات الجهاز (خريطة + عنوان)
void openAlertDetailFromNotif(BuildContext context, Map<String, dynamic> n) {
  final type    = (n['type'] ?? '').toString();
  final subtype = n['alarm_subtype']?.toString();
  final label   = notifTypeLabel(type, subtype);
  final color   = notifColorForType(type, subtype);
  final icon    = notifIconForType(type, subtype);
  final timeStr = _fmtNotifTime((n['event_time'] ?? n['created_at'])?.toString());

  final tid = n['traccar_id'] is int ? n['traccar_id'] as int : int.tryParse(n['traccar_id']?.toString() ?? '');
  final did = n['device_id']  is int ? n['device_id']  as int : int.tryParse(n['device_id']?.toString() ?? '');

  // البحث عن الجهاز من الـ provider (للحصول على الاسم/speedLimit/الموقع الاحتياطي)
  final provider = context.read<AppProvider>();
  DeviceModel? dev;
  for (final d in [...provider.devices, ...provider.inventory]) {
    if ((tid != null && d.traccarId == tid) || (did != null && d.id == did)) { dev = d; break; }
  }
  dev ??= DeviceModel.fromJson({
    'id': did ?? 0,
    'traccar_id': tid ?? 0,
    'name': (n['device_name'] ?? n['title'] ?? tr('cl_device_word')).toString(),
    'imei': '',
    'speed_limit': '100',
  });

  final lat = n['lat'] is num ? (n['lat'] as num).toDouble() : double.tryParse(n['lat']?.toString() ?? '');
  final lng = n['lng'] is num ? (n['lng'] as num).toDouble() : double.tryParse(n['lng']?.toString() ?? '');
  final spd = n['speed'] is num ? (n['speed'] as num).toDouble() : double.tryParse(n['speed']?.toString() ?? '');

  // Parse speedLimit from body text "(الحد: X)" — more reliable than device cache
  int resolvedSpeedLimit = dev.speedLimit > 0 ? dev.speedLimit : 100;
  if (type == 'deviceOverspeed') {
    final body = (n['body'] ?? '').toString();
    final limitMatch = RegExp(r'\(الحد[:\s]+(\d+)\)').firstMatch(body);
    if (limitMatch != null) {
      resolvedSpeedLimit = int.tryParse(limitMatch.group(1) ?? '') ?? resolvedSpeedLimit;
    }
  }

  final alert = <String, dynamic>{
    'type': type,
    if (lat != null && (lat != 0 || (lng ?? 0) != 0)) 'lat': lat,
    if (lng != null && ((lat ?? 0) != 0 || lng != 0)) 'lng': lng,
    if (spd != null && spd > 0) 'speed': spd,
    'speedLimit': resolvedSpeedLimit,
  };

  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => AlertDetailScreen(
      alert: alert, device: dev!, label: label, color: color, icon: icon, timeStr: timeStr,
    ),
  ));
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});
  @override State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  // Device notifications (notification_log)
  List<Map<String, dynamic>> _notifs = [];
  int _unreadCount = 0;
  bool _loadingNotifs = true;
  bool _markingAll = false;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    // تحديث فوري عند الضغط على تاب التنبيهات (الشاشة حيّة جوّه IndexedStack فالـ initState مبيتنفذش تاني)
    TabNav.notifTabTick.addListener(_onNotifTabTapped);
  }

  void _onNotifTabTapped() {
    if (mounted) _loadNotifications();
  }

  @override
  void dispose() {
    TabNav.notifTabTick.removeListener(_onNotifTabTapped);
    super.dispose();
  }

  // ─── Notifications API ───────────────────────────────────
  Future<void> _loadNotifications() async {
    setState(() => _loadingNotifs = true);
    try {
      final r = await ApiService.request('get_notifications', {'limit': 100});
      if (mounted && r['success'] == true) {
        setState(() {
          _notifs = (r['notifications'] as List? ?? []).cast<Map<String, dynamic>>();
          _unreadCount = r['unread_count'] is int ? r['unread_count'] : 0;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingNotifs = false);
  }

  Future<void> _markRead(int id) async {
    try {
      await ApiService.request('mark_notification_read', {'id': id});
      if (mounted) setState(() {
        final idx = _notifs.indexWhere((n) => n['id'] == id);
        if (idx >= 0 && _notifs[idx]['read_at'] == null) {
          _notifs[idx]['read_at'] = DateTime.now().toUtc().toIso8601String();
          _unreadCount = (_unreadCount - 1).clamp(0, 99999);
        }
      });
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    if (_unreadCount == 0 || _markingAll) return;
    setState(() => _markingAll = true);
    try {
      final r = await ApiService.request('mark_notification_read', {'all': true});
      if (mounted && r['success'] == true) {
        setState(() {
          final now = DateTime.now().toUtc().toIso8601String();
          for (var n in _notifs) { if (n['read_at'] == null) n['read_at'] = now; }
          _unreadCount = 0;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _markingAll = false);
  }

  void _onNotifTap(Map<String, dynamic> n) {
    final id = n['id'];
    if (id is int && n['read_at'] == null) _markRead(id);
    // رسالة إدارية = إشعار اتجاه واحد → اعرض النص فقط (بدون خريطة/جهاز)
    if ((n['type'] ?? '').toString() == 'message') {
      showDialog(context: context, builder: (dctx) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text((n['title'] ?? tr('an_message')).toString(), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w700)),
          content: Text((n['body'] ?? '').toString(), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, height: 1.5)),
          actions: [TextButton(onPressed: () => Navigator.pop(dctx), child: Text(tr('close'), style: const TextStyle(fontFamily: 'Cairo')))],
        ),
      ));
      return;
    }
    openAlertDetailFromNotif(context, n);
  }

  // ─── Icon + color per event type (delegate to top-level helpers) ───
  IconData _iconForType(String type, String? subtype) => notifIconForType(type, subtype);

  Color _colorForType(String type, String? subtype) => notifColorForType(type, subtype);

  String _timeAgo(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inSeconds < 60) return tr('ago_seconds', {'n': '${diff.inSeconds < 1 ? 1 : diff.inSeconds}'});
    if (diff.inMinutes < 60) return tr('ago_minutes', {'n': '${diff.inMinutes}'});
    if (diff.inHours < 24) return tr('ago_hours', {'n': '${diff.inHours}'});
    if (diff.inDays == 1) return tr('ago_yesterday');
    return tr('ago_days', {'n': '${diff.inDays}'});
  }

  // ─── Notification list UI ────────────────────────────────
  Widget _buildNotifList() {
    if (_loadingNotifs) return const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)));
    if (_notifs.isEmpty) {
      return RefreshIndicator(
        color: const Color(0xFFC41E3A), onRefresh: _loadNotifications,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
          const SizedBox(height: 100),
          Icon(Icons.notifications_none_outlined, size: 56, color: Theme.of(context).dividerColor),
          const SizedBox(height: 14),
          Center(child: Text(tr('no_alerts'), style: const TextStyle(color: Color(0xFF8892A4), fontFamily: 'Cairo'))),
        ]),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFFC41E3A), onRefresh: _loadNotifications,
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: _notifs.length,
        itemBuilder: (_, i) {
          final n = _notifs[i];
          final unread  = n['read_at'] == null;
          final type    = (n['type'] ?? '') as String;
          final subtype = n['alarm_subtype'] as String?;
          final color   = _colorForType(type, subtype);
          final icon    = _iconForType(type, subtype);
          final devName = (n['device_name'] ?? n['title'] ?? '') as String;
          final created = n['created_at'] as String?;

          return InkWell(
            onTap: () => _onNotifTap(n),
            borderRadius: BorderRadius.circular(11),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: unread ? Theme.of(context).colorScheme.errorContainer.withOpacity(0.15) : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: unread ? color.withOpacity(0.25) : Theme.of(context).dividerColor),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(devName,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo'))),
                    Text(_timeAgo(created), style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
                    if (unread) ...[const SizedBox(width: 6),
                      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle))],
                  ]),
                  const SizedBox(height: 3),
                  Text(notifTypeLabel(type, subtype),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color, fontFamily: 'Cairo')),
                  const SizedBox(height: 2),
                  Text(notifBodyText(n, type, subtype), style: const TextStyle(fontSize: 11, color: Color(0xFF555F6E), fontFamily: 'Cairo', height: 1.4)),
                ])),
              ]),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // تاب التنبيهات صار مخصصاً فقط لتنبيهات الأجهزة (الرسائل انتقلت إلى "حسابي")
    return Column(children: [
      if (_unreadCount > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            onPressed: _markingAll ? null : _markAllRead,
            icon: _markingAll
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.done_all, size: 16),
            label: Text(tr('mark_all_read'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 11)),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFC41E3A)),
          )),
        ),
      Expanded(child: _buildNotifList()),
    ]);
  }
}

// ============================================================
// AccountScreen
// ============================================================

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  bool _saving = false;
  bool _isDirty = false;
  Color? _avatarBg;
  String? _localAvatarUrl; // يتحدث فوراً بعد الرفع

  void _markDirty() => setState(() => _isDirty = true);

  @override
  void initState() {
    super.initState();
    final user = context.read<AppProvider>().currentUser;
    if (user != null) {
      _nameCtrl.text = user.fullName;
      _phoneCtrl.text = user.phone ?? '';
      _mobileCtrl.text = user.mobile ?? '';
      _emailCtrl.text = user.email ?? '';
      _addressCtrl.text = user.address ?? '';
    }
    // track changes
    _nameCtrl.addListener(_markDirty);
    _phoneCtrl.addListener(_markDirty);
    _mobileCtrl.addListener(_markDirty);
    _emailCtrl.addListener(_markDirty);
    _addressCtrl.addListener(_markDirty);
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_markDirty);
    _phoneCtrl.removeListener(_markDirty);
    _mobileCtrl.removeListener(_markDirty);
    _emailCtrl.removeListener(_markDirty);
    _addressCtrl.removeListener(_markDirty);
    _nameCtrl.dispose(); _phoneCtrl.dispose(); _mobileCtrl.dispose();
    _emailCtrl.dispose(); _addressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final user = provider.currentUser;
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFFC41E3A), Color(0xFF8A0F22)], begin: Alignment.topRight, end: Alignment.bottomLeft),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
            child: Column(children: [
              // Save button row (only when dirty)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: _isDirty ? 36 : 0,
                child: _isDirty ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  ElevatedButton(
                    onPressed: _saving ? null : () async { await _save(); setState(() => _isDirty = false); },
                    style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.surface, foregroundColor: const Color(0xFFC41E3A), elevation: 0, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Color(0xFFC41E3A), strokeWidth: 2)) : Text(tr('save'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ]) : const SizedBox.shrink(),
              ),
              const SizedBox(height: 8),
              // Profile row - bigger
              Row(children: [
                GestureDetector(
                  onTap: () => _changeAvatarColor(context),
                  child: Stack(children: [
                    _UserAvatar(avatarUrl: _localAvatarUrl ?? user?.avatarUrl, initials: user?.initials ?? 'U', radius: 38, bgColor: _avatarBg ?? Colors.white.withOpacity(0.2)),
                    Positioned(bottom: 0, right: 0, child: Container(width: 20, height: 20, decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle), child: const Icon(Icons.edit, size: 12, color: Colors.white))),
                  ])),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(user?.fullName ?? '', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
                  const SizedBox(height: 2),
                  Text('${user?.accountTypeAr ?? ''} - ${user?.username ?? ''}',
                      style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11, fontFamily: 'Cairo')),
                ])),
              ]),
              const SizedBox(height: 4),
            ]),
          ),
          _FieldCard(children: [
            _FieldRow(label: tr('username'), controller: TextEditingController(text: user?.username), readOnly: true, copyable: true),
            _FieldRow(label: tr('acc_name'), controller: _nameCtrl),
            _FieldRow(label: tr('acc_contact'), controller: _phoneCtrl, keyboard: TextInputType.phone),
            _FieldRow(label: tr('acc_mobile'), controller: _mobileCtrl, keyboard: TextInputType.phone),
            _FieldRow(label: tr('acc_email'), controller: _emailCtrl, keyboard: TextInputType.emailAddress),
            _FieldRow(label: tr('acc_address'), controller: _addressCtrl, isLast: true),
          ]),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(alignment: I18n.isAr ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(tr('acc_general'), style: const TextStyle(color: Color(0xFF8892A4), fontSize: 10, fontWeight: FontWeight.w500, fontFamily: 'Cairo')))),
          const SizedBox(height: 5),
          _ActionCard(items: [
            _ActionItem(icon: Icons.forum_outlined, label: tr('acc_messages'), color: const Color(0xFF2563EB), bg: const Color(0x1A2563EB), onTap: () => _openAccountMessages(context)),
            if (context.read<AppProvider>().currentUser?.accountType == 'admin' || context.read<AppProvider>().currentUser?.accountType == 'dealer')
              _ActionItem(icon: Icons.campaign_outlined, label: tr('bc_title'), color: const Color(0xFF0891B2), bg: const Color(0x1A0891B2), onTap: () => _openBroadcast(context)),
            if (context.read<AppProvider>().currentUser?.accountType != 'client')
              _ActionItem(icon: Icons.credit_card_outlined, label: tr('cn_title'), color: const Color(0xFF7C3AED), bg: const Color(0x1A7C3AED), onTap: () => _openCardNotifications(context)),
            _ActionItem(icon: Icons.notifications_active_outlined, label: tr('np_title'), color: const Color(0xFF6BA539), bg: const Color(0x1A6BA539), onTap: () => _openNotifPref(context)),
            _ActionItem(icon: Icons.schedule_outlined, label: tr('ae_title'), color: const Color(0xFFEF6C00), bg: const Color(0x1AEF6C00), onTap: () {
              final uid = context.read<AppProvider>().currentUser?.id;
              if (uid != null) openAutoEngine(context, uid);
            }),
            _ActionItem(icon: Icons.lock_outline, label: tr('acc_change_pw'), color: const Color(0xFFC41E3A), bg: const Color(0x1AC41E3A), onTap: () => _changePassword(context)),
            // الجلسة تعيش سنة، فلا بد أن يرى صاحب الحساب أجهزته. والعميل يرى فقط —
            // لا شيء يميّز جهاز المالك من غيره، فالإخراج بيد المزوّد (والسيرفر يفرضه).
            _ActionItem(icon: Icons.devices_outlined, label: tr('ses_title'), color: const Color(0xFF0D9488), bg: const Color(0x1A0D9488), onTap: () => openSessions(context,
                canRevoke: context.read<AppProvider>().currentUser?.accountType != 'client')),
            if (context.read<AppProvider>().currentUser?.accountType != 'client')
              _ActionItem(icon: Icons.sync_outlined, label: tr('acc_change_imei'), color: const Color(0xFFF59E0B), bg: const Color(0x1AF59E0B), onTap: () => _changeImei(context)),
            _ActionItem(icon: Icons.language_outlined, label: tr('acc_app_lang'), color: const Color(0xFF0891B2), bg: const Color(0x1A0891B2), onTap: () => _changeLanguage(context)),
            _ActionItem(icon: Icons.dark_mode_outlined, label: tr('acc_theme'), color: const Color(0xFF7C3AED), bg: const Color(0x1A7C3AED), onTap: () => _changeTheme(context)),
            _ActionItem(icon: Icons.share_outlined, label: tr('acc_share'), color: const Color(0xFF6BA539), bg: const Color(0x1A6BA539), onTap: () => _shareApp(context)),
            if (context.read<AppProvider>().currentUser?.accountType != 'admin')
              _ActionItem(icon: Icons.support_agent_outlined, label: tr('acc_provider'), color: const Color(0xFF7C3AED), bg: const Color(0x1A7C3AED), onTap: () => _showServiceProvider(context)),
          ]),
          const SizedBox(height: 8),
          _ActionCard(items: [
            _ActionItem(icon: Icons.logout, label: tr('logout'), color: const Color(0xFFC41E3A), bg: Colors.transparent, onTap: _logout, center: true),
          ]),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _showServiceProvider(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const ServiceProviderScreen()));
  }

  // ─── موزّع: العميل = محادثة مزود الخدمة، الأدمن/الديلر = قائمة محادثات ───
  void _openAccountMessages(BuildContext context) {
    final u = context.read<AppProvider>().currentUser;
    if (u != null && (u.accountType == 'admin' || u.accountType == 'dealer' || u.accountType == 'sub_dealer')) {
      _openMessagesHub(context);
    } else {
      _openProviderMessages(context);
    }
  }

  static String _fmtMsgTime(dynamic raw) {
    final s = (raw ?? '').toString();
    if (s.length < 16) return s;
    // "2026-06-04 14:22:00" → "2026-06-04 14:22"
    return s.substring(0, 16).replaceAll('T', ' ');
  }

  // ─── إشعارات البطاقات (واردة/مرسلة) — messages table type=notification ───
  void _openCardNotifications(BuildContext context) {
    List<Map<String, dynamic>> notifs = [];
    bool loading = true;
    String box = 'in'; // in = الواردة، out = المرسلة

    Future<void> loadNotifs(StateSetter setS) async {
      setS(() => loading = true);
      try {
        final r = await ApiService.request('get_messages', {'box': 'inbox', 'kind': 'notification'});
        final raw = (r['messages'] as List? ?? []).cast<Map<String, dynamic>>();
        final list = raw.map((m) {
          final body = (m['body'] ?? '').toString();
          return {
            ...m,
            '_dir': body.contains('رصيدك') ? 'in' : 'out',
            '_who': (m['sender_name'] ?? tr('mh_admin')).toString(),
          };
        }).toList()
          ..sort((a, b) => (b['created_at'] ?? '').toString().compareTo((a['created_at'] ?? '').toString()));
        setS(() { notifs = list; loading = false; });
        ApiService.request('mark_messages_read', {'kind': 'notification'});
      } catch (_) { setS(() => loading = false); }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (loading && notifs.isEmpty) loadNotifs(setS);
        final shown = notifs.where((n) => n['_dir'] == box).toList();
        Widget tabBtn(String key, String label) {
          final active = box == key;
          return Expanded(child: GestureDetector(
            onTap: () => setS(() => box = key),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: active ? const Color(0xFF7C3AED) : const Color(0xFFF1F2F6),
                borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.center,
              child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: active ? Colors.white : const Color(0xFF8892A4))),
            ),
          ));
        }
        return DraggableScrollableSheet(
          initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
          builder: (_, sc) => Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
                Text(tr('cn_title'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => loadNotifs(setS)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(children: [tabBtn('in', tr('cn_received')), tabBtn('out', tr('cn_sent'))])),
              const Divider(height: 1),
              Expanded(child: loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                  : shown.isEmpty
                      ? Center(child: Text(tr('cn_empty'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                      : ListView.separated(
                          controller: sc,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                          itemBuilder: (_, i) {
                            final n = shown[i];
                            return ListTile(
                              leading: CircleAvatar(radius: 18, backgroundColor: const Color(0x1A7C3AED), child: const Icon(Icons.credit_card_outlined, size: 18, color: Color(0xFF7C3AED))),
                              title: Text((box == 'out' ? '→ ' : '') + (n['_who'] as String), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text((n['body'] ?? '').toString(), style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Color(0xFF6B7280))),
                              trailing: Text(_fmtMsgTime(n['created_at']), style: const TextStyle(fontFamily: 'Cairo', fontSize: 9, color: Color(0xFF8892A4))),
                            );
                          },
                        )),
            ]),
          ),
        );
      }),
    );
  }

  // ─── رسالة جماعية (الأدمن→ديلرات / الديلر→موزعين) ───────────
  void _openBroadcast(BuildContext context) {
    final msgCtrl = TextEditingController();
    List<Map<String, dynamic>> targets = [];
    final Set<String> sel = {};
    bool loading = true, sending = false;
    bool started = false;

    // كل الحسابات اللي تحت المستخدم (مفلترة على السيرفر بـ get_users) — مش نوع واحد بس.
    Future<void> loadTargets(StateSetter setS, [int attempt = 0]) async {
      if (attempt == 0) setS(() => loading = true);
      try {
        final r = await ApiService.request('get_users', {});
        final arr = ((r['data'] ?? r['users']) as List? ?? []).cast<Map<String, dynamic>>();
        setS(() {
          targets = arr;
          loading = false;
        });
      } catch (_) {
        if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return loadTargets(setS, attempt + 1); }
        setS(() => loading = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!started) { started = true; WidgetsBinding.instance.addPostFrameCallback((_) => loadTargets(setS)); }
        final allSelected = sel.length == targets.length && targets.isNotEmpty;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
            expand: false,
            builder: (_, sc) => Container(
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
              child: Column(children: [
                Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
                  Text(tr('bc_title'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                ])),
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Row(children: [
                  Text(tr('bc_recipients'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF8892A4))),
                  const Spacer(),
                  TextButton(
                    onPressed: targets.isEmpty ? null : () => setS(() { if (allSelected) { sel.clear(); } else { sel..clear()..addAll(targets.map((u) => u['id'].toString())); } }),
                    child: Text(tr('bc_select_all'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
                  ),
                ])),
                Expanded(child: loading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                    : targets.isEmpty
                        ? Center(child: Text(tr('bc_no_recipients'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                        : ListView.builder(
                            controller: sc,
                            itemCount: targets.length,
                            itemBuilder: (_, i) {
                              final u = targets[i];
                              final id = u['id'].toString();
                              final name = (u['full_name'] ?? u['name'] ?? u['username'] ?? '').toString();
                              return CheckboxListTile(
                                value: sel.contains(id),
                                onChanged: (v) => setS(() { if (v == true) { sel.add(id); } else { sel.remove(id); } }),
                                title: Text(name, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                                activeColor: const Color(0xFFC41E3A),
                                controlAffinity: ListTileControlAffinity.leading,
                                dense: true,
                              );
                            },
                          )),
                Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 12), child: Row(children: [
                  Expanded(child: TextField(
                    controller: msgCtrl,
                    maxLines: 2, minLines: 1, maxLength: 300,
                    decoration: InputDecoration(
                      hintText: tr('bc_msg_hint'),
                      hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
                  )),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: (sending || targets.isEmpty) ? null : () async {
                      if (msgCtrl.text.trim().isEmpty) return;
                      setS(() => sending = true);
                      final all = sel.isEmpty || sel.length == targets.length;
                      try {
                        await ApiService.request('send_broadcast', all
                            ? {'body': msgCtrl.text.trim(), 'target': 'all'}
                            : {'body': msgCtrl.text.trim(), 'target': 'some', 'recipients': sel.toList()});
                      } catch (_) {}
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('bc_sent'), style: const TextStyle(fontFamily: 'Cairo'))));
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC41E3A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                    child: sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send, size: 18, color: Colors.white),
                  ),
                ])),
              ]),
            ),
          ),
        );
      }),
    );
  }

  // ─── تفضيل ظهور الإشعارات في درج الموبايل (مفتاح عام) ───────────
  void _openNotifPref(BuildContext context) {
    bool enabled = true;
    bool loading = true;

    Future<void> loadPref(StateSetter setS) async {
      try {
        final r = await ApiService.request('get_notif_pref', {});
        setS(() { enabled = (r['enabled'] == 1 || r['enabled'] == true); loading = false; });
      } catch (_) { setS(() => loading = false); }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (loading) loadPref(setS);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(alignment: Alignment.center, child: Container(margin: const EdgeInsets.only(bottom: 14), width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            Text(tr('np_title'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(tr('np_desc'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF8892A4))),
            const SizedBox(height: 12),
            loading
                ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(color: Color(0xFFC41E3A))))
                : SwitchListTile(
                    value: enabled,
                    activeColor: const Color(0xFF6BA539),
                    contentPadding: EdgeInsets.zero,
                    title: Text(I18n.isAr ? (enabled ? 'مفعّل' : 'معطّل') : (enabled ? 'On' : 'Off'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                    onChanged: (v) async {
                      setS(() => enabled = v);
                      try { await ApiService.request('set_notif_pref', {'enabled': v ? 1 : 0}); } catch (_) {}
                    },
                  ),
          ]),
        );
      }),
    );
  }

  // ─── قائمة المحادثات (الأدمن/الديلر) — مجمّعة لكل طرف ───────────
  void _openMessagesHub(BuildContext context) {
    final myId = context.read<AppProvider>().currentUser?.id.toString();
    List<Map<String, dynamic>> convs = [];
    bool loading = true;
    bool started = false;

    Future<void> loadConvs(StateSetter setS, [int attempt = 0]) async {
      if (attempt == 0) setS(() => loading = true);
      try {
        final inb = await ApiService.request('get_messages', {'box': 'inbox'});
        final snt = await ApiService.request('get_messages', {'box': 'sent'});
        final all = <Map<String, dynamic>>[
          ...((inb['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
          ...((snt['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
        ];
        // اجمع حسب الطرف الآخر
        final byParty = <String, Map<String, dynamic>>{};
        for (final m in all) {
          final sid = (m['sender_id'] ?? '').toString();
          final rid = (m['receiver_id'] ?? '').toString();
          final isMine = sid == myId;
          final otherId = isMine ? rid : sid;
          if (otherId.isEmpty || otherId == 'null') continue;
          final otherName = isMine
              ? (m['receiver_name'] ?? tr('mh_admin')).toString()
              : (m['sender_name'] ?? tr('mh_admin')).toString();
          final created = (m['created_at'] ?? '').toString();
          final existing = byParty[otherId];
          final isUnread = !isMine && (m['is_read']?.toString() == '0');
          if (existing == null || created.compareTo(existing['last_time'].toString()) > 0) {
            byParty[otherId] = {
              'id': otherId,
              'name': otherName,
              'last_body': (m['body'] ?? '').toString(),
              'last_time': created,
              'last_is_mine': isMine,
              'unread': (existing?['unread'] == true) || isUnread,
            };
          } else if (isUnread) {
            existing['unread'] = true;
          }
        }
        final list = byParty.values.toList()
          ..sort((a, b) => b['last_time'].toString().compareTo(a['last_time'].toString()));
        setS(() { convs = list; loading = false; });
      } catch (_) {
        if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return loadConvs(setS, attempt + 1); }
        setS(() => loading = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!started) { started = true; WidgetsBinding.instance.addPostFrameCallback((_) => loadConvs(setS)); }
        return DraggableScrollableSheet(
          initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
          builder: (_, sc) => Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
                Text(tr('mh_title'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => loadConvs(setS)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ])),
              const Divider(height: 1),
              Expanded(child: loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                  : convs.isEmpty
                      ? Center(child: Text(tr('mh_empty'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                      : ListView.separated(
                          controller: sc,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: convs.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                          itemBuilder: (_, i) {
                            final c = convs[i];
                            final mine = c['last_is_mine'] == true;
                            return ListTile(
                              leading: CircleAvatar(radius: 20, backgroundColor: const Color(0xFF2563EB), child: Text((c['name'] as String).isNotEmpty ? (c['name'] as String)[0] : '?', style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                              title: Text(c['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text((mine ? tr('mh_you') : '') + (c['last_body'] as String), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Color(0xFF8892A4))),
                              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(_fmtMsgTime(c['last_time']).length >= 16 ? _fmtMsgTime(c['last_time']).substring(11) : '', style: const TextStyle(fontFamily: 'Cairo', fontSize: 9, color: Color(0xFF8892A4))),
                                if (c['unread'] == true) ...[const SizedBox(height: 4), Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFC41E3A), shape: BoxShape.circle))],
                              ]),
                              onTap: () => _openConversation(context, c['id'].toString(), c['name'] as String),
                            );
                          },
                        )),
            ]),
          ),
        );
      }),
    );
  }

  // ─── محادثة مخصّصة مع طرف واحد ───────────────────────────────
  void _openConversation(BuildContext context, String partyId, String partyName) {
    final sendCtrl = TextEditingController();
    final myId = context.read<AppProvider>().currentUser?.id.toString();
    List<Map<String, dynamic>> msgs = [];
    bool loading = true, sending = false;
    bool started = false;

    Future<void> loadConv(StateSetter setS, [int attempt = 0]) async {
      if (attempt == 0) setS(() => loading = true);
      try {
        final inb = await ApiService.request('get_messages', {'box': 'inbox'});
        final snt = await ApiService.request('get_messages', {'box': 'sent'});
        final all = <Map<String, dynamic>>[
          ...((inb['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
          ...((snt['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
        ];
        final conv = all.where((m) {
          final sid = (m['sender_id'] ?? '').toString();
          final rid = (m['receiver_id'] ?? '').toString();
          return sid == partyId || rid == partyId;
        }).toList();
        final seen = <String>{};
        final dedup = <Map<String, dynamic>>[];
        for (final m in conv) {
          final k = (m['id'] ?? '${m['sender_id']}_${m['receiver_id']}_${m['created_at']}').toString();
          if (seen.add(k)) dedup.add(m);
        }
        dedup.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
        setS(() { msgs = dedup.reversed.toList(); loading = false; });
        // علّم رسائل هذه المحادثة كمقروءة (يبقي عدّاد غير المقروء دقيقاً)
        ApiService.request('mark_messages_read', {'peer_id': partyId});
      } catch (_) {
        if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return loadConv(setS, attempt + 1); }
        setS(() => loading = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!started) { started = true; WidgetsBinding.instance.addPostFrameCallback((_) => loadConv(setS)); }
        return DraggableScrollableSheet(
          initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
          builder: (_, sc) => Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
                CircleAvatar(radius: 17, backgroundColor: const Color(0xFF2563EB), child: Text(partyName.isNotEmpty ? partyName[0] : '?', style: const TextStyle(color: Colors.white, fontFamily: 'Cairo', fontWeight: FontWeight.bold))),
                const SizedBox(width: 10),
                Expanded(child: Text(partyName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => loadConv(setS)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ])),
              const Divider(height: 1),
              Expanded(child: loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                  : msgs.isEmpty
                      ? Center(child: Text(tr('mh_conv_empty'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                      : ListView.builder(
                          controller: sc, padding: const EdgeInsets.all(12), reverse: true, itemCount: msgs.length,
                          itemBuilder: (_, i) {
                            final m = msgs[i];
                            final isMe = (m['sender_id'] ?? '').toString() == myId;
                            return Align(
                              alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.75),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFFC41E3A) : Theme.of(context).scaffoldBackgroundColor,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(12), topRight: const Radius.circular(12),
                                    bottomLeft: Radius.circular(isMe ? 0 : 12), bottomRight: Radius.circular(isMe ? 12 : 0),
                                  ),
                                ),
                                child: Column(crossAxisAlignment: isMe ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: [
                                  Text(m['body'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface)),
                                  const SizedBox(height: 3),
                                  Text(_fmtMsgTime(m['created_at']), style: TextStyle(fontFamily: 'Cairo', fontSize: 8, color: isMe ? Colors.white70 : const Color(0xFF8892A4))),
                                ]),
                              ),
                            );
                          },
                        )),
              Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + MediaQuery.of(ctx).viewInsets.bottom),
                child: Row(children: [
                  Expanded(child: TextField(
                    controller: sendCtrl,
                    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: tr('pm_hint'), hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                      filled: true, fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  )),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: sending ? null : () async {
                      if (sendCtrl.text.trim().isEmpty) return;
                      setS(() => sending = true);
                      await ApiService.request('send_message', {'body': sendCtrl.text.trim(), 'receiver_id': partyId});
                      sendCtrl.clear();
                      setS(() => sending = false);
                      loadConv(setS);
                    },
                    child: Container(
                      width: 40, height: 40,
                      decoration: const BoxDecoration(color: Color(0xFFC41E3A), shape: BoxShape.circle),
                      child: sending
                          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)))
                          : const Icon(Icons.send, color: Colors.white, size: 18),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        );
      }),
    );
  }

  // ─── رسائل العميل مع مزود الخدمة (محادثة) ───────────────────
  void _openProviderMessages(BuildContext context) {
    final sendCtrl = TextEditingController();
    List<Map<String, dynamic>> msgs = [];
    Map<String, dynamic>? provider;
    bool loading = true, sending = false;
    bool started = false;

    Future<void> loadAll(StateSetter setS, [int attempt = 0]) async {
      if (attempt == 0) setS(() => loading = true);
      try {
        final pr = await ApiService.request('get_provider', {});
        provider = (pr['provider'] as Map?)?.cast<String, dynamic>();
        final inb = await ApiService.request('get_messages', {'box': 'inbox'});
        final snt = await ApiService.request('get_messages', {'box': 'sent'});
        final me = context.read<AppProvider>().currentUser?.id.toString();
        final pid = provider?['id']?.toString();
        // ادمج الوارد + المُرسَل — العميل يحادث مزود الخدمة (الديلر) فقط
        final conv = <Map<String, dynamic>>[
          ...((inb['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
          ...((snt['messages'] as List? ?? []).cast<Map<String, dynamic>>()),
        ];
        final seen = <String>{};
        final dedup = <Map<String, dynamic>>[];
        for (final m in conv) {
          final sid = m['sender_id']?.toString();
          final rid = m['receiver_id']?.toString();
          // استبعد أي رسالة مش بين العميل ومزود الخدمة (رسائل الأدمن تيجي كإشعار مش شات قابل للرد)
          if (pid != null && !((sid == pid && rid == me) || (sid == me && rid == pid))) continue;
          final k = (m['id'] ?? '${m['sender_id']}_${m['receiver_id']}_${m['created_at']}').toString();
          if (seen.add(k)) dedup.add(m);
        }
        dedup.sort((a, b) => (a['created_at'] ?? '').toString().compareTo((b['created_at'] ?? '').toString()));
        setS(() { msgs = dedup.reversed.toList(); loading = false; });
        // العميل يحادث مزود الخدمة فقط → علّم الوارد منه كمقروء
        if (pid != null) ApiService.request('mark_messages_read', {'peer_id': pid});
      } catch (_) {
        if (attempt < 2) { await Future.delayed(const Duration(milliseconds: 600)); return loadAll(setS, attempt + 1); }
        setS(() => loading = false);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        if (!started) { started = true; WidgetsBinding.instance.addPostFrameCallback((_) => loadAll(setS)); }
        final providerName = provider?['full_name'] ?? provider?['username'] ?? tr('pm_provider');
        return DraggableScrollableSheet(
          initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
          builder: (_, sc) => Container(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(children: [
              Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
                Container(width: 34, height: 34, decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle), child: const Icon(Icons.support_agent, color: Colors.white, size: 18)),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(providerName, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(tr('pm_provider'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Color(0xFF8892A4))),
                ])),
                IconButton(icon: const Icon(Icons.refresh), onPressed: () => loadAll(setS)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ])),
              const Divider(height: 1),
              Expanded(child: loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A)))
                  : msgs.isEmpty
                      ? Center(child: Text(tr('pm_empty'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))))
                      : ListView.builder(
                          controller: sc,
                          padding: const EdgeInsets.all(12),
                          reverse: true,
                          itemCount: msgs.length,
                          itemBuilder: (_, i) {
                            final m = msgs[i];
                            final isMe = m['sender_id']?.toString() == context.read<AppProvider>().currentUser?.id.toString();
                            return Align(
                              alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.75),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFFC41E3A) : Theme.of(context).scaffoldBackgroundColor,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(12), topRight: const Radius.circular(12),
                                    bottomLeft: Radius.circular(isMe ? 0 : 12), bottomRight: Radius.circular(isMe ? 12 : 0),
                                  ),
                                ),
                                child: Text(m['body'] ?? '', style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface)),
                              ),
                            );
                          },
                        )),
              Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + MediaQuery.of(ctx).viewInsets.bottom),
                child: Row(children: [
                  Expanded(child: TextField(
                    controller: sendCtrl,
                    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: tr('pm_hint'), hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
                      filled: true, fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  )),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: sending ? null : () async {
                      if (sendCtrl.text.trim().isEmpty) return;
                      setS(() => sending = true);
                      // العميل يراسل مزود الخدمة (الديلر) فقط — ممنوع مراسلة الأدمن
                      final payload = <String, dynamic>{'body': sendCtrl.text.trim()};
                      if (provider?['id'] != null) payload['receiver_id'] = provider!['id'];
                      await ApiService.request('send_message', payload);
                      sendCtrl.clear();
                      setS(() => sending = false);
                      loadAll(setS);
                    },
                    child: Container(
                      width: 40, height: 40,
                      decoration: const BoxDecoration(color: Color(0xFFC41E3A), shape: BoxShape.circle),
                      child: sending
                          ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)))
                          : const Icon(Icons.send, color: Colors.white, size: 18),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await context.read<AppProvider>().updateProfile(
      fullName: _nameCtrl.text.trim(), phone: _phoneCtrl.text.trim(),
      mobile: _mobileCtrl.text.trim(), email: _emailCtrl.text.trim(), address: _addressCtrl.text.trim(),
    );
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? tr('cl_data_saved') : tr('cl_save_failed'), style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: ok ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
      ));
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('cl_logout_title'), style: const TextStyle(fontFamily: 'Cairo')),
        content: Text(tr('cl_logout_q'), style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('cl_logout_btn'), style: const TextStyle(color: Color(0xFFC41E3A), fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await context.read<AppProvider>().logout();
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    }
  }
}

// ============================================================
// ServiceProviderScreen — صفحة مزود الخدمة كاملة
// ============================================================

class ServiceProviderScreen extends StatefulWidget {
  const ServiceProviderScreen({super.key});
  @override
  State<ServiceProviderScreen> createState() => _ServiceProviderScreenState();
}

class _ServiceProviderScreenState extends State<ServiceProviderScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = ApiService.request('get_provider');
  }

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        await launchUrl(uri);
      } catch (_) {}
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr('sp_copied'), style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: const Color(0xFF6BA539), duration: const Duration(seconds: 1),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1120),
        appBar: AppBar(
          backgroundColor: const Color(0xFF7C3AED),
          title: Text(tr('sp_title'), style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        ),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(color: Color(0xFF7C3AED)));
            }
            final p = snap.data ?? {};
            final name = (p['name'] ?? '').toString().isNotEmpty ? p['name'].toString() : 'Himaya Track';
            final phone = (p['phone'] ?? '').toString();
            final email = (p['email'] ?? '').toString();
            final website = (p['website'] ?? '').toString();
            final rawAvatar = (p['avatar'] ?? '').toString();
            final avatar = rawAvatar.length > 1
                ? (rawAvatar.startsWith('http') ? rawAvatar : 'https://himaya-track.com$rawAvatar')
                : '';
            final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
            return SingleChildScrollView(
              child: Column(children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 28),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)], begin: Alignment.topRight, end: Alignment.bottomLeft),
                  ),
                  child: Column(children: [
                    _UserAvatar(avatarUrl: avatar.isNotEmpty ? avatar : null, initials: initials, radius: 48, bgColor: const Color(0xFFC0392B)),
                    const SizedBox(height: 12),
                    Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Cairo')),
                    const SizedBox(height: 4),
                    Text(tr('sp_title'), style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12, fontFamily: 'Cairo')),
                  ]),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(children: [
                    _ProviderRow(icon: Icons.business_outlined, label: tr('sp_name'), value: name, onCopy: () => _copy(name)),
                    _ProviderRow(icon: Icons.chat, iconWidget: SvgPicture.string(_kWhatsappSvg, width: 20, height: 20), label: tr('sp_whatsapp'), value: phone.isNotEmpty ? phone : tr('sp_not_set'),
                      onTap: phone.isNotEmpty ? () => _launch('https://wa.me/${phone.replaceAll(RegExp(r'[^0-9]'), '').replaceFirst(RegExp(r'^0+'), '')}') : null,
                      onCopy: phone.isNotEmpty ? () => _copy(phone) : null),
                    _ProviderRow(icon: Icons.email_outlined, label: tr('sp_email'), value: email.isNotEmpty ? email : tr('sp_not_set'),
                      onTap: email.isNotEmpty ? () => _launch('mailto:$email') : null,
                      onCopy: email.isNotEmpty ? () => _copy(email) : null),
                    _ProviderRow(icon: Icons.language_outlined, label: tr('sp_website'), value: website.isNotEmpty ? website : tr('sp_not_set'),
                      onTap: website.isNotEmpty ? () => _launch(website.startsWith('http') ? website : 'https://$website') : null,
                      onCopy: website.isNotEmpty ? () => _copy(website) : null),
                  ]),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

const String _kWhatsappSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#25D366"><path d="M.057 24l1.687-6.163c-1.041-1.804-1.588-3.849-1.587-5.946.003-6.556 5.338-11.891 11.893-11.891 3.181.001 6.167 1.24 8.413 3.488 2.245 2.248 3.481 5.236 3.48 8.414-.003 6.557-5.338 11.892-11.893 11.892-1.99-.001-3.951-.5-5.688-1.448l-6.305 1.654zm6.597-3.807c1.676.995 3.276 1.591 5.392 1.592 5.448 0 9.886-4.434 9.889-9.885.002-5.462-4.415-9.89-9.881-9.892-5.452 0-9.887 4.434-9.889 9.884-.001 2.225.651 3.891 1.746 5.634l-.999 3.648 3.742-.981zm11.387-5.464c-.074-.124-.272-.198-.57-.347-.297-.149-1.758-.868-2.031-.967-.272-.099-.47-.149-.669.149-.198.297-.768.967-.941 1.165-.173.198-.347.223-.644.074-.297-.149-1.255-.462-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.297-.347.446-.521.151-.172.2-.296.3-.495.099-.198.05-.372-.025-.521-.075-.148-.669-1.611-.916-2.206-.242-.579-.487-.501-.669-.51l-.57-.01c-.198 0-.52.074-.792.372s-1.04 1.016-1.04 2.479 1.065 2.876 1.213 3.074c.149.198 2.095 3.2 5.076 4.487.709.306 1.263.489 1.694.626.712.226 1.36.194 1.872.118.571-.085 1.758-.719 2.006-1.413.248-.695.248-1.29.173-1.414z"/></svg>';

class _ProviderRow extends StatelessWidget {
  final IconData icon;
  final Widget? iconWidget;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;
  const _ProviderRow({required this.icon, this.iconWidget, required this.label, required this.value, this.onTap, this.onCopy});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withOpacity(0.06))),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            Container(width: 34, height: 34, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0x1A7C3AED), borderRadius: BorderRadius.circular(8)), child: iconWidget ?? Icon(icon, color: const Color(0xFF7C3AED), size: 18)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11, fontFamily: 'Cairo')),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(color: onTap != null ? const Color(0xFF93C5FD) : Colors.white, fontSize: 13, fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
            ])),
            if (onCopy != null) IconButton(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined, color: Color(0xFF7C3AED), size: 18),
              tooltip: tr('sp_copy'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ============================================================
// SplashScreen
// ============================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Optimistic startup:
  /// 1. Try cache-only init (no network) — < 100ms typically
  /// 2. If cached session exists → navigate to /main IMMEDIATELY
  /// 3. validateAndRefreshInBackground runs after navigation (no blocking)
  /// 4. If no cache → fallback to LoginScreen
  Future<void> _init() async {
    if (!mounted) return;
    final provider = context.read<AppProvider>();

    // 1. Cache-only init (instantaneous)
    final hasCachedSession = await provider.initFromCache();

    if (!mounted) return;

    if (hasCachedSession) {
      // 2. Navigate to /main immediately — UI built with cached data
      Navigator.pushReplacementNamed(context, '/main');
      // 3. Validate + refresh in background (doesn't block UI)
      provider.validateAndRefreshInBackground();
    } else {
      // No cached session → login
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: const Color(0xFFC41E3A),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: size.width * 0.52,
              height: size.width * 0.52,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(32),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 8))]),
              padding: const EdgeInsets.all(20),
              child: Image.asset('assets/images/logo.png', fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.location_on, color: Color(0xFFC41E3A), size: 80)),
            ),
            const SizedBox(height: 24),
            const Text('H.TRACK', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800, fontFamily: 'Cairo', letterSpacing: 3)),
            const SizedBox(height: 56),
            const CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LoginScreen
// ============================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  bool _obscure = true;
  List<String> _recentUsernames = [];

  static const String _kRecentUsersKey = 'recent_usernames';
  static const int _kMaxRecent = 3;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kRecentUsersKey) ?? [];
    if (mounted) setState(() => _recentUsernames = list);
  }

  Future<void> _saveRecent(String username) async {
    if (username.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_kRecentUsersKey) ?? []);
    list.removeWhere((u) => u == username);
    list.insert(0, username);
    while (list.length > _kMaxRecent) { list.removeLast(); }
    await prefs.setStringList(_kRecentUsersKey, list);
    if (mounted) setState(() => _recentUsernames = list);
  }

  Future<void> _removeRecent(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_kRecentUsersKey) ?? []);
    list.removeWhere((u) => u == username);
    await prefs.setStringList(_kRecentUsersKey, list);
    if (mounted) setState(() => _recentUsernames = list);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFFC41E3A), Color(0xFF8A0F22)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top - MediaQuery.of(context).padding.bottom - 48),
              child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 100, height: 100,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                  padding: const EdgeInsets.all(6),
                  alignment: Alignment.center,
                  child: Image.asset('assets/images/logo.png', fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(Icons.location_on, color: Color(0xFFC41E3A), size: 55)),
                ),
                const SizedBox(height: 16),
                const Text('H.TRACK', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, fontFamily: 'Cairo', letterSpacing: 2)),
                const SizedBox(height: 36),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16)),
                  child: provider.needsPasswordChange ? _buildPwChangeColumn(provider) : provider.needsTwoFactor ? _buildOtpColumn(provider) : Column(
                    children: [
                      TextField(
                        controller: _userCtrl,
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          hintText: tr('username'),
                          prefixIcon: const Icon(Icons.person_outline),
                          suffixIcon: _recentUsernames.isEmpty
                              ? null
                              : PopupMenuButton<String>(
                                  icon: const Icon(Icons.arrow_drop_down, color: Color(0xFFC41E3A), size: 28),
                                  tooltip: tr('recent_accounts'),
                                  position: PopupMenuPosition.under,
                                  color: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  onSelected: (u) {
                                    setState(() {
                                      _userCtrl.text = u;
                                      _passCtrl.clear();
                                    });
                                  },
                                  itemBuilder: (_) => _recentUsernames.map((u) => PopupMenuItem<String>(
                                        value: u,
                                        height: 40,
                                        child: Row(
                                          children: [
                                            const Icon(Icons.history, size: 16, color: Color(0xFFC41E3A)),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(u,
                                                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.black87),
                                                  overflow: TextOverflow.ellipsis),
                                            ),
                                            InkWell(
                                              borderRadius: BorderRadius.circular(12),
                                              onTap: () {
                                                Navigator.pop(context);
                                                _removeRecent(u);
                                              },
                                              child: const Padding(
                                                padding: EdgeInsets.all(4),
                                                child: Icon(Icons.close, size: 16, color: Colors.grey),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )).toList(),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passCtrl,
                        obscureText: _obscure,
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          hintText: tr('password'),
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      if (provider.error != null) ...[
                        const SizedBox(height: 8),
                        Text(provider.error!, style: const TextStyle(color: Color(0xFFC41E3A), fontSize: 12, fontFamily: 'Cairo')),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: provider.isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: provider.isLoading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : Text(tr('login'), style: const TextStyle(fontSize: 14, fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _login() async {
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) return;
    final username = _userCtrl.text.trim();
    final ok = await context.read<AppProvider>().login(username, _passCtrl.text);
    if (ok && mounted) {
      await _saveRecent(username);
      FirebaseMessaging.instance.getToken().then((fcmToken) {
        if (fcmToken != null) ApiService.saveFcmToken(fcmToken);
      });
      Navigator.pushReplacementNamed(context, '/main');
    }
  }

  // Admin two-factor: OTP entry card shown after a correct password.
  Widget _buildOtpColumn(AppProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.shield_outlined, color: Color(0xFFC41E3A), size: 40),
        const SizedBox(height: 10),
        Text(I18n.isAr ? 'تم إرسال رمز تحقق المالك عبر تيليجرام' : 'An owner verification code was sent via Telegram',
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(I18n.isAr ? 'أدخل الرمز المكوّن من 6 أرقام' : 'Enter the 6-digit code',
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 16),
        TextField(
          controller: _otpCtrl,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(
            counterText: '',
            hintText: '------',
            prefixIcon: Icon(Icons.password_outlined),
          ),
          onSubmitted: (_) => _verify(),
        ),
        if (provider.error != null) ...[
          const SizedBox(height: 8),
          Text(provider.error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFC41E3A), fontSize: 12, fontFamily: 'Cairo')),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: provider.isLoading ? null : _verify,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: provider.isLoading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text(I18n.isAr ? 'تحقّق' : 'Verify', style: const TextStyle(fontSize: 14, fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
        ),
        TextButton(
          onPressed: provider.isLoading ? null : () { _otpCtrl.clear(); provider.cancelTwoFactor(); },
          child: Text(I18n.isAr ? '‹ رجوع لتسجيل الدخول' : '‹ Back to login',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey)),
        ),
      ],
    );
  }

  Future<void> _verify() async {
    if (_otpCtrl.text.trim().length < 4) return;
    final ok = await context.read<AppProvider>().verifyTwoFactor(_otpCtrl.text.trim());
    if (ok && mounted) {
      await _saveRecent(_userCtrl.text.trim());
      _otpCtrl.clear();
      FirebaseMessaging.instance.getToken().then((fcmToken) {
        if (fcmToken != null) ApiService.saveFcmToken(fcmToken);
      });
      Navigator.pushReplacementNamed(context, '/main');
    }
  }

  // إجبار تغيير الباسورد عند أول دخول
  Widget _buildPwChangeColumn(AppProvider provider) {
    InputDecoration dec(String h) => InputDecoration(hintText: h, prefixIcon: const Icon(Icons.lock_outline));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.lock_reset, color: Color(0xFFC41E3A), size: 40),
        const SizedBox(height: 10),
        Text(I18n.isAr ? 'تعيين كلمة مرور جديدة' : 'Set a new password',
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(I18n.isAr ? 'لأول دخول، اختر كلمة مرور جديدة خاصة بك' : 'First login — please set your own new password',
            textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 12),
        // تحذير يوضّح سبب الطلب: الكلمة الحالية يعرفها المزوّد أو أنها شائعة
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0x1AF59E0B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x33F59E0B)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB45309), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  I18n.isAr
                      ? 'كلمة المرور الحالية ضعيفة أو يعرفها مزوّد الخدمة. اختر كلمة مرور جديدة لا تقل عن 6 أحرف ومختلفة عن الحالية.'
                      : 'Your current password is weak or known to your provider. Choose a new one, at least 6 characters and different from the current one.',
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, height: 1.5, color: Color(0xFF92400E)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(controller: _newPwCtrl, obscureText: true, textDirection: TextDirection.ltr, autofocus: true, decoration: dec(I18n.isAr ? 'كلمة المرور الجديدة' : 'New password')),
        const SizedBox(height: 10),
        TextField(controller: _confirmPwCtrl, obscureText: true, textDirection: TextDirection.ltr, onSubmitted: (_) => _submitNewPassword(), decoration: dec(I18n.isAr ? 'تأكيد كلمة المرور' : 'Confirm password')),
        if (provider.error != null) ...[
          const SizedBox(height: 8),
          Text(provider.error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFC41E3A), fontSize: 12, fontFamily: 'Cairo')),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: provider.isLoading ? null : _submitNewPassword,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: provider.isLoading
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text(I18n.isAr ? 'حفظ ودخول' : 'Save & continue', style: const TextStyle(fontSize: 14, fontFamily: 'Cairo', fontWeight: FontWeight.w600)),
        ),
        TextButton(
          onPressed: provider.isLoading ? null : () { _newPwCtrl.clear(); _confirmPwCtrl.clear(); provider.cancelPasswordChange(); },
          child: Text(I18n.isAr ? '‹ رجوع لتسجيل الدخول' : '‹ Back to login',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Colors.grey)),
        ),
      ],
    );
  }

  Future<void> _submitNewPassword() async {
    final np = _newPwCtrl.text.trim(), cp = _confirmPwCtrl.text.trim();
    if (np.length < 4) { _snack(I18n.isAr ? 'كلمة المرور قصيرة جداً (4 أحرف على الأقل)' : 'Password too short (min 4)'); return; }
    if (np != cp) { _snack(I18n.isAr ? 'كلمتا المرور غير متطابقتين' : 'Passwords do not match'); return; }
    final ok = await context.read<AppProvider>().submitNewPassword(np);
    if (ok && mounted) {
      await _saveRecent(_userCtrl.text.trim());
      _newPwCtrl.clear(); _confirmPwCtrl.clear();
      FirebaseMessaging.instance.getToken().then((fcmToken) { if (fcmToken != null) ApiService.saveFcmToken(fcmToken); });
      Navigator.pushReplacementNamed(context, '/main');
    }
  }
  void _snack(String m) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A))); }

  @override
  void dispose() { _userCtrl.dispose(); _passCtrl.dispose(); _otpCtrl.dispose(); _newPwCtrl.dispose(); _confirmPwCtrl.dispose(); super.dispose(); }
}

// ============================================================
// Shared Widgets
// ============================================================

class _Tab { final String id, label; const _Tab(this.id, this.label); }

class _FilterTabs extends StatelessWidget {
  final List<_Tab> tabs;
  final String current;
  final Function(String) onTap;
  final Map<String, int> counts;
  const _FilterTabs({required this.tabs, required this.current, required this.onTap, required this.counts});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: tabs.map((t) {
          final isOn = current == t.id;
          return Expanded(
            child: GestureDetector(
              onTap: () => onTap(t.id),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: isOn ? const Color(0xFFC41E3A) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isOn ? const Color(0xFFC41E3A) : Theme.of(context).dividerColor),
                ),
                child: Column(children: [
                  Text(t.label, style: TextStyle(fontSize: 10, color: isOn ? Colors.white : const Color(0xFF8892A4), fontFamily: 'Cairo')),
                  Text('${counts[t.id] ?? 0}', style: TextStyle(fontSize: 8, color: isOn ? Colors.white.withOpacity(0.8) : const Color(0xFF8892A4), fontFamily: 'Cairo')),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String>? onChanged;
  const _SearchField({required this.hint, this.onChanged});
  @override
  Widget build(BuildContext context) {
    return TextField(
      textDirection: TextDirection.rtl,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 18),
        filled: true, fillColor: Theme.of(context).colorScheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Theme.of(context).dividerColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Theme.of(context).dividerColor)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  final List<Widget> children;
  const _FieldCard({required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(children: children),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool readOnly, isLast;
  final TextInputType? keyboard;
  /// يُظهر زر نسخ بجانب الحقل (اسم المستخدم مثلًا)
  final bool copyable;
  const _FieldRow({required this.label, required this.controller, this.readOnly = false, this.keyboard, this.isLast = false, this.copyable = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(border: isLast ? null : Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        SizedBox(width: 68, child: Text(label, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 10, fontFamily: 'Cairo', fontWeight: FontWeight.w500))),
        Expanded(child: TextField(
          controller: controller, readOnly: readOnly, keyboardType: keyboard,
          textDirection: TextDirection.rtl,
          style: TextStyle(fontSize: 12, fontFamily: 'Cairo', color: readOnly ? const Color(0xFF8892A4) : Theme.of(context).colorScheme.onSurface),
          decoration: const InputDecoration(border: InputBorder.none, filled: false, isDense: true, contentPadding: EdgeInsets.zero),
        )),
        if (copyable && controller.text.trim().isNotEmpty)
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: controller.text.trim()));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr('sp_copied'), style: const TextStyle(fontFamily: 'Cairo')),
                backgroundColor: const Color(0xFF6BA539),
                duration: const Duration(seconds: 1),
                behavior: SnackBarBehavior.floating,
              ));
            },
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Icon(Icons.copy, size: 16, color: Color(0xFF1565C0)),
            ),
          ),
      ]),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final List<_ActionItem> items;
  const _ActionCard({required this.items});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Theme.of(context).dividerColor)),
      child: Column(
        children: items.asMap().entries.map((e) {
          final isLast = e.key == items.length - 1;
          final item = e.value;
          return GestureDetector(
            onTap: item.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(border: isLast ? null : Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
              child: item.center
                  ? Center(child: Text(item.label, style: TextStyle(color: item.color, fontSize: 12, fontWeight: FontWeight.w500, fontFamily: 'Cairo')))
                  : Row(children: [
                      Container(width: 30, height: 30, decoration: BoxDecoration(color: item.bg, borderRadius: BorderRadius.circular(8)), child: Icon(item.icon, color: item.color, size: 15)),
                      const SizedBox(width: 8),
                      Text(item.label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo')),
                      const Spacer(),
                      Text('>', style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4), fontSize: 14)),
                    ]),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ActionItem {
  final IconData icon;
  final String label;
  final Color color, bg;
  final VoidCallback onTap;
  final bool center;
  const _ActionItem({required this.icon, required this.label, required this.color, required this.bg, required this.onTap, this.center = false});
}

// ─── _HeaderStatTile ─────────────────────────────────────────────────────────
class _HeaderStatTile extends StatelessWidget {
  final IconData icon; final String label; final int value; final Color color, bg;
  const _HeaderStatTile({required this.icon, required this.label, required this.value, required this.color, required this.bg});
  static const _gradients = {
    0xFF6BA539: [Color(0xFF1B5E20), Color(0xFF43A047)],
    0xFF2196F3: [Color(0xFF0D47A1), Color(0xFF1976D2)],
    0xFF4CAF50: [Color(0xFF1B5E20), Color(0xFF43A047)],
    0xFFEF5350: [Color(0xFFB71C1C), Color(0xFFE53935)],
  };
  @override
  Widget build(BuildContext context) {
    final grad = _gradients[color.value] ?? [color.withOpacity(0.7), color];
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(gradient: LinearGradient(colors: grad, begin: Alignment.topRight, end: Alignment.bottomLeft), borderRadius: BorderRadius.circular(10), boxShadow: [BoxShadow(color: grad.last.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 18), const SizedBox(height: 2),
        Text(value.toString(), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white, fontFamily: 'Cairo')),
        Text(label, style: const TextStyle(fontSize: 9, color: Color(0xDDFFFFFF), fontFamily: 'Cairo')),
      ]),
    ));
  }
}

// ─── _ProfileBalTile ─────────────────────────────────────────────────────────
class _ProfileBalTile extends StatelessWidget {
  final IconData icon; final String label; final int value; final Color color, bg;
  const _ProfileBalTile({required this.icon, required this.label, required this.value, required this.color, required this.bg});
  @override
  Widget build(BuildContext context) {
    return Expanded(child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withOpacity(0.55), color.withOpacity(0.25)], begin: Alignment.topRight, end: Alignment.bottomLeft), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white.withOpacity(0.15))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 28, height: 28, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: color, size: 16)),
        const SizedBox(height: 3),
        Text(value.toString(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white, fontFamily: 'Cairo')),
        Text(label, style: const TextStyle(fontSize: 7.5, color: Color(0xCCFFFFFF), fontFamily: 'Cairo'), textAlign: TextAlign.center, maxLines: 2),
      ]),
    ));
  }
}

// ─── _UserAvatar ─────────────────────────────────────────────────────────────
class _UserAvatar extends StatelessWidget {
  final String? avatarUrl; final String initials; final double radius; final Color bgColor;
  const _UserAvatar({required this.initials, required this.radius, required this.bgColor, this.avatarUrl, super.key});
  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null) {
      return CircleAvatar(
        key: ValueKey(avatarUrl),
        radius: radius,
        backgroundColor: bgColor,
        backgroundImage: NetworkImage(avatarUrl!),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(radius: radius, backgroundColor: bgColor,
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: radius * 0.7, fontWeight: FontWeight.w600, fontFamily: 'Cairo')));
  }
}

// ─── AccountScreen Methods ────────────────────────────────────────────────────
extension _AccountScreenMethods on _AccountScreenState {
  void _changeAvatarColor(BuildContext context) {
    final user = context.read<AppProvider>().currentUser;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2))),
        if (user?.avatarUrl != null)
          ListTile(leading: const Icon(Icons.image_outlined, color: Color(0xFF1565C0)), title: Text(tr('cl_view_photo'), style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () { Navigator.pop(ctx); _viewAvatar(context, user!.avatarUrl!); }),
        ListTile(leading: const Icon(Icons.camera_alt_outlined, color: Color(0xFFC41E3A)), title: Text(tr('cl_change_photo'), style: const TextStyle(fontFamily: 'Cairo')),
          onTap: () { Navigator.pop(ctx); _pickAndUploadAvatar(context); }),
        if (user?.avatarUrl != null)
          ListTile(leading: const Icon(Icons.delete_outline, color: Color(0xFFEF5350)), title: Text(tr('cl_delete_photo'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFFEF5350))),
            onTap: () { Navigator.pop(ctx); _deleteAvatar(context); }),
        const SizedBox(height: 8),
      ])),
    );
  }

  void _viewAvatar(BuildContext context, String url) {
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: ClipRRect(borderRadius: BorderRadius.circular(16),
          child: Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 80, color: Colors.white))),
      ),
    ));
  }

  Future<void> _deleteAvatar(BuildContext context) async {
    final r = await ApiService.request('delete_avatar', {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['success']==true?tr('cl_photo_deleted'):tr('cl_fail'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: r['success']==true?const Color(0xFF6BA539):const Color(0xFFC41E3A)));
      if (r['success'] == true) { PaintingBinding.instance.imageCache.clear(); await context.read<AppProvider>().refreshUser(); }
    }
  }

  void _pickAndUploadAvatar(BuildContext context) async {
    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 85);
    if (image == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final bytes = await image.readAsBytes();
      final r = await ApiService.request('upload_avatar', {'image': base64Encode(bytes), 'ext': image.path.split('.').last.toLowerCase()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['success']==true?tr('cl_photo_changed'):r['error']??tr('cl_fail'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: r['success']==true?const Color(0xFF6BA539):const Color(0xFFC41E3A)));
        if (r['success'] == true) {
          // عرض الصورة الجديدة فوراً
          final newUrl = r['avatar'] != null
              ? 'https://himaya-track.com${r['avatar']}'
              : null;
          if (newUrl != null && mounted) setState(() => _localAvatarUrl = newUrl);
          // evict old image specifically then clear all + refresh user
          final oldUrl = context.read<AppProvider>().currentUser?.avatarUrl;
          if (oldUrl != null) NetworkImage(oldUrl).evict();
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          await context.read<AppProvider>().refreshUser();
        }
      }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('err_prefix')}: $e', style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
    } finally { if (mounted) setState(() => _saving = false); }
  }
  void _changePassword(BuildContext context) {
    final o=TextEditingController(), n=TextEditingController(), cf=TextEditingController();
    bool oo=true, on=true, sv=false;
    showDialog(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,ss)=>AlertDialog(
      title:Text(tr('pw_title'),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:o,obscureText:oo,textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,decoration:InputDecoration(labelText:tr('pw_current'),labelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12),suffixIcon:IconButton(icon:Icon(oo?Icons.visibility_off_outlined:Icons.visibility_outlined,size:18),onPressed:()=>ss(()=>oo=!oo)))),
        const SizedBox(height:8),
        TextField(controller:n,obscureText:on,textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,decoration:InputDecoration(labelText:tr('pw_new'),labelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12),suffixIcon:IconButton(icon:Icon(on?Icons.visibility_off_outlined:Icons.visibility_outlined,size:18),onPressed:()=>ss(()=>on=!on)))),
        const SizedBox(height:8),
        TextField(controller:cf,obscureText:true,textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,decoration:InputDecoration(labelText:tr('pw_confirm'),labelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12))),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo'))),
        ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFFC41E3A)),
          onPressed:sv?null:()async{if(o.text.isEmpty||n.text.isEmpty)return;if(n.text!=cf.text){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('pw_mismatch'),style:const TextStyle(fontFamily:'Cairo')),backgroundColor:const Color(0xFFC41E3A)));return;}ss(()=>sv=true);final r=await ApiService.request('change_password',{'old_password':o.text,'new_password':n.text});ss(()=>sv=false);if(ctx.mounted)Navigator.pop(ctx);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(r['success']==true?tr('pw_changed'):r['error']??tr('pw_failed'),style:const TextStyle(fontFamily:'Cairo')),backgroundColor:r['success']==true?const Color(0xFF6BA539):const Color(0xFFC41E3A)));},
          child:sv?const SizedBox(width:16,height:16,child:CircularProgressIndicator(color:Colors.white,strokeWidth:2)):Text(tr('save'),style:const TextStyle(fontFamily:'Cairo')))],
    )));
  }
  void _changeImei(BuildContext context) {
    final oc=TextEditingController(),nc=TextEditingController();
    String model='GT06N'; bool sv=false; String? err;
    showDialog(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,ss)=>AlertDialog(
      title:Text(tr('im_title'),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(tr('im_old'),style:const TextStyle(fontFamily:'Cairo',fontSize:11,color:Color(0xFF6B7280))),const SizedBox(height:4),
        TextField(controller:oc,keyboardType:TextInputType.number,onChanged:(_)=>ss(()=>err=null),decoration:InputDecoration(hintText:tr('im_old_hint'),border:const OutlineInputBorder(),isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:10))),
        const SizedBox(height:8),Text(tr('im_new'),style:const TextStyle(fontFamily:'Cairo',fontSize:11,color:Color(0xFF6B7280))),const SizedBox(height:4),
        TextField(controller:nc,keyboardType:TextInputType.number,onChanged:(_)=>ss(()=>err=null),decoration:InputDecoration(hintText:tr('im_new_hint'),border:const OutlineInputBorder(),isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:10))),
        const SizedBox(height:8),
        ModelPickerField(value:model,label:tr('cl_dev_type'),includeOther:true,onChanged:(v)=>ss(()=>model=v)),
        if(err!=null)...[const SizedBox(height:8),Text(err!,style:const TextStyle(fontFamily:'Cairo',fontSize:12,color:Color(0xFFDC2626)))],
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo'))),
        ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFFF59E0B)),
          onPressed:sv?null:()async{if(oc.text.trim().isEmpty||nc.text.trim().isEmpty){ss(()=>err=tr('im_enter_both'));return;}ss(()=>sv=true);final r=await ApiService.request('change_imei',{'old_imei':oc.text.trim(),'new_imei':nc.text.trim(),'model':model});ss(()=>sv=false);if(r['success']==true){if(ctx.mounted)Navigator.pop(ctx);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('im_changed'),style:const TextStyle(fontFamily:'Cairo')),backgroundColor:const Color(0xFF6BA539)));}else{ss(()=>err=r['error']??tr('im_failed'));}},
          child:sv?const SizedBox(width:16,height:16,child:CircularProgressIndicator(color:Colors.white,strokeWidth:2)):Text(tr('im_change'),style:const TextStyle(fontFamily:'Cairo')))],
    )));
  }
  void _changeLanguage(BuildContext context) {
    final prov = context.read<AppProvider>();
    final cur = prov.locale.languageCode;
    showDialog(context:context,builder:(ctx)=>AlertDialog(
      title:Text(tr('language'),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        ListTile(leading:const Text('عر',style:TextStyle(fontSize:20)),title:Text(tr('arabic'),style:const TextStyle(fontFamily:'Cairo')),
          trailing:cur=='ar'?const Icon(Icons.check,color:Color(0xFFC41E3A)):null,
          onTap:(){if(cur=='ar'){Navigator.pop(ctx);return;}_confirmLang(context,ctx,prov,'ar');}),
        ListTile(leading:const Text('EN',style:TextStyle(fontSize:20)),title:Text(tr('english'),style:const TextStyle(fontFamily:'Cairo')),
          trailing:cur=='en'?const Icon(Icons.check,color:Color(0xFFC41E3A)):null,
          onTap:(){if(cur=='en'){Navigator.pop(ctx);return;}_confirmLang(context,ctx,prov,'en');}),
      ]),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:Text(tr('close'),style:const TextStyle(fontFamily:'Cairo')))],
    ));
  }
  void _changeTheme(BuildContext context) {
    final prov = context.read<AppProvider>();
    final cur = prov.themeMode;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text(tr('acc_theme'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 14)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.brightness_auto_outlined),
          title: Text(tr('theme_system'), style: const TextStyle(fontFamily: 'Cairo')),
          trailing: cur == ThemeMode.system ? const Icon(Icons.check, color: Color(0xFFC41E3A)) : null,
          onTap: () { prov.setThemeMode(ThemeMode.system); Navigator.pop(ctx); },
        ),
        ListTile(
          leading: const Icon(Icons.light_mode_outlined),
          title: Text(tr('theme_light'), style: const TextStyle(fontFamily: 'Cairo')),
          trailing: cur == ThemeMode.light ? const Icon(Icons.check, color: Color(0xFFC41E3A)) : null,
          onTap: () { prov.setThemeMode(ThemeMode.light); Navigator.pop(ctx); },
        ),
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: Text(tr('theme_dark'), style: const TextStyle(fontFamily: 'Cairo')),
          trailing: cur == ThemeMode.dark ? const Icon(Icons.check, color: Color(0xFFC41E3A)) : null,
          onTap: () { prov.setThemeMode(ThemeMode.dark); Navigator.pop(ctx); },
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('close'), style: const TextStyle(fontFamily: 'Cairo')))],
    ));
  }

  void _confirmLang(BuildContext context, BuildContext pickerCtx, AppProvider prov, String code) {
    showDialog(context:context,builder:(c2)=>AlertDialog(
      title:Text(tr('lang_confirm_title'),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
      content:Text(tr('lang_confirm_msg'),style:const TextStyle(fontFamily:'Cairo',fontSize:13)),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(c2),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo'))),
        ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFFC41E3A)),
          onPressed:(){prov.setLocale(code);Navigator.pop(c2);Navigator.pop(pickerCtx);},
          child:Text(tr('ok'),style:const TextStyle(fontFamily:'Cairo'))),
      ],
    ));
  }
  void _shareApp(BuildContext context) {
    showDialog(context:context,builder:(ctx)=>AlertDialog(
      title:Text(tr('sh_title'),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
      content:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:Theme.of(context).scaffoldBackgroundColor,borderRadius:BorderRadius.circular(8)),child:const Text('H.Track - https://himaya-track.com',style:TextStyle(fontFamily:'Cairo',fontSize:12))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo'))),
        ElevatedButton.icon(style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFF6BA539)),icon:const Icon(Icons.copy,size:16),label:Text(tr('sh_copy'),style:const TextStyle(fontFamily:'Cairo')),
          onPressed:(){Navigator.pop(ctx);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('sh_copied'),style:const TextStyle(fontFamily:'Cairo')),backgroundColor:const Color(0xFF6BA539)));})],
    ));
  }
}

// ─── _EditDeviceSheet ─────────────────────────────────────────────────────────
class _EditDeviceSheet extends StatefulWidget {
  final DeviceModel device; final VoidCallback onSaved;
  const _EditDeviceSheet({required this.device, required this.onSaved});
  @override State<_EditDeviceSheet> createState() => _EditDeviceSheetState();
}
class _EditDeviceSheetState extends State<_EditDeviceSheet> with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _loading=true, _saving=false;
  late TextEditingController _name,_plate,_iccid,_phone,_installPerson,_installTime,_installCompany,_installLocation,_installAddress,_notes,_driverName,_driverMobile,_engineNumber,_vehicleBrand,_vehicleColor,_driverId,_permitNo,_permitCoverage,_speedLimit;
  static const _models=['GT06N','GT06E','GT06','GT02A','GK310','JM-VL01','TK103','TK103B','TK303','TK305','TK306','FMB920','FMB910','FMB003','FMB125','FMB130','FMC130','FMC640','FMB202','FMB204','FMT100','W15L','S06U','S5','EV404','TR06','OBD','Teltonika','OTHER'];
  static List<Map<String,String>> get _vIcons=>[{'key':'car','label':tr('vt_car')},{'key':'boat','label':tr('veh_boat')},{'key':'pickup','label':tr('vt_pickup')},{'key':'van','label':tr('vt_van')},{'key':'bus','label':tr('vt_bus')},{'key':'truck','label':tr('vt_truck')},{'key':'motorcycle','label':tr('vt_motorcycle')},{'key':'tuk_tuk','label':tr('vt_tuktuk')},{'key':'excavator','label':tr('veh_excavator')}];
  static const _vIconData={'car':Icons.directions_car,'boat':Icons.directions_boat,'pickup':Icons.local_shipping,'van':Icons.airport_shuttle,'bus':Icons.directions_bus,'truck':Icons.fire_truck,'motorcycle':Icons.two_wheeler,'tuk_tuk':Icons.electric_rickshaw,'excavator':Icons.front_loader};
  String _model='GT06N',_icon='car';
  DateTime? _expiryDate;
  late TextEditingController _expiryCtrl;
  late bool _aEOn,_aEOff,_aOvr,_aIdl,_aNs,_aPk,_aDoor,_aPow,_aLowBat,_aSos,_aGeo,_aTow,_aHBrk,_aHAcc;
  @override void initState(){super.initState();_tab=TabController(length:6,vsync:this);_expiryCtrl=TextEditingController();_load();}
  @override void dispose(){_tab.dispose();_expiryCtrl.dispose();super.dispose();}
  Future<void> _load() async {
    try{final d=<String,dynamic>{}; // نستخدم widget.device مباشرة بدون API call
    if(mounted)setState((){_model=widget.device.deviceType;_icon=d['icon']??widget.device.icon;
    _name=TextEditingController(text:d['name']??widget.device.name);_plate=TextEditingController(text:d['plate_number']??'');_iccid=TextEditingController(text:widget.device.iccid);_phone=TextEditingController(text:widget.device.simPhone);
    _installPerson=TextEditingController(text:d['install_person']??'');_installTime=TextEditingController(text:d['install_time']??'');_installCompany=TextEditingController(text:d['install_company']??'');_installLocation=TextEditingController(text:d['install_location']??'');_installAddress=TextEditingController(text:d['install_address']??'');_notes=TextEditingController(text:d['notes']??'');
    _driverName=TextEditingController(text:d['driver_name']??'');_driverMobile=TextEditingController(text:d['driver_mobile']??'');_engineNumber=TextEditingController(text:d['engine_number']??'');_vehicleBrand=TextEditingController(text:d['vehicle_brand']??'');_vehicleColor=TextEditingController(text:d['vehicle_color']??'');_driverId=TextEditingController(text:d['driver_id']??'');_permitNo=TextEditingController(text:d['permit_no']??'');_permitCoverage=TextEditingController(text:d['permit_coverage']??'');_speedLimit=TextEditingController(text:(widget.device.speedLimit).toString());
    _aEOn=widget.device.alertEngineOn==1;_aEOff=widget.device.alertEngineOff==1;_aOvr=widget.device.alertOverspeed==1;_aIdl=widget.device.alertIdle==1;_aNs=widget.device.alertNoSignal==1;_aPk=widget.device.alertParking==1;_aDoor=widget.device.alertDoor==1;_aPow=widget.device.alertPowerCut==1;_aLowBat=widget.device.alertLowBattery==1;_aSos=widget.device.alertSos==1;_aGeo=widget.device.alertGeofence==1;_aTow=widget.device.alertTowing==1;_aHBrk=widget.device.alertHarshBrake==1;_aHAcc=widget.device.alertHarshAccel==1;_expiryDate=widget.device.subscriptionEnd;_expiryCtrl.text=_fmtDate(_expiryDate);_loading=false;});}
    catch(_){if(mounted)setState((){_name=TextEditingController(text:widget.device.name);_plate=_installPerson=_installTime=_installCompany=_installLocation=_installAddress=_notes=_driverName=_driverMobile=_engineNumber=_vehicleBrand=_vehicleColor=_driverId=_permitNo=_permitCoverage=TextEditingController();_iccid=TextEditingController(text:widget.device.iccid);_phone=TextEditingController(text:widget.device.simPhone);_expiryDate=widget.device.subscriptionEnd;_expiryCtrl.text=_fmtDate(_expiryDate);_speedLimit=TextEditingController(text:(widget.device.speedLimit).toString());_aEOn=widget.device.alertEngineOn==1;_aEOff=widget.device.alertEngineOff==1;_aOvr=widget.device.alertOverspeed==1;_aIdl=widget.device.alertIdle==1;_aNs=widget.device.alertNoSignal==1;_aPk=widget.device.alertParking==1;_aDoor=widget.device.alertDoor==1;_aPow=widget.device.alertPowerCut==1;_aLowBat=widget.device.alertLowBattery==1;_aSos=widget.device.alertSos==1;_aGeo=widget.device.alertGeofence==1;_aTow=widget.device.alertTowing==1;_aHBrk=widget.device.alertHarshBrake==1;_aHAcc=widget.device.alertHarshAccel==1;_loading=false;});}
  }
  Future<void> _save() async {
    // Validation: speed limit required when overspeed alert is enabled
    if (_aOvr) {
      final lim = int.tryParse(_speedLimit.text.trim()) ?? 0;
      if (lim <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('speed_limit_required'), style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: const Color(0xFFC41E3A),
        ));
        return;
      }
    }
    setState(()=>_saving=true);
    final provider=context.read<AppProvider>();
    final r=await ApiService.request('update_device',{'id':widget.device.traccarId,'name':_name.text.trim(),'model':_model,'icon':_icon,'phone':_phone.text.trim(),'plate_number':_plate.text.trim(),'iccid':_iccid.text.trim(),'install_person':_installPerson.text.trim(),'install_time':_installTime.text.trim(),'install_company':_installCompany.text.trim(),'install_location':_installLocation.text.trim(),'install_address':_installAddress.text.trim(),'notes':_notes.text.trim(),'driver_name':_driverName.text.trim(),'driver_mobile':_driverMobile.text.trim(),'engine_number':_engineNumber.text.trim(),'vehicle_brand':_vehicleBrand.text.trim(),'vehicle_color':_vehicleColor.text.trim(),'driver_id':_driverId.text.trim(),'permit_no':_permitNo.text.trim(),'permit_coverage':_permitCoverage.text.trim(),'expiry_date':_expiryDate!=null?_fmtDate(_expiryDate):'','speed_limit':int.tryParse(_speedLimit.text)??100,'alert_engine_on':_aEOn?1:0,'alert_engine_off':_aEOff?1:0,'alert_overspeed':_aOvr?1:0,'alert_idle':_aIdl?1:0,'alert_no_signal':_aNs?1:0,'alert_parking':_aPk?1:0,'alert_door':_aDoor?1:0,'alert_power_cut':_aPow?1:0,'alert_low_battery':_aLowBat?1:0,'alert_sos':_aSos?1:0,'alert_geofence':_aGeo?1:0,'alert_towing':_aTow?1:0,'alert_harsh_brake':_aHBrk?1:0,'alert_harsh_accel':_aHAcc?1:0});
    setState(()=>_saving=false);
    if(!mounted)return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(r['success']==true?tr('saved_changes'):r['error']??tr('failed'),style:const TextStyle(fontFamily:'Cairo')),backgroundColor:r['success']==true?const Color(0xFF6BA539):const Color(0xFFC41E3A)));
    if(r['success']==true){
      // تحديث فوري (optimistic) للكائن المشترك عشان إعادة فتح الشيت تعرض الجديد فوراً بدون انتظار loadDevices
      final d=widget.device;
      d.alertEngineOn=_aEOn?1:0; d.alertEngineOff=_aEOff?1:0; d.alertOverspeed=_aOvr?1:0; d.alertIdle=_aIdl?1:0;
      d.alertNoSignal=_aNs?1:0; d.alertParking=_aPk?1:0; d.alertDoor=_aDoor?1:0; d.alertPowerCut=_aPow?1:0;
      d.alertLowBattery=_aLowBat?1:0; d.alertSos=_aSos?1:0; d.alertGeofence=_aGeo?1:0; d.alertTowing=_aTow?1:0;
      d.alertHarshBrake=_aHBrk?1:0; d.alertHarshAccel=_aHAcc?1:0; d.speedLimit=int.tryParse(_speedLimit.text)??d.speedLimit;
      widget.onSaved();provider.loadDevices();
    }
  }
  // ── helpers theme-aware ──────────────────────────────────────────────────────
  Widget _inp(String l, TextEditingController c, {TextInputType? kb, int ml = 1}) {
    final onS = Theme.of(context).colorScheme.onSurface;
    final surf = Theme.of(context).colorScheme.surface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: onS.withOpacity(0.65))),
        const SizedBox(height: 4),
        TextField(
          controller: c, keyboardType: kb, maxLines: ml,
          style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: onS),
          decoration: InputDecoration(
            filled: true, fillColor: surf,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ]),
    );
  }
  Widget _r2(Widget a,Widget b)=>Row(children:[Expanded(child:a),const SizedBox(width:8),Expanded(child:b)]);
  Widget _chk(String l, bool v, ValueChanged<bool> cb) => Row(children: [
    Checkbox(value: v, onChanged: (x) => cb(x!), activeColor: const Color(0xFFC41E3A), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    Flexible(child: Text(l, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Theme.of(context).colorScheme.onSurface))),
  ]);
  String _fmtDate(DateTime? d)=>d==null?'':'${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
  // مدّة البطاقة السنوية تأتي من البطاقة وقت التفعيل لا من إدخال الوكيل — وإلا
  // صارت بطاقة واحدة مدى الحياة مجانًا. الأدمن يتجاوز للتصحيح. (نفس حراسة السيرفر.)
  bool get _canEditExpiry{
    final t=context.read<AppProvider>().currentUser?.accountType;
    if(t!='admin'&&t!='dealer'&&t!='sub_dealer') return false;
    if(t=='admin') return true;
    return (widget.device.subscriptionType??'').toLowerCase().contains('lifetime');
  }
  Widget _ro(String l, String v) {
    final onS = Theme.of(context).colorScheme.onSurface;
    final surf = Theme.of(context).colorScheme.surface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: onS.withOpacity(0.65))),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: surf, border: Border.all(color: onS.withOpacity(0.2)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(v.isEmpty ? '-' : v, style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: onS.withOpacity(0.75))),
        ),
      ]),
    );
  }
  @override
  Widget build(BuildContext context)=>DraggableScrollableSheet(initialChildSize:0.92,maxChildSize:0.97,minChildSize:0.5,builder:(_,sc)=>Directionality(textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,child:Container(
    decoration:BoxDecoration(color:Theme.of(context).colorScheme.surface,borderRadius:const BorderRadius.vertical(top:Radius.circular(20))),
    child:Column(children:[
      Container(margin:const EdgeInsets.symmetric(vertical:10),width:40,height:4,decoration:BoxDecoration(color:Colors.grey[300],borderRadius:BorderRadius.circular(2))),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[const Icon(Icons.edit,size:18,color:Color(0xFF1565C0)),const SizedBox(width:8),Expanded(child:Text('${tr('edit_device')} - ${widget.device.name}',style:const TextStyle(fontSize:14,fontWeight:FontWeight.w600,fontFamily:'Cairo'))),IconButton(icon:const Icon(Icons.close),onPressed:()=>Navigator.pop(context))])),
      Directionality(textDirection:TextDirection.ltr,child:TabBar(controller:_tab,isScrollable:true,labelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12,fontWeight:FontWeight.w600),unselectedLabelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12),labelColor:const Color(0xFF1565C0),indicatorColor:const Color(0xFF1565C0),tabs:[Tab(text:tr('tab_basic')),Tab(text:tr('tab_icon')),Tab(text:tr('tab_install')),Tab(text:tr('tab_alerts')),Tab(text:tr('tab_geofence')),Tab(text:tr('tab_other'))])),
      const Divider(height:1),
      Expanded(child:_loading?const Center(child:CircularProgressIndicator()):TabBarView(controller:_tab,children:[
        SingleChildScrollView(controller:sc,padding:const EdgeInsets.all(16),child:Builder(builder:(ctx){
          final onS=Theme.of(ctx).colorScheme.onSurface;
          final surf=Theme.of(ctx).colorScheme.surface;
          final divC=Theme.of(ctx).dividerColor;
          Widget _topField(String lbl,Widget child)=>Padding(padding:const EdgeInsets.only(bottom:10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(lbl,style:TextStyle(fontFamily:'Cairo',fontSize:11,color:onS.withOpacity(0.65))),const SizedBox(height:4),child]));
          Widget _box({required Widget child})=>Container(width:double.infinity,padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),decoration:BoxDecoration(color:surf,border:Border.all(color:divC),borderRadius:BorderRadius.circular(8)),child:child);
          return Column(children:[
            _topField('IMEI',_box(child:Row(children:[Expanded(child:Text(widget.device.imei.isEmpty?'-':widget.device.imei,style:TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w500,color:onS))),InkWell(onTap:(){Clipboard.setData(ClipboardData(text:widget.device.imei));ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('imei_copied'),style:const TextStyle(fontFamily:'Cairo')),duration:const Duration(seconds:2),behavior:SnackBarBehavior.floating));},child:const Padding(padding:EdgeInsets.only(left:4),child:Icon(Icons.copy,size:18,color:Color(0xFF1565C0))))]))),
            _inp(tr('device_name'),_name),
            _r2(Padding(padding:const EdgeInsets.only(bottom:10),child:ModelPickerField(value:_models.contains(_model)?_model:_models.first,label:tr('device_type'),includeOther:true,onChanged:(v)=>setState(()=>_model=v))),_inp(tr('plate_number'),_plate)),
            _r2(_inp('ICCID',_iccid,kb:TextInputType.number),_inp(tr('sim_number'),_phone,kb:TextInputType.phone)),
            _r2(_ro(tr('activation_date'),_fmtDate(widget.device.activatedAt)),
              _topField(tr('expiry_date'),GestureDetector(onTap:_canEditExpiry?()async{final picked=await showDatePicker(context:context,initialDate:(_expiryDate!=null&&_expiryDate!.year<=2100)?_expiryDate!:DateTime.now(),firstDate:DateTime(2020),lastDate:DateTime(2100));if(picked!=null&&mounted)setState((){_expiryDate=picked;_expiryCtrl.text=_fmtDate(picked);});}:null,child:_box(child:Row(children:[Expanded(child:Text(_expiryCtrl.text.isEmpty?'-':_expiryCtrl.text,style:TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w500,color:_expiryDate!=null&&_expiryDate!.isBefore(DateTime.now())?const Color(0xFFC41E3A):onS))),if(_canEditExpiry)const Icon(Icons.calendar_today,size:16,color:Color(0xFF1565C0))])))),
            ),
          ]);
        })),
        Builder(builder:(ctx){final divC=Theme.of(ctx).dividerColor;final surf=Theme.of(ctx).scaffoldBackgroundColor;return SingleChildScrollView(padding:const EdgeInsets.all(16),child:GridView.count(crossAxisCount:4,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisSpacing:10,mainAxisSpacing:10,children:_vIcons.map((v){final s=_icon==v['key'];return GestureDetector(onTap:()=>setState(()=>_icon=v['key']!),child:Container(decoration:BoxDecoration(color:s?const Color(0xFF1565C0).withOpacity(0.15):surf,borderRadius:BorderRadius.circular(10),border:Border.all(color:s?const Color(0xFF1565C0):divC,width:s?2:1)),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(_vIconData[v['key']]??Icons.directions_car,size:28,color:s?const Color(0xFF1565C0):const Color(0xFF8892A4)),const SizedBox(height:4),Text(tr('veh_${v['key']}'),style:TextStyle(fontFamily:'Cairo',fontSize:10,color:s?const Color(0xFF1565C0):const Color(0xFF8892A4),fontWeight:s?FontWeight.w600:FontWeight.normal))])));}).toList()));}),
        SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[_r2(_inp(tr('install_person'),_installPerson),_inp(tr('install_time'),_installTime)),_r2(_inp(tr('install_company'),_installCompany),_inp(tr('install_location'),_installLocation)),_inp(tr('install_address'),_installAddress),_inp(tr('notes'),_notes,ml:3)])),
        Builder(builder:(ctx){final onS=Theme.of(ctx).colorScheme.onSurface;return SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(tr('alerts'),style:TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w600,color:onS)),const SizedBox(height:8),Wrap(children:[_chk(tr('al_engine_on'),_aEOn,(v)=>setState(()=>_aEOn=v)),_chk(tr('al_engine_off'),_aEOff,(v)=>setState(()=>_aEOff=v)),_chk(tr('al_overspeed'),_aOvr,(v){setState((){_aOvr=v;if(v&&_speedLimit.text.trim().isEmpty)_speedLimit.text='';});}),_chk(tr('al_idle'),_aIdl,(v)=>setState(()=>_aIdl=v)),_chk(tr('al_no_signal'),_aNs,(v)=>setState(()=>_aNs=v)),_chk(tr('al_parking'),_aPk,(v)=>setState(()=>_aPk=v)),_chk(tr('al_power_cut'),_aPow,(v)=>setState(()=>_aPow=v)),_chk(tr('al_sos'),_aSos,(v)=>setState(()=>_aSos=v)),_chk(tr('al_door'),_aDoor,(v)=>setState(()=>_aDoor=v)),_chk(tr('al_low_battery'),_aLowBat,(v)=>setState(()=>_aLowBat=v)),_chk(tr('al_towing'),_aTow,(v)=>setState(()=>_aTow=v)),_chk(tr('al_geofence'),_aGeo,(v)=>setState(()=>_aGeo=v)),_chk(tr('al_harsh_brake'),_aHBrk,(v)=>setState(()=>_aHBrk=v)),_chk(tr('al_harsh_accel'),_aHAcc,(v)=>setState(()=>_aHAcc=v))]),const SizedBox(height:12),AnimatedSize(duration:const Duration(milliseconds:250),curve:Curves.easeInOut,child:_aOvr?Container(decoration:BoxDecoration(color:Theme.of(ctx).colorScheme.primary.withOpacity(0.08),borderRadius:BorderRadius.circular(8),border:Border.all(color:const Color(0xFFFFB300))),padding:const EdgeInsets.all(10),child:Row(children:[const Icon(Icons.speed,color:Color(0xFFE65100),size:18),const SizedBox(width:8),Expanded(child:TextField(controller:_speedLimit,keyboardType:TextInputType.number,decoration:InputDecoration(hintText:tr('speed_limit_kmh'),hintStyle:const TextStyle(fontFamily:'Cairo',fontSize:12,color:Color(0xFFE65100)),border:const OutlineInputBorder(),isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:10,vertical:8),suffixText:tr('unit_kmh'),filled:true,fillColor:Theme.of(ctx).colorScheme.surface),style:TextStyle(fontFamily:'Cairo',fontWeight:FontWeight.bold,color:onS)))])):const SizedBox.shrink())]));}),
        _DeviceGeofenceTab(device:widget.device,alertEnabled:_aGeo,onEnableAlert:(){setState(()=>_aGeo=true);_save();}),
        SingleChildScrollView(padding:const EdgeInsets.all(16),child:Column(children:[_r2(_inp(tr('driver_name'),_driverName),_inp(tr('driver_mobile'),_driverMobile,kb:TextInputType.phone)),_r2(_inp(tr('engine_number'),_engineNumber),_inp(tr('vehicle_brand'),_vehicleBrand)),_r2(_inp(tr('vehicle_color'),_vehicleColor),_inp('Driver IC',_driverId)),_r2(_inp('Permit No',_permitNo),_inp('Permit Coverage',_permitCoverage))])),
      ])),
      Padding(padding:EdgeInsets.fromLTRB(16,8,16,16+MediaQuery.of(context).viewInsets.bottom),child:SizedBox(width:double.infinity,child:ElevatedButton(style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFF1565C0),padding:const EdgeInsets.symmetric(vertical:13),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10))),onPressed:_saving?null:_save,child:_saving?const SizedBox(width:20,height:20,child:CircularProgressIndicator(color:Colors.white,strokeWidth:2)):Text(tr('save_changes'),style:const TextStyle(fontFamily:'Cairo',fontSize:14,fontWeight:FontWeight.w600))))),
    ]),
  )));
}

// ─── Public entry point: open the device geofence manager (used from map) ────
void openDeviceGeofence(BuildContext context, DeviceModel device) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => Directionality(
    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
    child: Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text('${tr('tab_geofence')} - ${device.name}', style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
      ),
      body: _DeviceGeofenceTab(
        device: device,
        alertEnabled: device.alertGeofence == 1,
        onEnableAlert: () {
          ApiService.request('update_device', {'id': device.traccarId, 'alert_geofence': 1});
        },
      ),
    ),
  )));
}

// ─── _DeviceGeofenceTab ──────────────────────────────────────────────────────
class _DeviceGeofenceTab extends StatefulWidget {
  final DeviceModel device;
  final bool alertEnabled;
  final VoidCallback onEnableAlert;
  const _DeviceGeofenceTab({required this.device, required this.alertEnabled, required this.onEnableAlert});
  @override State<_DeviceGeofenceTab> createState()=>_DeviceGeofenceTabState();
}
class _DeviceGeofenceTabState extends State<_DeviceGeofenceTab> {
  bool _loading=true,_busy=false;
  List<Map<String,dynamic>> _linked=[];
  @override void initState(){super.initState();_loadLinked();}
  int _i(dynamic v)=>v is int?v:int.tryParse(v?.toString()??'0')??0;
  Widget _gchip(String l,Color fg,Color bg)=>Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),decoration:BoxDecoration(color:bg,borderRadius:BorderRadius.circular(20)),child:Text(l,style:TextStyle(fontFamily:'Cairo',fontSize:10,color:fg,fontWeight:FontWeight.w600)));
  Future<void> _loadLinked() async {
    if(mounted)setState(()=>_loading=true);
    final r=await ApiService.request('device_geofences',{'device_id':widget.device.id});
    final list=(r['data'] as List?)?.map((e)=>Map<String,dynamic>.from(e as Map)).toList()??<Map<String,dynamic>>[];
    if(mounted)setState((){_linked=list;_loading=false;});
  }
  void _snack(String m,Color c){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(m,style:const TextStyle(fontFamily:'Cairo')),backgroundColor:c));}
  Future<void> _unlink(int gfId,String name) async {
    final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:Text(tr('gf_remove_link'),style:const TextStyle(fontFamily:'Cairo',fontSize:15,fontWeight:FontWeight.w600)),
      content:Text(tr('gf_remove_q',{'n':name}),style:const TextStyle(fontFamily:'Cairo',fontSize:13)),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo'))),
        TextButton(onPressed:()=>Navigator.pop(c,true),child:Text(tr('remove'),style:const TextStyle(fontFamily:'Cairo',color:Color(0xFFC41E3A))))]));
    if(ok!=true)return;
    setState(()=>_busy=true);
    await ApiService.request('unlink_device_geofence',{'device_id':widget.device.id,'geofence_id':gfId});
    await _loadLinked();
    if(mounted)setState(()=>_busy=false);
  }
  Future<void> _openSettings(Map<String,dynamic> gs) async {
    final res=await showModalBottomSheet<Map<String,int>>(context:context,isScrollControlled:true,backgroundColor:Colors.transparent,builder:(_)=>_GeofenceSettingsSheet(
      name:(gs['name']?.toString().trim().isNotEmpty==true)?gs['name'].toString():'${tr('tab_geofence')} ${_i(gs['geofence_id'])}',
      evEnter:_i(gs['ev_enter'])==1,evExit:_i(gs['ev_exit'])==1,evSpeed:_i(gs['ev_speed'])==1,
      stopEngine:_i(gs['stop_engine'])==1,notifApp:_i(gs['notif_app'])==1,notifSms:_i(gs['notif_sms'])==1,
      notifEmail:_i(gs['notif_email'])==1,notifWhatsapp:_i(gs['notif_whatsapp'])==1,
    ));
    if(res==null)return;
    setState(()=>_busy=true);
    await ApiService.request('save_geofence_notif',{'device_id':widget.device.id,'geofence_id':_i(gs['geofence_id']),...res});
    await _loadLinked();
    if(mounted)setState(()=>_busy=false);
  }
  Future<void> _linkExisting() async {
    setState(()=>_busy=true);
    // مرّر مالك الجهاز كـ view_as عشان السيرفر يفلتر على سياجات العميل ده فقط (مش شبكة الديلر)
    final r=widget.device.userId!=null
        ? await ApiService.request('geofences',{'view_as':widget.device.userId})
        : await ApiService.request('geofences');
    final all=(r['data'] as List?)?.map((e)=>Map<String,dynamic>.from(e as Map)).toList()??<Map<String,dynamic>>[];
    if(mounted)setState(()=>_busy=false);
    final linkedIds=_linked.map((e)=>_i(e['geofence_id'])).toSet();
    final available=all.where((g)=>!linkedIds.contains(_i(g['id']))).toList();
    if(!mounted)return;
    if(available.isEmpty){_snack(tr('gf_none_available'),const Color(0xFF1565C0));return;}
    final picked=await showDialog<int>(context:context,builder:(c)=>AlertDialog(
      title:Text(tr('gf_link_existing'),style:const TextStyle(fontFamily:'Cairo',fontSize:15,fontWeight:FontWeight.w600)),
      content:SizedBox(width:double.maxFinite,child:ListView(shrinkWrap:true,children:available.map((g)=>ListTile(
        leading:const Icon(Icons.hexagon_outlined,color:Color(0xFF1565C0),size:20),
        title:Text(g['name']?.toString()??tr('tab_geofence'),style:const TextStyle(fontFamily:'Cairo',fontSize:13)),
        onTap:()=>Navigator.pop(c,_i(g['id'])),
      )).toList())),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:Text(tr('cancel'),style:const TextStyle(fontFamily:'Cairo')))]));
    if(picked==null)return;
    setState(()=>_busy=true);
    await ApiService.request('link_device_geofence',{'device_id':widget.device.id,'geofence_id':picked});
    await _loadLinked();
    if(mounted){setState(()=>_busy=false);_maybePromptAlert();}
  }
  Future<void> _createNew() async {
    final res=await Navigator.push<Map<String,dynamic>>(context,MaterialPageRoute(builder:(_)=>_GeofenceDrawScreen(device:widget.device)));
    if(res==null)return;
    setState(()=>_busy=true);
    final r=await ApiService.request('add_geofence',{'name':res['name'],'area':res['area'],'calendarId':0});
    final gfId=_i(r['id']);
    if(gfId>0){
      await ApiService.request('link_device_geofence',{'device_id':widget.device.id,'geofence_id':gfId});
      await _loadLinked();
      if(mounted){setState(()=>_busy=false);_snack(tr('gf_created'),const Color(0xFF6BA539));_maybePromptAlert();}
    } else {
      if(mounted){setState(()=>_busy=false);_snack(tr('gf_create_failed'),const Color(0xFFC41E3A));}
    }
  }
  void _maybePromptAlert(){
    if(widget.alertEnabled)return;
    showDialog(context:context,builder:(c)=>AlertDialog(
      title:Text(tr('gf_enable_alert'),style:const TextStyle(fontFamily:'Cairo',fontSize:15,fontWeight:FontWeight.w600)),
      content:Text(tr('gf_enable_alert_q'),style:const TextStyle(fontFamily:'Cairo',fontSize:13)),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:Text(tr('gf_later'),style:const TextStyle(fontFamily:'Cairo'))),
        TextButton(onPressed:(){Navigator.pop(c);widget.onEnableAlert();},child:Text(tr('gf_enable'),style:const TextStyle(fontFamily:'Cairo',color:Color(0xFF6BA539))))]));
  }
  @override
  Widget build(BuildContext context){
    if(_loading)return const Center(child:CircularProgressIndicator());
    return Stack(children:[
      ListView(padding:const EdgeInsets.all(16),children:[
        if(!widget.alertEnabled)Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:const Color(0xFFFFF3CD),borderRadius:BorderRadius.circular(8),border:Border.all(color:const Color(0xFFFFE69C))),child:Row(children:[const Icon(Icons.warning_amber_rounded,color:Color(0xFF9A7B00),size:20),const SizedBox(width:8),Expanded(child:Text(tr('gf_not_enabled'),style:const TextStyle(fontFamily:'Cairo',fontSize:11,color:Color(0xFF7A5C00)))),TextButton(onPressed:widget.onEnableAlert,style:TextButton.styleFrom(padding:const EdgeInsets.symmetric(horizontal:8),minimumSize:Size.zero,tapTargetSize:MaterialTapTargetSize.shrinkWrap),child:Text(tr('gf_enable'),style:const TextStyle(fontFamily:'Cairo',fontSize:12,fontWeight:FontWeight.w700,color:Color(0xFF6BA539))))])),
        Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:_busy?null:_linkExisting,icon:const Icon(Icons.link,size:18),label:Text(tr('gf_link'),style:const TextStyle(fontFamily:'Cairo',fontSize:12)),style:OutlinedButton.styleFrom(foregroundColor:const Color(0xFF1565C0),side:const BorderSide(color:Color(0xFF1565C0)),padding:const EdgeInsets.symmetric(vertical:11)))),
          const SizedBox(width:8),
          Expanded(child:ElevatedButton.icon(onPressed:_busy?null:_createNew,icon:const Icon(Icons.add_location_alt,size:18),label:Text(tr('gf_new'),style:const TextStyle(fontFamily:'Cairo',fontSize:12)),style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFF6BA539),foregroundColor:Colors.white,padding:const EdgeInsets.symmetric(vertical:11)))),
        ]),
        const SizedBox(height:16),
        Text(tr('gf_linked_count',{'n':'${_linked.length}'}),style:const TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w600)),
        const SizedBox(height:8),
        if(_linked.isEmpty)Container(padding:const EdgeInsets.all(24),alignment:Alignment.center,child:Column(children:[const Icon(Icons.hexagon_outlined,size:40,color:Color(0xFFBDBDBD)),const SizedBox(height:8),Text(tr('gf_none_linked'),style:const TextStyle(fontFamily:'Cairo',fontSize:12,color:Color(0xFF9E9E9E)))]))
        else ..._linked.map((gs){final gfId=_i(gs['geofence_id']);final name=(gs['name']?.toString().trim().isNotEmpty==true)?gs['name'].toString():'${tr('tab_geofence')} $gfId';final notifApp=_i(gs['notif_app'])==1;final notifSms=_i(gs['notif_sms'])==1;final notifEmail=_i(gs['notif_email'])==1;final notifWa=_i(gs['notif_whatsapp'])==1;final evEnter=_i(gs['ev_enter'])==1;final evExit=_i(gs['ev_exit'])==1;final evSpeed=_i(gs['ev_speed'])==1;final stopEng=_i(gs['stop_engine'])==1;
          final chips=<Widget>[];
          if(evEnter)chips.add(_gchip(tr('gf_chip_enter'),const Color(0xFF2E7D32),const Color(0xFFE8F5E9)));
          if(evExit)chips.add(_gchip(tr('gf_chip_exit'),const Color(0xFFC41E3A),const Color(0xFFFFEBEE)));
          if(evSpeed)chips.add(_gchip(tr('gf_speed'),const Color(0xFFE65100),const Color(0xFFFFF3E0)));
          if(stopEng)chips.add(_gchip(tr('gf_stop_engine'),const Color(0xFF6A1B9A),const Color(0xFFF3E5F5)));
          if(notifApp)chips.add(_gchip(tr('gf_app'),const Color(0xFF1565C0),const Color(0xFFE3F2FD)));
          if(notifEmail)chips.add(_gchip(tr('gf_email'),const Color(0xFFAD1457),const Color(0xFFFCE4EC)));
          if(notifWa)chips.add(_gchip(tr('gf_whatsapp'),const Color(0xFF1B5E20),const Color(0xFFE8F5E9)));
          if(notifSms)chips.add(_gchip(tr('gf_sms'),const Color(0xFF00695C),const Color(0xFFE0F2F1)));
          if(chips.isEmpty)chips.add(_gchip(tr('gf_no_settings'),const Color(0xFF9E9E9E),const Color(0xFFF5F5F5)));
          return Card(margin:const EdgeInsets.only(bottom:8),elevation:0,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(10),side:BorderSide(color:Theme.of(context).dividerColor)),child:Padding(padding:const EdgeInsets.fromLTRB(12,8,4,10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[const Icon(Icons.hexagon,color:Color(0xFF1565C0),size:18),const SizedBox(width:8),Expanded(child:Text(name,style:const TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w600))),IconButton(icon:const Icon(Icons.tune,color:Color(0xFF1565C0),size:20),tooltip:tr('gf_settings_btn'),onPressed:_busy?null:()=>_openSettings(gs),visualDensity:VisualDensity.compact),IconButton(icon:const Icon(Icons.delete_outline,color:Color(0xFFC41E3A),size:20),onPressed:_busy?null:()=>_unlink(gfId,name),visualDensity:VisualDensity.compact)]),
            Padding(padding:const EdgeInsets.only(right:8),child:Wrap(spacing:6,runSpacing:6,children:chips)),
          ])));
        }),
      ]),
      if(_busy)Container(color:Colors.black.withOpacity(0.05),child:const Center(child:CircularProgressIndicator())),
    ]);
  }
}

// ─── _GeofenceSettingsSheet ──────────────────────────────────────────────────
class _GeofenceSettingsSheet extends StatefulWidget {
  final String name;
  final bool evEnter,evExit,evSpeed,stopEngine,notifApp,notifSms,notifEmail,notifWhatsapp;
  const _GeofenceSettingsSheet({required this.name,required this.evEnter,required this.evExit,required this.evSpeed,required this.stopEngine,required this.notifApp,required this.notifSms,this.notifEmail=false,this.notifWhatsapp=false});
  @override State<_GeofenceSettingsSheet> createState()=>_GeofenceSettingsSheetState();
}
class _GeofenceSettingsSheetState extends State<_GeofenceSettingsSheet> {
  late bool _enter,_exit,_speed,_stop,_app,_sms,_email,_whatsapp;
  @override void initState(){super.initState();_enter=widget.evEnter;_exit=widget.evExit;_speed=widget.evSpeed;_stop=widget.stopEngine;_app=widget.notifApp;_sms=widget.notifSms;_email=widget.notifEmail;_whatsapp=widget.notifWhatsapp;}
  Widget _section(String t)=>Padding(padding:const EdgeInsets.only(top:14,bottom:6),child:Row(children:[Container(width:3,height:14,color:const Color(0xFFC41E3A),margin:const EdgeInsets.only(left:8)),Text(t,style:const TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w700,color:Color(0xFF333333)))]));
  Widget _chkRow(String l,String sub,bool v,ValueChanged<bool> cb,{Color? c})=>InkWell(onTap:()=>cb(!v),borderRadius:BorderRadius.circular(8),child:Padding(padding:const EdgeInsets.symmetric(vertical:6,horizontal:4),child:Row(children:[
    Checkbox(value:v,onChanged:(x)=>cb(x!),activeColor:c??const Color(0xFFC41E3A),materialTapTargetSize:MaterialTapTargetSize.shrinkWrap),
    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(l,style:const TextStyle(fontFamily:'Cairo',fontSize:13,fontWeight:FontWeight.w600)),if(sub.isNotEmpty)Text(sub,style:const TextStyle(fontFamily:'Cairo',fontSize:10,color:Color(0xFF9E9E9E)))])),
  ])));
  @override
  Widget build(BuildContext context)=>Directionality(textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,child:Container(
    decoration:BoxDecoration(color:Theme.of(context).colorScheme.surface,borderRadius:BorderRadius.vertical(top:Radius.circular(20))),
    padding:EdgeInsets.fromLTRB(18,10,18,18+MediaQuery.of(context).viewInsets.bottom),
    child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
      Center(child:Container(margin:const EdgeInsets.only(bottom:10),width:40,height:4,decoration:BoxDecoration(color:Colors.grey[300],borderRadius:BorderRadius.circular(2)))),
      Row(children:[const Icon(Icons.tune,color:Color(0xFF1565C0),size:20),const SizedBox(width:8),Expanded(child:Text('${tr('gf_settings')} — ${widget.name}',style:const TextStyle(fontFamily:'Cairo',fontSize:15,fontWeight:FontWeight.w700),overflow:TextOverflow.ellipsis)),IconButton(icon:const Icon(Icons.close),onPressed:()=>Navigator.pop(context))]),
      _section(tr('gf_event_type')),
      _chkRow(tr('gf_enter'),tr('gf_enter_sub'),_enter,(v)=>setState(()=>_enter=v),c:const Color(0xFF2E7D32)),
      _chkRow(tr('gf_exit'),tr('gf_exit_sub'),_exit,(v)=>setState(()=>_exit=v),c:const Color(0xFFC41E3A)),
      _chkRow(tr('gf_speed'),tr('gf_speed_sub'),_speed,(v)=>setState(()=>_speed=v),c:const Color(0xFFE65100)),
      _section(tr('gf_on_violation')),
      _chkRow(tr('gf_stop_engine'),tr('gf_stop_sub'),_stop,(v)=>setState(()=>_stop=v),c:const Color(0xFF6A1B9A)),
      _section(tr('gf_notify_method')),
      _chkRow(tr('gf_app'),tr('gf_app_sub'),_app,(v)=>setState(()=>_app=v),c:const Color(0xFF1565C0)),
      _chkRow(tr('gf_email'),tr('gf_email_sub'),_email,(v)=>setState(()=>_email=v),c:const Color(0xFFAD1457)),
      _chkRow(tr('gf_whatsapp'),tr('gf_whatsapp_sub'),_whatsapp,(v)=>setState(()=>_whatsapp=v),c:const Color(0xFF25D366)),
      _chkRow(tr('gf_sms'),tr('gf_sms_sub'),_sms,(v)=>setState(()=>_sms=v),c:const Color(0xFF00695C)),
      const SizedBox(height:16),
      SizedBox(width:double.infinity,child:ElevatedButton.icon(onPressed:(){Navigator.pop(context,{'ev_enter':_enter?1:0,'ev_exit':_exit?1:0,'ev_speed':_speed?1:0,'stop_engine':_stop?1:0,'notif_app':_app?1:0,'notif_sms':_sms?1:0,'notif_email':_email?1:0,'notif_whatsapp':_whatsapp?1:0});},icon:const Icon(Icons.save,size:18),label:Text(tr('save_settings'),style:const TextStyle(fontFamily:'Cairo',fontSize:14,fontWeight:FontWeight.w700)),style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFFC41E3A),foregroundColor:Colors.white,padding:const EdgeInsets.symmetric(vertical:13)))),
    ]),
  ));
}

// ─── _GeofenceDrawScreen ─────────────────────────────────────────────────────
enum _GfShape { circle, polygon, line }
class _GeofenceDrawScreen extends StatefulWidget {
  final DeviceModel device;
  const _GeofenceDrawScreen({required this.device});
  @override State<_GeofenceDrawScreen> createState()=>_GeofenceDrawScreenState();
}
class _GeofenceDrawScreenState extends State<_GeofenceDrawScreen> {
  GoogleMapController? _ctrl;
  _GfShape _shape=_GfShape.circle;
  LatLng? _center;            // circle
  double _radius=500;         // circle
  final List<LatLng> _pts=[]; // polygon / line
  final _nameCtrl=TextEditingController();
  @override void initState(){super.initState();if(widget.device.lat!=null&&widget.device.lng!=null&&widget.device.lat!=0&&widget.device.lng!=0)_center=LatLng(widget.device.lat!,widget.device.lng!);}
  @override void dispose(){_nameCtrl.dispose();_ctrl?.dispose();super.dispose();}
  void _err(String m){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(m,style:const TextStyle(fontFamily:'Cairo')),backgroundColor:const Color(0xFFC41E3A)));}
  void _onTap(LatLng ll){
    setState((){
      if(_shape==_GfShape.circle){_center=ll;}
      else{_pts.add(ll);}
    });
  }
  void _undo(){if(_pts.isNotEmpty)setState(()=>_pts.removeLast());}
  void _switchShape(_GfShape s){setState((){_shape=s;});}
  void _save(){
    final name=_nameCtrl.text.trim();
    if(name.isEmpty){_err(tr('gf_enter_name'));return;}
    String area;
    if(_shape==_GfShape.circle){
      if(_center==null){_err(tr('gf_tap_center'));return;}
      // Traccar يفسّر WKT بترتيب خط العرض أولاً: CIRCLE (lat lng, radius)
      area='CIRCLE (${_center!.latitude} ${_center!.longitude}, ${_radius.round()})';
    } else if(_shape==_GfShape.polygon){
      if(_pts.length<3){_err(tr('gf_poly_min'));return;}
      final coords=_pts.map((p)=>'${p.latitude} ${p.longitude}').join(', ');
      area='POLYGON (($coords, ${_pts.first.latitude} ${_pts.first.longitude}))';
    } else {
      if(_pts.length<2){_err(tr('gf_line_min'));return;}
      final coords=_pts.map((p)=>'${p.latitude} ${p.longitude}').join(', ');
      area='LINESTRING ($coords)';
    }
    Navigator.pop(context,{'name':name,'area':area});
  }
  Set<Marker> _markers(){
    if(_shape==_GfShape.circle)return _center!=null?{Marker(markerId:const MarkerId('c'),position:_center!)}:{};
    return _pts.asMap().entries.map((e)=>Marker(markerId:MarkerId('p${e.key}'),position:e.value)).toSet();
  }
  Set<Circle> _circles()=>(_shape==_GfShape.circle&&_center!=null)?{Circle(circleId:const CircleId('gf'),center:_center!,radius:_radius,fillColor:const Color(0x336BA539),strokeColor:const Color(0xFF6BA539),strokeWidth:2)}:{};
  Set<Polygon> _polygons()=>(_shape==_GfShape.polygon&&_pts.length>=3)?{Polygon(polygonId:const PolygonId('gf'),points:_pts,fillColor:const Color(0x336BA539),strokeColor:const Color(0xFF6BA539),strokeWidth:2)}:{};
  Set<Polyline> _polylines()=>(_shape==_GfShape.line&&_pts.length>=2)?{Polyline(polylineId:const PolylineId('gf'),points:_pts,color:const Color(0xFF6BA539),width:4)}:{};
  Widget _shapeBtn(String l,IconData ic,_GfShape s){final sel=_shape==s;return Expanded(child:GestureDetector(onTap:()=>_switchShape(s),child:Container(margin:const EdgeInsets.symmetric(horizontal:3),padding:const EdgeInsets.symmetric(vertical:8),decoration:BoxDecoration(color:sel?const Color(0xFF1565C0):const Color(0xFFF0F2F6),borderRadius:BorderRadius.circular(8),border:Border.all(color:sel?const Color(0xFF1565C0):const Color(0xFFE0E0E0))),child:Column(children:[Icon(ic,size:20,color:sel?Colors.white:const Color(0xFF8892A4)),const SizedBox(height:2),Text(l,style:TextStyle(fontFamily:'Cairo',fontSize:11,fontWeight:sel?FontWeight.w700:FontWeight.normal,color:sel?Colors.white:const Color(0xFF8892A4)))])))); }
  @override
  Widget build(BuildContext context){
    final initial=_center??(_pts.isNotEmpty?_pts.first:const LatLng(30.0444,31.2357));
    final hint=_shape==_GfShape.circle?(_center==null?tr('gf_tap_center2'):tr('gf_tap_center3')):(_shape==_GfShape.polygon?tr('gf_poly_hint'):tr('gf_line_hint'));
    return Directionality(textDirection:I18n.isAr?TextDirection.rtl:TextDirection.ltr,child:Scaffold(
      appBar:AppBar(title:Text(tr('gf_draw_new'),style:const TextStyle(fontFamily:'Cairo',fontSize:16)),backgroundColor:const Color(0xFF1565C0),foregroundColor:Colors.white,actions:[
        if(_shape!=_GfShape.circle)IconButton(icon:const Icon(Icons.undo),tooltip:tr('gf_undo'),onPressed:_pts.isEmpty?null:_undo),
      ]),
      body:Column(children:[
        Container(color:Theme.of(context).colorScheme.surface,padding:const EdgeInsets.fromLTRB(8,8,8,8),child:Row(children:[_shapeBtn(tr('gf_shape_circle'),Icons.circle_outlined,_GfShape.circle),_shapeBtn(tr('gf_shape_polygon'),Icons.pentagon_outlined,_GfShape.polygon),_shapeBtn(tr('gf_shape_line'),Icons.timeline,_GfShape.line)])),
        Expanded(child:Stack(children:[
          GoogleMap(
            initialCameraPosition:CameraPosition(target:initial,zoom:14),
            onMapCreated:(c)=>_ctrl=c,
            onTap:_onTap,
            markers:_markers(),
            circles:_circles(),
            polygons:_polygons(),
            polylines:_polylines(),
            myLocationButtonEnabled:false,mapToolbarEnabled:false,zoomControlsEnabled:false,compassEnabled:false,
          ),
          Positioned(top:10,left:10,right:10,child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:8),decoration:BoxDecoration(color:Colors.black.withOpacity(0.7),borderRadius:BorderRadius.circular(8)),child:Text(hint,textAlign:TextAlign.center,style:const TextStyle(fontFamily:'Cairo',fontSize:12,color:Colors.white)))),
          if(_shape!=_GfShape.circle&&_pts.isNotEmpty)Positioned(bottom:10,right:10,child:Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:5),decoration:BoxDecoration(color:const Color(0xFF1565C0),borderRadius:BorderRadius.circular(20)),child:Text(tr('gf_points',{'n':'${_pts.length}'}),style:const TextStyle(fontFamily:'Cairo',fontSize:12,color:Colors.white,fontWeight:FontWeight.w600)))),
        ])),
        Container(padding:EdgeInsets.fromLTRB(16,12,16,12+MediaQuery.of(context).viewInsets.bottom),decoration:BoxDecoration(color:Theme.of(context).colorScheme.surface,boxShadow:[BoxShadow(color:Colors.black12,blurRadius:8,offset:Offset(0,-2))]),child:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:_nameCtrl,textAlign:I18n.isAr?TextAlign.right:TextAlign.left,decoration:InputDecoration(labelText:tr('gf_name'),labelStyle:const TextStyle(fontFamily:'Cairo',fontSize:12),border:const OutlineInputBorder(),isDense:true,contentPadding:const EdgeInsets.symmetric(horizontal:12,vertical:10)),style:const TextStyle(fontFamily:'Cairo',fontSize:14)),
          if(_shape==_GfShape.circle)...[const SizedBox(height:8),Row(children:[Text(tr('gf_radius',{'n':'${_radius.round()}'}),style:const TextStyle(fontFamily:'Cairo',fontSize:12,fontWeight:FontWeight.w600)),Expanded(child:Slider(value:_radius,min:100,max:3000,divisions:29,activeColor:const Color(0xFF6BA539),label:'${_radius.round()}',onChanged:(v)=>setState(()=>_radius=v)))])],
          const SizedBox(height:8),
          SizedBox(width:double.infinity,child:ElevatedButton.icon(onPressed:_save,icon:const Icon(Icons.save,size:18),label:Text(tr('gf_save'),style:const TextStyle(fontFamily:'Cairo',fontSize:14,fontWeight:FontWeight.w600)),style:ElevatedButton.styleFrom(backgroundColor:const Color(0xFF6BA539),foregroundColor:Colors.white,padding:const EdgeInsets.symmetric(vertical:13)))),
        ])),
      ]),
    ));
  }
}

