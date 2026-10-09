import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';

// ---------------------------------------------------------------------------
// Rights
// ---------------------------------------------------------------------------

bool crmCan(ApiClient api, String perm) {
  final u = api.user;
  if (u == null) return false;
  return u.isAdmin || u.can(perm);
}

/// Reads the CRM (activities, tasks, segments…).
bool crmView(ApiClient api) => crmCan(api, 'crm.view');

/// Writes in the CRM.
bool crmEdit(ApiClient api) => crmCan(api, 'crm.edit');

/// Contacts, tags and files: crm.edit OR partners.edit.
bool crmEditFiche(ApiClient api) => crmEdit(api) || crmCan(api, 'partners.edit');

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-10-09" → "09/10/2026" (ISO timestamps → local date).
String crmDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  if (iso.length == 10) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : '${_two(d.day)}/${_two(d.month)}/${d.year}';
  }
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? iso : '${_two(d.day)}/${_two(d.month)}/${d.year}';
}

/// "09/10/2026 à 08:15" for a timestamp.
String crmDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  if (iso.length == 10) return crmDate(iso);
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  return '${_two(d.day)}/${_two(d.month)}/${d.year} à ${_two(d.hour)}:${_two(d.minute)}';
}

String isoDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

String monthKey(DateTime d) => '${d.year}-${_two(d.month)}';

const _monthNames = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
  'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
];

/// "2026-10" → "octobre 2026".
String monthLabel(String key) {
  final p = key.split('-');
  if (p.length != 2) return key;
  final m = int.tryParse(p[1]) ?? 1;
  return '${_monthNames[(m - 1).clamp(0, 11)]} ${p[0]}';
}

/// "« il y a 12 jours »" from a days count (-1 = never).
String daysAgo(int days) => switch (days) {
      < 0 => 'jamais',
      0 => 'aujourd’hui',
      1 => 'hier',
      _ => 'il y a $days jours',
    };

/// Phone in international form for wa.me (0550… → 213550…).
String phoneIntl(String phone) {
  var p = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  if (p.startsWith('+')) p = p.substring(1);
  if (p.startsWith('00')) p = p.substring(2);
  if (p.startsWith('0')) p = '213${p.substring(1)}';
  return p;
}

/// Opens a link with the Windows default application (browser, mail…).
Future<bool> openExternal(BuildContext context, String url) async {
  try {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      showToast(context, 'Impossible d’ouvrir : $url', kind: ToastKind.error);
    }
    return ok;
  } catch (e) {
    if (context.mounted) showToast(context, 'Impossible d’ouvrir : $e', kind: ToastKind.error);
    return false;
  }
}

Future<void> copyText(BuildContext context, String text, {String done = 'Copié.'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, done, kind: ToastKind.info);
}

/// Parses « 36.7525, 3.0420 » (also « 36,7525 3,0420 » or a Google Maps
/// link with @lat,lng). Null when invalid.
(double, double)? parseGps(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final at = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(s);
  if (at != null) {
    final lat = double.tryParse(at.group(1)!), lng = double.tryParse(at.group(2)!);
    if (lat != null && lng != null) return (lat, lng);
  }
  final nums = RegExp(r'-?\d+(?:[.,]\d+)?').allMatches(s).map((m) => m.group(0)!.replaceAll(',', '.')).toList();
  if (nums.length != 2) return null;
  final lat = double.tryParse(nums[0]), lng = double.tryParse(nums[1]);
  if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return null;
  return (lat, lng);
}

/// Opens Google Maps on a GPS point.
Future<void> openMaps(BuildContext context, double lat, double lng) =>
    openExternal(context, 'https://www.google.com/maps/search/?api=1&query=$lat,$lng');

