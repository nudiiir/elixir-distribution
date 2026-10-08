import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/analytics_models.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
import '../util/prefs.dart';
import '../widgets/analytics_charts.dart';
import '../widgets/ui.dart';

/// Analyses : deux modules. « Tableau de bord » = des tuiles (vues
/// enregistrées) que l'on déplace et redimensionne à la souris, avec une
/// période globale et un seul appel batch. « Explorateur » = le constructeur
/// de vues à trois panneaux (question · réponse en direct · style). Le
/// vocabulaire est celui d'un tableau croisé, jamais celui de SQL.
/// Demande d'ouverture dans l'explorateur (depuis une tuile du tableau de bord).
class ExplorerRequest {
  ExplorerRequest({this.report, this.seed});
  final SavedReport? report; // vue existante à modifier
  final Map<String, dynamic>? seed; // spec de départ (copie)
}

/// Module « Tableau de bord » : uniquement les tuiles. « Modifier » envoie la
/// vue dans le module Explorateur.
class AnalyticsDashboardScreen extends StatefulWidget {
  const AnalyticsDashboardScreen({super.key, required this.api, required this.session, required this.onEdit, required this.onNew, this.onOpenModule});
  final ApiClient api;
  final Session session;
  final void Function(SavedReport) onEdit;
  final VoidCallback onNew;

  /// Opens another module of the shell (« Bien démarrer » checklist):
  /// 'settings', 'products', 'partners', 'pos', 'purchases'.
  final void Function(String key)? onOpenModule;

  @override
  State<AnalyticsDashboardScreen> createState() => _AnalyticsDashboardScreenState();
}

class _AnalyticsDashboardScreenState extends State<AnalyticsDashboardScreen> {
  ASchema? _schema;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.analyticsSchema().then((s) {
      if (mounted) setState(() => _schema = s);
    }).catchError((e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, style: T.body.copyWith(color: T.dangerDark)));
    final s = _schema;
    if (s == null) return const Center(child: CircularProgressIndicator(color: T.mint));
    return DashboardView(api: widget.api, session: widget.session, schema: s, onOpen: widget.onEdit, onNew: widget.onNew, onOpenModule: widget.onOpenModule);
  }
}

/// Module « Explorateur » : uniquement le constructeur de vues. Reçoit les
/// demandes du tableau de bord par [request].
class AnalyticsExplorerScreen extends StatefulWidget {
  const AnalyticsExplorerScreen({super.key, required this.api, required this.session, required this.request, required this.onDone});
  final ApiClient api;
  final Session session;
  final ValueNotifier<ExplorerRequest?> request;
  final VoidCallback onDone;

  @override
  State<AnalyticsExplorerScreen> createState() => _AnalyticsExplorerScreenState();
}

class _AnalyticsExplorerScreenState extends State<AnalyticsExplorerScreen> {
  ASchema? _schema;
  String? _error;
  ExplorerRequest? _current;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _current = widget.request.value;
    widget.request.addListener(_onRequest);
    widget.api.analyticsSchema().then((s) {
      if (mounted) setState(() => _schema = s);
    }).catchError((e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    });
  }

  void _onRequest() {
    setState(() {
      _current = widget.request.value;
      _epoch++;
    });
  }

  @override
  void dispose() {
    widget.request.removeListener(_onRequest);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, style: T.body.copyWith(color: T.dangerDark)));
    final s = _schema;
    if (s == null) return const Center(child: CircularProgressIndicator(color: T.mint));
    final req = _current;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: Row(children: [
          const Text('Explorateur', style: T.h1),
          const SizedBox(width: 14),
          if (req?.report != null)
            MintChip('Modification · ${req!.report!.name}', color: T.mintTint2, fg: T.mintDark)
          else
            const MintChip('Nouvelle vue', color: T.border, fg: T.muted),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              widget.request.value = null;
              setState(() {
                _current = null;
                _epoch++;
              });
            },
            icon: const Icon(Icons.add_chart_rounded, size: 16),
            label: const Text('Nouvelle vue'),
          ),
        ]),
      ),
      Expanded(
        child: ExplorerView(
          key: ValueKey('${req?.report?.id ?? 'new'}-$_epoch'),
          api: widget.api,
          session: widget.session,
          schema: s,
          seed: req?.seed ?? req?.report?.spec,
          report: req?.report,
          onSaved: () {
            widget.request.value = null;
            widget.onDone();
          },
        ),
      ),
    ]);
  }
}

// =================================================================== tableau de bord

