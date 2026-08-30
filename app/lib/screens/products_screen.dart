import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
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
  List<Category> _cats = const [];
  String? _catFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.searchRequest?.addListener(_onExternalSearch);
    _load();
    _loadCats();
  }

  Future<void> _loadCats() async {
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
  }

  String _catName(String? id) {
    for (final c in _cats) {
      if (c.id == id) return c.name;
    }
    return '—';
  }

  Future<void> _manageCats() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CategoriesDialog(api: widget.api),
    );
    _loadCats();
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
            OutlinedButton.icon(
              onPressed: _manageCats,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: T.border3),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(T.rInner)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              icon: const Icon(Icons.sell_outlined, size: 16, color: T.ink),
              label: Text('Catégories',
                  style: T.small
                      .copyWith(color: T.ink, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
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
          if (_cats.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 32,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                _CatFilterChip(
                  label: 'Toutes',
                  selected: _catFilter == null,
                  onTap: () => setState(() => _catFilter = null),
                ),
                for (final c in _cats)
                  _CatFilterChip(
                    label: c.name,
                    selected: _catFilter == c.id,
                    onTap: () => setState(
                        () => _catFilter = _catFilter == c.id ? null : c.id),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Product>(
              items: [
                for (final p in _items)
                  if (_catFilter == null || p.categoryId == _catFilter) p
              ],
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
                  label: 'Catégorie',
                  flex: 2,
                  sortKey: (p) => _catName(p.categoryId),
                  cell: (context, p) => Text(_catName(p.categoryId),
                      style: T.small.copyWith(fontSize: 11.5),
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
  late final _extraBarcodes = TextEditingController(
      text: widget.existing?.barcodes.join(', ') ?? '');
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
  late final _promoPrice = TextEditingController(
      text: widget.existing?.promoPrice == null
          ? ''
          : editDA(widget.existing!.promoPrice!));
  late final _warranty = TextEditingController(
      text: widget.existing == null || widget.existing!.warrantyMonths == 0
          ? ''
          : '${widget.existing!.warrantyMonths}');
  late final _wholesale = TextEditingController(
      text: widget.existing?.priceWholesale == null
          ? ''
          : editDA(widget.existing!.priceWholesale!));
  late int _vat = widget.existing?.vatRate ?? 1900;
  late bool _weighable = widget.existing?.isWeighable ?? false;
  late bool _trackSerials = widget.existing?.trackSerials ?? false;
  late String? _categoryId = widget.existing?.categoryId;
  List<Category> _cats = const [];
  bool _generating = false;
  late String? _promoStart = widget.existing?.promoStart;
  late String? _promoEnd = widget.existing?.promoEnd;
  List<Product> _variants = const [];
  List<ProductUnit> _units = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVariants();
    _loadCats();
    _loadUnits();
  }

  Future<void> _loadCats() async {
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
  }

  Future<void> _loadUnits() async {
    final p = widget.existing;
    if (p == null || !p.trackSerials) return;
    try {
      final units = await widget.api.units(productId: p.id);
      if (mounted) setState(() => _units = units);
    } catch (_) {}
  }

  Future<void> _addSerials() async {
    final p = widget.existing;
    if (p == null) return;
    final ctrl = TextEditingController();
    bool used = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDlg) => Dialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rCard)),
          child: SizedBox(
            width: 400,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Ajouter des N° de série', style: T.h2),
                  const SizedBox(height: 4),
                  Text('Un numéro par ligne — scannez-les à la suite.',
                      style: T.small),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: TextField(
                      controller: ctrl,
                      autofocus: true,
                      maxLines: 7,
                      style: T.monoBody,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () => setDlg(() => used = !used),
                    child: Row(children: [
                      Icon(
                          used
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 18,
                          color: used ? T.mintDeep : T.faint),
                      const SizedBox(width: 8),
                      Text('Appareils d\'occasion (reprise)',
                          style: T.bodyMuted),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text('Annuler',
                          style: T.small.copyWith(color: T.muted)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 120,
                      child: PrimaryButton(
                        label: 'Ajouter',
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (ok == true) {
      final serials = [
        for (final line in ctrl.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim()
      ];
      if (serials.isNotEmpty) {
        try {
          final (added, dupes) =
              await widget.api.addUnits(p.id, serials, isUsed: used);
          if (mounted) {
            setState(() => _error = dupes.isEmpty
                ? null
                : 'Déjà connus (ignorés) : ${dupes.join(', ')}');
          }
          if (added > 0) _loadUnits();
        } on ApiException catch (e) {
          setState(() => _error = e.message);
        }
      }
    }
    ctrl.dispose();
  }

  Future<void> _loadVariants() async {
    final parent = widget.existing;
    if (parent == null || parent.parentProductId != null) return;
    try {
      final all = await widget.api.products(limit: 500);
      if (mounted) {
        setState(() => _variants =
            all.where((p) => p.parentProductId == parent.id).toList());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final c in [
      _name, _nameAr, _barcode, _extraBarcodes, _purchase, _retail,
      _minStock, _promoPrice, _warranty, _wholesale
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPromoDate(bool start) async {
    final current = start ? _promoStart : _promoEnd;
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(current ?? '') ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      final iso =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      setState(() {
        if (start) {
          _promoStart = iso;
        } else {
          _promoEnd = iso;
        }
      });
    }
  }

  Future<void> _generateBarcode() async {
    setState(() => _generating = true);
    try {
      final code = await widget.api.generateBarcode();
      setState(() => _barcode.text = code);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Serveur injoignable.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// Renders the product's shelf label with the shop's label template.
  Future<void> _printLabel() async {
    final p = widget.existing;
    if (p == null) return;
    try {
      final rec = await widget.api.defaultTemplate('label');
      final tpl =
          rec == null ? defaultTplDoc('label', 'fr') : TplDoc.fromJson(rec.body);
      final company = await widget.api.settings();
      final bytes = await renderTemplateBytes(tpl,
          lang: rec?.lang ?? 'fr', data: labelData(p, company));
      await saveAndOpenPdf(bytes, 'etiquette-${p.name}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Étiquette impossible : $e');
    }
  }

  Future<void> _addVariant() async {
    final parent = widget.existing;
    if (parent == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _VariantDialog(api: widget.api, parent: parent),
    );
    if (saved == true) _loadVariants();
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
      final promo = parseDA(_promoPrice.text);
      await widget.api.saveProduct({
        'name': _name.text.trim(),
        'name_ar': _nameAr.text.trim().isEmpty ? null : _nameAr.text.trim(),
        'barcode': _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
        'barcodes': [
          for (final b in _extraBarcodes.text.split(RegExp(r'[,;\s]+')))
            if (b.trim().isNotEmpty) b.trim()
        ],
        'vat_rate': _vat,
        'purchase_price': parseDA(_purchase.text) ?? 0,
        'price_retail': parseDA(_retail.text) ?? 0,
        'min_stock_milli': parseQty(_minStock.text) ?? 0,
        'is_weighable': _weighable,
        'unit': _weighable ? 'kg' : 'piece',
        'promo_price': (promo != null && promo > 0) ? promo : null,
        'promo_start': (promo != null && promo > 0) ? _promoStart : null,
        'promo_end': (promo != null && promo > 0) ? _promoEnd : null,
        'warranty_months': int.tryParse(_warranty.text.trim()) ?? 0,
        'category_id': _categoryId,
        'price_wholesale': parseDA(_wholesale.text),
        'track_serials': _trackSerials,
        'parent_product_id': widget.existing?.parentProductId,
        'variant_label': widget.existing?.variantLabel,
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
        width: 560,
        child: SingleChildScrollView(
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
              if (widget.existing?.variantLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: MintChip('variante · ${widget.existing!.variantLabel}',
                      color: T.mintTint, fg: T.mintDark),
                ),
              const SizedBox(height: 16),
              _Field(label: 'Désignation', controller: _name),
              Row(children: [
                Expanded(
                    child: _Field(
                        label: 'Désignation (arabe)', controller: _nameAr)),
                const SizedBox(width: 10),
                Expanded(
                    child: _Field(
                        label: 'Code-barres',
                        controller: _barcode,
                        mono: true,
                        trailing: Tooltip(
                          message:
                              'Générer un code-barres interne (produit sans code)',
                          child: InkWell(
                            onTap: _generating ? null : _generateBarcode,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              child: Icon(
                                  _generating
                                      ? Icons.hourglass_top_rounded
                                      : Icons.auto_fix_high_rounded,
                                  size: 16,
                                  color: T.mintDark),
                            ),
                          ),
                        ))),
              ]),
              Row(children: [
                if (widget.showCost) ...[
                  Expanded(
                      child: _Field(
                          label: _weighable
                              ? "Prix d'achat HT (DA/kg)"
                              : "Prix d'achat HT (DA)",
                          controller: _purchase,
                          mono: true)),
                  const SizedBox(width: 10),
                ],
                Expanded(
                    child: _Field(
                        label: _weighable
                            ? 'Prix de vente TTC (DA/kg)'
                            : 'Prix de vente TTC (DA)',
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
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const MicroLabel('Catégorie'),
                      const SizedBox(height: 4),
                      Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: T.bg,
                          borderRadius: BorderRadius.circular(T.rInner),
                          border: Border.all(color: T.border),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            value: _cats.any((c) => c.id == _categoryId)
                                ? _categoryId
                                : null,
                            isExpanded: true,
                            style: T.body,
                            dropdownColor: T.surface,
                            items: [
                              const DropdownMenuItem<String?>(
                                  value: null, child: Text('Sans catégorie')),
                              for (final c in _cats)
                                DropdownMenuItem<String?>(
                                    value: c.id, child: Text(c.name)),
                            ],
                            onChanged: (v) =>
                                setState(() => _categoryId = v),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                    child: _Field(
                        label: 'Prix demi-gros TTC (DA) — vide = aucun',
                        controller: _wholesale,
                        mono: true)),
              ]),
              Row(children: [
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
                const SizedBox(width: 20),
                InkWell(
                  onTap: () =>
                      setState(() => _trackSerials = !_trackSerials),
                  child: Row(children: [
                    Icon(
                        _trackSerials
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 18,
                        color: _trackSerials ? T.mintDeep : T.faint),
                    const SizedBox(width: 8),
                    Text('Suivi par N° de série / IMEI', style: T.bodyMuted),
                  ]),
                ),
              ]),
              const SizedBox(height: 12),
              _Field(
                  label:
                      'Codes-barres supplémentaires (séparés par des virgules)',
                  controller: _extraBarcodes,
                  mono: true),
              Row(children: [
                Expanded(
                    child: _Field(
                        label: 'Garantie (mois) — vide = sans garantie',
                        controller: _warranty,
                        mono: true)),
                const SizedBox(width: 10),
                if (widget.existing != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: OutlinedButton.icon(
                      onPressed: _printLabel,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: T.border3),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(T.rInner)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                      ),
                      icon: const Icon(Icons.qr_code_2_rounded,
                          size: 16, color: T.ink),
                      label: Text('Étiquette',
                          style: T.small.copyWith(
                              color: T.ink, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
              // ---- Serialized units (IMEI) ----
              if (widget.existing != null &&
                  widget.existing!.trackSerials) ...[
                const Divider(height: 20),
                Row(children: [
                  Expanded(
                    child: MicroLabel(
                        'N° de série — ${_units.where((u) => u.status == 'in_stock').length} en stock / ${_units.length} connus'),
                  ),
                  TextButton.icon(
                    onPressed: _addSerials,
                    icon: const Icon(Icons.add, size: 14, color: T.mintDark),
                    label: Text('Ajouter des numéros',
                        style: T.small.copyWith(
                            color: T.mintDark, fontWeight: FontWeight.w700)),
                  ),
                ]),
                for (final u in _units.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(children: [
                      Icon(
                          u.status == 'in_stock'
                              ? Icons.inventory_2_outlined
                              : Icons.sell_outlined,
                          size: 13,
                          color:
                              u.status == 'in_stock' ? T.mintDeep : T.faint),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(u.serial,
                              style: T.monoSmall.copyWith(fontSize: 11))),
                      if (u.isUsed)
                        const MintChip('occasion',
                            color: T.warnTint, fg: T.warnDark),
                      const SizedBox(width: 6),
                      Text(
                          switch (u.status) {
                            'in_stock' => 'en stock',
                            'sold' => 'vendu',
                            'returned' => 'retourné',
                            'repair' => 'en SAV',
                            _ => 'rebuté',
                          },
                          style: T.small.copyWith(fontSize: 10.5)),
                    ]),
                  ),
                if (_units.length > 6)
                  Text('… et ${_units.length - 6} autres', style: T.small),
              ],
              // ---- Promotion ----
              const Divider(height: 20),
              const MicroLabel('Promotion'),
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                    child: _Field(
                        label: 'Prix promo TTC (DA) — vide = pas de promo',
                        controller: _promoPrice,
                        mono: true)),
                const SizedBox(width: 10),
                _PromoDateBtn(
                    label: 'Du',
                    value: _promoStart,
                    onTap: () => _pickPromoDate(true)),
                const SizedBox(width: 8),
                _PromoDateBtn(
                    label: 'Au',
                    value: _promoEnd,
                    onTap: () => _pickPromoDate(false)),
              ]),
              // ---- Variants (only on a parent product being edited) ----
              if (widget.existing != null &&
                  widget.existing!.parentProductId == null) ...[
                const Divider(height: 20),
                Row(children: [
                  const Expanded(child: MicroLabel('Variantes')),
                  TextButton.icon(
                    onPressed: _addVariant,
                    icon: const Icon(Icons.add, size: 14, color: T.mintDark),
                    label: Text('Ajouter une variante',
                        style: T.small.copyWith(
                            color: T.mintDark, fontWeight: FontWeight.w700)),
                  ),
                ]),
                if (_variants.isEmpty)
                  Text(
                      'Aucune variante — ex. « 2L », « Rouge », chacune avec '
                      'son prix et son code-barres.',
                      style: T.small)
                else
                  for (final v in _variants)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(children: [
                        const Icon(Icons.subdirectory_arrow_right,
                            size: 14, color: T.faint),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(v.variantLabel ?? v.name,
                                style: T.body.copyWith(fontSize: 12.5))),
                        Text(fmtDA(v.priceRetail), style: T.monoSmall),
                      ]),
                    ),
              ],
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
      ),
    );
  }
}

class _CatFilterChip extends StatelessWidget {
  const _CatFilterChip(
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

/// Gestion des catégories (rayons) : ajouter, renommer, supprimer.
class _CategoriesDialog extends StatefulWidget {
  const _CategoriesDialog({required this.api});
  final ApiClient api;

  @override
  State<_CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends State<_CategoriesDialog> {
  List<Category> _cats = const [];
  final _newCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
  }

  Future<void> _add() async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty) return;
    try {
      await widget.api.createCategory(name);
      _newCtrl.clear();
      _load();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _rename(Category c) async {
    final ctrl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const MicroLabel('Renommer la catégorie'),
              const SizedBox(height: 8),
              Container(
                height: 38,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: T.body,
                  onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'Renommer',
                onPressed: () =>
                    Navigator.of(context).pop(ctrl.text.trim()),
              ),
            ]),
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty && name != c.name) {
      try {
        await widget.api.renameCategory(c.id, name);
        _load();
      } on ApiException catch (e) {
        setState(() => _error = e.message);
      }
    }
  }

  Future<void> _delete(Category c) async {
    try {
      await widget.api.deleteCategory(c.id);
      _load();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 380,
        height: 440,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(
                      child: Text('Catégories', style: T.h2)),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ]),
                Text('Rayons du magasin — filtre à la caisse et rapports.',
                    style: T.small),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_error!,
                        style: T.small.copyWith(color: T.dangerDark)),
                  ),
                const SizedBox(height: 10),
                Expanded(
                  child: _cats.isEmpty
                      ? const EmptyState(
                          icon: Icons.sell_outlined,
                          text:
                              'Aucune catégorie.\nEx. Boissons, Téléphones, Accessoires…')
                      : ListView.separated(
                          itemCount: _cats.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, i) {
                            final c = _cats[i];
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(children: [
                                Expanded(
                                    child: Text(c.name, style: T.body)),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Renommer',
                                  onPressed: () => _rename(c),
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 15, color: T.muted),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Supprimer',
                                  onPressed: () => _delete(c),
                                  icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 16,
                                      color: T.dangerDark),
                                ),
                              ]),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Container(
                      height: 38,
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: TextField(
                        controller: _newCtrl,
                        style: T.body,
                        onSubmitted: (_) => _add(),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Nouvelle catégorie…',
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 100,
                      child:
                          PrimaryButton(label: 'Ajouter', onPressed: _add)),
                ]),
              ]),
        ),
      ),
    );
  }
}

class _PromoDateBtn extends StatelessWidget {
  const _PromoDateBtn(
      {required this.label, required this.value, required this.onTap});
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rInner),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MicroLabel(label),
          const SizedBox(height: 2),
          Text(value ?? '—', style: T.monoBody.copyWith(fontSize: 11.5)),
        ]),
      ),
    );
  }
}

