// Models of the Analyses module: schema (whitelist), query
// specification and result. The spec is a plain JSON Map sent as-is to the
// server, which alone decides whether it is valid.

class AField {
  final String key, labelFr, labelAr, type, unit, format, group;
  final bool dimension, measure, filterable;
  final List<String> aggs, ops, buckets, enumValues;
  final String? gatedBy, enumSource;

  AField.fromJson(Map<String, dynamic> j)
    : key = j['field'] as String,
      labelFr = (j['label_fr'] as String?) ?? j['field'] as String,
      labelAr = (j['label_ar'] as String?) ?? '',
      type = (j['type'] as String?) ?? 'string',
      unit = (j['unit'] as String?) ?? '',
      format = (j['format'] as String?) ?? 'text',
      group = (j['group'] as String?) ?? '',
      dimension = j['dimension'] == true,
      measure = j['measure'] == true,
      filterable = j['filterable'] == true,
      aggs = [for (final a in (j['allowed_aggs'] as List? ?? const [])) '$a'],
      ops = [for (final a in (j['allowed_ops'] as List? ?? const [])) '$a'],
      buckets = [for (final a in (j['buckets'] as List? ?? const [])) '$a'],
      enumValues = [for (final a in (j['enum_values'] as List? ?? const [])) '$a'],
      gatedBy = j['gated_by'] as String?,
      enumSource = j['enum_source'] as String?;

  bool get isDate => type == 'date' || type == 'datetime';
}

class ANamed {
  final String key, labelFr, format, unit;
  ANamed.fromJson(Map<String, dynamic> j)
    : key = j['key'] as String,
      labelFr = (j['label_fr'] as String?) ?? j['key'] as String,
      format = (j['format'] as String?) ?? 'integer',
      unit = (j['unit'] as String?) ?? '';
}

class AParam {
  final String key, labelFr;
  final int def, min, max;
  AParam.fromJson(Map<String, dynamic> j)
    : key = j['key'] as String,
      labelFr = (j['label_fr'] as String?) ?? j['key'] as String,
      def = (j['default'] as num?)?.toInt() ?? 0,
      min = (j['min'] as num?)?.toInt() ?? 0,
      max = (j['max'] as num?)?.toInt() ?? 0;
}

class ASource {
  final String key, labelFr, icon, dateField;
  final bool template;
  final List<AField> fields;
  final List<ANamed> named;
  final List<AParam> params;
  ASource.fromJson(Map<String, dynamic> j)
    : key = j['key'] as String,
      labelFr = (j['label_fr'] as String?) ?? j['key'] as String,
      icon = (j['icon'] as String?) ?? '',
      dateField = (j['date_field'] as String?) ?? '',
      template = j['template'] == true,
      fields = [for (final f in (j['fields'] as List? ?? const [])) AField.fromJson(f as Map<String, dynamic>)],
      named = [for (final n in (j['named_measures'] as List? ?? const [])) ANamed.fromJson(n as Map<String, dynamic>)],
      params = [for (final p in (j['params'] as List? ?? const [])) AParam.fromJson(p as Map<String, dynamic>)];

  AField? field(String key) {
    for (final f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }

  ANamed? namedMeasure(String key) {
    for (final n in named) {
      if (n.key == key) return n;
    }
    return null;
  }
}

class ASchema {
  final int version;
  final List<ASource> sources;
  final List<String> ranges;
  ASchema.fromJson(Map<String, dynamic> j)
    : version = (j['version'] as num?)?.toInt() ?? 1,
      sources = [for (final s in (j['sources'] as List? ?? const [])) ASource.fromJson(s as Map<String, dynamic>)],
      ranges = [for (final r in (j['ranges'] as List? ?? const [])) '$r'];

  ASource? source(String key) {
    for (final s in sources) {
      if (s.key == key) return s;
    }
    return null;
  }
}

class AColumn {
  final String key, kind, field, label, format, unit, bucket, derived;