const _kCols = 12;
const _kGap = 12.0;
const _kRowH = 64.0;

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.api, required this.session, required this.schema, required this.onOpen, required this.onNew, this.onOpenModule});
  final ApiClient api;
  final Session session;
  final ASchema schema;
  final void Function(SavedReport) onOpen;
  final VoidCallback onNew;
  final void Function(String key)? onOpenModule;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  List<Dashboard> _dashboards = const [];
  Map<String, SavedReport> _reports = const {};
  Dashboard? _current;
  Map<String, Object> _results = const {};
  Map<String, dynamic> _range = const {'type': 'this_month'};
  bool _loading = true;
  bool _running = false;
  String? _error;
  DateTime? _computedAt;
  Timer? _saveDebounce;

  // ---- interaction en cours (déplacement ou redimensionnement)
  DashboardTile? _drag;
  Offset _dragDelta = Offset.zero;
  bool _resizing = false;
  (int, int, int, int)? _ghost; // x, y, w, h cible

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([widget.api.dashboards(), widget.api.savedReports()]);
      final ds = results[0] as List<Dashboard>;
      final rs = results[1] as List<SavedReport>;
      if (!mounted) return;
      setState(() {
        _dashboards = ds;
        _reports = {for (final r in rs) r.id: r};
        _current = ds.isEmpty ? null : (_current == null ? ds.first : ds.firstWhere((d) => d.id == _current!.id, orElse: () => ds.first));
        if (_current != null) _resolve(_current!.layout);
        _range = _current?.globalRange ?? const {'type': 'this_month'};
        _loading = false;
        _error = null;
      });
      await _run();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _run() async {
    final d = _current;
    if (d == null) return;
    setState(() => _running = true);
    try {
      final queries = <MapEntry<String, Map<String, dynamic>>>[];
      for (final t in d.layout) {
        final r = _reports[t.reportId];
        if (r != null && r.missing.isEmpty) queries.add(MapEntry(r.id, r.spec));
      }
      final out = await widget.api.analyticsBatch(queries, globalRange: _range, globalWarehouseId: d.globalWarehouseId);
      if (mounted) {
        setState(() {
          _results = out;
          _computedAt = DateTime.now();
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _saveLayout);
  }

  Future<void> _saveLayout() async {
    final d = _current;
    if (d == null) return;
    try {
      await widget.api.saveDashboard({
        'name': d.name,
        'layout': [for (final t in d.layout) t.toJson()],
        'global_range': _range,
        'global_warehouse_id': d.globalWarehouseId,
        'is_shared': d.isShared,
      }, id: d.id);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ---- grille : collisions et compactage vers le haut (comportement gridstack)
  static bool _overlap(DashboardTile a, DashboardTile b) =>
      a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

  /// Pousse vers le bas les tuiles qui chevauchent [fixed] (ou entre elles),
  /// puis remonte chaque tuile aussi haut que possible.
  void _resolve(List<DashboardTile> tiles, {DashboardTile? fixed}) {
    for (final t in tiles) {
      t.w = t.w.clamp(1, _kCols);
      t.h = t.h.clamp(1, 40);
      if (t.x + t.w > _kCols) t.x = _kCols - t.w;
      if (t.x < 0) t.x = 0;
      if (t.y < 0) t.y = 0;
    }
    final order = List.of(tiles)..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    if (fixed != null) {
      order.remove(fixed);
      order.insert(0, fixed);
    }
    final placed = <DashboardTile>[];
    for (final t in order) {
      if (t != fixed) {
        while (placed.any((p) => _overlap(p, t))) {
          t.y++;
        }
      }
      placed.add(t);
    }
    // compactage : chaque tuile remonte tant que rien ne la bloque
    final byY = List.of(tiles)..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    for (final t in byY) {
      if (t == fixed) continue;
      while (t.y > 0) {
        t.y--;
        if (byY.any((o) => o != t && _overlap(o, t))) {
          t.y++;
          break;
        }
      }
    }
  }

  Future<void> _newDashboard() async {
    final name = await _askName(context, 'Nouveau tableau de bord');
    if (name == null) return;
    try {
      final d = await widget.api.saveDashboard({'name': name, 'layout': [], 'global_range': _range, 'is_shared': true});
      setState(() => _current = d);
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _removeTile(DashboardTile t) async {
    final d = _current!;
    setState(() {
      d.layout.remove(t);
      _resolve(d.layout);
    });
    await _saveLayout();
  }

  Future<void> _deleteReport(DashboardTile t) async {
    final r = _reports[t.reportId];
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer la vue', style: T.h2),
        content: Text('« ${r?.name ?? ''} » sera supprimée de tous les tableaux de bord. Continuer ?', style: T.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          PrimaryButton(label: 'Supprimer', color: T.danger, fg: Colors.white, onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteReport(t.reportId);
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ---- gestes
  void _onDragStart(DashboardTile t, {required bool resize}) {
    setState(() {
      _drag = t;
      _resizing = resize;
      _dragDelta = Offset.zero;
      _ghost = (t.x, t.y, t.w, t.h);
    });
  }

  void _onDragUpdate(Offset delta, double unit) {
    final t = _drag;
    if (t == null) return;
    _dragDelta += delta;
    final dxUnits = (_dragDelta.dx / (unit + _kGap)).round();
    final dyUnits = (_dragDelta.dy / (_kRowH + _kGap)).round();
    setState(() {
      if (_resizing) {
        final w = (t.w + dxUnits).clamp(2, _kCols - t.x);
        final h = (t.h + dyUnits).clamp(2, 40);
        _ghost = (t.x, t.y, w, h);
      } else {
        final x = (t.x + dxUnits).clamp(0, _kCols - t.w);
        final y = (t.y + dyUnits).clamp(0, 400);
        _ghost = (x, y, t.w, t.h);
      }
    });
  }

  void _onDragEnd() {
    final t = _drag;
    final g = _ghost;
    if (t == null || g == null) return;
    final d = _current!;
    setState(() {
      t.x = g.$1;
      t.y = g.$2;
      t.w = g.$3;
      t.h = g.$4;
      _resolve(d.layout, fixed: t);
      _drag = null;
      _ghost = null;
      _resizing = false;
      _dragDelta = Offset.zero;
    });
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: T.mint));
    if (_error != null && _current == null) return Center(child: Text(_error!, style: T.body.copyWith(color: T.dangerDark)));
    final d = _current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Tableau de bord', style: T.h1),
          const SizedBox(width: 14),
          if (_dashboards.length > 1)
            DropdownButton<String>(
              value: d?.id,
              underline: const SizedBox(),
              style: T.body,
              items: [for (final x in _dashboards) DropdownMenuItem(value: x.id, child: Text(x.name, style: T.h2))],
              onChanged: (id) {
                setState(() {
                  _current = _dashboards.firstWhere((x) => x.id == id);
                  _resolve(_current!.layout);
                  _range = _current!.globalRange;
                });
                _run();
              },
            )
          else if (d != null)
            Text(d.name, style: T.h2.copyWith(color: T.muted)),
          const Spacer(),
          RangePicker(
            value: _range,
            onChanged: (r) {
              setState(() => _range = r);
              _scheduleSave();
              _run();
            },
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          TextButton.icon(onPressed: widget.onNew, icon: const Icon(Icons.add_chart_rounded, size: 18), label: const Text('Nouvelle tuile')),
          TextButton.icon(onPressed: _newDashboard, icon: const Icon(Icons.add_box_outlined, size: 18), label: const Text('Nouveau tableau de bord')),
          TextButton.icon(onPressed: _running ? null : _run, icon: const Icon(Icons.refresh, size: 18), label: const Text('Actualiser')),
          if (_computedAt != null) Text('calculé ${_ago(_computedAt!)}', style: T.small),
        ]),
        const SizedBox(height: 4),
        Text('Glissez une tuile par son titre pour la déplacer, tirez le coin inférieur droit pour la redimensionner.', style: T.small),
        SetupChecklist(api: widget.api, onOpenModule: widget.onOpenModule),
        if (_running) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.border) else const SizedBox(height: 2),
        const SizedBox(height: 8),
        Expanded(
          child: d == null || d.layout.isEmpty
              ? EmptyState(
                  icon: Icons.dashboard_customize_outlined,
                  text: 'Aucune tuile sur ce tableau de bord.\nUne tuile affiche un chiffre ou un graphique (ventes du mois, top produits…).',
                  actions: [('Créer une tuile', widget.onNew)],
                )
              : LayoutBuilder(builder: (context, c) {
                  final unit = (c.maxWidth - _kGap * (_kCols - 1)) / _kCols;
                  var maxY = 0;
                  for (final t in d.layout) {
                    if (t.y + t.h > maxY) maxY = t.y + t.h;
                  }
                  final g = _ghost;
                  if (g != null && g.$2 + g.$4 > maxY) maxY = g.$2 + g.$4;
                  double px(int x) => x * (unit + _kGap);
                  double py(int y) => y * (_kRowH + _kGap);
                  double pw(int w) => w * unit + (w - 1) * _kGap;
                  double ph(int h) => h * _kRowH + (h - 1) * _kGap;
                  return SingleChildScrollView(
                    child: SizedBox(
                      height: py(maxY + 2),
                      child: Stack(children: [
                        if (g != null)
                          Positioned(
                            left: px(g.$1),
                            top: py(g.$2),
                            width: pw(g.$3),
                            height: ph(g.$4),
                            child: Container(
                              decoration: BoxDecoration(
                                color: T.mintTint,
                                borderRadius: BorderRadius.circular(T.rCard),
                                border: Border.all(color: T.mint, width: 1.5),
                              ),
                            ),
                          ),
                        for (final t in d.layout)
                          Positioned(
                            left: px(t.x) + (_drag == t && !_resizing ? _dragDelta.dx : 0),
                            top: py(t.y) + (_drag == t && !_resizing ? _dragDelta.dy : 0),
                            width: _drag == t && _resizing && g != null ? pw(g.$3) : pw(t.w),
                            height: _drag == t && _resizing && g != null ? ph(g.$4) : ph(t.h),
                            child: Opacity(
                              opacity: _drag == t ? 0.85 : 1,
                              child: _Tile(
                                report: _reports[t.reportId],
                                result: _results[t.reportId],
                                dragging: _drag == t,
                                onOpen: () {
                                  final r = _reports[t.reportId];
                                  if (r != null) widget.onOpen(r);
                                },
                                onRemove: () => _removeTile(t),
                                onDelete: () => _deleteReport(t),
                                onMoveStart: () => _onDragStart(t, resize: false),
                                onResizeStart: () => _onDragStart(t, resize: true),
                                onDragUpdate: (delta) => _onDragUpdate(delta, unit),
                                onDragEnd: _onDragEnd,
                              ),
                            ),
                          ),
                      ]),
                    ),
                  );
                }),
        ),
      ]),
    );
  }
}

String _ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 5) return "à l'instant";
  if (s < 60) return 'il y a $s s';
  return 'il y a ${s ~/ 60} min';
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.report,
    required this.result,
    required this.dragging,
    required this.onOpen,
    required this.onRemove,
    required this.onDelete,
    required this.onMoveStart,
    required this.onResizeStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });
  final SavedReport? report;
  final Object? result;
  final bool dragging;
  final VoidCallback onOpen, onRemove, onDelete, onMoveStart, onResizeStart, onDragEnd;
  final ValueChanged<Offset> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final r = report;
    Widget body;
    if (r == null) {
      body = const EmptyState(icon: Icons.broken_image_outlined, text: 'Vue supprimée');
    } else if (r.missing.isNotEmpty) {
      body = Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.link_off_rounded, size: 22, color: T.warnDark),
        const SizedBox(height: 6),
        Text("Cette vue utilise un champ qui n'existe plus : ${r.missing.join(', ')}", style: T.small.copyWith(color: T.warnDark), textAlign: TextAlign.center),
        TextButton(onPressed: onOpen, child: const Text('Corriger')),
      ]);
    } else if (result == null) {
      body = const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: T.mint)));
    } else if (result is ApiException) {
      final e = result as ApiException;
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(e.status == 403 ? Icons.lock_outline_rounded : Icons.error_outline_rounded, size: 22, color: T.faint),
          const SizedBox(height: 6),
          Text(e.status == 403 ? 'Non disponible pour votre rôle' : e.message, style: T.small, textAlign: TextAlign.center),
        ]),
      );
    } else {
      final res = result as AResult;
      final type = r.chartType == 'auto' ? autoChartType(res) : r.chartType;
      final effective = chartTypeBlocker(type, res) == null ? type : 'table';
      body = effective == 'stat'
          ? StatTiles(result: res, compact: true, flat: true, title: r.name)
          : buildChart(effective, res, ChartEncoding.fromJson(r.encoding), compact: true);
    }
    final isStat = r != null && result is AResult && (r.chartType == 'stat' || (r.chartType == 'auto' && autoChartType(result as AResult) == 'stat'));
    final menu = PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: 'Actions sur cette tuile',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Actions', style: T.small.copyWith(color: T.muted, fontWeight: FontWeight.w600)),
          const Icon(Icons.arrow_drop_down_rounded, size: 18, color: T.muted),
        ]),
      ),
      onSelected: (v) => switch (v) {
        'open' => onOpen(),
        'remove' => onRemove(),
        _ => onDelete(),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'open', child: Text("Modifier dans l'explorateur")),
        PopupMenuDivider(),
        PopupMenuItem(value: 'remove', child: Text('Retirer du tableau de bord')),
        PopupMenuItem(value: 'delete', child: Text('Supprimer la vue', style: TextStyle(color: T.dangerDark))),
      ],
    );
    // poignée de déplacement = la zone de titre ; poignée de taille = coin bas droit
    final handle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onMoveStart(),
      onPanUpdate: (d) => onDragUpdate(d.delta),
      onPanEnd: (_) => onDragEnd(),
      onPanCancel: onDragEnd,
      onDoubleTap: onOpen,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Row(children: [
          const Icon(Icons.drag_indicator_rounded, size: 16, color: T.ghost),
          const SizedBox(width: 4),
          Expanded(child: Text(r?.name ?? '—', style: T.h2.copyWith(fontSize: 14.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ),
    );
    final resizeHandle = Positioned(
      right: 0,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onResizeStart(),
        onPanUpdate: (d) => onDragUpdate(d.delta),
        onPanEnd: (_) => onDragEnd(),
        onPanCancel: onDragEnd,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.bottomRight,
            padding: const EdgeInsets.all(3),
            child: CustomPaint(size: const Size(10, 10), painter: _CornerPainter()),
          ),
        ),
      ),
    );
    final card = Container(
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: dragging ? T.mint : T.border),
        boxShadow: dragging ? [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 6))] : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: isStat
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: handle), menu]),
              Expanded(child: body),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: handle),
                if (result is AResult && (result as AResult).truncated)
                  const Tooltip(message: 'Résultat tronqué — ouvrez la vue pour affiner', child: Icon(Icons.warning_amber_rounded, size: 15, color: T.warnDark)),
                menu,
              ]),
              const SizedBox(height: 6),
              Expanded(child: Padding(padding: const EdgeInsets.only(right: 6), child: body)),
            ]),
    );
    return Stack(children: [Positioned.fill(child: card), resizeHandle]);
  }
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = T.faint
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), p);
    canvas.drawLine(Offset(size.width, size.height * 0.5), Offset(size.width * 0.5, size.height), p);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => false;
}

// =================================================================== période

class RangePicker extends StatelessWidget {
  const RangePicker({super.key, required this.value, required this.onChanged, this.allowAll = true});
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool allowAll;

  @override
  Widget build(BuildContext context) {
    final type = (value['type'] as String?) ?? 'this_month';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.calendar_today_outlined, size: 15, color: T.muted),
      const SizedBox(width: 6),
      DropdownButton<String>(
        value: kRangeLabels.containsKey(type) ? type : 'this_month',
        underline: const SizedBox(),
        style: T.body,
        items: [
          for (final e in kRangeLabels.entries)
            if (allowAll || e.key != 'all') DropdownMenuItem(value: e.key, child: Text(e.value, style: T.body)),
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
      if (type == 'last_n_days' || type == 'last_n_months') ...[
        const SizedBox(width: 6),
        SizedBox(
          width: 56,
          child: _NumField(
            value: (value['n'] as num?)?.toInt() ?? 30,
            onChanged: (n) => onChanged({...value, 'n': n}),
          ),
        ),
      ],
      if (type == 'custom') ...[
        const SizedBox(width: 6),
        _DateButton(value: value['from'] as String?, onChanged: (d) => onChanged({...value, 'from': d})),
        const Text(' → ', style: T.small),
        _DateButton(value: value['to'] as String?, onChanged: (d) => onChanged({...value, 'to': d})),
      ],
    ]);
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
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), side: const BorderSide(color: T.border3), minimumSize: const Size(0, 30)),
      onPressed: () async {
        final init = DateTime.tryParse(value ?? '') ?? DateTime.now();
        final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(2015), lastDate: DateTime(2100));
        if (d != null) onChanged(_iso(d));
      },
      child: Text(value ?? '—', style: T.monoSmall.copyWith(color: T.ink)),
    );
  }
}

