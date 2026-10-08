part of '../analytics_screen.dart';

// =================================================================== module « Explorateur »

/// Module « Explorateur » : le constructeur de vues. Reçoit les demandes du
/// shell par [request] (vue à modifier, spec de départ avec titre/origine)
/// et, en repli, celles du tableau de bord par [AnalyticsBus.pendingRequest].
/// [onDone] montre le tableau de bord (« Voir sur le tableau de bord »).
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
    AnalyticsBus.pendingRequest.addListener(_onPending);
    if (AnalyticsBus.pendingRequest.value != null) {
      _current = AnalyticsBus.pendingRequest.value;
      AnalyticsBus.pendingRequest.value = null;
    }
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

  void _onRequest() {
    setState(() {
      _current = widget.request.value;
      _epoch++;
    });
  }

  void _onPending() {
    final p = AnalyticsBus.pendingRequest.value;
    if (p == null) return;
    AnalyticsBus.pendingRequest.value = null;
    setState(() {
      _current = p;
      _epoch++;
    });
  }

  /// Ouvre une autre demande depuis l'explorateur lui-même (Mes vues,
  /// Nouvelle vue) sans repasser par le shell.
  void _open(ExplorerRequest? r) {
    widget.request.removeListener(_onRequest);
    widget.request.value = r;
    widget.request.addListener(_onRequest);
    setState(() {
      _current = r;
      _epoch++;
    });
  }

  @override
  void dispose() {
    widget.request.removeListener(_onRequest);
    AnalyticsBus.pendingRequest.removeListener(_onPending);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return EmptyState(icon: Icons.cloud_off_rounded, text: "Impossible de charger l'explorateur.\n$_error", actions: [('Réessayer', _loadSchema)]);
    }
    final s = _schema;
    if (s == null) return const Center(child: CircularProgressIndicator(color: T.mint));
    return ExplorerView(key: ValueKey(_epoch), api: widget.api, session: widget.session, schema: s, request: _current, onOpen: _open, onShowDashboard: widget.onDone);
  }
}

// =================================================================== explorateur

class ExplorerView extends StatefulWidget {
  const ExplorerView({super.key, required this.api, required this.session, required this.schema, this.request, required this.onOpen, required this.onShowDashboard});
  final ApiClient api;
  final Session session;
  final ASchema schema;
  final ExplorerRequest? request;
  final void Function(ExplorerRequest? request) onOpen;
  final VoidCallback onShowDashboard;

  @override
  State<ExplorerView> createState() => _ExplorerViewState();
}

/// Sources mises en avant ; les autres sont sous « Plus ».
const _kPrimarySources = ['sale_lines', 'stock_snapshot', 'purchase_lines', 'partner_ledger'];

/// Mesure et découpage par défaut quand on change de sujet : jamais d'écran vide.
Map<String, dynamic>? _defaultMeasure(ASource s) {
  String? pick(List<String> keys) {
    for (final k in keys) {
      if (s.namedMeasure(k) != null) return k;
    }
    return null;
  }

  final k =
      switch (s.key) {
        'sale_lines' => pick(['ca_ttc']),
        'purchase_lines' => pick(['total_ht', 'qty']),
        'stock_movements' => pick(['net_qty']),
        'stock_snapshot' => pick(['qty']),
        'partner_ledger' => pick(['balance']),
        'product_performance' => pick(['qty_sold']),
        _ => null,
      } ??
      (s.named.isEmpty ? null : s.named.first.key);
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
      return n <= 31
          ? 'day'
          : n <= 90
          ? 'week'
          : 'month';
    case 'last_n_months':
      return n <= 1
          ? 'day'
          : n <= 3
          ? 'week'
          : 'month';
    case 'custom':
      final a = DateTime.tryParse('${range['from']}');
      final b = DateTime.tryParse('${range['to']}');
      if (a == null || b == null) return 'day';
      final d = b.difference(a).inDays;
      return d <= 31
          ? 'day'
          : d <= 90
          ? 'week'
          : 'month';
  }
  return 'day';
}

/// Une étape du chemin de détail (fil d'Ariane) : la vue AVANT le clic.
class _DrillStep {
  _DrillStep(this.label, this.spec, this.chartType);
  final String label;
  final Map<String, dynamic> spec;
  final String? chartType;
}

/// Champs proposés en premier pour « détailler par… ».
const _kDrillFields = ['product_name', 'category_name', 'brand', 'partner_name', 'cashier_name', 'warehouse_name', 'payment_method', 'doc_type'];

/// Périodes proposées quand le résultat est vide.
const _kWiderRanges = <(String, Map<String, dynamic>)>[
  ('3 derniers mois', {'type': 'last_n_months', 'n': 3}),
  ('Cette année', {'type': 'this_year'}),
  ('Tout', {'type': 'all'}),
];

class _ExplorerViewState extends State<ExplorerView> with TickerProviderStateMixin {
  late ASource _source;
  List<String> _dims = [];
  List<Map<String, dynamic>> _measures = [];
  List<Map<String, dynamic>> _filters = [];
  List<Map<String, dynamic>> _having = [];
  Map<String, dynamic> _range = {'type': 'this_month'};
  String? _compare; // null | previous_period | previous_year
  Map<String, int> _params = {};
  int _limit = 500;
  Map<String, dynamic> _extra = {}; // clés de spec non éditées ici (sort, date_field, zero_fill)
  Map<String, dynamic>? _comboSpec; // vue croisée (venue de l'IA ou d'une vue enregistrée) : non éditable ici

