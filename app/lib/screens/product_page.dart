import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/shortcuts.dart';
import '../widgets/app_page.dart';
import '../widgets/fiche_produit.dart'
    show pasteProductPhoto, pickProductPhoto, printProductLabels;
import '../widgets/product_thumb.dart';
import '../widgets/ui.dart';

/// Opens the full product page (création ET modification), pushed in the
/// current navigator (inside the module, menu still visible). [template]
/// pre-fills a new product (« Dupliquer ») — never its barcodes. Returns
/// true when anything was saved, false when left without saving, null when
/// closed from outside (breadcrumb « Produits », menu command).
Future<bool?> openProductPage(
  BuildContext context, {
  required ApiClient api,
  Product? existing,
  Product? template,
  required bool showCost,
  List<String> brands = const [],
}) {
  return _push(Navigator.of(context),
      api: api,
      existing: existing,
      template: template,
      showCost: showCost,
      brands: brands);
}

Future<bool?> _push(
  NavigatorState nav, {
  required ApiClient api,
  Product? existing,
  Product? template,
  required bool showCost,
  List<String> brands = const [],
}) {
  return nav.push<bool>(MaterialPageRoute(
    builder: (_) => ProductPage(
      api: api,
      existing: existing,
      template: template,
      showCost: showCost,
      brands: brands,
    ),
  ));
}

/// Product pages currently open with unsaved changes.
final Set<_ProductPageState> _dirtyPages = {};

/// Called before closing the product pages from outside (menu command,
/// breadcrumb): asks once when one of them has unsaved changes. True = go
/// ahead (the changes are dropped).
Future<bool> confirmLeaveProductPages(BuildContext context) async {
  final dirty = _dirtyPages.where((s) => s.mounted && s._dirty).toList();
  if (dirty.isEmpty) return true;
  final ok = await confirmAction(context,
      title: 'Quitter sans enregistrer ?',
      message: 'Les modifications du produit en cours seront perdues.',
      confirmLabel: 'Quitter',
      danger: true);
  if (!ok) return false;
  for (final s in dirty) {
    s._dirty = false;
  }
  _dirtyPages.clear();
  return true;
}

class ProductPage extends StatefulWidget {
  const ProductPage({
    super.key,
    required this.api,
    this.existing,
    this.template,
    required this.showCost,
    this.brands = const [],
  });
  final ApiClient api;
  final Product? existing;
  final Product? template;
  final bool showCost;
  final List<String> brands;

  @override
  State<ProductPage> createState() => _ProductPageState();
}

// ---- small editable rows ----

class _PackRow {
  _PackRow({String name = 'Carton', String factor = '', String barcode = ''})
      : name = TextEditingController(text: name),
        factor = TextEditingController(text: factor),
        barcode = TextEditingController(text: barcode);
  final TextEditingController name, factor, barcode;
  void dispose() {
    name.dispose();
    factor.dispose();
    barcode.dispose();
  }
}

class _OptionRow {
  _OptionRow(String name) : name = TextEditingController(text: name);
  final TextEditingController name;
  final input = TextEditingController();
  final focus = FocusNode();
  final List<String> values = [];
  void dispose() {
    name.dispose();
    input.dispose();
    focus.dispose();
  }
}

class _VariantRow {
  _VariantRow({String price = '', String cost = ''})
      : price = TextEditingController(text: price),
        cost = TextEditingController(text: cost);
  final barcode = TextEditingController();
  final TextEditingController price, cost;
  void dispose() {
    barcode.dispose();
    price.dispose();
    cost.dispose();
  }
}

const _newSentinel = '\u0000new';

class _ProductPageState extends State<ProductPage> {
  Features get _f => Features.instance;

  /// Produit en cours de modification (null = création). Devient null après
  /// « Enregistrer et nouveau ».
  late Product? _existing = widget.existing;
  bool get _isEdit => _existing != null;
  Product? get _src => widget.existing ?? widget.template;

  // ---- Identité ----
  late final _barcode = TextEditingController(text: widget.existing?.barcode ?? '');
  late final _name = TextEditingController(
      text: widget.existing?.name ??
          (widget.template == null ? '' : '${widget.template!.name} (copie)'));
  late final _nameAr = TextEditingController(text: _src?.nameAr ?? '');
  late final List<BarcodeEntry> _bcodes =
      List.of(widget.existing?.barcodesEx ?? const []);
  final _newBcode = TextEditingController();
  final _newBcodeLabel = TextEditingController();
  final List<(Uint8List, String)> _pendingPhotos = [];
  bool _busyPhoto = false;

  // ---- Prix ----
  late final _purchase = TextEditingController(
      text: _src == null || _src!.purchasePrice == 0
          ? ''
          : editDA(_src!.purchasePrice));
  final _margin = TextEditingController();
  late final _frozenCost = TextEditingController(
      text: widget.existing == null ? '' : editDA(widget.existing!.purchasePrice));
  late final _retail = TextEditingController(
      text: _src == null || _src!.priceRetail == 0 ? '' : editDA(_src!.priceRetail));
  late final _wholesale = TextEditingController(
      text: _src?.priceWholesale == null ? '' : editDA(_src!.priceWholesale!));
  late int _vat = _src?.vatRate ?? Features.instance.defaultVat;

  // ---- Classement ----
  late String? _categoryId = _src?.categoryId;
  late final _brand = TextEditingController(text: _src?.brand ?? '');
  final _brandFocus = FocusNode();
  late String? _supplierId = _src?.defaultSupplierId;
  List<Category> _cats = const [];
  List<Partner> _suppliers = const [];
  late List<String> _brands = widget.brands;

  // ---- Stock ----
  final _initialQty = TextEditingController();
  late final _minStock = TextEditingController(
      text: _src == null || _src!.minStockMilli == 0 ? '' : fmtQty(_src!.minStockMilli));
  late final List<_PackRow> _packs = [
    for (final k in _src?.packagings ?? const <Packaging>[])
      _PackRow(
          name: k.name,
          factor: fmtQty(k.factorMilli),
          barcode: widget.existing == null ? '' : (k.barcode ?? '')),
  ];
  late bool _soldByPack = _packs.isNotEmpty;

  // ---- Suivi / type ----
  late bool _lot = (_src?.trackLots ?? false) || (_src?.trackExpiry ?? false);
  late bool _serial = _src?.trackSerials ?? false;
  late bool _weighed = _src?.isWeighable ?? false;
  late bool _variantsOn = false;
  late String _kind = _src?.kind ?? 'standard';
  List<ProductUnit> _units = const [];
  List<Product> _existingVariants = const [];
  final List<_OptionRow> _options = [_OptionRow('Taille'), _OptionRow('Couleur')];
  final Map<String, _VariantRow> _variantRows = {};

  // ---- Colonne droite ----
  late bool _active = widget.existing?.active ?? true;
  late final _description = TextEditingController(text: _src?.description ?? '');
  late final _warranty = TextEditingController(
      text: _src == null || _src!.warrantyMonths == 0 ? '' : '${_src!.warrantyMonths}');
  late final _promoPrice = TextEditingController(
      text: widget.existing?.promoPrice == null ? '' : editDA(widget.existing!.promoPrice!));
  late String? _promoStart = widget.existing?.promoStart;
  late String? _promoEnd = widget.existing?.promoEnd;

  // ---- État ----
  final Map<String, String> _errors = {};
  final _keys = <String, GlobalKey>{};
  final _focus = <String, FocusNode>{};
  bool _isDirty = false;
  bool get _dirty => _isDirty;
  set _dirty(bool v) {
    _isDirty = v;
    v ? _dirtyPages.add(this) : _dirtyPages.remove(this);
  }

  bool _busy = false;
  bool _savedAny = false;
  bool _generating = false;

  /// « Options avancées » (nom arabe, codes-barres en plus, emballages,
  /// n° de série) — open from the start when the product uses them.
  late bool _advanced = (_src?.nameAr ?? '').isNotEmpty ||
      (widget.existing?.barcodesEx.isNotEmpty ?? false) ||
      (_src?.packagings.isNotEmpty ?? false);

  GlobalKey _k(String id) => _keys.putIfAbsent(id, GlobalKey.new);
  FocusNode _fn(String id) => _focus.putIfAbsent(id, FocusNode.new);

  @override
  void initState() {
    super.initState();
    if (_isEdit || widget.template != null) _recomputeMargin();
    _loadLists();
    _loadUnits();
    _loadVariants();
  }

