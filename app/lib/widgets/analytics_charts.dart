import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/analytics_models.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/list_export.dart';
import 'charts.dart';
import 'ui.dart';

/// Palette des séries (marque en tête, puis des teintes lisibles côte à côte).
const kSeriesColors = <Color>[T.mint, Color(0xFF4A63B8), Color(0xFFE0A020), Color(0xFFB8556B), Color(0xFF7B61C9), Color(0xFF2FA0B8), Color(0xFFC97A1A), Color(0xFF6B8E23)];

Color seriesColor(int i) => kSeriesColors[i % kSeriesColors.length];

/// Formate une valeur selon le format déclaré par le serveur.
String fmtValue(dynamic v, String format) {
  if (v == null) return '—';
  switch (format) {
    case 'currency':
      return '${fmtDA(_toNum(v).round())} DA';
    case 'quantity':
      return fmtQty(_toNum(v).round());
    case 'percent':
      return '${(_toNum(v) * 100).toStringAsFixed(1).replaceAll('.', ',')} %';
    case 'ratio':
      return _toNum(v).toStringAsFixed(2).replaceAll('.', ',');
    case 'integer':
      return _groupThousands(_toNum(v).round());
    case 'bool':
      return (v == 1 || v == true) ? 'Oui' : 'Non';
  }
  return '$v';
}

/// Version courte pour les axes (12,5 k, 1,2 M…).
String fmtAxis(double v, String format) {
  var x = v;
  var suffix = '';
  if (format == 'currency') x = v / 100;
  if (format == 'quantity') x = v / 1000;
  if (format == 'percent') return '${(v * 100).round()} %';
  if (format == 'ratio') return v.toStringAsFixed(1).replaceAll('.', ',');
  final ax = x.abs();
  if (ax >= 1e6) {
    x = x / 1e6;
    suffix = ' M';
  } else if (ax >= 1e3) {
    x = x / 1e3;
    suffix = ' k';
  }
  final s = x.abs() >= 100 || x == x.roundToDouble() ? x.round().toString() : x.toStringAsFixed(1).replaceAll('.', ',');
  return '$s$suffix';
}

double _toNum(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

String _groupThousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return (n < 0 ? '-' : '') + b.toString();
}

/// Encodage explicite d'un graphique (sauvegardé à part de la spec).
class ChartEncoding {
  String? x; // clé de colonne dimension
  String? series; // clé de colonne dimension (couleur)
  List<String> y; // clés de colonnes mesure
  bool stacked;
  String? secondary; // mesure sur l'axe secondaire
  bool showValues;
  bool showPrevious;

  /// Couleurs conditionnelles des tables : clé de colonne mesure → règles.
  Map<String, CondFormat> cond;

  ChartEncoding({this.x, this.series, List<String>? y, this.stacked = false, this.secondary, this.showValues = false, this.showPrevious = true, Map<String, CondFormat>? cond})
    : y = y ?? [],
      cond = cond ?? {};

  factory ChartEncoding.fromJson(Map<String, dynamic> j) => ChartEncoding(
    x: j['x'] as String?,
    series: j['series'] as String?,
    y: [for (final e in (j['y'] as List? ?? const [])) '$e'],
    stacked: j['stacked'] == true,
    secondary: j['secondary'] as String?,
    showValues: j['show_values'] == true,
    showPrevious: j['show_previous'] != false,
    cond: {
      for (final e in ((j['cond'] as Map?) ?? const {}).entries)
        if (e.value is Map) '${e.key}': CondFormat.fromJson(Map<String, dynamic>.from(e.value as Map)),
    },
  );

  Map<String, dynamic> toJson() => {
    if (x != null) 'x': x,
    if (series != null) 'series': series,
    'y': y,
    'stacked': stacked,
    if (secondary != null) 'secondary': secondary,
    'show_values': showValues,
    'show_previous': showPrevious,
    if (cond.values.any((c) => !c.isEmpty))
      'cond': {
        for (final e in cond.entries)
          if (!e.value.isEmpty) e.key: e.value.toJson(),
      },
  };

  ChartEncoding copy() => ChartEncoding.fromJson(toJson());

  /// Complète l'encodage avec des valeurs par défaut cohérentes avec le résultat.
  ChartEncoding resolved(AResult r) {
    final dims = r.dimensions;
    final meas = r.measures;
    final e = ChartEncoding(
      x: x,
      series: series,
      y: List.of(y),
      stacked: stacked,
      secondary: secondary,
      showValues: showValues,
      showPrevious: showPrevious,
      cond: {for (final c in cond.entries) c.key: CondFormat.fromJson(c.value.toJson())},
    );
    if (e.x == null || r.colIndex(e.x!) < 0) {
      e.x = dims.isNotEmpty ? dims.first.key : null;
    }
    if (e.series != null && (r.colIndex(e.series!) < 0 || e.series == e.x)) e.series = null;
    if (e.series == null && dims.length > 1) {
      e.series = dims.firstWhere((d) => d.key != e.x, orElse: () => dims[1]).key;
    }
    e.y = [
      for (final k in e.y)
        if (r.colIndex(k) >= 0) k,
    ];
    if (e.y.isEmpty) e.y = [for (final m in meas) m.key];
    if (e.secondary != null && !e.y.contains(e.secondary)) e.secondary = null;
    return e;
  }
}

const kChartTypes = ['stat', 'line', 'bar', 'donut', 'pivot', 'table'];
const kChartLabels = {'stat': 'Chiffre', 'line': 'Courbe', 'bar': 'Barres', 'donut': 'Anneau', 'pivot': 'Tableau croisé', 'table': 'Liste'};
const kChartIcons = {
  'stat': Icons.pin_outlined,
  'line': Icons.show_chart_rounded,
  'bar': Icons.bar_chart_rounded,
  'donut': Icons.donut_large_rounded,
  'pivot': Icons.grid_on_rounded,
  'table': Icons.table_rows_rounded,
};

/// Choix automatique d'après la forme du résultat.
String autoChartType(AResult r) {
  final nd = r.dimensions.length;
  final nm = r.measures.length;
  if (nd == 0) return 'stat';
  if (nd == 1) {
    final d = r.dimensions.first;
    if (d.bucket.isNotEmpty && d.bucket != 'dow' && d.bucket != 'hour') return 'line';
    if (nm == 1 && r.rows.length <= 8 && r.rows.length >= 2) return 'donut';
    return 'bar';
  }
  if (nd == 2) {
    final d = r.dimensions.first;
    if (d.bucket.isNotEmpty) return 'line';
    return 'pivot';
  }
  return 'table';
}

