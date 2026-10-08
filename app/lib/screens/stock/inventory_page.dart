import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// What the inventory page did, for the Stock screen toast.
class InventoryOutcome {
  const InventoryOutcome.posted(DocDetail this.doc)
      : saved = false,
        resumeId = null;
  const InventoryOutcome.saved(DocDetail this.doc)
      : saved = true,
        resumeId = null;
  const InventoryOutcome.resume(String this.resumeId)
      : doc = null,
        saved = false;
  final DocDetail? doc;
  final bool saved;
  final String? resumeId; // switch to another saved session
}

/// Opens the full-page physical inventory. [resumeId] = a saved session.
/// Returns the posted or saved document (null = left without saving).
Future<InventoryOutcome?> openInventoryPage(
  BuildContext context, {
  required ApiClient api,
  required List<Warehouse> warehouses,
  required bool viewCost,
  String? warehouseId,
  String? resumeId,
}) async {
  var resume = resumeId;
  while (true) {
    final out = await Navigator.of(context).push<InventoryOutcome>(MaterialPageRoute(
      builder: (_) => InventoryPage(
        api: api,
        warehouses: warehouses,
        viewCost: viewCost,
        initialWarehouseId: warehouseId,
        resumeId: resume,
      ),
    ));
    if (out?.resumeId == null || !context.mounted) return out;
    resume = out!.resumeId;
  }
}

/// Inventaire physique : scope (dépôt + catégorie + marque, ou tout le
/// catalogue), saisie ou scan des quantités comptées (vide = non compté, ne
/// bouge pas), sessions enregistrées en brouillon, rapport d'écarts avant
/// validation. Each counted line carries `expected_milli` = the stock shown
/// when it was counted: the server applies counted − expected on top of the
/// CURRENT level, so sales made meanwhile are not wiped out.
class InventoryPage extends StatefulWidget {
  const InventoryPage({
    super.key,
    required this.api,
    required this.warehouses,
    required this.viewCost,
    this.initialWarehouseId,
    this.resumeId,
  });

  final ApiClient api;
  final List<Warehouse> warehouses;
  final bool viewCost;
  final String? initialWarehouseId;
  final String? resumeId;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

enum _Show { all, uncounted, counted, diff }

class _InventoryPageState extends State<InventoryPage> {
  static const _p = 'stock_inventory';

  late String? _warehouseId = widget.initialWarehouseId ??
      UiPrefs.instance.get<String>(_p, 'warehouse') ??
      _defaultWarehouse();
  bool _allProducts = UiPrefs.instance.get<bool>(_p, 'all') ?? true;
  String? _category = UiPrefs.instance.get<String>(_p, 'category');
  String? _brand = UiPrefs.instance.get<String>(_p, 'brand');
  _Show _show = _Show.all;

  final _search = TextEditingController();
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();

  List<Product> _products = const [];
  List<Category> _categories = const [];
  Map<String, StockLevel> _levels = const {};
  Map<String, Product> _byCode = const {};
  Map<String, int> _packByCode = const {};
  bool _loading = true;
  String? _error;

  /// productId → counted quantity (milli). Absent = not counted.
  final Map<String, int> _counted = {};

  /// productId → theoretical stock shown when the line was counted.
  final Map<String, int> _expected = {};
  final Map<String, TextEditingController> _ctrls = {};
  final Set<String> _invalid = {};
  final Set<String> _scanned = {}; // shown even outside the scope

  String? _draftId;
  String? _draftDate;
  bool _dirty = false;
  bool _busy = false;
  String? _scanMsg;
  bool _scanOk = true;
  List<StockDoc> _openDrafts = const [];

  String? _defaultWarehouse() {
    for (final w in widget.warehouses) {
      if (w.isDefault) return w.id;
    }
    return widget.warehouses.isEmpty ? null : widget.warehouses.first.id;
  }

  @override
  void initState() {
    super.initState();
    if (!widget.warehouses.any((w) => w.id == _warehouseId)) {
      _warehouseId = _defaultWarehouse();
    }
    _init();
  }