  @override
  void dispose() {
    for (final c in [
      _barcode, _name, _nameAr, _newBcode, _newBcodeLabel, _purchase, _margin,
      _retail, _wholesale, _brand, _initialQty, _minStock, _description,
      _warranty, _promoPrice, _frozenCost,
    ]) {
      c.dispose();
    }
    for (final p in _packs) {
      p.dispose();
    }
    for (final o in _options) {
      o.dispose();
    }
    for (final v in _variantRows.values) {
      v.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _brandFocus.dispose();
    _dirtyPages.remove(this);
    super.dispose();
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _loadLists() async {
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
    try {
      final sup = await widget.api.partners(kind: 'supplier', limit: 500);
      if (mounted) setState(() => _suppliers = sup);
    } catch (_) {}
    if (_brands.isEmpty) {
      try {
        final all = await widget.api.products(limit: 500, includeInactive: true);
        if (mounted) {
          setState(() => _brands = {
                for (final p in all)
                  if (p.brand.isNotEmpty) p.brand
              }.toList()
                ..sort());
        }
      } catch (_) {}
    }
  }

  Future<void> _loadUnits() async {
    final p = _existing;
    if (p == null || !p.trackSerials) return;
    try {
      final units = await widget.api.units(productId: p.id);
      if (mounted) setState(() => _units = units);
    } catch (_) {}
  }

  Future<void> _loadVariants() async {
    final p = _existing;
    if (p == null || p.parentProductId != null) return;
    try {
      final all = await widget.api.products(limit: 500, includeInactive: true);
      if (mounted) {
        setState(() => _existingVariants =
            all.where((v) => v.parentProductId == p.id).toList());
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- prix

  /// Coût de référence de la marge : saisi à la création, figé ensuite.
  int get _cost => _isEdit
      ? _existing!.purchasePrice
      : (parseDA(_purchase.text) ?? 0);

  int? _parseMargin(String s) {
    final t = s.replaceAll('%', '').replaceAll(' ', '').replaceAll(',', '.').trim();
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v == null ? null : (v * 100).round();
  }

  String _fmtPct(int v) =>
      (v / 100).toStringAsFixed(1).replaceAll('.', ',');

  void _recomputeMargin() {
    final cost = _cost;
    final ttc = parseDA(_retail.text) ?? 0;
    if (cost <= 0 || ttc <= 0) {
      _margin.text = '';
      return;
    }
    final pvHT = roundDiv(ttc * 10000, 10000 + _vat);
    _margin.text = _fmtPct(roundDiv((pvHT - cost) * 10000, cost));
  }

  void _priceFromMargin() {
    final cost = _cost;
    final m = _parseMargin(_margin.text);
    if (cost <= 0 || m == null) return;
    final pvHT = roundDiv(cost * (10000 + m), 10000);
    _retail.text = editDA(roundDiv(pvHT * (10000 + _vat), 10000));
  }

  void _onRetailChanged(String _) {
    _recomputeMargin();
    _errors.remove('retail');
    _touch();
    setState(() {});
  }

  void _onMarginChanged(String _) {
    _priceFromMargin();
    _errors.remove('margin');
    _touch();
    setState(() {});
  }

  void _onCostChanged(String _) {
    if ((parseDA(_retail.text) ?? 0) > 0) {
      _recomputeMargin();
    } else {
      _priceFromMargin();
    }
    _errors.remove('purchase');
    _touch();
    setState(() {});
  }

  void _setVat(int v) {
    setState(() => _vat = v);
    _recomputeMargin();
    _touch();
  }

  // ---------------------------------------------------------------- photos

  Future<void> _addPhoto({bool paste = false}) async {
    if (_busyPhoto) return;
    final img = paste ? await pasteProductPhoto() : await pickProductPhoto();
    if (!mounted) return;
    if (img == null) {
      if (paste) {
        showToast(context, 'Aucune image dans le presse-papiers.',
            kind: ToastKind.info);
      }
      return;
    }
    final p = _existing;
    if (p == null) {
      setState(() => _pendingPhotos.add(img));
      _touch();
      return;
    }
    setState(() => _busyPhoto = true);
    try {
      final up = await widget.api.uploadProductImage(p.id, img.$1, img.$2);
      _savedAny = true;
      if (mounted) setState(() => _existing = up);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
  }

  Future<void> _photoOp(int index, {required bool remove}) async {
    final p = _existing;
    if (p == null) {
      setState(() {
        if (remove) {
          _pendingPhotos.removeAt(index);
        } else {
          _pendingPhotos.insert(0, _pendingPhotos.removeAt(index));
        }
      });
      return;
    }
    if (remove) {
      final ok = await confirmAction(context,
          title: 'Supprimer cette photo ?',
          confirmLabel: 'Supprimer',
          danger: true);
      if (!ok) return;
    }
    setState(() => _busyPhoto = true);
    try {
      final up = remove
          ? await widget.api.deleteProductImage(p.id, index)
          : await widget.api.setMainProductImage(p.id, index);
      _savedAny = true;
      if (mounted) setState(() => _existing = up);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
  }

  // ---------------------------------------------------------------- pickers

  Future<void> _newCategory() async {
    final name = await _askText(context, 'Nouvelle catégorie', 'Nom (Boissons, Téléphones…)');
    if (name == null || name.isEmpty) return;
    try {
      final c = await widget.api.createCategory(name);
      final cats = await widget.api.categories();
      if (mounted) {
        setState(() {
          _cats = cats;
          _categoryId = c.id;
        });
        _touch();
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _newSupplier() async {
    final res = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _NewSupplierDialog(),
    );
    if (res == null) return;
    try {
      final p = await widget.api.savePartner({
        'kind': 'supplier',
        'name': res.$1,
        'phone': res.$2.isEmpty ? null : res.$2,
      });
      if (mounted) {
        setState(() {
          _suppliers = [..._suppliers, p]..sort((a, b) => a.name.compareTo(b.name));
          _supplierId = p.id;
        });
        _touch();
        showToast(context, 'Fournisseur « ${p.name} » créé');
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _generateBarcode() async {
    setState(() => _generating = true);
    try {
      final code = await widget.api.generateBarcode();
      setState(() {
        _barcode.text = code;
        _errors.remove('barcode');
      });
      _touch();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } catch (_) {
      if (mounted) showToast(context, 'Serveur injoignable.', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _pickPromoDate(bool start) async {
    final current = start ? _promoStart : _promoEnd;
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(current ?? '') ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    final iso =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    setState(() {
      if (start) {
        _promoStart = iso;
      } else {
        _promoEnd = iso;
      }
      _errors.remove('promo');
    });
    _touch();
  }

  Future<void> _addSerials() async {
    final p = _existing;
    if (p == null) return;
    final res = await showDialog<(List<String>, bool)>(
      context: context,
      builder: (_) => const _SerialsDialog(),
    );
    if (res == null || res.$1.isEmpty) return;
    try {
      final (added, dupes) =
          await widget.api.addUnits(p.id, res.$1, isUsed: res.$2);
      if (!mounted) return;
      showToast(
          context,
          dupes.isEmpty
              ? '$added numéro${added > 1 ? 's' : ''} ajouté${added > 1 ? 's' : ''}'
              : '$added ajouté(s) — déjà connus (ignorés) : ${dupes.join(', ')}',
          kind: dupes.isEmpty ? ToastKind.success : ToastKind.warning);
      if (added > 0) _loadUnits();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  // ---------------------------------------------------------------- variantes

  List<List<String>> get _combos {
    final lists = [
      for (final o in _options)
        if (o.values.isNotEmpty) o.values
    ];
    if (lists.isEmpty) return const [];
    var out = <List<String>>[[]];
    for (final l in lists) {
      out = [
        for (final prefix in out)
          for (final v in l) [...prefix, v]
      ];
    }
    return out;
  }

  /// Rows for the current combinations; entered values survive a regenerate.
  List<(String, _VariantRow)> get _variantGrid {
    final out = <(String, _VariantRow)>[];
    for (final c in _combos) {
      final label = c.join(' / ');
      final row = _variantRows.putIfAbsent(
          label,
          () => _VariantRow(
              price: _retail.text, cost: _isEdit ? '' : _purchase.text));
      out.add((label, row));
    }
    return out;
  }

  void _addOptionValue(_OptionRow o, String raw) {
    var changed = false;
    for (final part in raw.split(',')) {
      final v = part.trim();
      if (v.isEmpty) continue;
      if (o.values.any((x) => x.toLowerCase() == v.toLowerCase())) continue;
      o.values.add(v);
      changed = true;
    }
    o.input.clear();
    if (changed) {
      _errors.remove('variants');
      _touch();
    }
    setState(() {});
  }

  // ---------------------------------------------------------------- save

  Map<String, String> _validate() {
    final e = <String, String>{};
    if (_name.text.trim().isEmpty) e['name'] = 'Le nom du produit est obligatoire.';
    final retail = parseDA(_retail.text);
    if (_retail.text.trim().isNotEmpty && retail == null) {
      e['retail'] = 'Montant invalide.';
    } else if ((retail ?? 0) <= 0) {
      e['retail'] = 'Saisissez le prix de vente.';
    }
    if (_margin.text.trim().isNotEmpty && _parseMargin(_margin.text) == null) {
      e['margin'] = 'Pourcentage invalide.';
    }
    if (!_isEdit && widget.showCost) {
      if (_purchase.text.trim().isNotEmpty && parseDA(_purchase.text) == null) {
        e['purchase'] = 'Montant invalide.';
      }
    }
    final initQty = parseQty(_initialQty.text) ?? 0;
    if (!_isEdit && _kind != 'service') {
      if (_initialQty.text.trim().isNotEmpty && parseQty(_initialQty.text) == null) {
        e['initialQty'] = 'Quantité invalide.';
      } else if (initQty > 0 && (parseDA(_purchase.text) ?? 0) <= 0) {
        e[widget.showCost ? 'purchase' : 'initialQty'] =
            "Le prix d'achat est obligatoire quand un stock initial est saisi.";
      }
    }
    if (_minStock.text.trim().isNotEmpty && parseQty(_minStock.text) == null) {
      e['minStock'] = 'Quantité invalide.';
    }
    if (_f.wholesale &&
        _wholesale.text.trim().isNotEmpty &&
        parseDA(_wholesale.text) == null) {
      e['wholesale'] = 'Montant invalide.';
    }
    if (_warranty.text.trim().isNotEmpty && int.tryParse(_warranty.text.trim()) == null) {
      e['warranty'] = 'Nombre de mois invalide.';
    }
    final promo = parseDA(_promoPrice.text);
    if (_promoPrice.text.trim().isNotEmpty) {
      if (promo == null || promo <= 0) {
        e['promo'] = 'Prix promo invalide.';
      } else if (retail != null && promo >= retail) {
        e['promo'] = 'Le prix promo doit être inférieur au prix de vente.';
      } else if (_promoStart != null &&
          _promoEnd != null &&
          _promoEnd!.compareTo(_promoStart!) < 0) {
        e['promo'] = 'La fin de la promotion précède son début.';
      }
    }
    if (_soldByPack && _f.packagings && _kind != 'service') {
      for (final k in _packs) {
        final f = parseQty(k.factor.text) ?? 0;
        if (k.name.text.trim().isEmpty || f <= 1000) {
          e['packs'] =
              'Chaque emballage exige un nom et un nombre d’unités supérieur à 1.';
          break;
        }
      }
    }
    if (_variantsOn && _f.variants) {
      final codes = <String>{};
      for (final (label, row) in _variantGrid) {
        final p = parseDA(row.price.text) ?? 0;
        if (p <= 0) {
          e['variants'] = 'Prix de vente manquant pour « $label ».';
          break;
        }
        final bc = row.barcode.text.trim();
        if (bc.isNotEmpty && (!codes.add(bc) || bc == _barcode.text.trim())) {
          e['variants'] = 'Code-barres $bc utilisé deux fois.';
          break;
        }
      }
    }
    return e;
  }

  static const _errorOrder = [
    'barcode', 'name', 'purchase', 'margin', 'retail', 'wholesale',
    'initialQty', 'minStock', 'variants', 'warranty', 'promo',
    'barcodesEx', 'packs',
  ];

  void _focusFirstError() {
    for (final id in _errorOrder) {
      if (!_errors.containsKey(id)) continue;
      final ctx = _keys[id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.2, duration: const Duration(milliseconds: 220));
      }
      _focus[id]?.requestFocus();
      return;
    }
  }

  Map<String, dynamic> _payload() {
    final promo = parseDA(_promoPrice.text);
    final hasPromo = promo != null && promo > 0;
    final service = _kind == 'service';
    final weighed = _f.weighed && _weighed && !service;
    final p = _existing;
    return {
      'name': _name.text.trim(),
      'name_ar': _nameAr.text.trim().isEmpty ? null : _nameAr.text.trim(),
      'barcode': _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      'barcodes_ex': [for (final b in _bcodes) b.toJson()],
      if (_f.packagings || _packs.isNotEmpty)
        'packagings': [
          if (_soldByPack && !service)
            for (final k in _packs)
              Packaging(
                      name: k.name.text.trim(),
                      factorMilli: parseQty(k.factor.text) ?? 0,
                      barcode: k.barcode.text.trim().isEmpty
                          ? null
                          : k.barcode.text.trim())
                  .toJson(),
        ],
      'vat_rate': _vat,
      'purchase_price': p?.purchasePrice ?? (parseDA(_purchase.text) ?? 0),
      'price_retail': parseDA(_retail.text) ?? 0,
      'price_wholesale': _f.wholesale
          ? parseDA(_wholesale.text)
          : _src?.priceWholesale,
      'min_stock_milli': service ? 0 : (parseQty(_minStock.text) ?? 0),
      'is_weighable': weighed,
      'unit': weighed ? 'kg' : 'piece',
      'promo_price': hasPromo ? promo : null,
      'promo_start': hasPromo ? _promoStart : null,
      'promo_end': hasPromo ? _promoEnd : null,
      'warranty_months': int.tryParse(_warranty.text.trim()) ?? 0,
      'category_id': _categoryId,
      'track_serials': !service && _serial,
      'track_lots': !service && _lot,
      'track_expiry': !service && _lot,
      'parent_product_id': p?.parentProductId,
      'variant_label': p?.variantLabel,
      'description': _description.text.trim(),
      'brand': _brand.text.trim(),
      'default_supplier_id': _supplierId,
      'kind': _kind,
      'active': _active,
      if (p == null && !service) 'initial_qty_milli': parseQty(_initialQty.text) ?? 0,
    };
  }

  Future<void> _save({bool andNew = false}) async {
    if (_busy) return;
    final errs = _validate();
    setState(() {
      _errors
        ..clear()
        ..addAll(errs);
      if (errs.containsKey('packs')) _advanced = true;
    });
    if (errs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstError());
      return;
    }
    // Vente sous le coût : avertit, ne bloque pas (spec §4.5).
    final cost = _cost;
    final ttc = parseDA(_retail.text) ?? 0;
    if (cost > 0 && ttc > 0 && roundDiv(ttc * 10000, 10000 + _vat) <= cost) {
      final ok = await confirmAction(context,
          title: 'Vendre au prix coûtant ou en dessous ?',
          message:
              'Le prix de vente HT (${fmtDA(roundDiv(ttc * 10000, 10000 + _vat))}) ne dépasse pas le prix d’achat (${fmtDA(cost)}).',
          confirmLabel: 'Enregistrer quand même',
          danger: true);
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      final saved =
          await widget.api.saveProduct(_payload(), id: _existing?.id);
      _savedAny = true;
      // Photos choisies avant la création.
      var withPhotos = saved;
      final photoErrors = <String>[];
      for (final (bytes, mime) in List.of(_pendingPhotos)) {
        try {
          withPhotos = await widget.api.uploadProductImage(saved.id, bytes, mime);
        } on ApiException catch (e) {
          photoErrors.add(e.message);
        }
      }
      _pendingPhotos.clear();
      // Déclinaisons générées : des produits frères liés au parent.
      var created = 0;
      final variantErrors = <String>[];
      if (_variantsOn && _f.variants && saved.parentProductId == null) {
        for (final (label, row) in _variantGrid) {
          try {
            await widget.api.saveProduct({
              'name': '${saved.name} — $label',
              'barcode':
                  row.barcode.text.trim().isEmpty ? null : row.barcode.text.trim(),
              'vat_rate': saved.vatRate,
              'purchase_price': parseDA(row.cost.text) ?? 0,
              'price_retail': parseDA(row.price.text) ?? saved.priceRetail,
              'price_wholesale': saved.priceWholesale,
              'min_stock_milli': 0,
              'is_weighable': saved.isWeighable,
              'unit': saved.unit,
              'category_id': saved.categoryId,
              'brand': saved.brand,
              'default_supplier_id': saved.defaultSupplierId,
              'track_lots': saved.trackLots,
              'track_expiry': saved.trackExpiry,
              'track_serials': saved.trackSerials,
              'warranty_months': saved.warrantyMonths,
              'kind': saved.kind,
              'parent_product_id': saved.id,
              'variant_label': label,
            });
            created++;
          } on ApiException catch (e) {
            variantErrors.add('$label : ${e.message}');
          }
        }
      }
      if (!mounted) return;
      final parts = [
        _isEdit ? 'Produit « ${saved.name} » enregistré' : 'Produit « ${saved.name} » créé',
        if (created > 0) '$created variante${created > 1 ? 's' : ''}',
      ];
      final problems = [...photoErrors, ...variantErrors];
      // Next step offered by the toast: another product.
      final nav = Navigator.of(context);
      final api = widget.api, showCost = widget.showCost, brands = _brands;
      final offerNew = !andNew && problems.isEmpty;
      showToast(
          context,
          problems.isEmpty
              ? parts.join(' · ')
              : '${parts.join(' · ')} — ${problems.join(' ; ')}',
          kind: problems.isEmpty ? ToastKind.success : ToastKind.warning,
          actionLabel: offerNew ? 'Nouveau produit' : null,
          onAction: offerNew
              ? () => _push(nav, api: api, showCost: showCost, brands: brands)
              : null);
      if (andNew) {
        _resetForNew();
      } else if (problems.isEmpty) {
        _dirty = false;
        Navigator.of(context).pop(true);
      } else {
        // Le produit existe : la page passe en modification.
        setState(() {
          _existing = withPhotos;
          _variantsOn = false;
          _dirty = false;
        });
        _loadVariants();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final m = e.message;
      setState(() {
        if (m.contains('code-barres')) {
          final main =
              m.contains(_barcode.text.trim()) && _barcode.text.trim().isNotEmpty;
          _errors[main ? 'barcode' : 'barcodesEx'] = m;
          if (!main) _advanced = true;
        } else if (m.contains("prix d'achat")) {
          _errors['purchase'] = m;
        } else {
          _errors['form'] = m;
        }
      });
      if (_errors.containsKey('form')) {
        showToast(context, m, kind: ToastKind.error);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstError());
    } catch (e) {
      if (mounted) showToast(context, 'Serveur injoignable : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// « Enregistrer et nouveau » : garde catégorie, marque, TVA, fournisseur
  /// et type — quarante produits du même rayon à la suite.
  void _resetForNew() {
    for (final c in [
      _barcode, _name, _nameAr, _newBcode, _newBcodeLabel, _purchase, _margin,
      _retail, _wholesale, _initialQty, _minStock, _description, _warranty,
      _promoPrice,
    ]) {
      c.clear();
    }
    for (final p in _packs) {
      p.dispose();
    }
    for (final v in _variantRows.values) {
      v.dispose();
    }
    setState(() {
      _existing = null;
      _bcodes.clear();
      _packs.clear();
      _soldByPack = false;
      _pendingPhotos.clear();
      _variantRows.clear();
      for (final o in _options) {
        o.values.clear();
      }
      _variantsOn = false;
      _promoStart = null;
      _promoEnd = null;
      _active = true;
      _units = const [];
      _existingVariants = const [];
      _errors.clear();
      _dirty = false;
    });
    _fn('barcode').requestFocus();
    final ctx = _keys['barcode']?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return confirmAction(context,
        title: 'Quitter sans enregistrer ?',
        message: 'Les modifications de ce produit seront perdues.',
        confirmLabel: 'Quitter',
        danger: true);
  }

  /// « Annuler », « Retour », Échap.
  Future<void> _close() async {
    if (!await _confirmDiscard()) return;
    _dirty = false;
    if (mounted) Navigator.of(context).pop(_savedAny);
  }

  /// Breadcrumb « Produits » : back to the list itself.
  Future<void> _closeToList() async {
    if (!await _confirmDiscard()) return;
    _dirty = false;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // ---------------------------------------------------------------- build

  String get _title => _isEdit
      ? _existing!.name
      : widget.template != null
          ? 'Dupliquer « ${widget.template!.name} »'
          : 'Nouveau produit';

  @override
  Widget build(BuildContext context) {
    final service = _kind == 'service';
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: bindingsFor({
          AppShortcuts.submit: () => _save(),
          AppShortcuts.saveAndNew: () => _save(andNew: true),
        }),
        child: AppPage(
          maxWidth: 860,
          onBack: _close,
          crumbs: [
            Crumb('Produits', _closeToList),
            if (_isEdit) ...[
              Crumb(_existing!.name, _close),
              const Crumb('Modifier'),
            ] else
              Crumb(widget.template != null ? 'Dupliquer' : 'Nouveau produit'),
          ],
          title: _title,
          subtitle: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                  _isEdit
                      ? (_existing!.variantLabel != null
                          ? 'Variante « ${_existing!.variantLabel} »'
                          : 'Modification du produit')
                      : 'Scannez le code-barres, puis complétez les champs. Les champs marqués * sont obligatoires.',
                  style: T.bodyMuted),
              if (_dirty)
                const MintChip('Modifications non enregistrées',
                    color: T.warnTint, fg: T.warnDark),
            ],
          ),
          actions: [
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.end,
                runSpacing: 8,
                children: [
                  if (_isEdit)
                    PageAction(
                      label: 'Étiquettes',
                      icon: Icons.qr_code_2_rounded,
                      onPressed: () =>
                          printProductLabels(context, widget.api, [_existing!]),
                    ),
                  PageAction(label: 'Annuler', onPressed: _close),
                  PageAction(
                    label: 'Enregistrer et nouveau',
                    onPressed: _busy ? null : () => _save(andNew: true),
                  ),
                  PageAction(
                    label: _busy ? 'Enregistrement…' : 'Enregistrer',
                    icon: Icons.check_rounded,
                    primary: true,
                    onPressed: _busy ? null : () => _save(),
                  ),
                ],
              ),
            ),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errors['form'] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: T.dangerTint,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.danger.withValues(alpha: 0.4)),
                    ),
                    child: FieldError(_errors['form']),
                  ),
                ),
              _identity(),
              _prices(),
              _classement(),
              if (!service) _stock(),
              if (!service) _tracking(),
              if (_f.webstore) _webstore(),
              _warrantyPromo(),
              _advancedSection(),
              Text('Raccourcis : Ctrl+Entrée = Enregistrer · Ctrl+Maj+Entrée = Enregistrer et nouveau · Échap = Retour',
                  style: T.small),
            ],
          ),
        ),
      ),
    );
  }

  /// A short field (price, quantity) does not stretch across the page.
  Widget _short(Widget child, {double width = 340}) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: SizedBox(width: width, child: child),
      );

  /// Two short fields side by side (the only two-column layout of the form).
  Widget _pair(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: a),
          const SizedBox(width: 16),
          Expanded(child: b),
        ],
      );

  // ---------------------------------------------------------------- Identité

  Widget _identity() {
    return PageSection(
      title: 'Identité',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _PField(
          fieldKey: _k('barcode'),
          focusNode: _fn('barcode'),
          label: 'Code-barres',
          helper:
              'Scannez le code-barres du produit. Il n’en a pas ? Cliquez sur « Générer ».',
          controller: _barcode,
          mono: true,
          autofocus: !_isEdit,
          error: _errors['barcode'],
          onChanged: (_) {
            _errors.remove('barcode');
            _touch();
          },
          onSubmitted: (_) => _fn('name').requestFocus(),
          trailing: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: TextButton.icon(
              onPressed: _generating ? null : _generateBarcode,
              icon: Icon(
                  _generating
                      ? Icons.hourglass_top_rounded
                      : Icons.auto_fix_high_rounded,
                  size: 16),
              label: const Text('Générer'),
            ),
          ),
        ),
        _PField(
          fieldKey: _k('name'),
          focusNode: _fn('name'),
          label: 'Nom du produit',
          required: true,
          hint: 'Ex. Coca-Cola 1 L, Samsung Galaxy A15 128 Go…',
          controller: _name,
          error: _errors['name'],
          onChanged: (_) {
            _errors.remove('name');
            _touch();
            setState(() {});
          },
        ),
        if (_f.services || _kind == 'service') _typeField(),
        const SizedBox(height: 4),
        _photoBlock(),
      ]),
    );
  }

  Widget _typeField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const _FieldLabel('Type'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final (k, label, icon) in const [
            ('standard', 'Produit (avec stock)', Icons.inventory_2_outlined),
            ('service', 'Service (sans stock)', Icons.handyman_outlined),
          ])
            ChoiceChip(
              avatar: Icon(icon,
                  size: 18, color: _kind == k ? T.mintDark : T.muted),
              label: Text(label,
                  style: T.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _kind == k ? T.mintDark : T.ink)),
              selected: _kind == k,
              selectedColor: T.mintTint,
              backgroundColor: T.surface,
              side: BorderSide(color: _kind == k ? T.mintDeep : T.border),
              showCheckmark: false,
              onSelected: (_) {
                setState(() => _kind = k);
                _touch();
              },
            ),
        ]),
        const SizedBox(height: 6),
        Text(
            _kind == 'service'
                ? 'Un service (main-d’œuvre, livraison, pose…) se vend sans stock : aucun mouvement, aucun inventaire.'
                : 'Un produit a un stock, des mouvements et un coût moyen.',
            style: T.small),
      ]),
    );
  }

  void _addExtraBarcode() {
    final c = _newBcode.text.trim();
    if (c.isEmpty) return;
    if (c == _barcode.text.trim() || _bcodes.any((b) => b.code == c)) {
      setState(() => _errors['barcodesEx'] = 'Ce code-barres est déjà sur le produit.');
      return;
    }
    setState(() {
      _bcodes.add(BarcodeEntry(code: c, label: _newBcodeLabel.text.trim()));
      _newBcode.clear();
      _newBcodeLabel.clear();
      _errors.remove('barcodesEx');
    });
    _touch();
  }

  Widget _photoBlock() {
    final p = _existing;
    final tiles = <Widget>[];
    if (p != null) {
      for (var i = 0; i < p.imageCount; i++) {
        tiles.add(_PhotoTile(
          main: i == 0,
          image: Image.network(
            widget.api.productImageUrl(p.id, p.imageRev, thumb: true, index: i),
            headers: widget.api.authHeaders,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.broken_image_outlined, color: T.ghost),
          ),
          onMain: i == 0 ? null : () => _photoOp(i, remove: false),
          onRemove: () => _photoOp(i, remove: true),
        ));
      }
    } else {
      for (var i = 0; i < _pendingPhotos.length; i++) {
        tiles.add(_PhotoTile(
          main: i == 0,
          image: Image.memory(_pendingPhotos[i].$1, fit: BoxFit.cover),
          onMain: i == 0 ? null : () => _photoOp(i, remove: false),
          onRemove: () => _photoOp(i, remove: true),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _FieldLabel('Photo'),
      const SizedBox(height: 6),
      Wrap(
        spacing: 4,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          if (tiles.isEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: _name.text.trim().isEmpty
                  ? Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: const Icon(Icons.image_outlined, color: T.ghost),
                    )
                  : ProductThumb(
                      api: widget.api,
                      product: Product.fromJson({'id': '', 'name': _name.text}),
                      size: 72),
            )
          else
            ...tiles,
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            OutlinedButton.icon(
              onPressed: _busyPhoto ? null : () => _addPhoto(),
              icon: Icon(
                  _busyPhoto
                      ? Icons.hourglass_top_rounded
                      : Icons.add_photo_alternate_outlined,
                  size: 18),
              label: const Text('Ajouter une photo'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _busyPhoto ? null : () => _addPhoto(paste: true),
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: const Text('Coller une image'),
            ),
          ]),
        ],
      ),
      const SizedBox(height: 6),
      Text('JPEG ou PNG, 2 Mo maximum. La première photo est la photo principale (caisse, liste, boutique).',
          style: T.small),
    ]);
  }

  // ---------------------------------------------------------------- Prix

  Widget _prices() {
    final unit = _weighed ? ' (DA le kg)' : ' (DA)';
    final cost = _cost;
    final ttc = parseDA(_retail.text) ?? 0;
    final pvHT = ttc <= 0 ? 0 : roundDiv(ttc * 10000, 10000 + _vat);
    final below = cost > 0 && ttc > 0 && pvHT <= cost;
    final vats = {1900, 900, 0, _f.defaultVat, _vat}.toList();
    final retail = _PField(
      fieldKey: _k('retail'),
      focusNode: _fn('retail'),
      label: 'Prix de vente TTC$unit',
      required: true,
      controller: _retail,
      mono: true,
      error: _errors['retail'],
      onChanged: _onRetailChanged,
    );
    return PageSection(
      title: 'Prix',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.showCost) ...[
          _short(_PField(
            fieldKey: _k('purchase'),
            focusNode: _fn('purchase'),
            label: 'Prix d’achat HT$unit',
            helper: _isEdit
                ? 'Ne change plus ici : chaque bon de réception met à jour le coût moyen.'
                : 'Ce que vous payez au fournisseur, hors taxes.',
            controller: _isEdit ? _frozenCost : _purchase,
            mono: true,
            enabled: !_isEdit,
            error: _errors['purchase'],
            hint: _isEdit ? null : '0,00',
            onChanged: _onCostChanged,
          ), width: 420),
          _short(
              _pair(
                _PField(
                  fieldKey: _k('margin'),
                  focusNode: _fn('margin'),
                  label: 'Marge',
                  helper: cost > 0
                      ? 'Tapez la marge : le prix se calcule.'
                      : 'Saisissez d’abord le prix d’achat.',
                  controller: _margin,
                  mono: true,
                  enabled: cost > 0,
                  error: _errors['margin'],
                  suffixText: '%',
                  onChanged: _onMarginChanged,
                ),
                retail,
              ),
              width: 640),
        ] else
          _short(retail, width: 420),
        if (below)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: T.dangerDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Prix de vente HT ${fmtDA(pvHT)} ≤ prix d’achat ${fmtDA(cost)} : vente à perte.',
                    style: T.body.copyWith(
                        color: T.dangerDark, fontWeight: FontWeight.w600)),
              ),
            ]),
          )
        else if (ttc > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('Soit ${fmtDA(pvHT)} hors taxes',
                style: T.monoBody.copyWith(color: T.muted)),
          ),
        const _FieldLabel('TVA'),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final v in vats)
            ChoiceChip(
              label: Text('${(v / 100).toStringAsFixed(v % 100 == 0 ? 0 : 1)} %',
                  style: TextStyle(
                      fontFamily: T.mono,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _vat == v ? T.mintDark : T.muted)),
              selected: _vat == v,
              selectedColor: T.mintTint,
              backgroundColor: T.bg,
              side: BorderSide(color: _vat == v ? T.mintDeep : T.border),
              showCheckmark: false,
              onSelected: (_) => _setVat(v),
            ),
        ]),
        if (_f.wholesale) ...[
          const SizedBox(height: 14),
          _short(
              _PField(
                fieldKey: _k('wholesale'),
                focusNode: _fn('wholesale'),
                label: 'Prix demi-gros TTC$unit',
                helper: 'Laissez vide si vous ne vendez pas en demi-gros.',
                controller: _wholesale,
                mono: true,
                error: _errors['wholesale'],
                onChanged: (_) {
                  _errors.remove('wholesale');
                  _touch();
                },
              ),
              width: 420),
        ],
      ]),
    );
  }

  // ---------------------------------------------------------------- Classement

  Widget _classement() {
    final catValue = _cats.any((c) => c.id == _categoryId) ? _categoryId : null;
    final supValue =
        _suppliers.any((s) => s.id == _supplierId) ? _supplierId : null;
    return PageSection(
      title: 'Classement',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Dropdown<String?>(
          label: 'Catégorie',
          helper: 'Le rayon du magasin : sert de filtre à la caisse et dans les rapports.',
          value: catValue,
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('Sans catégorie')),
            for (final c in _cats)
              DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
            DropdownMenuItem<String?>(
                value: _newSentinel,
                child: Text('+ Créer une catégorie',
                    style: T.body.copyWith(
                        color: T.mintDark, fontWeight: FontWeight.w700))),
          ],
          onChanged: (v) {
            if (v == _newSentinel) {
              _newCategory();
            } else {
              setState(() => _categoryId = v);
              _touch();
            }
          },
        ),
        _brandField(),
        _Dropdown<String?>(
          label: 'Fournisseur habituel',
          helper: 'Proposé d’office sur les bons de commande et les réceptions.',
          value: supValue,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Aucun')),
            for (final s in _suppliers)
              DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
            DropdownMenuItem<String?>(
                value: _newSentinel,
                child: Text('+ Créer un fournisseur',
                    style: T.body.copyWith(
                        color: T.mintDark, fontWeight: FontWeight.w700))),
          ],
          onChanged: (v) {
            if (v == _newSentinel) {
              _newSupplier();
            } else {
              setState(() => _supplierId = v);
              _touch();
            }
          },
        ),
        if (_isEdit)
          _SwitchRow(
            label: 'Produit actif',
            subtitle: _active
                ? 'Vendable à la caisse et visible dans les listes.'
                : 'Masqué de la caisse et des listes ; l’historique et le stock restent.',
            value: _active,
            onChanged: (v) {
              setState(() => _active = v);
              _touch();
            },
          ),
      ]),
    );
  }

  Widget _brandField() {
    return RawAutocomplete<String>(
      textEditingController: _brand,
      focusNode: _brandFocus,
      optionsBuilder: (v) {
        final q = v.text.trim().toLowerCase();
        final matches = [
          for (final b in _brands)
            if (q.isEmpty || b.toLowerCase().contains(q)) b
        ].take(8).toList();
        if (q.isNotEmpty && !_brands.any((b) => b.toLowerCase() == q)) {
          matches.add('$_newSentinel${v.text.trim()}');
        }
        return matches;
      },
      displayStringForOption: (o) =>
          o.startsWith(_newSentinel) ? o.substring(_newSentinel.length) : o,
      onSelected: (o) {
        final v = o.startsWith(_newSentinel) ? o.substring(_newSentinel.length) : o;
        _brand.text = v;
        if (!_brands.contains(v)) setState(() => _brands = [..._brands, v]..sort());
        _touch();
      },
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => _PField(
        label: 'Marque',
        controller: ctrl,
        focusNode: focus,
        hint: 'Choisissez dans la liste ou tapez une nouvelle marque',
        onChanged: (_) => _touch(),
        onSubmitted: (_) => onSubmit(),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          elevation: 6,
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rInner),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300, maxWidth: 380),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              children: [
                for (final o in options)
                  InkWell(
                    onTap: () => onSelected(o),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: o.startsWith(_newSentinel)
                          ? Text('+ Créer « ${o.substring(_newSentinel.length)} »',
                              style: T.body.copyWith(
                                  color: T.mintDark,
                                  fontWeight: FontWeight.w700))
                          : Text(o, style: T.body),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- Stock

  Widget _stock() {
    final initial = _PField(
      fieldKey: _k('initialQty'),
      focusNode: _fn('initialQty'),
      label: _weighed ? 'Stock initial (kg)' : 'Stock initial',
      helper: 'La quantité que vous avez en rayon aujourd’hui.',
      controller: _initialQty,
      mono: true,
      error: _errors['initialQty'],
      onChanged: (_) {
        _errors.remove('initialQty');
        _touch();
        setState(() {});
      },
    );
    final min = _PField(
      fieldKey: _k('minStock'),
      focusNode: _fn('minStock'),
      label: 'Stock minimum (alerte)',
      helper: 'En dessous, le produit apparaît « Sous le minimum ».',
      controller: _minStock,
      mono: true,
      error: _errors['minStock'],
      onChanged: (_) {
        _errors.remove('minStock');
        _touch();
      },
    );
    return PageSection(
      title: 'Stock',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _short(_isEdit ? min : _pair(initial, min), width: _isEdit ? 420 : 640),
        if (!_isEdit && (parseQty(_initialQty.text) ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
                'Le stock initial entre par un document « Stock initial » au prix d’achat : le stock ne change jamais sans document.',
                style: T.small),
          ),
        if (_isEdit)
          Text(
              'Le stock ne se modifie pas ici : utilisez « Ajuster le stock » sur la fiche du produit, ou un bon de réception.',
              style: T.small),
      ]),
    );
  }

  // ---------------------------------------------------------------- Suivi

  Widget _tracking() {
    final children = <Widget>[];
    if (_f.lots) {
      children.add(_SwitchRow(
        label: 'Lot et date de péremption',
        subtitle: 'Le n° de lot et la date de péremption sont demandés au bon de réception ; alertes de péremption.',
        value: _lot,
        onChanged: (v) {
          setState(() => _lot = v);
          _touch();
        },
      ));
      if (_lot) {
        children.add(_reveal(
            'Les lots se créent à la réception. La vente sort d’abord le lot qui périme le plus tôt.'));
      }
    }
    if (_f.serials) {
      children.add(_SwitchRow(
        label: 'N° de série / IMEI',
        subtitle: 'Chaque unité a son numéro : garantie, SAV, traçabilité.',
        value: _serial,
        onChanged: (v) {
          setState(() => _serial = v);
          _touch();
        },
      ));
      if (_serial) {
        children.add(_reveal(_existing?.trackSerials == true
            ? 'Les numéros enregistrés sont dans « Options avancées » en bas de la page.'
            : 'Les numéros se saisissent au bon de réception (ou ici, dans « Options avancées », une fois le produit enregistré).'));
      }
    }
    if (_f.weighed) {
      children.add(_SwitchRow(
        label: 'Vendu au poids',
        subtitle: 'Vendu au kg : prix au kilo, quantités décimales, étiquettes de balance.',
        value: _weighed,
        onChanged: (v) {
          setState(() => _weighed = v);
          _touch();
        },
      ));
      if (_weighed) {
        children.add(_reveal(
            'Les prix de ce produit s’entendent au kilo ; la caisse accepte les codes balance (21/22).'));
      }
    }
    final canVariants = _f.variants && _existing?.parentProductId == null;
    if (canVariants) {
      children.add(_SwitchRow(
        label: 'Variantes (taille, couleur…)',
        subtitle: 'Chaque combinaison devient un produit avec son code-barres, son prix et son stock.',
        value: _variantsOn,
        onChanged: (v) {
          setState(() => _variantsOn = v);
          _touch();
        },
      ));
      if (_existingVariants.isNotEmpty) children.add(_existingVariantsBlock());
      if (_variantsOn) children.add(_variantGenerator());
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return PageSection(
      title: 'Suivi',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _reveal(String text) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.subdirectory_arrow_right_rounded,
              size: 17, color: T.faint),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: T.small)),
        ]),
      );

  Widget _existingVariantsBlock() => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FieldLabel('${_existingVariants.length} variante(s) existante(s)'),
          const SizedBox(height: 6),
          for (final v in _existingVariants)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                const Icon(Icons.subdirectory_arrow_right,
                    size: 16, color: T.faint),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(v.variantLabel ?? v.name,
                        style: T.body, overflow: TextOverflow.ellipsis)),
                if (v.barcode != null)
                  SizedBox(
                      width: 170,
                      child: Text(v.barcode!,
                          style: T.monoSmall, overflow: TextOverflow.ellipsis)),
                SizedBox(
                    width: 130,
                    child: Text(fmtDA(v.priceRetail),
                        textAlign: TextAlign.end, style: T.monoBody)),
              ]),
            ),
        ]),
      );

  Widget _variantGenerator() {
    final grid = _variantGrid;
    return KeyedSubtree(
      key: _k('variants'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(
              color: _errors['variants'] != null ? T.danger : T.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const _FieldLabel('Options (ex. Taille : S, M, L — Couleur : Rouge, Bleu)'),
          const SizedBox(height: 8),
          for (var i = 0; i < _options.length; i++) _optionRow(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => _options.add(_OptionRow(''))),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Ajouter une option'),
            ),
          ),
          if (grid.isNotEmpty) ...[
            const SizedBox(height: 8),
            _FieldLabel(
                '${grid.length} variante${grid.length > 1 ? 's' : ''} — créée${grid.length > 1 ? 's' : ''} à l’enregistrement'),
            const SizedBox(height: 6),
            Row(children: [
              const Expanded(flex: 3, child: _FieldLabel('Variante')),
              const Expanded(flex: 3, child: _FieldLabel('Code-barres')),
              const Expanded(flex: 2, child: _FieldLabel('Prix de vente TTC')),
              if (widget.showCost)
                const Expanded(flex: 2, child: _FieldLabel('Prix d’achat HT')),
            ]),
            const SizedBox(height: 4),
            for (final (label, row) in grid)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Expanded(
                      flex: 3,
                      child: Text(label,
                          style: T.body.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis)),
                  Expanded(
                      flex: 3,
                      child: _GridInput(
                          controller: row.barcode,
                          mono: true,
                          onChanged: (_) => _touch())),
                  Expanded(
                      flex: 2,
                      child: _GridInput(
                          controller: row.price,
                          mono: true,
                          onChanged: (_) => _touch())),
                  if (widget.showCost)
                    Expanded(
                        flex: 2,
                        child: _GridInput(
                            controller: row.cost,
                            mono: true,
                            onChanged: (_) => _touch())),
                ]),
              ),
          ],
          FieldError(_errors['variants']),
        ]),
      ),
    );
  }

  Widget _optionRow(int i) {
    final o = _options[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 150,
          child: _GridInput(
              controller: o.name,
              hint: 'Option (Taille…)',
              onChanged: (_) => _touch()),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final v in o.values)
                  InputChip(
                    label: Text(v, style: T.small.copyWith(color: T.ink)),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: T.mintTint,
                    side: const BorderSide(color: T.mintTint2),
                    onDeleted: () {
                      setState(() => o.values.remove(v));
                      _touch();
                    },
                  ),
                SizedBox(
                  width: 240,
                  child: Focus(
                    onKeyEvent: (node, e) {
                      if (e is KeyDownEvent &&
                          e.logicalKey == LogicalKeyboardKey.backspace &&
                          o.input.text.isEmpty &&
                          o.values.isNotEmpty) {
                        setState(() => o.values.removeLast());
                        _touch();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: o.input,
                      focusNode: o.focus,
                      style: T.body,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: o.values.isEmpty
                            ? 'S, M, L… (Entrée ou virgule)'
                            : 'Ajouter une valeur…',
                        hintStyle: T.small.copyWith(color: T.ghost),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 9),
                      ),
                      onChanged: (t) {
                        if (t.contains(',')) _addOptionValue(o, t);
                      },
                      onSubmitted: (t) {
                        _addOptionValue(o, t);
                        o.focus.requestFocus();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: T.muted),
          onPressed: () {
            setState(() => _options.removeAt(i).dispose());
            _touch();
          },
          child: const Text('Retirer'),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- Boutique

  Widget _webstore() {
    return PageSection(
      title: 'Boutique en ligne',
      child: _PField(
        label: 'Description',
        helper: 'Une ligne « Clé : Valeur » = une ligne du tableau de caractéristiques sur la boutique.',
        controller: _description,
        maxLines: 6,
        hint: 'Marque : Samsung\nStockage : 128 Go\nNeuf sous blister…',
        onChanged: (_) => _touch(),
      ),
    );
  }

  // ---------------------------------------------------------------- Garantie / promo

  Widget _warrantyPromo() {
    return PageSection(
      title: 'Garantie et promotion',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _short(
            _PField(
              fieldKey: _k('warranty'),
              focusNode: _fn('warranty'),
              label: 'Garantie (mois)',
              helper: 'Laissez vide si le produit est vendu sans garantie.',
              controller: _warranty,
              mono: true,
              error: _errors['warranty'],
              onChanged: (_) {
                _errors.remove('warranty');
                _touch();
              },
            ),
            width: 420),
        _short(
            _PField(
              fieldKey: _k('promo'),
              focusNode: _fn('promo'),
              label: 'Prix promo TTC (DA)',
              helper: 'Laissez vide s’il n’y a pas de promotion.',
              controller: _promoPrice,
              mono: true,
              error: _errors['promo'],
              onChanged: (_) {
                _errors.remove('promo');
                _touch();
                setState(() {});
              },
            ),
            width: 420),
        _short(
            _pair(
              _DateBtn(
                  label: 'Du',
                  value: _promoStart,
                  onTap: () => _pickPromoDate(true),
                  onClear: _promoStart == null
                      ? null
                      : () => setState(() => _promoStart = null)),
              _DateBtn(
                  label: 'Au',
                  value: _promoEnd,
                  onTap: () => _pickPromoDate(false),
                  onClear: _promoEnd == null
                      ? null
                      : () => setState(() => _promoEnd = null)),
            ),
            width: 640),
        Builder(builder: (_) {
          final promo = parseDA(_promoPrice.text) ?? 0;
          final ttc = parseDA(_retail.text) ?? 0;
          if (promo <= 0 || ttc <= 0 || promo >= ttc) {
            return const SizedBox.shrink();
          }
          final pct = roundDiv((ttc - promo) * 10000, ttc);
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Remise de ${_fmtPct(pct)} %',
                style: T.monoBody.copyWith(color: T.mintDark)),
          );
        }),
      ]),
    );
  }

  // ---------------------------------------------------------------- Options avancées

  Widget _advancedSection() {
    final service = _kind == 'service';
    final hasError =
        _errors.containsKey('packs') || _errors.containsKey('barcodesEx');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: hasError ? T.danger : T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(T.rCard),
          onTap: () => setState(() => _advanced = !_advanced),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Options avancées', style: T.h2),
                      const SizedBox(height: 2),
                      Text(
                          [
                            'Nom en arabe',
                            'codes-barres supplémentaires',
                            if (_f.packagings && !service) 'emballages (carton, pack…)',
                            if (_f.serials && _serial) 'n° de série',
                          ].join(' · '),
                          style: T.small),
                    ]),
              ),
              Text(_advanced ? 'Masquer' : 'Afficher',
                  style: T.body.copyWith(
                      color: T.mintDark, fontWeight: FontWeight.w700)),
              Icon(_advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: T.mintDark),
            ]),
          ),
        ),
        if (_advanced)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 1),
                const SizedBox(height: 14),
                _PField(
                  label: 'Nom en arabe',
                  helper: 'Imprimé sur les tickets et étiquettes en arabe.',
                  controller: _nameAr,
                  rtl: true,
                  onChanged: (_) => _touch(),
                ),
                _extraBarcodes(),
                if (_f.packagings && !service) _packagings(),
                if (_f.serials && _serial && !service) _serialsBlock(),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _extraBarcodes() {
    return KeyedSubtree(
      key: _k('barcodesEx'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _FieldLabel('Codes-barres supplémentaires'),
          const SizedBox(height: 2),
          Text('Même produit, même stock, même prix (ex. un ancien code-barres, un code fournisseur).',
              style: T.small),
          const SizedBox(height: 8),
          for (var i = 0; i < _bcodes.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(
                    width: 200,
                    child: Text(_bcodes[i].code,
                        style: T.monoBody, overflow: TextOverflow.ellipsis)),
                Expanded(
                    child: Text(
                        _bcodes[i].label.isEmpty ? '—' : _bcodes[i].label,
                        style: T.body,
                        overflow: TextOverflow.ellipsis)),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: T.muted),
                  onPressed: () {
                    setState(() => _bcodes.removeAt(i));
                    _touch();
                  },
                  child: const Text('Retirer'),
                ),
              ]),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
                child: _PField(
                    label: 'Code-barres',
                    hint: 'Scannez le code…',
                    controller: _newBcode,
                    mono: true,
                    bottomGap: 0,
                    onSubmitted: (_) => _addExtraBarcode())),
            const SizedBox(width: 10),
            Expanded(
                child: _PField(
                    label: 'Libellé (facultatif)',
                    hint: 'Pomme, ancien code…',
                    controller: _newBcodeLabel,
                    bottomGap: 0,
                    onSubmitted: (_) => _addExtraBarcode())),
            const SizedBox(width: 10),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _addExtraBarcode,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter'),
              ),
            ),
          ]),
          FieldError(_errors['barcodesEx']),
        ]),
      ),
    );
  }

  Widget _packagings() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _SwitchRow(
          label: 'Vendu aussi par emballage (carton, pack…)',
          subtitle:
              'Chaque emballage a son code-barres et un nombre d’unités : scanner le carton vend 24 unités.',
          value: _soldByPack,
          onChanged: (v) {
            setState(() {
              _soldByPack = v;
              if (v && _packs.isEmpty) _packs.add(_PackRow());
              _errors.remove('packs');
            });
            _touch();
          },
        ),
        if (_soldByPack)
          KeyedSubtree(
            key: _k('packs'),
            child: Column(children: [
              for (var i = 0; i < _packs.length; i++)
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                      flex: 3,
                      child: _PField(
                          label: 'Emballage',
                          controller: _packs[i].name,
                          onChanged: (_) => _touch())),
                  const SizedBox(width: 10),
                  Expanded(
                      flex: 2,
                      child: _PField(
                          label: 'Unités dedans',
                          controller: _packs[i].factor,
                          mono: true,
                          hint: '24',
                          onChanged: (_) {
                            _errors.remove('packs');
                            _touch();
                          })),
                  const SizedBox(width: 10),
                  Expanded(
                      flex: 3,
                      child: _PField(
                          label: 'Code-barres de l’emballage',
                          controller: _packs[i].barcode,
                          mono: true,
                          onChanged: (_) => _touch())),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextButton(
                      style: TextButton.styleFrom(foregroundColor: T.muted),
                      onPressed: () {
                        setState(() => _packs.removeAt(i).dispose());
                        _touch();
                      },
                      child: const Text('Retirer'),
                    ),
                  ),
                ]),
              FieldError(_errors['packs']),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _packs.add(_PackRow()));
                    _touch();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Ajouter un emballage'),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _serialsBlock() {
    final p = _existing;
    if (p == null || !p.trackSerials) {
      return Text(
          'N° de série : ils se saisissent au bon de réception, ou ici une fois le produit enregistré.',
          style: T.small);
    }
    final inStock = _units.where((u) => u.status == 'in_stock').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: Text('N° de série : $inStock en stock sur ${_units.length} enregistrés',
                style: T.body.copyWith(fontWeight: FontWeight.w600))),
        OutlinedButton.icon(
          onPressed: _addSerials,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Ajouter des numéros'),
        ),
      ]),
      const SizedBox(height: 6),
      for (final u in _units.take(8))
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Icon(
                u.status == 'in_stock'
                    ? Icons.inventory_2_outlined
                    : Icons.sell_outlined,
                size: 16,
                color: u.status == 'in_stock' ? T.mintDeep : T.faint),
            const SizedBox(width: 8),
            Expanded(
                child: Text(u.serial,
                    style: T.monoBody, overflow: TextOverflow.ellipsis)),
            if (u.isUsed)
              const MintChip('occasion', color: T.warnTint, fg: T.warnDark),
            const SizedBox(width: 8),
            Text(
                switch (u.status) {
                  'in_stock' => 'en stock',
                  'sold' => 'vendu',
                  'returned' => 'retourné',
                  'repair' => 'en SAV',
                  _ => 'rebuté',
                },
                style: T.small),
          ]),
        ),
      if (_units.length > 8)
        Text('… et ${_units.length - 8} autres', style: T.small),
    ]);
  }
}

