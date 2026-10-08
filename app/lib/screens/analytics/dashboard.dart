part of '../analytics_screen.dart';

// =================================================================== module « Tableau de bord »

/// Module « Tableau de bord » : uniquement les tuiles. « Modifier » envoie la
/// vue dans le module Explorateur ([onEdit]) ; « Ouvrir dans l'explorateur »
/// y ouvre une copie ([onExplore] si le shell le fournit, sinon par
/// [AnalyticsBus.pendingRequest]).
class AnalyticsDashboardScreen extends StatefulWidget {
  const AnalyticsDashboardScreen({super.key, required this.api, required this.session, required this.onEdit, required this.onNew, this.onOpenModule, this.onExplore});
  final ApiClient api;
  final Session session;
  final void Function(SavedReport) onEdit;
  final VoidCallback onNew;

  /// Ouvre l'explorateur avec une demande (copie d'une vue, titre, origine).
  final void Function(ExplorerRequest request)? onExplore;

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
    _loadSchema();
  }

  void _loadSchema() {
    setState(() => _error = null);
    widget.api
        .analyticsSchema()
        .then((s) {
          if (mounted) setState(() => _schema = s);
        })
        .catchError((e) {
          if (mounted) setState(() => _error = _errText(e));
        });
  }

  void _explore(ExplorerRequest req) {
    if (widget.onExplore != null) {
      widget.onExplore!(req);
    } else {
      widget.onNew(); // ouvre l'explorateur (demande vide)…
      AnalyticsBus.pendingRequest.value = req; // …puis y dépose la copie
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return EmptyState(icon: Icons.cloud_off_rounded, text: "Impossible de charger les analyses.\n$_error", actions: [('Réessayer', _loadSchema)]);
    }
    final s = _schema;
    if (s == null) return const Center(child: CircularProgressIndicator(color: T.mint));
    return DashboardView(api: widget.api, session: widget.session, schema: s, onOpen: widget.onEdit, onExplore: _explore, onNew: widget.onNew, onOpenModule: widget.onOpenModule);
  }
}

