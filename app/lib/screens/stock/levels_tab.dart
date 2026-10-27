import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/list_export.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/fiche_produit.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/product_thumb.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// « Niveaux de stock » : one row per product (zeros included), the KPI strip follows
/// the filters. ONE rule for « stock faible » (low stock; see [StockLevel.isLow]).
class LevelsTab extends StatefulWidget {
  const LevelsTab({
    super.key,
    required this.api,
    required this.viewCost,
    required this.warehouses,
    required this.warehouseId,
    required this.onWarehouse,
    required this.onShowMoves,
    required this.onInventory,
    this.company = const {},
  });

  final ApiClient api;
  final bool viewCost;
  final List<Warehouse> warehouses;
  final String? warehouseId;
  final ValueChanged<String?> onWarehouse;
  final void Function(String productId, String productName) onShowMoves;
  final VoidCallback onInventory;
  final Map<String, String> company;

  @override
  State<LevelsTab> createState() => LevelsTabState();
}

class LevelsTabState extends State<LevelsTab> {
  static const _p = 'stock_levels';

  final _search = TextEditingController();
  List<StockLevel> _rows = const [];
  bool _loading = true;
  String? _error;

  bool _rupture = UiPrefs.instance.get<bool>(_p, 'f_rupture') ?? false;
  bool _underMin = UiPrefs.instance.get<bool>(_p, 'f_under') ?? false;
  String? _category = UiPrefs.instance.get<String>(_p, 'f_cat');
  String? _brand = UiPrefs.instance.get<String>(_p, 'f_brand');
  String? _supplier = UiPrefs.instance.get<String>(_p, 'f_sup');