// ---------------------------------------------------------------- widgets

/// Label above a field; a red « * » when the field is required.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.required = false, this.color});
  final String text;
  final bool required;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text),
        if (required)
          const TextSpan(
              text: ' *',
              style: TextStyle(color: T.danger, fontWeight: FontWeight.w800)),
      ]),
      style: T.label.copyWith(color: color ?? T.ink, fontWeight: FontWeight.w600),
    );
  }
}

class _PField extends StatelessWidget {
  const _PField({
    required this.label,
    required this.controller,
    this.fieldKey,
    this.focusNode,
    this.error,
    this.helper,
    this.required = false,
    this.mono = false,
    this.enabled = true,
    this.autofocus = false,
    this.rtl = false,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
    this.hint,
    this.suffixText,
    this.maxLines = 1,
    this.bottomGap = 14,
  });
  final String label;
  final TextEditingController controller;
  final Key? fieldKey;
  final FocusNode? focusNode;
  final String? error;
  final String? helper;
  final bool required;
  final bool mono;
  final bool enabled;
  final bool autofocus;
  final bool rtl;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final String? hint;
  final String? suffixText;
  final int maxLines;
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.isNotEmpty;
    return Padding(
      key: fieldKey,
      padding: EdgeInsets.only(bottom: bottomGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldLabel(label,
              required: required, color: hasError ? T.dangerDark : null),
          const SizedBox(height: 6),
          Container(
            constraints: BoxConstraints(minHeight: maxLines > 1 ? 0 : 44),
            decoration: BoxDecoration(
              color: enabled ? T.surface : T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(
                  color: hasError ? T.danger : T.border3,
                  width: hasError ? 1.4 : 1),
            ),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  autofocus: autofocus,
                  maxLines: maxLines,
                  textDirection: rtl ? TextDirection.rtl : null,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style: (mono ? T.monoBody : T.body)
                      .copyWith(color: enabled ? null : T.muted),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: hint,
                    hintStyle: T.body.copyWith(color: T.ghost),
                    suffixText: suffixText,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              ?trailing,
            ]),
          ),
          if (hasError)
            FieldError(error)
          else if (helper != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(helper!, style: T.small),
            ),
        ],
      ),
    );
  }
}

