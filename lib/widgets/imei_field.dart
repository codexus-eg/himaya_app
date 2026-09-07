import 'package:flutter/material.dart';

/// حقل السيريال في نماذج إضافة الجهاز.
///
/// يعالج مشكلتين لاحظهما المستخدم أثناء الإدخال:
///  • اللوحة الرقمية لا تعرض خيار «لصق» — ومعظم السيريالات تُنسَخ لا تُكتب،
///    فنستخدم لوحة كاملة مع تعطيل التصحيح والاقتراحات (تفسد الأرقام الطويلة).
///  • الخروج لتطبيق آخر لنسخ السيريال يُنزل لوحة المفاتيح، ولا يعيدها أندرويد
///    عند الرجوع — فنستعيد التركيز إن كان الحقل هو المُركَّز قبل الخروج.
class ImeiField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final TextStyle? style;

  const ImeiField({
    super.key,
    required this.controller,
    required this.decoration,
    this.style,
  });

  @override
  State<ImeiField> createState() => _ImeiFieldState();
}

class _ImeiFieldState extends State<ImeiField> with WidgetsBindingObserver {
  final _focus = FocusNode();
  bool _wasFocused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _wasFocused = _focus.hasFocus;
    } else if (state == AppLifecycleState.resumed && _wasFocused) {
      // تأخير قصير: طلب التركيز فور الرجوع يسبق استعادة النافذة فيُهمَل
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && _wasFocused) _focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      style: widget.style,
      keyboardType: TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: widget.decoration,
    );
  }
}
