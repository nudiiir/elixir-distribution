import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
import '../widgets/data_table.dart';
import '../widgets/ui.dart';

class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.api, required this.session});
  final ApiClient api;
  final Session session;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  bool get _viewCost => widget.session.user.can('view_cost');

  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<Warehouse> _warehouses = const [];
  String? _warehouseId; // null = all
  List<StockLevel> _levels = const [];
  bool _loading = true;
  String? _error;
  bool _onlyLow = false;
  Map<String, int> _minByProduct = const {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final results = await Future.wait([
        widget.api.warehouses(),
        widget.api.products(limit: 500),
      ]);
      if (mounted) {
        setState(() {
          _warehouses = results[0] as List<Warehouse>;
          _minByProduct = {
            for (final p in results[1] as List<Product>) p.id: p.minStockMilli,
          };
        });
      }
    } catch (_) {}
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.stockLevels(
        warehouseId: _warehouseId,
        q: _searchCtrl.text.trim(),
      );
      if (mounted) {
        setState(() {
          _levels = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  bool _isLow(StockLevel l) {
    final min = _minByProduct[l.productId] ?? 0;
    return l.qtyMilli <= 0 || (min > 0 && l.qtyMilli <= min);
  }

  List<StockLevel> get _visible =>
      _onlyLow ? _levels.where(_isLow).toList() : _levels;

  Future<void> _export(List<StockLevel> rows) async {
    final path = await exportCsv(
      baseName: 'stock',
      headers: [
        'Produit',
        'Code-barres',
        'Quantité',
        if (_viewCost) 'CUMP (DA)',
        if (_viewCost) 'Valeur (DA)',
      ],
      rows: [
        for (final l in rows)
          [
            l.productName,
            l.barcode ?? '',
            fmtQty(l.qtyMilli),
            if (_viewCost) editDA(l.avgCost),
            if (_viewCost) editDA(l.valuation),
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
    final visible = _visible;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('Stock', style: T.h1),
              const Spacer(),
              IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18, color: T.muted),
                tooltip: 'Actualiser',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SearchField(
                  controller: _searchCtrl,
                  hint: 'Rechercher un produit ou scanner…',
                  onChanged: _onQueryChanged,
                  onSubmitted: (_) => _load(),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: T.surface,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: _warehouseId,
                    style: T.body,
                    icon: const Icon(Icons.expand_more,
                        size: 16, color: T.faint),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Tous les dépôts')),
                      for (final w in _warehouses)
                        DropdownMenuItem<String?>(
                            value: w.id, child: Text(w.name)),
                    ],
                    onChanged: (v) {
                      setState(() => _warehouseId = v);
                      _load();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: () => setState(() => _onlyLow = !_onlyLow),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: _onlyLow ? T.dangerTint : T.surface,
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: _onlyLow ? T.danger : T.border),
                  ),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 15, color: _onlyLow ? T.dangerDark : T.faint),
                    const SizedBox(width: 6),
                    Text('Stock faible',
                        style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _onlyLow ? T.dangerDark : T.muted,
                        )),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _error != null
                ? Card14(
                    child: EmptyState(
                        icon: Icons.cloud_off,
                        text: 'Serveur injoignable\n$_error'))
                : DataListView<StockLevel>(
                    items: visible,
                    empty: EmptyState(
                        icon: Icons.inventory_2_outlined,
                        text: _loading
                            ? 'Chargement…'
                            : 'Aucun stock.\nLes réceptions fournisseur alimenteront cette liste.'),
                    onExport: _export,
                    aggregates: (rows) => [
                      if (_viewCost)
                        (
                          'Valeur totale',
                          fmtDA(rows.fold(0, (s, l) => s + l.valuation))
                        ),
                      ('Alertes', '${rows.where(_isLow).length}'),
                    ],
                    columns: [
                      ColumnSpec(
                        label: 'Produit',
                        flex: 5,
                        sortKey: (l) => l.productName.toLowerCase(),
                        cell: (context, l) => Text(l.productName,
                            style: T.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      ColumnSpec(
                        label: 'Code-barres',
                        flex: 3,
                        sortKey: (l) => l.barcode ?? '',
                        cell: (context, l) =>
                            Text(l.barcode ?? '—', style: T.monoSmall),
                      ),
                      ColumnSpec(
                        label: 'Qté',
                        width: 100,
                        sortKey: (l) => l.qtyMilli,
                        cell: (context, l) {
                          final low = _isLow(l);
                          return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (low)
                                  Container(
                                    margin:
                                        const EdgeInsetsDirectional.only(
                                            end: 6),
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                        color: l.qtyMilli <= 0
                                            ? T.danger
                                            : T.warn,
                                        shape: BoxShape.circle),
                                  ),
                                Text(fmtQty(l.qtyMilli),
                                    style: T.monoBody.copyWith(
                                        color: l.qtyMilli <= 0
                                            ? T.dangerDark
                                            : T.ink,
                                        fontWeight: FontWeight.w600)),
                              ]);
                        },
                      ),
                      if (_viewCost)
                        ColumnSpec(
                          label: 'CUMP',
                          width: 110,
                          numeric: true,
                          sortKey: (l) => l.avgCost,
                          cell: (context, l) => Text(fmtDA(l.avgCost),
                              style: T.monoBody.copyWith(color: T.muted)),
                        ),
                      if (_viewCost)
                        ColumnSpec(
                          label: 'Valeur',
                          width: 125,
                          numeric: true,
                          sortKey: (l) => l.valuation,
                          cell: (context, l) =>
                              Text(fmtDA(l.valuation), style: T.monoBody),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