  @override
  void dispose() {
    _search.dispose();
    _scan.dispose();
    _scanFocus.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      InvDraft? draft;
      if (widget.resumeId != null) {
        draft = await widget.api.inventoryDraft(widget.resumeId!);
        if (draft.warehouseId != null) _warehouseId = draft.warehouseId;
      }
      final results = await Future.wait([
        widget.api.allProducts(),
        widget.api.categories(),
        _fetchLevels(),
        widget.api.stockDocuments(types: const ['INVENTORY_COUNT'], status: 'draft'),
      ]);
      if (!mounted) return;
      final products = [
        for (final p in results[0] as List<Product>)
          if (p.active && !p.isService) p
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final byCode = <String, Product>{};
      final packByCode = <String, int>{};
      for (final p in products) {
        if (p.barcode != null && p.barcode!.isNotEmpty) byCode[p.barcode!] = p;
        for (final b in p.barcodes) {
          byCode[b] = p;
        }
        for (final pk in p.packagings) {
          if (pk.barcode != null && pk.barcode!.isNotEmpty) {
            byCode[pk.barcode!] = p;
            packByCode[pk.barcode!] = pk.factorMilli;
          }
        }
      }
      setState(() {
        _products = products;
        _byCode = byCode;
        _packByCode = packByCode;
        _categories = results[1] as List<Category>;
        _levels = results[2] as Map<String, StockLevel>;
        _openDrafts = [
          for (final d in results[3] as List<StockDoc>)
            if (d.id != widget.resumeId) d
        ];
        if (draft != null) {
          _draftId = draft.id;
          _draftDate = draft.docDate;
          for (final l in draft.lines) {
            _counted[l.productId] = l.qtyMilli;
            _expected[l.productId] = l.expectedMilli ?? _stockOf(l.productId);
            _scanned.add(l.productId);
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Chargement impossible : $e';
          _loading = false;
        });
      }
    }
  }

  Future<Map<String, StockLevel>> _fetchLevels() async {
    if (_warehouseId == null) return const {};
    final levels = await widget.api.stockLevels(warehouseId: _warehouseId, full: true);
    return {for (final l in levels) l.productId: l};
  }

  int _stockOf(String pid) => _levels[pid]?.qtyMilli ?? 0;
  int _theo(String pid) => _expected[pid] ?? _stockOf(pid);
  int _cost(String pid) => _levels[pid]?.avgCost ?? 0;

  Future<void> _changeWarehouse(String? id) async {
    if (id == null || id == _warehouseId) return;
    if (_counted.isNotEmpty) {
      final ok = await confirmAction(context,
          title: 'Changer de dépôt ?',
          message:
              'Les ${_counted.length} quantité(s) déjà comptée(s) concernent le dépôt actuel. '
              'Elles seront effacées.',
          confirmLabel: 'Changer et effacer',
          danger: true);
      if (!ok) return;
    }
    setState(() {
      _warehouseId = id;
      _counted.clear();
      _expected.clear();
      _invalid.clear();
      _scanned.clear();
      for (final c in _ctrls.values) {
        c.clear();
      }
      _levels = const {};
      _loading = true;
    });
    UiPrefs.instance.set(_p, 'warehouse', id);
    try {
      final lv = await _fetchLevels();
      if (mounted) {
        setState(() {
          _levels = lv;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Stock du dépôt indisponible : $e';
          _loading = false;
        });
      }
    }
  }

  void _saveScope() {
    UiPrefs.instance.set(_p, 'all', _allProducts);
    UiPrefs.instance.set(_p, 'category', _category);
    UiPrefs.instance.set(_p, 'brand', _brand);
  }

  bool _inScope(Product p) {
    if (_scanned.contains(p.id) || _counted.containsKey(p.id)) return true;
    if (_allProducts) return true;
    if (_category != null && p.categoryId != _category) return false;
    if (_brand != null && p.brand != _brand) return false;
    return _category != null || _brand != null;
  }

  List<Product> get _scope => [for (final p in _products) if (_inScope(p)) p];

  List<Product> get _shown {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final p in _scope)
        if ((q.isEmpty ||
                p.name.toLowerCase().contains(q) ||
                (p.barcode ?? '').contains(q)) &&
            switch (_show) {
              _Show.all => true,
              _Show.uncounted => !_counted.containsKey(p.id),
              _Show.counted => _counted.containsKey(p.id),
              _Show.diff => _counted.containsKey(p.id) && _counted[p.id] != _theo(p.id),
            })
          p
    ];
  }

