part of '../analytics_screen.dart';

// =================================================================== shared bus

/// Signal shared between the explorer and the dashboard (two modules that
/// stay alive in the shell's IndexedStack). Every save,
/// deletion or view addition calls [bump]; the dashboard listens to
/// [revision] and reloads, and re-reads before any change if the
/// revision has changed.
class AnalyticsBus {
  AnalyticsBus._();

  static final revision = ValueNotifier<int>(0);

  /// Dashboard shown (or requested: « Voir sur le tableau de bord »).
  static final currentDashboardId = ValueNotifier<String?>(null);

  /// Fallback when the shell does not provide `onExplore`: the dashboard
  /// drops an « ouvrir une copie » request here that the explorer applies.
  static final pendingRequest = ValueNotifier<ExplorerRequest?>(null);

  static int bump() => ++revision.value;

  static void showDashboard(String id) {
    currentDashboardId.value = id;
    UiPrefs.instance.set('analytics', 'dashboard', id);
  }

  static String? get lastDashboardId => currentDashboardId.value ?? UiPrefs.instance.get<String>('analytics', 'dashboard');
}

/// Request to open in the explorer: a saved view to edit
/// ([report]) or a starting spec ([seed], copy). [title] is the
/// displayed title and the name proposed when saving; [origin] says where
/// the request comes from (« Depuis la fiche produit »).
class ExplorerRequest {
  ExplorerRequest({this.report, this.seed, this.title, this.origin, this.chartType, this.encoding});
  final SavedReport? report; // existing view to edit
  final Map<String, dynamic>? seed; // starting spec (copy)
  final String? title; // displayed title + name proposed when saving
  final String? origin; // « Depuis la fiche produit »
  final String? chartType; // starting display of a copy ('bar', 'table'…)
  final Map<String, dynamic>? encoding; // starting style of a copy
}

/// Deep copy of a JSON spec (nested lists and maps).
Map<String, dynamic> _deepCopy(Map<String, dynamic> m) => Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map);

String _errText(Object e) => e is ApiException ? e.message : '$e';

/// Appends view [reportId] at the bottom of dashboard [dashboardId] (re-read
/// just before so nothing is overwritten). Returns the updated dashboard,
/// or null if it no longer exists. Does nothing if the view is already there.
Future<Dashboard?> _addTileToDashboard(ApiClient api, String dashboardId, String reportId, {bool small = false}) async {
  final ds = await api.dashboards();
  Dashboard? d;
  for (final x in ds) {
    if (x.id == dashboardId) d = x;
  }
  if (d == null) return null;
  if (d.layout.any((t) => t.reportId == reportId)) return d;
  var maxY = 0;
  for (final t in d.layout) {
    if (t.y + t.h > maxY) maxY = t.y + t.h;
  }
  final layout = [for (final t in d.layout) t.toJson(), DashboardTile(reportId: reportId, x: 0, y: maxY, w: small ? 3 : 6, h: small ? 2 : 4).toJson()];
  final saved = await api.saveDashboard({'name': d.name, 'layout': layout, 'global_range': d.globalRange, 'global_warehouse_id': d.globalWarehouseId, 'is_shared': d.isShared}, id: d.id);
  AnalyticsBus.bump();
  return saved;
}

String _chartWord(String t) => t == 'auto' ? 'Automatique' : (kChartLabels[t] ?? t);

// =================================================================== period

class RangePicker extends StatelessWidget {
  const RangePicker({super.key, required this.value, required this.onChanged, this.allowAll = true});
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool allowAll;

  @override
  Widget build(BuildContext context) {
    final type = (value['type'] as String?) ?? 'this_month';
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        Container(
          height: 42,
          constraints: const BoxConstraints(maxWidth: 250),
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: T.surface,
            border: Border.all(color: T.border3),
            borderRadius: BorderRadius.circular(T.rInner),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_today_outlined, size: 16, color: T.muted),
              const SizedBox(width: 6),
              Flexible(
                child: DropdownButton<String>(
                  value: kRangeLabels.containsKey(type) ? type : 'this_month',
                  isExpanded: true,
                  underline: const SizedBox(),
                  style: T.body,
                  items: [
                    for (final e in kRangeLabels.entries)
                      if (allowAll || e.key != 'all')
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value, style: T.body),
                        ),
                  ],
                  onChanged: (t) {
                    if (t == null) return;
                    if (t == 'last_n_days') {
                      onChanged({'type': t, 'n': 30});
                    } else if (t == 'last_n_months') {
                      onChanged({'type': t, 'n': 3});
                    } else if (t == 'custom') {
                      final now = DateTime.now();
                      onChanged({'type': t, 'from': _iso(DateTime(now.year, now.month, 1)), 'to': _iso(now)});
                    } else {
                      onChanged({'type': t});
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        if (type == 'last_n_days' || type == 'last_n_months')
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 70,
                child: _NumField(value: (value['n'] as num?)?.toInt() ?? 30, onChanged: (n) => onChanged({...value, 'n': n})),
              ),
              const SizedBox(width: 6),
              Text(type == 'last_n_days' ? 'jours' : 'mois', style: T.body),
            ],
          ),
        if (type == 'custom')
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('du ', style: T.body),
              _DateButton(value: value['from'] as String?, onChanged: (d) => onChanged({...value, 'from': d})),
              const Text(' au ', style: T.body),
              _DateButton(value: value['to'] as String?, onChanged: (d) => onChanged({...value, 'to': d})),
            ],
          ),
      ],
    );
  }
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _DateButton extends StatelessWidget {
  const _DateButton({required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        side: const BorderSide(color: T.border3),
        minimumSize: const Size(0, 42),
      ),
      onPressed: () async {
        final init = DateTime.tryParse(value ?? '') ?? DateTime.now();
        final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(2015), lastDate: DateTime(2100));
        if (d != null) onChanged(_iso(d));
      },
      child: Text(value == null ? '—' : frDate(value!), style: T.body.copyWith(color: T.ink)),
    );
  }
}

