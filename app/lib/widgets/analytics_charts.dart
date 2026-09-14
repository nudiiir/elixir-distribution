import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/analytics_models.dart';
import '../theme/tokens.dart';
import 'charts.dart';
import 'ui.dart';

/// Palette des séries (marque en tête, puis des teintes lisibles côte à côte).
const kSeriesColors = <Color>[
  T.mint,
  Color(0xFF4A63B8),
  Color(0xFFE0A020),
  Color(0xFFB8556B),
  Color(0xFF7B61C9),
  Color(0xFF2FA0B8),
  Color(0xFFC97A1A),
  Color(0xFF6B8E23),
];

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

  ChartEncoding({this.x, this.series, List<String>? y, this.stacked = false, this.secondary, this.showValues = false, this.showPrevious = true})
      : y = y ?? [];

  factory ChartEncoding.fromJson(Map<String, dynamic> j) => ChartEncoding(
        x: j['x'] as String?,
        series: j['series'] as String?,
        y: [for (final e in (j['y'] as List? ?? const [])) '$e'],
        stacked: j['stacked'] == true,
        secondary: j['secondary'] as String?,
        showValues: j['show_values'] == true,
        showPrevious: j['show_previous'] != false,
      );

  Map<String, dynamic> toJson() => {
        if (x != null) 'x': x,
        if (series != null) 'series': series,
        'y': y,
        'stacked': stacked,
        if (secondary != null) 'secondary': secondary,
        'show_values': showValues,
        'show_previous': showPrevious,
      };

  /// Complète l'encodage avec des valeurs par défaut cohérentes avec le résultat.
  ChartEncoding resolved(AResult r) {
    final dims = r.dimensions;
    final meas = r.measures;
    final e = ChartEncoding(x: x, series: series, y: List.of(y), stacked: stacked, secondary: secondary, showValues: showValues, showPrevious: showPrevious);
    if (e.x == null || r.colIndex(e.x!) < 0) {
      e.x = dims.isNotEmpty ? dims.first.key : null;
    }
    if (e.series != null && (r.colIndex(e.series!) < 0 || e.series == e.x)) e.series = null;
    if (e.series == null && dims.length > 1) {
      e.series = dims.firstWhere((d) => d.key != e.x, orElse: () => dims[1]).key;
    }
    e.y = [for (final k in e.y) if (r.colIndex(k) >= 0) k];
    if (e.y.isEmpty) e.y = [for (final m in meas) m.key];
    if (e.secondary != null && !e.y.contains(e.secondary)) e.secondary = null;
    return e;
  }
}

