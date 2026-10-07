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
              const SizedBox(width: 16),
              _ViewTab(
                  label: 'Niveaux',
                  selected: !_dlcView,
                  onTap: () => setState(() => _dlcView = false)),
              _ViewTab(
                  label: 'Dates de péremption',
                  selected: _dlcView,
                  onTap: () {
                    setState(() => _dlcView = true);
                    _loadLots();
                  }),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _startInventory,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: T.border3),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(T.rInner)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
                icon: const Icon(Icons.fact_check_outlined,
                    size: 16, color: T.ink),
                label: Text('Inventaire',
                    style: T.small
                        .copyWith(color: T.ink, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                onPressed: _dlcView ? _loadLots : _load,
                icon: const Icon(Icons.refresh, size: 18, color: T.muted),
                tooltip: 'Actualiser',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_dlcView) ...[
            Expanded(child: _buildDlc()),
          ] else ...[
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
        ],
      ),
    );
  }

  // ---- DLC (expiry) view ----

  List<Lot> _lots = const [];
  bool _lotsLoading = false;
  bool _dlcView = false;

  Future<void> _loadLots() async {
    setState(() => _lotsLoading = true);
    try {
      final items = await widget.api.lots();
      if (mounted) {
        setState(() {
          _lots = items;
          _lotsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _lotsLoading = false);
    }
  }

  Future<void> _editLot({Lot? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _LotDialog(api: widget.api, existing: existing),
    );
    if (saved == true) _loadLots();
  }

  Widget _buildDlc() {
    final sorted = [..._lots];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(
            'Suivi des DLC — informatif : le stock reste géré par les '
            'documents. ${sorted.where((l) => (l.daysLeft ?? 999) <= 15).length} lot(s) à surveiller.',
            style: T.small),
        const Spacer(),
        SizedBox(
          width: 150,
          child: PrimaryButton(
              label: 'Ajouter un lot', onPressed: () => _editLot()),
        ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: Card14(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: sorted.isEmpty
              ? EmptyState(
                  icon: Icons.hourglass_bottom_rounded,
                  text: _lotsLoading
                      ? 'Chargement…'
                      : 'Aucun lot suivi.\nAjoutez les produits périssables avec leur date.')
              : ListView.separated(
                  itemCount: sorted.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) {
                    final l = sorted[i];
                    final days = l.daysLeft;
                    final (color, label) = days == null
                        ? (T.faint, '—')
                        : days < 0
                            ? (T.dangerDark, 'Périmé (${-days} j)')
                            : days <= 15
                                ? (T.warnDark, 'J-$days')
                                : (T.mintDark, 'J-$days');
                    return InkWell(
                      onTap: () => _editLot(existing: l),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(children: [
                          Expanded(
                              flex: 4,
                              child: Text(l.productName,
                                  style: T.body,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                          Expanded(
                              flex: 2,
                              child:
                                  Text(l.lotNumber, style: T.monoSmall)),
                          SizedBox(
                              width: 100,
                              child: Text(l.expiryDate ?? '—',
                                  style: T.monoBody
                                      .copyWith(fontSize: 12))),
                          SizedBox(
                              width: 110,
                              child: Text(label,
                                  style: T.monoBody.copyWith(
                                      fontSize: 12,
                                      color: color,
                                      fontWeight: FontWeight.w700))),
                          SizedBox(
                              width: 90,
                              child: Text('${fmtQty(l.qtyMilli)} u.',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }

  Future<void> _startInventory() async {
    final posted = await showDialog<DocDetail>(
      context: context,
      builder: (_) => _InventoryDialog(
        api: widget.api,
        warehouses: _warehouses,
        initialWarehouseId: _warehouseId,
      ),
    );
    if (posted != null && mounted) {
      _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Text(
            'Inventaire ${posted.number} validé — ${posted.lines.length} produit(s) ajusté(s).',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
      ));
    }
  }
}

class _ViewTab extends StatelessWidget {
  const _ViewTab(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
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
      ),
    );
  }
}

class _LotDialog extends StatefulWidget {
  const _LotDialog({required this.api, this.existing});
  final ApiClient api;
  final Lot? existing;

  @override
  State<_LotDialog> createState() => _LotDialogState();
}

class _LotDialogState extends State<_LotDialog> {
  Product? _product;
  late final _lotNumber =
      TextEditingController(text: widget.existing?.lotNumber ?? '');
  late final _qty = TextEditingController(
      text: widget.existing == null ? '' : fmtQty(widget.existing!.qtyMilli));
  late String? _expiry = widget.existing?.expiryDate;
  final _productSearch = TextEditingController();
  List<Product> _found = const [];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _lotNumber.dispose();
    _qty.dispose();
    _productSearch.dispose();
    super.dispose();
  }

  Future<void> _searchProduct(String q) async {
    try {
      final items = await widget.api.products(q: q, limit: 8);
      if (mounted) setState(() => _found = items);
    } catch (_) {}
  }

  Future<void> _pickExpiry() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_expiry ?? '') ??
          DateTime.now().add(const Duration(days: 90)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _expiry =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    final productId = widget.existing?.productId ?? _product?.id;
    if (productId == null) {
      setState(() => _error = 'Choisissez un produit.');
      return;
    }
    if (_expiry == null && _lotNumber.text.trim().isEmpty) {
      setState(() => _error = 'Renseignez la date de péremption.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveLot({
        'product_id': productId,
        'lot_number': _lotNumber.text.trim(),
        'expiry_date': _expiry,
        'qty_milli': parseQty(_qty.text) ?? 0,
      }, id: widget.existing?.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (widget.existing == null) return;
    try {
      await widget.api.deleteLot(widget.existing!.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 430,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? 'Nouveau lot' : 'Lot', style: T.h2),
              const SizedBox(height: 12),
              if (widget.existing == null) ...[
                const MicroLabel('Produit'),
                const SizedBox(height: 4),
                if (_product == null) ...[
                  SearchField(
                    controller: _productSearch,
                    hint: 'Rechercher le produit…',
                    onChanged: _searchProduct,
                  ),
                  for (final p in _found.take(5))
                    InkWell(
                      onTap: () => setState(() => _product = p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(p.name,
                            style: T.body.copyWith(fontSize: 12.5)),
                      ),
                    ),
                ] else
                  Row(children: [
                    Expanded(child: Text(_product!.name, style: T.body)),
                    TextButton(
                      onPressed: () => setState(() => _product = null),
                      child: Text('Changer',
                          style: T.small.copyWith(color: T.mintDark)),
                    ),
                  ]),
                const SizedBox(height: 8),
              ] else ...[
                Text(widget.existing!.productName, style: T.body),
                const SizedBox(height: 10),
              ],
              Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MicroLabel('Péremption'),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: _pickExpiry,
                          borderRadius: BorderRadius.circular(T.rInner),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            alignment: AlignmentDirectional.centerStart,
                            decoration: BoxDecoration(
                              color: T.bg,
                              borderRadius:
                                  BorderRadius.circular(T.rInner),
                              border: Border.all(color: T.border),
                            ),
                            child:
                                Text(_expiry ?? '—', style: T.monoBody),
                          ),
                        ),
                      ]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MicroLabel('Quantité'),
                        const SizedBox(height: 4),
                        Container(
                          height: 38,
                          decoration: BoxDecoration(
                            color: T.bg,
                            borderRadius: BorderRadius.circular(T.rInner),
                            border: Border.all(color: T.border),
                          ),
                          child: TextField(
                            controller: _qty,
                            style: T.monoBody,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                      ]),
                ),
              ]),
              const SizedBox(height: 10),
              const MicroLabel('N° de lot (facultatif)'),
              const SizedBox(height: 4),
              Container(
                height: 38,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: _lotNumber,
                  style: T.monoBody,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(children: [
                if (widget.existing != null)
                  TextButton(
                    onPressed: _delete,
                    child: Text('Supprimer',
                        style: T.small.copyWith(color: T.dangerDark)),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Enregistrer',
                    onPressed: _busy ? null : _save,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inventaire physique : saisir les quantités comptées, seuls les écarts sont
/// ajustés (document INVENTORY_COUNT posté).
class _InventoryDialog extends StatefulWidget {
  const _InventoryDialog(
      {required this.api, required this.warehouses, this.initialWarehouseId});
  final ApiClient api;
  final List<Warehouse> warehouses;
  final String? initialWarehouseId;

  @override
  State<_InventoryDialog> createState() => _InventoryDialogState();
}

class _InventoryDialogState extends State<_InventoryDialog> {
  late String? _warehouseId = widget.initialWarehouseId ??
      (widget.warehouses.isEmpty ? null : widget.warehouses.first.id);
  final _search = TextEditingController();
  List<Product> _products = const [];
  Map<String, int> _current = const {};
  final Map<String, TextEditingController> _counted = {};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    for (final c in _counted.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.products(limit: 500),
        widget.api.stockLevels(warehouseId: _warehouseId),
      ]);
      if (mounted) {
        setState(() {
          _products = results[0] as List<Product>;
          _current = {
            for (final l in results[1] as List<StockLevel>)
              l.productId: l.qtyMilli,
          };
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  TextEditingController _ctrlFor(String productId) =>
      _counted.putIfAbsent(productId, TextEditingController.new);

  Future<void> _post() async {
    if (_warehouseId == null || _busy) return;
    final lines = <Map<String, dynamic>>[];
    for (final e in _counted.entries) {
      final txt = e.value.text.trim();
      if (txt.isEmpty) continue;
      final counted = parseQty(txt);
      if (counted == null || counted < 0) continue;
      if (counted == (_current[e.key] ?? 0)) continue; // no écart
      final p = _products.where((x) => x.id == e.key);
      lines.add({
        'product_id': e.key,
        'description': p.isEmpty ? '' : p.first.name,
        'qty_milli': counted,
        // stock théorique affiché au moment du comptage : le serveur applique
        // l'écart (compté − théorique), pas la quantité brute.
        'expected_milli': _current[e.key] ?? 0,
        'unit_price': 0,
        'vat_rate': 0,
        'discount_pct': 0,
        'position': lines.length,
      });
    }
    if (lines.isEmpty) {
      setState(() =>
          _error = 'Aucun écart : saisissez les quantités réellement comptées.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await widget.api.createDraft({
        'doc_type': 'INVENTORY_COUNT',
        'doc_date': todayISO(),
        'warehouse_id': _warehouseId,
        'lines': lines,
      });
      final posted = await widget.api.postDocument(draft.id);
      if (mounted) Navigator.of(context).pop(posted);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final shown = [
      for (final p in _products)
        if (q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            (p.barcode ?? '').contains(q))
          p
    ];
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 640,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(
                      child: Text('Inventaire physique', style: T.h2)),
                  if (widget.warehouses.length > 1)
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _warehouseId,
                        style: T.body,
                        items: [
                          for (final w in widget.warehouses)
                            DropdownMenuItem(
                                value: w.id, child: Text(w.name)),
                        ],
                        onChanged: (v) {
                          setState(() => _warehouseId = v);
                          _load();
                        },
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ]),
                Text(
                    'Saisissez la quantité comptée — les lignes laissées vides '
                    'ne bougent pas.',
                    style: T.small),
                const SizedBox(height: 10),
                SearchField(
                  controller: _search,
                  hint: 'Filtrer les produits…',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, i) {
                      final p = shown[i];
                      final cur = _current[p.id] ?? 0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(children: [
                          Expanded(
                              child: Text(p.name,
                                  style: T.body.copyWith(fontSize: 12.5),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                          SizedBox(
                              width: 110,
                              child: Text('En stock : ${fmtQty(cur)}',
                                  style: T.monoSmall)),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 110,
                            child: Container(
                              height: 34,
                              decoration: BoxDecoration(
                                color: T.bg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: T.border),
                              ),
                              child: TextField(
                                controller: _ctrlFor(p.id),
                                textAlign: TextAlign.center,
                                style: T.monoBody.copyWith(fontSize: 12.5),
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: InputBorder.none,
                                  hintText: 'compté',
                                  hintStyle: T.small
                                      .copyWith(color: T.ghost, fontSize: 11),
                                  contentPadding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                ),
                              ),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_error!,
                        style: T.small.copyWith(color: T.dangerDark)),
                  ),
                const SizedBox(height: 10),
                PrimaryButton(
                  label: _busy ? 'Validation…' : "Valider l'inventaire",
                  big: true,
                  onPressed: _busy ? null : _post,
                ),
              ]),
        ),
      ),
    );
  }
}