class _NumField extends StatefulWidget {
  const _NumField({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;
  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final _c = TextEditingController(text: '${widget.value}');
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      style: T.monoBody,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
      onSubmitted: (v) {
        final n = int.tryParse(v);
        if (n != null && n > 0) widget.onChanged(n);
      },
    );
  }
}

// =================================================================== explorateur

class ExplorerView extends StatefulWidget {
  const ExplorerView({super.key, required this.api, required this.session, required this.schema, this.seed, this.report, required this.onSaved});
  final ApiClient api;
  final Session session;
  final ASchema schema;
  final Map<String, dynamic>? seed;
  final SavedReport? report;
  final VoidCallback onSaved;

  @override
  State<ExplorerView> createState() => _ExplorerViewState();
}

/// Sources mises en avant ; les autres sont sous « Plus ».
const _kPrimarySources = ['sale_lines', 'stock_snapshot', 'purchase_lines', 'partner_ledger'];

/// Mesure et découpage par défaut quand on change de sujet : jamais d'écran vide.
Map<String, dynamic>? _defaultMeasure(ASource s, User u) {
  String? pick(List<String> keys) {
    for (final k in keys) {
      if (s.namedMeasure(k) != null) return k;
    }
    return null;
  }
  final k = switch (s.key) {
    'sale_lines' => pick(['ca_ttc']),
    'purchase_lines' => pick(['total_ht', 'qty']),
    'stock_movements' => pick(['net_qty']),
    'stock_snapshot' => pick(['qty']),
    'partner_ledger' => pick(['balance']),
    'product_performance' => pick(['qty_sold']),
    _ => s.named.isEmpty ? null : s.named.first.key,
  };
  return k == null ? null : {'name': k};
}

List<String> _defaultDims(ASource s) => switch (s.key) {
      'stock_snapshot' => ['category_name'],
      'partner_ledger' => ['partner_name'],
      'product_performance' => ['product_name'],
      _ => s.dateField.isEmpty ? [] : ['${s.dateField}:day'],
    };

Map<String, dynamic> _defaultRange(ASource s) => s.dateField.isEmpty && s.key != 'product_performance' ? {'type': 'all'} : {'type': 'this_month'};

/// Seau adapté à la période : jour ≤ 31 j, semaine ≤ 90 j, mois au-delà.
String _autoBucket(Map<String, dynamic> range) {
  final t = (range['type'] as String?) ?? 'this_month';
  final n = (range['n'] as num?)?.toInt() ?? 0;
  switch (t) {
    case 'today':
    case 'yesterday':
    case 'this_week':
    case 'previous_week':
    case 'this_month':
    case 'previous_month':
      return 'day';
    case 'this_quarter':
    case 'previous_quarter':
      return 'week';
    case 'this_year':
    case 'previous_year':
    case 'year_to_date':
    case 'all':
      return 'month';
    case 'last_n_days':
      return n <= 31 ? 'day' : n <= 90 ? 'week' : 'month';
    case 'last_n_months':
      return n <= 1 ? 'day' : n <= 3 ? 'week' : 'month';
    case 'custom':
      final a = DateTime.tryParse('${range['from']}');
      final b = DateTime.tryParse('${range['to']}');
      if (a == null || b == null) return 'day';
      final d = b.difference(a).inDays;
      return d <= 31 ? 'day' : d <= 90 ? 'week' : 'month';
  }
  return 'day';
}

class _ExplorerViewState extends State<ExplorerView> with TickerProviderStateMixin {
  late ASource _source;
  List<String> _dims = [];
  List<Map<String, dynamic>> _measures = [];
  List<Map<String, dynamic>> _filters = [];
  List<Map<String, dynamic>> _having = [];
  Map<String, dynamic> _range = {'type': 'this_month'};
  bool _compare = false;
  Map<String, int> _params = {};
  int _limit = 500;
  Map<String, dynamic>? _comboSpec; // vue croisée (venue de l'IA ou d'une vue enregistrée) : non éditable ici

  AResult? _result;
  String? _error;
  int? _errorStatus;
  bool _running = false;
  Timer? _debounce;
  int _gen = 0;
  String? _chartType;
  ChartEncoding _encoding = ChartEncoding();
  bool _showStyle = false;
  bool _askCollapsed = false;
  bool _showGallery = false;
  bool _multiView = false; // après une réponse de l'IA : toutes les vues possibles, deux par ligne
  List<GalleryItem> _gallery = const [];