Color hexColour(String hex, {Color fallback = T.mint}) {
  final h = hex.replaceAll('#', '');
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

/// Error message of anything thrown by the API.
String errText(Object e) => e is ApiException ? e.message : '$e';

/// One cached list of users (commerciaux / assignees) per app run.
class CrmDirectory {
  CrmDirectory._();
  static List<CrmUser>? _users;
  static List<CrmRoute>? _routes;
  static List<CrmTag>? _tags;

  static Future<List<CrmUser>> users(ApiClient api, {bool refresh = false}) async {
    if (_users != null && !refresh) return _users!;
    return _users = await api.crmUsers();
  }

  static Future<List<CrmRoute>> routes(ApiClient api, {bool refresh = false}) async {
    if (_routes != null && !refresh) return _routes!;
    try {
      return _routes = await api.crmRoutes();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<CrmTag>> tags(ApiClient api, {bool refresh = false}) async {
    if (_tags != null && !refresh) return _tags!;
    try {
      return _tags = await api.crmTags();
    } catch (_) {
      return const [];
    }
  }

  static void forgetTags() => _tags = null;
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

/// Pill tab (same look as the Stock screen tabs), with an optional count.
class CrmTab extends StatelessWidget {
  const CrmTab({super.key, required this.label, required this.selected, required this.onTap, this.count, this.alert = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border3),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : T.ink,
                )),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: alert ? T.danger : (selected ? Colors.white24 : T.bg),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('$count',
                    style: T.label.copyWith(
                        fontSize: 12, color: alert || selected ? Colors.white : T.muted)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Coloured tag chip, optionally removable.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.name, required this.colour, this.onRemove});
  final String name;
  final String colour;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = hexColour(colour);
    return Container(
      padding: EdgeInsetsDirectional.only(start: 9, end: onRemove == null ? 9 : 3, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: T.ink, fontSize: 12.5)),
        ),
        if (onRemove != null)
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(999),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.close_rounded, size: 14, color: T.muted),
            ),
          ),
      ]),
    );
  }
}

/// Small status chip for crm_status.
class CrmStatusChip extends StatelessWidget {
  const CrmStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      'active' => (T.mintTint, T.mintDark),
      'prospect' => (const Color(0x143B82F6), const Color(0xFF1D4ED8)),
      'dormant' => (T.warnTint, T.warnDark),
      'blocked' => (T.dangerTint, T.dangerDark),
      _ => (T.cream, T.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(T.rChip)),
      child: Text(crmStatusLabels[status] ?? status,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: T.label.copyWith(color: fg, fontSize: 12.5)),
    );
  }
}

/// KPI tile: label, big value, optional sentence under it.
class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.label, required this.value, this.note, this.color, this.width = 210});
  final String label;
  final String value;
  final String? note;
  final Color? color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: T.label),
        const SizedBox(height: 4),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.monoBody.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: color ?? T.ink)),
        if (note != null && note!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(note!, style: T.small, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ]),
    );
  }
}

/// Label above a dropdown (vertical forms).
class DropdownBlock<V> extends StatelessWidget {
  const DropdownBlock({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.noneLabel,
    this.helper,
    this.width,
    this.required = false,
  });
  final String label;
  final V? value;
  final List<(V, String)> options;
  final ValueChanged<V?> onChanged;

  /// When set, a first « none » choice with this text (value null).
  final String? noneLabel;
  final String? helper;
  final double? width;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final has = value == null || options.any((o) => o.$1 == value);
    final field = Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border3),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<V?>(
          isExpanded: true,
          value: has ? value : null,
          style: T.body,
          items: [
            if (noneLabel != null) DropdownMenuItem<V?>(value: null, child: Text(noneLabel!, style: T.bodyMuted)),
            for (final (v, l) in options)
              DropdownMenuItem<V?>(value: v, child: Text(l, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: label, style: T.label),
            if (required)
              const TextSpan(text: ' *', style: TextStyle(fontWeight: FontWeight.w800, color: T.danger)),
          ])),
          const SizedBox(height: 5),
          field,
          if (helper != null) ...[
            const SizedBox(height: 4),
            Text(helper!, style: T.small),
          ],
        ]),
      ),
    );
  }
}