/// Creates a sibling product linked to [parent] — its own price, barcode and
/// stock, sold as a normal product at the POS.
class _VariantDialog extends StatefulWidget {
  const _VariantDialog({required this.api, required this.parent});
  final ApiClient api;
  final Product parent;

  @override
  State<_VariantDialog> createState() => _VariantDialogState();
}

class _VariantDialogState extends State<_VariantDialog> {
  final _label = TextEditingController();
  final _price = TextEditingController();
  final _purchase = TextEditingController();
  final _bc = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_label, _price, _purchase, _bc]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final label = _label.text.trim();
    final price = parseDA(_price.text);
    if (label.isEmpty || price == null || price <= 0) {
      setState(() => _error = 'Libellé et prix de vente obligatoires.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = widget.parent;
      await widget.api.saveProduct({
        'name': '${p.name} — $label',
        'barcode': _bc.text.trim().isEmpty ? null : _bc.text.trim(),
        'vat_rate': p.vatRate,
        'purchase_price': parseDA(_purchase.text) ?? 0,
        'price_retail': price,
        'min_stock_milli': 0,
        'is_weighable': p.isWeighable,
        'unit': p.unit,
        'parent_product_id': p.id,
        'variant_label': label,
      });
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
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Variante de ${widget.parent.name}', style: T.h2),
              const SizedBox(height: 14),
              _Field(label: 'Libellé (ex. 2L, Rouge, XL)', controller: _label),
              Row(children: [
                Expanded(
                    child: _Field(
                        label: 'Prix de vente TTC (DA)',
                        controller: _price,
                        mono: true)),
                const SizedBox(width: 10),
                Expanded(
                    child: _Field(
                        label: "Prix d'achat HT (DA)",
                        controller: _purchase,
                        mono: true)),
              ]),
              _Field(label: 'Code-barres', controller: _bc, mono: true),
              if (_error != null)
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              const SizedBox(height: 14),
              Row(children: [
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
                    label: _busy ? '…' : 'Créer',
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
      {required this.label,
      required this.controller,
      this.mono = false,
      this.trailing});
  final String label;
  final TextEditingController controller;
  final bool mono;
  final Widget? trailing;

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
            child: Row(children: [
              Expanded(
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
              ?trailing,
            ]),
          ),
        ],
      ),
    );
  }
}