  TextEditingController _ctrl(String pid) => _ctrls.putIfAbsent(
      pid,
      () => TextEditingController(
          text: _counted.containsKey(pid) ? fmtQty(_counted[pid]!) : ''));

  void _onCountChanged(String pid, String txt) {
    final t = txt.trim();
    setState(() {
      _dirty = true;
      if (t.isEmpty) {
        _counted.remove(pid);
        _expected.remove(pid);
        _invalid.remove(pid);
        return;
      }
      final v = parseQty(t);
      if (v == null || v < 0) {
        _invalid.add(pid);
        _counted.remove(pid);
        return;
      }
      _invalid.remove(pid);
      _expected.putIfAbsent(pid, () => _stockOf(pid));
      _counted[pid] = v;
    });
  }

  /// Each scan adds one unit — or the pack factor for a packaging barcode.
  void _onScan(String raw) {
    final code = raw.trim();
    _scan.clear();
    _scanFocus.requestFocus();
    if (code.isEmpty) return;
    final p = _byCode[code];
    if (p == null) {
      SystemSound.play(SystemSoundType.alert);
      setState(() {
        _scanOk = false;
        _scanMsg = 'Code « $code » inconnu.';
      });
      return;
    }
    final add = _packByCode[code] ?? 1000;
    SystemSound.play(SystemSoundType.click);
    setState(() {
      _dirty = true;
      _scanned.add(p.id);
      _expected.putIfAbsent(p.id, () => _stockOf(p.id));
      final v = (_counted[p.id] ?? 0) + add;
      _counted[p.id] = v;
      _invalid.remove(p.id);
      _ctrls[p.id]?.text = fmtQty(v);
      _scanOk = true;
      _scanMsg = '${p.name} : +${fmtQty(add)} → ${fmtQty(v)} compté(s)';
    });
  }

  Map<String, dynamic> _payload() {
    final names = {for (final p in _products) p.id: p.name};
    final ids = _counted.keys.toList()
      ..sort((a, b) => (names[a] ?? '').compareTo(names[b] ?? ''));
    final cat = _categories.where((c) => c.id == _category).map((c) => c.name).firstOrNull;
    final scope = _allProducts
        ? 'tous les produits'
        : [if (cat != null) 'catégorie $cat', if (_brand != null) 'marque $_brand'].join(', ');
    return {
      'doc_type': 'INVENTORY_COUNT',
      'doc_date': todayISO(),
      'warehouse_id': _warehouseId,
      'notes': 'Inventaire — $scope',
      'lines': [
        for (var i = 0; i < ids.length; i++)
          {
            'product_id': ids[i],
            'description': names[ids[i]] ?? '',
            'qty_milli': _counted[ids[i]],
            'expected_milli': _theo(ids[i]),
            'unit_price': 0,
            'vat_rate': 0,
            'discount_pct': 0,
            'position': i,
          }
      ],
    };
  }

  Future<DocDetail> _persist() async {
    final body = _payload();
    if (_draftId == null) {
      final d = await widget.api.createDraft(body);
      _draftId = d.id;
      _draftDate = d.docDate;
      return d;
    }
    return widget.api.updateDraft(_draftId!, body);
  }

  bool _checkInput() {
    if (_warehouseId == null) {
      showToast(context, 'Choisissez le dépôt inventorié.', kind: ToastKind.warning);
      return false;
    }
    if (_invalid.isNotEmpty) {
      setState(() => _show = _Show.all);
      showToast(context, '${_invalid.length} quantité(s) invalide(s) — corrigez les champs en rouge.',
          kind: ToastKind.warning);
      return false;
    }
    if (_counted.isEmpty) {
      showToast(context, 'Aucune quantité comptée : saisissez ou scannez les produits comptés.',
          kind: ToastKind.warning);
      return false;
    }
    return true;
  }