/// Label + date button (+ « Effacer »). [value] is "YYYY-MM-DD" or null.
class DateBlock extends StatelessWidget {
  const DateBlock({super.key, required this.label, required this.value, required this.onChanged, this.helper, this.clearable = true});
  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? helper;
  final bool clearable;

  @override
  Widget build(BuildContext context) {
    Future<void> pick() async {
      final d = await showDatePicker(
        context: context,
        initialDate: DateTime.tryParse(value ?? '') ?? DateTime.now(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (d != null) onChanged(isoDate(d));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: T.label),
        const SizedBox(height: 5),
        Row(children: [
          InkWell(
            onTap: pick,
            borderRadius: BorderRadius.circular(T.rInner),
            child: Container(
              height: 44,
              width: 200,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(T.rInner),
                border: Border.all(color: T.border3),
              ),
              child: Row(children: [
                const Icon(Icons.calendar_today_outlined, size: 16, color: T.faint),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(value == null || value!.isEmpty ? 'Choisir une date' : crmDate(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: value == null || value!.isEmpty ? T.bodyMuted : T.monoBody),
                ),
              ]),
            ),
          ),
          if (clearable && value != null && value!.isNotEmpty)
            TextButton(onPressed: () => onChanged(null), child: const Text('Effacer')),
        ]),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(helper!, style: T.small),
        ],
      ]),
    );
  }
}

/// Choice chips (Type, Priorité…) for vertical forms.
class ChoiceRow<V> extends StatelessWidget {
  const ChoiceRow({super.key, required this.options, required this.value, required this.onSelect});
  final List<(V, String)> options;
  final V value;
  final ValueChanged<V> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (v, label) in options)
        ChoiceChip(
          label: Text(label,
              style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: value == v ? T.mintDark : T.ink)),
          selected: value == v,
          selectedColor: T.mintTint2,
          backgroundColor: T.surface,
          side: BorderSide(color: value == v ? T.mintDeep : T.border3),
          showCheckmark: false,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          onSelected: (_) => onSelect(v),
        ),
    ]);
  }
}

/// Plain text field with label above (same look as the partner form).
class TextBlock extends StatelessWidget {
  const TextBlock({
    super.key,
    required this.label,
    required this.controller,
    this.required = false,
    this.error,
    this.helper,
    this.hint,
    this.maxLines = 1,
    this.keyboard,
    this.onChanged,
    this.autofocus = false,
  });
  final String label;
  final TextEditingController controller;
  final bool required;
  final String? error;
  final String? helper;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboard;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: label, style: T.label),
          if (required)
            const TextSpan(text: ' *', style: TextStyle(fontWeight: FontWeight.w800, color: T.danger)),
        ])),
        const SizedBox(height: 5),
        Container(
          constraints: const BoxConstraints(minHeight: 44),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: error != null ? T.danger : T.border3, width: error != null ? 1.4 : 1),
          ),
          alignment: AlignmentDirectional.centerStart,
          child: TextField(
            controller: controller,
            autofocus: autofocus,
            maxLines: maxLines,
            minLines: 1,
            keyboardType: maxLines > 1 ? TextInputType.multiline : keyboard,
            onChanged: onChanged,
            style: T.body,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: T.bodyMuted.copyWith(color: T.ghost),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        if (helper != null && error == null) ...[
          const SizedBox(height: 4),
          Text(helper!, style: T.small),
        ],
        FieldError(error),
      ]),
    );
  }
}

/// Icon of a timeline / activity type.
IconData crmKindIcon(String kind, [String subType = '']) => switch (kind) {
      'order' => Icons.shopping_bag_outlined,
      'order_event' => Icons.local_shipping_outlined,
      'document' => Icons.receipt_long_outlined,
      'payment' => Icons.payments_outlined,
      'task' => Icons.task_alt_rounded,
      'message' => switch (subType) {
          'email' => Icons.email_outlined,
          'sms' => Icons.sms_outlined,
          _ => Icons.chat_outlined,
        },
      'activity' => activityIcon(subType),
      _ => Icons.circle_outlined,
    };