class _GridInput extends StatelessWidget {
  const _GridInput(
      {required this.controller, this.mono = false, this.hint, this.onChanged});
  final TextEditingController controller;
  final bool mono;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      margin: const EdgeInsetsDirectional.only(end: 6),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border3),
      ),
      child: TextField(
        controller: controller,
        style: (mono ? T.monoBody : T.body),
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: T.small.copyWith(color: T.ghost),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
      ),
    );
  }
}

class _Dropdown<V> extends StatelessWidget {
  const _Dropdown(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged,
      this.helper});
  final String label;
  final V value;
  final List<DropdownMenuItem<V>> items;
  final ValueChanged<V?> onChanged;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _FieldLabel(label),
        const SizedBox(height: 6),
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<V>(
              value: value,
              isExpanded: true,
              style: T.body,
              dropdownColor: T.surface,
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(helper!, style: T.small),
          ),
      ]),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow(
      {required this.label,
      this.subtitle,
      required this.value,
      required this.onChanged});
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(T.rInner),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: T.small),
              ],
            ]),
          ),
          const SizedBox(width: 12),
          Text(value ? 'Oui' : 'Non',
              style: T.body.copyWith(
                  color: value ? T.mintDark : T.muted,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Switch(
            value: value,
            activeTrackColor: T.mint,
            onChanged: onChanged,
          ),
        ]),
      ),
    );
  }
}

