import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
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
  Map<String, dynamic> _summary = const {};
  List<BreakdownRow> _rows = const [];
  bool _loading = true;

  bool get _viewCost => widget.session.user.can('view_cost');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month, now.day);
    _load();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() => _loading = true);
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
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _num(String k) => (_summary[k] as num?)?.toInt() ?? 0;

  Future<void> _preset(int daysBack, {bool month = false, bool year = false}) async {
    final now = DateTime.now();
    setState(() {
      _to = DateTime(now.year, now.month, now.day);
      if (year) {
        _from = DateTime(now.year, 1, 1);
      } else if (month) {
        _from = DateTime(now.year, now.month, 1);
      } else {
        _from = _to.subtract(Duration(days: daysBack));
      }
    });
    _load();
  }

  Future<void> _pickDate(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        if (isFrom) {
          _from = DateTime(d.year, d.month, d.day);
          if (_to.isBefore(_from)) _to = _from;
        } else {
          _to = DateTime(d.year, d.month, d.day);
          if (_from.isAfter(_to)) _from = _to;
        }
      });
      _load();
    }
  }

  String _labelFor(BreakdownRow r) {
    if (_by == 'hour') return '${r.label}h';
    if (_by == 'payment') return _paymentNames[r.label] ?? r.label;
    return r.label;
  }

  Future<void> _export() async {
    final path = await exportCsv(
      baseName: 'rapport-$_by',
      headers: [
        'Libellé',
        'Documents',
        if (_by == 'category' || _by == 'product') 'Quantité',
        'Total HT (DA)',
        'Total TTC (DA)',
        if (_viewCost && (_by == 'category' || _by == 'product')) 'Marge (DA)',
      ],
      rows: [
        for (final r in _rows)
          [
            _labelFor(r),
            '${r.count}',
            if (_by == 'category' || _by == 'product') fmtQty(r.qtyMilli),
            editDA(r.totalHT),
            editDA(r.totalTTC),
            if (_viewCost && (_by == 'category' || _by == 'product'))
              editDA(r.margin ?? 0),
          ]
      ],
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Text('Exporté : $path',
            style: const TextStyle(
                fontFamily: T.mono, fontSize: 12, color: Colors.white)),
      ));
    }
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
          const Spacer(),
          for (final (label, action) in [
            ("Aujourd'hui", () => _preset(0)),
            ('7 jours', () => _preset(6)),
            ('Ce mois', () => _preset(0, month: true)),
            ('Cette année', () => _preset(0, year: true)),
          ])
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: _Pill(label: label, onTap: action),
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
          _SumCard(label: 'Chiffre d\'affaires TTC', value: fmtDA(_num('ca_ttc')), loading: _loading),
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
              value: fmtDA(_num('vat')),
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
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: _Pill(
                label: label,
                selected: _by == key,
                onTap: () {
                  setState(() => _by = key);
                  _load();
                },
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: _rows.isEmpty ? null : _export,
            icon: const Icon(Icons.download_outlined, size: 14, color: T.muted),
            label: Text('Exporter CSV',
                style: T.small.copyWith(color: T.muted)),
          ),
        ]),
        const SizedBox(height: 10),
        Expanded(
          child: Card14(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: _rows.isEmpty
                ? EmptyState(
                    icon: Icons.query_stats_rounded,
                    text: _loading
                        ? 'Chargement…'
                        : 'Aucune vente sur la période')
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        const Expanded(flex: 3, child: MicroLabel('Libellé')),
                        const SizedBox(
                            width: 70,
                            child: MicroLabel('Docs')),
                        if (_by == 'category' || _by == 'product')
                          const SizedBox(width: 80, child: MicroLabel('Qté')),
                        const SizedBox(
                            width: 120, child: MicroLabel('Total HT')),
                        const SizedBox(
                            width: 130, child: MicroLabel('Total TTC')),
                        if (showMargin)
                          const SizedBox(
                              width: 110, child: MicroLabel('Marge')),
                        const Expanded(flex: 2, child: SizedBox()),
                      ]),
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) {
                          final r = _rows[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(children: [
                              Expanded(
                                  flex: 3,
                                  child: Text(_labelFor(r),
                                      style: T.body.copyWith(fontSize: 12.5),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              SizedBox(
                                  width: 70,
                                  child: Text('${r.count}',
                                      style: T.monoSmall)),
                              if (_by == 'category' || _by == 'product')
                                SizedBox(
                                    width: 80,
                                    child: Text(fmtQty(r.qtyMilli),
                                        style: T.monoSmall)),
                              SizedBox(
                                  width: 120,
                                  child: Text(fmtDA(r.totalHT),
                                      style: T.monoSmall)),
                              SizedBox(
                                  width: 130,
                                  child: Text(fmtDA(r.totalTTC),
                                      style: T.monoBody
                                          .copyWith(fontSize: 12))),
                              if (showMargin)
                                SizedBox(
                                    width: 110,
                                    child: Text(fmtDA(r.margin ?? 0),
                                        style: T.monoSmall.copyWith(
                                            color: (r.margin ?? 0) < 0
                                                ? T.dangerDark
                                                : T.mintDark))),
                              Expanded(
                                flex: 2,
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                      start: 10),
                                  child: _MiniBar(
                                      ratio: maxTTC == 0
                                          ? 0
                                          : r.totalTTC / maxTTC),
                                ),
                              ),
                            ]),
                          );
                        },
                      ),
                    ),
                  ]),
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
        height: 84,
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
                  T.label.copyWith(color: accent ?? T.mintDeep, fontSize: 9)),
          const Spacer(),
          Text(loading ? '—' : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: T.sans,
                  fontSize: 17,
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
              fontSize: 12,
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
