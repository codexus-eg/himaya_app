import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../providers/app_provider.dart';
import '../models/models.dart';
import '../services/i18n.dart';
import '../services/api_service.dart';
import '../services/notification_state.dart';
import '../widgets/model_picker.dart';
import 'map_screen.dart';
import 'all_screens.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().loadDevices();
    });
  }

  void _showAddDeviceSheet(BuildContext context) {
    final imeiCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String deviceType = 'GT06N';
    String subType = 'annual';
    int? selectedUserId;
    String searchQuery = '';
    bool saving = false;
    final provider = context.read<AppProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          // الديلر/الموزع/الأدمن يقدر يختار نفسه (يضيف الجهاز لحسابه هو) — يظهر أول القائمة.
          final me = provider.currentUser;
          final selectableUsers = <UserModel>[
            if (me != null) me,
            ...provider.users.where((u) => me == null || u.id != me.id),
          ];
          final filteredUsers = selectableUsers
              .where((u) =>
                  u.fullName.toLowerCase().contains(searchQuery.toLowerCase()) ||
                  u.username.toLowerCase().contains(searchQuery.toLowerCase()))
              .toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(tr('dash_add_device'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: imeiCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('dash_imei'),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.qr_code_scanner, color: Color(0xFFC41E3A)),
                        tooltip: tr('dash_scan_qr'),
                        onPressed: () async {
                          final code = await Navigator.of(ctx).push<String>(
                            MaterialPageRoute(builder: (_) => const _QrScanScreen()),
                          );
                          if (code != null && code.trim().isNotEmpty) {
                            setS(() => imeiCtrl.text = code.trim());
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('dash_device_name'))),
                  const SizedBox(height: 10),
                  ModelPickerField(
                    value: deviceType,
                    label: tr('dash_device_type'),
                    onChanged: (v) => setS(() => deviceType = v),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: subType,
                    decoration: InputDecoration(labelText: tr('dash_sub_type')),
                    items: [
                      DropdownMenuItem(value: 'lifetime', child: Text(tr('dash_lifetime'))),
                      DropdownMenuItem(value: 'annual', child: Text(tr('dash_annual'))),
                    ],
                    onChanged: (v) => setS(() => subType = v!),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    decoration: InputDecoration(labelText: tr('dash_search_client'), prefixIcon: const Icon(Icons.search, size: 18)),
                    onChanged: (v) => setS(() => searchQuery = v),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE8EAEF)), borderRadius: BorderRadius.circular(12)),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: filteredUsers.length,
                      itemBuilder: (_, i) {
                        final u = filteredUsers[i];
                        final isSelected = selectedUserId == u.id;
                        final isSelf = me != null && u.id == me.id;
                        return ListTile(
                          dense: true,
                          title: Text(isSelf ? '${u.fullName} (${tr('dash_self')})' : u.fullName, style: TextStyle(fontSize: 12, fontFamily: 'Cairo', fontWeight: isSelf ? FontWeight.w700 : FontWeight.normal)),
                          subtitle: Text(u.username, style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4))),
                          trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF6BA539), size: 18) : null,
                          tileColor: isSelected ? const Color(0xFFEDF7E6) : null,
                          onTap: () => setS(() => selectedUserId = u.id),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: saving ? null : () async {
                        if (imeiCtrl.text.isEmpty || nameCtrl.text.isEmpty || selectedUserId == null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_fill_all'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
                          return;
                        }
                        setS(() => saving = true);
                        final result = await provider.addDevice(imei: imeiCtrl.text.trim(), name: nameCtrl.text.trim(), deviceType: deviceType, userId: selectedUserId!, subscriptionType: subType);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(result['success'] == true ? tr('dash_device_added') : result['error'] ?? tr('dash_failed'), style: const TextStyle(fontFamily: 'Cairo')),
                            backgroundColor: result['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                          ));
                        }
                      },
                      child: saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : Text(tr('dash_add'), style: const TextStyle(fontFamily: 'Cairo')),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAddUserSheet(BuildContext context) {
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String accountType = 'client';
    bool obscure = true;
    bool obscureConfirm = true;
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tr('dash_add_client'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(controller: usernameCtrl, decoration: InputDecoration(labelText: tr('dash_username'))),
                const SizedBox(height: 10),
                TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('dash_full_name'))),
                const SizedBox(height: 10),
                TextField(controller: phoneCtrl, decoration: InputDecoration(labelText: tr('dash_phone')), keyboardType: TextInputType.phone),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordCtrl,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: tr('dash_password'),
                    suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => setS(() => obscure = !obscure)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmCtrl,
                  obscureText: obscureConfirm,
                  decoration: InputDecoration(
                    labelText: tr('dash_confirm_password'),
                    suffixIcon: IconButton(icon: Icon(obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: () => setS(() => obscureConfirm = !obscureConfirm)),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: accountType,
                  decoration: InputDecoration(labelText: tr('dash_account_type')),
                  items: [
                    DropdownMenuItem(value: 'client', child: Text(tr('dash_client'))),
                    // الأدمن فقط يقدر ينشئ ديلر؛ الديلر ينشئ موزع+عميل؛ الموزع عميل فقط
                    if (provider.currentUser?.accountType == 'admin')
                      DropdownMenuItem(value: 'dealer', child: Text(tr('dash_dealer'))),
                    if (provider.currentUser?.accountType == 'admin' || provider.currentUser?.accountType == 'dealer')
                      DropdownMenuItem(value: 'sub_dealer', child: Text(tr('dash_sub_dealer'))),
                  ],
                  onChanged: (v) => setS(() => accountType = v!),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (usernameCtrl.text.isEmpty || passwordCtrl.text.isEmpty || nameCtrl.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_fill_all'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
                        return;
                      }
                      if (passwordCtrl.text != confirmCtrl.text) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_pw_mismatch'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
                        return;
                      }
                      final result = await provider.addUser(username: usernameCtrl.text.trim(), password: passwordCtrl.text, fullName: nameCtrl.text.trim(), accountType: accountType, phone: phoneCtrl.text.trim());
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(result['success'] == true ? tr('dash_client_added') : result['error'] ?? tr('dash_failed'), style: const TextStyle(fontFamily: 'Cairo')),
                          backgroundColor: result['success'] == true ? const Color(0xFF6BA539) : const Color(0xFFC41E3A),
                        ));
                      }
                    },
                    child: Text(tr('dash_add'), style: const TextStyle(fontFamily: 'Cairo')),
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

  void _showAssignCardsSheet(BuildContext context) {
    final provider = context.read<AppProvider>();
    final searchCtrl = TextEditingController();
    String searchQuery = '';
    int? selectedUserId;
    String? selectedUserName;
    int newLifetime = 0;
    int newSubscription = 0;
    int renewLifetime = 0;
    int renewAnnual = 0;
    final notesCtrl = TextEditingController();
    final dealers = provider.users.where((u) => u.isDealer || u.isSubDealer).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final filtered = dealers.where((u) => u.fullName.toLowerCase().contains(searchQuery.toLowerCase()) || u.username.toLowerCase().contains(searchQuery.toLowerCase())).toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 16, right: 16, top: 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                      Row(children: [
                        const Icon(Icons.sync_alt, color: Color(0xFFC41E3A), size: 18),
                        const SizedBox(width: 6),
                        Text(tr('dash_transfer_card'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                      ]),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Align(alignment: Alignment.centerRight, child: Text(tr('dash_dealer_req'), style: const TextStyle(fontSize: 12, color: Color(0xFF8892A4), fontFamily: 'Cairo'))),
                  const SizedBox(height: 6),
                  TextField(
                    controller: searchCtrl,
                    decoration: InputDecoration(hintText: selectedUserName ?? tr('dash_search_dealer'), prefixIcon: const Icon(Icons.search, size: 18)),
                    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                    onChanged: (v) => setS(() => searchQuery = v),
                  ),
                  if (searchQuery.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 140),
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE8EAEF)), borderRadius: BorderRadius.circular(12)),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final u = filtered[i];
                          return ListTile(
                            dense: true,
                            title: Text(u.fullName, textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr, style: const TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                            subtitle: Text(u.accountTypeAr, textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr, style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4))),
                            onTap: () => setS(() {
                              selectedUserId = u.id;
                              selectedUserName = u.fullName;
                              searchQuery = '';
                              searchCtrl.clear();
                            }),
                          );
                        },
                      ),
                    ),
                  ],
                  if (selectedUserName != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFFEDF7E6), borderRadius: BorderRadius.circular(12)),
                        child: Text(selectedUserName!, style: const TextStyle(fontSize: 12, color: Color(0xFF6BA539), fontFamily: 'Cairo')),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _CardCounter(label: tr('dash_new_annual_sub'), color: const Color(0xFF2196F3), value: newSubscription, onChanged: (v) => setS(() => newSubscription = v))),
                    const SizedBox(width: 8),
                    Expanded(child: _CardCounter(label: tr('dash_new_lifetime_sub'), color: const Color(0xFF4CAF50), value: newLifetime, onChanged: (v) => setS(() => newLifetime = v))),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _CardCounter(label: tr('dash_renew_lifetime'), color: const Color(0xFFF59E0B), value: renewLifetime, onChanged: (v) => setS(() => renewLifetime = v))),
                    const SizedBox(width: 8),
                    Expanded(child: _CardCounter(label: tr('dash_renew_annual'), color: const Color(0xFF9C27B0), value: renewAnnual, onChanged: (v) => setS(() => renewAnnual = v))),
                  ]),
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: Text(tr('dash_notes'), style: const TextStyle(fontSize: 12, color: Color(0xFF8892A4), fontFamily: 'Cairo'))),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 3,
                    textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                    decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE8EAEF)))),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setS(() { newLifetime = 0; newSubscription = 0; renewLifetime = 0; renewAnnual = 0; selectedUserId = null; selectedUserName = null; notesCtrl.clear(); searchCtrl.clear(); }),
                        style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFE8EAEF)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        child: Text(tr('dash_reset'), style: const TextStyle(fontFamily: 'Cairo', color: Color(0xFF8892A4))),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(tr('dash_confirm'), style: const TextStyle(fontFamily: 'Cairo')),
                        onPressed: () async {
                          if (selectedUserId == null) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_select_dealer_first'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
                            return;
                          }
                          if (newLifetime == 0 && newSubscription == 0 && renewLifetime == 0 && renewAnnual == 0) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_enter_one_card'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFFC41E3A)));
                            return;
                          }
                          final calls = <Future>[];
                          if (newLifetime > 0) calls.add(provider.assignCards(toUserId: selectedUserId!, cardType: 'new_lifetime', quantity: newLifetime));
                          if (newSubscription > 0) calls.add(provider.assignCards(toUserId: selectedUserId!, cardType: 'new_subscription', quantity: newSubscription));
                          if (renewLifetime > 0) calls.add(provider.assignCards(toUserId: selectedUserId!, cardType: 'renew_lifetime', quantity: renewLifetime));
                          if (renewAnnual > 0) calls.add(provider.assignCards(toUserId: selectedUserId!, cardType: 'renew_annual', quantity: renewAnnual));
                          await Future.wait(calls);
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('dash_cards_transferred'), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: const Color(0xFF6BA539)));
                          }
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTransferDeviceSheet(BuildContext context) {
    final provider = context.read<AppProvider>();
    // كل أجهزة الحساب: المتعيّنة لعملاء + المخزون (البحث يلاقي أي جهاز، مش المخزون فقط).
    // dedup بالـ traccarId عشان لو جهاز ظهر في القائمتين.
    final _seen = <int>{};
    final inventory = [...provider.devices, ...provider.inventory]
        .where((d) => _seen.add(d.traccarId)).toList();
    final clients = provider.users.where((u) => u.isClient || u.isSubDealer).toList();

    DeviceModel? selectedDevice;
    UserModel? selectedClient;
    String deviceSearch = '';
    String clientSearch = '';
    bool loading = false;
    final deviceCtrl = TextEditingController();
    String? transferMsg; // رسالة داخل الموديل (SnackBar بيتخفي ورا الـ bottom sheet)

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final filteredDevices = inventory.where((d) =>
            d.name.toLowerCase().contains(deviceSearch.toLowerCase()) ||
            (d.imei ?? '').contains(deviceSearch)).toList();
          final filteredClients = clients.where((u) =>
            u.fullName.toLowerCase().contains(clientSearch.toLowerCase()) ||
            u.username.toLowerCase().contains(clientSearch.toLowerCase())).toList();

          return Container(
            decoration: BoxDecoration(
              color: Theme.of(ctx).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              left: 16, right: 16, top: 20,
            ),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  Row(children: [
                    const Icon(Icons.swap_horiz, color: Color(0xFF0891B2), size: 18),
                    const SizedBox(width: 6),
                    Text(tr('dash_transfer_device'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
                  ]),
                ]),
                const SizedBox(height: 16),

                Align(alignment: Alignment.centerRight,
                  child: Text(tr('dash_select_device'), style: const TextStyle(fontSize: 12, color: Color(0xFF8892A4), fontFamily: 'Cairo'))),
                const SizedBox(height: 6),
                TextField(
                  controller: deviceCtrl,
                  decoration: InputDecoration(
                    hintText: selectedDevice != null ? selectedDevice!.name : tr('dash_search_device'),
                    prefixIcon: const Icon(Icons.devices_outlined, size: 18),
                    // جهاز مُختار → مسح؛ غير كده → زر QR للبحث بالسيريال
                    suffixIcon: selectedDevice != null
                        ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setS(() { selectedDevice = null; deviceCtrl.clear(); deviceSearch = ''; }))
                        : IconButton(
                            icon: const Icon(Icons.qr_code_scanner, size: 18, color: Color(0xFF0891B2)),
                            tooltip: tr('dash_scan_qr'),
                            onPressed: () async {
                              final code = await Navigator.of(ctx).push<String>(
                                MaterialPageRoute(builder: (_) => const _QrScanScreen()));
                              if (code != null && code.trim().isNotEmpty) {
                                setS(() { deviceCtrl.text = code.trim(); deviceSearch = code.trim(); selectedDevice = null; });
                              }
                            }),
                  ),
                  textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                  onChanged: (v) => setS(() { deviceSearch = v; selectedDevice = null; }),
                ),
                // القائمة تظهر بس لما يبحث (مش كل الأجهزة) — الاسم/السيريال يظهر في النتائج
                if (deviceSearch.isNotEmpty && selectedDevice == null) ...[
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(border: Border.all(color: Theme.of(ctx).dividerColor), borderRadius: BorderRadius.circular(12)),
                    child: filteredDevices.isEmpty
                        ? Padding(padding: const EdgeInsets.all(12),
                            child: Text(tr('no_results'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF8892A4))))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredDevices.length,
                            itemBuilder: (_, i) {
                              final d = filteredDevices[i];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.directions_car_outlined, size: 18, color: Color(0xFF0891B2)),
                                title: Text(d.name, style: const TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                                subtitle: Text(d.imei ?? '', style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4))),
                                onTap: () => setS(() { selectedDevice = d; deviceSearch = ''; deviceCtrl.clear(); }),
                              );
                            }),
                  ),
                ],
                if (selectedDevice != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFFE0F2FE), borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF0891B2)),
                      const SizedBox(width: 6),
                      Text(selectedDevice!.name, style: const TextStyle(fontSize: 12, color: Color(0xFF0891B2), fontFamily: 'Cairo')),
                    ]),
                  ),
                ],

                const SizedBox(height: 16),

                Align(alignment: Alignment.centerRight,
                  child: Text(tr('dash_select_client'), style: const TextStyle(fontSize: 12, color: Color(0xFF8892A4), fontFamily: 'Cairo'))),
                const SizedBox(height: 6),
                TextField(
                  decoration: InputDecoration(
                    hintText: selectedClient != null ? selectedClient!.fullName : tr('dash_search_client'),
                    prefixIcon: const Icon(Icons.person_search_outlined, size: 18),
                    suffixIcon: selectedClient != null
                        ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setS(() => selectedClient = null))
                        : null,
                  ),
                  textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
                  onChanged: (v) => setS(() { clientSearch = v; selectedClient = null; }),
                ),
                if (clientSearch.isNotEmpty && selectedClient == null) ...[
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE8EAEF)), borderRadius: BorderRadius.circular(12)),
                    child: filteredClients.isEmpty
                        ? Padding(padding: const EdgeInsets.all(12),
                            child: Text(tr('no_results'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF8892A4))))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filteredClients.length,
                            itemBuilder: (_, i) {
                              final u = filteredClients[i];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.person_outline, size: 18, color: Color(0xFF6BA539)),
                                title: Text(u.fullName, style: const TextStyle(fontSize: 12, fontFamily: 'Cairo')),
                                subtitle: Text(u.accountTypeAr, style: const TextStyle(fontSize: 10, color: Color(0xFF8892A4))),
                                onTap: () => setS(() { selectedClient = u; clientSearch = ''; transferMsg = null; }),
                              );
                            }),
                  ),
                ],
                if (selectedClient != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFFEDF7E6), borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF6BA539)),
                      const SizedBox(width: 6),
                      Text(selectedClient!.fullName, style: const TextStyle(fontSize: 12, color: Color(0xFF6BA539), fontFamily: 'Cairo')),
                    ]),
                  ),
                ],

                if (transferMsg != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFF59E0B))),
                    child: Row(children: [
                      const Icon(Icons.info_outline, size: 16, color: Color(0xFFB45309)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(transferMsg!, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Color(0xFF92400E), fontFamily: 'Cairo'))),
                    ]),
                  ),
                ],

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: loading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.swap_horiz),
                    label: Text(tr('dash_transfer_device'), style: const TextStyle(fontFamily: 'Cairo')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (selectedDevice != null && selectedClient != null) ? const Color(0xFF0891B2) : Colors.grey,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: (selectedDevice == null || selectedClient == null || loading) ? null : () async {
                      // الجهاز أصلًا في حساب العميل المختار → رسالة داخل الموديل بدل نقل بلا داعي
                      if (selectedDevice!.userId != null && selectedDevice!.userId == selectedClient!.id) {
                        setS(() => transferMsg = '${tr('dash_device_already_at')} ${selectedClient!.fullName}');
                        return;
                      }
                      setS(() { loading = true; transferMsg = null; });
                      try {
                        final r = await ApiService.request('transfer_device', {
                          'imei': selectedDevice!.imei,
                          'userId': selectedClient!.id,
                        });
                        if (!ctx.mounted) return;
                        if (r['success'] == true) {
                          Navigator.pop(ctx);
                          await provider.loadDevices();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('${tr('dash_device_transferred')} ${selectedClient!.fullName}',
                                style: const TextStyle(fontFamily: 'Cairo')),
                            backgroundColor: const Color(0xFF6BA539),
                          ));
                        } else {
                          setS(() { loading = false; transferMsg = r['error']?.toString() ?? r['message']?.toString() ?? tr('api_error'); });
                        }
                      } catch (_) {
                        setS(() { loading = false; transferMsg = tr('api_error'); });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ]),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final user = provider.currentUser;
    final stats = provider.dashStats;
    final cards = provider.cardBalance;

    return RefreshIndicator(
      color: const Color(0xFFC41E3A),
      onRefresh: () async {
        await provider.loadDevices();
        await provider.loadUsers();
        await provider.loadCardBalance();
      },
      child: ListView(
        padding: EdgeInsets.zero,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          const _DashboardSearchBar(),
          _buildIconGrid(context, stats, cards, user),
          const SizedBox(height: 8),
          _buildSectionTitle(tr('dash_quick_actions')),
          _buildQuickActions(context, user),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildIconGrid(BuildContext context, DashboardStats stats, CardBalance cards, UserModel? user) {
    final provider = context.read<AppProvider>();
    final allUsers = provider.users;
    final dealerCount    = allUsers.where((u) => u.isDealer).length;
    final subDealerCount = allUsers.where((u) => u.isSubDealer).length;
    final clientCount    = allUsers.where((u) => u.isClient).length;
    final isAdmin  = user?.isAdmin == true;
    final isDealerAcct = user?.isDealer == true;
    final isDealer = user?.isDealer == true || user?.isSubDealer == true;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ══ الأجهزة ══════════════════════════════════════════════════════════
        _SectionGroup(color: const Color(0xFF2563EB), children: [
          _sectionHeader(tr('dash_sec_devices'), Icons.directions_car_outlined, const Color(0xFF2563EB)),
          const SizedBox(height: 8),
          Row(children: [
            _StatTile(icon: Icons.devices_other_outlined, label: tr('dash_total'),     value: stats.totalDevices,   color: const Color(0xFF2563EB), bg: const Color(0xFFEFF6FF), onTap: () => TabNav.goDevices('all')),
            const SizedBox(width: 8),
            _StatTile(icon: Icons.wifi_outlined,          label: tr('dash_online'),        value: stats.onlineDevices,  color: const Color(0xFF16A34A), bg: const Color(0xFFDCFCE7), onTap: () => TabNav.goDevices('on')),
            const SizedBox(width: 8),
            _StatTile(icon: Icons.speed_outlined,         label: tr('dash_moving'),       value: stats.movingDevices,  color: const Color(0xFF0891B2), bg: const Color(0xFFE0F2FE), onTap: () => TabNav.goDevices('moving')),
            const SizedBox(width: 8),
            _StatTile(icon: Icons.wifi_off_outlined,      label: tr('dash_offline'),    value: stats.offlineDevices, color: const Color(0xFFDC2626), bg: const Color(0xFFFEE2E2), onTap: () => TabNav.goDevices('off')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _StatTile(icon: Icons.warning_amber_outlined,   label: tr('dash_expired'),       value: stats.expiredDevices,  color: const Color(0xFF6B7280), bg: const Color(0xFFF3F4F6)),
            const SizedBox(width: 8),
            _StatTile(icon: Icons.hourglass_empty_outlined, label: tr('dash_needs_activation'), value: stats.needsActivation, color: const Color(0xFFD97706), bg: const Color(0xFFFEF3C7), onTap: () => TabNav.goDevices('inactive')),
            const SizedBox(width: 8),
            const Expanded(child: SizedBox()),
            const SizedBox(width: 8),
            const Expanded(child: SizedBox()),
          ]),
        ]),

        // ══ المخزون (ديلر/موزع فقط) ═════════════════════════════════════════
        if (isDealer) ...[
          const SizedBox(height: 10),
          _SectionGroup(color: const Color(0xFF0D9488), children: [
            _sectionHeader(tr('dash_inventory'), Icons.inventory_2_outlined, const Color(0xFF0D9488)),
            const SizedBox(height: 8),
            Row(children: [
              _StatTile(icon: Icons.inventory_2_outlined, label: tr('dash_inv_total'),    value: stats.inventoryCount,   color: const Color(0xFF0D9488), bg: const Color(0xFFCCFBF1)),
              const SizedBox(width: 8),
              _StatTile(icon: Icons.wifi_outlined,        label: tr('dash_online'),        value: stats.inventoryOnline,  color: const Color(0xFF16A34A), bg: const Color(0xFFDCFCE7)),
              const SizedBox(width: 8),
              _StatTile(icon: Icons.wifi_off_outlined,    label: tr('dash_offline'),    value: stats.inventoryOffline, color: const Color(0xFFDC2626), bg: const Color(0xFFFEE2E2)),
              const SizedBox(width: 8),
              const Expanded(child: SizedBox()),
            ]),
          ]),
        ],

        // ══ الحسابات ══════════════════════════════════════════════════════════
        const SizedBox(height: 10),
        _SectionGroup(color: const Color(0xFF7C3AED), children: [
          _sectionHeader(tr('dash_accounts'), Icons.people_outline, const Color(0xFF7C3AED)),
          const SizedBox(height: 8),
          Row(children: [
            if (isAdmin) ...[
              _StatTile(icon: Icons.storefront_outlined,         label: tr('dash_dealers'),   value: dealerCount,        color: const Color(0xFFDB2777), bg: const Color(0xFFFCE7F3), onTap: () => TabNav.goClients('dealer')),
              const SizedBox(width: 8),
            ],
            if (isAdmin || isDealerAcct) ...[
              _StatTile(icon: Icons.supervisor_account_outlined, label: tr('dash_sub_dealers'),  value: subDealerCount,     color: const Color(0xFF7C3AED), bg: const Color(0xFFF5F3FF), onTap: () => TabNav.goClients('sub')),
              const SizedBox(width: 8),
            ],
            _StatTile(icon: Icons.person_outline,    label: tr('dash_clients'),  value: clientCount,        color: const Color(0xFF2563EB), bg: const Color(0xFFEFF6FF), onTap: () => TabNav.goClients('client')),
            const SizedBox(width: 8),
            _StatTile(icon: Icons.people_outline,    label: tr('dash_inv_total'), value: stats.totalClients, color: const Color(0xFF0D9488), bg: const Color(0xFFCCFBF1), onTap: () => TabNav.goClients('all')),
            if (!isAdmin && !isDealerAcct) ...[const SizedBox(width: 8), const Expanded(child: SizedBox()), const SizedBox(width: 8), const Expanded(child: SizedBox())],
            if (isDealerAcct) ...[const SizedBox(width: 8), const Expanded(child: SizedBox())],
          ]),
        ]),

        // ══ البطاقات (ديلر/موزع فقط) ════════════════════════════════════════
        if (isDealer) ...[
          const SizedBox(height: 10),
          _SectionGroup(color: const Color(0xFFDB2777), children: [
            _sectionHeader(tr('dash_cards'), Icons.credit_card_outlined, const Color(0xFFDB2877)),
            const SizedBox(height: 8),
            Row(children: [
              _StatTile(icon: Icons.credit_card_outlined,   label: tr('dash_annual_sub'),    value: cards.newSubscription, color: const Color(0xFFDB2777), bg: const Color(0xFFFCE7F3)),
              const SizedBox(width: 8),
              _StatTile(icon: Icons.all_inclusive_outlined, label: tr('dash_lifetime_sub'),  value: cards.newLifetime,     color: const Color(0xFF16A34A), bg: const Color(0xFFDCFCE7)),
              const SizedBox(width: 8),
              _StatTile(icon: Icons.autorenew_outlined,     label: tr('dash_renew_annual'),   value: cards.renewAnnual,     color: const Color(0xFF2563EB), bg: const Color(0xFFEFF6FF)),
              const SizedBox(width: 8),
              _StatTile(icon: Icons.loop_outlined,          label: tr('dash_renew_lifetime'), value: cards.renewLifetime,   color: const Color(0xFFD97706), bg: const Color(0xFFFEF3C7)),
            ]),
          ]),
        ],
      ]),
    );
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 15, color: color),
      ),
      const SizedBox(width: 8),
      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color, fontFamily: 'Cairo')),
      const SizedBox(width: 8),
      Expanded(child: Divider(color: color.withOpacity(0.2))),
    ]);
  }

  Widget _buildHero(BuildContext context, UserModel? user, DashboardStats stats) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFC41E3A), Color(0xFF8A0F22)], begin: Alignment.topRight, end: Alignment.bottomLeft)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('مرحباً،', style: TextStyle(color: Color(0xBFFFFFFF), fontSize: 11, fontFamily: 'Cairo')),
                Text(user?.fullName ?? 'المستخدم', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
              ]),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(16)),
                child: Text(user?.accountTypeAr ?? '', style: const TextStyle(color: Colors.white, fontSize: 10, fontFamily: 'Cairo')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            _heroStat(stats.totalDevices.toString(), 'الأجهزة'),
            const SizedBox(width: 8),
            _heroStat(stats.totalClients.toString(), 'العملاء'),
            const SizedBox(width: 8),
            _heroStat(stats.inventoryCount.toString(), 'المخزون'),
          ]),
        ],
      ),
    );
  }

  Widget _heroStat(String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
          Text(label, style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 9, fontFamily: 'Cairo')),
        ]),
      ),
    );
  }

  Widget _buildDevicesCard(BuildContext context, DashboardStats stats) {
    return _BigCard(
      accentColor: const Color(0xFF6BA539),
      child: Column(children: [
        _CardHeader(title: 'الأجهزة', trailing: '${stats.totalDevices} جهاز', trailingColor: const Color(0xFF6BA539)),
        const SizedBox(height: 8),
        Row(children: [
          _StatBox(value: stats.onlineDevices, label: 'متصل', color: const Color(0xFF4CAF50)),
          const SizedBox(width: 5),
          _StatBox(value: stats.movingDevices, label: 'متحرك', color: const Color(0xFF2196F3)),
          const SizedBox(width: 5),
          _StatBox(value: stats.offlineDevices, label: 'غير متصل', color: const Color(0xFFEF5350)),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          _StatBox(value: stats.expiredDevices, label: 'منتهية', color: const Color(0xFF9CA3AF)),
          const SizedBox(width: 5),
          _StatBox(value: stats.needsActivation, label: 'يحتاج تنشيط', color: const Color(0xFFF59E0B)),
        ]),
      ]),
    );
  }

  Widget _buildInventoryCard(BuildContext context, AppProvider provider) {
    final stats = provider.dashStats;
    return _BigCard(
      accentColor: const Color(0xFFF59E0B),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _CardHeader(title: 'المخزون', trailing: 'عرض الكل >', trailingColor: Color(0xFFF59E0B)),
        Text(stats.inventoryCount.toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: Color(0xFFF59E0B), fontFamily: 'Cairo')),
        const Text('أجهزة غير موزعة على عملاء', style: TextStyle(color: Color(0xFF8892A4), fontSize: 9, fontFamily: 'Cairo')),
      ]),
    );
  }

  Widget _buildClientsCard(BuildContext context, DashboardStats stats) {
    return _BigCard(
      accentColor: const Color(0xFF2196F3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _CardHeader(title: 'العملاء', trailing: 'HiMAYA', trailingColor: Color(0xFF2196F3)),
        Text(stats.totalClients.toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: Color(0xFF2196F3), fontFamily: 'Cairo')),
        const Text('إجمالي العملاء المسجلين', style: TextStyle(color: Color(0xFF8892A4), fontSize: 9, fontFamily: 'Cairo')),
      ]),
    );
  }

  Widget _buildCardsCard(BuildContext context, CardBalance cards) {
    return _BigCard(
      accentColor: const Color(0xFFC41E3A),
      child: Column(children: [
        const _CardHeader(title: 'رصيد البطاقات'),
        const SizedBox(height: 8),
        Row(children: [
          _CardTypeBox(value: cards.newLifetime, label: 'جديد مدى الحياة', color: const Color(0xFF4CAF50)),
          const SizedBox(width: 5),
          _CardTypeBox(value: cards.newSubscription, label: 'اشتراك جديد', color: const Color(0xFF2196F3)),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          _CardTypeBox(value: cards.renewLifetime, label: 'تجديد مدى الحياة', color: const Color(0xFFF59E0B)),
          const SizedBox(width: 5),
          _CardTypeBox(value: cards.renewAnnual, label: 'تجديد سنوي', color: const Color(0xFF9C27B0)),
        ]),
      ]),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(title, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
    );
  }

  Widget _buildQuickActions(BuildContext context, UserModel? user) {
    final actions = <_QuickAction>[
      _QuickAction(label: tr('dash_add_client'), icon: Icons.person_add_outlined, color: const Color(0xFF6BA539), bg: const Color(0x1A6BA539), onTap: () => _showAddUserSheet(context)),
      if (user?.isDealer == true || user?.isAdmin == true || user?.isSubDealer == true)
        _QuickAction(label: tr('dash_add_device'), icon: Icons.add_to_queue_outlined, color: const Color(0xFFC41E3A), bg: const Color(0x1AC41E3A), onTap: () => _showAddDeviceSheet(context)),
      if (user?.isDealer == true || user?.isAdmin == true || user?.isSubDealer == true)
        _QuickAction(label: tr('dash_transfer_device'), icon: Icons.swap_horiz_outlined, color: const Color(0xFF0891B2), bg: const Color(0x1A0891B2), onTap: () => _showTransferDeviceSheet(context)),
      if (user?.isDealer == true || user?.isAdmin == true)
        _QuickAction(label: tr('dash_transfer_cards'), icon: Icons.sync_alt_outlined, color: const Color(0xFFF59E0B), bg: const Color(0x1AF59E0B), onTap: () => _showAssignCardsSheet(context)),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.count(
        crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.8,
        children: actions.map((a) => _QuickActionCard(action: a)).toList(),
      ),
    );
  }
}

