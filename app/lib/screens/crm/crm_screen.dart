import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../util/commands.dart';
import '../../util/prefs.dart';
import '../../widgets/doc_list.dart' show popToModuleRoot;
import '../../widgets/list_toolbar.dart';
import 'crm_common.dart';
import 'reps_tab.dart';
import 'segments_tab.dart';
import 'tags_page.dart';
import 'tasks_tab.dart';
import 'wilaya_tab.dart';

enum CrmView { tasks, segments, reps, wilayas }

/// « Relation clients » module (perm crm.view).
/// Menu commands: `tab:tasks` · `tab:segments` · `tab:reps` · `tab:wilayas`
/// · `new:task` · `generate`.
class CrmScreen extends StatefulWidget {
  const CrmScreen({super.key, required this.api, this.command, this.onTasksChanged});
  final ApiClient api;
  final ScreenCommand? command;

  /// Called with the overdue count when the tasks are reloaded (sidebar badge).
  final ValueChanged<int>? onTasksChanged;

  @override
  State<CrmScreen> createState() => _CrmScreenState();
}

class _CrmScreenState extends State<CrmScreen> {
  static const _prefs = 'crm';
  late CrmView _view = CrmView.values.firstWhere(
      (v) => v.name == UiPrefs.instance.get<String>(_prefs, 'view'),
      orElse: () => CrmView.tasks);
  final Set<CrmView> _visited = {};
  final _tasksKey = GlobalKey<TasksTabState>();
  final _segmentsKey = GlobalKey<SegmentsTabState>();
  final _repsKey = GlobalKey<RepsTabState>();
  final _wilayaKey = GlobalKey<WilayaTabState>();
  TaskSummary _summary = const TaskSummary.empty();

  @override
  void initState() {
    super.initState();
    widget.command?.addListener(_onCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
    widget.api.crmTaskSummary(assigneeId: 'me').then((s) {
      if (mounted && !_visited.contains(CrmView.tasks)) setState(() => _summary = s);
    }).catchError((_) {});
  }

  @override
  void didUpdateWidget(CrmScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    switch (cmd) {
      case 'tab:tasks':
        _select(CrmView.tasks);
      case 'tab:segments':
        _select(CrmView.segments);
      case 'tab:reps':
        _select(CrmView.reps);
      case 'tab:wilayas':
        _select(CrmView.wilayas);
      case 'new:task':
        _select(CrmView.tasks);
        WidgetsBinding.instance.addPostFrameCallback((_) => _tasksKey.currentState?.newTask());
      case 'generate':
        _select(CrmView.tasks);
        WidgetsBinding.instance.addPostFrameCallback((_) => _tasksKey.currentState?.generate());
    }
  }

  void _select(CrmView v) {
    setState(() => _view = v);
    UiPrefs.instance.set(_prefs, 'view', v.name);
  }

  (String, IconData, VoidCallback)? get _primary => switch (_view) {
        CrmView.tasks when crmEdit(widget.api) =>
          ('Nouvelle tâche', Icons.add_task_rounded, () => _tasksKey.currentState?.newTask()),
        CrmView.segments when crmEdit(widget.api) =>
          ('Nouveau segment', Icons.add_rounded, () => _segmentsKey.currentState?.newSegment()),
        CrmView.reps when crmEdit(widget.api) && (widget.api.user?.scope ?? 'all') != 'own' =>
          ('Fixer des objectifs', Icons.flag_outlined, () => _repsKey.currentState?.setTargets()),
        _ => null,
      };

  Widget _build(CrmView v) => switch (v) {
        CrmView.tasks => TasksTab(
            key: _tasksKey,
            api: widget.api,
            onSummary: (s) {
              setState(() => _summary = s);
              widget.onTasksChanged?.call(s.overdue);
            }),
        CrmView.segments => SegmentsTab(key: _segmentsKey, api: widget.api),
        CrmView.reps => RepsTab(key: _repsKey, api: widget.api),
        CrmView.wilayas => WilayaTab(key: _wilayaKey, api: widget.api),
      };

  @override
  Widget build(BuildContext context) {
    _visited.add(_view);
    final p = _primary;
    const tabs = [
      (CrmView.tasks, 'Mes tâches'),
      (CrmView.segments, 'Segments'),
      (CrmView.reps, 'Commerciaux'),
      (CrmView.wilayas, 'Par wilaya'),
    ];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Relation clients',
          primaryLabel: p?.$1,
          primaryIcon: p?.$2 ?? Icons.add_rounded,
          onPrimary: p?.$3,
          more: [
            if (crmEdit(widget.api))
              MenuEntry('Générer les relances automatiques', Icons.auto_mode_rounded, () {
                _select(CrmView.tasks);
                WidgetsBinding.instance.addPostFrameCallback((_) => _tasksKey.currentState?.generate());
              }),
            MenuEntry('Gérer les étiquettes', Icons.sell_outlined, () => openTagsPage(context, widget.api)),
          ],
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (v, label) in tabs)
              CrmTab(
                label: label,
                selected: _view == v,
                count: v == CrmView.tasks ? (_summary.overdue > 0 ? _summary.overdue : _summary.today) : null,
                alert: v == CrmView.tasks && _summary.overdue > 0,
                onTap: () => _select(v),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: IndexedStack(
            index: tabs.indexWhere((t) => t.$1 == _view),
            children: [
              for (final (v, _) in tabs)
                KeyedSubtree(
                  key: ValueKey(v),
                  child: _visited.contains(v) ? _build(v) : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}