/// Le type peut-il rendre cette forme ? Retourne null si oui, sinon la raison.
String? chartTypeBlocker(String type, AResult r) {
  final nd = r.dimensions.length;
  final nm = r.measures.length;
  switch (type) {
    case 'stat':
      return nd == 0 ? null : 'Chiffre : aucune dimension';
    case 'line':
    case 'bar':
      if (nd == 0) return '${kChartLabels[type]} : au moins 1 dimension';
      if (nd > 2) return '${kChartLabels[type]} : 2 dimensions au plus';
      if (nm == 0) return 'Aucune mesure';
      return null;
    case 'donut':
      if (nd != 1) return 'Anneau : exactement 1 dimension';
      if (r.rows.length > 12) return 'Anneau : 12 valeurs au plus';
      return null;
    case 'pivot':
      return nd >= 2 ? null : 'Tableau croisé : 2 dimensions au moins';
  }
  return null;
}

/// Rend le résultat avec le type et l'encodage donnés.
/// [title] sert de titre aux exports des tables ; [onDrill] rend les valeurs
/// de regroupement cliquables (détail).
Widget buildChart(String type, AResult r, ChartEncoding enc, {bool compact = false, void Function(AColumn col, dynamic value)? onDrill, String title = 'Analyse'}) {
  if (r.rows.isEmpty) {
    return const EmptyState(icon: Icons.query_stats_rounded, text: 'Aucune donnée sur cette période');
  }
  final e = enc.resolved(r);
  switch (type) {
    case 'stat':
      return StatTiles(result: r, compact: compact);
    case 'line':
      return SeriesChart(result: r, encoding: e, line: true, compact: compact, onDrill: onDrill);
    case 'bar':
      return SeriesChart(result: r, encoding: e, line: false, compact: compact, onDrill: onDrill);
    case 'donut':
      return DonutChart(result: r, encoding: e, compact: compact, onDrill: onDrill);
    case 'pivot':
      return PivotGrid(result: r, encoding: e, compact: compact, onDrill: onDrill, title: title);
  }
  return ResultTable(result: r, encoding: e, compact: compact, onDrill: onDrill, title: title);
}

// ---------------------------------------------------------------- valeurs affichées

/// Valeur brute (centimes, millièmes, ratio) → valeur lue par l'utilisateur
/// (DA, quantité, %). Les seuils des couleurs sont saisis dans cette unité.
double displayNum(dynamic raw, String format) {
  final v = _toNum(raw);
  return switch (format) {
    'currency' => v / 100,
    'quantity' => v / 1000,
    'percent' => v * 100,
    _ => v,
  };
}

/// Unité affichée à côté des seuils et dans les en-têtes d'export.
String unitWord(String format) => switch (format) {
  'currency' => 'DA',
  'quantity' => 'quantité',
  'percent' => '%',
  _ => '',
};

// ---------------------------------------------------------------- couleurs conditionnelles

/// Couleurs proposées pour les règles (clé enregistrée → libellé, fond, texte).
const kCondColors = <String, (String, Color, Color)>{
  'red': ('Rouge', Color(0x33E5484D), T.dangerDark),
  'green': ('Vert', Color(0x3300CC99), T.mintDark),
  'orange': ('Orange', Color(0x40E0A020), T.warnDark),
  'blue': ('Bleu', Color(0x2E4A63B8), Color(0xFF34488F)),
};

/// Une règle « valeur op seuil → couleur ». [a]/[b] sont dans l'unité affichée.
class CondRule {
  String op; // lt | lte | gt | gte | eq | between
  double a;
  double? b;
  String color;
  CondRule({this.op = 'lt', this.a = 0, this.b, this.color = 'red'});
  factory CondRule.fromJson(Map<String, dynamic> j) =>
      CondRule(op: (j['op'] as String?) ?? 'lt', a: (j['a'] as num?)?.toDouble() ?? 0, b: (j['b'] as num?)?.toDouble(), color: (j['color'] as String?) ?? 'red');
  Map<String, dynamic> toJson() => {'op': op, 'a': a, if (b != null) 'b': b, 'color': color};

  bool matches(double v) => switch (op) {
    'lt' => v < a,
    'lte' => v <= a,
    'gt' => v > a,
    'gte' => v >= a,
    'eq' => v == a,
    'between' => v >= math.min(a, b ?? a) && v <= math.max(a, b ?? a),
    _ => false,
  };
}

const kCondOps = <String, String>{'lt': 'inférieur à', 'lte': 'inférieur ou égal à', 'gt': 'supérieur à', 'gte': 'supérieur ou égal à', 'eq': 'égal à', 'between': 'entre'};

/// Mise en forme conditionnelle d'une colonne mesure.
class CondFormat {
  String scale; // none | up (plus haut = mieux) | down (plus bas = mieux) | neutral
  bool bars;
  List<CondRule> rules;
  String top; // none | top | bottom
  int topN;
  CondFormat({this.scale = 'none', this.bars = false, List<CondRule>? rules, this.top = 'none', this.topN = 5}) : rules = rules ?? [];

  factory CondFormat.fromJson(Map<String, dynamic> j) => CondFormat(
    scale: (j['scale'] as String?) ?? 'none',
    bars: j['bars'] == true,
    rules: [
      for (final r in (j['rules'] as List? ?? const []))
        if (r is Map) CondRule.fromJson(Map<String, dynamic>.from(r)),
    ],
    top: (j['top'] as String?) ?? 'none',
    topN: (j['top_n'] as num?)?.toInt() ?? 5,
  );
  Map<String, dynamic> toJson() => {
    'scale': scale,
    'bars': bars,
    'rules': [for (final r in rules) r.toJson()],
    'top': top,
    'top_n': topN,
  };

  bool get isEmpty => scale == 'none' && !bars && rules.isEmpty && top == 'none';
}

/// Statistiques d'une colonne (valeurs affichées) pour l'échelle et le top N.
class CondStats {
  CondStats(List<double> values, CondFormat f)
    : min = values.isEmpty ? 0 : values.reduce(math.min),
      max = values.isEmpty ? 0 : values.reduce(math.max),
      maxAbs = values.isEmpty ? 0 : values.map((v) => v.abs()).reduce(math.max),
      cut = _cut(values, f);
  final double min, max, maxAbs;
  final double? cut;

  static double? _cut(List<double> values, CondFormat f) {
    if (f.top == 'none' || values.isEmpty || f.topN <= 0) return null;
    final s = List.of(values)..sort();
    final n = math.min(f.topN, s.length);
    return f.top == 'top' ? s[s.length - n] : s[n - 1];
  }
}

/// Aspect d'une cellule : fond, couleur et graisse du texte, barre (0..1, signe).
class CellLook {
  const CellLook({this.bg, this.fg, this.bold = false, this.bar});
  final Color? bg, fg;
  final bool bold;
  final double? bar;
}