  // ---- assistant
  final _askCtrl = TextEditingController();
  final _askFocus = FocusNode();
  bool _asking = false;
  int _askPhase = 0;
  Timer? _phaseTimer;
  AskAnswer? _answer;
  bool _demo = false;
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  late final AnimationController _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));

  static const _phases = ['Je lis votre question…', 'Je choisis la source et les mesures…', 'Je construis la vue…', 'Je calcule sur vos données…'];

  @override
  void initState() {
    super.initState();
    _source = widget.schema.sources.first;
    final seed = widget.seed;
    if (seed != null) {
      _applySpec(seed, silent: true);
    } else {
      _applyDefaults(_source);
    }
    if (widget.report != null) {
      _chartType = widget.report!.chartType == 'auto' ? null : widget.report!.chartType;
      _encoding = ChartEncoding.fromJson(widget.report!.encoding);
    }
    widget.api.analyticsGallery().then((g) {
      if (mounted) setState(() => _gallery = g);
    }).catchError((_) {});
    _reveal.value = 1;
    _schedule(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _phaseTimer?.cancel();
    _glow.dispose();
    _reveal.dispose();
    _askCtrl.dispose();
    _askFocus.dispose();
    super.dispose();
  }

  void _applyDefaults(ASource s) {
    final m = _defaultMeasure(s, widget.session.user);
    _measures = m == null ? [] : [m];
    _dims = _defaultDims(s);
    _range = _defaultRange(s);
    _filters = [];
    _having = [];
    _params = {};
    _compare = false;
    _comboSpec = null;
    _limit = s.key == 'product_performance' ? 20 : 500;
  }

  /// Charge une spec (galerie, vue enregistrée ou IA) dans le constructeur.
  void _applySpec(Map<String, dynamic> spec, {bool silent = false}) {
    if (spec['combo'] == true) {
      _comboSpec = Map<String, dynamic>.from(spec);
      _range = Map<String, dynamic>.from((spec['range'] as Map?) ?? const {'type': 'this_month'});
      _measures = [];
      _dims = [];
      _filters = [];
      _having = [];
    } else {
      final src = widget.schema.source('${spec['source']}');
      if (src != null) _source = src;
      _comboSpec = null;
      _dims = [for (final d in (spec['dimensions'] as List? ?? const [])) '$d'];
      _measures = [for (final m in (spec['measures'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];
      _filters = [for (final f in (spec['filters'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)];
      _having = [for (final h in (spec['having'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)];
      _range = Map<String, dynamic>.from((spec['range'] as Map?) ?? const {'type': 'this_month'});
      _compare = spec['compare'] != null;
      _params = {for (final e in ((spec['params'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()};
      _limit = (spec['limit'] as num?)?.toInt() ?? 500;
    }
    if (!silent) _schedule(immediate: true);
  }

  Map<String, dynamic> get _spec => _comboSpec != null
      ? {..._comboSpec!, 'range': _range}
      : {
          'source': _source.key,
          'dimensions': _dims,
          'measures': _measures,
          'filters': _filters,
          'having': _having,
          'range': _range,
          if (_compare) 'compare': 'previous_period',
          if (_params.isNotEmpty) 'params': _params,
          'limit': _limit,
        };

  bool get _hasQuery => _comboSpec != null || _measures.isNotEmpty;

  void _schedule({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 300), _run);
  }

  Future<void> _run() async {
    if (!_hasQuery) {
      setState(() {
        _result = null;
        _error = null;
      });
      return;
    }
    final gen = ++_gen;
    setState(() => _running = true);
    try {
      final r = await widget.api.analyticsQuery(_spec);
      if (!mounted || gen != _gen) return;
      setState(() {
        _result = r;
        _error = null;
        _errorStatus = null;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e.message;
        _errorStatus = e.status;
      });
    } finally {
      if (mounted && gen == _gen) setState(() => _running = false);
    }
  }

  void _set(VoidCallback f) {
    setState(f);
    _schedule();
  }

  void _changeSource(ASource s) {
    _set(() {
      _source = s;
      _applyDefaults(s);
      _result = null;
      _chartType = null;
      _encoding = ChartEncoding();
      _answer = null;
    });
  }

  void _drill(AColumn col, dynamic value) {
    if (_comboSpec != null) return;
    final f = _source.field(col.field);
    if (f == null || !f.filterable) return;
    if (col.bucket.isNotEmpty && col.bucket != 'day') return;
    _set(() {
      _filters.add({'field': f.key, 'op': 'eq', 'value': value});
      _dims.remove(col.bucket.isEmpty ? col.field : '${col.field}:${col.bucket}');
    });
  }

  String get _effectiveChart {
    final r = _result;
    if (r == null) return 'table';
    final t = _chartType ?? autoChartType(r);
    return chartTypeBlocker(t, r) == null ? t : 'table';
  }

  // ---- assistant ------------------------------------------------------------

  Future<void> _ask([String? text]) async {
    final q = (text ?? _askCtrl.text).trim();
    if (q.isEmpty || _asking) return;
    _askCtrl.text = q;
    setState(() {
      _asking = true;
      _askPhase = 0;
      _answer = null;
      _showGallery = false;
    });
    _phaseTimer?.cancel();
    _phaseTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (mounted && _asking) setState(() => _askPhase = (_askPhase + 1) % _phases.length);
    });
    try {
      final a = await widget.api.analyticsAsk(q);
      if (!mounted) return;
      _phaseTimer?.cancel();
      setState(() {
        _answer = a;
        _asking = false;
      });
      if (a.spec != null) {
        _gen++; // annule toute requête en vol du constructeur
        setState(() {
          _applySpec(a.spec!, silent: true);
          _chartType = a.chartType == 'auto' || a.chartType.isEmpty ? null : a.chartType;
          _encoding = ChartEncoding();
          _error = a.result == null ? a.error : null;
          _errorStatus = null;
          _result = a.result;
          _multiView = a.result != null && a.result!.rows.isNotEmpty;
          _showStyle = false;
        });
        _reveal.forward(from: 0);
        if (a.result == null) _schedule(immediate: true);
      } else if (a.clarification != null) {
        _askFocus.requestFocus();
      } else {
        setState(() {
          _error = a.error ?? "Je n'ai pas compris la question";
          _errorStatus = null;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _phaseTimer?.cancel();
      setState(() {
        _asking = false;
        _error = e.message;
        _errorStatus = e.status;
      });
    }
  }

  static const _demoQuestions = [
    "Quel est mon chiffre d'affaires par jour ce mois-ci, comparé au mois dernier ?",
    'Quels produits périment dans les 90 prochains jours ?',
    'Répartition de mes achats par fournisseur sur les 3 derniers mois',
    'À quelle heure de la journée je vends le plus ?',
  ];

  Future<void> _runDemo() async {
    if (_demo) return;
    setState(() => _demo = true);
    try {
      for (final q in _demoQuestions) {
        if (!mounted || !_demo) break;
        _askCtrl.clear();
        _askFocus.requestFocus();
        for (var i = 1; i <= q.length; i++) {
          if (!mounted || !_demo) return;
          _askCtrl.text = q.substring(0, i);
          _askCtrl.selection = TextSelection.collapsed(offset: i);
          await Future.delayed(Duration(milliseconds: 18 + (q[i - 1] == ' ' ? 30 : 0)));
        }
        await Future.delayed(const Duration(milliseconds: 350));
        await _ask(q);
        // laisse le temps de lire la réponse
        for (var t = 0; t < 40 && mounted && _demo; t++) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    } finally {
      if (mounted) setState(() => _demo = false);
    }
  }

  // ---- enregistrement ---------------------------------------------------------

  bool get _canEditReport {
    final r = widget.report;
    if (r == null) return false;
    final u = widget.session.user;
    return u.isAdmin || (u.role == 'manager' && (r.isShared || r.isDefault)) || r.ownerId == u.id;
  }

  Future<void> _delete() async {
    final r = widget.report;
    if (r == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer la vue', style: T.h2),
        content: Text('« ${r.name} » sera supprimée de tous les tableaux de bord. Continuer ?', style: T.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          PrimaryButton(label: 'Supprimer', color: T.danger, fg: Colors.white, onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteReport(r.id);
      if (mounted) widget.onSaved();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _save() async {
    final editing = _canEditReport;
    final suggested = widget.report?.name ?? _answer?.title ?? '';
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _SaveDialog(initialName: suggested, initialShared: widget.report?.isShared ?? true, canAdd: !editing),
    );
    if (res == null) return;
    try {
      final saved = await widget.api.saveReport({
        'name': res['name'],
        'spec': _spec,
        'chart_type': _chartType ?? 'auto',
        'encoding': _encoding.toJson(),
        'is_shared': res['shared'] == true,
      }, id: editing ? widget.report!.id : null);
      if (res['add'] == true) {
        final ds = await widget.api.dashboards();
        if (ds.isNotEmpty) {
          final d = ds.first;
          final layout = [for (final t in d.layout) t.toJson()];
          var maxY = 0;
          for (final t in d.layout) {
            if (t.y + t.h > maxY) maxY = t.y + t.h;
          }
          layout.add(DashboardTile(reportId: saved.id, x: 0, y: maxY, w: 6, h: 4).toJson());
          await widget.api.saveDashboard({'name': d.name, 'layout': layout, 'global_range': d.globalRange, 'global_warehouse_id': d.globalWarehouseId, 'is_shared': d.isShared}, id: d.id);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('« ${saved.name} » enregistrée')));
        widget.onSaved();
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _export() async {
    final r = _result;
    if (r == null) return;
    final path = await exportCsv(
      baseName: 'analyse-${_comboSpec != null ? 'croisee' : _source.key}',
      headers: [for (final c in r.columns) c.label],
      rows: [
        for (final row in r.rows)
          [for (var i = 0; i < r.columns.length; i++) r.columns[i].isDimension ? r.labelOf(r.columns[i], row[i]) : fmtValue(row[i], r.columns[i].format)],
      ],
    );
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exporté : $path')));
  }

  // ---- rendu -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _AiBar(
          controller: _askCtrl,
          focus: _askFocus,
          glow: _glow,
          asking: _asking,
          phase: _asking ? _phases[_askPhase] : null,
          answer: _answer,
          demoRunning: _demo,
          onAsk: () => _ask(),
          onDemo: _runDemo,
          onStopDemo: () => setState(() => _demo = false),
          onGallery: () => setState(() => _showGallery = !_showGallery),
          galleryOpen: _showGallery,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: _askCollapsed ? 40 : 300,
              child: _askCollapsed
                  ? Card14(padding: EdgeInsets.zero, child: IconButton(onPressed: () => setState(() => _askCollapsed = false), icon: const Icon(Icons.chevron_right, color: T.muted)))
                  : _AskPanel(
                      schema: widget.schema,
                      source: _source,
                      dims: _dims,
                      measures: _measures,
                      filters: _filters,
                      having: _having,
                      range: _range,
                      compare: _compare,
                      params: _params,
                      combo: _comboSpec != null,
                      onSource: _changeSource,
                      onCompare: (v) => _set(() => _compare = v),
                      onChanged: _set,
                      onCollapse: () => setState(() => _askCollapsed = true),
                      autoBucket: () => _autoBucket(_range),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _showGallery || !_hasQuery ? _galleryPanel() : _answerPanel()),
            if (_showStyle && _result != null && !_showGallery) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 280,
                child: _StylePanel(
                  result: _result!,
                  chartType: _effectiveChart,
                  encoding: _encoding.resolved(_result!),
                  onChanged: (e) => setState(() => _encoding = e),
                  onClose: () => setState(() => _showStyle = false),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  /// Toutes les représentations possibles du résultat, deux par ligne. Un
  /// clic sur l'une d'elles la met en pleine vue ; le bouton de la barre
  /// d'outils ramène à la vue par défaut.
  Widget _allChartsGrid(AResult r, String suggested) {
    final types = [for (final t in kChartTypes) if (chartTypeBlocker(t, r) == null) t];
    return LayoutBuilder(builder: (context, c) {
      const gap = 12.0;
      final w = (c.maxWidth - gap) / 2;
      final h = math.max(230.0, math.min(330.0, (c.maxHeight - gap) / 2));
      return SingleChildScrollView(
        child: Wrap(spacing: gap, runSpacing: gap, children: [
          for (final t in types)
            SizedBox(
              width: w,
              height: h,
              child: _ChartPreviewCard(
                type: t,
                suggested: t == suggested,
                onTap: () => setState(() {
                  _chartType = t;
                  _multiView = false;
                  if (t != 'stat' && t != 'table') _showStyle = true;
                }),
                child: buildChart(t, r, _encoding, compact: true),
              ),
            ),
        ]),
      );
    });
  }

  Widget _galleryPanel() {
    final themes = <String, List<GalleryItem>>{};
    for (final g in _gallery) {
      themes.putIfAbsent(g.theme, () => []).add(g);
    }
    return Card14(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: _gallery.isEmpty
          ? const Center(child: CircularProgressIndicator(color: T.mint))
          : ListView(children: [
              Row(children: [
                const Text('Que voulez-vous savoir ?', style: T.h2),
                const Spacer(),
                if (_hasQuery) TextButton(onPressed: () => setState(() => _showGallery = false), child: const Text('Retour à ma vue')),
              ]),
              const SizedBox(height: 4),
              Text('Une question, un clic. Vous pourrez ensuite ajuster chaque détail à gauche, ou poser votre propre question en haut.', style: T.small),
              const SizedBox(height: 14),
              for (final e in themes.entries) ...[
                MicroLabel(e.key, color: T.mintDark),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final g in e.value)
                    ActionChip(
                      avatar: Icon(kChartIcons[g.chartType] ?? Icons.table_rows_rounded, size: 15, color: T.mintDark),
                      label: Text(g.title, style: T.small.copyWith(color: T.ink)),
                      backgroundColor: T.bg,
                      side: const BorderSide(color: T.border),
                      onPressed: () {
                        _gen++;
                        setState(() {
                          _applySpec(g.spec, silent: true);
                          _chartType = g.chartType == 'auto' ? null : g.chartType;
                          _encoding = ChartEncoding();
                          _answer = null;
                          _showGallery = false;
                          _multiView = false;
                        });
                        _schedule(immediate: true);
                      },
                    ),
                ]),
                const SizedBox(height: 16),
              ],
            ]),
    );
  }

  Widget _answerPanel() {
    final r = _result;
    final type = _effectiveChart;
    return Card14(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (r != null)
            for (final t in kChartTypes)
              Tooltip(
                message: chartTypeBlocker(t, r) ?? kChartLabels[t]!,
                child: InkWell(
                  onTap: chartTypeBlocker(t, r) == null
                      ? () => setState(() {
                            _chartType = t;
                            _multiView = false;
                            if (t != 'stat' && t != 'table') _showStyle = true;
                          })
                      : null,
                  borderRadius: BorderRadius.circular(T.rChip),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(color: type == t ? T.mintTint2 : Colors.transparent, borderRadius: BorderRadius.circular(T.rChip)),
                    child: Icon(kChartIcons[t], size: 18, color: chartTypeBlocker(t, r) != null ? T.ghost : type == t ? T.mintDark : T.muted),
                  ),
                ),
              ),
          if (r != null && _chartType != null && !_multiView) TextButton(onPressed: () => setState(() => _chartType = null), child: const Text('auto', style: TextStyle(fontSize: 12.5))),
          if (r != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: _multiView ? 'Revenir à la vue par défaut' : 'Voir toutes les représentations',
              child: InkWell(
                onTap: () => setState(() {
                  _multiView = !_multiView;
                  if (_multiView) _showStyle = false;
                }),
                borderRadius: BorderRadius.circular(T.rChip),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: _multiView ? T.ink : T.mintTint,
                    borderRadius: BorderRadius.circular(T.rChip),
                    border: Border.all(color: _multiView ? T.ink : T.border),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_multiView ? Icons.fullscreen_rounded : Icons.grid_view_rounded, size: 16, color: _multiView ? Colors.white : T.mintDark),
                    const SizedBox(width: 5),
                    Text(_multiView ? 'Vue par défaut' : 'Toutes les vues', style: T.small.copyWith(color: _multiView ? Colors.white : T.mintDark, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ],
          const Spacer(),
          if (r != null && (type == 'line' || type == 'bar' || type == 'donut' || type == 'pivot'))
            TextButton.icon(onPressed: () => setState(() => _showStyle = !_showStyle), icon: const Icon(Icons.tune_rounded, size: 16), label: const Text('Style')),
          if (r != null) TextButton.icon(onPressed: _export, icon: const Icon(Icons.download_outlined, size: 16), label: const Text('CSV')),
          if (r != null && _canEditReport) IconButton(onPressed: _delete, tooltip: 'Supprimer la vue', icon: const Icon(Icons.delete_outline_rounded, size: 18, color: T.dangerDark)),
          if (r != null) const SizedBox(width: 6),
          if (r != null) PrimaryButton(label: _canEditReport ? 'Enregistrer les modifications' : 'Enregistrer la vue', onPressed: _save),
        ]),
        if (_running || _asking) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.border) else const SizedBox(height: 2),
        const SizedBox(height: 8),
        if (_comboSpec != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(T.rInner)),
            child: Text('Vue croisée (deux sources) : la période se règle à gauche, le reste est fixé par la question.', style: T.small.copyWith(color: T.mintDark)),
          ),
        if (_error != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: T.dangerTint, borderRadius: BorderRadius.circular(T.rInner)),
            child: Row(children: [
              Icon(_errorStatus == 403 ? Icons.lock_outline_rounded : Icons.error_outline_rounded, size: 16, color: T.dangerDark),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: T.small.copyWith(color: T.dangerDark))),
              if (_errorStatus == 504) TextButton(onPressed: () => _set(() => _range = {'type': 'last_n_days', 'n': 30}), child: const Text('Réduire la période')),
            ]),
          ),
        if (r != null && r.truncated)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: T.warnTint, borderRadius: BorderRadius.circular(T.rInner)),
            child: Text('Affichage des ${r.rows.length} premières lignes sur ${r.totalRows} — ajoutez un filtre ou exportez en CSV', style: T.small.copyWith(color: T.warnDark)),
          ),
        if (r != null && r.dropped.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('Non disponible pour votre rôle : ${r.dropped.join(', ')}', style: T.small.copyWith(color: T.warnDark))),
        Expanded(
          child: r == null
              ? const SizedBox()
              : FadeTransition(
                  opacity: CurvedAnimation(parent: _reveal, curve: Curves.easeOut),
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: _reveal, curve: Curves.easeOutCubic)),
                    child: Opacity(opacity: _running ? 0.55 : 1, child: _multiView ? _allChartsGrid(r, type) : buildChart(type, r, _encoding, onDrill: _drill)),
                  ),
                ),
        ),
        if (r != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Text('${r.totalRows} ligne${r.totalRows > 1 ? 's' : ''} · ${r.durationMs} ms${r.cached ? ' · cache' : ''}', style: T.small),
              const Spacer(),
              Text(r.rangeAll ? 'Toute la période' : '${r.rangeFrom} → ${r.rangeTo}${r.prevFrom != null ? '   (comparé à ${r.prevFrom} → ${r.prevTo})' : ''}', style: T.small),
            ]),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------- aperçu d'une représentation

class _ChartPreviewCard extends StatefulWidget {
  const _ChartPreviewCard({required this.type, required this.suggested, required this.onTap, required this.child});
  final String type;
  final bool suggested;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ChartPreviewCard> createState() => _ChartPreviewCardState();
}

class _ChartPreviewCardState extends State<_ChartPreviewCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rCard),
            border: Border.all(color: _hover || widget.suggested ? T.mint : T.border, width: _hover ? 1.8 : 1),
            boxShadow: [
              if (_hover || widget.suggested) BoxShadow(color: T.mint.withValues(alpha: _hover ? 0.28 : 0.14), blurRadius: _hover ? 18 : 10, spreadRadius: 1),
            ],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(kChartIcons[widget.type], size: 16, color: T.mintDark),
              const SizedBox(width: 6),
              Text(kChartLabels[widget.type] ?? widget.type, style: T.h2.copyWith(fontSize: 14)),
              const Spacer(),
              if (widget.suggested) const MintChip('Suggéré par l\'IA', color: T.mintTint2, fg: T.mintDark),
              if (_hover && !widget.suggested) Text('Cliquer pour agrandir', style: T.small),
            ]),
            const SizedBox(height: 6),
            // les aperçus sont en lecture seule : le clic sélectionne la vue
            Expanded(child: AbsorbPointer(child: widget.child)),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- barre IA

class _AiBar extends StatelessWidget {
  const _AiBar({
    required this.controller,
    required this.focus,
    required this.glow,
    required this.asking,
    required this.phase,
    required this.answer,
    required this.demoRunning,
    required this.onAsk,
    required this.onDemo,
    required this.onStopDemo,
    required this.onGallery,
    required this.galleryOpen,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final AnimationController glow;
  final bool asking, demoRunning, galleryOpen;
  final String? phase;
  final AskAnswer? answer;
  final VoidCallback onAsk, onDemo, onStopDemo, onGallery;

  @override
  Widget build(BuildContext context) {
    final a = answer;
    return AnimatedBuilder(
      animation: glow,
      builder: (context, _) {
        final t = glow.value;
        final pulse = asking ? 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * math.pi * 2)) : 0.35;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CustomPaint(
            painter: _GlowBorderPainter(progress: t, active: asking, intensity: pulse),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: T.mint.withValues(alpha: asking ? 0.35 * pulse : 0.12), blurRadius: asking ? 26 : 14, spreadRadius: asking ? 2 : 0)],
              ),
              child: Row(children: [
                Transform.scale(
                  scale: asking ? 1 + 0.12 * math.sin(t * math.pi * 2) : 1,
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(colors: [T.mint, Color(0xFF4A63B8), Color(0xFF7B61C9)]).createShader(rect),
                    child: const Icon(Icons.auto_awesome_rounded, size: 22, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    enabled: !demoRunning,
                    style: T.body.copyWith(fontSize: 14.5),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: asking ? phase : "Posez votre question à Elixir AI — « marge par labo ce trimestre », « quels produits périment ? »…",
                      hintStyle: T.body.copyWith(color: asking ? T.mintDark : T.faint, fontSize: 14, fontStyle: asking ? FontStyle.italic : FontStyle.normal),
                    ),
                    onSubmitted: (_) => onAsk(),
                  ),
                ),
                if (asking)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: T.mint)))
                else
                  IconButton(onPressed: onAsk, tooltip: 'Demander', icon: const Icon(Icons.arrow_upward_rounded, size: 20), style: IconButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink)),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: onGallery,
                  icon: Icon(galleryOpen ? Icons.close_rounded : Icons.lightbulb_outline_rounded, size: 16),
                  label: Text(galleryOpen ? 'Fermer' : 'Questions'),
                ),
                TextButton.icon(
                  onPressed: demoRunning ? onStopDemo : onDemo,
                  icon: Icon(demoRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline_rounded, size: 16),
                  label: Text(demoRunning ? 'Arrêter' : 'Démo'),
                ),
              ]),
            ),
          ),
          if (a != null && !asking)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 6),
              child: Row(children: [
                MintChip(a.provider == 'cloud' ? 'Elixir AI' : 'Elixir AI · hors ligne', color: a.provider == 'cloud' ? T.mintTint2 : T.border, fg: a.provider == 'cloud' ? T.mintDark : T.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    a.clarification != null
                        ? '❓ ${a.clarification}'
                        : a.spec == null
                            ? (a.error ?? "Je n'ai pas compris la question")
                            : '${a.title.isNotEmpty ? '${a.title} — ' : ''}${a.explanation}',
                    style: T.small.copyWith(color: a.spec == null && a.clarification == null ? T.dangerDark : T.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (a.durationMs > 0) Text('${a.durationMs} ms${a.attempts > 1 ? ' · ${a.attempts} essais' : ''}', style: T.small),
              ]),
            ),
        ]);
      },
    );
  }
}