class _CardCounter extends StatelessWidget {
  final String label;
  final Color color;
  final int value;
  final ValueChanged<int> onChanged;
  const _CardCounter({required this.label, required this.color, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE8EAEF)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(label, textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr, style: TextStyle(fontSize: 10, color: color, fontFamily: 'Cairo', fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _CounterBtn(icon: Icons.add, onTap: () => onChanged(value + 1)),
          Text(value.toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: 'Cairo')),
          _CounterBtn(icon: Icons.remove, onTap: () => onChanged(value > 0 ? value - 1 : 0)),
        ]),
      ]),
    );
  }
}

class _CounterBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CounterBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
        child: Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

class _SectionGroup extends StatelessWidget {
  final Color color;
  final List<Widget> children;
  const _SectionGroup({required this.color, required this.children});
  @override
  Widget build(BuildContext context) {
    final cardColor = Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface;
    final borderColor = Theme.of(context).dividerColor;
    return IntrinsicHeight(
      child: Stack(
        children: [
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2))],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BigCard extends StatelessWidget {
  final Color accentColor;
  final Widget child;
  const _BigCard({required this.accentColor, required this.child});

  @override
  Widget build(BuildContext context) {
    final cardColor = Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface;
    return Container(
      margin: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor, borderRadius: BorderRadius.circular(14),
        border: Border(right: BorderSide(color: accentColor, width: 3)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 1))],
      ),
      child: child,
    );
  }
}

