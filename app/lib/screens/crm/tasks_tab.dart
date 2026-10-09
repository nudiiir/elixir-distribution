import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../partners/partner_crm_tabs.dart' show TaskRow;
import '../partners/partner_pages.dart' show openPartnerDetailById, PartnerTab;
import 'crm_common.dart';

enum TaskView { today, overdue, upcoming, open, done }

/// « Mes tâches » : today / overdue / upcoming / done, filters, quick
/// complete, automatic reminders.
class TasksTab extends StatefulWidget {
  const TasksTab({super.key, required this.api, this.onSummary});
  final ApiClient api;

  /// Tells the module the counts (tab badge).
  final ValueChanged<TaskSummary>? onSummary;

  @override
  State<TasksTab> createState() => TasksTabState();
}

class TasksTabState extends State<TasksTab> {
  static const _prefs = 'crm_tasks';
  static const _pageSize = 50;
  TaskView _view = TaskView.today;
  String _assignee = 'me'; // me | all | unassigned | <id>
  String? _type;
  String? _source;
  List<CrmTask> _items = const [];
  TaskSummary _summary = const TaskSummary.empty();
  List<CrmUser> _users = const [];
  bool _loading = true;
  String? _error;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    final v = UiPrefs.instance.get<String>(_prefs, 'view');
    _view = TaskView.values.firstWhere((x) => x.name == v, orElse: () => TaskView.today);
    _assignee = UiPrefs.instance.get<String>(_prefs, 'assignee') ?? 'me';
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final today = isoDate(DateTime.now());
    try {
      final summary = await widget.api.crmTaskSummary(assigneeId: _assignee == 'unassigned' ? 'all' : _assignee);
      final items = await widget.api.crmTasks(
        assigneeId: _assignee == 'all' ? null : _assignee,
        status: _view == TaskView.done ? 'done' : 'open',
        due: switch (_view) {
          TaskView.today => 'today',
          TaskView.overdue => 'overdue',
          _ => null,
        },
        type: _type,
        source: _source,
      );
      var list = items;
      if (_view == TaskView.upcoming) {
        list = [for (final t in items) if (t.dueDate.isEmpty || t.dueDate.compareTo(today) > 0) t];
      }
      if (_view == TaskView.done) {
        list = [...list]..sort((a, b) => (b.completedAt ?? '').compareTo(a.completedAt ?? ''));
      }
      if (!mounted) return;
      setState(() {
        _items = list;
        _summary = summary;
        _page = 0;
      });
      widget.onSummary?.call(summary);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _setView(TaskView v) {
    setState(() => _view = v);
    UiPrefs.instance.set(_prefs, 'view', v.name);
    reload();
  }

  Future<void> newTask() async {
    final t = await openTaskForm(context, widget.api);
    if (t != null) reload();
  }

  Future<void> generate() async {
    final opts = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _GenerateDialog());
    if (opts == null || !mounted) return;
    try {
      final r = await widget.api.crmGenerateTasks(
        inactiveDays: opts['days'] as int?,
        overdue: opts['overdue'] as bool,
        inactive: opts['inactive'] as bool,
        backorder: opts['backorder'] as bool,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
          title: Text(r.created == 0 ? 'Aucune nouvelle relance' : '${r.created} relance(s) créée(s)', style: T.h2),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _genLine(Icons.payments_outlined, 'Factures échues à encaisser', r.byOverdue),
              _genLine(Icons.replay_rounded, 'Clients sans achat depuis ${r.inactiveDays} jours', r.byInactive),
              _genLine(Icons.call_outlined, 'Reliquats de nouveau disponibles', r.byBackorder),
              const SizedBox(height: 10),
              Text(
                  r.skipped > 0
                      ? '${r.skipped} relance(s) déjà ouverte(s) ou faite(s) depuis moins de 7 jours : pas de doublon.'
                      : 'Les relances sont confiées au commercial du client.',
                  style: T.small),
            ]),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Voir les tâches'),
            ),
          ],
        ),
      );
      if (mounted) {
        setState(() {
          _assignee = 'all';
          _view = TaskView.today;
        });
        reload();
      }
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  Widget _genLine(IconData icon, String label, int n) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(icon, size: 18, color: T.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: T.body)),
          Text('$n', style: T.monoBody.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );

  String get _emptyText => switch (_view) {
        TaskView.today => 'Rien de prévu aujourd’hui.',
        TaskView.overdue => 'Aucune tâche en retard. Bravo !',
        TaskView.upcoming => 'Aucune tâche à venir.',
        TaskView.open => 'Aucune tâche ouverte.',
        TaskView.done => 'Aucune tâche terminée.',
      };

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEdit(widget.api);
    final pages = (_items.length / _pageSize).ceil();
    final shown = _items.skip(_page * _pageSize).take(_pageSize).toList();
    final assigneeOpts = <(String, String)>[
      ('all', 'Tout le monde'),
      ('unassigned', 'Personne (non attribuées)'),
      for (final u in _users)
        if (u.id != widget.api.user?.id) (u.id, u.name),
      if (_assignee != 'me' && _assignee != 'all' && _assignee != 'unassigned' && !_users.any((u) => u.id == _assignee))
        (_assignee, 'Utilisateur choisi'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        KpiTile(label: 'En retard', value: '${_summary.overdue}', color: _summary.overdue > 0 ? T.dangerDark : null, width: 170),
        KpiTile(label: 'Aujourd’hui', value: '${_summary.today}', width: 170),
        KpiTile(label: '7 prochains jours', value: '${_summary.upcoming7d}', width: 170),
        KpiTile(label: 'Ouvertes en tout', value: '${_summary.open}', width: 170),
      ]),
      const SizedBox(height: 14),
      ListToolbar(
        quickFilters: [
          FilterPill(label: 'Aujourd’hui', active: _view == TaskView.today, count: _summary.today, onTap: () => _setView(TaskView.today)),
          FilterPill(
              label: 'En retard',
              icon: Icons.error_outline_rounded,
              active: _view == TaskView.overdue,
              count: _summary.overdue,
              onTap: () => _setView(TaskView.overdue)),
          FilterPill(label: 'À venir', active: _view == TaskView.upcoming, onTap: () => _setView(TaskView.upcoming)),
          FilterPill(label: 'Toutes les ouvertes', active: _view == TaskView.open, count: _summary.open, onTap: () => _setView(TaskView.open)),
          FilterPill(label: 'Faites', icon: Icons.check_rounded, active: _view == TaskView.done, onTap: () => _setView(TaskView.done)),
        ],
        trailing: [
          if (canEdit)
            OutlinedButton.icon(
              onPressed: generate,
              icon: const Icon(Icons.auto_mode_rounded, size: 18),
              label: const Text('Générer les relances automatiques'),
            ),
        ],
        panel: FilterPanel(fields: [
          FilterField<String>(
            label: 'Confiées à',
            value: assigneeOpts.any((o) => o.$1 == _assignee) ? _assignee : null,
            allLabel: 'Moi',
            options: assigneeOpts,
            onChanged: (v) {
              setState(() => _assignee = v ?? 'me');
              UiPrefs.instance.set(_prefs, 'assignee', _assignee);
              reload();
            },
          ),
          FilterField<String>(
            label: 'Type',
            value: _type,
            options: [for (final e in taskTypeLabels.entries) (e.key, e.value)],
            onChanged: (v) {
              setState(() => _type = v);
              reload();
            },
          ),
          FilterField<String>(
            label: 'Origine',
            value: _source,
            allLabel: 'Toutes',
            width: 240,
            options: [for (final e in taskSourceLabels.entries) (e.key, e.value)],
            onChanged: (v) {
              setState(() => _source = v);
              reload();
            },
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: Card14(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? EmptyState(icon: Icons.error_outline_rounded, text: _error!, actions: [('Réessayer', reload)])
                  : _items.isEmpty
                      ? EmptyState(
                          icon: Icons.task_alt_rounded,
                          text: _emptyText,
                          actions: [
                            if (canEdit) ('Générer les relances automatiques', generate),
                            if (canEdit) ('Nouvelle tâche', newTask),
                          ],
                        )
                      : Column(children: [
                          Expanded(
                            child: ListView(children: [
                              for (final t in shown)
                                TaskRow(
                                  api: widget.api,
                                  task: t,
                                  onChanged: reload,
                                  onOpenPartner: (t) async {
                                    if (t.partnerId == null) return;
                                    await openPartnerDetailById(context, widget.api, t.partnerId!, tab: PartnerTab.tasks);
                                    if (mounted) reload();
                                  },
                                ),
                            ]),
                          ),
                          if (pages > 1)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(children: [
                                Text('${_page * _pageSize + 1}–${_page * _pageSize + shown.length} sur ${_items.length}',
                                    style: T.small),
                                const Spacer(),
                                OutlinedButton(
                                    onPressed: _page == 0 ? null : () => setState(() => _page--),
                                    child: const Text('Précédent')),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                    onPressed: _page >= pages - 1 ? null : () => setState(() => _page++),
                                    child: const Text('Suivant')),
                              ]),
                            ),
                        ]),
        ),
      ),
    ]);
  }
}