const _kScaleLow = Color(0x40E5484D);
const _kScaleHigh = Color(0x4D00CC99);
const _kScaleNeutral = Color(0x404A63B8);

CellLook condLook(CondFormat? f, double v, CondStats? s) {
  if (f == null || f.isEmpty || s == null) return const CellLook();
  Color? bg;
  Color? fg;
  var bold = false;
  // échelle de couleur (la plus faible priorité)
  if (f.scale != 'none' && s.max > s.min) {
    final t = ((v - s.min) / (s.max - s.min)).clamp(0.0, 1.0);
    if (f.scale == 'neutral') {
      bg = Color.lerp(Colors.transparent, _kScaleNeutral, t);
    } else {
      final good = f.scale == 'up' ? t : 1 - t;
      bg = good < 0.5 ? Color.lerp(_kScaleLow, Colors.transparent, good * 2) : Color.lerp(Colors.transparent, _kScaleHigh, (good - 0.5) * 2);
    }
  }
  // N premiers / derniers
  if (s.cut != null && (f.top == 'top' ? v >= s.cut! : v <= s.cut!)) {
    bg = f.top == 'top' ? const Color(0x3300CC99) : const Color(0x40E0A020);
    fg = f.top == 'top' ? T.mintDark : T.warnDark;
    bold = true;
  }
  // règles : la première qui correspond gagne
  for (final r in f.rules) {
    if (r.matches(v)) {
      final c = kCondColors[r.color] ?? kCondColors['red']!;
      bg = c.$2;
      fg = c.$3;
      bold = true;
      break;
    }
  }
  double? bar;
  if (f.bars && s.maxAbs > 0) bar = (v / s.maxAbs).clamp(-1.0, 1.0);
  return CellLook(bg: bg, fg: fg, bold: bold, bar: bar);
}

/// Cellule numérique avec son aspect conditionnel (fond + barre de données).
class CondCell extends StatelessWidget {
  const CondCell({super.key, required this.text, required this.look, required this.style, this.width, this.height, this.padding = const EdgeInsets.symmetric(horizontal: 8)});
  final String text;
  final CellLook look;
  final TextStyle style;
  final double? width, height;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final bar = look.bar;
    return Container(
      width: width,
      height: height,
      color: look.bg,
      child: Stack(
        children: [
          if (bar != null && bar != 0)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: bar.abs(),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: bar < 0 ? const Color(0x55E5484D) : const Color(0x5500CC99), borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: Padding(
              padding: padding,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  text,
                  style: style.copyWith(color: look.fg ?? style.color, fontWeight: look.bold ? FontWeight.w700 : style.fontWeight),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- export

/// Exporte un résultat (lignes déjà filtrées/triées) en Excel, CSV ou PDF :
/// valeurs en DA / quantité / % (des nombres dans Excel).
Future<String> exportResult(AResult r, List<List<dynamic>> rows, String title, ExportFormat f, {List<AColumn>? columns}) {
  final cols = columns ?? r.columns;
  final idx = [for (final c in cols) r.colIndex(c.key)];
  final headers = [for (final c in cols) c.isMeasure && unitWord(c.format).isNotEmpty && c.format != 'quantity' ? '${c.label} (${unitWord(c.format)})' : c.label];
  final data = <List<Object?>>[
    for (final row in rows)
      [
        for (var i = 0; i < cols.length; i++)
          cols[i].isDimension
              ? r.labelOf(cols[i], row[idx[i]])
              : row[idx[i]] == null
              ? null
              : _round2(displayNum(row[idx[i]], cols[i].format)),
      ],
  ];
  final safe = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return exportTable(
    ExportTable(
      title: title,
      baseName: 'analyse-${safe.isEmpty ? 'vue' : safe}',
      headers: headers,
      rows: data,
      numeric: {
        for (var i = 0; i < cols.length; i++)
          if (cols[i].isMeasure) i,
      },
    ),
    f,
  );
}

num _round2(double v) => v == v.roundToDouble() ? v.round() : (v * 100).round() / 100;

/// Bouton « Exporter ▾ » (Excel, CSV, PDF) commun aux tables.
class ExportMenuButton extends StatelessWidget {
  const ExportMenuButton({super.key, required this.onExport, this.label = 'Exporter'});
  final Future<String> Function(ExportFormat f) onExport;
  final String label;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ExportFormat>(
      tooltip: 'Exporter en Excel, CSV ou PDF',
      onSelected: (f) async {
        try {
          final path = await onExport(f);
          if (context.mounted) showToast(context, 'Exporté : $path', kind: ToastKind.success);
        } catch (e) {
          if (context.mounted) showToast(context, "L'export a échoué : $e", kind: ToastKind.error);
        }
      },
      itemBuilder: (_) => [
        for (final f in const [ExportFormat.xlsx, ExportFormat.csv, ExportFormat.pdf])
          PopupMenuItem(
            value: f,
            child: Text(f.label, style: T.body),
          ),
      ],
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: T.border3),
          borderRadius: BorderRadius.circular(T.rInner),
          color: T.surface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_outlined, size: 17, color: T.ink),
            const SizedBox(width: 6),
            Text(label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
            const Icon(Icons.arrow_drop_down_rounded, size: 20, color: T.muted),
          ],
        ),
      ),
    );
  }
}

/// Petit champ de recherche des tables (filtre les lignes affichées).
class _TableSearch extends StatelessWidget {
  const _TableSearch({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 38,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: T.body,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Rechercher dans le tableau…',
          hintStyle: T.bodyMuted.copyWith(color: T.ghost),
          prefixIcon: const Icon(Icons.search, size: 18, color: T.faint),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Effacer la recherche',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border3),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border3),
          ),
        ),
      ),
    );
  }
}

int _cmpCells(dynamic va, dynamic vb) {
  if (va == null && vb == null) return 0;
  if (va == null) return -1;
  if (vb == null) return 1;
  if (va is num && vb is num) return va.compareTo(vb);
  return '$va'.toLowerCase().compareTo('$vb'.toLowerCase());
}

// ---------------------------------------------------------------- chiffres