const _kCols = 12;
const _kGap = 12.0;
const _kRowH = 64.0;

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.api, required this.session, required this.schema, required this.onOpen, required this.onExplore, required this.onNew, this.onOpenModule});
  final ApiClient api;
  final Session session;
  final ASchema schema;
  final void Function(SavedReport) onOpen;
  final void Function(ExplorerRequest) onExplore;
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
  Future<void>? _saving;

  /// Révision du bus au dernier chargement : si elle a bougé, on relit avant
  /// toute modification (sinon on écraserait une vue ajoutée par l'explorateur).
  int _rev = -1;
  bool _stale = false; // révision changée pendant un glisser
  bool _selfBump = false;

  /// Vues retirées localement, pas encore enregistrées (la fusion ne doit
  /// pas les faire revenir depuis la version serveur).
  final Set<String> _removed = {};

  // ---- interaction en cours (déplacement ou redimensionnement)
  DashboardTile? _drag;
  Offset _dragDelta = Offset.zero;
  bool _resizing = false;
  (int, int, int, int)? _ghost; // x, y, w, h cible

  @override
  void initState() {
    super.initState();
    AnalyticsBus.revision.addListener(_onRevision);
    AnalyticsBus.currentDashboardId.addListener(_onDashboardRequest);
    _load();
  }

  @override
  void dispose() {
    AnalyticsBus.revision.removeListener(_onRevision);
    AnalyticsBus.currentDashboardId.removeListener(_onDashboardRequest);
    _saveDebounce?.cancel();
    super.dispose();
  }

  void _bumpSelf() {
    _selfBump = true;
    try {
      _rev = AnalyticsBus.bump();
    } finally {
      _selfBump = false;
    }
  }

  void _onRevision() {
    if (_selfBump) {
      _rev = AnalyticsBus.revision.value;
      return;
    }
    if (_rev == AnalyticsBus.revision.value) return;
    if (_drag != null) {
      _stale = true; // rechargé à la fin du geste
      return;
    }
    _flushThenLoad();
  }

  /// Enregistre d'abord une disposition en attente, puis relit le serveur.
  Future<void> _flushThenLoad() async {
    if (_saveDebounce?.isActive == true) {
      _saveDebounce!.cancel();
      await _saveLayout();
    } else if (_saving != null) {
      await _saving;
    }
    if (mounted) await _load();
  }

  void _onDashboardRequest() {
    final id = AnalyticsBus.currentDashboardId.value;
    if (id == null || id == _current?.id) return;
    final d = _dashboards.where((x) => x.id == id).firstOrNull;
    if (d == null) {
      _flushThenLoad(); // nouveau tableau de bord créé ailleurs
      return;
    }
    _switchTo(d);
  }

  void _switchTo(Dashboard d) {
    setState(() {
      _current = d;
      _resolve(d.layout);
      _range = d.globalRange;
      _removed.clear();
    });
    AnalyticsBus.showDashboard(d.id);
    _run();
  }

  Future<void> _load() async {
    final rev = AnalyticsBus.revision.value;
    if (_dashboards.isEmpty) setState(() => _loading = true);
    try {
      final results = await Future.wait([widget.api.dashboards(), widget.api.savedReports()]);
      final ds = results[0] as List<Dashboard>;
      final rs = results[1] as List<SavedReport>;
      if (!mounted) return;
      final wanted = _current?.id ?? AnalyticsBus.lastDashboardId;
      setState(() {
        _dashboards = ds;
        _reports = {for (final r in rs) r.id: r};
        _current = ds.isEmpty ? null : ds.firstWhere((d) => d.id == wanted, orElse: () => ds.first);
        if (_current != null) _resolve(_current!.layout);
        _range = _current?.globalRange ?? const {'type': 'this_month'};
        _loading = false;
        _error = null;
        _rev = rev;
        _stale = false;
        _removed.clear();
      });
      if (_current != null && AnalyticsBus.currentDashboardId.value != _current!.id) AnalyticsBus.showDashboard(_current!.id);
      await _run();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _errText(e);
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
      final out = queries.isEmpty ? <String, Object>{} : await widget.api.analyticsBatch(queries, globalRange: _range, globalWarehouseId: d.globalWarehouseId);
      if (mounted) {
        setState(() {
          _results = out;
          _computedAt = DateTime.now();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), _saveLayout);
  }

  Future<void> _saveLayout() {
    final f = _doSaveLayout();
    _saving = f;
    return f.whenComplete(() {
      if (identical(_saving, f)) _saving = null;
    });
  }

  /// Enregistre la disposition en FUSIONNANT avec la version serveur : les
  /// tuiles ajoutées ailleurs (explorateur) et absentes d'ici sont gardées
  /// et placées en bas, sauf celles que l'on vient de retirer.
  Future<void> _doSaveLayout() async {
    final d = _current;
    if (d == null) return;
    var added = false;
    var needReports = false;
    try {
      final ds = await widget.api.dashboards();
      final server = ds.where((x) => x.id == d.id).firstOrNull;
      if (server != null && mounted) {
        final local = {for (final t in d.layout) t.reportId};
        final extra = [
          for (final t in server.layout)
            if (!local.contains(t.reportId) && !_removed.contains(t.reportId)) t,
        ];
        if (extra.isNotEmpty) {
          var maxY = 0;
          for (final t in d.layout) {
            if (t.y + t.h > maxY) maxY = t.y + t.h;
          }
          setState(() {
            for (final t in extra) {
              t.y = maxY;
              maxY += t.h;
              d.layout.add(t);
            }
            _resolve(d.layout);
          });
          added = true;
          needReports = extra.any((t) => !_reports.containsKey(t.reportId));
        }
      }
      await widget.api.saveDashboard({
        'name': d.name,
        'layout': [for (final t in d.layout) t.toJson()],
        'global_range': _range,
        'global_warehouse_id': d.globalWarehouseId,
        'is_shared': d.isShared,
      }, id: d.id);
      _removed.clear();
      if (!mounted) return;
      if (needReports) {
        await _load();
      } else if (added) {
        await _run();
      }
    } catch (e) {
      if (mounted) showToast(context, "La disposition n'a pas pu être enregistrée : ${_errText(e)}", kind: ToastKind.error);
    }
  }

  // ---- grille : collisions et compactage vers le haut (comportement gridstack)
  static bool _overlap(DashboardTile a, DashboardTile b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

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

  // ---- tableaux de bord
  Future<void> _newDashboard() async {
    final name = await _askName(context, 'Nouveau tableau de bord');
    if (name == null) return;
    try {
      final d = await widget.api.saveDashboard({'name': name, 'layout': [], 'global_range': _range, 'is_shared': true});
      _current = d;
      AnalyticsBus.showDashboard(d.id);
      _bumpSelf();
      await _load();
      if (mounted) showToast(context, 'Tableau de bord « ${d.name} » créé', actionLabel: 'Ajouter une vue', onAction: _addExisting);
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _renameDashboard() async {
    final d = _current;
    if (d == null) return;
    final name = await _askName(context, 'Renommer le tableau de bord', initial: d.name, confirm: 'Renommer');
    if (name == null || name == d.name) return;
    try {
      await widget.api.saveDashboard({
        'name': name,
        'layout': [for (final t in d.layout) t.toJson()],
        'global_range': _range,
        'global_warehouse_id': d.globalWarehouseId,
        'is_shared': d.isShared,
      }, id: d.id);
      _bumpSelf();
      await _load();
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _deleteDashboard() async {
    final d = _current;
    if (d == null) return;
    final ok = await confirmAction(
      context,
      title: 'Supprimer « ${d.name} » ?',
      message: 'Le tableau de bord disparaît pour tout le monde. Les vues restent dans « Mes vues ».',
      confirmLabel: 'Supprimer',
      danger: true,
    );
    if (!ok) return;
    try {
      await widget.api.deleteDashboard(d.id);
      _current = null;
      _bumpSelf();
      await _load();
      if (mounted) showToast(context, 'Tableau de bord supprimé');
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  // ---- tuiles
  Future<void> _addExisting() async {
    final d = _current;
    if (d == null) return;
    final reports = _reports.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final r = await _pickSavedView(context, reports, exclude: {for (final t in d.layout) t.reportId}, onCreate: widget.onNew);
    if (r == null || !mounted) return;
    var maxY = 0;
    for (final t in d.layout) {
      if (t.y + t.h > maxY) maxY = t.y + t.h;
    }
    final small = r.chartType == 'stat';
    setState(() {
      _removed.remove(r.id);
      d.layout.add(DashboardTile(reportId: r.id, x: 0, y: maxY, w: small ? 3 : 6, h: small ? 2 : 4));
      _resolve(d.layout);
    });
    _saveDebounce?.cancel();
    await _saveLayout();
    _bumpSelf();
    await _run();
    if (mounted) showToast(context, '« ${r.name} » ajoutée au tableau de bord');
  }

  Future<void> _removeTile(DashboardTile t) async {
    final d = _current!;
    final r = _reports[t.reportId];
    setState(() {
      d.layout.remove(t);
      _removed.add(t.reportId);
      _resolve(d.layout);
    });
    _saveDebounce?.cancel();
    await _saveLayout();
    _bumpSelf();
    if (!mounted) return;
    showUndoToast(
      context,
      '« ${r?.name ?? 'La vue'} » retirée du tableau de bord (elle reste dans « Mes vues »)',
      undo: () async {
        if (!mounted || _current?.id != d.id) return;
        setState(() {
          _removed.remove(t.reportId);
          d.layout.add(t);
          _resolve(d.layout, fixed: t);
        });
        await _saveLayout();
        _bumpSelf();
        _run();
      },
    );
  }

  Future<void> _deleteReport(DashboardTile t) async {
    final r = _reports[t.reportId];
    final ok = await confirmAction(
      context,
      title: 'Supprimer la vue « ${r?.name ?? ''} » ?',
      message: 'Elle sera supprimée de « Mes vues » et de tous les tableaux de bord. Pour seulement l\'enlever d\'ici, choisissez « Retirer du tableau de bord ».',
      confirmLabel: 'Supprimer la vue',
      danger: true,
    );
    if (!ok) return;
    try {
      _saveDebounce?.cancel();
      await widget.api.deleteReport(t.reportId); // le serveur la retire aussi des dispositions
      if (!mounted) return;
      final d = _current;
      if (d != null) {
        setState(() {
          d.layout.removeWhere((x) => x.reportId == t.reportId);
          _resolve(d.layout);
        });
        await _saveLayout(); // garde les déplacements en attente, sans la vue supprimée
      }
      _bumpSelf();
      await _load();
      if (mounted) showToast(context, 'Vue supprimée');
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  void _exploreTile(SavedReport r) =>
      widget.onExplore(ExplorerRequest(seed: _deepCopy(r.spec), title: r.name, origin: 'Depuis le tableau de bord', chartType: r.chartType, encoding: _deepCopy(r.encoding)));

  // ---- gestes
  void _onDragStart(DashboardTile t, {required bool resize}) {
    if (_rev != AnalyticsBus.revision.value) {
      // une vue a été ajoutée ou supprimée ailleurs : relire avant de modifier
      _flushThenLoad();
      return;
    }
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
    if (_stale) {
      _saveDebounce?.cancel();
      _saveLayout().then((_) {
        if (mounted) _load();
      });
    } else {
      _scheduleSave();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: T.mint));
    if (_error != null && _current == null && _dashboards.isEmpty) {
      return EmptyState(icon: Icons.cloud_off_rounded, text: 'Impossible de charger le tableau de bord.\n$_error', actions: [('Réessayer', _load)]);
    }
    final d = _current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Tableau de bord', style: T.h1),
              const SizedBox(width: 14),
              if (_dashboards.length > 1)
                Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: T.border3),
                    borderRadius: BorderRadius.circular(T.rInner),
                    color: T.surface,
                  ),
                  child: DropdownButton<String>(
                    value: d?.id,
                    underline: const SizedBox(),
                    style: T.body,
                    items: [
                      for (final x in _dashboards)
                        DropdownMenuItem(
                          value: x.id,
                          child: Text(x.name, style: T.h2),
                        ),
                    ],
                    onChanged: (id) {
                      final x = _dashboards.where((x) => x.id == id).firstOrNull;
                      if (x != null && x.id != _current?.id) _switchTo(x);
                    },
                  ),
                )
              else if (d != null)
                Flexible(
                  child: Text(
                    d.name,
                    style: T.h2.copyWith(color: T.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Spacer(),
              if (d != null)
                RangePicker(
                  value: _range,
                  onChanged: (r) {
                    setState(() => _range = r);
                    _scheduleSave();
                    _run();
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (d != null) ...[
                SizedBox(
                  height: 42,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: T.mint,
                      foregroundColor: T.ink,
                      textStyle: const TextStyle(fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    onPressed: widget.onNew,
                    icon: const Icon(Icons.add_chart_rounded, size: 18),
                    label: const Text('Créer une vue'),
                  ),
                ),
                _OutlineAction(icon: Icons.library_add_outlined, label: 'Ajouter une vue existante', onPressed: _addExisting),
                _OutlineAction(icon: Icons.refresh, label: 'Actualiser', onPressed: _running ? null : _run),
              ],
              PopupMenuButton<String>(
                tooltip: 'Autres actions',
                onSelected: (v) => switch (v) {
                  'new' => _newDashboard(),
                  'rename' => _renameDashboard(),
                  _ => _deleteDashboard(),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'new',
                    child: Text('Nouveau tableau de bord', style: T.body),
                  ),
                  if (d != null)
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('Renommer ce tableau de bord', style: T.body),
                    ),
                  if (d != null && !d.isDefault)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Supprimer ce tableau de bord', style: TextStyle(color: T.dangerDark)),
                    ),
                ],
                child: const _OutlineAction(icon: Icons.more_horiz_rounded, label: 'Plus', onPressed: null, asChild: true),
              ),
              if (_computedAt != null) Text('Calculé ${_ago(_computedAt!)}', style: T.small),
            ],
          ),
          if (d != null && d.layout.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Glissez une tuile par son titre pour la déplacer, tirez le coin en bas à droite pour l’agrandir. « Actions » sur chaque tuile pour l’ouvrir, la modifier ou la retirer.',
              style: T.small,
            ),
          ],
          // la liste « Bien démarrer » ne doit jamais écraser la grille sur un petit écran
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42),
            child: SingleChildScrollView(
              child: SetupChecklist(api: widget.api, onOpenModule: widget.onOpenModule),
            ),
          ),
          if (_error != null && d != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(color: T.dangerTint, borderRadius: BorderRadius.circular(T.rInner)),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, size: 18, color: T.dangerDark),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: T.body.copyWith(color: T.dangerDark)),
                  ),
                  TextButton(onPressed: _load, child: const Text('Réessayer')),
                ],
              ),
            ),
          const SizedBox(height: 6),
          if (_running) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.border) else const SizedBox(height: 2),
          const SizedBox(height: 8),
          Expanded(
            child: d == null
                ? EmptyState(
                    icon: Icons.dashboard_customize_outlined,
                    text: "Aucun tableau de bord pour l'instant.\nUn tableau de bord rassemble vos chiffres et graphiques préférés.",
                    actions: [('Créer un tableau de bord', _newDashboard)],
                  )
                : d.layout.isEmpty
                ? EmptyState(
                    icon: Icons.dashboard_customize_outlined,
                    text: 'Ce tableau de bord est vide.\nAjoutez une vue : un chiffre ou un graphique (ventes du mois, meilleurs produits…).',
                    actions: [('Ajouter une vue existante', _addExisting), ('Créer une vue', widget.onNew)],
                  )
                : _grid(d),
          ),
        ],
      ),
    );
  }

  Widget _grid(Dashboard d) {
    return LayoutBuilder(
      builder: (context, c) {
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
            child: Stack(
              children: [
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
                        onEdit: () {
                          final r = _reports[t.reportId];
                          if (r != null) widget.onOpen(r);
                        },
                        onExplore: () {
                          final r = _reports[t.reportId];
                          if (r != null) _exploreTile(r);
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
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bouton secondaire bordé avec icône ET libellé.
class _OutlineAction extends StatelessWidget {
  const _OutlineAction({required this.icon, required this.label, required this.onPressed, this.asChild = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool asChild; // dans un PopupMenuButton : simple apparence, pas de clic propre

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: T.ink),
        const SizedBox(width: 6),
        Text(label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
        if (asChild) const Icon(Icons.arrow_drop_down_rounded, size: 20, color: T.muted),
      ],
    );
    if (asChild) {
      return Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: T.border3),
          borderRadius: BorderRadius.circular(T.rInner),
          color: T.surface,
        ),
        child: content,
      );
    }
    return SizedBox(
      height: 42,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: T.ink,
          side: const BorderSide(color: T.border3),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: onPressed,
        child: content,
      ),
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
    required this.onEdit,
    required this.onExplore,
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
  final VoidCallback onEdit, onExplore, onRemove, onDelete, onMoveStart, onResizeStart, onDragEnd;
  final ValueChanged<Offset> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final r = report;
    Widget body;
    if (r == null) {
      body = EmptyState(icon: Icons.broken_image_outlined, text: 'Cette vue a été supprimée', actions: [('Retirer', onRemove)]);
    } else if (r.missing.isNotEmpty) {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link_off_rounded, size: 22, color: T.warnDark),
          const SizedBox(height: 6),
          Text(
            "Cette vue utilise un champ qui n'existe plus : ${r.missing.join(', ')}",
            style: T.small.copyWith(color: T.warnDark),
            textAlign: TextAlign.center,
          ),
          TextButton(onPressed: onEdit, child: const Text('Corriger')),
        ],
      );
    } else if (result == null) {
      body = const Center(
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: T.mint)),
      );
    } else if (result is ApiException) {
      final e = result as ApiException;
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(e.status == 403 ? Icons.lock_outline_rounded : Icons.error_outline_rounded, size: 22, color: T.faint),
            const SizedBox(height: 6),
            Text(e.status == 403 ? 'Non disponible pour votre rôle' : e.message, style: T.small, textAlign: TextAlign.center),
          ],
        ),
      );
    } else {
      final res = result as AResult;
      final type = r.chartType == 'auto' ? autoChartType(res) : r.chartType;
      final effective = chartTypeBlocker(type, res) == null ? type : 'table';
      body = res.rows.isEmpty
          ? Center(child: Text('Rien sur cette période', style: T.bodyMuted))
          : effective == 'stat'
          ? StatTiles(result: res, compact: true, flat: true, title: r.name)
          : buildChart(effective, res, ChartEncoding.fromJson(r.encoding), compact: true, title: r.name);
    }
    final isStat = r != null && result is AResult && (result as AResult).rows.isNotEmpty && (r.chartType == 'stat' || (r.chartType == 'auto' && autoChartType(result as AResult) == 'stat'));
    final menu = PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      tooltip: 'Actions sur cette tuile',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Actions',
              style: T.small.copyWith(color: T.muted, fontWeight: FontWeight.w600),
            ),
            const Icon(Icons.arrow_drop_down_rounded, size: 18, color: T.muted),
          ],
        ),
      ),
      onSelected: (v) => switch (v) {
        'explore' => onExplore(),
        'edit' => onEdit(),
        'remove' => onRemove(),
        _ => onDelete(),
      },
      itemBuilder: (_) => [
        if (r != null) ...const [
          PopupMenuItem(
            value: 'explore',
            child: Text("Ouvrir dans l'explorateur", style: T.body),
          ),
          PopupMenuItem(
            value: 'edit',
            child: Text('Modifier', style: T.body),
          ),
          PopupMenuDivider(),
        ],
        const PopupMenuItem(
          value: 'remove',
          child: Text('Retirer du tableau de bord', style: T.body),
        ),
        if (r != null)
          const PopupMenuItem(
            value: 'delete',
            child: Text('Supprimer la vue', style: TextStyle(color: T.dangerDark)),
          ),
      ],
    );
    // poignée de déplacement = la zone de titre ; poignée de taille = coin bas droit
    final handle = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onMoveStart(),
      onPanUpdate: (d) => onDragUpdate(d.delta),
      onPanEnd: (_) => onDragEnd(),
      onPanCancel: onDragEnd,
      onDoubleTap: onEdit,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Row(
          children: [
            const Icon(Icons.drag_indicator_rounded, size: 16, color: T.ghost),
            const SizedBox(width: 4),
            Expanded(
              child: Text(r?.name ?? '—', style: T.h2.copyWith(fontSize: 14.5), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
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
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: handle),
                    menu,
                  ],
                ),
                Expanded(child: body),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: handle),
                    if (result is AResult && (result as AResult).truncated)
                      const Tooltip(
                        message: 'Résultat tronqué — ouvrez la vue pour affiner',
                        child: Icon(Icons.warning_amber_rounded, size: 15, color: T.warnDark),
                      ),
                    menu,
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Padding(padding: const EdgeInsets.only(right: 6), child: body),
                ),
              ],
            ),
    );
    return Stack(
      children: [
        Positioned.fill(child: card),
        resizeHandle,
      ],
    );
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
