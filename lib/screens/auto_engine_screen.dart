import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/i18n.dart';

/// يفتح شاشة «التشغيل والإيقاف التلقائي».
///
/// [ownerUserId] صاحب الأجهزة: العميل يمرّر حسابه، ومزوّد الخدمة يمرّر حساب
/// العميل المعروض. السيرفر يتحقق من الصلاحية في الحالتين.
void openAutoEngine(BuildContext context, int ownerUserId, {String? subtitle}) {
  Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    builder: (_) => Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: AutoEngineScreen(ownerUserId: ownerUserId, subtitle: subtitle),
    ),
  ));
}

class AutoEngineScreen extends StatefulWidget {
  final int ownerUserId;
  final String? subtitle;
  const AutoEngineScreen({super.key, required this.ownerUserId, this.subtitle});

  @override
  State<AutoEngineScreen> createState() => _AutoEngineScreenState();
}

class _AutoEngineScreenState extends State<AutoEngineScreen> {
  static const _red = Color(0xFFC41E3A);
  static const _green = Color(0xFF6BA539);
  static const _blue = Color(0xFF1565C0);

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _body([Map<String, dynamic>? extra]) =>
      {'owner_user_id': widget.ownerUserId, ...?extra};

  Future<void> _load({int attempt = 0}) async {
    if (mounted) setState(() => _error = null);
    try {
      final r = await ApiService.request('get_auto_engine', _body());
      final groups = r['groups'];
      final rules = r['rules'];
      final devices = r['devices'];
      // لا نُفرِّغ القوائم عند فشل عابر — نبقي المعروض ونعرض خطأ
      if (groups is List && rules is List && devices is List) {
        if (!mounted) return;
        setState(() {
          _groups = groups.cast<Map<String, dynamic>>();
          _rules = rules.cast<Map<String, dynamic>>();
          _devices = devices.cast<Map<String, dynamic>>();
          _loading = false;
        });
        return;
      }
      throw Exception(r['error'] ?? 'bad response');
    } catch (_) {
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) return _load(attempt: attempt + 1);
        return;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('error');
      });
    }
  }

  void _toast(String msg, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: bad ? _red : _green,
      duration: const Duration(seconds: 2),
    ));
  }

  /// القاعدة الخاصة بنطاق معيّن، أو null
  Map<String, dynamic>? _ruleFor({required bool all, int groupId = 0}) {
    for (final r in _rules) {
      if (all && r['scope'] == 'all') return r;
      if (!all && r['scope'] == 'group' && (r['group_id'] as num?)?.toInt() == groupId) return r;
    }
    return null;
  }

  int _countFor({required bool all, int groupId = 0}) {
    if (!all) return _devices.where((d) => d['group_id'] == groupId).length;
    // "الكل" يستثني الأجهزة التي مجموعتها لها قاعدة خاصة
    final ruledGroups = _rules
        .where((r) => r['scope'] == 'group')
        .map((r) => (r['group_id'] as num).toInt())
        .toSet();
    return _devices.where((d) {
      final g = d['group_id'];
      return g == null || !ruledGroups.contains(g);
    }).length;
  }

  // ── تنسيق الوقت ───────────────────────────────────────────────────────────
  TimeOfDay? _parse(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final p = hhmm.split(':');
    if (p.length < 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _fmt(String? hhmm) {
    final t = _parse(hhmm);
    if (t == null) return tr('ae_not_set');
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final mm = t.minute.toString().padLeft(2, '0');
    final suffix = I18n.isAr ? (t.hour < 12 ? 'ص' : 'م') : (t.hour < 12 ? 'AM' : 'PM');
    return '$h12:$mm $suffix';
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  // ── حفظ قاعدة ─────────────────────────────────────────────────────────────
  Future<void> _saveRule({
    required bool all,
    int groupId = 0,
    String? stop,
    String? start,
  }) async {
    final r = await ApiService.request('save_auto_rule', _body({
      'scope': all ? 'all' : 'group',
      if (!all) 'group_id': groupId,
      'stop_time': stop ?? '',
      'start_time': start ?? '',
    }));
    if (r['success'] == true) {
      _toast(tr('ae_saved'));
      await _load();
    } else {
      _toast(tr('error'), bad: true);
    }
  }

  Future<void> _pickTime({
    required bool all,
    int groupId = 0,
    required bool isStop,
  }) async {
    final rule = _ruleFor(all: all, groupId: groupId);
    // الأقواس ضرورية: `? x?['k'] :` يلتبس على محلّل Dart بين الشرطي و null-aware
    final cur = _parse(isStop ? (rule?['stop_time'] as String?) : (rule?['start_time'] as String?));
    final picked = await showTimePicker(
      context: context,
      initialTime: cur ?? TimeOfDay(hour: isStop ? 22 : 6, minute: 0),
      builder: (ctx, child) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
    );
    if (picked == null) return;
    final v = '${_two(picked.hour)}:${_two(picked.minute)}';
    await _saveRule(
      all: all,
      groupId: groupId,
      stop: isStop ? v : (rule?['stop_time'] as String?),
      start: isStop ? (rule?['start_time'] as String?) : v,
    );
  }

  Future<void> _clearTimes({required bool all, int groupId = 0}) async {
    // إرسال الوقتين فارغين = حذف القاعدة على السيرفر
    await _saveRule(all: all, groupId: groupId, stop: '', start: '');
  }

  // ── المجموعات ─────────────────────────────────────────────────────────────
  Future<void> _groupDialog({Map<String, dynamic>? existing}) async {
    final ctrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(existing == null ? tr('ae_new_group') : tr('edit'),
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 16)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: const TextStyle(fontFamily: 'Cairo'),
            decoration: InputDecoration(
              labelText: tr('ae_group_name'),
              labelStyle: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(tr('save'), style: const TextStyle(fontFamily: 'Cairo'))),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    final r = await ApiService.request('save_device_group', _body({
      if (existing != null) 'id': existing['id'],
      'name': name,
    }));
    if (r['success'] == true) {
      await _load();
    } else {
      _toast(r['error'] == 'duplicate' ? tr('ae_dup_group') : tr('error'), bad: true);
    }
  }

  Future<void> _deleteGroup(Map<String, dynamic> g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(g['name'] as String? ?? '',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 16)),
          content: Text(tr('ae_del_group_q'), style: const TextStyle(fontFamily: 'Cairo')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('delete'),
                    style: const TextStyle(fontFamily: 'Cairo', color: _red))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final r = await ApiService.request('delete_device_group', _body({'id': g['id']}));
    if (r['success'] == true) {
      await _load();
    } else {
      _toast(tr('error'), bad: true);
    }
  }

  Future<void> _pickDevices(Map<String, dynamic> g) async {
    final gid = (g['id'] as num).toInt();
    final selected = _devices
        .where((d) => d['group_id'] == gid)
        .map((d) => (d['id'] as num).toInt())
        .toSet();

    final result = await Navigator.of(context).push<Set<int>>(MaterialPageRoute(
      builder: (_) => Directionality(
        textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: _DevicePicker(
          title: g['name'] as String? ?? '',
          devices: _devices,
          initial: selected,
          groupId: gid,
          groups: _groups,
        ),
      ),
    ));
    if (result == null) return;

    final added = result.difference(selected).toList();
    final removed = selected.difference(result).toList();
    if (added.isEmpty && removed.isEmpty) return;

    if (added.isNotEmpty) {
      await ApiService.request(
          'assign_device_group', _body({'group_id': gid, 'device_ids': added}));
    }
    if (removed.isNotEmpty) {
      await ApiService.request(
          'assign_device_group', _body({'group_id': 0, 'device_ids': removed}));
    }
    _toast(tr('ae_saved'));
    await _load();
  }

  // ── البناء ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('ae_title'),
                style: const TextStyle(
                    fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
              Text(widget.subtitle!,
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontSize: 11, color: Colors.white70)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                children: [
                  if (_error != null) _errorBar(),
                  _hintCard(),
                  const SizedBox(height: 10),
                  _scopeCard(all: true),
                  for (final g in _groups) ...[
                    const SizedBox(height: 10),
                    _scopeCard(all: false, group: g),
                  ],
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => _groupDialog(),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(tr('ae_new_group'),
                        style: const TextStyle(fontFamily: 'Cairo')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _blue,
                      side: const BorderSide(color: _blue),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                  if (_devices.isEmpty) ...[
                    const SizedBox(height: 24),
                    Center(
                      child: Text(tr('ae_empty'),
                          style: const TextStyle(
                              fontFamily: 'Cairo', color: Colors.grey, fontSize: 13)),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _errorBar() => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: const Color(0x1AC41E3A), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Icon(Icons.error_outline, color: _red, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_error!,
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: _red))),
          TextButton(
              onPressed: _load,
              child: Text(tr('retry'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12))),
        ]),
      );

  Widget _hintCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0x141565C0), borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 17, color: _blue),
          const SizedBox(width: 8),
          Expanded(
              child: Text(tr('ae_hint'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontSize: 11.5, height: 1.5, color: _blue))),
        ]),
      );

  Widget _scopeCard({required bool all, Map<String, dynamic>? group}) {
    final gid = all ? 0 : (group!['id'] as num).toInt();
    final rule = _ruleFor(all: all, groupId: gid);
    final count = _countFor(all: all, groupId: gid);
    final title = all ? tr('ae_all_devices') : (group!['name'] as String? ?? '');
    final active = rule != null;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: active ? _green.withOpacity(.45) : Colors.grey.withOpacity(.25)),
      ),
      child: Column(children: [
        // الرأس
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(children: [
            Icon(all ? Icons.select_all : Icons.folder_outlined,
                size: 18, color: active ? _green : Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700)),
                  Text(tr('ae_devices_n', {'n': '$count'}),
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            if (!all) ...[
              IconButton(
                  onPressed: () => _groupDialog(existing: group),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  color: Colors.grey,
                  visualDensity: VisualDensity.compact),
              IconButton(
                  onPressed: () => _deleteGroup(group!),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: _red,
                  visualDensity: VisualDensity.compact),
            ],
          ]),
        ),
        // الوقتان
        Row(children: [
          Expanded(
              child: _timeTile(
                  label: tr('ae_stop_time'),
                  value: _fmt(rule?['stop_time'] as String?),
                  icon: Icons.power_settings_new,
                  color: _red,
                  onTap: () => _pickTime(all: all, groupId: gid, isStop: true))),
          Container(width: 1, height: 46, color: Colors.grey.withOpacity(.2)),
          Expanded(
              child: _timeTile(
                  label: tr('ae_start_time'),
                  value: _fmt(rule?['start_time'] as String?),
                  icon: Icons.lock_open,
                  color: _green,
                  onTap: () => _pickTime(all: all, groupId: gid, isStop: false))),
        ]),
        // التذييل
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(children: [
            if (all)
              Expanded(
                  child: Text(tr('ae_all_hint'),
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontSize: 10, color: Colors.grey)))
            else
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _pickDevices(group!),
                    icon: const Icon(Icons.checklist, size: 16),
                    label: Text(tr('ae_pick_devices'),
                        style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
                    style: TextButton.styleFrom(
                        foregroundColor: _blue, visualDensity: VisualDensity.compact),
                  ),
                ),
              ),
            if (active)
              TextButton(
                onPressed: () => _clearTimes(all: all, groupId: gid),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: Text(tr('ae_clear_times'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontSize: 11, color: Colors.grey)),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _timeTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontSize: 11, color: Colors.grey)),
            ]),
            const SizedBox(height: 3),
            Text(value,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: color)),
          ]),
        ),
      );
}