  /// The server may say whether the column is additive (« Total » row). Absent
  /// = guessed client-side from the format and label ([isAdditive]).
  final bool? additive;
  AColumn.fromJson(Map<String, dynamic> j)
    : key = j['key'] as String,
      kind = (j['kind'] as String?) ?? 'measure',
      field = (j['field'] as String?) ?? '',
      label = (j['label'] as String?) ?? '',
      format = (j['format'] as String?) ?? 'integer',
      unit = (j['unit'] as String?) ?? '',
      bucket = (j['bucket'] as String?) ?? '',
      derived = (j['derived'] as String?) ?? '',
      additive = j['additive'] is bool ? j['additive'] as bool : null;
  bool get isDimension => kind == 'dimension';
  bool get isMeasure => kind == 'measure';
  bool get isBase => derived.isEmpty; // nor prev/delta/share/cum

  static final _nonAdditive = RegExp(r'moyen|moyenne|min\b|max\b|distinct|unitaire|taux|%', caseSensitive: false);
  static final _countLike = RegExp(r'^(nombre|lignes)', caseSensitive: false);

  /// Does a sum of this column make sense (« Total » row)?
  bool get isAdditive {
    if (!isMeasure) return false;
    if (additive != null) return additive!;
    if (derived == 'delta_pct' || derived == 'cum') return false;
    if (_nonAdditive.hasMatch(label)) return false;
    if (format == 'currency' || format == 'quantity') return true;
    if (format == 'integer') return _countLike.hasMatch(label) || derived == 'share';
    return false;
  }
}

class AResult {
  final List<AColumn> columns;
  final List<List<dynamic>> rows;
  final int totalRows;
  final bool truncated, cached;
  final String rangeFrom, rangeTo;
  final bool rangeAll;
  final String? prevFrom, prevTo;
  final List<String> dropped;
  final int durationMs;
  final Map<String, Map<String, String>> labels;

  AResult.fromJson(Map<String, dynamic> j)
    : columns = [for (final c in (j['columns'] as List? ?? const [])) AColumn.fromJson(c as Map<String, dynamic>)],
      rows = [for (final r in (j['rows'] as List? ?? const [])) List<dynamic>.from(r as List)],
      totalRows = (j['total_rows'] as num?)?.toInt() ?? 0,
      truncated = j['truncated'] == true,
      cached = j['cached'] == true,
      rangeFrom = (j['range']?['from'] as String?) ?? '',
      rangeTo = (j['range']?['to'] as String?) ?? '',
      rangeAll = j['range']?['all'] == true,
      prevFrom = j['prev_range']?['from'] as String?,
      prevTo = j['prev_range']?['to'] as String?,
      dropped = [for (final d in (j['dropped'] as List? ?? const [])) '$d'],
      durationMs = (j['duration_ms'] as num?)?.toInt() ?? 0,
      labels = {
        for (final e in ((j['labels'] as Map?) ?? const {}).entries) '${e.key}': {for (final x in (e.value as Map).entries) '${x.key}': '${x.value}'},
      };

  List<AColumn> get dimensions => [
    for (final c in columns)
      if (c.isDimension) c,
  ];
  List<AColumn> get measures => [
    for (final c in columns)
      if (c.isMeasure && c.isBase) c,
  ];
  List<AColumn> get allMeasures => [
    for (final c in columns)
      if (c.isMeasure) c,
  ];

  int colIndex(String key) => columns.indexWhere((c) => c.key == key);