/// Liseré lumineux tournant autour de la barre pendant que l'IA travaille.
class _GlowBorderPainter extends CustomPainter {
  _GlowBorderPainter({required this.progress, required this.active, required this.intensity});
  final double progress, intensity;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(16));
    if (!active) {
      canvas.drawRRect(rrect, Paint()
        ..color = T.mint.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
      return;
    }
    final sweep = SweepGradient(
      startAngle: 0,
      endAngle: math.pi * 2,
      transform: GradientRotation(progress * math.pi * 2),
      colors: const [T.mint, Color(0xFF4A63B8), Color(0xFF7B61C9), Color(0xFFE0A020), T.mint],
    );
    canvas.drawRRect(rrect, Paint()
      ..shader = sweep.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 + 1.2 * intensity);
    canvas.drawRRect(rrect.inflate(2), Paint()
      ..shader = sweep.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..color = Colors.white.withValues(alpha: 0.5 * intensity));
  }

  @override
  bool shouldRepaint(_GlowBorderPainter old) => old.progress != progress || old.active != active || old.intensity != intensity;
}

// ------------------------------------------------------------------- panneau A (simplifié)

class _AskPanel extends StatefulWidget {
  const _AskPanel({
    required this.schema,
    required this.source,
    required this.dims,
    required this.measures,
    required this.filters,
    required this.having,
    required this.range,
    required this.compare,
    required this.params,
    required this.combo,
    required this.onSource,
    required this.onCompare,
    required this.onChanged,
    required this.onCollapse,
    required this.autoBucket,
  });
  final ASchema schema;
  final ASource source;
  final List<String> dims;
  final List<Map<String, dynamic>> measures, filters, having;
  final Map<String, dynamic> range;
  final bool compare, combo;
  final Map<String, int> params;
  final ValueChanged<ASource> onSource;
  final ValueChanged<bool> onCompare;
  final void Function(VoidCallback) onChanged;
  final VoidCallback onCollapse;
  final String Function() autoBucket;

