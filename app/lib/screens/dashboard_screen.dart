import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../widgets/charts.dart';
import '../widgets/doc_list.dart' show docTypeLabels, StatusChip;
import '../widgets/ui.dart';

const _monthShort = [
  'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
  'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc'
];

class _LowStock {
  _LowStock(this.name, this.qtyMilli);
  final String name;
  final int qtyMilli;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.api,
    required this.session,
    required this.onNavigate,
  });
  final ApiClient api;
  final Session session;
  final ValueChanged<String> onNavigate;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String? _error;

  bool get _viewCost => widget.session.user.can('view_cost');

  int _stockValue = 0;
  int _refCount = 0;
  int _salesToday = 0;
  int _ticketsToday = 0;
  List<double> _salesSpark = const [];
  List<double> _ticketsSpark = const [];
  List<(String, double)> _monthlySales = const [];
  List<(double, Color)> _donut = const [];
  List<(String, Color, String)> _donutLegend = const [];
  List<_LowStock> _lowStock = const [];
  List<StockMovement> _movements = const [];
  List<Partner> _debtors = const [];
  List<DocSummary> _recent = const [];

  static const _donutColors = [
    T.mint,
    Color(0xFF66E0C2),
    Color(0xFFB3F0E0),
    Color(0xFFDCF5EE),
    Color(0xFFD8DBD9),
  ];

  @override
  void initState() {
    super.initState();
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
      final now = DateTime.now();
      final from180 = _iso(now.subtract(const Duration(days: 180)));
      final results = await Future.wait([
        widget.api.stockLevels(),
        widget.api.products(limit: 500),
        widget.api.documents(
            type: 'SALE_TICKET', status: 'posted', from: from180, limit: 500),
        widget.api.documents(
            type: 'SALE_INVOICE', status: 'posted', from: from180, limit: 500),
        widget.api.stockMovements(limit: 8),
        widget.api.partners(kind: 'customer', limit: 500),
        widget.api.documents(limit: 7),
      ]);
      final levels = results[0] as List<StockLevel>;
      final products = results[1] as List<Product>;
      final sales = [
        ...results[2] as List<DocSummary>,
        ...results[3] as List<DocSummary>,
      ];

      // --- Stock cards + donut + alerts ---
      final stockValue = levels.fold(0, (s, l) => s + l.valuation);
      final minByProduct = {
        for (final p in products) p.id: p.minStockMilli,
      };
      final low = <_LowStock>[];
      for (final l in levels) {
        final min = minByProduct[l.productId] ?? 0;
        if (l.qtyMilli <= 0 || (min > 0 && l.qtyMilli <= min)) {
          low.add(_LowStock(l.productName, l.qtyMilli));
        }
      }
      low.sort((a, b) => a.qtyMilli.compareTo(b.qtyMilli));

      final byValue = [...levels]
        ..sort((a, b) => b.valuation.compareTo(a.valuation));
      final top = byValue.take(4).toList();
      final rest = byValue.skip(4).fold(0, (s, l) => s + l.valuation);
      final donut = <(double, Color)>[];
      final legend = <(String, Color, String)>[];
      for (var i = 0; i < top.length; i++) {
        donut.add((top[i].valuation.toDouble(), _donutColors[i]));
        final pct =
            stockValue > 0 ? (top[i].valuation * 100 ~/ stockValue) : 0;
        legend.add((top[i].productName, _donutColors[i], '$pct%'));
      }
      if (rest > 0) {
        donut.add((rest.toDouble(), _donutColors[4]));
        final pct = stockValue > 0 ? (rest * 100 ~/ stockValue) : 0;
        legend.add(('Autres', _donutColors[4], '$pct%'));
      }

      // --- Sales aggregations ---
      final today = _iso(now);
      var salesToday = 0, ticketsToday = 0;
      final dailyTTC = <String, int>{};
      final dailyCount = <String, int>{};
      final monthlyTTC = <String, int>{};
      for (final d in sales) {
        if (d.docDate == today) {
          salesToday += d.totalTTC;
          ticketsToday++;
        }
        dailyTTC[d.docDate] = (dailyTTC[d.docDate] ?? 0) + d.totalTTC;
        dailyCount[d.docDate] = (dailyCount[d.docDate] ?? 0) + 1;
        if (d.docDate.length >= 7) {
          final m = d.docDate.substring(0, 7);
          monthlyTTC[m] = (monthlyTTC[m] ?? 0) + d.totalTTC;
        }
      }
      final spark = <double>[];
      final sparkCount = <double>[];
      for (var i = 13; i >= 0; i--) {
        final day = _iso(now.subtract(Duration(days: i)));
        spark.add((dailyTTC[day] ?? 0).toDouble());
        sparkCount.add((dailyCount[day] ?? 0).toDouble());
      }
      final monthly = <(String, double)>[];
      for (var i = 5; i >= 0; i--) {
        final m = DateTime(now.year, now.month - i);
        final key =
            '${m.year.toString().padLeft(4, '0')}-${m.month.toString().padLeft(2, '0')}';
        monthly.add(
            (_monthShort[m.month - 1], (monthlyTTC[key] ?? 0).toDouble()));
      }

      // --- Partners with credit ---
      final debtors = (results[5] as List<Partner>)
          .where((p) => p.balance > 0)
          .toList()
        ..sort((a, b) => b.balance.compareTo(a.balance));

      setState(() {
        _stockValue = stockValue;
        _refCount = levels.length;
        _salesToday = salesToday;
        _ticketsToday = ticketsToday;
        _salesSpark = spark;
        _ticketsSpark = sparkCount;
        _monthlySales = monthly;
        _donut = donut;
        _donutLegend = legend;
        _lowStock = low.take(6).toList();
        _movements = results[4] as List<StockMovement>;
        _debtors = debtors.take(5).toList();
        _recent = results[6] as List<DocSummary>;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off, size: 34, color: T.ghost),
          const SizedBox(height: 10),
          Text('Impossible de joindre le serveur\n$_error',
              style: T.bodyMuted, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          SizedBox(
              width: 130,
              child: PrimaryButton(label: 'Réessayer', onPressed: _load)),
        ]),
      );
    }
    return RefreshIndicator(
      color: T.mint,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Bonjour, Administrateur',
                      style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: T.ink)),
                  const SizedBox(height: 4),
                  Text('Voici un aperçu de votre commerce.',
                      style: T.bodyMuted.copyWith(fontSize: 14)),
                ],
              ),
            ),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18, color: T.muted),
              tooltip: 'Actualiser',
            ),
          ]),
          const SizedBox(height: 22),
          // ---- Stat cards ----
          Row(children: [
            if (_viewCost) ...[
              _StatCard(
                  label: 'Valeur totale du stock',
                  value: fmtDA(_stockValue),
                  loading: _loading),
              const SizedBox(width: 14),
            ],
            _StatCard(
                label: "Ventes aujourd'hui",
                value: fmtDA(_salesToday),
                spark: _salesSpark,
                loading: _loading),
            const SizedBox(width: 14),
            _StatCard(
                label: 'Tickets',
                value: '$_ticketsToday',
                spark: _ticketsSpark,
                loading: _loading),
            const SizedBox(width: 14),
            _StatCard(
                label: 'Nombre de produits',
                value: '$_refCount',
                loading: _loading),
            const SizedBox(width: 14),
            _StatCard(
                label: 'Alertes stock faible',
                value: '${_lowStock.length}',
                accent: _lowStock.isNotEmpty ? T.danger : null,
                loading: _loading),
          ]),
          const SizedBox(height: 16),
          // ---- Row 2 ----
          SizedBox(
            height: 300,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: _PanelCard(
                    title: 'Mouvements récents',
                    actionLabel: 'Voir tout',
                    onAction: () => widget.onNavigate('stock'),
                    child: _movements.isEmpty
                        ? const EmptyState(
                            icon: Icons.swap_vert, text: 'Aucun mouvement')
                        : ListView.separated(
                            itemCount: _movements.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) =>
                                _MovementRow(m: _movements[i]),
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                if (_viewCost)
                Expanded(
                  flex: 4,
                  child: _PanelCard(
                    title: 'Répartition du stock',
                    child: Row(children: [
                      Donut(
                        slices: _donut,
                        size: 148,
                        center: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$_refCount',
                                style: const TextStyle(
                                    fontFamily: T.sans,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                    color: T.ink)),
                            Text('Produits',
                                style: T.small.copyWith(fontSize: 11)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final (name, color, pct) in _donutLegend)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 7),
                                child: Row(children: [
                                  Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                          color: color,
                                          shape: BoxShape.circle)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(name,
                                        style:
                                            T.small.copyWith(fontSize: 11.5),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  Text(pct, style: T.monoSmall),
                                ]),
                              ),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 3,
                  child: _PanelCard(
                    title: 'Alertes stock faible',
                    actionLabel: 'Voir tout',
                    onAction: () => widget.onNavigate('stock'),
                    child: _lowStock.isEmpty
                        ? const EmptyState(
                            icon: Icons.check_circle_outline,
                            text: 'Aucune alerte')
                        : ListView.separated(
                            itemCount: _lowStock.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) {
                              final a = _lowStock[i];
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Row(children: [
                                  Container(
                                      width: 7,
                                      height: 7,
                                      decoration: const BoxDecoration(
                                          color: T.danger,
                                          shape: BoxShape.circle)),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(a.name,
                                        style:
                                            T.body.copyWith(fontSize: 12.5),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  Text('Stock : ${fmtQty(a.qtyMilli)}',
                                      style: T.monoSmall.copyWith(
                                          color: T.dangerDark,
                                          fontSize: 11)),
                                ]),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // ---- Row 3 ----
          SizedBox(
            height: 280,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: _PanelCard(
                    title: 'Crédits clients',
                    actionLabel: 'Voir tout',
                    onAction: () => widget.onNavigate('partners'),
                    child: _debtors.isEmpty
                        ? const EmptyState(
                            icon: Icons.credit_score,
                            text: 'Aucun crédit en cours')
                        : ListView.separated(
                            itemCount: _debtors.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) {
                              final p = _debtors[i];
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 9),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(p.name,
                                            style: T.body
                                                .copyWith(fontSize: 12.5),
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow.ellipsis),
                                        if (p.phone != null)
                                          Text(p.phone!,
                                              style: T.monoSmall
                                                  .copyWith(fontSize: 10.5)),
                                      ],
                                    ),
                                  ),
                                  Text(fmtDA(p.balance),
                                      style: T.monoBody.copyWith(
                                          color: T.warnDark,
                                          fontWeight: FontWeight.w600)),
                                ]),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 4,
                  child: _PanelCard(
                    title: 'Ventes — 6 derniers mois',
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Bars(data: _monthlySales, height: 190),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 3,
                  child: _PanelCard(
                    title: 'Derniers documents',
                    actionLabel: 'Voir tout',
                    onAction: () => widget.onNavigate('sales'),
                    child: _recent.isEmpty
                        ? const EmptyState(
                            icon: Icons.receipt_long_outlined,
                            text: 'Aucun document')
                        : ListView.separated(
                            itemCount: _recent.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) {
                              final d = _recent[i];
                              final isPayment =
                                  d.docType.startsWith('PAYMENT');
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(d.number ?? '(brouillon)',
                                            style: T.monoBody.copyWith(
                                                fontSize: 11.5,
                                                color: d.number == null
                                                    ? T.ghost
                                                    : T.ink)),
                                        Text(
                                            docTypeLabels[d.docType] ??
                                                d.docType,
                                            style: T.small
                                                .copyWith(fontSize: 10.5)),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                          fmtDA(isPayment
                                              ? d.amount
                                              : d.totalTTC),
                                          style: T.monoBody
                                              .copyWith(fontSize: 11.5)),
                                      const SizedBox(height: 2),
                                      StatusChip(status: d.status),
                                    ],
                                  ),
                                ]),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.spark,
    this.accent,
    this.loading = false,
  });
  final String label;
  final String value;
  final List<double>? spark;
  final Color? accent;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 128,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rCard),
          border: Border.all(color: T.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.label
                    .copyWith(color: accent ?? T.mintDeep, fontSize: 9.5)),
            const SizedBox(height: 8),
            Text(loading ? '—' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: T.sans,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: T.ink)),
            const Spacer(),
            if (spark != null && spark!.isNotEmpty)
              Sparkline(values: spark!, height: 26)
            else
              const SizedBox(height: 26),
          ],
        ),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard(
      {required this.title,
      required this.child,
      this.actionLabel,
      this.onAction});
  final String title;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontFamily: T.sans,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: T.ink)),
            ),
            if (actionLabel != null)
              InkWell(
                onTap: onAction,
                child: Text(actionLabel!,
                    style: T.small.copyWith(fontSize: 11.5)),
              ),
          ]),
          const SizedBox(height: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.m});
  final StockMovement m;

  @override
  Widget build(BuildContext context) {
    final isTransfer = m.docType == 'STOCK_TRANSFER';
    final isIn = m.qtyMilli > 0;
    final (icon, color, label) = isTransfer
        ? (Icons.swap_horiz_rounded, T.muted, 'Transfert')
        : isIn
            ? (Icons.south_rounded, T.mintDeep, 'Entrée')
            : (Icons.north_rounded, T.dangerDark, 'Sortie');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        SizedBox(
            width: 66,
            child: Text(label, style: T.small.copyWith(fontSize: 11.5))),
        SizedBox(
          width: 118,
          child: Text(m.docNumber ?? '—',
              style: T.monoSmall.copyWith(fontSize: 10.5)),
        ),
        Expanded(
          child: Text(m.productName,
              style: T.body.copyWith(fontSize: 12.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        Text('${isIn ? '+' : ''}${fmtQty(m.qtyMilli)}',
            style: T.monoBody.copyWith(
                fontSize: 12,
                color: isTransfer ? T.muted : color,
                fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Text(m.createdAt.length >= 10 ? m.createdAt.substring(0, 10) : '',
            style: T.monoSmall.copyWith(fontSize: 10.5)),
      ]),
    );
  }
}