IconData activityIcon(String type) => switch (type) {
      'call' => Icons.call_outlined,
      'visit' => Icons.directions_walk_rounded,
      'note' => Icons.sticky_note_2_outlined,
      'whatsapp' => Icons.chat_outlined,
      'sms' => Icons.sms_outlined,
      'email' => Icons.email_outlined,
      'meeting' => Icons.event_outlined,
      _ => Icons.circle_outlined,
    };

IconData taskTypeIcon(String type) => switch (type) {
      'call' => Icons.call_outlined,
      'visit' => Icons.directions_walk_rounded,
      'collect_payment' => Icons.payments_outlined,
      'follow_up' => Icons.replay_rounded,
      _ => Icons.task_alt_rounded,
    };

// ---------------------------------------------------------------------------
// Task form page
// ---------------------------------------------------------------------------

/// Opens the create / edit page of a task. Returns the saved task.
Future<CrmTask?> openTaskForm(BuildContext context, ApiClient api,
    {CrmTask? existing, String? partnerId, String? partnerName, String? orderId, String? title, String? type}) {
  return Navigator.of(context).push<CrmTask>(MaterialPageRoute(
    builder: (_) => TaskFormPage(
        api: api,
        existing: existing,
        partnerId: partnerId ?? existing?.partnerId,
        partnerName: partnerName ?? existing?.partnerName,
        orderId: orderId ?? existing?.orderId,
        initialTitle: title,
        initialType: type),
  ));
}

class TaskFormPage extends StatefulWidget {
  const TaskFormPage({
    super.key,
    required this.api,
    this.existing,
    this.partnerId,
    this.partnerName,
    this.orderId,
    this.initialTitle,
    this.initialType,
  });
  final ApiClient api;
  final CrmTask? existing;
  final String? partnerId;
  final String? partnerName;
  final String? orderId;
  final String? initialTitle;
  final String? initialType;

  @override
  State<TaskFormPage> createState() => _TaskFormPageState();
}

