import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_editor.dart';
import '../../widgets/fiche_produit.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/product_thumb.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// « À commander » : replenishment proposal per product (server rule:
/// target = max(2 × min, 30 jours de ventes), rounded to the packaging),
/// editable quantities, one draft purchase order per supplier.
class ReorderTab extends StatefulWidget {
  const ReorderTab({
    super.key,
    required this.api,
    required this.viewCost,
    required this.canPurchase,
    required this.warehouses,
    required this.warehouseId,
    required this.onWarehouse,
    this.company = const {},
  });

  final ApiClient api;
  final bool viewCost;
  final bool canPurchase;
  final List<Warehouse> warehouses;
  final String? warehouseId;
  final ValueChanged<String?> onWarehouse;
  final Map<String, String> company;

  @override
  State<ReorderTab> createState() => _ReorderTabState();
}

class _ReorderTabState extends State<ReorderTab> {
  static const _p = 'stock_reorder';
  static const _none = '__none__';

  final _search = TextEditingController();
  List<ReorderRow> _rows = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  bool _urgentOnly = UiPrefs.instance.get<bool>(_p, 'urgent') ?? true;
  String? _supplier = UiPrefs.instance.get<String>(_p, 'supplier');

  final Map<String, TextEditingController> _qty = {};
  final Map<String, Product> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReorderTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouseId != widget.warehouseId) _load();
  }

  @override
  void dispose() {
    _search.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.stockReorder(warehouseId: widget.warehouseId);
      if (mounted) {
        setState(() {
          _rows = rows;
          for (final c in _qty.values) {
            c.dispose();
          }
          _qty.clear();
          for (final r in rows) {
            _qty[r.productId] = TextEditingController(text: fmtQty(r.suggestedMilli));
          }
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Proposition indisponible : $e';
          _loading = false;
        });
      }
    }
  }

  void _save() {
    UiPrefs.instance.set(_p, 'urgent', _urgentOnly);
    UiPrefs.instance.set(_p, 'supplier', _supplier);
  }

  List<ReorderRow> get _visible {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final r in _rows)
        if ((!_urgentOnly || r.urgent) &&
            (_supplier == null ||
                (_supplier == _none ? r.supplierId == null : r.supplierId == _supplier)) &&
            (q.isEmpty ||
                r.productName.toLowerCase().contains(q) ||
                (r.barcode ?? '').contains(q)))
          r
    ];
  }

  int _qtyOf(ReorderRow r) => parseQty(_qty[r.productId]?.text ?? '') ?? 0;

  Product _thumb(ReorderRow r) => _thumbs.putIfAbsent(
      '${r.productId}:${r.imageRev}',
      () => Product.fromJson(
          {'id': r.productId, 'name': r.productName, 'image_rev': r.imageRev}));

  /// One draft PURCHASE_ORDER per supplier with the edited quantities.
  Future<bool> _createOrders(List<ReorderRow> rows) async {
    if (_busy) return false;
    if (!widget.canPurchase) {
      showToast(context, 'Vous n’avez pas le droit de créer des commandes fournisseur.',
          kind: ToastKind.warning);
      return false;
    }
    final lines = [for (final r in rows) if (_qtyOf(r) > 0) r];
    if (lines.isEmpty) {
      showToast(context, 'Aucune quantité à commander.', kind: ToastKind.warning);
      return false;
    }
    final bySupplier = <String?, List<ReorderRow>>{};
    for (final r in lines) {
      bySupplier.putIfAbsent(r.supplierId, () => []).add(r);
    }
    // Produits sans fournisseur connu : on demande à qui les commander.
    final orphans = bySupplier.remove(null);
    Partner? orphanSupplier;
    if (orphans != null) {
      final ok = await confirmAction(context,
          title: 'Fournisseur manquant',
          message:
              '${orphans.length} produit(s) n’ont ni dernier fournisseur ni fournisseur habituel. '
              'Choisissez le fournisseur à qui les commander, ou annulez pour les ignorer.',
          confirmLabel: 'Choisir un fournisseur');
      if (!mounted) return false;
      if (ok) {
        orphanSupplier = await showPartnerPicker(context, widget.api, kind: 'supplier');
        if (!mounted) return false;
      }
      if (orphanSupplier != null) {
        bySupplier.putIfAbsent(orphanSupplier.id, () => []).addAll(orphans);
      }
    }
    if (bySupplier.isEmpty) return false;
    final names = <String, String>{
      for (final r in lines)
        if (r.supplierId != null) r.supplierId!: r.supplierName ?? '—',
      if (orphanSupplier != null) orphanSupplier.id: orphanSupplier.name,
    };
    final ok = await confirmAction(context,
        title: 'Créer ${bySupplier.length} bon(s) de commande ?',
        message: [
          for (final e in bySupplier.entries)
            '• ${names[e.key] ?? '—'} : ${e.value.length} produit(s)'
        ].join('\n'),
        confirmLabel: 'Créer les brouillons');
    if (!ok || !mounted) return false;

    setState(() => _busy = true);
    final created = <DocDetail>[];
    final errors = <String>[];
    for (final e in bySupplier.entries) {
      try {
        final d = await widget.api.createDraft({
          'doc_type': 'PURCHASE_ORDER',
          'doc_date': todayISO(),
          'partner_id': e.key,
          'warehouse_id': widget.warehouseId,
          'notes': 'Proposition de réapprovisionnement (écran Stock)',
          'lines': [
            for (var i = 0; i < e.value.length; i++)
              {
                'product_id': e.value[i].productId,
                'description': e.value[i].productName,
                'qty_milli': _qtyOf(e.value[i]),
                'unit_price': e.value[i].lastUnitCost,
                'discount_pct': 0,
                'vat_rate': e.value[i].vatRate,
                'pack_factor_milli': 1000,
                'position': i,
              }
          ],
        });
        created.add(d);
      } on ApiException catch (err) {
        errors.add('${names[e.key] ?? '—'} : ${err.message}');
      } catch (err) {
        errors.add('${names[e.key] ?? '—'} : $err');
      }
    }
    if (!mounted) return false;
    setState(() => _busy = false);
    if (errors.isNotEmpty) {
      showToast(context, 'Commandes non créées — ${errors.join(' ; ')}', kind: ToastKind.error);
    }
    if (created.isNotEmpty) {
      final first = created.first;
      showToast(
        context,
        created.length == 1
            ? 'Bon de commande créé en brouillon (${names[first.partnerId] ?? ''}).'
            : '${created.length} bons de commande créés en brouillon.',
        actionLabel: 'Ouvrir',
        onAction: () => Navigator.of(context).push(MaterialPageRoute<bool>(
          builder: (_) => DocEditorScreen(
              api: widget.api, config: purchaseOrderConfig, existing: first),
        )),
      );
    }
    return created.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final suppliers = <String, String>{
      for (final r in _rows)
        if (r.supplierId != null) r.supplierId!: r.supplierName ?? '—'
    };
    final hasOrphans = _rows.any((r) => r.supplierId == null);
    final urgentCount = _rows.where((r) => r.urgent).length;
    final total = rows.fold<int>(0, (s, r) => s + (_qtyOf(r) * r.lastUnitCost) ~/ 1000);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        search: _search,
        searchHint: 'Rechercher un produit…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          FilterPill(
            label: 'Urgent',
            icon: Icons.priority_high_rounded,
            active: _urgentOnly,
            count: urgentCount,
            onTap: () {
              setState(() => _urgentOnly = !_urgentOnly);
              _save();
            },
          ),
          FilterPill(
            label: 'Toutes les propositions',
            active: !_urgentOnly,
            count: _rows.length,
            onTap: () {
              setState(() => _urgentOnly = false);
              _save();
            },
          ),
        ],
        panel: FilterPanel(fields: [
          FilterField<String>(
            label: 'Fournisseur',
            value: _supplier == _none || suppliers.containsKey(_supplier) ? _supplier : null,
            options: [
              for (final e in suppliers.entries.toList()
                ..sort((a, b) => a.value.compareTo(b.value)))
                (e.key, e.value),
              if (hasOrphans) (_none, 'Sans fournisseur'),
            ],
            onChanged: (v) {
              setState(() => _supplier = v);
              _save();
            },
          ),
        ]),
        active: [
          if (_supplier != null)
            ActiveFilter(
                'Fournisseur : ${_supplier == _none ? 'aucun' : suppliers[_supplier] ?? '—'}', () {
              setState(() => _supplier = null);
              _save();
            }),
        ],
        trailing: [
          DepotDropdown(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
          ),
          IconButton(
            tooltip: 'Recalculer',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18, color: T.muted),
          ),
          const SizedBox(width: 6),
          SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: _busy || rows.isEmpty ? null : () => _createOrders(rows),
              icon: const Icon(Icons.local_shipping_outlined, size: 16),
              label: Text(_busy ? 'Création…' : 'Créer les bons de commande'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
          'Objectif : max(2 × stock minimum, 30 jours de ventes), arrondi au conditionnement. '
          'Cochez des lignes pour ne commander qu’une partie.',
          style: T.small.copyWith(fontSize: 11.5)),
      const SizedBox(height: 10),
      Expanded(
        child: DataListView<ReorderRow>(
          prefsKey: _p,
          items: rows,
          loading: _loading,
          error: _error,
          onRetry: _load,
          rowId: (r) => r.productId,
          initialSortColumn: 0,
          exportTitle: 'À commander',
          exportBaseName: 'a_commander',
          company: widget.company,
          bulkActions: [
            BulkAction('Créer les bons de commande', Icons.local_shipping_outlined,
                (sel) => _createOrders(sel)),
          ],
          onTap: (r) => showFicheProduit(context, widget.api, r.productId,
              canCost: widget.viewCost, onChanged: _load),
          rowMenu: (r) => [
            RowAction('Voir la fiche', Icons.inventory_2_outlined, (r) {
              showFicheProduit(context, widget.api, r.productId,
                  canCost: widget.viewCost, onChanged: _load);
            }),
            RowAction('Remettre la quantité suggérée', Icons.restart_alt_rounded, (r) {
              setState(() => _qty[r.productId]?.text = fmtQty(r.suggestedMilli));
            }),
          ],
          empty: EmptyState(
            icon: Icons.task_alt_rounded,
            text: _urgentOnly && _rows.isNotEmpty
                ? 'Rien d’urgent : aucun produit en rupture ni sous son minimum.'
                : 'Rien à commander.\nRenseignez un stock minimum sur les produits pour recevoir des propositions.',
            actions: [
              if (_urgentOnly && _rows.isNotEmpty)
                ('Voir toutes les propositions', () {
                  setState(() => _urgentOnly = false);
                  _save();
                }),
            ],
          ),
          aggregates: (sel) => [
            if (widget.viewCost)
              ('Montant HT estimé',
                  fmtDA(sel.fold<int>(0, (s, r) => s + (_qtyOf(r) * r.lastUnitCost) ~/ 1000))),
            ('Fournisseurs', '${{for (final r in sel) r.supplierId}.length}'),
          ],
          columns: [
            ColumnSpec(
              id: 'supplier',
              label: 'Fournisseur',
              flex: 3,
              sortKey: (r) =>
                  '${r.supplierName == null ? '~' : r.supplierName!.toLowerCase()}|${r.productName.toLowerCase()}',
              exportValue: (r) => r.supplierName ?? '',
              cell: (context, r) => Text(r.supplierName ?? 'Sans fournisseur',
                  style: T.small.copyWith(
                      color: r.supplierName == null ? T.warnDark : T.ink, fontSize: 12.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'product',
              label: 'Produit',
              flex: 5,
              hideable: false,
              sortKey: (r) => r.productName.toLowerCase(),
              exportValue: (r) => r.productName,
              cell: (context, r) => Row(children: [
                ProductThumb(api: widget.api, product: _thumb(r), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(r.productName,
                      style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
            ColumnSpec(
              id: 'qty',
              label: 'Stock',
              width: 90,
              numeric: true,
              sortKey: (r) => r.qtyMilli,
              exportValue: (r) => r.qtyMilli / 1000,
              cell: (context, r) => Row(mainAxisSize: MainAxisSize.min, children: [
                StockDot(
                    rupture: r.qtyMilli <= 0,
                    underMin: r.qtyMilli > 0 &&
                        r.minStockMilli > 0 &&
                        r.qtyMilli < r.minStockMilli),
                Text(fmtQty(r.qtyMilli), style: T.monoBody),
              ]),
            ),
            ColumnSpec(
              id: 'min',
              label: 'Min.',
              width: 70,
              numeric: true,
              sortKey: (r) => r.minStockMilli,
              exportValue: (r) => r.minStockMilli / 1000,
              cell: (context, r) => Text(
                  r.minStockMilli > 0 ? fmtQty(r.minStockMilli) : '—',
                  style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'daily',
              label: 'Ventes / j',
              width: 85,
              numeric: true,
              sortKey: (r) => r.avgDailyMilli,
              exportValue: (r) => r.avgDailyMilli / 1000,
              cell: (context, r) => Text(
                  r.avgDailyMilli > 0 ? fmtQty(r.avgDailyMilli) : '—',
                  style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'coverage',
              label: 'Couverture',
              width: 90,
              numeric: true,
              sortKey: (r) => r.coverageDays ?? 99999,
              exportValue: (r) => r.coverageDays ?? '',
              cell: (context, r) => Text(
                  r.coverageDays == null ? '—' : '${r.coverageDays} j',
                  style: T.monoSmall.copyWith(
                      color: (r.coverageDays ?? 99) < 7 ? T.dangerDark : T.muted)),
            ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'cost',
                label: 'Dernier coût',
                width: 110,
                numeric: true,
                sortKey: (r) => r.lastUnitCost,
                exportValue: (r) => r.lastUnitCost / 100,
                cell: (context, r) => Text(fmtDA(r.lastUnitCost),
                    style: T.monoBody.copyWith(color: T.muted)),
              ),
            ColumnSpec(
              id: 'order',
              label: 'À commander',
              width: 150,
              numeric: true,
              hideable: false,
              sortKey: (r) => _qtyOf(r),
              exportValue: (r) => _qtyOf(r) / 1000,
              cell: (context, r) => Row(mainAxisSize: MainAxisSize.min, children: [
                if (r.packName != null && r.packFactorMilli > 0)
                  Tooltip(
                    message: '${r.packName} de ${fmtQty(r.packFactorMilli)}',
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: Text(
                          '${fmtQty((_qtyOf(r) * 1000) ~/ r.packFactorMilli)} ${r.packName!.toLowerCase()}',
                          style: T.small.copyWith(fontSize: 10.5)),
                    ),
                  ),
                SizedBox(
                  width: 72,
                  height: 30,
                  child: TextField(
                    controller: _qty[r.productId],
                    textAlign: TextAlign.end,
                    style: T.monoBody.copyWith(fontWeight: FontWeight.w700),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                      filled: true,
                      fillColor: T.bg,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: T.border)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: T.border)),
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
      if (widget.viewCost && rows.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Montant HT estimé des lignes affichées : ${fmtDA(total)}',
              style: T.small),
        ),
    ]);
  }
}