  final Map<String, Product> _thumbs = {};

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant LevelsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouseId != widget.warehouseId) load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows =
          await widget.api.stockLevels(warehouseId: widget.warehouseId, full: true);
      if (mounted) {
        setState(() {
          _rows = rows;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Stock indisponible : $e';
          _loading = false;
        });
      }
    }
  }

  void _save() {
    UiPrefs.instance.set(_p, 'f_rupture', _rupture);
    UiPrefs.instance.set(_p, 'f_under', _underMin);
    UiPrefs.instance.set(_p, 'f_cat', _category);
    UiPrefs.instance.set(_p, 'f_brand', _brand);
    UiPrefs.instance.set(_p, 'f_sup', _supplier);
  }

  void _clearAll() {
    setState(() {
      _rupture = _underMin = false;
      _category = _brand = _supplier = null;
      _search.clear();
    });
    _save();
  }

  bool get _anyFilter =>
      _rupture ||
      _underMin ||
      _category != null ||
      _brand != null ||
      _supplier != null ||
      _search.text.trim().isNotEmpty;

  /// Rows after search + panel filters, BEFORE the quick pills (so the pill
  /// counts stay meaningful).
  List<StockLevel> get _base {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final l in _rows)
        if ((q.isEmpty ||
                l.productName.toLowerCase().contains(q) ||
                (l.barcode ?? '').contains(q)) &&
            (_category == null || l.categoryId == _category) &&
            (_brand == null || l.brand == _brand) &&
            (_supplier == null || l.defaultSupplierId == _supplier))
          l
    ];
  }

  List<StockLevel> get visibleRows {
    final base = _base;
    if (!_rupture && !_underMin) return base;
    return [
      for (final l in base)
        if ((_rupture && l.isRupture) || (_underMin && l.isUnderMin)) l
    ];
  }

  Product _thumb(StockLevel l) => _thumbs.putIfAbsent(
      '${l.productId}:${l.imageRev}',
      () => Product.fromJson(
          {'id': l.productId, 'name': l.productName, 'image_rev': l.imageRev}));

  int _saleValue(StockLevel l) =>
      l.qtyMilli > 0 ? (l.qtyMilli * l.priceRetail) ~/ 1000 : 0;
  int _saleHT(StockLevel l) =>
      roundDiv(_saleValue(l) * 10000, 10000 + l.vatRate);
  int _costValue(StockLevel l) => l.qtyMilli > 0 ? l.valuation : 0;

  /// Export of the filtered list from the page « Plus » menu.
  Future<String> exportVisible(ExportFormat f) async {
    // first visit from the « Plus » menu: wait for the list to arrive
    for (var i = 0; i < 100 && _loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final rows = visibleRows;
    return exportTable(
      ExportTable(
        title: 'Stock',
        baseName: 'stock',
        headers: [
          'Produit',
          'Code-barres',
          'Catégorie',
          'Quantité',
          'Minimum',
          if (widget.viewCost) 'Coût moyen (DA)',
          if (widget.viewCost) 'Valeur (DA)',
          'Prix de vente (DA)',
        ],
        rows: [
          for (final l in rows)
            [
              l.productName,
              l.barcode ?? '',
              l.categoryName ?? '',
              l.qtyMilli / 1000,
              l.minStockMilli / 1000,
              if (widget.viewCost) l.avgCost / 100,
              if (widget.viewCost) l.valuation / 100,
              l.priceRetail / 100,
            ]
        ],
        numeric: {for (var i = 3; i < (widget.viewCost ? 8 : 6); i++) i},
      ),
      f,
      company: widget.company,
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = _base;
    final rows = visibleRows;
    final rupture = base.where((l) => l.isRupture).length;
    final under = base.where((l) => l.isUnderMin).length;

    final cats = <String, String>{
      for (final l in _rows)
        if (l.categoryId != null) l.categoryId!: l.categoryName ?? '—'
    };
    final brands = {for (final l in _rows) if (l.brand.isNotEmpty) l.brand}.toList()..sort();
    final sups = <String, String>{
      for (final l in _rows)
        if (l.defaultSupplierId != null) l.defaultSupplierId!: l.defaultSupplierName ?? '—'
    };

    final cost = rows.fold<int>(0, (s, l) => s + _costValue(l));
    final sale = rows.fold<int>(0, (s, l) => s + _saleValue(l));
    final saleHT = rows.fold<int>(0, (s, l) => s + _saleHT(l));
    final rowsRupture = rows.where((l) => l.isRupture).length;
    final rowsUnder = rows.where((l) => l.isUnderMin).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      KpiStrip(loading: _loading && _rows.isEmpty, items: [
        if (widget.viewCost)
          Kpi('Valeur au coût moyen', fmtDA(cost), hint: 'quantité × coût moyen'),
        Kpi('Valeur au prix de vente', fmtDA(sale), hint: 'TTC, prix actuels'),
        if (widget.viewCost)
          Kpi('Bénéfice possible', fmtDA(saleHT - cost),
              hint: saleHT > 0
                  ? '${((saleHT - cost) * 100 / saleHT).toStringAsFixed(1).replaceAll('.', ',')} % du HT'
                  : null),
        Kpi('Produits en rupture', '$rowsRupture',
            tone: rowsRupture > 0 ? T.dangerDark : null,
            hint: 'quantité à zéro ou moins',
            onTap: () {
              setState(() {
                _rupture = true;
                _underMin = false;
              });
              _save();
            }),
        Kpi('Sous le minimum', '$rowsUnder',
            tone: rowsUnder > 0 ? T.warnDark : null,
            hint: 'quantité sous le stock minimum',
            onTap: () {
              setState(() {
                _underMin = true;
                _rupture = false;
              });
              _save();
            }),
      ]),
      const SizedBox(height: 12),
      ListToolbar(
        search: _search,
        searchHint: 'Rechercher un produit ou scanner…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          FilterPill(
            label: 'Rupture',
            icon: Icons.remove_shopping_cart_outlined,
            active: _rupture,
            count: rupture,
            onTap: () {
              setState(() => _rupture = !_rupture);
              _save();
            },
          ),
          FilterPill(
            label: 'Sous le minimum',
            icon: Icons.warning_amber_rounded,
            active: _underMin,
            count: under,
            onTap: () {
              setState(() => _underMin = !_underMin);
              _save();
            },
          ),
        ],
        panel: FilterPanel(fields: [
          ?depotFilter(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
          ),
          FilterField<String>(
            label: 'Catégorie',
            value: cats.containsKey(_category) ? _category : null,
            allLabel: 'Toutes',
            options: [
              for (final e in cats.entries.toList()
                ..sort((a, b) => a.value.compareTo(b.value)))
                (e.key, e.value)
            ],
            onChanged: (v) {
              setState(() => _category = v);
              _save();
            },
          ),
          FilterField<String>(
            label: 'Marque',
            value: brands.contains(_brand) ? _brand : null,
            allLabel: 'Toutes',
            options: [for (final b in brands) (b, b)],
            onChanged: (v) {
              setState(() => _brand = v);
              _save();
            },
          ),
          FilterField<String>(
            label: 'Fournisseur habituel',
            value: sups.containsKey(_supplier) ? _supplier : null,
            options: [
              for (final e in sups.entries.toList()
                ..sort((a, b) => a.value.compareTo(b.value)))
                (e.key, e.value)
            ],
            onChanged: (v) {
              setState(() => _supplier = v);
              _save();
            },
          ),
        ]),
        active: [
          if (_rupture)
            ActiveFilter('Rupture', () {
              setState(() => _rupture = false);
              _save();
            }),
          if (_underMin)
            ActiveFilter('Sous le minimum', () {
              setState(() => _underMin = false);
              _save();
            }),
          if (_category != null)
            ActiveFilter('Catégorie : ${cats[_category] ?? '—'}', () {
              setState(() => _category = null);
              _save();
            }),
          if (_brand != null)
            ActiveFilter('Marque : $_brand', () {
              setState(() => _brand = null);
              _save();
            }),
          if (_supplier != null)
            ActiveFilter('Fournisseur : ${sups[_supplier] ?? '—'}', () {
              setState(() => _supplier = null);
              _save();
            }),
        ],
        onClearAll: _clearAll,
        trailing: [RefreshButton(onPressed: load)],
      ),
      const SizedBox(height: 12),
      Expanded(
        child: DataListView<StockLevel>(
          prefsKey: _p,
          items: rows,
          loading: _loading,
          error: _error,
          onRetry: load,
          rowId: (l) => l.productId,
          exportTitle: 'Stock',
          exportBaseName: 'stock',
          company: widget.company,
          onTap: (l) => showFicheProduit(context, widget.api, l.productId,
              canCost: widget.viewCost, onChanged: load),
          rowMenu: (l) => [
            RowAction('Voir la fiche', Icons.inventory_2_outlined, (l) {
              showFicheProduit(context, widget.api, l.productId,
                  canCost: widget.viewCost, onChanged: load);
            }),
            RowAction('Voir les mouvements', Icons.swap_vert_rounded,
                (l) => widget.onShowMoves(l.productId, l.productName)),
            RowAction('Corriger le stock', Icons.tune_rounded, (l) async {
              final done = await showAdjustStock(context, widget.api, l.productId);
              if (done) load();
            }),
          ],
          empty: _anyFilter
              ? EmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  text: 'Aucun produit ne correspond à ces filtres.',
                  actions: [('Effacer les filtres', _clearAll)])
              : EmptyState(
                  icon: Icons.inventory_2_outlined,
                  text: 'Aucun produit en stock.\n'
                      'Les bons de réception et les inventaires remplissent cette liste.',
                  actions: [('Faire un inventaire', widget.onInventory)]),
          aggregates: (sel) => [
            if (widget.viewCost)
              ('Valeur', fmtDA(sel.fold<int>(0, (s, l) => s + _costValue(l)))),
            ('Rupture', '${sel.where((l) => l.isRupture).length}'),
            ('Sous le minimum','${sel.where((l) => l.isUnderMin).length}'),
          ],
          columns: [
            ColumnSpec(
              id: 'product',
              label: 'Produit',
              flex: 5,
              hideable: false,
              sortKey: (l) => l.productName.toLowerCase(),
              exportValue: (l) => l.productName,
              cell: (context, l) => Row(children: [
                ProductThumb(api: widget.api, product: _thumb(l), size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(l.productName,
                      style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
            ColumnSpec(
              id: 'barcode',
              label: 'Code-barres',
              flex: 3,
              sortKey: (l) => l.barcode ?? '',
              exportValue: (l) => l.barcode ?? '',
              cell: (context, l) => Text(l.barcode ?? '—', style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'category',
              label: 'Catégorie',
              flex: 2,
              visibleByDefault: false,
              sortKey: (l) => l.categoryName ?? '',
              exportValue: (l) => l.categoryName ?? '',
              cell: (context, l) => Text(l.categoryName ?? '—',
                  style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'qty',
              label: 'Quantité',
              width: 130,
              numeric: true,
              hideable: false,
              sortKey: (l) => l.qtyMilli,
              exportValue: (l) => l.qtyMilli / 1000,
              cell: (context, l) => Tooltip(
                message: l.isRupture
                    ? 'Rupture'
                    : l.isUnderMin
                        ? 'Sous le minimum (${fmtQty(l.minStockMilli)})'
                        : l.minStockMilli > 0
                            ? 'Minimum ${fmtQty(l.minStockMilli)}'
                            : '',
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  StockDot(rupture: l.isRupture, underMin: l.isUnderMin),
                  Text(qtyUnit(l.qtyMilli, l.unit),
                      style: T.monoBody.copyWith(
                          color: l.isRupture ? T.dangerDark : T.ink,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
            ColumnSpec(
              id: 'min',
              label: 'Minimum',
              width: 100,
              numeric: true,
              visibleByDefault: false,
              sortKey: (l) => l.minStockMilli,
              exportValue: (l) => l.minStockMilli / 1000,
              cell: (context, l) => Text(
                  l.minStockMilli > 0 ? fmtQty(l.minStockMilli) : '—',
                  style: T.monoSmall),
            ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'cmup',
                label: 'Coût moyen',
                width: 130,
                numeric: true,
                sortKey: (l) => l.avgCost,
                exportValue: (l) => l.avgCost / 100,
                cell: (context, l) => Text(fmtDA(l.avgCost),
                    style: T.monoBody.copyWith(color: T.muted)),
              ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'value',
                label: 'Valeur',
                width: 130,
                numeric: true,
                sortKey: (l) => l.valuation,
                exportValue: (l) => l.valuation / 100,
                cell: (context, l) => Text(fmtDA(l.valuation), style: T.monoBody),
              ),
            ColumnSpec(
              id: 'price',
              label: 'Prix de vente',
              width: 120,
              numeric: true,
              visibleByDefault: false,
              sortKey: (l) => l.priceRetail,
              exportValue: (l) => l.priceRetail / 100,
              cell: (context, l) => Text(fmtDA(l.priceRetail), style: T.monoBody),
            ),
          ],
        ),
      ),
    ]);
  }
}
