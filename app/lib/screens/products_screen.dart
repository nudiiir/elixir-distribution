import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import '../util/prefs.dart';
import '../widgets/data_table.dart';
import '../widgets/fiche_produit.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/product_thumb.dart';
import '../widgets/ui.dart';
import 'product_page.dart';

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

/// Suivi filter values → label (each shown only when its feature is on).
const _trackLabels = {
  'lots': 'Lot & DLC',
  'serials': 'N° de série',
  'weighed': 'Au poids',
  'variants': 'Déclinaisons',
  'service': 'Service',
};

class _ProductsScreenState extends State<ProductsScreen> {
  static const _pk = 'products'; // UiPrefs screen key

  bool get _viewCost => widget.session.user.can('view_cost');
  bool get _canEdit => widget.session.user.can('products');
  Features get _f => Features.instance;

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Product> _items = const [];
  List<Category> _cats = const [];
  List<StockLevel> _levels = const [];
  List<Warehouse> _warehouses = const [];
  List<Partner> _suppliers = const [];
  Set<String> _expiringSoon = const {};
  Map<String, String> _company = const {};

  // Filtres mémorisés par utilisateur (UiPrefs).
  String? _warehouseFilter = UiPrefs.instance.get<String>(_pk, 'f_wh');
  String? _catFilter = UiPrefs.instance.get<String>(_pk, 'f_cat');
  String? _brandFilter = UiPrefs.instance.get<String>(_pk, 'f_brand');
  String? _supplierFilter = UiPrefs.instance.get<String>(_pk, 'f_sup');
  String _status = UiPrefs.instance.get<String>(_pk, 'f_status') ?? 'active';
  String? _track = UiPrefs.instance.get<String>(_pk, 'f_track');
  String _quick = UiPrefs.instance.get<String>(_pk, 'f_quick') ?? '';

  bool _loading = true;
  String? _error;
  final _ctl = DataListController<Product>();
  String? _openId; // produit ouvert dans le panneau latéral

  @override
  void initState() {
    super.initState();
    widget.searchRequest?.addListener(_onExternalSearch);
    _f.addListener(_onFeatures);
    final q = widget.searchRequest?.value ?? '';
    if (q.isNotEmpty) _searchCtrl.text = q;
    _load();
    _loadCats();
    widget.api.settings().then((s) {
      if (mounted) setState(() => _company = s);
    }).catchError((_) {});
  }