  @override
  State<_AskPanel> createState() => _AskPanelState();
}

class _AskPanelState extends State<_AskPanel> {
  bool _moreSources = false;
  bool _advanced = false;

  ASource get source => widget.source;

  String _dimLabel(String d) {
    final parts = d.split(':');
    final f = source.field(parts[0]);
    final base = f?.labelFr ?? parts[0];
    return parts.length > 1 ? '$base · ${kBucketLabels[parts[1]] ?? parts[1]}' : base;
  }

  String _measureLabel(Map<String, dynamic> m) {
    if (m['name'] != null) return source.namedMeasure('${m['name']}')?.labelFr ?? '${m['name']}';
    final f = source.field('${m['field']}');
    return '${kAggLabels[m['agg'] ?? 'sum'] ?? m['agg']} · ${f?.labelFr ?? m['field']}';
  }

  String _measureLabelFor(String ref) {
    final n = source.namedMeasure(ref);
    if (n != null) return n.labelFr;
    final m = RegExp(r'^m(\d+)$').firstMatch(ref);
    if (m != null) {
      final i = int.parse(m.group(1)!);
      if (i < widget.measures.length) return _measureLabel(widget.measures[i]);
    }
    return ref;
  }

  String _filterLabel(Map<String, dynamic> f) {
    final fld = source.field('${f['field']}');
    final op = '${f['op']}';
    final v = f['value'];
    final vs = v is List ? v.map((e) => '$e').join(', ') : v == true ? 'oui' : v == false ? 'non' : '${v ?? ''}';
    return '${fld?.labelFr ?? f['field']} ${kOpLabels[op] ?? op} $vs'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final primary = [for (final s in widget.schema.sources) if (_kPrimarySources.contains(s.key)) s];
    final others = [for (final s in widget.schema.sources) if (!_kPrimarySources.contains(s.key)) s];
    final showOthers = _moreSources || others.any((s) => s.key == source.key);
    final hasPeriod = source.dateField.isNotEmpty || source.key == 'product_performance';
    return Card14(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      child: ListView(children: [
        Row(children: [
          const MicroLabel('Sujet', color: T.mintDark),
          const Spacer(),
          IconButton(onPressed: widget.onCollapse, icon: const Icon(Icons.chevron_left, size: 18, color: T.muted), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in [...primary, if (showOthers) ...others])
            ChoiceChip(
              label: Text(s.labelFr, style: T.small.copyWith(color: s.key == source.key && !widget.combo ? Colors.white : T.ink, fontSize: 13)),
              selected: s.key == source.key && !widget.combo,
              selectedColor: T.ink,
              backgroundColor: T.bg,
              showCheckmark: false,
              side: const BorderSide(color: T.border),
              onSelected: (_) => widget.onSource(s),
            ),
          if (!showOthers)
            ActionChip(label: Text('Plus…', style: T.small.copyWith(color: T.mintDark, fontSize: 13)), backgroundColor: Colors.transparent, side: const BorderSide(color: T.border), onPressed: () => setState(() => _moreSources = true)),
        ]),
        const SizedBox(height: 14),
        if (widget.combo)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('Vue croisée : choisissez un sujet ci-dessus pour repartir du constructeur.', style: T.small),
          )
        else ...[
          _Zone(
            label: 'Que voulez-vous mesurer ?',
            chips: [
              for (var i = 0; i < widget.measures.length; i++)
                _chip(_measureLabel(widget.measures[i]), onDelete: () => widget.onChanged(() => widget.measures.removeAt(i)), color: T.mintTint2),
            ],
            onAdd: () => _pickMeasure(context),
          ),
          _Zone(
            label: widget.dims.isEmpty ? 'Découpé par…' : 'Découpé par… (le 2e devient les colonnes)',
            chips: [for (var i = 0; i < widget.dims.length; i++) _dimChip(context, i)],
            onAdd: widget.dims.length < 3 ? () => _pickDimension(context) : null,
          ),
          _Zone(
            label: 'Filtres',
            chips: [
              for (var i = 0; i < widget.filters.length; i++)
                _chip(_filterLabel(widget.filters[i]), onDelete: () => widget.onChanged(() => widget.filters.removeAt(i)), onTap: () => _editFilter(context, i)),
            ],
            onAdd: () => _editFilter(context, null),
          ),
        ],
        const SizedBox(height: 4),
        const MicroLabel('Période'),
        const SizedBox(height: 4),
        if (!hasPeriod && !widget.combo)
          Text('Ce sujet est un état instantané (pas de période)', style: T.small)
        else
          RangePicker(
              value: widget.range,
              onChanged: (r) => widget.onChanged(() {
                    widget.range
                      ..clear()
                      ..addAll(r);
                    // le seau de la dimension date suit la période
                    for (var i = 0; i < widget.dims.length; i++) {
                      final parts = widget.dims[i].split(':');
                      if (parts.length == 2 && parts[0] == source.dateField && parts[1] != 'dow' && parts[1] != 'hour') {
                        widget.dims[i] = '${parts[0]}:${widget.autoBucket()}';
                      }
                    }
                  })),
        if (hasPeriod && !widget.combo)
          Row(children: [
            Switch(value: widget.compare, activeThumbColor: T.mint, onChanged: widget.onCompare),
            Expanded(child: Text('Comparer à la période précédente', style: T.small.copyWith(color: T.ink))),
          ]),
        if (!widget.combo) ...[
          const SizedBox(height: 6),
          InkWell(
            onTap: () => setState(() => _advanced = !_advanced),
            child: Row(children: [
              Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 16, color: T.mintDark),
              const SizedBox(width: 4),
              Text('Avancé', style: T.small.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
            ]),
          ),
          if (_advanced) ...[
            const SizedBox(height: 8),
            if (widget.measures.isNotEmpty)
              _Zone(
                label: 'Sur le résultat (après totaux)',
                chips: [
                  for (var i = 0; i < widget.having.length; i++)
                    _chip('${_measureLabelFor('${widget.having[i]['measure']}')} ${kOpLabels[widget.having[i]['op']] ?? widget.having[i]['op']} ${widget.having[i]['value']}',
                        onDelete: () => widget.onChanged(() => widget.having.removeAt(i))),
                ],
                onAdd: () => _editHaving(context),
              ),
            for (final p in source.params)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(child: Text(p.labelFr, style: T.small.copyWith(color: T.ink))),
                  SizedBox(width: 64, child: _NumField(value: widget.params[p.key] ?? p.def, onChanged: (n) => widget.onChanged(() => widget.params[p.key] = n))),
                ]),
              ),
          ],
        ],
      ]),
    );
  }

  Widget _dimChip(BuildContext context, int i) {
    final d = widget.dims[i];
    final parts = d.split(':');
    final f = source.field(parts[0]);
    return _chip(i == 0 ? _dimLabel(d) : '${_dimLabel(d)} → colonnes',
        onDelete: () => widget.onChanged(() => widget.dims.removeAt(i)),
        onTap: f != null && f.isDate
            ? () async {
                final b = await _pickBucket(context, f);
                if (b != null) widget.onChanged(() => widget.dims[i] = '${f.key}:$b');
              }
            : null,
        color: T.bg);
  }

  Widget _chip(String text, {required VoidCallback onDelete, VoidCallback? onTap, Color color = T.bg}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rChip),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(T.rChip), border: Border.all(color: T.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(text, style: T.small.copyWith(color: T.ink, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          InkWell(onTap: onDelete, child: const Icon(Icons.close, size: 13, color: T.faint)),
        ]),
      ),
    );
  }

  Future<void> _pickMeasure(BuildContext context) async {
    final res = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _MeasurePicker(source: source));
    if (res != null) widget.onChanged(() => widget.measures.add(res));
  }

  Future<void> _pickDimension(BuildContext context) async {
    final f = await showDialog<AField>(
        context: context,
        builder: (_) => _FieldPicker(source: source, title: 'Découper par', onlyDimensions: true, exclude: {for (final d in widget.dims) d.split(':')[0]}));
    if (f == null) return;
    var key = f.key;
    if (f.isDate) {
      // granularité automatique d'après la période ; modifiable en cliquant la puce
      key = '${f.key}:${f.key == source.dateField ? widget.autoBucket() : 'month'}';
    }
    widget.onChanged(() => widget.dims.add(key));
  }

  Future<String?> _pickBucket(BuildContext context, AField f) {
    return showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text('Granularité · ${f.labelFr}', style: T.h2),
        children: [
          for (final b in f.buckets) SimpleDialogOption(onPressed: () => Navigator.pop(context, b), child: Text(kBucketLabels[b] ?? b, style: T.body)),
        ],
      ),
    );
  }

  Future<void> _editFilter(BuildContext context, int? index) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FilterDialog(source: source, initial: index == null ? null : widget.filters[index]),
    );
    if (res == null) return;
    widget.onChanged(() {
      if (index == null) {
        widget.filters.add(res);
      } else {
        widget.filters[index] = res;
      }
    });
  }

  Future<void> _editHaving(BuildContext context) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _HavingDialog(labels: [for (var i = 0; i < widget.measures.length; i++) ('m$i', _measureLabel(widget.measures[i]))]),
    );
    if (res != null) widget.onChanged(() => widget.having.add(res));
  }
}

class _Zone extends StatelessWidget {
  const _Zone({required this.label, required this.chips, this.onAdd});
  final String label;
  final List<Widget> chips;
  final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          MicroLabel(label),
          const Spacer(),
          if (onAdd != null)
            InkWell(onTap: onAdd, child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.add_circle_outline, size: 16, color: T.mintDark))),
        ]),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(color: T.bg.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(T.rInner), border: Border.all(color: T.border2)),
          child: chips.isEmpty
              ? Padding(padding: const EdgeInsets.all(4), child: Text(onAdd == null ? '—' : 'Ajouter…', style: T.small.copyWith(color: T.ghost)))
              : Wrap(spacing: 5, runSpacing: 5, children: chips),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------- pickers

class _FieldPicker extends StatefulWidget {
  const _FieldPicker({required this.source, required this.title, this.onlyDimensions = false, this.onlyFilterable = false, this.exclude = const {}});
  final ASource source;
  final String title;
  final bool onlyDimensions, onlyFilterable;
  final Set<String> exclude;
  @override
  State<_FieldPicker> createState() => _FieldPickerState();
}