class _DateBtn extends StatelessWidget {
  const _DateBtn(
      {required this.label, required this.value, required this.onTap, this.onClear});
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _FieldLabel(label),
        const SizedBox(height: 6),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(T.rInner),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border3),
            ),
            child: Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 16, color: T.muted),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(value ?? 'Choisir une date',
                      style: value == null
                          ? T.body.copyWith(color: T.muted)
                          : T.monoBody)),
              if (onClear != null)
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: T.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: onClear,
                  child: const Text('Effacer'),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile(
      {required this.image, required this.main, this.onMain, this.onRemove});
  final Widget image;
  final bool main;
  final VoidCallback? onMain;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final s = main ? 96.0 : 72.0;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 10),
      child: SizedBox(
        width: 150,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(
                      color: main ? T.mintDeep : T.border, width: main ? 1.5 : 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(T.rInner - 1),
                  child: SizedBox(width: s, height: s, child: image),
                ),
              ),
              if (main)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Photo principale', style: T.small),
                ),
              if (onMain != null)
                TextButton.icon(
                  onPressed: onMain,
                  icon: const Icon(Icons.star_outline_rounded, size: 16),
                  label: const Text('Mettre en premier'),
                ),
              if (onRemove != null)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('Supprimer'),
                ),
            ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- dialogs