const kChartTypes = ['stat', 'line', 'bar', 'donut', 'pivot', 'table'];
const kChartLabels = {'stat': 'Chiffre', 'line': 'Ligne', 'bar': 'Barres', 'donut': 'Anneau', 'pivot': 'Tableau croisé', 'table': 'Table'};
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
Widget buildChart(String type, AResult r, ChartEncoding enc, {bool compact = false, void Function(AColumn col, dynamic value)? onDrill}) {
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
      return PivotGrid(result: r, encoding: e);
  }
  return ResultTable(result: r, compact: compact);
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
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        MicroLabel(title ?? m.label, color: T.mintDark),
        const SizedBox(height: 8),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(fmtValue(row[i], m.format), style: T.monoBig)),
        if (prevI >= 0 && row[prevI] != null) ...[
          const SizedBox(height: 4),
          Text('${_toNum(row[prevI]) >= 0 ? '▲' : '▼'} ${fmtValue(row[prevI], 'percent')} vs période préc.',
              style: T.small.copyWith(color: _toNum(row[prevI]) >= 0 ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w600)),
        ] else if (title != null && title != m.label) ...[
          const SizedBox(height: 4),
          Text(m.label, style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ]);
    }
    if (flat) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        if (title != null) MicroLabel(title!, color: T.mintDark),
        const SizedBox(height: 6),
        Row(children: [
          for (final m in r.measures) ...[
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(fmtValue(row[r.colIndex(m.key)], m.format), style: T.h2.copyWith(fontSize: 20))),
                Text(m.label, style: T.small.copyWith(fontSize: 10.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ],
        ]),
      ]);
    }
    final tiles = <Widget>[];
    for (final m in r.measures) {
      final i = r.colIndex(m.key);
      final prevI = r.colIndex('${m.key}_delta_pct');
      tiles.add(Container(
        constraints: BoxConstraints(minWidth: compact ? 120 : 160),
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(color: T.bg, borderRadius: BorderRadius.circular(T.rInner), border: Border.all(color: T.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          MicroLabel(m.label, color: T.mintDark),
          const SizedBox(height: 6),
          Text(fmtValue(row[i], m.format), style: compact ? T.h2 : T.monoBig),
          if (prevI >= 0 && row[prevI] != null) ...[
            const SizedBox(height: 4),
            Text('${_toNum(row[prevI]) >= 0 ? '▲' : '▼'} ${fmtValue(row[prevI], 'percent')} vs période préc.',
                style: T.small.copyWith(color: _toNum(row[prevI]) >= 0 ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w600)),
          ],
        ]),
      ));
    }
    return SingleChildScrollView(
      child: Wrap(spacing: 10, runSpacing: 10, children: tiles),
    );
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
    final visible = [for (final s in series) if (!_hidden.contains(s.label)) s];
    final labels = [for (final v in xVals) r.labelOf(xCol, v)];

    return Column(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
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
        }),
      ),
      if (series.length > 1 || _hoverX != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 12, runSpacing: 4, alignment: WrapAlignment.center, children: [
            for (final s in series)
              InkWell(
                onTap: () => setState(() => _hidden.contains(s.label) ? _hidden.remove(s.label) : _hidden.add(s.label)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: _hidden.contains(s.label) ? T.border : s.color, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(
                    _hoverX == null || s.values[_hoverX!] == null ? s.label : '${s.label} : ${fmtValue(s.values[_hoverX!], s.format)}',
                    style: T.small.copyWith(fontSize: 11, decoration: _hidden.contains(s.label) ? TextDecoration.lineThrough : null),
                  ),
                ]),
              ),
          ]),
        ),
    ]);
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
      tp.text = TextSpan(text: fmtAxis(v, fmt), style: T.monoSmall.copyWith(fontSize: 9.5));
      tp.layout();
      tp.paint(canvas, Offset(left - tp.width - 6, y - tp.height / 2));
    }
    if (hasSecondary) {
      final sf = series.firstWhere((s) => s.secondary).format;
      for (var i = 0; i <= 4; i++) {
        final v = secondaryMax * i / 4;
        final y = yOf(v, true);
        tp.text = TextSpan(text: fmtAxis(v, sf), style: T.monoSmall.copyWith(fontSize: 9.5, color: T.faint));
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
      tp.text = TextSpan(text: labels[i].length > 12 ? '${labels[i].substring(0, 11)}…' : labels[i], style: T.monoSmall.copyWith(fontSize: 9.5));
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
            tp.text = TextSpan(text: fmtAxis(v, s.format), style: T.monoSmall.copyWith(fontSize: 9, color: T.muted));
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
        _drawDashed(canvas, path, Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
      }
    }
    canvas.drawLine(Offset(left, zeroY), Offset(right, zeroY), Paint()
      ..color = T.border3
      ..strokeWidth = 1.2);
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
    final nf = f <= 1 ? 1.0 : f <= 2 ? 2.0 : f <= 2.5 ? 2.5 : f <= 5 ? 5.0 : 10.0;
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
    return Row(children: [
      Donut(
        slices: slices,
        size: size,
        center: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(fmtAxis(total, m.format), style: compact ? T.h2 : T.monoBig.copyWith(fontSize: 20)),
          Text('total', style: T.small.copyWith(fontSize: 10)),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < rows.length; i++)
              InkWell(
                onTap: onDrill == null ? null : () => onDrill!(xCol, rows[i][xi]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: seriesColor(i), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(r.labelOf(xCol, rows[i][xi]), style: T.small.copyWith(color: T.ink, fontSize: 11.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 6),
                    Text(fmtValue(rows[i][mi], m.format), style: T.monoSmall.copyWith(color: T.ink)),
                    const SizedBox(width: 6),
                    SizedBox(width: 44, child: Text(total == 0 ? '' : '${(_toNum(rows[i][mi]) / total * 100).toStringAsFixed(1).replaceAll('.', ',')} %', style: T.monoSmall, textAlign: TextAlign.end)),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- tableau croisé

class PivotGrid extends StatelessWidget {
  const PivotGrid({super.key, required this.result, required this.encoding});
  final AResult result;
  final ChartEncoding encoding;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final dims = r.dimensions;
    final colDim = r.columns[r.colIndex(encoding.series ?? dims.last.key)];
    final rowDims = [for (final d in dims) if (d.key != colDim.key) d];
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
    if (colKeys.length > 60) return const EmptyState(icon: Icons.grid_on_rounded, text: 'Trop de colonnes pour un tableau croisé (60 max) — passez en table');
    final nm = meas.length;
    final colTotals = List<double>.filled(colKeys.length * nm, 0);
    final grand = List<double>.filled(nm, 0);
    final rowTotals = <List<double>>[];
    for (var ri = 0; ri < rowKeys.length; ri++) {
      final tot = List<double>.filled(nm, 0);
      for (var cj = 0; cj < colKeys.length; cj++) {
        final v = cells['${rowKeys[ri]}||${colKeys[cj]}'];
        if (v == null) continue;
        for (var k = 0; k < nm; k++) {
          tot[k] += v[k];
          colTotals[cj * nm + k] += v[k];
          grand[k] += v[k];
        }
      }
      rowTotals.add(tot);
    }
    const cw = 108.0;
    final headerStyle = T.label.copyWith(color: T.ink, fontSize: 9.5);
    Widget hcell(String t, {double w = cw, bool left = false}) => Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          color: T.bg,
          child: Text(t, style: headerStyle, textAlign: left ? TextAlign.left : TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis),
        );
    Widget vcell(double v, String format, {bool bold = false, double w = cw}) => Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: T.border2))),
          child: Text(fmtValue(v, format), style: (bold ? T.monoBody.copyWith(fontWeight: FontWeight.w700) : T.monoBody).copyWith(fontSize: 11.5), textAlign: TextAlign.end),
        );
    final rowW = 200.0;
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              hcell(rowDims.map((d) => d.label).join(' / '), w: rowW, left: true),
              for (final cv in colVals) for (final m in meas) hcell(nm == 1 ? r.labelOf(colDim, cv) : '${r.labelOf(colDim, cv)}\n${m.label}'),
              for (final m in meas) hcell(nm == 1 ? 'Total' : 'Total ${m.label}'),
            ]),
            for (var ri = 0; ri < rowKeys.length; ri++)
              Row(children: [
                Container(
                  width: rowW,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: T.border2))),
                  child: Text([for (var i = 0; i < rowDims.length; i++) r.labelOf(rowDims[i], rowVals[ri][i])].join(' · '), style: T.body.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                for (var cj = 0; cj < colKeys.length; cj++)
                  for (var k = 0; k < nm; k++) vcell(cells['${rowKeys[ri]}||${colKeys[cj]}']?[k] ?? 0, meas[k].format),
                for (var k = 0; k < nm; k++) vcell(rowTotals[ri][k], meas[k].format, bold: true),
              ]),
            Row(children: [
              Container(width: rowW, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), color: T.bg, child: Text('Total', style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 12))),
              for (var cj = 0; cj < colKeys.length; cj++) for (var k = 0; k < nm; k++) Container(color: T.bg, child: vcell(colTotals[cj * nm + k], meas[k].format, bold: true)),
              for (var k = 0; k < nm; k++) Container(color: T.bg, child: vcell(grand[k], meas[k].format, bold: true)),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- table

