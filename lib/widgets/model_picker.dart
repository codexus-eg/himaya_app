import 'package:flutter/material.dart';
import '../services/i18n.dart';

/// Canonical device-model list (kept identical to the web app.jsx list).
const List<String> kDeviceModels = [
  'GT06N', 'GT06E', 'GT06', 'GT02A', 'GK310', 'JM-VL01',
  'TK103', 'TK103B', 'TK303', 'TK305', 'TK306',
  'FMB920', 'FMB910', 'FMB003', 'FMB125', 'FMB130', 'FMC130', 'FMC640',
  'FMB202', 'FMB204', 'FMT100',
  'W15L', 'S06U', 'S5', 'EV404', 'TR06', 'OBD', 'Teltonika',
];

/// Opens a searchable dialog to pick a device model. Returns the chosen value
/// (or null if dismissed). When [includeOther] is true an 'OTHER' entry is added.
Future<String?> showModelPicker(BuildContext context,
    {String? current, bool includeOther = false}) {
  final models =
      includeOther ? <String>[...kDeviceModels, 'OTHER'] : kDeviceModels;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      String q = '';
      return StatefulBuilder(builder: (ctx, setS) {
        final ql = q.trim().toLowerCase();
        final filtered = ql.isEmpty
            ? models
            : models.where((m) => m.toLowerCase().contains(ql)).toList();
        return Directionality(
          textDirection: I18n.isAr ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Text(tr('dash_device_type')),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      hintText: tr('search'),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setS(() => q = v),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(tr('search')),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: filtered.length,
                            itemBuilder: (c, i) {
                              final m = filtered[i];
                              return ListTile(
                                dense: true,
                                title: Text(m, textDirection: TextDirection.ltr),
                                selected: m == current,
                                trailing: m == current
                                    ? const Icon(Icons.check,
                                        color: Color(0xFF6BA539))
                                    : null,
                                onTap: () => Navigator.pop(ctx, m),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('cancel')),
              ),
            ],
          ),
        );
      });
    },
  );
}

/// Drop-in replacement for the device-type DropdownButtonFormField:
/// a labeled field that opens [showModelPicker] when tapped.
class ModelPickerField extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final bool includeOther;
  const ModelPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.includeOther = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final r = await showModelPicker(context,
            current: value, includeOther: includeOther);
        if (r != null) onChanged(r);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(child: Text(value, textDirection: TextDirection.ltr)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