  /// Label of a dimension value (translated bucket if available).
  String labelOf(AColumn col, dynamic v) {
    if (v == null) return '—';
    final m = labels[col.key];
    if (m != null && m['$v'] != null) return m['$v']!;
    final s = '$v';
    if (s.isEmpty) return '(vide)';
    if (col.format == 'bool') return (v == 1 || v == true) ? 'Oui' : 'Non';
    return s;
  }
}

class GalleryItem {
  final String theme, title, chartType;
  final Map<String, dynamic> spec;
  GalleryItem.fromJson(Map<String, dynamic> j)
    : theme = (j['theme'] as String?) ?? '',
      title = (j['title'] as String?) ?? '',
      chartType = (j['chart_type'] as String?) ?? 'auto',
      spec = Map<String, dynamic>.from((j['spec'] as Map?) ?? const {});
}

class AskAnswer {
  final String question, chartType, title, explanation, provider, model;
  final String? clarification, error;
  final Map<String, dynamic>? spec;
  final AResult? result;
  final int attempts, durationMs;
  AskAnswer.fromJson(Map<String, dynamic> j)
    : question = (j['question'] as String?) ?? '',
      chartType = (j['chart_type'] as String?) ?? 'auto',
      title = (j['title'] as String?) ?? '',
      explanation = (j['explanation'] as String?) ?? '',
      provider = (j['provider'] as String?) ?? 'local',
      model = (j['model'] as String?) ?? '',
      clarification = j['clarification'] as String?,
      error = j['error'] as String?,
      spec = j['spec'] is Map ? Map<String, dynamic>.from(j['spec'] as Map) : null,
      result = j['result'] is Map ? AResult.fromJson(j['result'] as Map<String, dynamic>) : null,
      attempts = (j['attempts'] as num?)?.toInt() ?? 0,
      durationMs = (j['duration_ms'] as num?)?.toInt() ?? 0;
}

class SavedReport {
  final String id, name, chartType;
  final Map<String, dynamic> spec, encoding;
  final int specVersion;
  final String? ownerId;
  final bool isShared, isDefault;
  final List<String> missing;
  SavedReport.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      name = j['name'] as String,
      chartType = (j['chart_type'] as String?) ?? 'auto',
      spec = Map<String, dynamic>.from((j['spec'] as Map?) ?? const {}),
      encoding = Map<String, dynamic>.from((j['encoding'] as Map?) ?? const {}),
      specVersion = (j['spec_version'] as num?)?.toInt() ?? 1,
      ownerId = j['owner_id'] as String?,
      isShared = j['is_shared'] == true,
      isDefault = j['is_default'] == true,
      missing = [for (final m in (j['missing_fields'] as List? ?? const [])) '$m'];
}

class DashboardTile {
  String reportId;
  int x, y, w, h;
  DashboardTile({required this.reportId, this.x = 0, this.y = 0, this.w = 6, this.h = 4});
  DashboardTile.fromJson(Map<String, dynamic> j)
    : reportId = j['report_id'] as String,
      x = (j['x'] as num?)?.toInt() ?? 0,
      y = (j['y'] as num?)?.toInt() ?? 0,
      w = (j['w'] as num?)?.toInt() ?? 6,
      h = (j['h'] as num?)?.toInt() ?? 4;
  Map<String, dynamic> toJson() => {'report_id': reportId, 'x': x, 'y': y, 'w': w, 'h': h};
}

class Dashboard {
  final String id, name;
  final String? ownerId, globalWarehouseId;
  final bool isShared, isDefault;
  final List<DashboardTile> layout;
  final Map<String, dynamic> globalRange;
  Dashboard.fromJson(Map<String, dynamic> j)
    : id = j['id'] as String,
      name = j['name'] as String,
      ownerId = j['owner_id'] as String?,
      globalWarehouseId = j['global_warehouse_id'] as String?,
      isShared = j['is_shared'] == true,
      isDefault = j['is_default'] == true,
      layout = [for (final t in (j['layout'] as List? ?? const [])) DashboardTile.fromJson(t as Map<String, dynamic>)],
      globalRange = Map<String, dynamic>.from((j['global_range'] as Map?) ?? const {'type': 'this_month'});
}

/// Relative periods offered in the UI (server key → label).
const kRangeLabels = <String, String>{
  'today': "Aujourd'hui",
  'yesterday': 'Hier',
  'this_week': 'Cette semaine',
  'previous_week': 'Semaine dernière',
  'this_month': 'Ce mois',
  'previous_month': 'Mois dernier',
  'this_quarter': 'Ce trimestre',
  'previous_quarter': 'Trimestre dernier',
  'this_year': 'Cette année',
  'previous_year': 'Année dernière',
  'year_to_date': "Depuis le 1er janvier",
  'last_n_days': 'N derniers jours',
  'last_n_months': 'N derniers mois',
  'all': 'Tout',
  'custom': 'Personnalisée',
};

const kBucketLabels = <String, String>{'day': 'Jour', 'week': 'Semaine', 'month': 'Mois', 'quarter': 'Trimestre', 'year': 'Année', 'dow': 'Jour de semaine', 'hour': 'Heure'};

const kAggLabels = <String, String>{'sum': 'Somme', 'avg': 'Moyenne', 'min': 'Min', 'max': 'Max', 'count': 'Nombre', 'count_distinct': 'Distincts'};

const kOpLabels = <String, String>{
  'eq': '=',
  'ne': '≠',
  'gt': '>',
  'gte': '≥',
  'lt': '<',
  'lte': '≤',
  'between': 'entre',
  'in': 'parmi',
  'not_in': 'sauf',
  'contains': 'contient',
  'starts_with': 'commence par',
  'ends_with': 'finit par',
  'is_null': 'est vide',
  'is_not_null': 'est renseigné',
};

/// The period in plain words, to put in a sentence: « ce mois-ci »,
/// « sur les 30 derniers jours », « du 2026-01-01 au 2026-03-31 ».
String rangePhrase(Map<String, dynamic> r) {
  final t = (r['type'] as String?) ?? 'this_month';
  return switch (t) {
    'today' => "aujourd'hui",
    'yesterday' => 'hier',
    'this_week' => 'cette semaine',
    'previous_week' => 'la semaine dernière',
    'this_month' => 'ce mois-ci',
    'previous_month' => 'le mois dernier',
    'this_quarter' => 'ce trimestre',
    'previous_quarter' => 'le trimestre dernier',
    'this_year' => 'cette année',
    'previous_year' => "l'année dernière",
    'year_to_date' => 'depuis le 1er janvier',
    'last_n_days' => 'sur les ${r['n'] ?? 30} derniers jours',
    'last_n_months' => 'sur les ${r['n'] ?? 3} derniers mois',
    'all' => 'sur toute la période',
    'custom' => 'du ${frDate('${r['from'] ?? ''}')} au ${frDate('${r['to'] ?? ''}')}',
    _ => kRangeLabels[t] ?? t,
  };
}

const _kMonthsShort = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];

/// « 2026-10-08 » → « 8 oct. 2026 » (leaves the text as-is if it is not a date).
String frDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day} ${_kMonthsShort[d.month - 1]} ${d.year}';
}

/// What the source counts, for empty messages: « Aucune vente ».
String emptyNoun(String source) => switch (source) {
  'sale_lines' || 'product_performance' => 'Aucune vente',
  'purchase_lines' => 'Aucun achat',
  'stock_movements' => 'Aucun mouvement de stock',
  'stock_snapshot' => 'Aucun stock',
  'partner_ledger' => 'Aucune opération client ou fournisseur',
  _ => 'Aucune donnée',
};

String rangeLabel(Map<String, dynamic> r) {
  final t = (r['type'] as String?) ?? 'this_month';
  switch (t) {
    case 'last_n_days':
      return '${r['n'] ?? 30} derniers jours';
    case 'last_n_months':
      return '${r['n'] ?? 3} derniers mois';
    case 'custom':
      return '${r['from'] ?? ''} → ${r['to'] ?? ''}';
  }
  return kRangeLabels[t] ?? t;
}
