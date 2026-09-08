import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/i18n.dart';

// ─── الأجهزة الداخلة على الحساب ──────────────────────────────────────────
// تُفتح من «حسابي» (بلا userId = جلساتي) أو من بروفايل حساب (المزوّد يرى جلسات
// عميله ويُخرج منها). صار لها معنى بعد أن أصبحت الجلسة تعيش سنة بدل أسبوع:
// هاتف ضائع يبقى داخلًا، فلا بد من رؤية الأجهزة وإخراج ما لا يعرفه صاحبها.
//
// الحماية كلها على السيرفر: `userManages` للشجرة، وقيد `user_id` في جملة الحذف
// — فلا يُخرج أحد جلسة خارج نطاقه مهما أرسل من معرّفات.
//
// `canRevoke=false` للعميل: كل الجلسات دخلت بنفس اسم المستخدم وكلمة المرور، فلا
// شيء في النظام يميّز جهاز المالك الفعلي من غيره — ومن يضغط «إخراج» قد يقطع
// المالك نفسه. الإخراج بيد المزوّد. والسيرفر يرفضه للعميل أصلًا، وهذا إخفاء عرض.
void openSessions(BuildContext context, {int? userId, String? subtitle, bool canRevoke = true}) {
  Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    builder: (_) => SessionsScreen(userId: userId, subtitle: subtitle, canRevoke: canRevoke),
  ));
}

class SessionsScreen extends StatefulWidget {
  final int? userId;
  final String? subtitle;
  final bool canRevoke;
  const SessionsScreen({super.key, this.userId, this.subtitle, this.canRevoke = true});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<dynamic> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([int attempt = 0]) async {
    if (mounted) setState(() { _loading = true; _error = null; });
    final r = await ApiService.request('get_sessions', {
      if (widget.userId != null) 'user_id': widget.userId,
    });
    if (!mounted) return;
    final raw = r['sessions'];
    if (raw is List) {
      setState(() { _sessions = raw; _loading = false; });
    } else if (attempt < 2) {
      // فشل عابر على شبكة الموبايل — نعيد المحاولة بدل إظهار خطأ
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _load(attempt + 1);
    } else {
      setState(() { _loading = false; _error = r['error']?.toString() ?? tr('cl_fail'); });
    }
  }

  Future<void> _revoke(Map s) async {
    const cairo = TextStyle(fontFamily: 'Cairo');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Theme.of(c).colorScheme.surface,
        title: Text(tr('ses_revoke_q'), style: cairo.copyWith(fontSize: 15, fontWeight: FontWeight.bold)),
        content: Text(s['name']?.toString() ?? '', style: cairo.copyWith(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cl_cancel'), style: cairo)),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('ses_revoke'),
                style: cairo.copyWith(color: const Color(0xFFEF5350), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final r = await ApiService.request('revoke_session', {
      'session_id': s['id'],
      if (widget.userId != null) 'user_id': widget.userId,
    });
    if (!mounted) return;
    if (r['success'] == true) {
      setState(() => _sessions.removeWhere((x) => x['id'] == s['id']));
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('ses_revoked'), style: const TextStyle(fontFamily: 'Cairo'))));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['error']?.toString() ?? tr('cl_fail'),
              style: const TextStyle(fontFamily: 'Cairo'))));
    }
  }

  String _ago(String? iso) {
    final d = DateTime.tryParse((iso ?? '').replaceFirst(' ', 'T'));
    if (d == null) return '—';
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 2) return tr('ses_now');
    if (m < 60) return tr('ses_min_ago', {'n': '$m'});
    final h = m ~/ 60;
    if (h < 24) return tr('ses_hr_ago', {'n': '$h'});
    return tr('ses_day_ago', {'n': '${h ~/ 24}'});
  }

  @override
  Widget build(BuildContext context) {
    const cairo = TextStyle(fontFamily: 'Cairo');
    final onS = Theme.of(context).colorScheme.onSurface;
    return Directionality(
      textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('ses_title'), style: cairo.copyWith(fontSize: 16, fontWeight: FontWeight.bold)),
              if (widget.subtitle != null)
                Text(widget.subtitle!, style: cairo.copyWith(fontSize: 11, color: Colors.grey)),
            ],
          ),
          actions: [IconButton(onPressed: _loading ? null : () => _load(), icon: const Icon(Icons.refresh))],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _error != null
                ? Center(child: Text(_error!, style: cairo.copyWith(color: Colors.grey)))
                : _sessions.isEmpty
                    ? Center(child: Text(tr('ses_none'), style: cairo.copyWith(color: Colors.grey)))
                    : ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            child: Text(tr('ses_count', {'n': '${_sessions.length}'}),
                                style: cairo.copyWith(fontSize: 12, color: Colors.grey)),
                          ),
                          if (!widget.canRevoke)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                              child: Text(tr('ses_view_only'),
                                  style: cairo.copyWith(fontSize: 11, color: const Color(0xFFF59E0B))),
                            ),
                          const SizedBox(height: 6),
                          ..._sessions.map((s) {
                            final cur = s['current'] == true;
                            final ip = (s['ip'] ?? '').toString();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: cur ? const Color(0xFF0D9488) : Colors.grey.withOpacity(.22),
                                  width: cur ? 1.4 : 1,
                                ),
                              ),
                              child: Row(children: [
                                Icon(Icons.smartphone,
                                    size: 22, color: cur ? const Color(0xFF0D9488) : Colors.grey),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Flexible(
                                        child: Text(s['name']?.toString() ?? '',
                                            style: cairo.copyWith(
                                                fontSize: 13, fontWeight: FontWeight.bold, color: onS),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      if (cur) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(
                                              color: const Color(0x1A0D9488),
                                              borderRadius: BorderRadius.circular(5)),
                                          child: Text(tr('ses_this'),
                                              style: cairo.copyWith(
                                                  fontSize: 9, color: const Color(0xFF0D9488))),
                                        ),
                                      ],
                                    ]),
                                    const SizedBox(height: 3),
                                    Text('${tr('ses_last_use')}: ${_ago(s['last_used']?.toString())}',
                                        style: cairo.copyWith(fontSize: 11, color: Colors.grey)),
                                    if (ip.isNotEmpty)
                                      Text('IP $ip',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                          textDirection: TextDirection.ltr),
                                  ]),
                                ),
                                if (!cur && widget.canRevoke)
                                  TextButton(
                                    onPressed: () => _revoke(s as Map),
                                    child: Text(tr('ses_revoke'),
                                        style: cairo.copyWith(fontSize: 12, color: const Color(0xFFEF5350))),
                                  ),
                              ]),
                            );
                          }),
                        ],
                      ),
      ),
    );
  }
}
