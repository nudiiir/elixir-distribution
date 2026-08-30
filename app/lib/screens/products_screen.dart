import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
import '../widgets/data_table.dart';
import '../widgets/ui.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen(
      {super.key, required this.api, required this.session, this.searchRequest});
  final ApiClient api;
  final Session session;

  /// Set by the shell's global search bar: switches here and applies the query.
  final ValueNotifier<String>? searchRequest;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  bool get _viewCost => widget.session.user.can('view_cost');

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Product> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.searchRequest?.addListener(_onExternalSearch);
    _load();
  }

  void _onExternalSearch() {
    final q = widget.searchRequest?.value ?? '';
    if (q.isEmpty) return;
    _searchCtrl.text = q;
    _load();
  }

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_onExternalSearch);
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items =
          await widget.api.products(q: _searchCtrl.text.trim(), limit: 500);
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openForm({Product? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProductFormDialog(
          api: widget.api, existing: existing, showCost: _viewCost),
    );
    if (saved == true) _load();
  }

  int? _margin(Product p) {
    if (p.purchasePrice <= 0) return null;
    return ((p.unitPriceHT - p.purchasePrice) * 100 / p.purchasePrice).round();
  }

  Future<void> _export(List<Product> rows) async {
    final path = await exportCsv(
      baseName: 'produits',
      headers: [
        'Produit',
        'Code-barres',
        'TVA (%)',
        if (_viewCost) 'Achat HT (DA)',
        'Vente TTC (DA)',
        if (_viewCost) 'Marge (%)',
      ],
      rows: [
        for (final p in rows)
          [
            p.name,
            p.barcode ?? '',
            '${p.vatRate ~/ 100}',
            if (_viewCost) editDA(p.purchasePrice),
            editDA(p.priceRetail),
            if (_viewCost) _margin(p)?.toString() ?? '',
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Produits', style: T.h1),
            const Spacer(),
            SizedBox(
              width: 180,
              child: PrimaryButton(
                label: 'Nouveau produit',
                onPressed: () => _openForm(),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          SearchField(
            controller: _searchCtrl,
            hint: 'Rechercher un produit ou scanner…',
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), _load);
            },
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Product>(
              items: _items,
              onTap: (p) => _openForm(existing: p),
              onExport: _export,
              empty: EmptyState(
                  icon: Icons.category_outlined,
                  text: _loading ? 'Chargement…' : 'Aucun produit'),
              aggregates: (rows) {
                if (!_viewCost) return const [];
                final margins = [
                  for (final p in rows)
                    if (_margin(p) != null) _margin(p)!
                ];
                final avg = margins.isEmpty
                    ? null
                    : (margins.reduce((a, b) => a + b) / margins.length)
                        .round();
                return [
                  if (avg != null) ('Marge moyenne', '$avg%'),
                ];
              },
              columns: [
                ColumnSpec(
                  label: 'Produit',
                  flex: 5,
                  sortKey: (p) => p.name.toLowerCase(),
                  cell: (context, p) => Text(p.name,
                      style: T.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  label: 'Code-barres',
                  flex: 3,
                  sortKey: (p) => p.barcode ?? '',
                  cell: (context, p) =>
                      Text(p.barcode ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  label: 'TVA',
                  width: 56,
                  sortKey: (p) => p.vatRate,
                  cell: (context, p) =>
                      Text('${p.vatRate ~/ 100}%', style: T.monoSmall),
                ),
                if (_viewCost)
                  ColumnSpec(
                    label: 'Achat HT',
                    width: 110,
                    numeric: true,
                    sortKey: (p) => p.purchasePrice,
                    cell: (context, p) => Text(fmtDA(p.purchasePrice),
                        style: T.monoBody.copyWith(color: T.muted)),
                  ),
                ColumnSpec(
                  label: 'Vente TTC',
                  width: 110,
                  numeric: true,
                  sortKey: (p) => p.priceRetail,
                  cell: (context, p) =>
                      Text(fmtDA(p.priceRetail), style: T.monoBody),
                ),
                if (_viewCost)
                  ColumnSpec(
                    label: 'Marge',
                    width: 75,
                    numeric: true,
                    sortKey: (p) => _margin(p) ?? -9999,
                    cell: (context, p) {
                      final m = _margin(p);
                      return Text(m == null ? '—' : '$m%',
                          style: T.monoSmall.copyWith(
                              color: m != null && m < 0
                                  ? T.dangerDark
                                  : T.mintDark));
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductFormDialog extends StatefulWidget {
  const _ProductFormDialog(
      {required this.api, this.existing, this.showCost = true});
  final ApiClient api;
  final Product? existing;
  final bool showCost;

  @override
  State<_ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends State<_ProductFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _nameAr =
      TextEditingController(text: widget.existing?.nameAr ?? '');
  late final _barcode =
      TextEditingController(text: widget.existing?.barcode ?? '');
  late final _purchase = TextEditingController(
      text: widget.existing == null
          ? ''
          : editDA(widget.existing!.purchasePrice));
  late final _retail = TextEditingController(
      text:
          widget.existing == null ? '' : editDA(widget.existing!.priceRetail));
  late final _minStock = TextEditingController(
      text: widget.existing == null || widget.existing!.minStockMilli == 0
          ? ''
          : fmtQty(widget.existing!.minStockMilli));
  late int _vat = widget.existing?.vatRate ?? 1900;
  late bool _weighable = widget.existing?.isWeighable ?? false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _nameAr, _barcode, _purchase, _retail, _minStock]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Le nom est obligatoire.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveProduct({
        'name': _name.text.trim(),
        'name_ar': _nameAr.text.trim().isEmpty ? null : _nameAr.text.trim(),
        'barcode': _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
        'vat_rate': _vat,
        'purchase_price': parseDA(_purchase.text) ?? 0,
        'price_retail': parseDA(_retail.text) ?? 0,
        'min_stock_milli': parseQty(_minStock.text) ?? 0,
        'is_weighable': _weighable,
        'unit': _weighable ? 'kg' : 'piece',
      }, id: widget.existing?.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 540,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  widget.existing == null
                      ? 'Nouveau produit'
                      : widget.existing!.name,
                  style: T.h2),
              const SizedBox(height: 16),
              _Field(label: 'Désignation', controller: _name),
              Row(children: [
                Expanded(
                    child: _Field(
                        label: 'Désignation (arabe)', controller: _nameAr)),
                const SizedBox(width: 10),
                Expanded(
                    child: _Field(label: 'Code-barres', controller: _barcode)),
              ]),
              Row(children: [
                if (widget.showCost) ...[
                  Expanded(
                      child: _Field(
                          label: "Prix d'achat HT (DA)",
                          controller: _purchase,
                          mono: true)),
                  const SizedBox(width: 10),
                ],
                Expanded(
                    child: _Field(
                        label: 'Prix de vente TTC (DA)',
                        controller: _retail,
                        mono: true)),
              ]),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MicroLabel('TVA'),
                        const SizedBox(height: 4),
                        Wrap(spacing: 6, children: [
                          for (final v in [1900, 900, 0])
                            ChoiceChip(
                              label: Text('${v ~/ 100}%',
                                  style: TextStyle(
                                      fontFamily: T.mono,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          _vat == v ? T.mintDark : T.muted)),
                              selected: _vat == v,
                              selectedColor: T.mintTint,
                              backgroundColor: T.bg,
                              side: BorderSide(
                                  color: _vat == v ? T.mintDeep : T.border),
                              showCheckmark: false,
                              onSelected: (_) => setState(() => _vat = v),
                            ),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _Field(
                          label: 'Stock minimum',
                          controller: _minStock,
                          mono: true)),
                ],
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () => setState(() => _weighable = !_weighable),
                child: Row(children: [
                  Icon(
                      _weighable
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: _weighable ? T.mintDeep : T.faint),
                  const SizedBox(width: 8),
                  Text('Produit au poids (kg)', style: T.bodyMuted),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
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

class _Field extends StatelessWidget {
  const _Field(
      {required this.label, required this.controller, this.mono = false});
  final String label;
  final TextEditingController controller;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MicroLabel(label),
          const SizedBox(height: 4),
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: TextField(
              controller: controller,
              style: mono ? T.monoBody : T.body,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