class ResultTable extends StatefulWidget {
  const ResultTable({super.key, required this.result, this.compact = false});
  final AResult result;
  final bool compact;

  @override
  State<ResultTable> createState() => _ResultTableState();
}

class _ResultTableState extends State<ResultTable> {
  int? _sortCol;
  bool _asc = true;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    var rows = List.of(r.rows);
    if (_sortCol != null) {
      final c = _sortCol!;
      rows.sort((a, b) {
        final va = a[c], vb = b[c];
        int cmp;
        if (va is num && vb is num) {
          cmp = va.compareTo(vb);
        } else {
          cmp = '${va ?? ''}'.compareTo('${vb ?? ''}');
        }
        return _asc ? cmp : -cmp;
      });
    }
    final widths = [for (final c in r.columns) c.isDimension ? 180.0 : 120.0];
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: widths.fold<double>(0.0, (a, b) => a + b),
          child: Column(children: [
            Row(children: [
              for (var i = 0; i < r.columns.length; i++)
                InkWell(
                  onTap: () => setState(() {
                    if (_sortCol == i) {
                      _asc = !_asc;
                    } else {
                      _sortCol = i;
                      _asc = r.columns[i].isDimension;
                    }
                  }),
                  child: Container(
                    width: widths[i],
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    color: T.bg,
                    child: Row(mainAxisAlignment: r.columns[i].isDimension ? MainAxisAlignment.start : MainAxisAlignment.end, children: [
                      Flexible(child: Text(r.columns[i].label, style: T.label.copyWith(color: T.ink, fontSize: 9.5), maxLines: 2, overflow: TextOverflow.ellipsis)),
                      if (_sortCol == i) Icon(_asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 14, color: T.mintDark),
                    ]),
                  ),
                ),
            ]),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemExtent: widget.compact ? 28 : 32,
                itemBuilder: (context, ri) => Container(
                  decoration: BoxDecoration(color: ri.isOdd ? T.bg.withValues(alpha: 0.6) : Colors.white, border: Border(bottom: BorderSide(color: T.border2))),
                  child: Row(children: [
                    for (var i = 0; i < r.columns.length; i++)
                      Container(
                        width: widths[i],
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: r.columns[i].isDimension ? Alignment.centerLeft : Alignment.centerRight,
                        child: Text(
                          r.columns[i].isDimension ? r.labelOf(r.columns[i], rows[ri][i]) : fmtValue(rows[ri][i], r.columns[i].format),
                          style: (r.columns[i].isDimension ? T.body : T.monoBody).copyWith(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