class _TaskFormPageState extends State<TaskFormPage> {
  late final _title = TextEditingController(text: widget.existing?.title ?? widget.initialTitle ?? '');
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late String _type = widget.existing?.type ?? widget.initialType ?? 'call';
  late int _priority = widget.existing?.priority ?? 0;
  late String? _due = widget.existing == null
      ? isoDate(DateTime.now())
      : (widget.existing!.dueDate.isEmpty ? null : widget.existing!.dueDate);
  late String? _assignee = widget.existing == null ? widget.api.user?.id : widget.existing!.assigneeId;
  late String? _partnerId = widget.partnerId;
  late String? _partnerName = widget.partnerName;
  List<CrmUser> _users = const [];
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickPartner() async {
    final p = await pickCustomer(context, widget.api);
    if (p != null) {
      setState(() {
        _partnerId = p.id;
        _partnerName = p.name;
      });
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _err = 'Écrivez ce qu’il faut faire.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final t = await widget.api.crmSaveTask({
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'partner_id': ?_partnerId,
        'order_id': ?widget.orderId,
        'assignee_id': ?_assignee,
        'due_at': ?_due,
        'priority': _priority,
        'type': _type,
      }, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, widget.existing == null ? 'Tâche créée.' : 'Tâche enregistrée.');
      Navigator.of(context).pop(t);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AppPage(
      crumbs: [
        Crumb('Tâches', () => Navigator.of(context).pop()),
        Crumb(isNew ? 'Nouvelle tâche' : 'Modifier'),
      ],
      title: isNew ? 'Nouvelle tâche' : 'Modifier la tâche',
      maxWidth: 760,
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageSection(
          title: 'La tâche',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextBlock(
                label: 'À faire',
                required: true,
                controller: _title,
                autofocus: isNew,
                hint: 'Ex. Rappeler pour la commande de la semaine',
                error: _err != null && _title.text.trim().isEmpty ? _err : null),
            Text('Type', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<String>(
              options: [for (final e in taskTypeLabels.entries) (e.key, e.value)],
              value: _type,
              onSelect: (v) => setState(() => _type = v),
            ),
            const SizedBox(height: 14),
            Text('Priorité', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<int>(
              options: [for (final e in taskPriorityLabels.entries) (e.key, e.value)],
              value: _priority,
              onSelect: (v) => setState(() => _priority = v),
            ),
            const SizedBox(height: 14),
            TextBlock(label: 'Détails', controller: _desc, maxLines: 4),
          ]),
        ),
        PageSection(
          title: 'Quand et qui',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DateBlock(label: 'Échéance', value: _due, onChanged: (v) => setState(() => _due = v)),
            DropdownBlock<String>(
              label: 'Confiée à',
              width: 380,
              value: _assignee,
              noneLabel: 'Personne',
              options: [for (final u in _users) (u.id, u.name)],
              onChanged: (v) => setState(() => _assignee = v),
            ),
            Text('Client', style: T.label),
            const SizedBox(height: 5),
            Row(children: [
              Expanded(
                child: Text(_partnerName ?? 'Aucun client',
                    style: _partnerName == null ? T.bodyMuted : T.body.copyWith(fontWeight: FontWeight.w700)),
              ),
              OutlinedButton.icon(
                onPressed: _pickPartner,
                icon: const Icon(Icons.person_search_outlined, size: 18),
                label: Text(_partnerId == null ? 'Choisir un client' : 'Changer'),
              ),
              if (_partnerId != null) ...[
                const SizedBox(width: 8),
                TextButton(
                    onPressed: () => setState(() {
                          _partnerId = null;
                          _partnerName = null;
                        }),
                    child: const Text('Retirer')),
              ],
            ]),
          ]),
        ),
        if (_err != null && _title.text.trim().isNotEmpty) FieldError(_err),
      ]),
    );
  }
}

