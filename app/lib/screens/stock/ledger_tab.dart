import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// « Mouvements » : the stock journal with a running balance per product ×
/// depot, opening / closing for the period, type pills.
class LedgerTab extends StatefulWidget {
  const LedgerTab({
    super.key,
    required this.api,
    required this.viewCost,
    required this.warehouses,
    required this.warehouseId,
    required this.onWarehouse,
    this.company = const {},
  });

  final ApiClient api;
  final bool viewCost;
  final List<Warehouse> warehouses;
  final String? warehouseId;
  final ValueChanged<String?> onWarehouse;
  final Map<String, String> company;

  @override
  State<LedgerTab> createState() => LedgerTabState();
}

class LedgerTabState extends State<LedgerTab> {
  static const _p = 'stock_ledger';

  static const _kinds = [
    ('sales', 'Ventes'),
    ('purchases', 'Achats'),
    ('returns', 'Retours'),
    ('adjustments', 'Ajustements'),
    ('inventory', 'Inventaires'),
    ('transfers', 'Transferts'),
  ];

  final _search = TextEditingController();
  Timer? _debounce;
  late StockPeriod _period = StockPeriod.load(_p);
  late Set<String> _kindSel = {...?UiPrefs.instance.getList(_p, 'kinds')};
  String? _productId = UiPrefs.instance.get<String>(_p, 'product_id');
  String? _productName = UiPrefs.instance.get<String>(_p, 'product_name');