class _GenerateDialog extends StatefulWidget {
  const _GenerateDialog();

  @override
  State<_GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<_GenerateDialog> {
  bool _overdue = true;
  bool _inactive = true;
  bool _backorder = true;
  final _days = TextEditingController();

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  Widget _check(String title, String sub, bool v, ValueChanged<bool> on) => CheckboxListTile(
        value: v,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: T.mintDeep,
        title: Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: T.small),
        onChanged: (x) => setState(() => on(x ?? false)),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: const Text('Générer les relances automatiques', style: T.h2),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Le logiciel crée une tâche pour chaque cas trouvé, pour aujourd’hui. Pas de doublon.', style: T.bodyMuted),
          const SizedBox(height: 10),
          _check('Factures échues', 'Une tâche « Encaisser » par client qui a une facture en retard.', _overdue,
              (v) => _overdue = v),
          _check('Clients inactifs', 'Une tâche « Relancer » par client actif qui n’achète plus.', _inactive,
              (v) => _inactive = v),
          if (_inactive)
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: 6),
              child: SizedBox(
                width: 260,
                child: TextBlock(
                    label: 'Sans achat depuis (jours)',
                    controller: _days,
                    hint: '30',
                    keyboard: TextInputType.number,
                    helper: 'Vide = réglage du magasin (30 par défaut).'),
              ),
            ),
          _check('Reliquats disponibles', 'Une tâche « Appeler » quand un produit attendu est de retour en stock.',
              _backorder, (v) => _backorder = v),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: !_overdue && !_inactive && !_backorder
              ? null
              : () => Navigator.of(context).pop({
                    'overdue': _overdue,
                    'inactive': _inactive,
                    'backorder': _backorder,
                    'days': int.tryParse(_days.text.trim()),
                  }),
          child: const Text('Générer'),
        ),
      ],
    );
  }
}