class _FieldPickerState extends State<_FieldPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<AField>>{};
    for (final f in widget.source.fields) {
      if (widget.onlyDimensions && !f.dimension) continue;
      if (widget.onlyFilterable && !f.filterable) continue;
      if (widget.exclude.contains(f.key)) continue;
      if (_q.isNotEmpty && !f.labelFr.toLowerCase().contains(_q.toLowerCase())) continue;
      groups.putIfAbsent(f.group.isEmpty ? 'Autres' : f.group, () => []).add(f);
    }
    return Dialog(
      child: SizedBox(
        width: 420,
        height: 520,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [Text(widget.title, style: T.h2), const Spacer(), IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18))]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(autofocus: true, onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(hintText: 'Rechercher un champ…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder())),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(8), children: [
              for (final g in groups.entries) ...[
                Padding(padding: const EdgeInsets.fromLTRB(8, 10, 8, 4), child: MicroLabel(g.key, color: T.mintDark)),
                for (final f in g.value)
                  ListTile(
                    dense: true,
                    title: Text(f.labelFr, style: T.body),
                    subtitle: f.isDate ? Text('date · ${f.buckets.map((b) => kBucketLabels[b]).join(', ')}', style: T.small) : null,
                    onTap: () => Navigator.pop(context, f),
                  ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MeasurePicker extends StatefulWidget {
  const _MeasurePicker({required this.source});
  final ASource source;
  @override
  State<_MeasurePicker> createState() => _MeasurePickerState();
}

class _MeasurePickerState extends State<_MeasurePicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    final named = [for (final n in s.named) if (_q.isEmpty || n.labelFr.toLowerCase().contains(_q.toLowerCase())) n];
    final fields = [for (final f in s.fields) if (f.measure && (_q.isEmpty || f.labelFr.toLowerCase().contains(_q.toLowerCase()))) f];
    return Dialog(
      child: SizedBox(
        width: 460,
        height: 540,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(children: [const Text('Ajouter une valeur', style: T.h2), const Spacer(), IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18))]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(autofocus: true, onChanged: (v) => setState(() => _q = v), decoration: const InputDecoration(hintText: 'Rechercher…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder())),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(8), children: [
              const Padding(padding: EdgeInsets.fromLTRB(8, 10, 8, 4), child: MicroLabel('Indicateurs prêts à l\'emploi', color: T.mintDark)),
              for (final n in named)
                ListTile(dense: true, title: Text(n.labelFr, style: T.body), trailing: Text(n.format, style: T.monoSmall), onTap: () => Navigator.pop(context, {'name': n.key})),
              const Padding(padding: EdgeInsets.fromLTRB(8, 14, 8, 4), child: MicroLabel('Champ + agrégat', color: T.mintDark)),
              for (final f in fields)
                ListTile(
                  dense: true,
                  title: Text(f.labelFr, style: T.body),
                  trailing: Wrap(spacing: 4, children: [
                    for (final a in f.aggs)
                      ActionChip(
                        label: Text(kAggLabels[a] ?? a, style: T.small.copyWith(fontSize: 12, color: T.ink)),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(context, {'field': f.key, 'agg': a}),
                      ),
                    if (f.dimension)
                      ActionChip(
                        label: Text('Distincts', style: T.small.copyWith(fontSize: 12, color: T.ink)),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(context, {'field': f.key, 'agg': 'count_distinct'}),
                      ),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _FilterDialog extends StatefulWidget {
  const _FilterDialog({required this.source, this.initial});
  final ASource source;
  final Map<String, dynamic>? initial;
  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  AField? _field;
  String _op = 'eq';
  final _v1 = TextEditingController();
  final _v2 = TextEditingController();
  bool _bool = true;
  final Set<String> _multi = {};

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _field = widget.source.field('${i['field']}');
      _op = '${i['op']}';
      final v = i['value'];
      if (v is List) {
        _multi.addAll(v.map((e) => '$e'));
      } else if (v is bool) {
        _bool = v;
      } else if (v != null) {
        _v1.text = '$v';
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _field;
    final ops = f?.ops ?? const <String>[];
    if (f != null && !ops.contains(_op)) _op = ops.first;
    return AlertDialog(
      title: Text(widget.initial == null ? 'Ajouter un filtre' : 'Modifier le filtre', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          OutlinedButton(
            onPressed: () async {
              final x = await showDialog<AField>(context: context, builder: (_) => _FieldPicker(source: widget.source, title: 'Filtrer sur', onlyFilterable: true));
              if (x != null) setState(() {
                _field = x;
                _multi.clear();
                _v1.clear();
              });
            },
            child: Text(f?.labelFr ?? 'Choisir un champ…', style: T.body),
          ),
          if (f != null) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, children: [
              for (final o in ops)
                ChoiceChip(label: Text(kOpLabels[o] ?? o, style: T.small.copyWith(color: _op == o ? Colors.white : T.ink)), selected: _op == o, selectedColor: T.ink, showCheckmark: false, onSelected: (_) => setState(() => _op = o)),
            ]),
            const SizedBox(height: 10),
            if (_op == 'is_null' || _op == 'is_not_null')
              const SizedBox()
            else if (f.type == 'bool')
              Row(children: [Switch(value: _bool, activeThumbColor: T.mint, onChanged: (v) => setState(() => _bool = v)), Text(_bool ? 'Oui' : 'Non', style: T.body)])
            else if (f.enumValues.isNotEmpty && (_op == 'in' || _op == 'not_in'))
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final v in f.enumValues)
                  FilterChip(label: Text(v, style: T.small.copyWith(color: T.ink)), selected: _multi.contains(v), onSelected: (s) => setState(() => s ? _multi.add(v) : _multi.remove(v))),
              ])
            else if (f.enumValues.isNotEmpty)
              DropdownButton<String>(
                value: f.enumValues.contains(_v1.text) ? _v1.text : null,
                hint: const Text('Valeur'),
                items: [for (final v in f.enumValues) DropdownMenuItem(value: v, child: Text(v))],
                onChanged: (v) => setState(() => _v1.text = v ?? ''),
              )
            else if (_op == 'in' || _op == 'not_in')
              TextField(controller: _v1, decoration: const InputDecoration(labelText: 'Valeurs séparées par des virgules', isDense: true, border: OutlineInputBorder()))
            else if (_op == 'between')
              Row(children: [
                Expanded(child: TextField(controller: _v1, decoration: InputDecoration(labelText: f.isDate ? 'Du (AAAA-MM-JJ)' : 'De', isDense: true, border: const OutlineInputBorder()))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _v2, decoration: InputDecoration(labelText: f.isDate ? 'Au (AAAA-MM-JJ)' : 'À', isDense: true, border: const OutlineInputBorder()))),
              ])
            else
              TextField(controller: _v1, autofocus: true, decoration: InputDecoration(labelText: f.isDate ? 'AAAA-MM-JJ' : f.type == 'number' ? 'Valeur (${f.unit == 'centimes' ? 'centimes' : f.unit == 'milli' ? 'millièmes' : 'nombre'})' : 'Valeur', isDense: true, border: const OutlineInputBorder())),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(
          label: 'Appliquer',
          onPressed: f == null
              ? null
              : () {
                  dynamic value;
                  if (_op == 'is_null' || _op == 'is_not_null') {
                    value = null;
                  } else if (f.type == 'bool') {
                    value = _bool;
                  } else if (_op == 'in' || _op == 'not_in') {
                    value = f.enumValues.isNotEmpty ? _multi.toList() : [for (final p in _v1.text.split(',')) if (p.trim().isNotEmpty) p.trim()];
                  } else if (_op == 'between') {
                    value = f.type == 'number' ? [double.tryParse(_v1.text) ?? 0, double.tryParse(_v2.text) ?? 0] : [_v1.text.trim(), _v2.text.trim()];
                  } else if (f.type == 'number') {
                    value = double.tryParse(_v1.text.replaceAll(',', '.')) ?? 0;
                  } else {
                    value = _v1.text.trim();
                  }
                  Navigator.pop(context, {'field': f.key, 'op': _op, if (value != null) 'value': value});
                },
        ),
      ],
    );
  }
}

class _HavingDialog extends StatefulWidget {
  const _HavingDialog({required this.labels});
  final List<(String, String)> labels;
  @override
  State<_HavingDialog> createState() => _HavingDialogState();
}

class _HavingDialogState extends State<_HavingDialog> {
  late String _m = widget.labels.first.$1;
  String _op = 'gt';
  final _v = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filtrer sur le résultat', style: T.h2),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButton<String>(value: _m, isExpanded: true, items: [for (final l in widget.labels) DropdownMenuItem(value: l.$1, child: Text(l.$2, style: T.body))], onChanged: (v) => setState(() => _m = v!)),
        Wrap(spacing: 6, children: [
          for (final o in const ['gt', 'gte', 'lt', 'lte', 'eq', 'ne'])
            ChoiceChip(label: Text(kOpLabels[o]!, style: T.small.copyWith(color: _op == o ? Colors.white : T.ink)), selected: _op == o, selectedColor: T.ink, showCheckmark: false, onSelected: (_) => setState(() => _op = o)),
        ]),
        const SizedBox(height: 8),
        TextField(controller: _v, autofocus: true, decoration: const InputDecoration(labelText: 'Valeur (même unité que la mesure : centimes, millièmes, ratio)', isDense: true, border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: 'Appliquer', onPressed: () => Navigator.pop(context, {'measure': _m, 'op': _op, 'value': double.tryParse(_v.text.replaceAll(',', '.')) ?? 0})),
      ],
    );
  }
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.initialName, required this.initialShared, required this.canAdd});
  final String initialName;
  final bool initialShared, canAdd;
  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late bool _shared = widget.initialShared;
  bool _add = false;
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enregistrer la vue', style: T.h2),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Nom', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        Row(children: [Switch(value: _shared, activeThumbColor: T.mint, onChanged: (v) => setState(() => _shared = v)), const Text('Partager avec tout le magasin', style: T.body)]),
        if (widget.canAdd) Row(children: [Switch(value: _add, activeThumbColor: T.mint, onChanged: (v) => setState(() => _add = v)), const Text('Ajouter au tableau de bord', style: T.body)]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: 'Enregistrer', onPressed: () => _name.text.trim().isEmpty ? null : Navigator.pop(context, {'name': _name.text.trim(), 'shared': _shared, 'add': _add})),
      ],
    );
  }
}

Future<String?> _askName(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title, style: T.h2),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Nom', isDense: true, border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: 'Créer', onPressed: () => Navigator.pop(context, c.text.trim().isEmpty ? null : c.text.trim())),
      ],
    ),
  );
}

