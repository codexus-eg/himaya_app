import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../services/i18n.dart';
import '../services/notification_state.dart';
import 'dashboard_screen.dart';
import 'map_screen.dart';
import 'all_screens.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  bool _initialIndexSet = false;
  List<_NavItem> _navItems = [];
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    PendingNotification.tick.removeListener(_onPendingNotification);
    PendingNotification.alertTick.removeListener(_onPendingAlert);
    TabNav.goDevicesTick.removeListener(_onGoDevices);
    TabNav.goClientsTick.removeListener(_onGoClients);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onGoDevices() {
    if (!mounted) return;
    final filter = TabNav.requestedDeviceFilter;
    if (filter != null) {
      context.read<AppProvider>().setDeviceFilter(filter);
    }
    final devIdx = _navItems.indexWhere((e) => e.icon == Icons.directions_car_outlined);
    if (devIdx >= 0 && _currentIndex != devIdx) {
      setState(() => _currentIndex = devIdx);
      _saveTab();
    }
  }

  void _onGoClients() {
    if (!mounted) return;
    final filter = TabNav.requestedClientFilter;
    if (filter != null) {
      context.read<AppProvider>().setClientFilter(filter);
    }
    final cliIdx = _navItems.indexWhere((e) => e.icon == Icons.people_outline);
    if (cliIdx >= 0 && _currentIndex != cliIdx) {
      setState(() => _currentIndex = cliIdx);
      _saveTab();
    }
  }

  void _onPendingAlert() {
    if (!mounted) return;
    final data = PendingNotification.alertData;
    if (data == null) return;
    PendingNotification.clearAlert();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openAlertDetailFromNotif(context, data);
    });
  }

  void _onPendingNotification() {
    if (!mounted) return;
    final mapIdx = _navItems.indexWhere((e) => e.icon == Icons.map_outlined);
    debugPrint('[MainShell] pending notif: mapIdx=$mapIdx current=$_currentIndex');
    if (mapIdx >= 0 && _currentIndex != mapIdx) {
      setState(() => _currentIndex = mapIdx);
      _saveTab();
    }
  }

  // حفظ التاب الحالي (بالـ icon codePoint) ليُسترجع بعد الخلفية/إعادة التشغيل
  void _saveTab() {
    if (_currentIndex < 0 || _currentIndex >= _navItems.length) return;
    final code = _navItems[_currentIndex].icon.codePoint;
    SharedPreferences.getInstance().then((p) => p.setInt('last_tab_icon', code)).catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() => _buildNavItems());
    });
    _buildNavItems();
    PendingNotification.tick.addListener(_onPendingNotification);
    PendingNotification.alertTick.addListener(_onPendingAlert);
    TabNav.goDevicesTick.addListener(_onGoDevices);
    TabNav.goClientsTick.addListener(_onGoClients);
    // if there's a pending notification at init time, react after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PendingNotification.traccarId != null || PendingNotification.deviceId != null) {
        _onPendingNotification();
      }
      if (PendingNotification.alertData != null) {
        _onPendingAlert();
      }
    });
  }

  void _buildNavItems() {
    final provider = context.read<AppProvider>();
    final user = provider.currentUser;
    if (!_initialIndexSet) {
      _initialIndexSet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // القفل النهائي (cold start): افتح على افتراضي الدور — العميل على الخريطة،
        // المزوّد (أدمن/ديلر/موزع) على الداشبورد. (مانسترجعش آخر تاب.)
        // الخلفية/الرجوع = الـ process حي فيحتفظ بالتاب تلقائيًا — الكتلة دي متشتغلش تاني.
        final targetIcon = (user == null || user.isClient)
            ? Icons.map_outlined
            : Icons.home_outlined;
        final idx = _navItems.indexWhere((e) => e.icon == targetIcon);
        if (idx >= 0 && mounted) setState(() => _currentIndex = idx);
      });
    }
    if (user == null || user.isClient) {
      _navItems = [
        _NavItem(label: 'nav_account', icon: Icons.person_outline, screen: const AccountScreen()),
        _NavItem(label: 'nav_alerts', icon: Icons.notifications_outlined, screen: const MessagesScreen()),
        _NavItem(label: 'nav_devices', icon: Icons.directions_car_outlined, screen: DevicesScreen(searchQuery: _searchQuery)),
        _NavItem(label: 'nav_map', icon: Icons.map_outlined, screen: const MapScreen()),
      ];
    } else if (user.isDealer || user.isSubDealer) {
      _navItems = [
        _NavItem(label: 'nav_account', icon: Icons.person_outline, screen: const AccountScreen()),
        _NavItem(label: 'nav_clients', icon: Icons.people_outline, screen: ClientsScreen(searchQuery: _searchQuery)),
        _NavItem(label: 'nav_devices', icon: Icons.directions_car_outlined, screen: DevicesScreen(searchQuery: _searchQuery)),
        _NavItem(label: 'nav_map', icon: Icons.map_outlined, screen: const MapScreen()),
        _NavItem(label: 'nav_dashboard', icon: Icons.home_outlined, screen: const DashboardScreen()),
      ];
    } else {
      _navItems = [
        _NavItem(label: 'nav_account', icon: Icons.person_outline, screen: const AccountScreen()),
        _NavItem(label: 'nav_clients', icon: Icons.people_outline, screen: ClientsScreen(searchQuery: _searchQuery)),
        _NavItem(label: 'nav_devices', icon: Icons.directions_car_outlined, screen: DevicesScreen(searchQuery: _searchQuery)),
        _NavItem(label: 'nav_dashboard', icon: Icons.home_outlined, screen: const DashboardScreen()),
      ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    if (_navItems.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFFC41E3A))));
    }
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: Column(
          children: [
            SafeArea(bottom: false, child: _buildHeader(context, provider)),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: _navItems.map((e) => e.screen).toList(),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _buildBottomNav(context),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppProvider provider) {
    final surface = Theme.of(context).colorScheme.surface;
    final divider = Theme.of(context).dividerColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: surface, border: Border(bottom: BorderSide(color: divider))),
      child: _navItems[_currentIndex].icon == Icons.map_outlined
        ? Center(child: Text(provider.currentUser?.fullName ?? provider.currentUser?.username ?? 'H.Track', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: textColor, fontFamily: 'Cairo')))
        : Row(children: [Text(tr(_navItems[_currentIndex].label), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: textColor, fontFamily: 'Cairo')), const Spacer()]),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final divider = Theme.of(context).dividerColor;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: divider)),
        boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(_navItems.length, (i) {
              final item = _navItems[i];
              final isActive = _currentIndex == i;
              return GestureDetector(
                onTap: () {
                  setState(() => _currentIndex = i);
                  _saveTab();
                  // عند الضغط على تاب التنبيهات → اطلب تحديث فوري للقائمة
                  if (item.icon == Icons.notifications_outlined) {
                    TabNav.refreshNotifTab();
                  }
                },
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: MediaQuery.of(context).size.width / _navItems.length,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isActive ? _filled(item.icon) : item.icon,
                          color: isActive ? const Color(0xFFC41E3A) : const Color(0xFF8892A4), size: 22),
                      const SizedBox(height: 3),
                      Text(tr(item.label),
                          style: TextStyle(
                              fontSize: 8,
                              fontFamily: 'Cairo',
                              color: isActive ? const Color(0xFFC41E3A) : const Color(0xFF8892A4),
                              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  IconData _filled(IconData o) {
    if (o == Icons.home_outlined) return Icons.home;
    if (o == Icons.map_outlined) return Icons.map;
    if (o == Icons.directions_car_outlined) return Icons.directions_car;
    if (o == Icons.people_outline) return Icons.people;
    if (o == Icons.chat_bubble_outline) return Icons.chat_bubble;
    if (o == Icons.notifications_outlined) return Icons.notifications;
    if (o == Icons.person_outline) return Icons.person;
    return o;
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final Widget screen;
  const _NavItem({required this.label, required this.icon, required this.screen});
}