class _CardHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  final Color? trailingColor;
  const _CardHeader({required this.title, this.trailing, this.trailingColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11, fontWeight: FontWeight.w500, fontFamily: 'Cairo')),
        if (trailing != null) Text(trailing!, style: TextStyle(color: trailingColor ?? const Color(0xFF8892A4), fontSize: 10, fontFamily: 'Cairo')),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final int value;
  final String label;
  final Color color;
  const _StatBox({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
        child: Column(children: [
          Text(value.toString(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color, fontFamily: 'Cairo')),
          Text(label, style: const TextStyle(fontSize: 8, color: Color(0xFF8892A4), fontFamily: 'Cairo'), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _CardTypeBox extends StatelessWidget {
  final int value;
  final String label;
  final Color color;
  const _CardTypeBox({required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).dividerColor)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value.toString(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: color, fontFamily: 'Cairo')),
          Text(label, style: const TextStyle(fontSize: 8, color: Color(0xFF8892A4), fontFamily: 'Cairo')),
        ]),
      ),
    );
  }
}

class _QuickAction {
  final String label;
  final IconData icon;
  final Color color;
  final Color bg;
  final VoidCallback onTap;
  const _QuickAction({required this.label, required this.icon, required this.color, required this.bg, required this.onTap});
}

class _QuickActionCard extends StatelessWidget {
  final _QuickAction action;
  const _QuickActionCard({required this.action});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: action.onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 3, offset: const Offset(0, 1))],
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: action.bg, borderRadius: BorderRadius.circular(11)),
            child: Icon(action.icon, color: action.color, size: 22),
          ),
          const SizedBox(height: 6),
          Text(action.label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.onSurface, fontFamily: 'Cairo'), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