Future<String?> _askText(BuildContext context, String title, String hint) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(title, style: T.h2),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          style: T.body,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
            label: 'Créer',
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim())),
      ],
    ),
  ).whenComplete(ctrl.dispose);
}

/// « + Nouveau fournisseur » : le minimum pour continuer la fiche ; le reste
/// se complète dans Partenaires.
class _NewSupplierDialog extends StatefulWidget {
  const _NewSupplierDialog();

  @override
  State<_NewSupplierDialog> createState() => _NewSupplierDialogState();
}

class _NewSupplierDialogState extends State<_NewSupplierDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _ok() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Le nom est obligatoire.');
      return;
    }
    Navigator.of(context).pop((_name.text.trim(), _phone.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Nouveau fournisseur', style: T.h2),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            style: T.body,
            decoration: InputDecoration(
                labelText: 'Nom *', errorText: _error),
            onSubmitted: (_) => _ok(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _phone,
            style: T.monoBody,
            decoration: const InputDecoration(labelText: 'Téléphone'),
            onSubmitted: (_) => _ok(),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(label: 'Créer', onPressed: _ok),
      ],
    );
  }
}

class _SerialsDialog extends StatefulWidget {
  const _SerialsDialog();

  @override
  State<_SerialsDialog> createState() => _SerialsDialogState();
}

class _SerialsDialogState extends State<_SerialsDialog> {
  final _ctrl = TextEditingController();
  bool _used = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Ajouter des N° de série', style: T.h2),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Un numéro par ligne — scannez-les à la suite.', style: T.small),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 7,
              style: T.monoBody,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _used,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text('Appareils d’occasion (reprise)', style: T.bodyMuted),
              onChanged: (v) => setState(() => _used = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
          label: 'Ajouter',
          onPressed: () => Navigator.of(context).pop((
            [
              for (final l in _ctrl.text.split('\n'))
                if (l.trim().isNotEmpty) l.trim()
            ],
            _used
          )),
        ),
      ],
    );
  }
}