  SavedReport? _report; // vue enregistrée en cours de modification
  String? _title; // titre venu de la demande (autre module)
  String? _origin;

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
  bool _showLibrary = false;
  bool _multiView = false; // après une réponse de l'IA : toutes les vues possibles, deux par ligne
  List<GalleryItem> _gallery = const [];
  List<_DrillStep> _drillPath = [];

  // ---- Mes vues
  List<SavedReport>? _views;
  List<Dashboard> _boards = const [];
  bool _libLoading = false;
  String? _libError;

  // ---- assistant
  final _askCtrl = TextEditingController();
  final _askFocus = FocusNode();
  bool _asking = false;
  int _askPhase = 0;
  Timer? _phaseTimer;
  AskAnswer? _answer;
  bool _answerHidden = false;
  bool _demo = false;
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  late final AnimationController _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));

  static const _phases = ['Je lis votre question…', 'Je choisis la source et les mesures…', 'Je construis la vue…', 'Je calcule sur vos données…'];

  @override
  void initState() {
    super.initState();
    _source = widget.schema.sources.first;
    final req = widget.request;
    _report = req?.report;
    _title = req?.title;
    _origin = req?.origin;
    final seed = req?.seed ?? req?.report?.spec;
    if (seed != null && seed.isNotEmpty) {
      _applySpec(_deepCopy(seed), silent: true);
    } else {
      _applyDefaults(_source);
    }
    final ct = req?.report?.chartType ?? req?.chartType;
    if (ct != null && ct != 'auto' && kChartTypes.contains(ct)) _chartType = ct;
    final enc = req?.report?.encoding ?? req?.encoding;
    if (enc != null) _encoding = ChartEncoding.fromJson(enc);
    widget.api
        .analyticsGallery()
        .then((g) {
          if (mounted) setState(() => _gallery = g);
        })
        .catchError((_) {});
    AnalyticsBus.revision.addListener(_onRevision);
    _reveal.value = 1;
    _schedule(immediate: true);
  }

  @override
  void dispose() {
    AnalyticsBus.revision.removeListener(_onRevision);
    _debounce?.cancel();
    _phaseTimer?.cancel();
    _glow.dispose();
    _reveal.dispose();
    _askCtrl.dispose();
    _askFocus.dispose();
    super.dispose();
  }

  void _onRevision() {
    if (_showLibrary || _views != null) _loadLibrary();
  }

  void _applyDefaults(ASource s) {
    final m = _defaultMeasure(s);
    _measures = m == null ? [] : [m];
    _dims = _defaultDims(s);
    _range = _defaultRange(s);
    _filters = [];
    _having = [];
    _params = {};
    _compare = null;
    _extra = {};
    _comboSpec = null;
    _limit = s.key == 'product_performance' ? 20 : 500;
  }

  /// Charge une spec (galerie, vue enregistrée, IA, autre module) dans le constructeur.
  void _applySpec(Map<String, dynamic> spec, {bool silent = false}) {
    _extra = {
      for (final k in const ['sort', 'date_field', 'zero_fill'])
        if (spec[k] != null) k: spec[k],
    };
    if (spec['combo'] == true) {
      _comboSpec = Map<String, dynamic>.from(spec);
      _range = Map<String, dynamic>.from((spec['range'] as Map?) ?? const {'type': 'this_month'});
      _measures = [];
      _dims = [];
      _filters = [];
      _having = [];
      _compare = null;
    } else {
      final src = widget.schema.source('${spec['source']}');
      if (src == null) {
        _applyDefaults(_source);
        _error = "Cette vue utilise un sujet qui n'existe plus (${spec['source']}).";
        return;
      }
      _source = src;
      _comboSpec = null;
      _dims = [for (final d in (spec['dimensions'] as List? ?? const [])) '$d'];
      _measures = [for (final m in (spec['measures'] as List? ?? const [])) Map<String, dynamic>.from(m as Map)];
      _filters = [for (final f in (spec['filters'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)];
      _having = [for (final h in (spec['having'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)];
      _range = Map<String, dynamic>.from((spec['range'] as Map?) ?? _defaultRange(src));
      final c = spec['compare'];
      _compare = c is String && c.isNotEmpty ? c : null;
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
          if (_compare != null) 'compare': _compare,
          if (_params.isNotEmpty) 'params': _params,
          'limit': _limit,
          ..._extra,
        };

  bool get _hasQuery => _comboSpec != null || _measures.isNotEmpty;

  void _schedule({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 300), _run);
  }

  Future<void> _run() async {
    if (!_hasQuery) {
      if (mounted) {
        setState(() {
          _result = null;
          _error = null;
        });
      }
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

  /// Modification faite dans le constructeur : l'explication de l'IA ne
  /// correspond plus, et un tri hérité pourrait viser une colonne disparue.
  void _edit(VoidCallback f) {
    _set(() {
      f();
      _extra.remove('sort');
      _answer = null;
    });
  }

  /// Change la période ; le seau de la dimension date suit (jour/semaine/mois).
  void _setRange(Map<String, dynamic> r) {
    _set(() {
      _range = Map<String, dynamic>.from(r);
      for (var i = 0; i < _dims.length; i++) {
        final parts = _dims[i].split(':');
        if (parts.length == 2 && parts[0] == _source.dateField && parts[1] != 'dow' && parts[1] != 'hour') {
          _dims[i] = '${parts[0]}:${_autoBucket(_range)}';
        }
      }
    });
  }

  void _changeSource(ASource s) {
    _set(() {
      _source = s;
      _applyDefaults(s);
      _result = null;
      _chartType = null;
      _encoding = ChartEncoding();
      _answer = null;
      _drillPath = [];
      _showGallery = false;
      _showLibrary = false;
    });
  }

  void _applyGallery(GalleryItem g) {
    _gen++;
    setState(() {
      _applySpec(_deepCopy(g.spec), silent: true);
      _chartType = g.chartType == 'auto' ? null : g.chartType;
      _encoding = ChartEncoding();
      _answer = null;
      _showGallery = false;
      _showLibrary = false;
      _multiView = false;
      _drillPath = [];
      _title ??= g.title;
    });
    _schedule(immediate: true);
  }

  String get _effectiveChart {
    final r = _result;
    if (r == null) return 'table';
    final t = _chartType ?? autoChartType(r);
    return chartTypeBlocker(t, r) == null ? t : 'table';
  }

  // ---- libellés ------------------------------------------------------------------

  String _fieldWord(String key) => (_source.field(key)?.labelFr ?? key).replaceAll(' (nom)', '');

  String _measureWord(Map<String, dynamic> m) {
    if (m['name'] != null) return _source.namedMeasure('${m['name']}')?.labelFr ?? '${m['name']}';
    final f = _source.field('${m['field']}');
    return '${kAggLabels[m['agg'] ?? 'sum'] ?? m['agg']} · ${f?.labelFr ?? m['field']}';
  }

  /// Nom proposé : celui de la vue, celui de la demande, celui de l'IA, ou
  /// « Chiffre d'affaires TTC par jour ».
  String get _viewName {
    final n = _report?.name ?? _title ?? (_answer?.title.isNotEmpty == true ? _answer!.title : null);
    if (n != null && n.isNotEmpty) return n;
    if (_comboSpec != null || _measures.isEmpty) return 'Nouvelle vue';
    final m = _measureWord(_measures.first);
    if (_dims.isEmpty) return m;
    final p = _dims.first.split(':');
    final by = p.length > 1 ? (kBucketLabels[p[1]] ?? p[1]).toLowerCase() : _fieldWord(p[0]).toLowerCase();
    return '$m par $by';
  }

  // ---- détail (clic sur une ligne, une barre, une part) ----------------------------

  Future<void> _drill(AColumn col, dynamic value) async {
    if (_comboSpec != null || value == null) return;
    final f = _source.field(col.field);
    if (f == null || !f.filterable) return;
    final valueLabel = _result?.labelOf(col, value) ?? '$value';
    Map<String, dynamic>? filter;
    String? finer;
    final b = col.bucket;
    if (b.isEmpty || b == 'day') {
      filter = {'field': f.key, 'op': 'eq', 'value': value};
    } else if (f.ops.contains('between')) {
      final span = _bucketSpan(b, '$value');
      if (span != null) {
        filter = {
          'field': f.key,
          'op': 'between',
          'value': [span.$1, span.$2],
        };
        finer = switch (b) {
          'quarter' || 'year' => 'month',
          _ => 'day',
        };
      }
    }
    if (filter == null) {
      showToast(context, 'Impossible de détailler « $valueLabel » : choisissez un autre regroupement.', kind: ToastKind.info);
      return;
    }
    final colDim = b.isEmpty ? col.field : '${col.field}:$b';
    final opts = <(String, String?)>[
      if (finer != null) ('Par ${(kBucketLabels[finer] ?? finer).toLowerCase()}', '${f.key}:$finer'),
      for (final k in _kDrillFields)
        if (k != col.field && _source.field(k)?.dimension == true && !_dims.any((d) => d.split(':')[0] == k)) ('Par ${_fieldWord(k).toLowerCase()}', k),
      if (_source.dateField.isNotEmpty && col.field != _source.dateField && !_dims.any((d) => d.split(':')[0] == _source.dateField)) ('Par jour', '${_source.dateField}:day'),
    ];
    final choices = [...opts.take(7), ('Sans regroupement (seulement filtrer)', null)];
    final picked = await showDialog<(String, String?)>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Détailler « $valueLabel »', style: T.h2),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Voir le détail par :', style: T.bodyMuted),
          ),
          for (var i = 0; i < choices.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, choices[i]),
              child: Text(
                choices[i].$1,
                style: T.body.copyWith(fontWeight: i == 0 ? FontWeight.w700 : null, color: choices[i].$2 == null ? T.muted : T.ink),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final step = _DrillStep('${_fieldWord(f.key)} : $valueLabel', _deepCopy(_spec), _chartType);
    _set(() {
      _drillPath = [..._drillPath, step];
      _filters.add(filter!);
      final i = _dims.indexOf(colDim);
      final next = picked.$2;
      if (i >= 0) {
        if (next == null) {
          _dims.removeAt(i);
        } else {
          _dims[i] = next;
        }
      } else if (next != null) {
        _dims.insert(0, next);
      }
      _extra.remove('sort');
      _chartType = null;
      _multiView = false;
    });
  }

  /// Bornes (AAAA-MM-JJ) d'une valeur de seau : mois « 2026-09 », semaine
  /// « 2026-09-07 » (premier jour), trimestre « 2026-Q3 », année « 2026 ».
  (String, String)? _bucketSpan(String bucket, String v) {
    switch (bucket) {
      case 'month':
        final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(v);
        if (m == null) return null;
        final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!);
        return (_iso(DateTime(y, mo, 1)), _iso(DateTime(y, mo + 1, 0)));
      case 'week':
        final d = DateTime.tryParse(v);
        if (d == null) return null;
        return (_iso(d), _iso(d.add(const Duration(days: 6))));
      case 'quarter':
        final m = RegExp(r'^(\d{4})-Q([1-4])$').firstMatch(v);
        if (m == null) return null;
        final y = int.parse(m.group(1)!), q = int.parse(m.group(2)!);
        return (_iso(DateTime(y, (q - 1) * 3 + 1, 1)), _iso(DateTime(y, q * 3 + 1, 0)));
      case 'year':
        final y = int.tryParse(v);
        if (y == null) return null;
        return ('$y-01-01', '$y-12-31');
    }
    return null;
  }

  void _drillBack(int index) {
    final step = _drillPath[index];
    _gen++;
    setState(() {
      _drillPath = _drillPath.sublist(0, index);
      _applySpec(_deepCopy(step.spec), silent: true);
      _chartType = step.chartType;
      _multiView = false;
    });
    _schedule(immediate: true);
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
      _answerHidden = false;
      _showGallery = false;
      _showLibrary = false;
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
          _applySpec(_deepCopy(a.spec!), silent: true);
          _chartType = a.chartType == 'auto' || a.chartType.isEmpty ? null : a.chartType;
          _encoding = ChartEncoding();
          _error = a.result == null ? a.error : null;
          _errorStatus = null;
          _result = a.result;
          _multiView = a.result != null && !_isEmpty(a.result!);
          _showStyle = false;
          _drillPath = [];
        });
        _reveal.forward(from: 0);
        if (a.result == null) _schedule(immediate: true);
      } else if (a.clarification != null) {
        _askFocus.requestFocus();
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

  bool _canEdit(SavedReport? r) {
    if (r == null) return false;
    final u = widget.session.user;
    return u.isAdmin || (u.role == 'manager' && (r.isShared || r.isDefault)) || r.ownerId == u.id;
  }

  bool get _canEditReport => _canEdit(_report);

  Future<void> _deleteView(SavedReport r) async {
    final ok = await confirmAction(
      context,
      title: 'Supprimer la vue « ${r.name} » ?',
      message: 'Elle sera supprimée de « Mes vues » et de tous les tableaux de bord.',
      confirmLabel: 'Supprimer la vue',
      danger: true,
    );
    if (!ok) return;
    try {
      await widget.api.deleteReport(r.id);
      AnalyticsBus.bump();
      if (!mounted) return;
      showToast(context, 'Vue « ${r.name} » supprimée');
      if (r.id == _report?.id) {
        widget.onOpen(null);
      } else {
        _loadLibrary();
      }
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _renameView(SavedReport r) async {
    final name = await _askName(context, 'Renommer la vue', initial: r.name, confirm: 'Renommer');
    if (name == null || name == r.name) return;
    try {
      final saved = await widget.api.saveReport({'name': name, 'spec': r.spec, 'chart_type': r.chartType, 'encoding': r.encoding, 'is_shared': r.isShared}, id: r.id);
      AnalyticsBus.bump();
      if (!mounted) return;
      if (saved.id == _report?.id) setState(() => _report = saved);
      showToast(context, 'Vue renommée « ${saved.name} »');
      _loadLibrary();
    } catch (e) {
      if (mounted) showToast(context, _errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _addViewTo(SavedReport r, Dashboard d) async {
    try {
      final out = await _addTileToDashboard(widget.api, d.id, r.id, small: r.chartType == 'stat');
      if (!mounted) return;
      if (out == null) {
        showToast(context, "Ce tableau de bord n'existe plus", kind: ToastKind.warning);
        return;
      }
      showToast(
        context,
        '« ${r.name} » ajoutée à « ${d.name} »',
        actionLabel: 'Voir sur le tableau de bord',
        onAction: () {
          AnalyticsBus.showDashboard(d.id);
          widget.onShowDashboard();
        },
      );
      _loadLibrary();
    } catch (e) {
      if (mounted) showToast(context, "Impossible d'ajouter la vue : ${_errText(e)}", kind: ToastKind.error);
    }
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _libLoading = true;
      _libError = null;
    });
    try {
      final res = await Future.wait([widget.api.savedReports(), widget.api.dashboards()]);
      if (!mounted) return;
      setState(() {
        _views = (res[0] as List<SavedReport>)..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _boards = res[1] as List<Dashboard>;
        _libLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _libError = _errText(e);
          _libLoading = false;
        });
      }
    }
  }

  void _toggleLibrary() {
    setState(() {
      _showLibrary = !_showLibrary;
      if (_showLibrary) _showGallery = false;
    });
    if (_showLibrary) _loadLibrary();
  }

  Future<void> _save() async {
    List<Dashboard> boards = const [];
    try {
      boards = await widget.api.dashboards();
    } catch (_) {}
    if (!mounted) return;
    final editing = _canEditReport;
    // tableaux de bord qui montrent déjà la vue modifiée (une copie n'y est pas)
    final onBoards = <String>{
      if (editing)
        for (final d in boards)
          if (d.layout.any((t) => t.reportId == _report!.id)) d.id,
    };
    final last = AnalyticsBus.lastDashboardId;
    final String? target = editing && onBoards.isNotEmpty
        ? null
        : boards.any((d) => d.id == last)
        ? last
        : (boards.isEmpty ? null : boards.first.id);
    final res = await showDialog<_SaveChoice>(
      context: context,
      builder: (_) => _SaveDialog(initialName: _viewName, initialShared: _report?.isShared ?? true, editing: editing, boards: boards, onBoards: onBoards, initialTarget: target),
    );
    if (res == null || !mounted) return;
    final SavedReport saved;
    try {
      saved = await widget.api.saveReport({
        'name': res.name,
        'spec': _spec,
        'chart_type': _chartType ?? 'auto',
        'encoding': _encoding.toJson(),
        'is_shared': res.shared,
      }, id: editing && !res.asCopy ? _report!.id : null);
    } catch (e) {
      if (mounted) showToast(context, "La vue n'a pas pu être enregistrée : ${_errText(e)}", kind: ToastKind.error);
      return;
    }
    AnalyticsBus.bump();
    Dashboard? addedTo;
    String? addError;
    if (res.target != null && (res.asCopy || !onBoards.contains(res.target))) {
      try {
        addedTo = await _addTileToDashboard(widget.api, res.target!, saved.id, small: (_chartType ?? (_result == null ? 'auto' : autoChartType(_result!))) == 'stat');
      } catch (e) {
        addError = _errText(e);
      }
    }
    if (!mounted) return;
    setState(() {
      _report = saved;
      _title = null;
    });
    if (_showLibrary) _loadLibrary();
    void show(String id) {
      AnalyticsBus.showDashboard(id);
      widget.onShowDashboard();
    }

    if (addError != null) {
      showToast(context, "« ${saved.name} » est enregistrée dans « Mes vues », mais n'a pas pu être ajoutée au tableau de bord : $addError", kind: ToastKind.warning);
    } else if (addedTo != null) {
      final id = addedTo.id;
      showToast(context, '« ${saved.name} » enregistrée et ajoutée à « ${addedTo.name} »', actionLabel: 'Voir sur le tableau de bord', onAction: () => show(id));
    } else if (onBoards.isNotEmpty && !res.asCopy) {
      final id = onBoards.contains(last) ? last! : onBoards.first;
      showToast(context, '« ${saved.name} » enregistrée', actionLabel: 'Voir sur le tableau de bord', onAction: () => show(id));
    } else {
      showToast(
        context,
        '« ${saved.name} » enregistrée dans « Mes vues »',
        actionLabel: 'Mes vues',
        onAction: () {
          if (mounted && !_showLibrary) _toggleLibrary();
        },
      );
    }
  }

  Future<String> _export(ExportFormat f) {
    final r = _result!;
    return exportResult(r, r.rows, _viewName, f);
  }

  // ---- rendu -------------------------------------------------------------------

  /// Un résultat « vide » : aucune ligne, ou un chiffre seul tout à zéro.
  bool _isEmpty(AResult r) {
    if (r.rows.isEmpty) return true;
    if (r.dimensions.isNotEmpty) return false;
    for (final row in r.rows) {
      for (final m in r.measures) {
        final v = row[r.colIndex(m.key)];
        if (v != null && v != 0) return false;
      }
    }
    return true;
  }

  String _periodWords(AResult r) => r.rangeAll ? 'toute la période' : 'du ${frDate(r.rangeFrom)} au ${frDate(r.rangeTo)}';

  @override
  Widget build(BuildContext context) {
    final editingName = _report?.name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Explorateur', style: T.h1),
              const SizedBox(width: 14),
              Flexible(
                child: editingName != null ? MintChip('Vue enregistrée · $editingName', color: T.mintTint2, fg: T.mintDark) : MintChip(_title ?? 'Nouvelle vue', color: T.border, fg: T.ink),
              ),
              if (_origin != null) ...[const SizedBox(width: 8), MintChip(_origin!, color: T.warnTint, fg: T.warnDark)],
              const Spacer(),
              _OutlineAction(icon: _showLibrary ? Icons.close_rounded : Icons.bookmarks_outlined, label: _showLibrary ? 'Fermer Mes vues' : 'Mes vues', onPressed: _toggleLibrary),
              const SizedBox(width: 8),
              _OutlineAction(icon: Icons.add_chart_rounded, label: 'Nouvelle vue', onPressed: () => widget.onOpen(null)),
              if (_report != null && _canEditReport) ...[
                const SizedBox(width: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                  onPressed: () => _deleteView(_report!),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Supprimer la vue'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
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
            onGallery: () => setState(() {
              _showGallery = !_showGallery;
              if (_showGallery) _showLibrary = false;
            }),
            galleryOpen: _showGallery,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final styleOpen = _showStyle && _result != null && !_showGallery && !_showLibrary && _effectiveChart != 'stat';
                // petit écran : le panneau de style replie le constructeur pour laisser la place au résultat
                final collapsed = _askCollapsed || (styleOpen && box.maxWidth < 1180);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: collapsed ? 48 : 330,
                      child: collapsed
                          ? Card14(
                              padding: EdgeInsets.zero,
                              child: Column(
                                children: [
                                  IconButton(
                                    tooltip: 'Afficher le constructeur',
                                    onPressed: () => setState(() {
                                      _askCollapsed = false;
                                      if (box.maxWidth < 1180) _showStyle = false;
                                    }),
                                    icon: const Icon(Icons.chevron_right, color: T.muted),
                                  ),
                                ],
                              ),
                            )
                          : ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: 330,
                                maxWidth: 330,
                                child: _AskPanel(
                                  schema: widget.schema,
                                  source: _source,
                                  dims: _dims,
                                  measures: _measures,
                                  filters: _filters,
                                  having: _having,
                                  range: _range,
                                  compare: _compare,
                                  params: _params,
                                  limit: _limit,
                                  combo: _comboSpec != null,
                                  suggestions: [
                                    for (final g in _gallery)
                                      if (g.spec['source'] == _source.key) g,
                                  ],
                                  onSuggestion: _applyGallery,
                                  onSource: _changeSource,
                                  onCompare: (v) => _edit(() => _compare = v),
                                  onRange: _setRange,
                                  onLimit: (n) => _edit(() => _limit = n),
                                  onChanged: _edit,
                                  onCollapse: () => setState(() => _askCollapsed = true),
                                  autoBucket: () => _autoBucket(_range),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _showLibrary
                          ? _libraryPanel()
                          : _showGallery || !_hasQuery
                          ? _galleryPanel()
                          : _answerPanel(),
                    ),
                    if (styleOpen) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 310,
                        child: _StylePanel(
                          result: _result!,
                          chartType: _effectiveChart,
                          encoding: _encoding.resolved(_result!),
                          onChanged: (e) => setState(() => _encoding = e),
                          onClose: () => setState(() => _showStyle = false),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryPanel() {
    return _MyViewsPanel(
      views: _views,
      boards: _boards,
      loading: _libLoading,
      error: _libError,
      currentId: _report?.id,
      canEdit: _canEdit,
      onRetry: _loadLibrary,
      onOpen: (r) => widget.onOpen(ExplorerRequest(report: r)),
      onRename: _renameView,
      onDelete: _deleteView,
      onAddTo: _addViewTo,
      onShowDashboard: (d) {
        AnalyticsBus.showDashboard(d.id);
        widget.onShowDashboard();
      },
      onCreate: () => setState(() => _showLibrary = false),
    );
  }

  /// Toutes les représentations possibles du résultat, deux par ligne. Un
  /// clic sur l'une d'elles la met en pleine vue ; le bouton de la barre
  /// d'outils ramène à la vue par défaut.
  Widget _allChartsGrid(AResult r, String suggested) {
    final types = [
      for (final t in kChartTypes)
        if (chartTypeBlocker(t, r) == null) t,
    ];
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 12.0;
        final w = (c.maxWidth - gap) / 2;
        final h = math.max(230.0, math.min(330.0, (c.maxHeight - gap) / 2));
        return SingleChildScrollView(
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
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
                    }),
                    child: buildChart(t, r, _encoding, compact: true),
                  ),
                ),
            ],
          ),
        );
      },
    );
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
          : ListView(
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Que voulez-vous savoir ?', style: T.h2)),
                    if (_hasQuery) TextButton(onPressed: () => setState(() => _showGallery = false), child: const Text('Retour à ma vue')),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Une question, un clic. Vous pourrez ensuite ajuster chaque détail à gauche, ou poser votre propre question en haut.', style: T.bodyMuted),
                const SizedBox(height: 14),
                for (final e in themes.entries) ...[
                  MicroLabel(e.key, color: T.mintDark),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in e.value)
                        ActionChip(
                          avatar: Icon(kChartIcons[g.chartType] ?? Icons.table_rows_rounded, size: 16, color: T.mintDark),
                          label: Text(g.title, style: T.body.copyWith(fontSize: 13.5)),
                          backgroundColor: T.bg,
                          side: const BorderSide(color: T.border),
                          onPressed: () => _applyGallery(g),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
    );
  }

  /// Bandeau de la réponse de l'IA : ce qu'elle a compris, la période en mots.
  Widget? _answerBanner(AResult? r) {
    final a = _answer;
    if (a == null || a.spec == null || _answerHidden) return null;
    final local = a.provider != 'cloud';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: local ? T.bg : T.mintTint,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: local ? T.border3 : T.mintDeep.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(local ? Icons.lightbulb_outline_rounded : Icons.auto_awesome_rounded, size: 20, color: T.mintDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  local ? 'Réponse trouvée dans les questions prêtes' : 'Elixir AI a compris votre question',
                  style: T.label.copyWith(color: T.mintDark, fontWeight: FontWeight.w700),
                ),
                if (a.title.isNotEmpty) ...[const SizedBox(height: 2), Text(a.title, style: T.h2.copyWith(fontSize: 15.5))],
                if (a.explanation.isNotEmpty) ...[const SizedBox(height: 2), Text(a.explanation, style: T.body)],
                const SizedBox(height: 4),
                Text('Période : ${rangeLabel(_range)}${r == null ? '' : ' (${_periodWords(r)})'}', style: T.bodyMuted),
                if (local) ...[
                  const SizedBox(height: 4),
                  Text("Elixir AI n'a pas répondu : j'ai pris la question prête la plus proche de la vôtre. Vérifiez qu'elle correspond, ou choisissez-en une autre.", style: T.small),
                ],
              ],
            ),
          ),
          if (local)
            TextButton(
              onPressed: () => setState(() {
                _showGallery = true;
                _showLibrary = false;
              }),
              child: const Text('Voir les questions prêtes'),
            ),
          IconButton(
            tooltip: 'Masquer cette explication',
            onPressed: () => setState(() => _answerHidden = true),
            icon: const Icon(Icons.close, size: 16, color: T.muted),
          ),
        ],
      ),
    );
  }

  /// Résultat vide : on explique la période et on propose plus large.
  Widget _emptyResult() {
    final hasPeriod = _comboSpec != null || _source.dateField.isNotEmpty || _source.key == 'product_performance';
    final noun = _comboSpec != null ? 'Aucune donnée' : emptyNoun(_source.key);
    final cur = (_range['type'] as String?) ?? 'this_month';
    final wider = [
      for (final w in _kWiderRanges)
        if (w.$2['type'] != cur || (cur == 'last_n_months' && w.$2['n'] != _range['n']))
          (
            w.$1,
            () {
              setState(() => _answerHidden = false);
              _setRange(w.$2);
            },
          ),
    ];
    final text = hasPeriod
        ? '$noun ${rangePhrase(_range)}.\nLa question est bien comprise : il n\'y a simplement rien sur cette période.${wider.isEmpty ? '' : '\nEssayez une période plus large :'}'
        : '$noun ne correspond à ces critères.';
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: EmptyState(icon: Icons.event_busy_outlined, text: text, actions: [if (_filters.isNotEmpty) ('Retirer les filtres', () => _edit(() => _filters.clear())), if (hasPeriod) ...wider]),
      ),
    );
  }

  Widget _chartPicker(AResult r, String type) {
    Widget chip(String label, IconData icon, bool selected, String? blocker, VoidCallback onTap) {
      final disabled = blocker != null;
      return Tooltip(
        message: blocker ?? label,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(T.rChip),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? T.ink : (disabled ? Colors.transparent : T.surface),
              borderRadius: BorderRadius.circular(T.rChip),
              border: Border.all(color: selected ? T.ink : T.border3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: selected ? Colors.white : (disabled ? T.ghost : T.mintDark)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: T.body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, color: selected ? Colors.white : (disabled ? T.ghost : T.ink)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Affichage :', style: T.label.copyWith(color: T.muted)),
        chip(
          'Automatique',
          Icons.auto_fix_high_rounded,
          _chartType == null && !_multiView,
          null,
          () => setState(() {
            _chartType = null;
            _multiView = false;
          }),
        ),
        for (final t in kChartTypes)
          chip(
            kChartLabels[t]!,
            kChartIcons[t]!,
            _chartType == t && !_multiView,
            chartTypeBlocker(t, r),
            () => setState(() {
              _chartType = t;
              _multiView = false;
            }),
          ),
        chip(
          _multiView ? 'Revenir à une seule vue' : 'Comparer les affichages',
          _multiView ? Icons.fullscreen_rounded : Icons.grid_view_rounded,
          _multiView,
          null,
          () => setState(() {
            _multiView = !_multiView;
            if (_multiView) _showStyle = false;
          }),
        ),
      ],
    );
  }

  Widget _answerPanel() {
    final r = _result;
    final type = _effectiveChart;
    final banner = _answerBanner(r);
    final empty = r != null && _isEmpty(r);
    return Card14(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: LayoutBuilder(
        builder: (context, box) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // en-tête, affichages et messages : jamais plus de la moitié de la hauteur
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.5),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_viewName, style: T.h2, maxLines: 1, overflow: TextOverflow.ellipsis),
                              if (r != null)
                                Text(
                                  'Période : ${_periodWords(r)}${r.prevFrom != null ? ' — comparée au ${frDate(r.prevFrom!)} → ${frDate(r.prevTo ?? '')}' : ''}',
                                  style: T.bodyMuted,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (r != null && !empty && type != 'stat')
                                _OutlineAction(icon: Icons.palette_outlined, label: _showStyle ? 'Fermer le style' : 'Couleurs et style', onPressed: () => setState(() => _showStyle = !_showStyle)),
                              if (r != null && !empty) ExportMenuButton(onExport: _export),
                              if (_hasQuery) PrimaryButton(label: _canEditReport ? 'Enregistrer les modifications' : 'Enregistrer la vue', onPressed: _save),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (r != null && !empty) _chartPicker(r, type),
                    if (_running || _asking)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.border),
                      )
                    else
                      const SizedBox(height: 10),
                    const SizedBox(height: 8),
                    ?banner,
                    if (_comboSpec != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(T.rInner)),
                        child: Text('Vue croisée (deux sujets) : la période se règle à gauche, le reste est fixé par la question.', style: T.body.copyWith(color: T.mintDark)),
                      ),
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(color: T.dangerTint, borderRadius: BorderRadius.circular(T.rInner)),
                        child: Row(
                          children: [
                            Icon(_errorStatus == 403 ? Icons.lock_outline_rounded : Icons.error_outline_rounded, size: 18, color: T.dangerDark),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_errorStatus == 403 ? 'Non disponible pour votre rôle : $_error' : _error!, style: T.body.copyWith(color: T.dangerDark)),
                            ),
                            if (_errorStatus == 504) TextButton(onPressed: () => _setRange({'type': 'last_n_days', 'n': 30}), child: const Text('Réduire la période')),
                            TextButton(onPressed: () => _schedule(immediate: true), child: const Text('Réessayer')),
                          ],
                        ),
                      ),
                    if (r != null && r.truncated)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(color: T.warnTint, borderRadius: BorderRadius.circular(T.rInner)),
                        child: Text('Seules les ${r.rows.length} premières lignes sur ${r.totalRows} sont affichées — ajoutez un filtre pour affiner.', style: T.body.copyWith(color: T.warnDark)),
                      ),
                    if (r != null && r.dropped.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('Non disponible pour votre rôle : ${r.dropped.join(', ')}', style: T.body.copyWith(color: T.warnDark)),
                      ),
                    if (_drillPath.isNotEmpty) _breadcrumb(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: r == null
                  ? (_error == null ? const Center(child: CircularProgressIndicator(color: T.mint)) : const SizedBox())
                  : empty
                  ? _emptyResult()
                  : FadeTransition(
                      opacity: CurvedAnimation(parent: _reveal, curve: Curves.easeOut),
                      child: SlideTransition(
                        position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: _reveal, curve: Curves.easeOutCubic)),
                        child: Opacity(
                          opacity: _running ? 0.55 : 1,
                          child: _multiView ? _allChartsGrid(r, type) : buildChart(type, r, _encoding, onDrill: _comboSpec == null ? _drill : null, title: _viewName),
                        ),
                      ),
                    ),
            ),
            if (r != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${r.totalRows} ligne${r.totalRows > 1 ? 's' : ''} · calculé en ${r.durationMs} ms${r.cached ? ' (déjà en mémoire)' : ''}',
                        style: T.small,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (r.dimensions.isNotEmpty && _comboSpec == null && !empty)
                      Flexible(
                        child: Text('Astuce : cliquez une valeur pour voir son détail', style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumb() {
    Widget crumb(String label, VoidCallback? onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rChip),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: T.body.copyWith(
            fontSize: 13.5,
            color: onTap == null ? T.ink : T.mintDark,
            fontWeight: onTap == null ? FontWeight.w700 : FontWeight.w600,
            decoration: onTap == null ? null : TextDecoration.underline,
          ),
        ),
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined, size: 16, color: T.muted),
          const SizedBox(width: 6),
          Text('Détail :', style: T.label.copyWith(color: T.muted)),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                crumb('Vue de départ', () => _drillBack(0)),
                for (var i = 0; i < _drillPath.length; i++) ...[
                  const Icon(Icons.chevron_right_rounded, size: 18, color: T.faint),
                  crumb(_drillPath[i].label, i == _drillPath.length - 1 ? null : () => _drillBack(i + 1)),
                ],
              ],
            ),
          ),
          TextButton.icon(onPressed: () => _drillBack(_drillPath.length - 1), icon: const Icon(Icons.arrow_back_rounded, size: 16), label: const Text('Revenir')),
        ],
      ),
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
              if (_hover || widget.suggested)
                BoxShadow(
                  color: T.mint.withValues(alpha: _hover ? 0.28 : 0.14),
                  blurRadius: _hover ? 18 : 10,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(kChartIcons[widget.type], size: 16, color: T.mintDark),
                  const SizedBox(width: 6),
                  Text(kChartLabels[widget.type] ?? widget.type, style: T.h2.copyWith(fontSize: 14.5)),
                  const Spacer(),
                  if (widget.suggested) const MintChip('Suggéré', color: T.mintTint2, fg: T.mintDark),
                  if (!widget.suggested) Text('Choisir cet affichage', style: T.small.copyWith(color: _hover ? T.mintDark : T.muted)),
                ],
              ),
              const SizedBox(height: 6),
              // les aperçus sont en lecture seule : le clic sélectionne la vue
              Expanded(child: AbsorbPointer(child: widget.child)),
            ],
          ),
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
    // la réponse réussie s'affiche au-dessus du résultat ; ici seulement les
    // demandes de précision et les échecs
    final note = a == null || asking
        ? null
        : a.clarification != null
        ? (Icons.help_outline_rounded, a.clarification!, T.ink)
        : a.spec == null
        ? (Icons.error_outline_rounded, a.error ?? "Je n'ai pas compris la question. Reformulez-la, ou choisissez une question prête.", T.dangerDark)
        : null;
    return AnimatedBuilder(
      animation: glow,
      builder: (context, _) {
        final t = glow.value;
        final pulse = asking ? 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * math.pi * 2)) : 0.35;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CustomPaint(
              painter: _GlowBorderPainter(progress: t, active: asking, intensity: pulse),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                decoration: BoxDecoration(
                  color: T.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: T.mint.withValues(alpha: asking ? 0.35 * pulse : 0.12),
                      blurRadius: asking ? 26 : 14,
                      spreadRadius: asking ? 2 : 0,
                    ),
                  ],
                ),
                child: Row(
                  children: [
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
                        style: T.body.copyWith(fontSize: 15),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          hintText: asking ? phase : 'Posez votre question — « ventes par jour ce mois-ci », « quels produits périment ? »…',
                          hintStyle: T.body.copyWith(color: asking ? T.mintDark : T.faint, fontSize: 14.5, fontStyle: asking ? FontStyle.italic : FontStyle.normal),
                        ),
                        onSubmitted: (_) => onAsk(),
                      ),
                    ),
                    if (asking)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: T.mint)),
                      )
                    else
                      SizedBox(
                        height: 40,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: T.mint,
                            foregroundColor: T.ink,
                            textStyle: const TextStyle(fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                          onPressed: onAsk,
                          icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                          label: const Text('Demander'),
                        ),
                      ),
                    const SizedBox(width: 6),
                    TextButton.icon(
                      onPressed: onGallery,
                      icon: Icon(galleryOpen ? Icons.close_rounded : Icons.lightbulb_outline_rounded, size: 18),
                      label: Text(galleryOpen ? 'Fermer les questions' : 'Questions prêtes'),
                    ),
                    TextButton.icon(
                      onPressed: demoRunning ? onStopDemo : onDemo,
                      icon: Icon(demoRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline_rounded, size: 18),
                      label: Text(demoRunning ? 'Arrêter la démo' : 'Démo'),
                    ),
                  ],
                ),
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 6),
                child: Row(
                  children: [
                    Icon(note.$1, size: 18, color: note.$3),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note.$2,
                        style: T.body.copyWith(color: note.$3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(onPressed: onGallery, child: const Text('Voir les questions prêtes')),
                  ],
                ),
              ),
          ],
        );
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
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = T.mint.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      return;
    }
    final sweep = SweepGradient(
      startAngle: 0,
      endAngle: math.pi * 2,
      transform: GradientRotation(progress * math.pi * 2),
      colors: const [T.mint, Color(0xFF4A63B8), Color(0xFF7B61C9), Color(0xFFE0A020), T.mint],
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = sweep.createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 + 1.2 * intensity,
    );
    canvas.drawRRect(
      rrect.inflate(2),
      Paint()
        ..shader = sweep.createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..color = Colors.white.withValues(alpha: 0.5 * intensity),
    );
  }

  @override
  bool shouldRepaint(_GlowBorderPainter old) => old.progress != progress || old.active != active || old.intensity != intensity;
}