/// « Terminer la tâche » : optional result sentence. Returns null if cancelled.
Future<String?> askTaskResult(BuildContext context, CrmTask t, {bool cancel = false}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(cancel ? 'Annuler la tâche' : 'Tâche faite', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextBlock(
              label: cancel ? 'Pourquoi ? (facultatif)' : 'Résultat (facultatif)',
              controller: ctrl,
              autofocus: true,
              hint: cancel ? 'Ex. Client fermé' : 'Ex. Commande prise pour lundi'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Retour')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: cancel ? T.danger : T.mint, foregroundColor: cancel ? Colors.white : T.ink),
          onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
          child: Text(cancel ? 'Annuler la tâche' : 'Marquer comme faite'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Activity form page
// ---------------------------------------------------------------------------

Future<CrmActivity?> openActivityForm(BuildContext context, ApiClient api,
    {required String partnerId, required String partnerName, CrmActivity? existing, String type = 'call', String? orderId}) {
  return Navigator.of(context).push<CrmActivity>(MaterialPageRoute(
    builder: (_) => ActivityFormPage(
        api: api, partnerId: partnerId, partnerName: partnerName, existing: existing, initialType: type, orderId: orderId),
  ));
}

class ActivityFormPage extends StatefulWidget {
  const ActivityFormPage({
    super.key,
    required this.api,
    required this.partnerId,
    required this.partnerName,
    this.existing,
    this.initialType = 'call',
    this.orderId,
  });
  final ApiClient api;
  final String partnerId;
  final String partnerName;
  final CrmActivity? existing;
  final String initialType;
  final String? orderId;

  @override
  State<ActivityFormPage> createState() => _ActivityFormPageState();
}

class _ActivityFormPageState extends State<ActivityFormPage> {
  late String _type = widget.existing?.type ?? widget.initialType;
  late final _outcome = TextEditingController(text: widget.existing?.outcome ?? '');
  late final _summary = TextEditingController(text: widget.existing?.summary ?? '');
  late final _duration = TextEditingController(
      text: (widget.existing?.durationMin ?? 0) > 0 ? '${widget.existing!.durationMin}' : '');
  late final _next = TextEditingController(text: widget.existing?.nextAction ?? '');
  late final _lat = TextEditingController(text: widget.existing?.latitude?.toString() ?? '');
  late final _lng = TextEditingController(text: widget.existing?.longitude?.toString() ?? '');
  String? _nextDue;
  late String _date = widget.existing == null
      ? isoDate(DateTime.now())
      : isoDate(DateTime.tryParse(widget.existing!.at)?.toLocal() ?? DateTime.now());
  late TimeOfDay _time = widget.existing == null
      ? TimeOfDay.now()
      : TimeOfDay.fromDateTime(DateTime.tryParse(widget.existing!.at)?.toLocal() ?? DateTime.now());
  bool _busy = false;
  String? _err;

  static const _outcomes = <String, List<String>>{
    'call': ['Joint', 'Pas de réponse', 'À rappeler', 'Commande prise', 'Pas intéressé'],
    'visit': ['Visite faite', 'Absent', 'Commande prise', 'Paiement reçu', 'Réclamation'],
    'whatsapp': ['Message envoyé', 'Réponse reçue', 'Commande prise'],
    'sms': ['Message envoyé'],
    'email': ['E-mail envoyé', 'Réponse reçue'],
    'meeting': ['Rendez-vous fait', 'Reporté', 'Annulé'],
    'note': <String>[],
  };

  @override
  void dispose() {
    for (final c in [_outcome, _summary, _duration, _next, _lat, _lng]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final dur = _duration.text.trim().isEmpty ? 0 : int.tryParse(_duration.text.trim());
    if (dur == null || dur < 0) {
      setState(() => _err = 'Durée invalide (en minutes).');
      return;
    }
    double? lat, lng;
    if (_lat.text.trim().isNotEmpty || _lng.text.trim().isNotEmpty) {
      lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
      lng = double.tryParse(_lng.text.trim().replaceAll(',', '.'));
      if (lat == null || lng == null) {
        setState(() => _err = 'Position GPS invalide.');
        return;
      }
    }
    if (_summary.text.trim().isEmpty && _outcome.text.trim().isEmpty) {
      setState(() => _err = 'Écrivez au moins un résultat ou un résumé.');
      return;
    }
    final d = DateTime.tryParse(_date) ?? DateTime.now();
    final at = DateTime(d.year, d.month, d.day, _time.hour, _time.minute).toUtc().toIso8601String();
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final a = await widget.api.crmSaveActivity({
        'partner_id': widget.partnerId,
        'type': _type,
        'outcome': _outcome.text.trim(),
        'summary': _summary.text.trim(),
        'at': at,
        'duration_min': dur,
        'order_id': ?(widget.existing?.orderId ?? widget.orderId),
        'latitude': ?lat,
        'longitude': ?lng,
        'next_action': _next.text.trim(),
        if (widget.existing == null && _nextDue != null) 'next_action_due': _nextDue,
      }, id: widget.existing?.id);
      if (!mounted) return;
      showToast(
          context,
          widget.existing == null && _nextDue != null
              ? 'Activité notée. Une tâche de suivi est créée pour le ${crmDate(_nextDue)}.'
              : 'Activité notée.');
      Navigator.of(context).pop(a);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final suggestions = _outcomes[_type] ?? const [];
    return AppPage(
      crumbs: [
        Crumb(widget.partnerName, () => Navigator.of(context).pop()),
        Crumb(isNew ? 'Noter une activité' : 'Modifier l’activité'),
      ],
      title: isNew ? 'Noter une activité' : 'Modifier l’activité',
      subtitle: Text(widget.partnerName, style: T.bodyMuted),
      maxWidth: 760,
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageSection(
          title: 'Ce qui s’est passé',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Type', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<String>(
              options: [for (final e in activityTypeLabels.entries) (e.key, e.value)],
              value: _type,
              onSelect: (v) => setState(() => _type = v),
            ),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DateBlock(
                  label: 'Date',
                  value: _date,
                  clearable: false,
                  onChanged: (v) => setState(() => _date = v ?? _date)),
              const SizedBox(width: 14),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Heure', style: T.label),
                  const SizedBox(height: 5),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(120, 44)),
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: _time);
                      if (t != null) setState(() => _time = t);
                    },
                    icon: const Icon(Icons.schedule_rounded, size: 16),
                    label: Text('${_two(_time.hour)}:${_two(_time.minute)}', style: T.monoBody),
                  ),
                ]),
              ),
              const SizedBox(width: 14),
              SizedBox(
                  width: 160,
                  child: TextBlock(
                      label: 'Durée (minutes)', controller: _duration, keyboard: TextInputType.number)),
            ]),
            TextBlock(label: 'Résultat', controller: _outcome, hint: 'Ex. Commande prise'),
            if (suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in suggestions)
                    ActionChip(
                      label: Text(s, style: T.small.copyWith(color: T.ink)),
                      backgroundColor: T.surface,
                      side: const BorderSide(color: T.border3),
                      onPressed: () => setState(() => _outcome.text = s),
                    ),
                ]),
              ),
            TextBlock(label: 'Résumé', controller: _summary, maxLines: 4, hint: 'Ce qui a été dit, demandé…'),
          ]),
        ),
        PageSection(
          title: 'Et ensuite ?',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextBlock(
                label: 'Prochaine action',
                controller: _next,
                hint: 'Ex. Rappeler pour confirmer la livraison'),
            if (isNew)
              DateBlock(
                label: 'À faire le',
                value: _nextDue,
                onChanged: (v) => setState(() => _nextDue = v),
                helper: 'Avec une date, une tâche de suivi est créée pour vous.',
              ),
          ]),
        ),
        if (_type == 'visit')
          PageSection(
            title: 'Position GPS de la visite (facultatif)',
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: TextBlock(label: 'Latitude', controller: _lat, hint: '36.75')),
              const SizedBox(width: 14),
              Expanded(child: TextBlock(label: 'Longitude', controller: _lng, hint: '3.06')),
            ]),
          ),
        if (_err != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: FieldError(_err)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Customer picker (search dialog)
// ---------------------------------------------------------------------------

Future<Partner?> pickCustomer(BuildContext context, ApiClient api) {
  return showDialog<Partner>(context: context, builder: (_) => _CustomerPicker(api: api));
}

class _CustomerPicker extends StatefulWidget {
  const _CustomerPicker({required this.api});
  final ApiClient api;

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  final _q = TextEditingController();
  List<Partner> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.api.crmPartners(q: _q.text, kind: 'customer', limit: 50);
      if (mounted) setState(() => _items = r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 520,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Choisir un client', style: T.h2),
            const SizedBox(height: 12),
            SearchField(
                controller: _q,
                autofocus: true,
                hint: 'Nom ou téléphone…',
                onChanged: (_) => _load()),
            const SizedBox(height: 10),
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? Center(child: Text('Aucun client trouvé.', style: T.bodyMuted))
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (_, i) {
                            final p = _items[i];
                            return ListTile(
                              dense: true,
                              title: Text(p.name, style: T.body),
                              subtitle: Text(
                                  [p.phone ?? '', p.wilaya].where((s) => s.isNotEmpty).join(' · '),
                                  style: T.small),
                              onTap: () => Navigator.of(context).pop(p),
                            );
                          }),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
            ),
          ]),
        ),
      ),
    );
  }
}