  StockLedger? _data;
  bool _loading = true;
  String? _error;
  final Map<String, int> _seq = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LedgerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouseId != widget.warehouseId) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Opens the journal on one product (from the levels row menu).
  void showProduct(String id, String name) {
    setState(() {
      _productId = id;
      _productName = name;
    });
    _saveProduct();
    _load();
  }

  void _saveProduct() {
    UiPrefs.instance.set(_p, 'product_id', _productId);
    UiPrefs.instance.set(_p, 'product_name', _productName);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.api.stockLedger(
        from: _period.fromIso,
        to: _period.toIso,
        warehouseId: widget.warehouseId,
        productId: _productId,
        kinds: _kindSel.toList(),
        q: _search.text.trim(),
      );
      if (mounted) {
        setState(() {
          _data = d;
          _seq
            ..clear()
            ..addAll({for (var i = 0; i < d.rows.length; i++) d.rows[i].id: i});
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Journal indisponible : $e';
          _loading = false;
        });
      }
    }
  }

  void _toggleKind(String k) {
    setState(() => _kindSel.contains(k) ? _kindSel.remove(k) : _kindSel.add(k));
    UiPrefs.instance.set(_p, 'kinds', _kindSel.toList());
    _load();
  }

  Future<void> _pickProduct() async {
    final p = await pickProduct(context, widget.api, title: 'Mouvements d’un produit');
    if (p == null) return;
    showProduct(p.id, p.name);
  }

  void _clearAll() {
    setState(() {
      _kindSel = {};
      _productId = _productName = null;
      _search.clear();
    });
    UiPrefs.instance.set(_p, 'kinds', const <String>[]);
    _saveProduct();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final rows = d?.rows ?? const <LedgerRow>[];
    final showDepot = widget.warehouses.length > 1 && widget.warehouseId == null;
    final lots = Features.instance.lots;
    final filtered = _kindSel.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      KpiStrip(loading: _loading && d == null, items: [
        Kpi('Ouverture', d == null ? '—' : fmtQty(d.openingMilli),
            hint: widget.viewCost && d != null
                ? fmtDA(d.openingValue)
                : 'stock au début de la période'),
        Kpi('Entrées', d == null ? '—' : '+${fmtQty(d.inMilli)}',
            tone: T.mintDark, hint: filtered ? 'types choisis' : null),
        Kpi('Sorties', d == null ? '—' : '−${fmtQty(d.outMilli)}',
            tone: T.dangerDark, hint: filtered ? 'types choisis' : null),
        Kpi('Clôture', d == null ? '—' : fmtQty(d.closingMilli),
            hint: widget.viewCost && d != null
                ? fmtDA(d.closingValue)
                : 'stock à la fin de la période'),
      ]),
      const SizedBox(height: 12),
      ListToolbar(
        search: _search,
        searchHint: 'Produit ou code-barres…',
        onSearchChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), _load);
        },
        onSearchSubmitted: (_) => _load(),
        quickFilters: [
          PeriodButton(
            period: _period,
            onChanged: (p) {
              setState(() => _period = p);
              p.save(_p);
              _load();
            },
          ),
          for (final (k, l) in _kinds)
            FilterPill(label: l, active: _kindSel.contains(k), onTap: () => _toggleKind(k)),
        ],
        active: [
          if (_productId != null)
            ActiveFilter('Produit : ${_productName ?? '—'}', () {
              setState(() => _productId = _productName = null);
              _saveProduct();
              _load();
            }),
          for (final (k, l) in _kinds)
            if (_kindSel.contains(k)) ActiveFilter(l, () => _toggleKind(k)),
        ],
        onClearAll: _clearAll,
        trailing: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: FilterPill(
              label: _productId == null ? 'Produit…' : 'Changer de produit',
              icon: Icons.search_rounded,
              active: false,
              onTap: _pickProduct,
            ),
          ),
          DepotDropdown(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
          ),
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18, color: T.muted),
          ),
        ],
      ),
      if (d?.truncated == true)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
              'Seuls les ${rows.length} derniers mouvements sont affichés — réduisez la période ou filtrez par produit.',
              style: T.small.copyWith(color: T.warnDark)),
        ),
      const SizedBox(height: 12),
      Expanded(
        child: DataListView<LedgerRow>(
          prefsKey: _p,
          items: rows,
          loading: _loading,
          error: _error,
          onRetry: _load,
          rowId: (r) => r.id,
          initialSortColumn: 0,
          initialAscending: false,
          exportTitle: 'Mouvements de stock — ${_period.label}',
          exportBaseName: 'mouvements_stock',
          company: widget.company,
          onTap: (r) async {
            final changed = await openStockDocument(context, widget.api, r.documentId);
            if (changed) _load();
          },
          rowMenu: (r) => [
            RowAction('Ouvrir le document', Icons.description_outlined, (r) async {
              final changed = await openStockDocument(context, widget.api, r.documentId);
              if (changed) _load();
            }),
            RowAction('Mouvements de ce produit', Icons.filter_alt_outlined,
                (r) => showProduct(r.productId, r.productName)),
          ],
          empty: EmptyState(
            icon: Icons.swap_vert_rounded,
            text: 'Aucun mouvement sur cette période.',
            actions: [
              if (_kindSel.isNotEmpty || _productId != null || _search.text.isNotEmpty)
                ('Effacer les filtres', _clearAll),
              if (_period.key != 'all')
                ('Voir tout l’historique', () {
                  setState(() => _period = StockPeriod.preset('all'));
                  _period.save(_p);
                  _load();
                }),
            ],
          ),
          aggregates: (sel) => [
            ('Entrées', fmtQty(sel.fold<int>(0, (s, r) => s + r.inMilli))),
            ('Sorties', fmtQty(sel.fold<int>(0, (s, r) => s + r.outMilli))),
          ],
          columns: [
            ColumnSpec(
              id: 'date',
              label: 'Date',
              width: 128,
              hideable: false,
              sortKey: (r) => '${r.createdAt}#${(_seq[r.id] ?? 0).toString().padLeft(8, '0')}',
              exportValue: (r) => frDateTime(r.at),
              cell: (context, r) => Text(frDateTime(r.at), style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'type',
              label: 'Type',
              width: 120,
              sortKey: (r) => docLabel(r.docType),
              exportValue: (r) =>
                  r.isReversal ? '${docLabel(r.docType)} (annulation)' : docLabel(r.docType),
              cell: (context, r) => Text(
                  r.isReversal ? '${docLabel(r.docType)} ↺' : docLabel(r.docType),
                  style: T.small.copyWith(
                      color: r.isReversal ? T.warnDark : T.ink, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'number',
              label: 'N°',
              width: 150,
              sortKey: (r) => r.number ?? '',
              exportValue: (r) => r.number ?? '',
              cell: (context, r) => Text(r.number ?? '—', style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'product',
              label: 'Produit',
              flex: 4,
              hideable: false,
              sortKey: (r) => r.productName.toLowerCase(),
              exportValue: (r) => r.productName,
              cell: (context, r) => Text(r.productName,
                  style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (showDepot)
              ColumnSpec(
                id: 'depot',
                label: 'Dépôt',
                flex: 2,
                sortKey: (r) => r.warehouseName,
                exportValue: (r) => r.warehouseName,
                cell: (context, r) => Text(r.warehouseName,
                    style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (lots)
              ColumnSpec(
                id: 'lot',
                label: 'Lot',
                width: 100,
                visibleByDefault: false,
                sortKey: (r) => r.lotNumber ?? '',
                exportValue: (r) => r.lotNumber ?? '',
                cell: (context, r) => Text(r.lotNumber ?? '—', style: T.monoSmall),
              ),
            ColumnSpec(
              id: 'in',
              label: 'Entrée',
              width: 90,
              numeric: true,
              sortKey: (r) => r.inMilli,
              exportValue: (r) => r.inMilli / 1000,
              cell: (context, r) => Text(r.inMilli > 0 ? '+${fmtQty(r.inMilli)}' : '',
                  style: T.monoBody.copyWith(color: T.mintDark)),
            ),
            ColumnSpec(
              id: 'out',
              label: 'Sortie',
              width: 90,
              numeric: true,
              sortKey: (r) => r.outMilli,
              exportValue: (r) => r.outMilli / 1000,
              cell: (context, r) => Text(r.outMilli > 0 ? '−${fmtQty(r.outMilli)}' : '',
                  style: T.monoBody.copyWith(color: T.dangerDark)),
            ),
            ColumnSpec(
              id: 'balance',
              label: 'Solde',
              width: 90,
              numeric: true,
              sortKey: (r) => r.balanceMilli,
              exportValue: (r) => r.balanceMilli / 1000,
              cell: (context, r) => Text(fmtQty(r.balanceMilli),
                  style: T.monoBody.copyWith(
                      fontWeight: FontWeight.w700,
                      color: r.balanceMilli < 0 ? T.dangerDark : T.ink)),
            ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'cost',
                label: 'Coût unit.',
                width: 110,
                numeric: true,
                visibleByDefault: false,
                sortKey: (r) => r.unitCost,
                exportValue: (r) => r.unitCost / 100,
                cell: (context, r) => Text(fmtDA(r.unitCost),
                    style: T.monoBody.copyWith(color: T.muted)),
              ),
          ],
        ),
      ),
    ]);
  }
}