// ─── Stat Tile (clean card, colored icon bg) ─────────────────────────────────

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  final Color bg;
  final VoidCallback? onTap;
  const _StatTile({required this.icon, required this.label, required this.value, required this.color, required this.bg, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 1))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: color, size: 17),
            ),
            const SizedBox(height: 4),
            Text(value.toString(),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color, fontFamily: 'Cairo')),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 9, color: Color(0xFF8892A4), fontFamily: 'Cairo'),
                textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.visible),
          ],
        ),
        ),
      ),
    );
  }
}

// ── شريط البحث العام أعلى الداشبورد (اسم العميل / اسم العربية / السيريال + QR) ──
class _DashboardSearchBar extends StatefulWidget {
  const _DashboardSearchBar();
  @override
  State<_DashboardSearchBar> createState() => _DashboardSearchBarState();
}

class _DashboardSearchBarState extends State<_DashboardSearchBar> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // كل الأجهزة اللي المستخدم يقدر يوصلها (أجهزة العملاء + المخزون) بدون تكرار
  List<DeviceModel> _allDevices(AppProvider p) {
    final map = <int, DeviceModel>{};
    for (final d in [...p.devices, ...p.inventory]) {
      map[d.id] = d;
    }
    return map.values.toList();
  }

  // الأجهزة: بحث بالاسم أو السيريال فقط (مش باسم المالك — عشان بحث اسم الحساب
  // ميطلّعش كل أجهزته، بل يظهر الحساب نفسه في قسم الحسابات).
  List<DeviceModel> _matchDevices(AppProvider p) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final list = _allDevices(p).where((d) =>
        d.name.toLowerCase().contains(q) ||
        d.imei.toLowerCase().contains(q)).toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list.take(12).toList();
  }

  // الحسابات: بحث بالاسم أو اسم المستخدم → يفتح داشبورد (بروفايل) الحساب
  List<UserModel> _matchAccounts(AppProvider p) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final list = p.users.where((u) =>
        u.fullName.toLowerCase().contains(q) ||
        u.username.toLowerCase().contains(q)).toList();
    list.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    return list.take(12).toList();
  }

  void _openAccount(UserModel u) {
    FocusScope.of(context).unfocus();
    setState(() { _q = ''; _ctrl.clear(); });
    openUserProfile(context, u);
  }

  void _openDevice(DeviceModel d) {
    FocusScope.of(context).unfocus();
    setState(() { _q = ''; _ctrl.clear(); });
    final provider = context.read<AppProvider>();
    final nav = Navigator.of(context, rootNavigator: true);
    // نلاقي العميل صاحب الجهاز (لو جهاز عميل مش مخزون)
    UserModel? owner;
    if (d.userId != null) {
      for (final u in provider.users) {
        if (u.id == d.userId) { owner = u; break; }
      }
    }
    // جهاز تابع لعميل → افتح بروفايل (داشبورد) العميل الأول، عشان الرجوع من الخريطة
    // يوديك على العميل التابع له (تعرف مين صاحب الجهاز) مش الداشبورد الرئيسي.
    if (owner != null) {
      openUserProfile(context, owner);
    }
    // ثم خريطة الجهاز فوق البروفايل — تعرض الجهاز بغضّ النظر عن scope الخريطة الرئيسية.
    nav.push(MaterialPageRoute(
      builder: (_) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFC41E3A),
            foregroundColor: Colors.white,
            title: Text(d.name.isNotEmpty ? d.name : d.imei,
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
          ),
          body: MapScreen(initialDevices: [d], viewAsUserId: d.userId),
        ),
      ),
    ));
  }

  Future<void> _scanQr() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanScreen()),
    );
    if (code == null || !mounted) return;
    final raw = code.trim();
    final p = context.read<AppProvider>();
    DeviceModel? found;
    for (final d in _allDevices(p)) {
      final imei = d.imei.trim();
      if (imei.isNotEmpty && (imei == raw || raw.contains(imei) || imei.contains(raw))) {
        found = d;
        break;
      }
    }
    if (!mounted) return;
    if (found != null) {
      _openDevice(found);
    } else {
      // مفيش جهاز بنفس السيريال → حُط الكود في البحث لعرض أي مطابقة نصية
      setState(() { _q = raw; _ctrl.text = raw; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('dash_qr_no_match'), style: const TextStyle(fontFamily: 'Cairo')),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppProvider>();
    final accounts = _matchAccounts(p);
    final devices = _matchDevices(p);
    final hasResults = accounts.isNotEmpty || devices.isNotEmpty;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final fieldBg = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E2530) : const Color(0xFFF1F3F6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      child: Column(children: [
        Container(
          decoration: BoxDecoration(color: fieldBg, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const SizedBox(width: 12),
            Icon(Icons.search, size: 20, color: onSurface.withOpacity(0.5)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                onChanged: (v) => setState(() => _q = v),
                style: TextStyle(fontSize: 13, fontFamily: 'Cairo', color: onSurface),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: tr('dash_global_search'),
                  hintStyle: TextStyle(fontSize: 12, fontFamily: 'Cairo', color: onSurface.withOpacity(0.45)),
                ),
              ),
            ),
            if (_q.isNotEmpty)
              InkWell(
                onTap: () => setState(() { _q = ''; _ctrl.clear(); }),
                child: Padding(padding: const EdgeInsets.all(6), child: Icon(Icons.close, size: 18, color: onSurface.withOpacity(0.5))),
              ),
            Container(width: 1, height: 24, color: onSurface.withOpacity(0.12)),
            InkWell(
              onTap: _scanQr,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Icon(Icons.qr_code_scanner, size: 22, color: Color(0xFFC41E3A)),
              ),
            ),
          ]),
        ),
        if (_q.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: onSurface.withOpacity(0.08)),
            ),
            child: !hasResults
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(tr('dash_search_no_results'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, fontFamily: 'Cairo', color: onSurface.withOpacity(0.5))),
                )
              : Column(children: [
                  // الحسابات أولاً (بحث بالاسم → يفتح داشبورد الحساب)
                  for (int i = 0; i < accounts.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: onSurface.withOpacity(0.06)),
                    _AccountResultRow(user: accounts[i], onTap: () => _openAccount(accounts[i])),
                  ],
                  if (accounts.isNotEmpty && devices.isNotEmpty)
                    Divider(height: 1, thickness: 1, color: onSurface.withOpacity(0.10)),
                  // ثم الأجهزة (بحث بالسيريال/اسم العربية → يفتح الخريطة)
                  for (int i = 0; i < devices.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: onSurface.withOpacity(0.06)),
                    _SearchResultRow(device: devices[i], onTap: () => _openDevice(devices[i])),
                  ],
                ]),
          ),
        ],
      ]),
    );
  }
}