/// Integer numeric field: applies the value as you type (if valid) and
/// follows the incoming value when it changes elsewhere.
class _NumField extends StatefulWidget {
  const _NumField({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;
  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c = TextEditingController(text: '${widget.value}');
  Timer? _debounce;

  @override
  void didUpdateWidget(_NumField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && int.tryParse(_c.text) != widget.value) _c.text = '${widget.value}';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _apply(String v) {
    final n = int.tryParse(v.trim());
    if (n != null && n > 0 && n != widget.value) widget.onChanged(n);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: TextField(
        controller: _c,
        style: T.monoBody,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 11)),
        onChanged: (v) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 600), () => _apply(v));
        },
        onSubmitted: _apply,
      ),
    );
  }
}

// =================================================================== small dialogs

Future<String?> _askName(BuildContext context, String title, {String initial = '', String confirm = 'Créer'}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial, confirm: confirm),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial, required this.confirm});
  final String title, initial, confirm;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.initial);
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim();
    if (v.isEmpty) {
      setState(() => _err = 'Donnez un nom');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: T.h2),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nom', style: T.label),
            const SizedBox(height: 4),
            TextField(
              controller: _c,
              autofocus: true,
              style: T.body,
              onSubmitted: (_) => _ok(),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
            FieldError(_err),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: widget.confirm, onPressed: _ok),
      ],
    );
  }
}

/// Pick a saved view (to add it to a dashboard).
Future<SavedReport?> _pickSavedView(BuildContext context, List<SavedReport> reports, {Set<String> exclude = const {}, VoidCallback? onCreate}) {
  return showDialog<SavedReport>(
    context: context,
    builder: (_) => _ViewPickerDialog(reports: reports, exclude: exclude, onCreate: onCreate),
  );
}

class _ViewPickerDialog extends StatefulWidget {
  const _ViewPickerDialog({required this.reports, required this.exclude, this.onCreate});
  final List<SavedReport> reports;
  final Set<String> exclude;
  final VoidCallback? onCreate;
  @override
  State<_ViewPickerDialog> createState() => _ViewPickerDialogState();
}

class _ViewPickerDialogState extends State<_ViewPickerDialog> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final items = [
      for (final r in widget.reports)
        if (_q.isEmpty || r.name.toLowerCase().contains(_q.toLowerCase())) r,
    ];
    return Dialog(
      child: SizedBox(
        width: 480,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
              child: Row(
                children: [
                  const Expanded(child: Text('Ajouter une vue existante', style: T.h2)),
                  IconButton(tooltip: 'Fermer', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                autofocus: true,
                style: T.body,
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: const InputDecoration(hintText: 'Rechercher une vue…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? EmptyState(
                      icon: Icons.bookmarks_outlined,
                      text: widget.reports.isEmpty ? "Vous n'avez encore enregistré aucune vue." : 'Aucune vue ne correspond.',
                      actions: [
                        if (widget.onCreate != null)
                          (
                            'Créer une vue',
                            () {
                              Navigator.pop(context);
                              widget.onCreate!();
                            },
                          ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final r in items)
                          ListTile(
                            leading: Icon(kChartIcons[r.chartType] ?? Icons.auto_graph_rounded, color: T.mintDark),
                            title: Text(r.name, style: T.body),
                            subtitle: Text(widget.exclude.contains(r.id) ? 'Déjà sur ce tableau de bord' : 'Affichage : ${_chartWord(r.chartType)}', style: T.small),
                            enabled: !widget.exclude.contains(r.id),
                            trailing: widget.exclude.contains(r.id)
                                ? null
                                : const Text(
                                    'Ajouter',
                                    style: TextStyle(color: T.mintDark, fontWeight: FontWeight.w700),
                                  ),
                            onTap: () => Navigator.pop(context, r),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
