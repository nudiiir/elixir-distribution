import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/analysis_links.dart';
import '../util/prefs.dart';
import '../widgets/analyze_button.dart';
import '../widgets/data_table.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/ui.dart';

const _tabs = [
  ('day', 'Par jour'),
  ('hour', 'Par heure'),
  ('category', 'Par catégorie'),
  ('product', 'Par produit'),
  ('user', 'Par vendeur'),
  ('payment', 'Par paiement'),
];

const _paymentNames = {
  'cash': 'Espèces',
  'cib': 'Carte CIB',
  'edahabia': 'Edahabia',
  'cheque': 'Chèque',
  'transfer': 'Virement',
  'credit': 'Crédit',
  'autre': 'Autre (cadeau…)',
};

/// Rapports: CA, marges, TVA et ventilations sur une période.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.api, required this.session});
  final ApiClient api;
  final Session session;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late DateTime _from;
  late DateTime _to;
  String _by = 'day';
  String _period = 'month'; // today | 7d | month | year | custom
  Map<String, dynamic> _summary = const {};
  List<BreakdownRow> _rows = const [];
  bool _loading = true;
  String? _error;

  bool get _viewCost => widget.session.user.can('view_cost');

  @override
  void initState() {
    super.initState();
    _by = UiPrefs.instance.get<String>('reports', 'by') ?? 'day';
    if (!_tabs.any((t) => t.$1 == _by)) _by = 'day';
    _period = UiPrefs.instance.get<String>('reports', 'period') ?? 'month';
    _applyPeriod(_period);
    if (_period == 'custom') {
      final f = DateTime.tryParse(UiPrefs.instance.get<String>('reports', 'from') ?? '');
      final t = DateTime.tryParse(UiPrefs.instance.get<String>('reports', 'to') ?? '');
      if (f != null && t != null) {
        _from = f;
        _to = t;
      }
    }
    _load();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.reportSummary(from: _iso(_from), to: _iso(_to)),
        widget.api.reportBreakdown(from: _iso(_from), to: _iso(_to), by: _by),
      ]);
      if (mounted) {
        setState(() {
          _summary = results[0] as Map<String, dynamic>;
          _rows = results[1] as List<BreakdownRow>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Rapport indisponible : $e';
        });
      }
    }
  }

  int _num(String k) => (_summary[k] as num?)?.toInt() ?? 0;

  void _applyPeriod(String p) {
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    switch (p) {
      case 'today':
        _from = _to;
      case '7d':
        _from = _to.subtract(const Duration(days: 6));
      case 'year':
        _from = DateTime(now.year, 1, 1);
      default:
        _from = DateTime(now.year, now.month, 1);
    }
  }

  Future<void> _preset(String p) async {
    setState(() {
      _period = p;
      _applyPeriod(p);
    });
    UiPrefs.instance.set('reports', 'period', p);
    _load();
  }

  /// Sort key keeping hours and dates in their natural order.
  Comparable _sortLabel(BreakdownRow r) =>
      _by == 'hour' ? (int.tryParse(r.label) ?? 0) : _labelFor(r).toLowerCase();

  Future<void> _pickDate(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        _period = 'custom';
        if (isFrom) {
          _from = DateTime(d.year, d.month, d.day);
          if (_to.isBefore(_from)) _to = _from;
        } else {
          _to = DateTime(d.year, d.month, d.day);
          if (_from.isAfter(_to)) _from = _to;
        }
      });
      UiPrefs.instance.set('reports', 'period', 'custom');
      UiPrefs.instance.set('reports', 'from', _iso(_from));
      UiPrefs.instance.set('reports', 'to', _iso(_to));
      _load();
    }
  }

  String _labelFor(BreakdownRow r) {
    if (_by == 'hour') return '${r.label}h';
    if (_by == 'payment') return _paymentNames[r.label] ?? r.label;
    return r.label;
  }

  @override
  Widget build(BuildContext context) {
    final showMargin =
        _viewCost && (_by == 'category' || _by == 'product');
    final maxTTC = _rows.fold<int>(0, (m, r) => r.totalTTC > m ? r.totalTTC : m);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Rapports', style: T.h1),
          AnalyzeButton(label: 'Explorer plus loin', seeds: [
            AnalysisLinks.sales(),
            AnalysisLinks.purchases(),
            AnalysisLinks.receivables(),
            AnalysisLinks.stock(),
          ]),
          const Spacer(),
          for (final (key, label) in const [
            ('today', "Aujourd'hui"),
            ('7d', '7 jours'),
            ('month', 'Ce mois'),
            ('year', 'Cette année'),
          ])
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: _Pill(
                  label: label,
                  selected: _period == key,
                  onTap: () => _preset(key)),
            ),
          const SizedBox(width: 10),
          _DateChip(label: _iso(_from), onTap: () => _pickDate(true)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('→', style: T.small),
          ),
          _DateChip(label: _iso(_to), onTap: () => _pickDate(false)),
        ]),
        const SizedBox(height: 16),
        // ---- Summary cards ----
        Row(children: [
          // net : avoirs déduits, timbre exclu (taxe, pas du chiffre d'affaires)
          _SumCard(label: 'CA net TTC', value: fmtDA(_num('net_ca_ttc')), loading: _loading),
          const SizedBox(width: 12),
          _SumCard(label: 'Tickets / factures', value: '${_num('tickets')}', loading: _loading),
          const SizedBox(width: 12),
          _SumCard(label: 'Panier moyen', value: fmtDA(_num('avg_ticket')), loading: _loading),
          if (_viewCost) ...[
            const SizedBox(width: 12),
            _SumCard(
                label: 'Marge brute',
                value: fmtDA(_num('margin')),
                accent: T.mintDeep,
                loading: _loading),
          ],
          const SizedBox(width: 12),
          _SumCard(
              label: 'TVA collectée',
              value: fmtDA(_num('net_vat')),
              loading: _loading),
          const SizedBox(width: 12),
          _SumCard(
              label: 'Retours (avoirs)',
              value: fmtDA(_num('refunds')),
              accent: _num('refunds') > 0 ? T.dangerDark : null,
              loading: _loading),
        ]),
        const SizedBox(height: 16),
        // ---- Breakdown ----
        Row(children: [
          for (final (key, label) in _tabs)
            FilterPill(
              label: label,
              active: _by == key,
              onTap: () {
                setState(() => _by = key);
                UiPrefs.instance.set('reports', 'by', key);
                _load();
              },
            ),
        ]),
        const SizedBox(height: 10),
        Expanded(
          child: DataListView<BreakdownRow>(
            key: ValueKey('reports-$_by'),
            items: _rows,
            loading: _loading,
            error: _error,
            onRetry: _load,
            prefsKey: 'reports_$_by',
            exportTitle: 'Rapport ${_tabs.firstWhere((t) => t.$1 == _by).$2.toLowerCase()} '
                '· ${_iso(_from)} → ${_iso(_to)}',
            exportBaseName: 'rapport-$_by',
            empty: const EmptyState(
                icon: Icons.query_stats_rounded,
                text: 'Aucune vente sur la période'),
            aggregates: (rows) => [
              ('Total HT', fmtDA(rows.fold<int>(0, (s, r) => s + r.totalHT))),
              ('Total TTC', fmtDA(rows.fold<int>(0, (s, r) => s + r.totalTTC))),
              if (showMargin)
                ('Marge', fmtDA(rows.fold<int>(0, (s, r) => s + (r.margin ?? 0)))),
            ],
            columns: [
              ColumnSpec<BreakdownRow>(
                label: 'Libellé',
                flex: 3,
                hideable: false,
                sortKey: (r) => _sortLabel(r),
                exportValue: _labelFor,
                cell: (_, r) => Text(_labelFor(r),
                    style: T.body.copyWith(fontSize: 13.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec<BreakdownRow>(
                label: 'Docs',
                width: 70,
                numeric: true,
                sortKey: (r) => r.count,
                exportValue: (r) => r.count,
                cell: (_, r) => Text('${r.count}', style: T.monoSmall),
              ),
              if (_by == 'category' || _by == 'product')
                ColumnSpec<BreakdownRow>(
                  label: 'Qté',
                  width: 90,
                  numeric: true,
                  sortKey: (r) => r.qtyMilli,
                  exportValue: (r) => r.qtyMilli / 1000,
                  cell: (_, r) => Text(fmtQty(r.qtyMilli), style: T.monoSmall),
                ),
              ColumnSpec<BreakdownRow>(
                label: 'Total HT',
                width: 120,
                numeric: true,
                sortKey: (r) => r.totalHT,
                exportValue: (r) => r.totalHT / 100,
                cell: (_, r) => Text(fmtDA(r.totalHT), style: T.monoSmall),
              ),
              ColumnSpec<BreakdownRow>(
                label: 'Total TTC',
                width: 130,
                numeric: true,
                sortKey: (r) => r.totalTTC,
                exportValue: (r) => r.totalTTC / 100,
                cell: (_, r) => Text(fmtDA(r.totalTTC),
                    style: T.monoBody.copyWith(fontSize: 13)),
              ),
              if (showMargin)
                ColumnSpec<BreakdownRow>(
                  label: 'Marge',
                  width: 110,
                  numeric: true,
                  sortKey: (r) => r.margin ?? 0,
                  exportValue: (r) => (r.margin ?? 0) / 100,
                  cell: (_, r) => Text(fmtDA(r.margin ?? 0),
                      style: T.monoSmall.copyWith(
                          color: (r.margin ?? 0) < 0 ? T.dangerDark : T.mintDark)),
                ),
              ColumnSpec<BreakdownRow>(
                label: 'Part',
                flex: 2,
                cell: (_, r) => Padding(
                  padding: const EdgeInsetsDirectional.only(start: 10),
                  child: _MiniBar(ratio: maxTTC == 0 ? 0 : r.totalTTC / maxTTC),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.ratio});
  final double ratio;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: ratio.clamp(0.0, 1.0),
        child: Container(
          height: 6,
          decoration: BoxDecoration(
            color: T.mint,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

class _SumCard extends StatelessWidget {
  const _SumCard(
      {required this.label,
      required this.value,
      this.accent,
      this.loading = false});
  final String label;
  final String value;
  final Color? accent;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 92,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rCard),
          border: Border.all(color: T.border),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  T.label.copyWith(color: accent ?? T.mintDeep, fontSize: 13)),
          const Spacer(),
          Text(loading ? '—' : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: T.sans,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: T.ink)),
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap, this.selected = false});
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? T.ink : T.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? T.ink : T.border),
        ),
        child: Text(label,
            style: TextStyle(
              fontFamily: T.sans,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : T.muted,
            )),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: T.border),
        ),
        child: Text(label, style: T.monoSmall.copyWith(color: T.ink)),
      ),
    );
  }
}