// صف نتيجة حساب في البحث — يفتح داشبورد (بروفايل) الحساب
class _AccountResultRow extends StatelessWidget {
  final UserModel user;
  final VoidCallback onTap;
  const _AccountResultRow({required this.user, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Container(
            width: 30, height: 30,
            decoration: const BoxDecoration(color: Color(0x1AC41E3A), shape: BoxShape.circle),
            child: const Icon(Icons.person_outline, size: 17, color: Color(0xFFC41E3A)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(user.fullName.isNotEmpty ? user.fullName : user.username,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo', color: onSurface),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(user.accountTypeAr,
                  style: TextStyle(fontSize: 10, fontFamily: 'Cairo', color: onSurface.withOpacity(0.5)),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.dashboard_outlined, size: 17, color: Color(0xFF2563EB)),
        ]),
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  final DeviceModel device;
  final VoidCallback onTap;
  const _SearchResultRow({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final Color dot;
    if (device.isInactive)      dot = const Color(0xFF9E9E9E);
    else if (device.isMoving)   dot = const Color(0xFF6BA539);
    else if (device.isOnline)   dot = const Color(0xFF2196F3);
    else                        dot = const Color(0xFF9E9E9E);
    final owner = device.userName?.trim() ?? '';
    final sub = [device.imei, if (owner.isNotEmpty) owner].join('  •  ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device.name.isNotEmpty ? device.name : device.imei,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'Cairo', color: onSurface),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(sub,
                  style: TextStyle(fontSize: 10, fontFamily: 'Cairo', color: onSurface.withOpacity(0.5)),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.place_outlined, size: 18, color: Color(0xFFC41E3A)),
        ]),
      ),
    );
  }
}

// ── شاشة مسح الباركود/QR ── (تُرجّع النص المقروء عبر Navigator.pop)
class _QrScanScreen extends StatefulWidget {
  const _QrScanScreen();
  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: const Color(0xFFC41E3A),
          foregroundColor: Colors.white,
          title: Text(tr('dash_scan_qr'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
        ),
        body: Stack(alignment: Alignment.center, children: [
          MobileScanner(onDetect: _onDetect),
          IgnorePointer(
            child: Container(
              width: 230, height: 230,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withOpacity(0.9), width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