// ------------------------------------------------------------------- panneau C

class _StylePanel extends StatelessWidget {
  const _StylePanel({required this.result, required this.chartType, required this.encoding, required this.onChanged, required this.onClose});
  final AResult result;
  final String chartType;
  final ChartEncoding encoding;
  final ValueChanged<ChartEncoding> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final e = encoding;
    final dims = r.dimensions;
    final meas = r.measures;
    Widget row(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [MicroLabel(label), const SizedBox(height: 4), child]),
        );
    return Card14(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      child: ListView(children: [
        Row(children: [const Text('Style', style: T.h2), const Spacer(), IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 16, color: T.muted), padding: EdgeInsets.zero, constraints: const BoxConstraints())]),
        const SizedBox(height: 8),
        if (chartType == 'line' || chartType == 'bar' || chartType == 'donut') ...[
          row('Axe X', _dd(dims, e.x, (v) => onChanged(e..x = v))),
          if (chartType != 'donut' && dims.length > 1)
            row('Séries (couleur)', _dd(dims.where((d) => d.key != e.x).toList(), e.series, (v) => onChanged(e..series = v), allowNone: true)),
          if (chartType != 'donut')
            row('Valeurs (Y)', Wrap(spacing: 6, runSpacing: 6, children: [
              for (final m in meas)
                FilterChip(
                  label: Text(m.label, style: T.small.copyWith(color: T.ink, fontSize: 12.5)),
                  selected: e.y.contains(m.key),
                  onSelected: (s) => onChanged(e..y = s ? [...e.y, m.key] : [for (final k in e.y) if (k != m.key) k]),
                ),
            ])),
          if (chartType == 'bar' && (e.series != null || e.y.length > 1))
            row('Barres', Row(children: [Switch(value: e.stacked, activeThumbColor: T.mint, onChanged: (v) => onChanged(e..stacked = v)), Text(e.stacked ? 'Empilées' : 'Groupées', style: T.body)])),
          if (chartType != 'donut' && e.y.length > 1)
            row('Axe secondaire', _dd([for (final m in meas) if (e.y.contains(m.key)) m], e.secondary, (v) => onChanged(e..secondary = v), allowNone: true)),
          if (chartType == 'bar')
            row('Valeurs sur les barres', Switch(value: e.showValues, activeThumbColor: T.mint, onChanged: (v) => onChanged(e..showValues = v))),
          if (r.prevFrom != null)
            row('Période précédente', Switch(value: e.showPrevious, activeThumbColor: T.mint, onChanged: (v) => onChanged(e..showPrevious = v))),
        ],
        if (chartType == 'pivot') ...[
          row('Colonnes', _dd(dims, e.series ?? dims.last.key, (v) => onChanged(e..series = v))),
          row('Valeurs', Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in meas)
              FilterChip(
                label: Text(m.label, style: T.small.copyWith(color: T.ink, fontSize: 12.5)),
                selected: e.y.contains(m.key),
                onSelected: (s) => onChanged(e..y = s ? [...e.y, m.key] : [for (final k in e.y) if (k != m.key) k]),
              ),
          ])),
        ],
      ]),
    );
  }

  Widget _dd(List<AColumn> cols, String? value, ValueChanged<String?> onChanged, {bool allowNone = false}) {
    return DropdownButton<String>(
      value: cols.any((c) => c.key == value) ? value : (allowNone ? null : (cols.isEmpty ? null : cols.first.key)),
      isExpanded: true,
      hint: const Text('Aucune'),
      underline: const SizedBox(),
      style: T.body,
      items: [
        if (allowNone) const DropdownMenuItem<String>(value: null, child: Text('Aucune')),
        for (final c in cols) DropdownMenuItem(value: c.key, child: Text(c.label, style: T.body, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: onChanged,
    );
  }
}

// ================= « Bien démarrer » (first-run checklist) =================

/// First-run checklist shown at the top of the dashboard until every step is
/// done or the user hides it (remembered per user in [UiPrefs]
/// 'dashboard'/'setup_hidden'). Each step says whether it is done and has the
/// button that does it, through [onOpenModule] ('settings', 'products',
/// 'partners', 'purchases', 'pos').
class SetupChecklist extends StatefulWidget {
  const SetupChecklist({super.key, required this.api, this.onOpenModule});
  final ApiClient api;
  final void Function(String key)? onOpenModule;

  @override
  State<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<SetupChecklist> {
  static const _prefScreen = 'dashboard';
  static const _prefKey = 'setup_hidden';

  bool _hidden = UiPrefs.instance.get<bool>(_prefScreen, _prefKey) == true;
  bool _loaded = false;
  bool _checking = false;
  bool _company = false, _products = false, _supplier = false, _receipt = false, _caisse = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (!_hidden) {
      _check();
      // The dashboard stays alive while the user works in other modules:
      // re-check from time to time so the ticks follow what was done.
      _poll = Timer.periodic(const Duration(seconds: 90), (_) {
        if (!_hidden && !_allDone) _check();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get _allDone => _company && _products && _supplier && _receipt && _caisse;
  int get _doneCount => [_company, _products, _supplier, _receipt, _caisse].where((b) => b).length;

  Future<bool> _safe(Future<bool> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final api = widget.api;
    final r = await Future.wait([
      _safe(() async => (await api.settings())['company_name']?.trim().isNotEmpty ?? false),
      _safe(() async => (await api.products(limit: 1)).isNotEmpty),
      _safe(() async => (await api.partners(kind: 'supplier', limit: 1)).isNotEmpty),
      _safe(() async => (await api.documents(type: 'PURCHASE_RECEIPT', status: 'posted', limit: 1)).isNotEmpty),
      _safe(() async => await api.caisseSessionCount() > 0),
    ]);
    if (!mounted) return;
    setState(() {
      _company = r[0];
      _products = r[1];
      _supplier = r[2];
      _receipt = r[3];
      _caisse = r[4];
      _loaded = true;
      _checking = false;
    });
    if (_allDone) _poll?.cancel();
  }

  void _hide() {
    UiPrefs.instance.set(_prefScreen, _prefKey, true);
    _poll?.cancel();
    setState(() => _hidden = true);
  }

  void _open(String key) => widget.onOpenModule?.call(key);

  @override
  Widget build(BuildContext context) {
    if (_hidden || !_loaded || _allDone) return const SizedBox.shrink();
    final can = widget.onOpenModule != null;
    final steps = <_SetupStep>[
      _SetupStep(
        title: "Informations de l'entreprise",
        help: 'Nom, adresse, NIF, RC : ils sont imprimés sur vos factures et tickets.',
        done: _company,
        actions: [('Ouvrir les paramètres', can ? () => _open('settings') : null)],
      ),
      _SetupStep(
        title: 'Ajouter vos produits',
        help: 'Importez votre liste (Excel, CSV) ou créez vos produits un par un.',
        done: _products,
        actions: [
          ('Importer un fichier', can ? () => _open('products') : null),
          ('Nouveau produit', can ? () => _open('products') : null),
        ],
      ),
      _SetupStep(
        title: 'Ajouter un fournisseur',
        help: 'Celui qui vous livre la marchandise.',
        done: _supplier,
        actions: [('Nouveau fournisseur', can ? () => _open('partners') : null)],
      ),
      _SetupStep(
        title: 'Premier bon de réception',
        help: 'Entrez la marchandise reçue : le stock et le coût moyen se mettent à jour.',
        done: _receipt,
        actions: [('Nouveau bon de réception', can ? () => _open('purchases') : null)],
      ),
      _SetupStep(
        title: 'Ouvrir la caisse',
        help: 'Saisissez le fond de caisse et faites votre première vente.',
        done: _caisse,
        actions: [('Aller à la caisse', can ? () => _open('pos') : null)],
      ),
    ];
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 18),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.mintDeep.withValues(alpha: 0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_outlined, size: 20, color: T.mintDark),
          const SizedBox(width: 8),
          const Text('Bien démarrer', style: T.h2),
          const SizedBox(width: 12),
          Text('$_doneCount sur ${steps.length} étapes faites', style: T.bodyMuted),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _doneCount / steps.length,
                minHeight: 6,
                color: T.mint,
                backgroundColor: T.border,
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _checking ? null : _check,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Actualiser'),
          ),
          TextButton.icon(
            onPressed: _hide,
            style: TextButton.styleFrom(foregroundColor: T.muted),
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            label: const Text('Masquer'),
          ),
        ]),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          const gap = 12.0;
          final perRow = c.maxWidth >= 1250 ? 5 : (c.maxWidth >= 760 ? 3 : (c.maxWidth >= 500 ? 2 : 1));
          final w = (c.maxWidth - gap * (perRow - 1) - 8) / perRow;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (var i = 0; i < steps.length; i++) SizedBox(width: w, child: _stepCard(i + 1, steps[i])),
          ]);
        }),
      ]),
    );
  }

  Widget _stepCard(int n, _SetupStep s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: s.done ? T.mintTint : T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: s.done ? T.mintDeep.withValues(alpha: 0.5) : T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: s.done ? T.mint : T.surface,
              shape: BoxShape.circle,
              border: Border.all(color: s.done ? T.mint : T.border3),
            ),
            child: s.done
                ? const Icon(Icons.check_rounded, size: 17, color: T.ink)
                : Text('$n', style: T.monoSmall.copyWith(color: T.ink, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(s.title, style: T.body.copyWith(fontWeight: FontWeight.w700, color: s.done ? T.mintDark : T.ink)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(s.done ? 'Fait.' : s.help, style: T.small),
        if (!s.done) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (var i = 0; i < s.actions.length; i++)
              i == s.actions.length - 1
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: T.mint,
                        foregroundColor: T.ink,
                        minimumSize: const Size(0, 38),
                        textStyle: const TextStyle(fontFamily: T.sans, fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                      onPressed: s.actions[i].$2,
                      child: Text(s.actions[i].$1),
                    )
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: T.ink,
                        side: const BorderSide(color: T.border3),
                        minimumSize: const Size(0, 38),
                        textStyle: const TextStyle(fontFamily: T.sans, fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                      onPressed: s.actions[i].$2,
                      child: Text(s.actions[i].$1),
                    ),
          ]),
        ],
      ]),
    );
  }
}

class _SetupStep {
  const _SetupStep({required this.title, required this.help, required this.done, required this.actions});
  final String title;
  final String help;
  final bool done;
  final List<(String, VoidCallback?)> actions;
}
