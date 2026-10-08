import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/gs1.dart';
import 'ui.dart';

/// Configuration of the DocumentEditor archetype for one document type.
class DocEditorConfig {
  const DocEditorConfig({
    required this.docType,
    required this.title,
    this.partnerKind,
    this.partnerRequired = false,
    this.needsWarehouse = true,
    this.isPurchase = false,
    this.hasPaymentMethod = false,
  });

  final String docType;
  final String title;
  final String? partnerKind; // 'customer' | 'supplier' | null
  final bool partnerRequired;
  final bool needsWarehouse;
  final bool isPurchase; // prices are costs, default = purchase_price
  final bool hasPaymentMethod;

  bool get isReception => docType == 'PURCHASE_RECEIPT';
  bool get isSupplierInvoice => docType == 'PURCHASE_INVOICE';
}

const saleInvoiceConfig = DocEditorConfig(
    docType: 'SALE_INVOICE',
    title: 'Facture de vente',
    partnerKind: 'customer',
    hasPaymentMethod: true);
const quoteConfig = DocEditorConfig(
    docType: 'QUOTE',
    title: 'Devis',
    partnerKind: 'customer',
    needsWarehouse: false);
const deliveryNoteConfig = DocEditorConfig(
    docType: 'DELIVERY_NOTE',
    title: 'Bon de livraison',
    partnerKind: 'customer');
const saleCreditNoteConfig = DocEditorConfig(
    docType: 'SALE_CREDIT_NOTE',
    title: 'Avoir client',
    partnerKind: 'customer');
const purchaseOrderConfig = DocEditorConfig(
    docType: 'PURCHASE_ORDER',
    title: 'Bon de commande',
    partnerKind: 'supplier',
    partnerRequired: true,
    needsWarehouse: false,
    isPurchase: true);
// Le fournisseur est obligatoire à la validation d'une réception : sans lui,
// pas d'historique d'achat, pas de comparaison de prix, pas de compte.
const purchaseReceiptConfig = DocEditorConfig(
    docType: 'PURCHASE_RECEIPT',
    title: 'Réception fournisseur',
    partnerKind: 'supplier',
    partnerRequired: true,
    isPurchase: true);
const purchaseInvoiceConfig = DocEditorConfig(
    docType: 'PURCHASE_INVOICE',
    title: 'Facture fournisseur',
    partnerKind: 'supplier',
    partnerRequired: true,
    isPurchase: true);
const purchaseCreditNoteConfig = DocEditorConfig(
    docType: 'PURCHASE_CREDIT_NOTE',
    title: 'Avoir fournisseur',
    partnerKind: 'supplier',
    isPurchase: true);
// Transfert entre dépôts : pas de partenaire, dépôt source + destination.
// (L'éditeur gère le dépôt de destination pour ce type.)
const stockTransferConfig = DocEditorConfig(
    docType: 'STOCK_TRANSFER',
    title: 'Transfert de stock',
    isPurchase: true);

class _EditLine {
  _EditLine({
    this.productId,
    this.product,
    required this.description,
    required int qtyMilli,
    required int unitPrice,
    required int discountPct,
    required this.vatRate,
    int qtyFreeMilli = 0,
    String lotNumber = '',
    this.expiryDate,
    this.packaging,
    int? salePrice,
  })  : qtyCtrl = TextEditingController(text: fmtQty(qtyMilli)),
        priceCtrl = TextEditingController(text: editDA(unitPrice)),
        discCtrl = TextEditingController(
            text: discountPct == 0 ? '' : fmtQty(discountPct * 10)),
        freeCtrl = TextEditingController(
            text: qtyFreeMilli == 0 ? '' : fmtQty(qtyFreeMilli)),
        lotCtrl = TextEditingController(text: lotNumber),
        saleCtrl =
            TextEditingController(text: salePrice == null ? '' : editDA(salePrice));

  final String? productId;
  final Product? product; // porte suivi lot/DLC, conditionnements, prix actuel
  final String description;
  final TextEditingController qtyCtrl;
  final TextEditingController priceCtrl;
  final TextEditingController discCtrl;
  final TextEditingController freeCtrl;
  final TextEditingController lotCtrl;
  final TextEditingController saleCtrl;
  String? expiryDate; // YYYY-MM-DD
  Packaging? packaging; // null = unité de base
  int vatRate;

  int get qtyMilli => parseQty(qtyCtrl.text) ?? 0;
  int get unitPrice => parseDA(priceCtrl.text) ?? 0;
  int get qtyFreeMilli => parseQty(freeCtrl.text) ?? 0;
  int? get salePrice => parseDA(saleCtrl.text);
  int get packFactor => packaging?.factorMilli ?? 1000;

  int get discountPct {
    final v = parseQty(discCtrl.text);
    if (v == null) return 0;
    return (v ~/ 10).clamp(0, 10000); // "15" -> 1500
  }

  int get lineHT {
    final gross = roundDiv(unitPrice * qtyMilli, 1000);
    return roundDiv(gross * (10000 - discountPct), 10000);
  }

  int get lineVAT => roundDiv(lineHT * vatRate, 10000);
  int get lineTTC => lineHT + lineVAT;

  /// Unités de base entrant en stock (qté + gratuit, converties par le pack).
  int get baseUnits =>
      roundDiv((qtyMilli + qtyFreeMilli) * packFactor, 1000);

  /// Coût effectif par unité de base : le net HT dilué par les gratuités.
  /// C'est LE chiffre qui rend la marge honnête (79,17 et non 100).
  int? get effectiveCost {
    final u = baseUnits;
    if (u <= 0) return null;
    return roundDiv(lineHT * 1000, u);
  }

  void dispose() {
    qtyCtrl.dispose();
    priceCtrl.dispose();
    discCtrl.dispose();
    freeCtrl.dispose();
    lotCtrl.dispose();
    saleCtrl.dispose();
  }
}

/// Full-screen document editor. Returns true if a document was saved/posted.
class DocEditorScreen extends StatefulWidget {
  const DocEditorScreen({
    super.key,
    required this.api,
    required this.config,
    this.existing,
    this.receiveFrom,
  });