// ─── شاشة اختيار الأجهزة ─────────────────────────────────────────────────────
class _DevicePicker extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> groups;
  final Set<int> initial;
  final int groupId;
  const _DevicePicker({
    required this.title,
    required this.devices,
    required this.groups,
    required this.initial,
    required this.groupId,
  });

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  late Set<int> _sel;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _sel = {...widget.initial};
  }

  String _groupName(int? gid) {
    if (gid == null) return tr('ae_ungrouped');
    for (final g in widget.groups) {
      if ((g['id'] as num).toInt() == gid) return g['name'] as String? ?? '';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.devices.where((d) {
      if (_q.isEmpty) return true;
      final n = (d['name'] ?? '').toString().toLowerCase();
      return n.contains(_q.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(widget.title,
            style: const TextStyle(
                fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _sel),
            child: Text(tr('save'),
                style: const TextStyle(fontFamily: 'Cairo', color: Colors.white)),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              hintText: tr('search'),
              hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final d = list[i];
              final id = (d['id'] as num).toInt();
              final gid = d['group_id'] == null ? null : (d['group_id'] as num).toInt();
              // جهاز في مجموعة أخرى: يُنقل عند الاختيار (مجموعة واحدة لكل جهاز)
              final inOther = gid != null && gid != widget.groupId;
              return CheckboxListTile(
                value: _sel.contains(id),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _sel.add(id);
                  } else {
                    _sel.remove(id);
                  }
                }),
                dense: true,
                title: Text((d['name'] ?? '').toString(),
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                subtitle: inOther
                    ? Text(_groupName(gid),
                        style: const TextStyle(
                            fontFamily: 'Cairo', fontSize: 10, color: Color(0xFFF59E0B)))
                    : null,
              );
            },
          ),
        ),
      ]),
    );
  }
}