  void _onFeatures() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_onExternalSearch);
    _f.removeListener(_onFeatures);
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onExternalSearch() {
    final q = widget.searchRequest?.value ?? '';
    if (q.isEmpty) return;
    _searchCtrl.text = q;
    _load();
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

  String _supplierName(String? id) {
    for (final s in _suppliers) {
      if (s.id == id) return s.name;
    }
    return '';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.products(
          q: _searchCtrl.text.trim(),
          limit: 500,
          includeInactive: _status != 'active');
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Serveur injoignable.';
        });
      }
    }
    _loadContext();
  }

  Future<void> _loadContext() async {
    try {
      final levels = await widget.api.stockLevels();
      if (mounted) setState(() => _levels = levels);
    } catch (_) {}
    try {
      final whs = await widget.api.warehouses();
      if (mounted) setState(() => _warehouses = whs);
    } catch (_) {}
    if (_f.lots) {
      try {
        final lots = await widget.api.lots(expiringDays: 90);
        if (mounted) {
          setState(() => _expiringSoon = {for (final l in lots) l.productId});
        }
      } catch (_) {}
    }
    try {
      final sup = await widget.api.partners(kind: 'supplier', limit: 500);
      if (mounted) setState(() => _suppliers = sup);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- calculs

  // Cumuls par produit pour le dépôt filtré, recalculés seulement quand les
  // niveaux ou le dépôt changent (les cellules et pastilles les lisent souvent).
  List<StockLevel>? _aggSrc;
  String? _aggWh;
  Map<String, int> _stockMap = const {};
  Map<String, int> _cmupMap = const {};

  void _ensureAgg() {
    if (identical(_aggSrc, _levels) && _aggWh == _warehouseFilter) return;
    final stock = <String, int>{};
    final posQty = <String, int>{};
    final posValue = <String, int>{};
    for (final l in _levels) {
      if (_warehouseFilter != null && l.warehouseId != _warehouseFilter) {
        continue;
      }
      stock[l.productId] = (stock[l.productId] ?? 0) + l.qtyMilli;
      if (l.qtyMilli > 0) {
        posQty[l.productId] = (posQty[l.productId] ?? 0) + l.qtyMilli;
        posValue[l.productId] =
            (posValue[l.productId] ?? 0) + (l.qtyMilli * l.avgCost) ~/ 1000;
      }
    }
    _stockMap = stock;
    _cmupMap = {
      for (final e in posQty.entries)
        e.key: ((posValue[e.key] ?? 0) * 1000) ~/ e.value,
    };
    _aggSrc = _levels;
    _aggWh = _warehouseFilter;
  }

  /// Stock du produit pour le dépôt sélectionné (ou tous combinés).
  int _stockOf(Product p) {
    _ensureAgg();
    return _stockMap[p.id] ?? 0;
  }

  /// CMUP pour le dépôt sélectionné — moyenne pondérée quand « tous ». Tiret
  /// (null) quand le stock est nul : une moyenne de rien n'est pas zéro.
  int? _cmupOf(Product p) {
    _ensureAgg();
    return _cmupMap[p.id];
  }

  /// Marge sur PV_HT contre CMUP (spec §2.4) — en pct x100.
  int? _marginOf(Product p) {
    final cmup = _cmupOf(p);
    if (cmup == null || cmup <= 0) return null;
    final pvHT = roundDiv(p.priceRetail * 10000, 10000 + p.vatRate);
    return roundDiv((pvHT - cmup) * 10000, cmup);
  }

  Set<String> get _parentIds => {
        for (final p in _items)
          if (p.parentProductId != null) p.parentProductId!
      };

  bool _hasVariantPool(Product p, Set<String> parents) =>
      p.parentProductId == null && _stockOf(p) > 0 && parents.contains(p.id);

  bool _isLow(Product p) =>
      !p.isService &&
      p.minStockMilli > 0 &&
      _stockOf(p) > 0 &&
      _stockOf(p) < p.minStockMilli;

  bool _quickMatch(String q, Product p) => switch (q) {
        'rupture' => !p.isService && _stockOf(p) <= 0,
        'sous_min' => _isLow(p),
        'peremption' => _f.lots && _expiringSoon.contains(p.id),
        _ => true,
      };

  bool _trackOn(String key) => switch (key) {
        'lots' => _f.lots,
        'serials' => _f.serials,
        'weighed' => _f.weighed,
        'variants' => _f.variants,
        'service' => _f.services,
        _ => false,
      };

  /// Tous les filtres sauf la pastille rapide (sert aussi à compter les pastilles).
  List<Product> get _base {
    final parents = _parentIds;
    final track = _track != null && _trackOn(_track!) ? _track : null;
    return [
      for (final p in _items)
        if ((_catFilter == null || p.categoryId == _catFilter) &&
            (_brandFilter == null || p.brand == _brandFilter) &&
            (_supplierFilter == null || p.defaultSupplierId == _supplierFilter) &&
            switch (_status) {
              'inactive' => !p.active,
              'all' => true,
              _ => p.active,
            } &&
            switch (track) {
              'lots' => p.trackLots || p.trackExpiry,
              'serials' => p.trackSerials,
              'weighed' => p.isWeighable,
              'variants' =>
                p.parentProductId != null || parents.contains(p.id),
              'service' => p.isService,
              _ => true,
            })
          p
    ];
  }

  List<Product> get _filtered {
    final base = _base;
    if (_quick.isEmpty) return base;
    return [for (final p in base) if (_quickMatch(_quick, p)) p];
  }

  // ---------------------------------------------------------------- filtres

  void _setPref(String key, Object? v) => UiPrefs.instance.set(_pk, key, v);

  void _setQuick(String q) {
    setState(() => _quick = _quick == q ? '' : q);
    _setPref('f_quick', _quick.isEmpty ? null : _quick);
  }

  void _setStatus(String? v) {
    final s = v ?? 'active';
    final reload = (s == 'active') != (_status == 'active');
    setState(() => _status = s);
    _setPref('f_status', s == 'active' ? null : s);
    if (reload) _load();
  }

  void _clearFilters() {
    final reload = _status != 'active';
    setState(() {
      _warehouseFilter = null;
      _catFilter = null;
      _brandFilter = null;
      _supplierFilter = null;
      _track = null;
      _quick = '';
      _status = 'active';
    });
    for (final k in ['f_wh', 'f_cat', 'f_brand', 'f_sup', 'f_track', 'f_quick', 'f_status']) {
      _setPref(k, null);
    }
    if (reload) _load();
  }

  List<ActiveFilter> get _activeFilters {
    String whName(String id) => _warehouses
        .firstWhere((w) => w.id == id,
            orElse: () => Warehouse.fromJson({'id': id, 'name': 'Dépôt'}))
        .name;
    return [
      if (_warehouseFilter != null)
        ActiveFilter('Dépôt : ${whName(_warehouseFilter!)}', () {
          setState(() => _warehouseFilter = null);
          _setPref('f_wh', null);
        }),
      if (_catFilter != null)
        ActiveFilter('Catégorie : ${_catName(_catFilter)}', () {
          setState(() => _catFilter = null);
          _setPref('f_cat', null);
        }),
      if (_brandFilter != null)
        ActiveFilter('Marque : $_brandFilter', () {
          setState(() => _brandFilter = null);
          _setPref('f_brand', null);
        }),
      if (_supplierFilter != null)
        ActiveFilter('Fournisseur : ${_supplierName(_supplierFilter)}', () {
          setState(() => _supplierFilter = null);
          _setPref('f_sup', null);
        }),
      if (_status != 'active')
        ActiveFilter(
            'Statut : ${_status == 'inactive' ? 'Inactifs' : 'Tous'}',
            () => _setStatus(null)),
      if (_track != null && _trackOn(_track!))
        ActiveFilter('Suivi : ${_trackLabels[_track] ?? _track}', () {
          setState(() => _track = null);
          _setPref('f_track', null);
        }),
    ];
  }

  Widget _toolbar() {
    final base = _base;
    int count(String q) => base.where((p) => _quickMatch(q, p)).length;
    final brands = {
      for (final p in _items)
        if (p.brand.isNotEmpty) p.brand
    }.toList()
      ..sort();
    final trackOptions = [
      for (final e in _trackLabels.entries)
        if (_trackOn(e.key)) (e.key, e.value),
    ];
    return ListToolbar(
      search: _searchCtrl,
      searchHint: 'Rechercher un produit ou scanner…',
      onSearchChanged: (_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 250), _load);
      },
      onSearchSubmitted: (_) => _load(),
      quickFilters: [
        FilterPill(
            label: 'Rupture',
            icon: Icons.remove_shopping_cart_outlined,
            active: _quick == 'rupture',
            count: count('rupture'),
            onTap: () => _setQuick('rupture')),
        FilterPill(
            label: 'Sous le minimum',
            icon: Icons.trending_down_rounded,
            active: _quick == 'sous_min',
            count: count('sous_min'),
            onTap: () => _setQuick('sous_min')),
        if (_f.lots)
          FilterPill(
              label: 'Péremption < 90 j',
              icon: Icons.hourglass_bottom_rounded,
              active: _quick == 'peremption',
              count: count('peremption'),
              onTap: () => _setQuick('peremption')),
      ],
      panel: FilterPanel(fields: [
        if (_warehouses.length > 1)
          FilterField<String>(
            label: 'Dépôt',
            value: _warehouseFilter,
            allLabel: 'Tous les dépôts',
            options: [for (final w in _warehouses) (w.id, w.name)],
            onChanged: (v) {
              setState(() => _warehouseFilter = v);
              _setPref('f_wh', v);
            },
          ),
        FilterField<String>(
          label: 'Catégorie',
          value: _cats.any((c) => c.id == _catFilter) ? _catFilter : null,
          allLabel: 'Toutes',
          options: [for (final c in _cats) (c.id, c.name)],
          onChanged: (v) {
            setState(() => _catFilter = v);
            _setPref('f_cat', v);
          },
        ),
        if (brands.isNotEmpty)
          FilterField<String>(
            label: 'Marque',
            value: brands.contains(_brandFilter) ? _brandFilter : null,
            allLabel: 'Toutes',
            options: [for (final b in brands) (b, b)],
            onChanged: (v) {
              setState(() => _brandFilter = v);
              _setPref('f_brand', v);
            },
          ),
        if (_suppliers.isNotEmpty)
          FilterField<String>(
            label: 'Fournisseur',
            value: _suppliers.any((s) => s.id == _supplierFilter)
                ? _supplierFilter
                : null,
            options: [for (final s in _suppliers) (s.id, s.name)],
            onChanged: (v) {
              setState(() => _supplierFilter = v);
              _setPref('f_sup', v);
            },
          ),
        FilterField<String>(
          label: 'Statut',
          value: _status == 'active' ? null : _status,
          allLabel: 'Actifs',
          options: const [('inactive', 'Inactifs'), ('all', 'Tous')],
          onChanged: _setStatus,
        ),
        if (trackOptions.isNotEmpty)
          FilterField<String>(
            label: 'Suivi',
            value: _track != null && _trackOn(_track!) ? _track : null,
            options: trackOptions,
            onChanged: (v) {
              setState(() => _track = v);
              _setPref('f_track', v);
            },
          ),
      ]),
      active: _activeFilters,
      onClearAll: _clearFilters,
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _importCsv() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportCsvDialog(api: widget.api),
    );
    if (done == true) _load();
  }

  Future<void> _manageCats() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CategoriesDialog(api: widget.api),
    );
    _loadCats();
    _load();
  }

  Future<void> _quickCreate() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProductFormDialog(api: widget.api, showCost: _viewCost),
    );
    if (saved == true) _load();
  }

  List<String> get _brandList => {
        for (final p in _items)
          if (p.brand.isNotEmpty) p.brand
      }.toList()
        ..sort();

  Future<void> _openPage({Product? existing, Product? template}) async {
    final saved = await openProductPage(context,
        api: widget.api,
        existing: existing,
        template: template,
        showCost: _viewCost,
        brands: _brandList);
    if (saved == true) _load();
  }

  Future<void> _openFiche(Product p, {bool moves = false}) async {
    setState(() => _openId = p.id);
    await showFicheProduit(
      context,
      widget.api,
      p.id,
      canCost: _viewCost,
      onChanged: _load,
      onEdit: _canEdit ? (prod) => _openPage(existing: prod) : null,
      navigate: (cur, delta) {
        final rows = _ctl.rows;
        final i = rows.indexWhere((r) => r.id == cur);
        final j = i + delta;
        return i >= 0 && j >= 0 && j < rows.length ? rows[j].id : null;
      },
      onShown: (id) {
        if (mounted) setState(() => _openId = id);
      },
      focusMoves: moves,
    );
    if (mounted) setState(() => _openId = null);
  }

  Future<void> _adjust(Product p) async {
    final done = await showAdjustStock(context, widget.api, p.id);
    if (done) {
      _load();
      if (mounted) showToast(context, 'Stock de « ${p.name} » ajusté');
    }
  }

  Future<int?> _bulk(List<Product> rows, String op,
      [Map<String, dynamic> extra = const {}]) async {
    try {
      final n = await widget.api
          .bulkProducts([for (final p in rows) p.id], op, extra: extra);
      if (mounted) {
        showToast(context, '$n produit${n > 1 ? 's' : ''} mis à jour');
      }
      _load();
      return n;
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
      return null;
    }
  }

  Future<void> _setActive(Product p, bool active) async {
    if (!active) {
      final ok = await confirmAction(context,
          title: 'Désactiver « ${p.name} » ?',
          message:
              'Le produit disparaît de la caisse et des listes ; son historique et son stock restent. Vous pourrez le réactiver.',
          confirmLabel: 'Désactiver',
          danger: true);
      if (!ok) return;
    }
    await _bulk([p], active ? 'activate' : 'deactivate');
  }

  Future<void> _printDisplayed() async {
    final rows = _ctl.rows;
    if (rows.isEmpty) return;
    if (rows.length > 40) {
      final ok = await confirmAction(context,
          title: 'Imprimer ${rows.length} étiquettes ?',
          message:
              'Toutes les lignes affichées. Astuce : sélectionnez des lignes pour n’imprimer qu’elles.',
          confirmLabel: 'Imprimer');
      if (!ok || !mounted) return;
    }
    await printProductLabels(context, widget.api, rows);
  }

  List<RowAction<Product>> _rowMenu(Product p) => [
        RowAction('Voir la fiche', Icons.visibility_outlined, (p) => _openFiche(p)),
        if (_canEdit)
          RowAction('Modifier', Icons.edit_outlined, (p) => _openPage(existing: p)),
        if (!p.isService)
          RowAction('Ajuster le stock', Icons.tune_rounded, _adjust),
        RowAction('Imprimer étiquettes', Icons.qr_code_2_rounded,
            (p) => printProductLabels(context, widget.api, [p])),
        if (!p.isService)
          RowAction('Historique des mouvements', Icons.history_rounded,
              (p) => _openFiche(p, moves: true)),
        if (_canEdit)
          RowAction('Dupliquer', Icons.copy_all_rounded,
              (p) => _openPage(template: p)),
        if (_canEdit)
          p.active
              ? RowAction('Désactiver', Icons.block_rounded,
                  (p) => _setActive(p, false),
                  danger: true)
              : RowAction('Réactiver', Icons.restore_rounded,
                  (p) => _setActive(p, true)),
      ];

  List<BulkAction<Product>> get _bulkActions => [
        BulkAction('Imprimer étiquettes', Icons.qr_code_2_rounded, (rows) async {
          await printProductLabels(context, widget.api, rows);
          return false;
        }),
        if (_canEdit) ...[
          BulkAction('Changer de catégorie', Icons.sell_outlined, (rows) async {
            final v = await showDialog<(String?,)>(
              context: context,
              builder: (_) => _PickCategoryDialog(cats: _cats, count: rows.length),
            );
            if (v == null) return false;
            return await _bulk(rows, 'set_category', {'category_id': v.$1}) != null;
          }),
          BulkAction('Changer la TVA', Icons.percent_rounded, (rows) async {
            final v = await showDialog<int>(
              context: context,
              builder: (_) => _PickVatDialog(count: rows.length),
            );
            if (v == null) return false;
            return await _bulk(rows, 'set_vat', {'vat_rate': v}) != null;
          }),
          BulkAction('Définir une promotion', Icons.local_offer_outlined,
              (rows) async {
            final v = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (_) => _PromoDialog(count: rows.length),
            );
            if (v == null) return false;
            return await _bulk(rows, 'set_promo', v) != null;
          }),
          BulkAction('Retirer la promotion', Icons.money_off_rounded,
              (rows) async {
            final ok = await confirmAction(context,
                title: 'Retirer la promotion de ${rows.length} produit(s) ?',
                confirmLabel: 'Retirer');
            if (!ok) return false;
            return await _bulk(rows, 'clear_promo') != null;
          }),
          if (_status != 'active')
            BulkAction('Réactiver', Icons.restore_rounded, (rows) async {
              return await _bulk(rows, 'activate') != null;
            }),
          BulkAction('Désactiver', Icons.block_rounded, (rows) async {
            final ok = await confirmAction(context,
                title: 'Désactiver ${rows.length} produit(s) ?',
                message:
                    'Ils disparaissent de la caisse et des listes ; historique et stock restent. Réactivables depuis le filtre Statut.',
                confirmLabel: 'Désactiver',
                danger: true);
            if (!ok) return false;
            return await _bulk(rows, 'deactivate') != null;
          }, danger: true),
        ],
      ];

  // ---------------------------------------------------------------- build

  String _unitOf(Product p) => p.isWeighable || p.unit == 'kg' ? 'kg' : 'u.';

  String _pct(int m) =>
      '${(m / 100).toStringAsFixed(1).replaceAll('.', ',')}%';

  List<ColumnSpec<Product>> _columns(Set<String> parents) => [
        ColumnSpec(
          id: 'name',
          label: 'Produit',
          flex: 5,
          hideable: false,
          sortKey: (p) => p.name.toLowerCase(),
          exportValue: (p) => p.name,
          cell: (context, p) => Row(children: [
            ProductThumb(api: widget.api, product: p, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(p.name,
                      style: T.body.copyWith(color: p.active ? T.ink : T.ghost),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (p.brand.isNotEmpty)
                    Text(p.brand,
                        style: T.small.copyWith(fontSize: 10.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
        ),
        ColumnSpec(
          id: 'category',
          label: 'Catégorie',
          flex: 2,
          sortKey: (p) => _catName(p.categoryId),
          exportValue: (p) => p.categoryId == null ? '' : _catName(p.categoryId),
          cell: (context, p) => Text(_catName(p.categoryId),
              style: T.small.copyWith(fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        ColumnSpec(
          id: 'barcode',
          label: 'Code-barres',
          flex: 3,
          sortKey: (p) => p.barcode ?? '',
          exportValue: (p) =>
              [if (p.barcode != null) p.barcode!, ...p.barcodes].join(' '),
          cell: (context, p) => Text(
              p.barcodes.isEmpty
                  ? (p.barcode ?? '—')
                  : '${p.barcode ?? p.barcodes.first} +${p.barcode == null ? p.barcodes.length - 1 : p.barcodes.length}',
              style: T.monoSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        ColumnSpec(
          id: 'stock',
          label: 'Stock',
          width: 100,
          numeric: true,
          sortKey: (p) => p.isService ? 1 << 40 : _stockOf(p),
          exportValue: (p) => p.isService ? '' : _stockOf(p) / 1000,
          cell: (context, p) {
            if (p.isService) {
              return Text('service', style: T.small.copyWith(fontSize: 11));
            }
            final s = _stockOf(p);
            final low = p.minStockMilli > 0 && s < p.minStockMilli;
            final color = s <= 0
                ? T.dangerDark
                : low
                    ? T.warnDark
                    : T.ink;
            return Text.rich(
              TextSpan(children: [
                TextSpan(text: fmtQty(s)),
                TextSpan(
                    text: ' ${_unitOf(p)}',
                    style: T.small.copyWith(fontSize: 10.5, color: T.faint)),
              ]),
              textAlign: TextAlign.end,
              style: T.monoBody.copyWith(color: color),
            );
          },
        ),
        ColumnSpec(
          id: 'vat',
          label: 'TVA',
          width: 56,
          visibleByDefault: false,
          sortKey: (p) => p.vatRate,
          exportValue: (p) => p.vatRate / 100,
          cell: (context, p) => Text('${p.vatRate ~/ 100}%', style: T.monoSmall),
        ),
        ColumnSpec(
          id: 'price',
          label: 'Vente TTC',
          width: 120,
          numeric: true,
          sortKey: (p) => p.priceRetail,
          exportValue: (p) => p.priceRetail / 100,
          cell: (context, p) {
            final dg = _f.wholesale && p.priceWholesale != null && p.priceWholesale! > 0;
            final price = Text(fmtDA(p.priceRetail),
                style: T.monoBody.copyWith(
                    color: p.promoActive ? T.warnDark : null));
            final main = p.promoActive
                ? Tooltip(
                    message: 'Promotion en cours : ${fmtDA(p.promoPrice!)}',
                    child: price)
                : price;
            if (!dg) return main;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                main,
                Text('DG ${fmtDA(p.priceWholesale!)}',
                    style: T.monoSmall.copyWith(fontSize: 10, color: T.faint)),
              ],
            );
          },
        ),
        if (_viewCost)
          ColumnSpec(
            id: 'cmup',
            label: 'Achat (CMUP)',
            width: 110,
            numeric: true,
            sortKey: (p) => _cmupOf(p) ?? -1,
            exportValue: (p) {
              final c = _cmupOf(p);
              return c == null ? '' : c / 100;
            },
            cell: (context, p) {
              final c = _cmupOf(p);
              return Text(c == null ? '—' : fmtDA(c),
                  style: T.monoBody.copyWith(color: T.muted));
            },
          ),
        if (_viewCost)
          ColumnSpec(
            id: 'margin',
            label: 'Marge',
            width: 75,
            numeric: true,
            sortKey: (p) => _marginOf(p) ?? -999999,
            exportValue: (p) {
              final m = _marginOf(p);
              return m == null ? '' : m / 100;
            },
            cell: (context, p) {
              final m = _marginOf(p);
              return Text(m == null ? '—' : _pct(m),
                  style: T.monoSmall.copyWith(
                      color: m != null && m < 0 ? T.dangerDark : T.mintDark));
            },
          ),
        if (_viewCost)
          ColumnSpec(
            id: 'value_cost',
            label: 'Valeur au coût',
            width: 120,
            numeric: true,
            visibleByDefault: false,
            sortKey: (p) => (_stockOf(p) * (_cmupOf(p) ?? 0)) ~/ 1000,
            exportValue: (p) =>
                ((_stockOf(p) * (_cmupOf(p) ?? 0)) ~/ 1000) / 100,
            cell: (context, p) => Text(
                fmtDA((_stockOf(p).clamp(0, 1 << 50) * (_cmupOf(p) ?? 0)) ~/ 1000),
                style: T.monoSmall),
          ),
        ColumnSpec(
          id: 'value_sale',
          label: 'Valeur de vente',
          width: 120,
          numeric: true,
          visibleByDefault: false,
          sortKey: (p) => (_stockOf(p) * p.priceRetail) ~/ 1000,
          exportValue: (p) => ((_stockOf(p) * p.priceRetail) ~/ 1000) / 100,
          cell: (context, p) => Text(
              fmtDA((_stockOf(p).clamp(0, 1 << 50) * p.priceRetail) ~/ 1000),
              style: T.monoSmall),
        ),
        ColumnSpec(
          id: 'brand',
          label: 'Marque',
          flex: 2,
          visibleByDefault: false,
          sortKey: (p) => p.brand.toLowerCase(),
          exportValue: (p) => p.brand,
          cell: (context, p) => Text(p.brand.isEmpty ? '—' : p.brand,
              style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        ColumnSpec(
          id: 'supplier',
          label: 'Fournisseur',
          flex: 2,
          visibleByDefault: false,
          sortKey: (p) => _supplierName(p.defaultSupplierId).toLowerCase(),
          exportValue: (p) => _supplierName(p.defaultSupplierId),
          cell: (context, p) {
            final n = _supplierName(p.defaultSupplierId);
            return Text(n.isEmpty ? '—' : n,
                style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis);
          },
        ),
        ColumnSpec(
          id: 'alerts',
          label: 'Alertes',
          width: 86,
          sortKey: (p) =>
              (!p.isService && _stockOf(p) <= 0 ? 0 : 1) * 100 +
              (_expiringSoon.contains(p.id) ? 0 : 10),
          exportValue: (p) => [
            if (!p.isService && _stockOf(p) <= 0) 'Rupture',
            if (_isLow(p)) 'Sous le minimum',
            if (_f.lots && _expiringSoon.contains(p.id)) 'Péremption < 90 j',
            if (_hasVariantPool(p, parents)) 'Stock à ventiler',
          ].join(', '),
          cell: (context, p) {
            final icons = <Widget>[];
            final s = _stockOf(p);
            if (!p.isService && s <= 0) {
              icons.add(const Tooltip(
                  message: 'Rupture',
                  child: Icon(Icons.remove_shopping_cart_outlined,
                      size: 14, color: T.dangerDark)));
            } else if (_isLow(p)) {
              icons.add(const Tooltip(
                  message: 'Sous le minimum',
                  child: Icon(Icons.trending_down_rounded,
                      size: 14, color: T.warnDark)));
            }
            if (_f.lots && _expiringSoon.contains(p.id)) {
              icons.add(const Tooltip(
                  message: 'Péremption < 90 j',
                  child: Icon(Icons.hourglass_bottom_rounded,
                      size: 14, color: T.warnDark)));
            }
            if (_hasVariantPool(p, parents)) {
              icons.add(const Tooltip(
                  message: 'Stock à ventiler entre les déclinaisons',
                  child: Icon(Icons.call_split_rounded,
                      size: 14, color: T.warnDark)));
            }
            if (p.promoActive) {
              icons.add(const Tooltip(
                  message: 'Promotion en cours',
                  child: Icon(Icons.local_offer_outlined,
                      size: 14, color: T.warnDark)));
            }
            return Row(children: [
              for (final w in icons)
                Padding(
                    padding: const EdgeInsetsDirectional.only(end: 4),
                    child: w),
            ]);
          },
        ),
      ];

  Widget _empty() {
    final filtered = _quick.isNotEmpty ||
        _activeFilters.isNotEmpty ||
        _searchCtrl.text.trim().isNotEmpty;
    if (filtered && _items.isNotEmpty || _searchCtrl.text.trim().isNotEmpty) {
      return EmptyState(
        icon: Icons.filter_alt_off_outlined,
        text: 'Aucun produit ne correspond à la recherche ou aux filtres.',
        actions: [
          ('Effacer les filtres', () {
            _searchCtrl.clear();
            _clearFilters();
            _load();
          }),
        ],
      );
    }
    return EmptyState(
      icon: Icons.category_outlined,
      text: 'Aucun produit pour l’instant.\nImportez votre catalogue ou créez le premier produit.',
      actions: [
        if (_canEdit) ('Importer un fichier', _importCsv),
        if (_canEdit) ('Nouveau produit', () => _openPage()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final parents = _parentIds;
    final total = _items.where((p) => _status == 'active' ? p.active : true).length;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Produits',
            subtitle: _loading && _items.isEmpty
                ? null
                : rows.length == total
                    ? '$total produit${total > 1 ? 's' : ''}${total >= 500 ? ' (500 premiers — affinez la recherche)' : ''}'
                    : '${rows.length} / $total produits',
            primaryLabel: _canEdit ? 'Nouveau produit' : null,
            onPrimary: () => _openPage(),
            more: [
              if (_canEdit)
                MenuEntry('Importer un fichier', Icons.upload_file_outlined,
                    _importCsv),
              if (_canEdit)
                MenuEntry('Catégories', Icons.sell_outlined, _manageCats),
              if (_canEdit)
                MenuEntry('Création rapide', Icons.bolt_rounded, _quickCreate),
              MenuEntry('Imprimer des étiquettes', Icons.qr_code_2_rounded,
                  _printDisplayed),
            ],
          ),
          const SizedBox(height: 16),
          _toolbar(),
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Product>(
              prefsKey: _pk,
              items: rows,
              rowId: (p) => p.id,
              controller: _ctl,
              highlight: (p) => p.id == _openId,
              loading: _loading,
              error: _error,
              onRetry: _load,
              onTap: _openFiche,
              rowMenu: _rowMenu,
              bulkActions: _bulkActions,
              exportTitle: 'Produits',
              exportBaseName: 'produits',
              company: _company,
              empty: _empty(),
              aggregates: (rows) {
                if (!_viewCost) return const [];
                // Valeur du stock + marge PONDÉRÉE par la valeur du stock —
                // jamais une moyenne simple de pourcentages (spec §3.2).
                var value = 0, weighted = 0;
                for (final p in rows) {
                  final cmup = _cmupOf(p);
                  final stock = _stockOf(p);
                  if (cmup == null || stock <= 0) continue;
                  final v = (stock * cmup) ~/ 1000;
                  value += v;
                  final pvHT =
                      roundDiv(p.priceRetail * 10000, 10000 + p.vatRate);
                  weighted += (stock * (pvHT - cmup)) ~/ 1000;
                }
                final marginPct =
                    value <= 0 ? null : roundDiv(weighted * 10000, value);
                return [
                  ('Valeur du stock', fmtDA(value)),
                  if (marginPct != null) ('Marge pondérée', _pct(marginPct)),
                ];
              },
              columns: _columns(parents),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- Dialogues des actions groupées ----------------

class _PickCategoryDialog extends StatefulWidget {
  const _PickCategoryDialog({required this.cats, required this.count});
  final List<Category> cats;
  final int count;

  @override
  State<_PickCategoryDialog> createState() => _PickCategoryDialogState();
}

class _PickCategoryDialogState extends State<_PickCategoryDialog> {
  String? _id;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Changer de catégorie', style: T.h2),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.count} produit(s) sélectionné(s)', style: T.bodyMuted),
            const SizedBox(height: 10),
            DropdownButton<String?>(
              isExpanded: true,
              value: _id,
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('Sans catégorie')),
                for (final c in widget.cats)
                  DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _id = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
            label: 'Appliquer',
            onPressed: () => Navigator.of(context).pop((_id,))),
      ],
    );
  }
}

class _PickVatDialog extends StatefulWidget {
  const _PickVatDialog({required this.count});
  final int count;

  @override
  State<_PickVatDialog> createState() => _PickVatDialogState();
}

class _PickVatDialogState extends State<_PickVatDialog> {
  late int _vat = Features.instance.defaultVat;

  @override
  Widget build(BuildContext context) {
    final vats = {1900, 900, 0, Features.instance.defaultVat}.toList();
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Changer la TVA', style: T.h2),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${widget.count} produit(s). Le prix de vente TTC ne change pas ; le HT est recalculé.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            Wrap(spacing: 6, children: [
              for (final v in vats)
                ChoiceChip(
                  label: Text('${v ~/ 100} %'),
                  selected: _vat == v,
                  selectedColor: T.mintTint,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _vat = v),
                ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
            label: 'Appliquer', onPressed: () => Navigator.of(context).pop(_vat)),
      ],
    );
  }
}

class _PromoDialog extends StatefulWidget {
  const _PromoDialog({required this.count});
  final int count;

  @override
  State<_PromoDialog> createState() => _PromoDialogState();
}

class _PromoDialogState extends State<_PromoDialog> {
  final _price = TextEditingController();
  String? _start;
  String? _end;
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start) async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse((start ? _start : _end) ?? '') ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    final iso =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    setState(() => start ? _start = iso : _end = iso);
  }

  void _ok() {
    final p = parseDA(_price.text);
    if (p == null || p <= 0) {
      setState(() => _error = 'Saisissez le prix promo TTC.');
      return;
    }
    if (_start != null && _end != null && _end!.compareTo(_start!) < 0) {
      setState(() => _error = 'La fin précède le début.');
      return;
    }
    Navigator.of(context)
        .pop({'promo_price': p, 'promo_start': _start, 'promo_end': _end});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Définir une promotion', style: T.h2),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.count} produit(s) — même prix promo pour tous.',
                style: T.bodyMuted),
            const SizedBox(height: 10),
            TextField(
              controller: _price,
              autofocus: true,
              style: T.monoBody,
              decoration: InputDecoration(
                  labelText: 'Prix promo TTC (DA)', errorText: _error),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => _pick(true),
                    child: Text('Du ${_start ?? '—'}')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                    onPressed: () => _pick(false),
                    child: Text('Au ${_end ?? '—'}')),
              ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(label: 'Appliquer', onPressed: _ok),
      ],
    );
  }
}

/// « Création rapide » : le formulaire court d'origine (modification et
/// création complète passent par la page produit).
class _ProductFormDialog extends StatefulWidget {
  const _ProductFormDialog({required this.api, this.showCost = true});
  final ApiClient api;
  final bool showCost;

  /// Toujours une création ici.
  Product? get existing => null;

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
  late final _description =
      TextEditingController(text: widget.existing?.description ?? '');
  late final _wholesale = TextEditingController(
      text: widget.existing?.priceWholesale == null
          ? ''
          : editDA(widget.existing!.priceWholesale!));
  late int _vat = widget.existing?.vatRate ?? 1900;
  late bool _weighable = widget.existing?.isWeighable ?? false;
  late bool _trackSerials = widget.existing?.trackSerials ?? false;
  // Une seule case « Lot et péremption » pour tout le produit (spec §4.3).
  late bool _trackLotExp = (widget.existing?.trackLots ?? false) ||
      (widget.existing?.trackExpiry ?? false);
  late String? _categoryId = widget.existing?.categoryId;
  final _initialQty = TextEditingController();
  late final _brand = TextEditingController(text: widget.existing?.brand ?? '');
  late String? _supplierId = widget.existing?.defaultSupplierId;
  List<Partner> _supplierList = const [];
  late final List<BarcodeEntry> _bcodes =
      List.of(widget.existing?.barcodesEx ?? const []);
  late final List<Packaging> _packs =
      List.of(widget.existing?.packagings ?? const []);
  final _newBcode = TextEditingController();
  final _newBcodeLabel = TextEditingController();
  List<Category> _cats = const [];
  bool _generating = false;
  late String? _promoStart = widget.existing?.promoStart;
  late String? _promoEnd = widget.existing?.promoEnd;
  List<Product> _variants = const [];
  List<ProductUnit> _units = const [];
  bool _busy = false;
  bool _belowCostConfirmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVariants();
    _loadCats();
    _loadUnits();
    _loadSuppliers();
    if (widget.existing == null) {
      // TVA par défaut depuis le régime fiscal du magasin, pas codée en dur.
      widget.api.settings().then((s) {
        final v = int.tryParse(s['default_vat'] ?? '');
        if (v != null && mounted) setState(() => _vat = v);
      }).catchError((_) {});
    }
  }

  Future<void> _loadSuppliers() async {
    try {
      final sup = await widget.api.partners(kind: 'supplier', limit: 500);
      if (mounted) setState(() => _supplierList = sup);
    } catch (_) {}
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
      _minStock, _promoPrice, _warranty, _wholesale, _description,
      _initialQty, _brand, _newBcode, _newBcodeLabel
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
    final initQty = parseQty(_initialQty.text) ?? 0;
    if (widget.existing == null &&
        initQty > 0 &&
        (parseDA(_purchase.text) ?? 0) <= 0) {
      setState(() => _error =
          "Le prix d'achat est obligatoire quand une quantité initiale est saisie.");
      return;
    }
    // Vente sous le coût : avertit, ne bloque pas (spec §4.5).
    final achat = parseDA(_purchase.text) ?? 0;
    final vente = parseDA(_retail.text) ?? 0;
    if (achat > 0 && vente > 0) {
      final pvHT = roundDiv(vente * 10000, 10000 + _vat);
      if (pvHT < achat && !_belowCostConfirmed) {
        setState(() {
          _error =
              'Prix de vente HT (${fmtDA(pvHT)}) sous le prix d\'achat — cliquez encore pour confirmer.';
          _belowCostConfirmed = true;
        });
        return;
      }
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
        'barcodes_ex': [for (final b in _bcodes) b.toJson()],
        'packagings': [for (final k in _packs) k.toJson()],
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
        'description': _description.text.trim(),
        'brand': _brand.text.trim(),
        'track_expiry': _trackLotExp,
        'default_supplier_id': _supplierId,
        if (widget.existing == null) 'initial_qty_milli': initQty,
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
              // Le code-barres D'ABORD : scanner puis compléter — plus rapide
              // pour les quarante produits d'affilée (spec §4.3).
              Row(children: [
                Expanded(
                    flex: 2,
                    child: _Field(
                        label: 'Code-barres — scannez d\'abord',
                        controller: _barcode,
                        mono: true,
                        autofocus: widget.existing == null,
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
                const SizedBox(width: 10),
                Expanded(
                    flex: 3,
                    child: _Field(label: 'Désignation *', controller: _name)),
              ]),
              Row(children: [
                if (widget.showCost) ...[
                  Expanded(
                      child: _Field(
                          label: widget.existing != null
                              ? "Prix d'achat HT — figé (les réceptions le font vivre)"
                              : (_weighable
                                  ? "Prix d'achat HT (DA/kg)"
                                  : "Prix d'achat HT (DA)"),
                          controller: _purchase,
                          mono: true,
                          enabled: widget.existing == null,
                          onChanged: (_) => setState(() {}))),
                  const SizedBox(width: 10),
                ],
                Expanded(
                    child: _Field(
                        label: _weighable
                            ? 'Prix de vente TTC (DA/kg)'
                            : 'Prix de vente TTC (DA)',
                        controller: _retail,
                        mono: true,
                        onChanged: (_) => setState(() {}))),
                if (widget.existing == null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                      child: _Field(
                          label: 'Stock initial (quantité)',
                          controller: _initialQty,
                          mono: true,
                          onChanged: (_) => setState(() {}))),
                ],
              ]),
              // Marge affichée en direct pendant la saisie (PV_HT vs achat).
              if (widget.showCost) ...[
                Builder(builder: (context) {
                  final a = parseDA(_purchase.text) ?? 0;
                  final v = parseDA(_retail.text) ?? 0;
                  if (a <= 0 || v <= 0) return const SizedBox.shrink();
                  final pvHT = roundDiv(v * 10000, 10000 + _vat);
                  final m = roundDiv((pvHT - a) * 10000, a);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                        'Marge : ${(m / 100).toStringAsFixed(1).replaceAll('.', ',')} %  (PV HT ${fmtDA(pvHT)})',
                        style: T.monoSmall.copyWith(
                            color: m < 0 ? T.dangerDark : T.mintDark)),
                  );
                }),
              ],
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
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                InkWell(
                  onTap: () => setState(() => _trackLotExp = !_trackLotExp),
                  child: Row(children: [
                    Icon(
                        _trackLotExp
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 18,
                        color: _trackLotExp ? T.mintDeep : T.faint),
                    const SizedBox(width: 8),
                    Text('Lot et péremption (DLC exigée à la réception)',
                        style: T.bodyMuted),
                  ]),
                ),
                const SizedBox(width: 20),
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
              ]),
              if (widget.existing == null &&
                  (parseQty(_initialQty.text) ?? 0) > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      'Le stock initial sera créé par un document « Stock initial » — rien ne change le stock hors document.',
                      style: T.small.copyWith(fontSize: 10.5)),
                ),
              const SizedBox(height: 8),
              // ---- Tout le reste, replié : la création courante tient en
              // quelques champs, quinze secondes par produit. ----
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: Text('Plus de détails',
                      style: T.small.copyWith(
                          color: T.mintDark, fontWeight: FontWeight.w700)),
                  children: [
                    Row(children: [
                      Expanded(
                          child: _Field(
                              label: 'Désignation (arabe)',
                              controller: _nameAr)),
                      const SizedBox(width: 10),
                      Expanded(
                          child:
                              _Field(label: 'Marque', controller: _brand)),
                    ]),
                    Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const MicroLabel('Catégorie'),
                            const SizedBox(height: 4),
                            Container(
                              height: 38,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: T.bg,
                                borderRadius:
                                    BorderRadius.circular(T.rInner),
                                border: Border.all(color: T.border),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String?>(
                                  value:
                                      _cats.any((c) => c.id == _categoryId)
                                          ? _categoryId
                                          : null,
                                  isExpanded: true,
                                  style: T.body,
                                  dropdownColor: T.surface,
                                  items: [
                                    const DropdownMenuItem<String?>(
                                        value: null,
                                        child: Text('Sans catégorie')),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const MicroLabel('Fournisseur habituel'),
                            const SizedBox(height: 4),
                            Container(
                              height: 38,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: T.bg,
                                borderRadius:
                                    BorderRadius.circular(T.rInner),
                                border: Border.all(color: T.border),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String?>(
                                  value: _supplierList
                                          .any((s) => s.id == _supplierId)
                                      ? _supplierId
                                      : null,
                                  isExpanded: true,
                                  style: T.body,
                                  dropdownColor: T.surface,
                                  items: [
                                    const DropdownMenuItem<String?>(
                                        value: null, child: Text('— aucun —')),
                                    for (final s in _supplierList)
                                      DropdownMenuItem<String?>(
                                          value: s.id, child: Text(s.name)),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _supplierId = v),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ]),
                    Row(children: [
                      Expanded(
                          child: _Field(
                              label: 'Prix demi-gros TTC (DA) — vide = aucun',
                              controller: _wholesale,
                              mono: true)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _Field(
                              label: 'Stock minimum',
                              controller: _minStock,
                              mono: true)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _Field(
                              label: 'Garantie (mois)',
                              controller: _warranty,
                              mono: true)),
                    ]),
                    Row(children: [
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
                          Text('Suivi par N° de série / IMEI',
                              style: T.bodyMuted),
                        ]),
                      ),
                      const Spacer(),
                      if (widget.existing != null)
                        OutlinedButton.icon(
                          onPressed: _printLabel,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: T.border3),
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(T.rInner)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                          ),
                          icon: const Icon(Icons.qr_code_2_rounded,
                              size: 16, color: T.ink),
                          label: Text('Étiquette',
                              style: T.small.copyWith(
                                  color: T.ink,
                                  fontWeight: FontWeight.w700)),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    // ---- Codes-barres supplémentaires : une LISTE bâtie au
                    // scanner, avec libellé descriptif par code. Personne ne
                    // saisit correctement une chaîne à virgules. ----
                    const MicroLabel(
                        'CODES-BARRES SUPPLÉMENTAIRES — même stock, même prix'),
                    const SizedBox(height: 6),
                    for (var i = 0; i < _bcodes.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(children: [
                          SizedBox(
                              width: 150,
                              child: Text(_bcodes[i].code,
                                  style: T.monoSmall)),
                          Expanded(
                              child: Text(
                                  _bcodes[i].label.isEmpty
                                      ? '—'
                                      : _bcodes[i].label,
                                  style: T.small)),
                          InkWell(
                            onTap: () =>
                                setState(() => _bcodes.removeAt(i)),
                            child: const Icon(Icons.close,
                                size: 14, color: T.faint),
                          ),
                        ]),
                      ),
                    Row(children: [
                      Expanded(
                          child: _Field(
                              label: 'Scanner un code…',
                              controller: _newBcode,
                              mono: true)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _Field(
                              label: 'Libellé (Pomme…)',
                              controller: _newBcodeLabel)),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: IconButton(
                          onPressed: () {
                            final c = _newBcode.text.trim();
                            if (c.isEmpty) return;
                            setState(() {
                              _bcodes.add(BarcodeEntry(
                                  code: c,
                                  label: _newBcodeLabel.text.trim()));
                              _newBcode.clear();
                              _newBcodeLabel.clear();
                            });
                          },
                          icon: const Icon(Icons.add_circle_outline,
                              size: 20, color: T.mintDark),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    // ---- Conditionnements : carton = 24 pièces, avec son
                    // propre code-barres qui pré-remplit la réception. ----
                    const MicroLabel(
                        'CONDITIONNEMENTS — carton, boîte… (achat converti en pièces)'),
                    const SizedBox(height: 6),
                    for (var i = 0; i < _packs.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(children: [
                          Expanded(
                              child: Text(
                                  '${_packs[i].name} = ${fmtQty(_packs[i].factorMilli)} unités',
                                  style: T.body.copyWith(fontSize: 12.5))),
                          if (_packs[i].barcode != null)
                            Text(_packs[i].barcode!, style: T.monoSmall),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() => _packs.removeAt(i)),
                            child: const Icon(Icons.close,
                                size: 14, color: T.faint),
                          ),
                        ]),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () async {
                          final k = await showDialog<Packaging>(
                            context: context,
                            builder: (_) => const _PackagingDialog(),
                          );
                          if (k != null) setState(() => _packs.add(k));
                        },
                        icon: const Icon(Icons.add,
                            size: 14, color: T.mintDark),
                        label: Text('Ajouter un conditionnement',
                            style: T.small.copyWith(
                                color: T.mintDark,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const MicroLabel(
                        'Fiche produit — boutique en ligne (« Clé: Valeur » par ligne = tableau de caractéristiques)'),
                    const SizedBox(height: 4),
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: TextField(
                        controller: _description,
                        style: T.body,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText:
                              'Marque: Samsung\nStockage: 128 Go\nTéléphone neuf sous blister…',
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
              // ---- Promotion (jamais dans le formulaire de création :
              // une promo a des dates, une portée et un rapport) ----
              if (widget.existing != null) ...[
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
              ],
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
      this.trailing,
      this.enabled = true,
      this.autofocus = false,
      this.onChanged});
  final String label;
  final TextEditingController controller;
  final bool mono;
  final Widget? trailing;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

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
                  enabled: enabled,
                  autofocus: autofocus,
                  onChanged: onChanged,
                  style: (mono ? T.monoBody : T.body)
                      .copyWith(color: enabled ? null : T.ghost),
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

/// Une boîte pour un conditionnement : nom, facteur, code-barres du pack.
class _PackagingDialog extends StatefulWidget {
  const _PackagingDialog();

  @override
  State<_PackagingDialog> createState() => _PackagingDialogState();
}

class _PackagingDialogState extends State<_PackagingDialog> {
  final _name = TextEditingController(text: 'Carton');
  final _factor = TextEditingController();
  final _barcode = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _factor.dispose();
    _barcode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      title: Text('Conditionnement', style: T.h2),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              style: T.body,
              decoration:
                  const InputDecoration(labelText: 'Nom (Carton, Boîte…)')),
          const SizedBox(height: 8),
          TextField(
              controller: _factor,
              style: T.monoBody,
              decoration: const InputDecoration(
                  labelText: 'Unités de base par pack (ex : 24)')),
          const SizedBox(height: 8),
          TextField(
              controller: _barcode,
              style: T.monoBody,
              decoration: const InputDecoration(
                  labelText: 'Code-barres du pack (optionnel)')),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler')),
        PrimaryButton(
            label: 'Ajouter',
            onPressed: () {
              final f = parseQty(_factor.text) ?? 0;
              if (_name.text.trim().isEmpty || f <= 0) return;
              Navigator.pop(
                  context,
                  Packaging(
                      name: _name.text.trim(),
                      factorMilli: f,
                      barcode: _barcode.text.trim().isEmpty
                          ? null
                          : _barcode.text.trim()));
            }),
      ],
    );
  }
}

/// Import CSV avec correspondance de colonnes et aperçu (spec §4.6, voie 3).
/// Les produits avec quantité créent leur document « Stock initial ».
class _ImportCsvDialog extends StatefulWidget {
  const _ImportCsvDialog({required this.api});
  final ApiClient api;

  @override
  State<_ImportCsvDialog> createState() => _ImportCsvDialogState();
}

class _ImportCsvDialogState extends State<_ImportCsvDialog> {
  List<List<String>> _rows = const [];
  String? _path;
  // mapping: champ -> index de colonne (-1 = ignoré)
  final Map<String, int> _map = {
    'designation': -1,
    'barcode': -1,
    'achat': -1,
    'vente': -1,
    'quantite': -1,
    'marque': -1,
    'tva': -1,
  };
  static const _labels = {
    'designation': 'Désignation *',
    'barcode': 'Code-barres',
    'achat': "Prix d'achat HT",
    'vente': 'Prix de vente TTC',
    'quantite': 'Quantité (stock initial)',
    'marque': 'Marque',
    'tva': 'TVA (%)',
  };
  bool _hasHeader = true;
  bool _busy = false;
  int _done = 0;
  final List<String> _errors = [];

  Future<void> _pick() async {
    final path = pickFile('Fichiers CSV', '*.csv;*.txt');
    if (path == null) return;
    try {
      final raw = await File(path).readAsBytes();
      String text;
      try {
        text = utf8.decode(raw);
      } catch (_) {
        text = latin1.decode(raw);
      }
      final sep = text.contains(';') ? ';' : ',';
      final rows = [
        for (final line in text.split(RegExp(r'\r?\n')))
          if (line.trim().isNotEmpty)
            [for (final c in line.split(sep)) c.trim()]
      ];
      setState(() {
        _path = path;
        _rows = rows;
      });
      // Auto-mapping par en-tête.
      if (rows.isNotEmpty) {
        final h = [for (final c in rows.first) c.toLowerCase()];
        void auto(String key, List<String> hints) {
          for (var i = 0; i < h.length; i++) {
            if (hints.any((x) => h[i].contains(x))) {
              _map[key] = i;
              return;
            }
          }
        }

        auto('designation', ['design', 'nom', 'produit', 'libel']);
        auto('barcode', ['code', 'barre', 'ean']);
        auto('achat', ['achat', 'cout', 'coût']);
        auto('vente', ['vente', 'prix', 'ttc']);
        auto('quantite', ['quant', 'qte', 'qté', 'stock']);
        auto('marque', ['marque', 'brand']);
        auto('tva', ['tva']);
        setState(() {});
      }
    } catch (e) {
      setState(() => _errors.add('Lecture impossible : $e'));
    }
  }

  List<List<String>> get _dataRows =>
      _hasHeader && _rows.isNotEmpty ? _rows.sublist(1) : _rows;

  String _cell(List<String> row, String key) {
    final i = _map[key] ?? -1;
    if (i < 0 || i >= row.length) return '';
    return row[i];
  }

  Future<void> _import() async {
    if (_map['designation'] == -1) {
      setState(() => _errors.add('Choisissez la colonne Désignation.'));
      return;
    }
    setState(() {
      _busy = true;
      _errors.clear();
      _done = 0;
    });
    for (final row in _dataRows) {
      final name = _cell(row, 'designation');
      if (name.isEmpty) continue;
      try {
        final qty = parseQty(_cell(row, 'quantite')) ?? 0;
        final achat = parseDA(_cell(row, 'achat')) ?? 0;
        final tvaRaw = _cell(row, 'tva').replaceAll('%', '').trim();
        final tva = ((double.tryParse(tvaRaw.replaceAll(',', '.')) ?? 19) * 100)
            .round();
        await widget.api.saveProduct({
          'name': name,
          'barcode':
              _cell(row, 'barcode').isEmpty ? null : _cell(row, 'barcode'),
          'vat_rate': tva,
          'purchase_price': achat,
          'price_retail': parseDA(_cell(row, 'vente')) ?? 0,
          'min_stock_milli': 0,
          'is_weighable': false,
          'unit': 'piece',
          'track_lots': false,
          'track_serials': false,
          'warranty_months': 0,
          'description': '',
          'brand': _cell(row, 'marque'),
          'track_expiry': false,
          if (qty > 0 && achat > 0) 'initial_qty_milli': qty,
        });
        _done++;
        if (mounted && _done % 10 == 0) setState(() {});
      } on ApiException catch (e) {
        _errors.add('$name : ${e.message}');
      } catch (e) {
        _errors.add('$name : $e');
      }
    }
    if (mounted) {
      setState(() => _busy = false);
      if (_errors.isEmpty) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 640,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Importer des produits (CSV)', style: T.h2),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(
                  onPressed: _pick,
                  child: Text(_path == null
                      ? 'Choisir un fichier…'
                      : _path!.split('\\').last)),
              const SizedBox(width: 12),
              if (_rows.isNotEmpty)
                InkWell(
                  onTap: () => setState(() => _hasHeader = !_hasHeader),
                  child: Row(children: [
                    Icon(
                        _hasHeader
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 16,
                        color: _hasHeader ? T.mintDeep : T.faint),
                    const SizedBox(width: 6),
                    Text('1re ligne = en-têtes', style: T.small),
                  ]),
                ),
              const Spacer(),
              if (_rows.isNotEmpty)
                Text('${_dataRows.length} lignes', style: T.small),
            ]),
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: 10),
              const MicroLabel('CORRESPONDANCE DES COLONNES'),
              const SizedBox(height: 6),
              Wrap(spacing: 10, runSpacing: 6, children: [
                for (final key in _map.keys)
                  SizedBox(
                    width: 190,
                    child: Row(children: [
                      Expanded(
                          child: Text(_labels[key]!,
                              style: T.small, overflow: TextOverflow.ellipsis)),
                      DropdownButton<int>(
                        value: _map[key],
                        style: T.monoSmall.copyWith(color: T.ink),
                        items: [
                          const DropdownMenuItem(value: -1, child: Text('—')),
                          for (var i = 0; i < _rows.first.length; i++)
                            DropdownMenuItem(
                                value: i,
                                child: Text(_hasHeader
                                    ? _rows.first[i]
                                    : 'Col ${i + 1}')),
                        ],
                        onChanged: (v) =>
                            setState(() => _map[key] = v ?? -1),
                      ),
                    ]),
                  ),
              ]),
              const SizedBox(height: 10),
              const MicroLabel('APERÇU'),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(children: [
                  for (final row in _dataRows.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                          '${_cell(row, 'designation')}  ·  ${_cell(row, 'barcode')}  ·  achat ${_cell(row, 'achat')}  ·  vente ${_cell(row, 'vente')}  ·  qté ${_cell(row, 'quantite')}',
                          style: T.monoSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                ]),
              ),
            ] else
              const Expanded(
                  child: EmptyState(
                      icon: Icons.upload_file_outlined,
                      text:
                          'Choisissez un fichier CSV (séparateur ; ou ,).\nColonnes libres — vous les associez ensuite.')),
            if (_errors.isNotEmpty)
              SizedBox(
                height: 60,
                child: ListView(children: [
                  for (final e in _errors)
                    Text(e,
                        style: T.small.copyWith(color: T.dangerDark),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              if (_busy || _done > 0)
                Text('$_done importés…', style: T.small),
              const Spacer(),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(_done > 0),
                  child: const Text('Fermer')),
              const SizedBox(width: 8),
              SizedBox(
                width: 150,
                child: PrimaryButton(
                    label: _busy ? '…' : 'Importer',
                    onPressed: _busy || _rows.isEmpty ? null : _import),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