  final ApiClient api;
  final DocEditorConfig config;
  final DocDetail? existing; // draft being edited

  /// Bon de commande à réceptionner : pré-remplit les lignes avec le reliquat
  /// et lie la réception (suivi des réceptions partielles).
  final DocDetail? receiveFrom;

  @override
  State<DocEditorScreen> createState() => _DocEditorScreenState();
}

class _DocEditorScreenState extends State<DocEditorScreen> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _supplierRefCtrl = TextEditingController();
  final _freightCtrl = TextEditingController();
  Timer? _debounce;
  List<Product> _results = const [];
  bool _searching = false;

  final List<_EditLine> _lines = [];
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  Partner? _partner;
  String? _warehouseId;
  String? _refDocumentId;
  String? _refDocNumber;
  List<Warehouse> _warehouses = const [];
  String _paymentMethod = 'cash';
  bool _busy = false;

  /// Dernier prix payé à ce fournisseur, par produit (variance de coût).
  Map<String, int> _lastPrices = const {};

  /// Stock et CMUP courants par produit — pour la marge « nouveau CMUP » live.
  final Map<String, (int, int)> _stockNow = {}; // productId -> (qty, avg)

  int _targetMarginPct = 3000; // marge cible (pct x100) pour le prix suggéré

  DocEditorConfig get cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final whs = await widget.api.warehouses();
      if (mounted) {
        setState(() {
          _warehouses = whs;
          _warehouseId = widget.existing?.warehouseId ??
              (whs.isEmpty
                  ? null
                  : whs
                      .firstWhere((w) => w.isDefault, orElse: () => whs.first)
                      .id);
        });
      }
    } catch (_) {}

    if (cfg.isReception) {
      try {
        final s = await widget.api.settings();
        final t = int.tryParse(s['target_margin_pct'] ?? '');
        if (t != null && t > 0) _targetMarginPct = t;
      } catch (_) {}
      _loadStockNow();
    }

    final ex = widget.existing;
    if (ex != null) {
      _date = DateTime.tryParse(ex.docDate) ?? DateTime.now();
      _dueDate = ex.dueDate == null ? null : DateTime.tryParse(ex.dueDate!);
      _paymentMethod = ex.paymentMethod ?? 'cash';
      _refDocumentId = ex.refDocumentId;
      _supplierRefCtrl.text = ex.supplierRef ?? '';
      if (ex.freightCost > 0) _freightCtrl.text = editDA(ex.freightCost);
      // Recharger les produits des lignes pour retrouver suivi lot/packagings.
      final prods = <String, Product>{};
      for (final l in ex.lines) {
        if (l.productId != null && !prods.containsKey(l.productId)) {
          try {
            prods[l.productId!] = await widget.api.getProduct(l.productId!);
          } catch (_) {}
        }
      }
      for (final l in ex.lines) {
        final p = l.productId == null ? null : prods[l.productId];
        Packaging? pack;
        if (p != null && l.packFactorMilli != 1000) {
          final hits =
              p.packagings.where((k) => k.factorMilli == l.packFactorMilli);
          if (hits.isNotEmpty) pack = hits.first;
        }
        _lines.add(_EditLine(
          productId: l.productId,
          product: p,
          description: l.description,
          qtyMilli: l.qtyMilli,
          unitPrice: l.unitPrice,
          discountPct: l.discountPct,
          vatRate: l.vatRate,
          qtyFreeMilli: l.qtyFreeMilli,
          lotNumber: l.lotNumber ?? '',
          expiryDate: l.expiryDate,
          packaging: pack,
          salePrice: l.newSalePrice ??
              (cfg.isReception ? p?.priceRetail : null),
        ));
      }
      if (ex.partnerId != null) {
        try {
          final all = await widget.api.partners(limit: 500);
          final match = all.where((p) => p.id == ex.partnerId);
          if (match.isNotEmpty && mounted) {
            _partner = match.first;
            _loadLastPrices();
          }
        } catch (_) {}
      }
      if (mounted) setState(() {});
    }

    // Réception d'un bon de commande : reliquat pré-rempli, lien conservé.
    final from = widget.receiveFrom;
    if (from != null && widget.existing == null) {
      _refDocumentId = from.id;
      _refDocNumber = from.number;
      if (from.partnerId != null) {
        try {
          final all = await widget.api.partners(limit: 500);
          final match = all.where((p) => p.id == from.partnerId);
          if (match.isNotEmpty) _partner = match.first;
        } catch (_) {}
      }
      for (final l in from.lines) {
        if (l.productId == null) continue;
        final outstanding =
            l.qtyMilli - l.qtyReceivedMilli - l.qtyCancelledMilli;
        if (outstanding <= 0) continue;
        Product? p;
        try {
          p = await widget.api.getProduct(l.productId!);
        } catch (_) {}
        _lines.add(_EditLine(
          productId: l.productId,
          product: p,
          description: l.description,
          qtyMilli: outstanding,
          unitPrice: l.unitPrice,
          discountPct: l.discountPct,
          vatRate: l.vatRate,
          salePrice: cfg.isReception ? p?.priceRetail : null,
        ));
      }
      _loadLastPrices();
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadStockNow() async {
    try {
      final levels = await widget.api.stockLevels();
      _stockNow.clear();
      for (final l in levels) {
        if (_warehouseId != null && l.warehouseId != _warehouseId) continue;
        final prev = _stockNow[l.productId] ?? (0, 0);
        // même dépôt : une seule ligne par produit, sinon on garde la première
        _stockNow[l.productId] = (prev.$1 + l.qtyMilli, l.avgCost);
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadLastPrices() async {
    if (_partner == null || !cfg.isPurchase) return;
    try {
      final m = await widget.api.lastSupplierPrices(_partner!.id);
      if (mounted) setState(() => _lastPrices = m);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _supplierRefCtrl.dispose();
    _freightCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  // ---- product search ----
  void _onQueryChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await widget.api.products(q: q.trim(), limit: 12);
        if (mounted) setState(() => _results = items);
      } catch (_) {}
    });
  }

  Future<void> _onSearchSubmitted(String q) async {
    final raw = q.trim();
    if (raw.isEmpty) return;

    // GS1-128 : un scan remplit produit, lot, DLC et quantité.
    if (cfg.isReception) {
      final gs1 = parseGs1(raw);
      if (gs1 != null && gs1.gtin != null) {
        await _addFromGs1(gs1);
        return;
      }
    }

    try {
      final items = await widget.api.products(q: raw, limit: 5);
      final exact = items
          .where((p) =>
              p.barcode == raw ||
              p.barcodes.contains(raw) ||
              p.packagings.any((k) => k.barcode == raw))
          .toList();
      final pick = exact.isNotEmpty
          ? exact.first
          : (items.length == 1 ? items.first : null);
      if (pick != null) {
        // Le code du carton pré-sélectionne le conditionnement.
        Packaging? pack;
        final hit = pick.packagings.where((k) => k.barcode == raw);
        if (hit.isNotEmpty) pack = hit.first;
        _addProduct(pick, packaging: pack);
        return;
      }
      if (items.isEmpty && RegExp(r'^\d{6,14}$').hasMatch(raw)) {
        // Code-barres inconnu : création en ligne, sans quitter la réception.
        // Le moment le plus friction du flux entier — spec §7.2.
        await _quickCreate(raw);
        return;
      }
      if (mounted) {
        setState(() {
          _results = items;
          _searching = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _addFromGs1(Gs1Data gs1) async {
    try {
      // On cherche par les 13 derniers chiffres significatifs du GTIN.
      var code = gs1.gtin!;
      if (code.length == 14) code = code.substring(1);
      final items = await widget.api.products(q: code, limit: 5);
      final match = items
          .where((p) =>
              (p.barcode != null && gtinMatches(gs1.gtin!, p.barcode!)) ||
              p.barcodes.any((b) => gtinMatches(gs1.gtin!, b)))
          .toList();
      if (match.isEmpty) {
        await _quickCreate(code, lot: gs1.lot, expiry: gs1.expiry, qty: gs1.qty);
        return;
      }
      final p = match.first;
      setState(() {
        _lines.add(_EditLine(
          productId: p.id,
          product: p,
          description: p.name,
          qtyMilli: (gs1.qty ?? 1) * 1000,
          unitPrice: _lastPrices[p.id] ?? p.purchasePrice,
          discountPct: 0,
          vatRate: p.vatRate,
          lotNumber: gs1.lot ?? '',
          expiryDate: gs1.expiry,
          salePrice: cfg.isReception ? p.priceRetail : null,
        ));
        _results = const [];
        _searching = false;
      });
      _searchCtrl.clear();
      _searchFocus.requestFocus();
      _snack('GS1 : ${p.name} — lot ${gs1.lot ?? '—'}, DLC ${gs1.expiry ?? '—'}');
    } catch (_) {}
  }

  /// Création éclair d'un produit inconnu en pleine réception.
  Future<void> _quickCreate(String barcode,
      {String? lot, String? expiry, int? qty}) async {
    final created = await showDialog<Product>(
      context: context,
      builder: (_) => _QuickCreateDialog(api: widget.api, barcode: barcode),
    );
    if (created == null) return;
    setState(() {
      _lines.add(_EditLine(
        productId: created.id,
        product: created,
        description: created.name,
        qtyMilli: (qty ?? 1) * 1000,
        unitPrice: created.purchasePrice,
        discountPct: 0,
        vatRate: created.vatRate,
        lotNumber: lot ?? '',
        expiryDate: expiry,
        salePrice: cfg.isReception ? created.priceRetail : null,
      ));
      _results = const [];
      _searching = false;
    });
    _searchCtrl.clear();
    _searchFocus.requestFocus();
  }

  void _addProduct(Product p, {Packaging? packaging}) {
    setState(() {
      _lines.add(_EditLine(
        productId: p.id,
        product: p,
        description: p.name,
        qtyMilli: 1000,
        unitPrice: cfg.isPurchase
            ? (_lastPrices[p.id] != null && packaging == null
                ? _lastPrices[p.id]!
                : p.purchasePrice)
            : p.unitPriceHT,
        discountPct: 0,
        vatRate: p.vatRate,
        packaging: packaging,
        salePrice: cfg.isReception ? p.priceRetail : null,
      ));
      _results = const [];
      _searching = false;
    });
    _searchCtrl.clear();
    _searchFocus.requestFocus();
  }

  // ---- totals (mirror server math) ----
  int get _totalHT => _lines.fold(0, (s, l) => s + l.lineHT);
  int get _totalVAT => _lines.fold(0, (s, l) => s + l.lineVAT);
  int get _timbre {
    if (cfg.docType != 'SALE_INVOICE' ||
        !cfg.hasPaymentMethod ||
        _paymentMethod != 'cash' ||
        _lines.isEmpty) {
      return 0;
    }
    return timbreFor(_totalHT + _totalVAT);
  }

  int get _totalTTC => _totalHT + _totalVAT + _timbre;
  int get _freight => parseDA(_freightCtrl.text) ?? 0;

  /// Marge live d'une ligne de réception contre le NOUVEAU CMUP, gratuités et
  /// frais compris — le chiffre qui fait réfléchir avant de valider.
  ({int? newCmup, int? marginPct}) _lineMargin(_EditLine l) {
    var cost = l.effectiveCost;
    if (cost == null || l.productId == null) return (newCmup: null, marginPct: null);
    // Frais d'approche au prorata de la valeur.
    if (_freight > 0 && _totalHT > 0) {
      final alloc = roundDiv(_freight * l.lineHT, _totalHT);
      cost = roundDiv((l.lineHT + alloc) * 1000, l.baseUnits);
    }
    final now = _stockNow[l.productId] ?? (0, 0);
    final int newCmup;
    if (now.$1 <= 0) {
      newCmup = cost;
    } else {
      newCmup = roundDiv(now.$1 * now.$2 + l.baseUnits * cost,
          now.$1 + l.baseUnits);
    }
    final sale = l.salePrice;
    if (sale == null || sale <= 0 || newCmup <= 0) {
      return (newCmup: newCmup, marginPct: null);
    }
    // PV_HT = PV_TTC / (1 + tva) — jamais de marge TTC contre un coût HT.
    final pvHT = roundDiv(sale * 10000, 10000 + l.vatRate);
    return (
      newCmup: newCmup,
      marginPct: roundDiv((pvHT - newCmup) * 10000, newCmup)
    );
  }

  /// Prix suggéré : nouveau CMUP × (1 + marge cible) × (1 + TVA). Jamais
  /// appliqué tout seul — un tap l'accepte.
  int? _suggestedPrice(_EditLine l) {
    final m = _lineMargin(l);
    if (m.newCmup == null || m.newCmup! <= 0) return null;
    final ht = roundDiv(m.newCmup! * (10000 + _targetMarginPct), 10000);
    final ttc = roundDiv(ht * (10000 + l.vatRate), 10000);
    // arrondi commerçant au dinar
    return roundDiv(ttc, 100) * 100;
  }

  bool _costVariance(_EditLine l) {
    final last = l.productId == null ? null : _lastPrices[l.productId];
    if (last == null || last <= 0) return false;
    final eff = l.effectiveCost;
    if (eff == null) return false;
    final diff = (eff - last).abs();
    return diff * 100 > last * 15; // > 15 %
  }

  // ---- save/post ----
  Map<String, dynamic> _payload(
      {bool acceptShort = false, bool acceptOver = false}) {
    return {
      'doc_type': cfg.docType,
      'doc_date':
          '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
      'partner_id': _partner?.id,
      'warehouse_id': cfg.needsWarehouse ? _warehouseId : null,
      'payment_method': cfg.hasPaymentMethod ? _paymentMethod : null,
      'ref_document_id': _refDocumentId,
      'supplier_ref': cfg.isPurchase && _supplierRefCtrl.text.trim().isNotEmpty
          ? _supplierRefCtrl.text.trim()
          : null,
      'due_date': _dueDate == null
          ? null
          : '${_dueDate!.year.toString().padLeft(4, '0')}-${_dueDate!.month.toString().padLeft(2, '0')}-${_dueDate!.day.toString().padLeft(2, '0')}',
      'freight_cost': cfg.isReception ? _freight : 0,
      'accept_short_dated': acceptShort,
      'accept_over_receipt': acceptOver,
      'lines': [
        for (final l in _lines)
          {
            'product_id': l.productId,
            'description': l.description,
            'qty_milli': l.qtyMilli,
            'unit_price': l.unitPrice,
            'discount_pct': l.discountPct,
            'vat_rate': l.vatRate,
            'qty_free_milli': cfg.isReception ? l.qtyFreeMilli : 0,
            'lot_number': cfg.isReception && l.lotCtrl.text.trim().isNotEmpty
                ? l.lotCtrl.text.trim()
                : null,
            'expiry_date': cfg.isReception ? l.expiryDate : null,
            'pack_factor_milli': cfg.isReception ? l.packFactor : 1000,
            'new_sale_price': cfg.isReception &&
                    l.salePrice != null &&
                    l.salePrice != l.product?.priceRetail
                ? l.salePrice
                : null,
          }
      ],
    };
  }

  String? _validate() {
    if (_lines.isEmpty) return 'Ajoutez au moins une ligne.';
    if (cfg.needsWarehouse && _warehouseId == null) {
      return 'Aucun dépôt disponible.';
    }
    final needPartner = cfg.partnerRequired ||
        (cfg.hasPaymentMethod && _paymentMethod == 'credit');
    if (needPartner && _partner == null) {
      return cfg.partnerKind == 'supplier'
          ? 'Le fournisseur est obligatoire pour valider.'
          : 'Sélectionnez un client.';
    }
    if (_lines.any((l) => l.qtyMilli == 0 && l.qtyFreeMilli == 0)) {
      return 'Une ligne a une quantité nulle.';
    }
    if (_lines.any((l) => l.discountPct < 0)) {
      return 'Remise négative refusée.';
    }
    if (cfg.isReception) {
      for (final l in _lines) {
        final p = l.product;
        if (p == null) continue;
        if (p.trackLots && l.lotCtrl.text.trim().isEmpty) {
          return 'Le n° de lot est obligatoire pour « ${p.name} ».';
        }
        if (p.trackExpiry && (l.expiryDate == null || l.expiryDate!.isEmpty)) {
          return 'La date de péremption est obligatoire pour « ${p.name} ».';
        }
      }
    }
    return null;
  }

  /// Un prix de vente sous le nouveau CMUP avertit, ne bloque pas.
  Future<bool> _confirmBelowCost() async {
    if (!cfg.isReception) return true;
    final bad = <String>[];
    for (final l in _lines) {
      final m = _lineMargin(l);
      if (m.marginPct != null && m.marginPct! < 0) bad.add(l.description);
    }
    if (bad.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: Text('Vente à perte ?', style: T.h2),
        content: Text(
            'Prix de vente sous le coût de revient pour :\n• ${bad.join('\n• ')}',
            style: T.body.copyWith(height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Corriger')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: T.warn, foregroundColor: T.ink),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Valider quand même')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save({required bool post}) async {
    final msg = _validate();
    if (msg != null) {
      _snack(msg, error: true);
      return;
    }
    if (post && !await _confirmBelowCost()) return;
    setState(() => _busy = true);
    var acceptShort = false;
    var acceptOver = false;
    try {
      while (true) {
        final DocDetail draft;
        final payload =
            _payload(acceptShort: acceptShort, acceptOver: acceptOver);
        if (widget.existing != null) {
          draft = await widget.api.updateDraft(widget.existing!.id, payload);
        } else if (acceptShort || acceptOver) {
          // retry : le brouillon vient d'être créé au tour précédent
          draft = await widget.api.updateDraft(_retryDraftId!, payload);
        } else {
          draft = await widget.api.createDraft(payload);
        }
        _retryDraftId = draft.id;
        if (!post) {
          if (!mounted) return;
          Navigator.of(context).pop(true);
          _snackGlobal('Brouillon enregistré');
          return;
        }
        try {
          final posted = await widget.api.postDocument(draft.id);
          if (!mounted) return;
          Navigator.of(context).pop(true);
          _snackGlobal('${posted.number}  ·  ${fmtDA(posted.totalTTC)}');
          _priceSummary(posted);
          return;
        } on ApiException catch (e) {
          // Les acceptations explicites de la spec : courte durée de vie et
          // sur-réception. Refus propre → confirmation → revalidation.
          if (e.message.contains('durée de vie') && !acceptShort) {
            final ok = await _confirmException('Durée de vie insuffisante',
                e.message, 'Accepter le lot court');
            if (ok) {
              acceptShort = true;
              continue;
            }
            return;
          }
          if (e.message.contains('sur-réception') && !acceptOver) {
            final ok = await _confirmException('Sur-réception',
                e.message, 'Accepter la sur-réception');
            if (ok) {
              acceptOver = true;
              continue;
            }
            return;
          }
          rethrow;
        }
      }
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('Erreur : $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _retryDraftId;

  Future<bool> _confirmException(
      String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: Text(title, style: T.h2),
        content: Text(message, style: T.body.copyWith(height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: T.warn, foregroundColor: T.ink),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  /// Après validation : quels prix de vente ont changé (revue immédiate).
  void _priceSummary(DocDetail posted) {
    final changed = posted.lines
        .where((l) => l.newSalePrice != null)
        .map((l) => l.description)
        .toList();
    if (changed.isEmpty) return;
    _snackGlobal('Prix de vente mis à jour : ${changed.join(', ')}');
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: error ? T.danger : T.ink,
      behavior: SnackBarBehavior.floating,
      content: Text(msg,
          style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
    ));
  }

  void _snackGlobal(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: T.ink,
      behavior: SnackBarBehavior.floating,
      content: Row(children: [
        const Icon(Icons.check_circle, color: T.mint, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(msg,
              style: const TextStyle(
                  fontFamily: T.mono, fontSize: 13, color: Colors.white)),
        ),
      ]),
    ));
  }

  Future<void> _pickPartner() async {
    final p = await showPartnerPicker(context, widget.api,
        kind: cfg.partnerKind);
    if (p != null) {
      setState(() => _partner = p);
      _loadLastPrices();
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickDueDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? _date.add(const Duration(days: 30)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _dueDate = d);
  }

  @override
  Widget build(BuildContext context) {
    final partnerLabel =
        cfg.partnerKind == 'supplier' ? 'Fournisseur' : 'Client';
    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          // ---- Top bar ----
          Container(
            color: T.surface,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  onPressed:
                      _busy ? null : () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.arrow_back, size: 20, color: T.muted),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cfg.title, style: T.h2),
                      Text(
                          _refDocNumber != null
                              ? 'Réception de $_refDocNumber'
                              : widget.existing?.number ??
                                  (widget.existing != null
                                      ? 'Brouillon'
                                      : 'Nouveau document'),
                          style: T.monoSmall),
                    ],
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: T.border3),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(T.rInner)),
                    ),
                    onPressed: _busy ? null : () => _save(post: false),
                    child: const Text('Enregistrer',
                        style: TextStyle(
                            fontFamily: T.sans,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: T.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: PrimaryButton(
                    label: _busy ? 'Validation…' : 'Valider',
                    onPressed: _busy ? null : () => _save(post: true),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          // ---- Header fields ----
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                _HeaderField(
                  label: 'Date',
                  child: InkWell(
                    onTap: _pickDate,
                    child: Row(children: [
                      const Icon(Icons.calendar_today_outlined,
                          size: 14, color: T.faint),
                      const SizedBox(width: 8),
                      Text(
                          '${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}',
                          style: T.monoBody),
                    ]),
                  ),
                ),
                const SizedBox(width: 12),
                _HeaderField(
                  label: partnerLabel + (cfg.partnerRequired ? ' *' : ''),
                  child: InkWell(
                    onTap: _pickPartner,
                    child: Row(children: [
                      Icon(
                          cfg.partnerKind == 'supplier'
                              ? Icons.local_shipping_outlined
                              : Icons.person_outline,
                          size: 15,
                          color: T.faint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_partner?.name ?? '— aucun —',
                            overflow: TextOverflow.ellipsis,
                            style: _partner == null
                                ? T.bodyMuted.copyWith(color: T.ghost)
                                : T.body),
                      ),
                      if (_partner != null)
                        InkWell(
                          onTap: () => setState(() => _partner = null),
                          child:
                              const Icon(Icons.close, size: 14, color: T.faint),
                        ),
                    ]),
                  ),
                ),
                if (cfg.needsWarehouse) ...[
                  const SizedBox(width: 12),
                  _HeaderField(
                    label: 'Dépôt',
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _warehouseId,
                        isDense: true,
                        isExpanded: true,
                        style: T.body,
                        icon: const Icon(Icons.expand_more,
                            size: 15, color: T.faint),
                        items: [
                          for (final w in _warehouses)
                            DropdownMenuItem(value: w.id, child: Text(w.name)),
                        ],
                        onChanged: (v) {
                          setState(() => _warehouseId = v);
                          if (cfg.isReception) _loadStockNow();
                        },
                      ),
                    ),
                  ),
                ],
                if (cfg.isPurchase &&
                    (cfg.isReception || cfg.isSupplierInvoice)) ...[
                  const SizedBox(width: 12),
                  _HeaderField(
                    label: cfg.isReception ? 'N° BL fournisseur' : 'N° facture *',
                    child: TextField(
                      controller: _supplierRefCtrl,
                      style: T.monoBody,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: cfg.isReception ? 'BL-…' : 'FAC-…',
                        hintStyle: T.monoSmall.copyWith(color: T.ghost),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
                if (cfg.isReception) ...[
                  const SizedBox(width: 12),
                  _HeaderField(
                    label: 'Frais (transport…)',
                    child: TextField(
                      controller: _freightCtrl,
                      onChanged: (_) => setState(() {}),
                      style: T.monoBody,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0,00',
                        hintStyle: T.monoSmall.copyWith(color: T.ghost),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
                if (cfg.isSupplierInvoice) ...[
                  const SizedBox(width: 12),
                  _HeaderField(
                    label: 'Échéance',
                    child: InkWell(
                      onTap: _pickDueDate,
                      child: Row(children: [
                        const Icon(Icons.event_outlined,
                            size: 14, color: T.faint),
                        const SizedBox(width: 8),
                        Text(
                            _dueDate == null
                                ? '— aucune —'
                                : '${_dueDate!.day.toString().padLeft(2, '0')}/${_dueDate!.month.toString().padLeft(2, '0')}/${_dueDate!.year}',
                            style: _dueDate == null
                                ? T.bodyMuted.copyWith(color: T.ghost)
                                : T.monoBody),
                      ]),
                    ),
                  ),
                ],
                if (cfg.hasPaymentMethod) ...[
                  const SizedBox(width: 12),
                  _HeaderField(
                    label: 'Règlement',
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _paymentMethod,
                        isDense: true,
                        isExpanded: true,
                        style: T.body,
                        icon: const Icon(Icons.expand_more,
                            size: 15, color: T.faint),
                        items: const [
                          DropdownMenuItem(
                              value: 'cash', child: Text('Espèces')),
                          DropdownMenuItem(
                              value: 'credit', child: Text('Crédit')),
                          DropdownMenuItem(
                              value: 'cib', child: Text('Carte CIB')),
                          DropdownMenuItem(
                              value: 'cheque', child: Text('Chèque')),
                          DropdownMenuItem(
                              value: 'transfer', child: Text('Virement')),
                        ],
                        onChanged: (v) =>
                            setState(() => _paymentMethod = v ?? 'cash'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ---- Add product ----
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Column(
              children: [
                SearchField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  autofocus: true,
                  hint: cfg.isReception
                      ? 'Scanner (EAN-13 ou GS1-128) ou rechercher — code inconnu = création en ligne'
                      : 'Ajouter un produit — scanner ou rechercher…',
                  onChanged: _onQueryChanged,
                  onSubmitted: _onSearchSubmitted,
                ),
                if (_searching && _results.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 220),
                    decoration: BoxDecoration(
                      color: T.surface,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, i) {
                        final p = _results[i];
                        return InkWell(
                          onTap: () => _addProduct(p),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            child: Row(children: [
                              Expanded(child: Text(p.name, style: T.body)),
                              Text(
                                  fmtDA(cfg.isPurchase
                                      ? p.purchasePrice
                                      : p.priceRetail),
                                  style: T.monoSmall),
                            ]),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          // ---- Lines ----
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Card14(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    Padding(
                      padding:
                          const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 8),
                      child: cfg.isReception
                          ? const Row(children: [
                              Expanded(flex: 4, child: MicroLabel('Produit')),
                              SizedBox(width: 92, child: MicroLabel('Unité')),
                              SizedBox(width: 70, child: MicroLabel('Qté')),
                              SizedBox(width: 70, child: MicroLabel('Gratuit')),
                              SizedBox(width: 100, child: MicroLabel('Coût HT')),
                              SizedBox(width: 62, child: MicroLabel('Rem. %')),
                              SizedBox(width: 50, child: MicroLabel('TVA')),
                              SizedBox(
                                  width: 104,
                                  child: Align(
                                      alignment:
                                          AlignmentDirectional.centerEnd,
                                      child: MicroLabel('Total TTC'))),
                              SizedBox(width: 34),
                            ])
                          : Row(children: [
                              const Expanded(
                                  flex: 5, child: MicroLabel('Produit')),
                              const SizedBox(
                                  width: 86, child: MicroLabel('Qté')),
                              SizedBox(
                                  width: 110,
                                  child: MicroLabel(
                                      cfg.isPurchase ? 'Coût HT' : 'PU HT')),
                              const SizedBox(
                                  width: 70, child: MicroLabel('Rem. %')),
                              const SizedBox(
                                  width: 56, child: MicroLabel('TVA')),
                              const SizedBox(
                                  width: 110,
                                  child: Align(
                                      alignment:
                                          AlignmentDirectional.centerEnd,
                                      child: MicroLabel('Total TTC'))),
                              const SizedBox(width: 34),
                            ]),
                    ),
                    const Divider(),
                    Expanded(
                      child: _lines.isEmpty
                          ? const EmptyState(
                              icon: Icons.playlist_add,
                              text:
                                  'Aucune ligne.\nScannez ou recherchez un produit ci-dessus.')
                          : ListView.separated(
                              itemCount: _lines.length,
                              separatorBuilder: (_, _) => const Divider(),
                              itemBuilder: (context, i) => cfg.isReception
                                  ? _ReceptionLineRow(
                                      line: _lines[i],
                                      margin: _lineMargin(_lines[i]),
                                      suggested: _suggestedPrice(_lines[i]),
                                      variance: _costVariance(_lines[i]),
                                      lastPrice: _lines[i].productId == null
                                          ? null
                                          : _lastPrices[_lines[i].productId],
                                      onChanged: () => setState(() {}),
                                      onRemove: () => setState(() {
                                        _lines.removeAt(i).dispose();
                                      }),
                                      onPickExpiry: () async {
                                        final l = _lines[i];
                                        final d = await showDatePicker(
                                          context: context,
                                          initialDate: DateTime.tryParse(
                                                  l.expiryDate ?? '') ??
                                              DateTime.now().add(
                                                  const Duration(days: 365)),
                                          firstDate: DateTime(2020),
                                          lastDate: DateTime(2100),
                                        );
                                        if (d != null) {
                                          setState(() => l.expiryDate =
                                              '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
                                        }
                                      },
                                    )
                                  : _LineRow(
                                      line: _lines[i],
                                      onChanged: () => setState(() {}),
                                      onRemove: () => setState(() {
                                        _lines.removeAt(i).dispose();
                                      }),
                                    ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ---- Totals ----
          Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rCard),
              border: Border.all(color: T.border),
            ),
            child: Row(
              children: [
                MicroLabel('${_lines.length} lignes'),
                if (cfg.isReception && _freight > 0) ...[
                  const SizedBox(width: 16),
                  MintChip('Frais ${fmtDA(_freight)} répartis',
                      color: T.cream, fg: T.faint),
                ],
                const Spacer(),
                _Total('HT', _totalHT),
                _Total('TVA', _totalVAT),
                if (_timbre > 0) _Total('Timbre', _timbre),
                const SizedBox(width: 22),
                Text(fmtDA(_totalTTC), style: T.monoBig),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderField extends StatelessWidget {
  const _HeaderField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MicroLabel(label),
            const SizedBox(height: 3),
            Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: child)),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow(
      {required this.line, required this.onChanged, required this.onRemove});
  final _EditLine line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 5, 14, 5),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: Text(line.description,
              style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        SizedBox(
            width: 86,
            child: _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
        SizedBox(
            width: 110,
            child:
                _CellField(controller: line.priceCtrl, onChanged: onChanged)),
        SizedBox(
            width: 70,
            child: _CellField(
                controller: line.discCtrl, onChanged: onChanged, hint: '0')),
        SizedBox(
            width: 56,
            child: Text('${line.vatRate ~/ 100}%',
                style: T.monoSmall.copyWith(color: T.muted))),
        SizedBox(
          width: 110,
          child: Text(fmtDA(line.lineTTC),
              textAlign: TextAlign.end, style: T.monoBody),
        ),
        SizedBox(
          width: 34,
          child: IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 15, color: T.faint),
            tooltip: 'Supprimer la ligne',
          ),
        ),
      ]),
    );
  }
}

/// Ligne de réception sur deux étages : quantités/coûts en haut, lot/DLC et
/// prix de vente + marge live en bas — la marge inclut gratuités et frais.
class _ReceptionLineRow extends StatelessWidget {
  const _ReceptionLineRow({
    required this.line,
    required this.margin,
    required this.suggested,
    required this.variance,
    required this.lastPrice,
    required this.onChanged,
    required this.onRemove,
    required this.onPickExpiry,
  });
  final _EditLine line;
  final ({int? newCmup, int? marginPct}) margin;
  final int? suggested;
  final bool variance;
  final int? lastPrice;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onPickExpiry;

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final needsLot = p?.trackLots ?? false;
    final needsExpiry = p?.trackExpiry ?? false;
    final m = margin.marginPct;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 14, 6),
      child: Column(children: [
        Row(children: [
          Expanded(
            flex: 4,
            child: Text(line.description,
                style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 92,
            child: p != null && p.packagings.isNotEmpty
                ? DropdownButtonHideUnderline(
                    child: DropdownButton<Packaging?>(
                      value: line.packaging,
                      isDense: true,
                      isExpanded: true,
                      style: T.monoSmall.copyWith(color: T.ink),
                      items: [
                        const DropdownMenuItem<Packaging?>(
                            value: null, child: Text('Pièce')),
                        for (final k in p.packagings)
                          DropdownMenuItem(
                              value: k,
                              child: Text('${k.name} ×${fmtQty(k.factorMilli)}',
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (v) {
                        line.packaging = v;
                        onChanged();
                      },
                    ),
                  )
                : Text('Pièce', style: T.monoSmall.copyWith(color: T.faint)),
          ),
          SizedBox(
              width: 70,
              child:
                  _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
          SizedBox(
              width: 70,
              child: _CellField(
                  controller: line.freeCtrl, onChanged: onChanged, hint: '0')),
          SizedBox(
            width: 100,
            child: Row(children: [
              Expanded(
                  child: _CellField(
                      controller: line.priceCtrl, onChanged: onChanged)),
              if (variance)
                Tooltip(
                  message:
                      'Écart > 15 % vs dernier prix payé (${fmtDA(lastPrice ?? 0)})',
                  child: const Padding(
                    padding: EdgeInsetsDirectional.only(end: 6),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 15, color: T.warnDark),
                  ),
                ),
            ]),
          ),
          SizedBox(
              width: 62,
              child: _CellField(
                  controller: line.discCtrl, onChanged: onChanged, hint: '0')),
          SizedBox(
              width: 50,
              child: Text('${line.vatRate ~/ 100}%',
                  style: T.monoSmall.copyWith(color: T.muted))),
          SizedBox(
            width: 104,
            child: Text(fmtDA(line.lineTTC),
                textAlign: TextAlign.end, style: T.monoBody),
          ),
          SizedBox(
            width: 34,
            child: IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 15, color: T.faint),
              tooltip: 'Supprimer la ligne',
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: 12),
          // Lot
          SizedBox(
            width: 140,
            child: Row(children: [
              Icon(Icons.qr_code_2_rounded,
                  size: 13, color: needsLot ? T.warnDark : T.ghost),
              const SizedBox(width: 4),
              Expanded(
                child: _CellField(
                    controller: line.lotCtrl,
                    onChanged: onChanged,
                    hint: needsLot ? 'Lot *' : 'Lot'),
              ),
            ]),
          ),
          // DLC
          InkWell(
            onTap: onPickExpiry,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              margin: const EdgeInsetsDirectional.only(end: 8),
              decoration: BoxDecoration(
                color: T.bg,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                    color: needsExpiry &&
                            (line.expiryDate == null ||
                                line.expiryDate!.isEmpty)
                        ? T.warn
                        : T.border2),
              ),
              child: Row(children: [
                const Icon(Icons.event_outlined, size: 13, color: T.faint),
                const SizedBox(width: 5),
                Text(
                    line.expiryDate == null || line.expiryDate!.isEmpty
                        ? (needsExpiry ? 'DLC *' : 'DLC')
                        : line.expiryDate!,
                    style: T.monoSmall.copyWith(
                        color: line.expiryDate == null ? T.ghost : T.ink)),
              ]),
            ),
          ),
          if (line.baseUnits > 0 && line.effectiveCost != null) ...[
            MintChip(
                '${fmtQty(line.baseUnits)} u. à ${fmtDA(margin.newCmup ?? line.effectiveCost!)}',
                color: T.cream,
                fg: T.faint),
            const SizedBox(width: 8),
          ],
          const Spacer(),
          // Prix de vente TTC — pré-rempli, jamais vide ; s'applique à TOUT le
          // stock de ce produit dans ce dépôt (logique un-seul-prix).
          const MicroLabel('PV TTC'),
          const SizedBox(width: 6),
          SizedBox(
              width: 96,
              child: _CellField(
                  controller: line.saleCtrl, onChanged: onChanged)),
          if (suggested != null && suggested != line.salePrice)
            Tooltip(
              message: 'Prix suggéré (marge cible) — cliquez pour appliquer',
              child: InkWell(
                onTap: () {
                  line.saleCtrl.text = editDA(suggested!);
                  onChanged();
                },
                child: Container(
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  margin: const EdgeInsetsDirectional.only(end: 8),
                  decoration: BoxDecoration(
                    color: T.bg,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: T.border2),
                  ),
                  alignment: Alignment.center,
                  child: Text('≈ ${fmtDA(suggested!)}',
                      style: T.monoSmall.copyWith(color: T.ghost)),
                ),
              ),
            ),
          SizedBox(
            width: 92,
            child: m == null
                ? Text('—', style: T.monoSmall.copyWith(color: T.ghost))
                : MintChip(
                    'Marge ${(m / 100).toStringAsFixed(1).replaceAll('.', ',')} %',
                    color: m < 0
                        ? T.dangerTint
                        : m < 1000
                            ? T.warnTint
                            : T.mintTint,
                    fg: m < 0
                        ? T.dangerDark
                        : m < 1000
                            ? T.warnDark
                            : T.mintDark,
                  ),
          ),
        ]),
      ]),
    );
  }
}

class _CellField extends StatelessWidget {
  const _CellField(
      {required this.controller, required this.onChanged, this.hint});
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      margin: const EdgeInsetsDirectional.only(end: 8),
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: T.border2),
      ),
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged(),
        style: T.monoBody.copyWith(fontSize: 12.5),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: T.monoSmall.copyWith(color: T.ghost),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.label, this.amount);
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          MicroLabel(label),
          const SizedBox(height: 2),
          Text(fmtDA(amount), style: T.monoBody.copyWith(color: T.muted)),
        ],
      ),
    );
  }
}

/// Création éclair d'un produit inconnu scanné en pleine réception : deux
/// champs essentiels, le reste se complète plus tard sur la fiche.
class _QuickCreateDialog extends StatefulWidget {
  const _QuickCreateDialog({required this.api, required this.barcode});
  final ApiClient api;
  final String barcode;

  @override
  State<_QuickCreateDialog> createState() => _QuickCreateDialogState();
}

class _QuickCreateDialogState extends State<_QuickCreateDialog> {
  final _name = TextEditingController();
  final _sale = TextEditingController();
  int _vat = 1900;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.settings().then((s) {
      final v = int.tryParse(s['default_vat'] ?? '');
      if (v != null && mounted) setState(() => _vat = v);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _sale.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Le nom est obligatoire.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.api.saveProduct({
        'name': _name.text.trim(),
        'barcode': widget.barcode,
        'vat_rate': _vat,
        'purchase_price': 0,
        'price_retail': parseDA(_sale.text) ?? 0,
        'min_stock_milli': 0,
        'is_weighable': false,
        'unit': 'piece',
        'track_lots': false,
        'track_serials': false,
        'warranty_months': 0,
        'description': '',
        'brand': '',
        'track_expiry': false,
      });
      if (mounted) Navigator.of(context).pop(p);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Produit inconnu', style: T.h2),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Code-barres ${widget.barcode} — créez-le sans quitter la réception.',
                style: T.small.copyWith(height: 1.4)),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              style: T.body,
              decoration: const InputDecoration(labelText: 'Désignation *'),
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _sale,
                  style: T.body,
                  decoration:
                      const InputDecoration(labelText: 'Prix de vente TTC'),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<int>(
                value: _vat,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('TVA 0%')),
                  DropdownMenuItem(value: 900, child: Text('TVA 9%')),
                  DropdownMenuItem(value: 1900, child: Text('TVA 19%')),
                ],
                onChanged: (v) => setState(() => _vat = v ?? 1900),
              ),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: T.small.copyWith(
                      color: T.dangerDark, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : 'Créer et ajouter',
            onPressed: _busy ? null : _create),
      ],
    );
  }
}

/// Shared partner picker dialog (search + list). Returns the chosen partner.
Future<Partner?> showPartnerPicker(BuildContext context, ApiClient api,
    {String? kind}) {
  return showDialog<Partner>(
    context: context,
    builder: (context) => _PartnerPickerDialog(api: api, kind: kind),
  );
}

class _PartnerPickerDialog extends StatefulWidget {
  const _PartnerPickerDialog({required this.api, this.kind});
  final ApiClient api;
  final String? kind;

  @override
  State<_PartnerPickerDialog> createState() => _PartnerPickerDialogState();
}

class _PartnerPickerDialogState extends State<_PartnerPickerDialog> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Partner> _items = const [];

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load(String q) async {
    try {
      final items = await widget.api.partners(q: q, kind: widget.kind);
      if (mounted) setState(() => _items = items);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 440,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: SearchField(
                controller: _ctrl,
                autofocus: true,
                hint: widget.kind == 'supplier'
                    ? 'Rechercher un fournisseur…'
                    : 'Rechercher un client…',
                onChanged: (q) {
                  _debounce?.cancel();
                  _debounce = Timer(
                      const Duration(milliseconds: 250), () => _load(q));
                },
              ),
            ),
            const Divider(),
            Expanded(
              child: _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.person_search, text: 'Aucun résultat')
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, i) {
                        final p = _items[i];
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(p),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 11),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.name, style: T.body),
                                    if (p.phone != null)
                                      Text(p.phone!, style: T.monoSmall),
                                  ],
                                ),
                              ),
                              if (p.balance != 0)
                                Text(fmtDA(p.balance),
                                    style: T.monoSmall.copyWith(
                                        color: p.balance > 0
                                            ? T.warnDark
                                            : T.mintDark)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