  Future<void> _saveForLater() async {
    if (_busy || !_checkInput()) return;
    setState(() => _busy = true);
    try {
      final d = await _persist();
      _dirty = false;
      if (mounted) Navigator.of(context).pop(InventoryOutcome.saved(d));
    } on ApiException catch (e) {
      if (mounted) showToast(context, 'Enregistrement impossible : ${e.message}', kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Enregistrement impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _validate() async {
    if (_busy || !_checkInput()) return;
    final names = {for (final p in _products) p.id: p.name};
    final diffs = [
      for (final e in _counted.entries)
        if (e.value != _theo(e.key))
          (
            id: e.key,
            name: names[e.key] ?? '',
            theo: _theo(e.key),
            counted: e.value,
            diff: e.value - _theo(e.key),
            value: ((e.value - _theo(e.key)) * _cost(e.key)) ~/ 1000,
          )
    ]..sort((a, b) => a.value.abs() == b.value.abs()
        ? a.name.compareTo(b.name)
        : b.value.abs().compareTo(a.value.abs()));
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DiffReport(
        counted: _counted.length,
        diffs: diffs,
        viewCost: widget.viewCost,
        warehouse: widget.warehouses.firstWhere((w) => w.id == _warehouseId).name,
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final d = await _persist();
      final posted = await widget.api.postDocument(d.id);
      _dirty = false;
      if (mounted) Navigator.of(context).pop(InventoryOutcome.posted(posted));
    } on ApiException catch (e) {
      if (mounted) {
        showToast(context, 'Validation impossible : ${e.message}', kind: ToastKind.error);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Validation impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discardDraft(StockDoc d) async {
    final ok = await confirmAction(context,
        title: 'Abandonner cet inventaire ?',
        message:
            'Session du ${frDate(d.docDate)} (${d.lineCount} ligne(s) comptée(s)) : elle sera annulée, le stock ne change pas.',
        confirmLabel: 'Abandonner',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await widget.api.cancelDocument(d.id);
      if (mounted) setState(() => _openDrafts = [for (final x in _openDrafts) if (x.id != d.id) x]);
    } on ApiException catch (e) {
      if (mounted) showToast(context, 'Abandon impossible : ${e.message}', kind: ToastKind.error);
    }
  }

  Future<void> _resume(StockDoc d) async {
    if (_dirty && _counted.isNotEmpty) {
      final ok = await confirmAction(context,
          title: 'Reprendre une autre session ?',
          message: 'Les quantités saisies ici et non enregistrées seront perdues.',
          confirmLabel: 'Reprendre',
          danger: true);
      if (!ok || !mounted) return;
    }
    _dirty = false;
    Navigator.of(context).pop(InventoryOutcome.resume(d.id));
  }

  Future<void> _close() async {
    if (_dirty && _counted.isNotEmpty) {
      final ok = await confirmAction(context,
          title: 'Quitter sans enregistrer ?',
          message:
              '${_counted.length} quantité(s) comptée(s) seront perdues. « Enregistrer pour plus tard » les garde.',
          confirmLabel: 'Quitter',
          danger: true);
      if (!ok || !mounted) return;
    }
    _dirty = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    final shown = _shown;
    final countedInScope = scope.where((p) => _counted.containsKey(p.id)).length;
    final diffCount =
        _counted.entries.where((e) => e.value != _theo(e.key)).length;
    final brands = {for (final p in _products) if (p.brand.isNotEmpty) p.brand}.toList()..sort();
    final whName = widget.warehouses
        .where((w) => w.id == _warehouseId)
        .map((w) => w.name)
        .firstOrNull;

    return PopScope(
      canPop: !(_dirty && _counted.isNotEmpty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveForLater,
        },
        child: Scaffold(
          backgroundColor: T.bg,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                IconButton(
                  tooltip: 'Retour (Échap)',
                  onPressed: _close,
                  icon: const Icon(Icons.arrow_back_rounded, color: T.ink),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: PageHeader(
                    title: 'Inventaire physique',
                    subtitle: whName == null && _draftId == null
                        ? null
                        : [
                            ?whName,
                            if (_draftId != null)
                              'session enregistrée${_draftDate == null ? '' : ' le ${frDate(_draftDate!)}'}',
                          ].join(' · '),
                    primaryLabel: _busy ? 'Validation…' : 'Vérifier et valider',
                    primaryIcon: Icons.fact_check_outlined,
                    onPrimary: _busy || _loading ? null : _validate,
                    trailing: [
                      Tooltip(
                        message: 'Ctrl+S',
                        child: SizedBox(
                          height: 40,
                          child: OutlinedButton.icon(
                            onPressed: _busy || _loading ? null : _saveForLater,
                            icon: const Icon(Icons.save_outlined, size: 16),
                            label: const Text('Enregistrer pour plus tard'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (_openDrafts.isNotEmpty && _draftId == null) ...[
                _OpenDrafts(drafts: _openDrafts, onResume: _resume, onDiscard: _discardDraft),
                const SizedBox(height: 12),
              ],
              Card14(
                child: Wrap(spacing: 14, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.end, children: [
                  SizedBox(
                    width: 210,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const MicroLabel('Dépôt inventorié'),
                      const SizedBox(height: 5),
                      DepotDropdown(
                        warehouses: widget.warehouses,
                        value: _warehouseId,
                        allowAll: false,
                        onChanged: _changeWarehouse,
                      ),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const MicroLabel('Périmètre'),
                    const SizedBox(height: 5),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      FilterPill(
                        label: 'Tous les produits',
                        active: _allProducts,
                        onTap: () {
                          setState(() => _allProducts = true);
                          _saveScope();
                        },
                      ),
                      FilterPill(
                        label: 'Par catégorie / marque',
                        active: !_allProducts,
                        onTap: () {
                          setState(() => _allProducts = false);
                          _saveScope();
                        },
                      ),
                    ]),
                  ]),
                  if (!_allProducts) ...[
                    FilterField<String>(
                      label: 'Catégorie',
                      value: _categories.any((c) => c.id == _category) ? _category : null,
                      allLabel: 'Toutes',
                      options: [for (final c in _categories) (c.id, c.name)],
                      onChanged: (v) {
                        setState(() => _category = v);
                        _saveScope();
                      },
                    ),
                    FilterField<String>(
                      label: 'Marque',
                      value: brands.contains(_brand) ? _brand : null,
                      allLabel: 'Toutes',
                      options: [for (final b in brands) (b, b)],
                      onChanged: (v) {
                        setState(() => _brand = v);
                        _saveScope();
                      },
                    ),
                  ],
                  SizedBox(
                    width: 300,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const MicroLabel('Scanner pour compter'),
                      const SizedBox(height: 5),
                      SizedBox(
                        height: 38,
                        child: TextField(
                          controller: _scan,
                          focusNode: _scanFocus,
                          autofocus: true,
                          onSubmitted: _onScan,
                          style: T.monoBody,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Code-barres (produit ou carton)',
                            hintStyle: T.small.copyWith(color: T.ghost),
                            prefixIcon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                            filled: true,
                            fillColor: T.surface,
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(T.rInner),
                                borderSide: const BorderSide(color: T.border)),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(T.rInner),
                                borderSide: const BorderSide(color: T.border)),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ]),
              ),
              if (_scanMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Row(children: [
                    Icon(_scanOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                        size: 14, color: _scanOk ? T.mintDark : T.dangerDark),
                    const SizedBox(width: 6),
                    Text(_scanMsg!,
                        style: T.small.copyWith(color: _scanOk ? T.mintDark : T.dangerDark)),
                  ]),
                ),
              const SizedBox(height: 12),
              ListToolbar(
                search: _search,
                searchHint: 'Filtrer la liste…',
                onSearchChanged: (_) => setState(() {}),
                quickFilters: [
                  FilterPill(
                      label: 'Tous',
                      active: _show == _Show.all,
                      count: scope.length,
                      onTap: () => setState(() => _show = _Show.all)),
                  FilterPill(
                      label: 'Non comptés',
                      active: _show == _Show.uncounted,
                      count: scope.length - countedInScope,
                      onTap: () => setState(() => _show = _Show.uncounted)),
                  FilterPill(
                      label: 'Comptés',
                      active: _show == _Show.counted,
                      count: _counted.length,
                      onTap: () => setState(() => _show = _Show.counted)),
                  FilterPill(
                      label: 'Écarts',
                      icon: Icons.difference_outlined,
                      active: _show == _Show.diff,
                      count: diffCount,
                      onTap: () => setState(() => _show = _Show.diff)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                  'Saisissez la quantité réellement comptée — une ligne laissée vide ne bouge pas. '
                  'Le stock théorique est figé au moment où la ligne est comptée.',
                  style: T.small.copyWith(fontSize: 11.5)),
              const SizedBox(height: 8),
              Expanded(child: _buildList(shown)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<Product> shown) {
    if (_loading && _products.isEmpty) {
      return Card14(
        child: ListView(children: [
          for (var i = 0; i < 8; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: SkeletonBar(width: 320, height: 10),
            ),
        ]),
      );
    }
    if (_error != null) {
      return Card14(
          child: EmptyState(
              icon: Icons.cloud_off_rounded,
              text: _error!,
              actions: [('Réessayer', _init)]));
    }
    if (shown.isEmpty) {
      return Card14(
        child: EmptyState(
          icon: Icons.inventory_2_outlined,
          text: !_allProducts && _category == null && _brand == null
              ? 'Choisissez une catégorie ou une marque, ou inventoriez tous les produits.'
              : 'Aucun produit dans cette vue.',
          actions: [
            if (_show != _Show.all || _search.text.isNotEmpty)
              ('Tout afficher', () {
                setState(() {
                  _show = _Show.all;
                  _search.clear();
                });
              }),
            if (!_allProducts)
              ('Tous les produits', () {
                setState(() => _allProducts = true);
                _saveScope();
              }),
          ],
        ),
      );
    }
    return Card14(
      padding: EdgeInsets.zero,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(children: [
            const Expanded(child: MicroLabel('Produit')),
            const SizedBox(width: 130, child: MicroLabel('Code-barres')),
            const SizedBox(
                width: 100,
                child: Align(alignment: AlignmentDirectional.centerEnd, child: MicroLabel('Théorique'))),
            const SizedBox(width: 16),
            const SizedBox(width: 110, child: Center(child: MicroLabel('Compté'))),
            const SizedBox(
                width: 90,
                child: Align(alignment: AlignmentDirectional.centerEnd, child: MicroLabel('Écart'))),
          ]),
        ),
        const Divider(),
        Expanded(
          child: ListView.separated(
            itemCount: shown.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, i) {
              final p = shown[i];
              final counted = _counted[p.id];
              final theo = _theo(p.id);
              final diff = counted == null ? null : counted - theo;
              final bad = _invalid.contains(p.id);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Text(p.name,
                        style: T.body.copyWith(fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                      width: 130,
                      child: Text(p.barcode ?? '—',
                          style: T.monoSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    width: 100,
                    child: Text(qtyUnit(theo, p.unit),
                        textAlign: TextAlign.end, style: T.monoBody.copyWith(color: T.muted)),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 110,
                    height: 32,
                    child: TextField(
                      controller: _ctrl(p.id),
                      textAlign: TextAlign.center,
                      textInputAction: TextInputAction.next,
                      style: T.monoBody.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
                      onChanged: (v) => _onCountChanged(p.id, v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'compté',
                        hintStyle: T.small.copyWith(color: T.ghost, fontSize: 11),
                        filled: true,
                        fillColor: counted != null ? T.mintTint : T.bg,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: bad ? T.danger : T.border)),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: bad ? T.danger : T.border)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      bad
                          ? 'invalide'
                          : diff == null
                              ? ''
                              : diff == 0
                                  ? '='
                                  : '${diff > 0 ? '+' : '−'}${fmtQty(diff.abs())}',
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          fontWeight: FontWeight.w700,
                          color: bad || (diff ?? 0) < 0
                              ? T.dangerDark
                              : (diff ?? 0) > 0
                                  ? T.mintDark
                                  : T.faint),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            MicroLabel('${_counted.length} produit(s) compté(s)'),
            const SizedBox(width: 18),
            MicroLabel('${_counted.entries.where((e) => e.value != _theo(e.key)).length} écart(s)'),
            const Spacer(),
            if (widget.viewCost)
              Text(
                'Écart en valeur : ${fmtDA(_counted.entries.fold<int>(0, (s, e) => s + ((e.value - _theo(e.key)) * _cost(e.key)) ~/ 1000))}',
                style: T.monoBody.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _OpenDrafts extends StatelessWidget {
  const _OpenDrafts({required this.drafts, required this.onResume, required this.onDiscard});
  final List<StockDoc> drafts;
  final void Function(StockDoc) onResume;
  final void Function(StockDoc) onDiscard;

  @override
  Widget build(BuildContext context) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history_rounded, size: 16, color: T.warnDark),
          const SizedBox(width: 8),
          Text('Inventaires en cours (${drafts.length})',
              style: T.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('— reprenez une session enregistrée ou commencez-en une nouvelle ci-dessous.',
              style: T.small),
        ]),
        const SizedBox(height: 6),
        for (final d in drafts.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 95, child: Text(frDate(d.docDate), style: T.monoSmall)),
              SizedBox(
                  width: 160,
                  child: Text(d.warehouseName ?? '—',
                      style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Expanded(
                  child: Text('${d.lineCount} ligne(s) comptée(s) · ${d.notes ?? ''}',
                      style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
              TextButton(onPressed: () => onResume(d), child: const Text('Reprendre')),
              IconButton(
                tooltip: 'Abandonner cette session',
                onPressed: () => onDiscard(d),
                icon: const Icon(Icons.delete_outline_rounded, size: 17, color: T.muted),
              ),
            ]),
          ),
      ]),
    );
  }
}

typedef _Diff = ({String id, String name, int theo, int counted, int diff, int value});

/// Rapport d'écarts shown before posting.
class _DiffReport extends StatelessWidget {
  const _DiffReport({
    required this.counted,
    required this.diffs,
    required this.viewCost,
    required this.warehouse,
  });
  final int counted;
  final List<_Diff> diffs;
  final bool viewCost;
  final String warehouse;

  @override
  Widget build(BuildContext context) {
    final total = diffs.fold<int>(0, (s, d) => s + d.value);
    final plus = diffs.where((d) => d.diff > 0).fold<int>(0, (s, d) => s + d.value);
    final minus = diffs.where((d) => d.diff < 0).fold<int>(0, (s, d) => s + d.value);
    Widget head(String t, double w, {bool end = false}) => SizedBox(
        width: w,
        child: Align(
            alignment: end ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            child: MicroLabel(t)));
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 760,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Rapport d’écarts', style: T.h2)),
              IconButton(
                tooltip: 'Fermer (Échap)',
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close, size: 18, color: T.muted),
              ),
            ]),
            Text(
                '$warehouse — $counted produit(s) compté(s), ${diffs.length} écart(s). '
                'Seuls les écarts ajusteront le stock ; les produits non comptés ne bougent pas.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: MicroLabel('Produit')),
              head('Théorique', 90, end: true),
              head('Compté', 90, end: true),
              head('Écart', 90, end: true),
              if (viewCost) head('Écart en valeur', 130, end: true),
            ]),
            const Divider(),
            Expanded(
              child: diffs.isEmpty
                  ? const EmptyState(
                      icon: Icons.verified_outlined,
                      text: 'Aucun écart : le stock compté correspond au stock théorique.')
                  : ListView.separated(
                      itemCount: diffs.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, i) {
                        final d = diffs[i];
                        final c = d.diff < 0 ? T.dangerDark : T.mintDark;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            Expanded(
                                child: Text(d.name,
                                    style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            SizedBox(
                                width: 90,
                                child: Text(fmtQty(d.theo),
                                    textAlign: TextAlign.end, style: T.monoBody)),
                            SizedBox(
                                width: 90,
                                child: Text(fmtQty(d.counted),
                                    textAlign: TextAlign.end, style: T.monoBody)),
                            SizedBox(
                                width: 90,
                                child: Text('${d.diff > 0 ? '+' : '−'}${fmtQty(d.diff.abs())}',
                                    textAlign: TextAlign.end,
                                    style: T.monoBody
                                        .copyWith(color: c, fontWeight: FontWeight.w700))),
                            if (viewCost)
                              SizedBox(
                                  width: 130,
                                  child: Text(fmtDA(d.value),
                                      textAlign: TextAlign.end,
                                      style: T.monoBody.copyWith(color: c))),
                          ]),
                        );
                      },
                    ),
            ),
            const Divider(),
            if (viewCost)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Text('Surplus ${fmtDA(plus)}', style: T.small.copyWith(color: T.mintDark)),
                  const SizedBox(width: 16),
                  Text('Manquants ${fmtDA(minus)}', style: T.small.copyWith(color: T.dangerDark)),
                  const Spacer(),
                  Text('Total : ${fmtDA(total)}',
                      style: T.monoBody.copyWith(
                          fontWeight: FontWeight.w800,
                          color: total < 0 ? T.dangerDark : T.ink)),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Revenir au comptage'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                autofocus: true,
                style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(diffs.isEmpty ? 'Valider l’inventaire' : 'Valider et ajuster le stock'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