class StatTiles extends StatelessWidget {
  const StatTiles({super.key, required this.result, this.compact = false, this.flat = false, this.title});
  final AResult result;
  final bool compact;
  final bool flat; // carte de tableau de bord : pas de cadre interne, le titre sert de libellé
  final String? title;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final row = r.rows.first;
    if (flat && r.measures.length == 1) {
      final m = r.measures.first;
      final i = r.colIndex(m.key);
      final prevI = r.colIndex('${m.key}_delta_pct');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MicroLabel(title ?? m.label, color: T.mintDark),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(fmtValue(row[i], m.format), style: T.monoBig),
          ),
          if (prevI >= 0 && row[prevI] != null) ...[
            const SizedBox(height: 4),
            Text(
              '${_toNum(row[prevI]) >= 0 ? '▲' : '▼'} ${fmtValue(row[prevI], 'percent')} vs période préc.',
              style: T.small.copyWith(color: _toNum(row[prevI]) >= 0 ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w600),
            ),
          ] else if (title != null && title != m.label) ...[
            const SizedBox(height: 4),
            Text(m.label, style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      );
    }
    if (flat) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (title != null) MicroLabel(title!, color: T.mintDark),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final m in r.measures) ...[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(fmtValue(row[r.colIndex(m.key)], m.format), style: T.h2.copyWith(fontSize: 20)),
                      ),
                      Text(m.label, style: T.small.copyWith(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }
    final tiles = <Widget>[];
    for (final m in r.measures) {
      final i = r.colIndex(m.key);
      final prevI = r.colIndex('${m.key}_delta_pct');
      tiles.add(
        Container(
          constraints: BoxConstraints(minWidth: compact ? 120 : 160),
          padding: EdgeInsets.all(compact ? 10 : 14),
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MicroLabel(m.label, color: T.mintDark),
              const SizedBox(height: 6),
              Text(fmtValue(row[i], m.format), style: compact ? T.h2 : T.monoBig),
              if (prevI >= 0 && row[prevI] != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${_toNum(row[prevI]) >= 0 ? '▲' : '▼'} ${fmtValue(row[prevI], 'percent')} vs période préc.',
                  style: T.small.copyWith(color: _toNum(row[prevI]) >= 0 ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(child: Wrap(spacing: 10, runSpacing: 10, children: tiles));
  }
}

// ---------------------------------------------------------------- lignes / barres

class _Series {
  _Series(this.label, this.color, this.values, {this.format = 'integer', this.dashed = false, this.secondary = false});
  final String label;
  final Color color;
  final List<double?> values;
  final String format;
  final bool dashed;
  final bool secondary;
}

class SeriesChart extends StatefulWidget {
  const SeriesChart({super.key, required this.result, required this.encoding, required this.line, this.compact = false, this.onDrill});
  final AResult result;
  final ChartEncoding encoding;
  final bool line;
  final bool compact;
  final void Function(AColumn col, dynamic value)? onDrill;

  @override
  State<SeriesChart> createState() => _SeriesChartState();
}

class _SeriesChartState extends State<SeriesChart> {
  final Set<String> _hidden = {};
  int? _hoverX;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final e = widget.encoding;
    final xCol = r.columns[r.colIndex(e.x!)];
    final xi = r.colIndex(e.x!);
    // catégories x dans l'ordre des lignes
    final xs = <String>[];
    final xVals = <dynamic>[];
    final seen = <String>{};
    for (final row in r.rows) {
      final k = '${row[xi]}';
      if (seen.add(k)) {
        xs.add(k);
        xVals.add(row[xi]);
      }
    }
    final series = <_Series>[];
    if (e.series != null) {
      final si = r.colIndex(e.series!);
      final sCol = r.columns[si];
      final m = r.columns[r.colIndex(e.y.first)];
      final mi = r.colIndex(m.key);
      final sVals = <String>[];
      final sSeen = <String>{};
      for (final row in r.rows) {
        final k = '${row[si]}';
        if (sSeen.add(k)) sVals.add(k);
      }
      for (var s = 0; s < sVals.length && s < 12; s++) {
        final vals = List<double?>.filled(xs.length, null);
        for (final row in r.rows) {
          if ('${row[si]}' == sVals[s]) {
            final xi2 = xs.indexOf('${row[xi]}');
            if (xi2 >= 0) vals[xi2] = row[mi] == null ? null : _toNum(row[mi]);
          }
        }
        series.add(_Series(r.labelOf(sCol, sVals[s]), seriesColor(s), vals, format: m.format));
      }
    } else {
      var ci = 0;
      for (final key in e.y) {
        final m = r.columns[r.colIndex(key)];
        final mi = r.colIndex(key);
        final vals = List<double?>.filled(xs.length, null);
        for (final row in r.rows) {
          final xi2 = xs.indexOf('${row[xi]}');
          if (xi2 >= 0) vals[xi2] = row[mi] == null ? null : _toNum(row[mi]);
        }
        series.add(_Series(m.label, seriesColor(ci), vals, format: m.format, secondary: e.secondary == key));
        final pi = r.colIndex('${key}_prev');
        if (pi >= 0 && e.showPrevious) {
          final pv = List<double?>.filled(xs.length, null);
          for (final row in r.rows) {
            final xi2 = xs.indexOf('${row[xi]}');
            if (xi2 >= 0) pv[xi2] = row[pi] == null ? null : _toNum(row[pi]);
          }
          series.add(_Series('${m.label} (préc.)', seriesColor(ci).withValues(alpha: 0.45), pv, format: m.format, dashed: true, secondary: e.secondary == key));
        }
        ci++;
      }
    }
    final visible = [
      for (final s in series)
        if (!_hidden.contains(s.label)) s,
    ];
    final labels = [for (final v in xVals) r.labelOf(xCol, v)];

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              return MouseRegion(
                onHover: (ev) {
                  final plotLeft = 56.0, plotRight = c.maxWidth - (visible.any((s) => s.secondary) ? 56 : 12);
                  final w = plotRight - plotLeft;
                  if (xs.isEmpty || w <= 0) return;
                  final idx = ((ev.localPosition.dx - plotLeft) / w * xs.length).floor().clamp(0, xs.length - 1);
                  if (idx != _hoverX) setState(() => _hoverX = idx);
                },
                onExit: (_) => setState(() => _hoverX = null),
                child: GestureDetector(
                  onTapUp: (d) {
                    if (widget.onDrill == null || _hoverX == null) return;
                    widget.onDrill!(xCol, xVals[_hoverX!]);
                  },
                  child: CustomPaint(
                    size: Size(c.maxWidth, c.maxHeight),
                    painter: _SeriesPainter(series: visible, labels: labels, line: widget.line, stacked: e.stacked && !widget.line, hover: _hoverX, showValues: e.showValues, compact: widget.compact),
                  ),
                ),
              );
            },
          ),
        ),
        if (series.length > 1 || _hoverX != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                for (final s in series)
                  InkWell(
                    onTap: () => setState(() => _hidden.contains(s.label) ? _hidden.remove(s.label) : _hidden.add(s.label)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: _hidden.contains(s.label) ? T.border : s.color, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _hoverX == null || s.values[_hoverX!] == null ? s.label : '${s.label} : ${fmtValue(s.values[_hoverX!], s.format)}',
                          style: T.small.copyWith(fontSize: 13, decoration: _hidden.contains(s.label) ? TextDecoration.lineThrough : null),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SeriesPainter extends CustomPainter {
  _SeriesPainter({required this.series, required this.labels, required this.line, required this.stacked, this.hover, this.showValues = false, this.compact = false});
  final List<_Series> series;
  final List<String> labels;
  final bool line, stacked, showValues, compact;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty || series.isEmpty) return;
    final hasSecondary = series.any((s) => s.secondary);
    final left = 56.0, right = size.width - (hasSecondary ? 56 : 12), top = 10.0, bottom = size.height - (compact ? 22 : 30);
    final w = right - left, h = bottom - top;
    if (w <= 10 || h <= 10) return;

    double maxOf(bool secondary) {
      var mx = 0.0, mn = 0.0;
      if (stacked && !secondary) {
        for (var i = 0; i < labels.length; i++) {
          var pos = 0.0, neg = 0.0;
          for (final s in series) {
            final v = s.values[i] ?? 0;
            if (v >= 0) {
              pos += v;
            } else {
              neg += v;
            }
          }
          mx = math.max(mx, pos);
          mn = math.min(mn, neg);
        }
      } else {
        for (final s in series) {
          if (s.secondary != secondary) continue;
          for (final v in s.values) {
            if (v == null) continue;
            mx = math.max(mx, v);
            mn = math.min(mn, v);
          }
        }
      }
      if (mx == 0 && mn == 0) mx = 1;
      return mx - mn;
    }

    final primaryMax = _nice(maxOf(false));
    final secondaryMax = hasSecondary ? _nice(maxOf(true)) : 1.0;
    final primaryMin = math.min(0.0, series.where((s) => !s.secondary).expand((s) => s.values).whereType<double>().fold(0.0, math.min));
    final range = primaryMax - primaryMin;
    double yOf(double v, bool secondary) {
      if (secondary) return bottom - (v / secondaryMax) * h;
      return bottom - ((v - primaryMin) / (range == 0 ? 1 : range)) * h;
    }

    // grille + axe Y
    final grid = Paint()
      ..color = T.border
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final fmt = series.firstWhere((s) => !s.secondary, orElse: () => series.first).format;
    for (var i = 0; i <= 4; i++) {
      final v = primaryMin + range * i / 4;
      final y = yOf(v, false);
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
      tp.text = TextSpan(text: fmtAxis(v, fmt), style: T.monoSmall.copyWith(fontSize: 13));
      tp.layout();
      tp.paint(canvas, Offset(left - tp.width - 6, y - tp.height / 2));
    }
    if (hasSecondary) {
      final sf = series.firstWhere((s) => s.secondary).format;
      for (var i = 0; i <= 4; i++) {
        final v = secondaryMax * i / 4;
        final y = yOf(v, true);
        tp.text = TextSpan(
          text: fmtAxis(v, sf),
          style: T.monoSmall.copyWith(fontSize: 13, color: T.faint),
        );
        tp.layout();
        tp.paint(canvas, Offset(right + 6, y - tp.height / 2));
      }
    }
    // survol
    final n = labels.length;
    final slot = w / n;
    if (hover != null) {
      canvas.drawRect(Rect.fromLTWH(left + hover! * slot, top, slot, h), Paint()..color = T.mintTint);
    }
    // libellés X (échantillonnés)
    final step = math.max(1, (n / (w / 64)).ceil());
    for (var i = 0; i < n; i += step) {
      tp.text = TextSpan(text: labels[i].length > 12 ? '${labels[i].substring(0, 11)}…' : labels[i], style: T.monoSmall.copyWith(fontSize: 13));
      tp.layout();
      tp.paint(canvas, Offset(left + i * slot + slot / 2 - tp.width / 2, bottom + 5));
    }
    final zeroY = yOf(0, false);
    if (line) {
      for (final s in series) {
        final path = Path();
        var started = false;
        final pts = <Offset>[];
        for (var i = 0; i < n; i++) {
          final v = s.values[i];
          if (v == null) {
            started = false;
            continue;
          }
          final p = Offset(left + i * slot + slot / 2, yOf(v, s.secondary));
          pts.add(p);
          if (!started) {
            path.moveTo(p.dx, p.dy);
            started = true;
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        final paint = Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.dashed ? 1.4 : 2.2
          ..strokeJoin = StrokeJoin.round;
        if (s.dashed) {
          _drawDashed(canvas, path, paint);
        } else {
          canvas.drawPath(path, paint);
          // remplissage léger sous la première série
          if (identical(s, series.first) && pts.length > 1) {
            final fill = Path.from(path)
              ..lineTo(pts.last.dx, bottom)
              ..lineTo(pts.first.dx, bottom)
              ..close();
            canvas.drawPath(fill, Paint()..color = s.color.withValues(alpha: 0.08));
          }
        }
        if (n <= 40 && !s.dashed) {
          for (final p in pts) {
            canvas.drawCircle(p, 2.6, Paint()..color = s.color);
          }
        }
      }
    } else {
      final groups = stacked ? 1 : series.where((s) => !s.dashed).length;
      final gap = slot * 0.18;
      final bw = (slot - gap) / math.max(1, groups);
      for (var i = 0; i < n; i++) {
        var posAcc = 0.0, negAcc = 0.0;
        var g = 0;
        for (final s in series) {
          if (s.dashed) continue;
          final v = s.values[i];
          if (v == null) {
            g++;
            continue;
          }
          double x0, x1, y0, y1;
          if (stacked) {
            x0 = left + i * slot + gap / 2;
            x1 = x0 + bw;
            if (v >= 0) {
              y0 = yOf(posAcc + v, false);
              y1 = yOf(posAcc, false);
              posAcc += v;
            } else {
              y0 = yOf(negAcc, false);
              y1 = yOf(negAcc + v, false);
              negAcc += v;
            }
          } else {
            x0 = left + i * slot + gap / 2 + g * bw;
            x1 = x0 + bw * 0.92;
            y0 = math.min(yOf(v, s.secondary), s.secondary ? yOf(0, true) : zeroY);
            y1 = math.max(yOf(v, s.secondary), s.secondary ? yOf(0, true) : zeroY);
          }
          final rect = RRect.fromRectAndCorners(Rect.fromLTRB(x0, y0, x1, y1), topLeft: const Radius.circular(3), topRight: const Radius.circular(3));
          canvas.drawRRect(rect, Paint()..color = hover == i ? s.color : s.color.withValues(alpha: 0.85));
          if (showValues && !stacked && n <= 24) {
            tp.text = TextSpan(
              text: fmtAxis(v, s.format),
              style: T.monoSmall.copyWith(fontSize: 12, color: T.muted),
            );
            tp.layout();
            tp.paint(canvas, Offset((x0 + x1) / 2 - tp.width / 2, y0 - tp.height - 2));
          }
          g++;
        }
      }
      // séries « précédentes » en barres : ligne pointillée par-dessus
      for (final s in series.where((s) => s.dashed)) {
        final path = Path();
        var started = false;
        for (var i = 0; i < n; i++) {
          final v = s.values[i];
          if (v == null) {
            started = false;
            continue;
          }
          final p = Offset(left + i * slot + slot / 2, yOf(v, s.secondary));
          if (!started) {
            path.moveTo(p.dx, p.dy);
            started = true;
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        _drawDashed(
          canvas,
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    }
    canvas.drawLine(
      Offset(left, zeroY),
      Offset(right, zeroY),
      Paint()
        ..color = T.border3
        ..strokeWidth = 1.2,
    );
  }

  static void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = math.min(d + 5, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + 4;
      }
    }
  }

  static double _nice(double v) {
    if (v <= 0) return 1;
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    final f = v / exp;
    final nf = f <= 1
        ? 1.0
        : f <= 2
        ? 2.0
        : f <= 2.5
        ? 2.5
        : f <= 5
        ? 5.0
        : 10.0;
    return nf * exp;
  }

  @override
  bool shouldRepaint(_SeriesPainter old) => true;
}

// ---------------------------------------------------------------- anneau

class DonutChart extends StatelessWidget {
  const DonutChart({super.key, required this.result, required this.encoding, this.compact = false, this.onDrill});
  final AResult result;
  final ChartEncoding encoding;
  final bool compact;
  final void Function(AColumn col, dynamic value)? onDrill;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final xCol = r.columns[r.colIndex(encoding.x!)];
    final xi = r.colIndex(encoding.x!);
    final m = r.columns[r.colIndex(encoding.y.first)];
    final mi = r.colIndex(m.key);
    final rows = r.rows.take(12).toList();
    final total = rows.fold<double>(0, (a, row) => a + math.max(0, _toNum(row[mi])));
    final slices = <(double, Color)>[];
    for (var i = 0; i < rows.length; i++) {
      slices.add((math.max(0, _toNum(rows[i][mi])), seriesColor(i)));
    }
    final size = compact ? 120.0 : 170.0;
    return Row(
      children: [
        Donut(
          slices: slices,
          size: size,
          center: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmtAxis(total, m.format), style: compact ? T.h2 : T.monoBig.copyWith(fontSize: 20)),
              Text('total', style: T.small.copyWith(fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < rows.length; i++)
                  InkWell(
                    onTap: onDrill == null ? null : () => onDrill!(xCol, rows[i][xi]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: seriesColor(i), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              r.labelOf(xCol, rows[i][xi]),
                              style: T.small.copyWith(color: T.ink, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(fmtValue(rows[i][mi], m.format), style: T.monoSmall.copyWith(color: T.ink)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 60,
                            child: Text(total == 0 ? '' : '${(_toNum(rows[i][mi]) / total * 100).toStringAsFixed(1).replaceAll('.', ',')} %', style: T.monoSmall, textAlign: TextAlign.end),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- tableau croisé

/// Tableau croisé d'investigation : tri par clic sur l'en-tête, recherche,
/// totaux, export, couleurs conditionnelles, clic sur une ligne = détail.
class PivotGrid extends StatefulWidget {
  const PivotGrid({super.key, required this.result, required this.encoding, this.compact = false, this.onDrill, this.title = 'Tableau croisé'});
  final AResult result;
  final ChartEncoding encoding;
  final bool compact;
  final void Function(AColumn col, dynamic value)? onDrill;
  final String title;

  @override
  State<PivotGrid> createState() => _PivotGridState();
}

class _PivotGridState extends State<PivotGrid> {
  final _search = TextEditingController();
  String _q = '';
  int? _sort; // -1 = libellé de ligne, sinon index de colonne de valeurs (totaux compris)
  bool _asc = false;
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final encoding = widget.encoding;
    final dims = r.dimensions;
    final colDim = r.columns[r.colIndex(encoding.series ?? dims.last.key)];
    final rowDims = [
      for (final d in dims)
        if (d.key != colDim.key) d,
    ];
    final meas = [for (final k in encoding.y) r.columns[r.colIndex(k)]];
    final ci = r.colIndex(colDim.key);
    final rowIdx = [for (final d in rowDims) r.colIndex(d.key)];
    final mIdx = [for (final m in meas) r.colIndex(m.key)];

    final colKeys = <String>[];
    final colVals = <dynamic>[];
    final cseen = <String>{};
    final rowKeys = <String>[];
    final rowVals = <List<dynamic>>[];
    final rseen = <String>{};
    final cells = <String, List<double>>{};
    for (final row in r.rows) {
      final ck = '${row[ci]}';
      if (cseen.add(ck)) {
        colKeys.add(ck);
        colVals.add(row[ci]);
      }
      final rv = [for (final i in rowIdx) row[i]];
      final rk = rv.join('|');
      if (rseen.add(rk)) {
        rowKeys.add(rk);
        rowVals.add(rv);
      }
      cells['$rk||$ck'] = [for (final i in mIdx) _toNum(row[i])];
    }
    if (colKeys.length > 60) return const EmptyState(icon: Icons.grid_on_rounded, text: 'Trop de colonnes pour un tableau croisé (60 au plus) — choisissez « Liste »');
    final nm = meas.length;
    final nc = colKeys.length;
    String rowLabel(int ri) => [for (var i = 0; i < rowDims.length; i++) r.labelOf(rowDims[i], rowVals[ri][i])].join(' · ');

    // valeurs par ligne : [col0 m0, col0 m1, …, total m0, total m1…]
    final values = <List<double?>>[];
    for (var ri = 0; ri < rowKeys.length; ri++) {
      final line = <double?>[];
      final tot = List<double>.filled(nm, 0);
      for (var cj = 0; cj < nc; cj++) {
        final v = cells['${rowKeys[ri]}||${colKeys[cj]}'];
        for (var k = 0; k < nm; k++) {
          line.add(v?[k]);
          if (v != null) tot[k] += v[k];
        }
      }
      line.addAll(tot);
      values.add(line);
    }
    // recherche + tri
    var order = [for (var i = 0; i < rowKeys.length; i++) i];
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      order = [
        for (final i in order)
          if (rowLabel(i).toLowerCase().contains(q)) i,
      ];
    }
    if (_sort != null) {
      final s = _sort!;
      order.sort((a, b) {
        final c = s < 0 ? _cmpCells(rowLabel(a), rowLabel(b)) : _cmpCells(values[a][s], values[b][s]);
        return _asc ? c : -c;
      });
    }
    // totaux de colonnes sur les lignes affichées
    final colTotals = List<double>.filled((nc + 1) * nm, 0);
    for (final ri in order) {
      for (var j = 0; j < (nc + 1) * nm; j++) {
        colTotals[j] += values[ri][j] ?? 0;
      }
    }
    // couleurs conditionnelles : statistiques par mesure sur les cellules du corps
    final stats = <int, CondStats>{};
    for (var k = 0; k < nm; k++) {
      final f = encoding.cond[meas[k].key];
      if (f == null || f.isEmpty) continue;
      final vs = <double>[
        for (final ri in order)
          for (var cj = 0; cj < nc; cj++)
            if (values[ri][cj * nm + k] != null) displayNum(values[ri][cj * nm + k], meas[k].format),
      ];
      stats[k] = CondStats(vs, f);
    }

    final cw = widget.compact ? 100.0 : 124.0;
    const rowW = 220.0;
    final rowH = widget.compact ? 30.0 : 36.0;
    final headerStyle = T.label.copyWith(color: T.ink, fontSize: 13, fontWeight: FontWeight.w700);
    final drillable = widget.onDrill != null && rowDims.length == 1;

    Widget hcell(String t, int sortIdx, {double? w, bool left = false}) => InkWell(
      onTap: () => setState(() {
        if (_sort == sortIdx) {
          _asc = !_asc;
        } else {
          _sort = sortIdx;
          _asc = sortIdx < 0;
        }
      }),
      child: Container(
        width: w ?? cw,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        color: T.bg,
        child: Row(
          mainAxisAlignment: left ? MainAxisAlignment.start : MainAxisAlignment.end,
          children: [
            Flexible(
              child: Text(t, style: headerStyle, textAlign: left ? TextAlign.left : TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (_sort == sortIdx) Icon(_asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: T.mintDark),
          ],
        ),
      ),
    );
    Widget vcell(double? v, int k, {bool bold = false, bool total = false}) {
      final m = meas[k];
      final look = total || v == null ? const CellLook() : condLook(encoding.cond[m.key], displayNum(v, m.format), stats[k]);
      return Container(
        decoration: BoxDecoration(
          color: total ? T.bg : null,
          border: const Border(bottom: BorderSide(color: T.border2)),
        ),
        child: CondCell(
          width: cw,
          height: rowH,
          text: v == null ? '—' : fmtValue(v, m.format),
          look: look,
          style: (bold ? T.monoBody.copyWith(fontWeight: FontWeight.w700) : T.monoBody).copyWith(fontSize: 13.5, color: v == null ? T.faint : T.ink),
        ),
      );
    }

    final header = Row(
      children: [
        hcell(rowDims.map((d) => d.label).join(' / '), -1, w: rowW, left: true),
        for (var cj = 0; cj < nc; cj++)
          for (var k = 0; k < nm; k++) hcell(nm == 1 ? r.labelOf(colDim, colVals[cj]) : '${r.labelOf(colDim, colVals[cj])}\n${meas[k].label}', cj * nm + k),
        for (var k = 0; k < nm; k++) hcell(nm == 1 ? 'Total' : 'Total ${meas[k].label}', nc * nm + k),
      ],
    );
    Widget bodyRow(int ri) => Row(
      children: [
        InkWell(
          onTap: drillable ? () => widget.onDrill!(rowDims.first, rowVals[ri][0]) : null,
          child: Container(
            width: rowW,
            height: rowH,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: T.border2)),
            ),
            child: Text(
              rowLabel(ri),
              style: T.body.copyWith(fontSize: 13.5, color: drillable ? T.mintDark : T.ink, fontWeight: drillable ? FontWeight.w600 : null),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        for (var cj = 0; cj < nc; cj++)
          for (var k = 0; k < nm; k++) vcell(values[ri][cj * nm + k], k),
        for (var k = 0; k < nm; k++) vcell(values[ri][nc * nm + k], k, bold: true),
      ],
    );
    final totalRow = Row(
      children: [
        Container(
          width: rowW,
          height: rowH,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: T.bg,
          child: Text('Total', style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
        for (var j = 0; j < (nc + 1) * nm; j++) vcell(meas[j % nm].isAdditive ? colTotals[j] : null, j % nm, bold: true, total: true),
      ],
    );
    final width = rowW + cw * (nc + 1) * nm;

    final table = Scrollbar(
      controller: _hScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _hScroll,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              header,
              Expanded(
                child: order.isEmpty
                    ? Center(child: Text('Aucune ligne ne correspond à « $_q »', style: T.bodyMuted))
                    : ListView.builder(itemCount: order.length, itemExtent: rowH, itemBuilder: (_, i) => bodyRow(order[i])),
              ),
              totalRow,
            ],
          ),
        ),
      ),
    );
    if (widget.compact) return table;

    Future<String> doExport(ExportFormat f) {
      final headers = [
        rowDims.map((d) => d.label).join(' / '),
        for (var cj = 0; cj < nc; cj++)
          for (var k = 0; k < nm; k++) nm == 1 ? r.labelOf(colDim, colVals[cj]) : '${r.labelOf(colDim, colVals[cj])} — ${meas[k].label}',
        for (var k = 0; k < nm; k++) nm == 1 ? 'Total' : 'Total ${meas[k].label}',
      ];
      final rows = <List<Object?>>[
        for (final ri in order) [rowLabel(ri), for (var j = 0; j < (nc + 1) * nm; j++) values[ri][j] == null ? null : _round2(displayNum(values[ri][j], meas[j % nm].format))],
      ];
      return exportTable(ExportTable(title: widget.title, baseName: 'tableau-croise', headers: headers, rows: rows, numeric: {for (var i = 1; i < headers.length; i++) i}), f);
    }

    return LayoutBuilder(
      builder: (context, o) {
        if (o.maxHeight < 140) return table; // trop petit pour la barre d'outils
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _TableSearch(controller: _search, onChanged: (v) => setState(() => _q = v.trim())),
                      Text(order.length == rowKeys.length ? '${rowKeys.length} ligne${rowKeys.length > 1 ? 's' : ''}' : '${order.length} sur ${rowKeys.length} lignes', style: T.bodyMuted),
                      if (drillable && o.maxWidth >= 760) Text('Cliquez une ligne pour voir son détail', style: T.small),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExportMenuButton(onExport: doExport),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: table),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------- liste

/// Liste d'investigation : tri par clic sur l'en-tête, recherche, ligne
/// « Total », nombre de lignes, export Excel/CSV/PDF, couleurs
/// conditionnelles, clic sur une valeur de regroupement = détail.
class ResultTable extends StatefulWidget {
  const ResultTable({super.key, required this.result, this.encoding, this.compact = false, this.onDrill, this.title = 'Analyse'});
  final AResult result;
  final ChartEncoding? encoding;
  final bool compact;
  final void Function(AColumn col, dynamic value)? onDrill;
  final String title;

  @override
  State<ResultTable> createState() => _ResultTableState();
}

class _ResultTableState extends State<ResultTable> {
  int? _sortCol;
  bool _asc = true;
  final _search = TextEditingController();
  String _q = '';
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _search.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final cols = r.columns;
    var rows = List.of(r.rows);
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      rows = [
        for (final row in rows)
          if ([
            for (var i = 0; i < cols.length; i++)
              if (cols[i].isDimension) r.labelOf(cols[i], row[i]),
          ].join(' ').toLowerCase().contains(q))
            row,
      ];
    }
    if (_sortCol != null) {
      final c = _sortCol!;
      rows.sort((a, b) {
        final cmp = cols[c].isDimension ? _cmpCells(r.labelOf(cols[c], a[c]), r.labelOf(cols[c], b[c])) : _cmpCells(a[c], b[c]);
        return _asc ? cmp : -cmp;
      });
    }
    final cond = widget.encoding?.cond ?? const <String, CondFormat>{};
    final stats = <int, CondStats>{};
    for (var i = 0; i < cols.length; i++) {
      final f = cond[cols[i].key];
      if (f == null || f.isEmpty || !cols[i].isMeasure) continue;
      stats[i] = CondStats([
        for (final row in rows)
          if (row[i] != null) displayNum(row[i], cols[i].format),
      ], f);
    }
    final hasTotals = rows.length > 1 && cols.any((c) => c.isAdditive);
    final totals = List<double>.filled(cols.length, 0);
    if (hasTotals) {
      for (final row in rows) {
        for (var i = 0; i < cols.length; i++) {
          if (cols[i].isAdditive) totals[i] += _toNum(row[i]);
        }
      }
    }
    final rowH = widget.compact ? 30.0 : 36.0;
    final firstDim = cols.indexWhere((c) => c.isDimension);

    final table = LayoutBuilder(
      builder: (context, c) {
        final base = [for (final col in cols) col.isDimension ? 200.0 : 140.0];
        final sum = base.fold<double>(0, (a, b) => a + b);
        final scale = c.maxWidth.isFinite && sum < c.maxWidth ? c.maxWidth / sum : 1.0;
        final widths = [for (final w in base) w * scale];
        final width = sum * scale;
        return Scrollbar(
          controller: _hScroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < cols.length; i++)
                        InkWell(
                          onTap: () => setState(() {
                            if (_sortCol == i) {
                              _asc = !_asc;
                            } else {
                              _sortCol = i;
                              _asc = cols[i].isDimension;
                            }
                          }),
                          child: Tooltip(
                            message: 'Trier par ${cols[i].label}',
                            waitDuration: const Duration(milliseconds: 600),
                            child: Container(
                              width: widths[i],
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                              color: T.bg,
                              child: Row(
                                mainAxisAlignment: cols[i].isDimension ? MainAxisAlignment.start : MainAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: Text(
                                      cols[i].label,
                                      style: T.label.copyWith(color: T.ink, fontSize: 13, fontWeight: FontWeight.w700),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (_sortCol == i) Icon(_asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: T.mintDark),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Expanded(
                    child: rows.isEmpty
                        ? Center(child: Text('Aucune ligne ne correspond à « $_q »', style: T.bodyMuted))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemExtent: rowH,
                            itemBuilder: (context, ri) {
                              final row = rows[ri];
                              return Container(
                                decoration: BoxDecoration(
                                  color: ri.isOdd ? T.bg.withValues(alpha: 0.6) : Colors.white,
                                  border: const Border(bottom: BorderSide(color: T.border2)),
                                ),
                                child: Row(
                                  children: [
                                    for (var i = 0; i < cols.length; i++)
                                      if (cols[i].isDimension)
                                        _dimCell(cols[i], row[i], widths[i], drill: widget.onDrill != null && (i == firstDim || cols.where((x) => x.isDimension).length > 1))
                                      else
                                        CondCell(
                                          width: widths[i],
                                          height: rowH,
                                          text: fmtValue(row[i], cols[i].format),
                                          look: row[i] == null ? const CellLook() : condLook(cond[cols[i].key], displayNum(row[i], cols[i].format), stats[i]),
                                          style: T.monoBody.copyWith(fontSize: 13.5, color: T.ink),
                                        ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  if (hasTotals && !widget.compact && c.maxHeight > 160)
                    Container(
                      decoration: const BoxDecoration(
                        color: T.bg,
                        border: Border(top: BorderSide(color: T.border3)),
                      ),
                      child: Row(
                        children: [
                          for (var i = 0; i < cols.length; i++)
                            Container(
                              width: widths[i],
                              height: rowH,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              alignment: cols[i].isDimension ? Alignment.centerLeft : Alignment.centerRight,
                              child: Text(
                                i == firstDim
                                    ? 'Total'
                                    : cols[i].isAdditive
                                    ? fmtValue(totals[i], cols[i].format)
                                    : '',
                                style: (cols[i].isDimension ? T.body : T.monoBody).copyWith(fontSize: 13.5, fontWeight: FontWeight.w700),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (widget.compact) return table;
    return LayoutBuilder(
      builder: (context, o) {
        if (o.maxHeight < 140) return table; // trop petit pour la barre d'outils
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (firstDim >= 0) _TableSearch(controller: _search, onChanged: (v) => setState(() => _q = v.trim())),
                      Text(rows.length == r.rows.length ? '${r.rows.length} ligne${r.rows.length > 1 ? 's' : ''}' : '${rows.length} sur ${r.rows.length} lignes', style: T.bodyMuted),
                      if (widget.onDrill != null && firstDim >= 0 && o.maxWidth >= 760) Text('Cliquez une valeur en vert pour voir son détail', style: T.small),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ExportMenuButton(onExport: (f) => exportResult(r, rows, widget.title, f)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: table),
          ],
        );
      },
    );
  }

  Widget _dimCell(AColumn col, dynamic v, double w, {required bool drill}) {
    final text = Text(
      widget.result.labelOf(col, v),
      style: T.body.copyWith(fontSize: 13.5, color: drill ? T.mintDark : T.ink, fontWeight: drill ? FontWeight.w600 : null),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final box = Container(width: w, padding: const EdgeInsets.symmetric(horizontal: 8), alignment: Alignment.centerLeft, child: text);
    if (!drill) return box;
    return InkWell(onTap: () => widget.onDrill!(col, v), child: box);
  }
}
