import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
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
  bool get isSaleInvoice => docType == 'SALE_INVOICE';

  /// Transfert entre dépôts : pas de partenaire, quantités seulement.
  bool get isTransfer => docType == 'STOCK_TRANSFER';
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
// Transfert entre dépôts : pas de partenaire, dépôt source + destination,
// quantités seulement (le coût suit le CMUP du dépôt source).
const stockTransferConfig = DocEditorConfig(
    docType: 'STOCK_TRANSFER',
    title: 'Transfert de stock',
    isPurchase: true);

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _frDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

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
        saleCtrl = TextEditingController(
            text: salePrice == null ? '' : editDA(salePrice));

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

  /// Ligne libre (service, transport…) : pas de produit, pas de stock.
  bool get isFree => productId == null;

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
  int get baseUnits => roundDiv((qtyMilli + qtyFreeMilli) * packFactor, 1000);

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
    this.copyFrom,
    this.linkToCopy = false,
    this.initialPartner,
  });

  final ApiClient api;
  final DocEditorConfig config;
  final DocDetail? existing; // draft being edited

  /// Bon de commande à réceptionner : pré-remplit les lignes avec le reliquat
  /// et lie la réception (suivi des réceptions partielles).
  final DocDetail? receiveFrom;

  /// Nouveau document pré-rempli depuis un autre (Dupliquer, Convertir en…) :
  /// partenaire, lignes et notes repris, date du jour.
  final DocDetail? copyFrom;

  /// Avec [copyFrom] : le nouveau document référence l'original
  /// (devis → facture, BL → facture : le stock n'est pas sorti deux fois).
  final bool linkToCopy;

  /// Partenaire pré-sélectionné (« Nouvelle facture » depuis Partenaires).
  final Partner? initialPartner;

  @override
  State<DocEditorScreen> createState() => _DocEditorScreenState();
}

class _DocEditorScreenState extends State<DocEditorScreen> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _supplierRefCtrl = TextEditingController();
  final _freightCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _internalNotesCtrl = TextEditingController();
  final _termCtrl = TextEditingController();
  Timer? _debounce;
  List<Product> _results = const [];
  bool _searching = false;
  int _hi = -1; // résultat surligné au clavier

  final List<_EditLine> _lines = [];
  final List<_EditLine> _removed = []; // gardées pour « Annuler », libérées à la fin
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  Partner? _partner;
  String? _warehouseId;
  String? _destWarehouseId;
  String? _refDocumentId;
  String? _refDocNumber;
  List<Warehouse> _warehouses = const [];
  String _paymentMethod = 'cash';
  bool _busy = false;
  bool _showNotes = false;

  /// Id du brouillon côté serveur, dès qu'il existe.
  String? _docId;
  List<DocAttachment> _attachments = const [];

  /// Erreurs par champ (partner, warehouse, dest, supplierRef, lines).
  Map<String, String> _errors = const {};

  /// Empreinte du document à l'ouverture : sert à détecter les modifications.
  String? _initialSig;

  /// Dernier prix payé à ce fournisseur, par produit (variance de coût).
  Map<String, int> _lastPrices = const {};

  /// Stock et CMUP courants par produit — pour la marge « nouveau CMUP » live.
  final Map<String, (int, int)> _stockNow = {}; // productId -> (qty, avg)

  int _targetMarginPct = 3000; // marge cible (pct x100) pour le prix suggéré

  DocEditorConfig get cfg => widget.config;

  /// Échéance proposée : factures à crédit et factures fournisseur.
  bool get _hasDueDate =>
      cfg.isSupplierInvoice ||
      (cfg.isSaleInvoice && cfg.hasPaymentMethod && _paymentMethod == 'credit');

  @override
  void initState() {
    super.initState();
    _docId = widget.existing?.id;
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
          if (cfg.isTransfer) {
            _destWarehouseId = widget.existing?.destWarehouseId ??
                widget.copyFrom?.destWarehouseId;
          }
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

    if (widget.initialPartner != null) _partner = widget.initialPartner;

    final ex = widget.existing ?? widget.copyFrom;
    if (ex != null) {
      final isCopy = widget.existing == null;
      if (!isCopy) {
        _date = DateTime.tryParse(ex.docDate) ?? DateTime.now();
        _dueDate = ex.dueDate == null ? null : DateTime.tryParse(ex.dueDate!);
        _refDocumentId = ex.refDocumentId;
        _supplierRefCtrl.text = ex.supplierRef ?? '';
        if (ex.freightCost > 0) _freightCtrl.text = editDA(ex.freightCost);
      } else if (widget.linkToCopy) {
        _refDocumentId = ex.id;
        _refDocNumber = ex.number;
      }
      if (cfg.hasPaymentMethod && ex.paymentMethod != null) {
        _paymentMethod = ex.paymentMethod!;
      }
      if (!isCopy || ex.docType == cfg.docType) {
        _warehouseId = ex.warehouseId ?? _warehouseId;
      }
      _notesCtrl.text = ex.notes ?? '';
      _internalNotesCtrl.text = ex.internalNotes ?? '';
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
          qtyFreeMilli: isCopy ? 0 : l.qtyFreeMilli,
          lotNumber: isCopy ? '' : (l.lotNumber ?? ''),
          expiryDate: isCopy ? null : l.expiryDate,
          packaging: pack,
          salePrice: isCopy
              ? (cfg.isReception ? p?.priceRetail : null)
              : l.newSalePrice ?? (cfg.isReception ? p?.priceRetail : null),
        ));
      }
      if (ex.partnerId != null && !cfg.isTransfer) {
        try {
          _partner = await widget.api.getPartner(ex.partnerId!);
          _loadLastPrices();
        } catch (_) {}
      }
      if (!isCopy) _loadAttachments();
    }

    // Réception d'un bon de commande : reliquat pré-rempli, lien conservé.
    final from = widget.receiveFrom;
    if (from != null && widget.existing == null) {
      _refDocumentId = from.id;
      _refDocNumber = from.number;
      if (from.partnerId != null) {
        try {
          _partner = await widget.api.getPartner(from.partnerId!);
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
    }

    // Délai de paiement par défaut (Paramètres → payment_term_days).
    if (widget.existing == null && _dueDate == null) {
      final days = Features.instance.paymentTermDays;
      if (days > 0) _termCtrl.text = '$days';
      if (_hasDueDate && days > 0) {
        _dueDate = _date.add(Duration(days: days));
      }
    } else if (_dueDate != null) {
      _termCtrl.text = '${_dueDate!.difference(_dayOf(_date)).inDays}';
    }

    _showNotes = _notesCtrl.text.isNotEmpty || _internalNotesCtrl.text.isNotEmpty;
    if (mounted) setState(() {});
    // Un document dupliqué/converti n'est pas encore enregistré : il compte
    // comme modifié dès l'ouverture.
    _initialSig =
        widget.copyFrom != null || widget.receiveFrom != null ? '' : _signature();
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  String _signature() => jsonEncode(_payload());

  bool get _dirty {
    if (_initialSig == null) return false;
    if (_initialSig!.isEmpty) return _lines.isNotEmpty;
    return _signature() != _initialSig;
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
    if (_partner == null || !cfg.isPurchase || cfg.isTransfer) return;
    try {
      final m = await widget.api.lastSupplierPrices(_partner!.id);
      if (mounted) setState(() => _lastPrices = m);
    } catch (_) {}
  }

  Future<void> _loadAttachments() async {
    final id = _docId;
    if (id == null) return;
    try {
      final a = await widget.api.documentAttachments(id);
      if (mounted) setState(() => _attachments = a);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _supplierRefCtrl.dispose();
    _freightCtrl.dispose();
    _notesCtrl.dispose();
    _internalNotesCtrl.dispose();
    _termCtrl.dispose();
    for (final l in [..._lines, ..._removed]) {
      l.dispose();
    }
    super.dispose();
  }

  // ---- product search ----
  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _hi = -1;
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
        if (mounted) {
          setState(() {
            _results = items;
            _hi = -1;
          });
        }
      } catch (_) {}
    });
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final open = _searching && _results.isNotEmpty;
    if (!open) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _hi = (_hi + 1).clamp(0, _results.length - 1));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _hi = (_hi - 1).clamp(0, _results.length - 1));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _results = const [];
        _searching = false;
        _hi = -1;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _onSearchSubmitted(String q) async {
    // Entrée sur un résultat surligné : on l'ajoute.
    if (_searching && _hi >= 0 && _hi < _results.length) {
      _addProduct(_results[_hi]);
      return;
    }
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
        if (exact.isNotEmpty) SystemSound.play(SystemSoundType.alert);
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
          _hi = items.isEmpty ? -1 : 0;
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
        await _quickCreate(code,
            lot: gs1.lot, expiry: gs1.expiry, qty: gs1.qty);
        return;
      }
      final p = match.first;
      SystemSound.play(SystemSoundType.alert);
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
        _hi = -1;
        _errors = {..._errors}..remove('lines');
      });
      _searchCtrl.clear();
      _searchFocus.requestFocus();
      if (!mounted) return;
      showToast(context,
          'GS1 : ${p.name} — lot ${gs1.lot ?? '—'}, DLC ${gs1.expiry ?? '—'}',
          kind: ToastKind.info);
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
      _hi = -1;
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
        unitPrice: cfg.isTransfer
            ? 0
            : cfg.isPurchase
                ? (_lastPrices[p.id] != null && packaging == null
                    ? _lastPrices[p.id]!
                    : p.purchasePrice)
                : p.unitPriceHT,
        discountPct: 0,
        vatRate: cfg.isTransfer ? 0 : p.vatRate,
        packaging: packaging,
        salePrice: cfg.isReception ? p.priceRetail : null,
      ));
      _results = const [];
      _searching = false;
      _hi = -1;
      _errors = {..._errors}..remove('lines');
    });
    _searchCtrl.clear();
    _searchFocus.requestFocus();
  }

  /// « + Ligne libre » : service, transport, frais… sans produit ni stock.
  Future<void> _addFreeLine() async {
    final r = await showDialog<_FreeLineResult>(
      context: context,
      builder: (_) => _FreeLineDialog(defaultVat: Features.instance.defaultVat),
    );
    if (r == null) return;
    setState(() {
      _lines.add(_EditLine(
        description: r.description,
        qtyMilli: r.qtyMilli,
        unitPrice: r.unitPrice,
        discountPct: 0,
        vatRate: r.vatRate,
      ));
      _errors = {..._errors}..remove('lines');
    });
  }

  void _removeLine(int i) {
    final l = _lines[i];
    setState(() => _lines.removeAt(i));
    _removed.add(l);
    showUndoToast(context, 'Ligne « ${l.description} » supprimée', undo: () {
      if (!mounted) return;
      setState(() {
        _removed.remove(l);
        _lines.insert(i.clamp(0, _lines.length), l);
      });
    });
  }

  // ---- totals (mirror server math) ----
  int get _totalHT => _lines.fold(0, (s, l) => s + l.lineHT);
  int get _totalVAT => _lines.fold(0, (s, l) => s + l.lineVAT);
  int get _totalQty => _lines.fold(0, (s, l) => s + l.qtyMilli);
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
    if (cost == null || l.productId == null) {
      return (newCmup: null, marginPct: null);
    }
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
      newCmup = roundDiv(
          now.$1 * now.$2 + l.baseUnits * cost, now.$1 + l.baseUnits);
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
  String? _trimOrNull(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Map<String, dynamic> _payload(
      {bool acceptShort = false, bool acceptOver = false}) {
    return {
      'doc_type': cfg.docType,
      'doc_date': _isoDate(_date),
      'partner_id': cfg.isTransfer ? null : _partner?.id,
      'warehouse_id': cfg.needsWarehouse ? _warehouseId : null,
      'dest_warehouse_id': cfg.isTransfer ? _destWarehouseId : null,
      'payment_method': cfg.hasPaymentMethod ? _paymentMethod : null,
      'ref_document_id': _refDocumentId,
      'supplier_ref': cfg.isPurchase &&
              !cfg.isTransfer &&
              _supplierRefCtrl.text.trim().isNotEmpty
          ? _supplierRefCtrl.text.trim()
          : null,
      'due_date': _hasDueDate && _dueDate != null ? _isoDate(_dueDate!) : null,
      'freight_cost': cfg.isReception ? _freight : 0,
      'notes': _trimOrNull(_notesCtrl),
      'internal_notes': _trimOrNull(_internalNotesCtrl),
      'accept_short_dated': acceptShort,
      'accept_over_receipt': acceptOver,
      'lines': [
        for (final l in _lines)
          {
            'product_id': l.productId,
            'description': l.description,
            'qty_milli': l.qtyMilli,
            'unit_price': cfg.isTransfer ? 0 : l.unitPrice,
            'discount_pct': cfg.isTransfer ? 0 : l.discountPct,
            'vat_rate': cfg.isTransfer ? 0 : l.vatRate,
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

  /// Field-level validation. Returns field → message (empty = OK).
  Map<String, String> _validate({required bool post}) {
    final e = <String, String>{};
    if (_lines.isEmpty) e['lines'] = 'Ajoutez au moins une ligne.';
    if (cfg.needsWarehouse && _warehouseId == null) {
      e['warehouse'] = 'Choisissez un dépôt.';
    }
    if (cfg.isTransfer) {
      if (_destWarehouseId == null) {
        e['dest'] = 'Choisissez le dépôt de destination.';
      } else if (_destWarehouseId == _warehouseId) {
        e['dest'] = 'Doit être différent du dépôt source.';
      }
    }
    final needPartner = !cfg.isTransfer &&
        (cfg.partnerRequired ||
            (cfg.hasPaymentMethod && _paymentMethod == 'credit'));
    if (needPartner && _partner == null) {
      e['partner'] = cfg.partnerKind == 'supplier'
          ? 'Le fournisseur est obligatoire.'
          : 'Une vente à crédit exige un client.';
    }
    if (post &&
        cfg.isSupplierInvoice &&
        _supplierRefCtrl.text.trim().isEmpty) {
      e['supplierRef'] = 'Le n° de facture du fournisseur est obligatoire.';
    }
    if (!e.containsKey('lines')) {
      final zero = _lines.where((l) => l.qtyMilli == 0 && l.qtyFreeMilli == 0);
      if (zero.isNotEmpty) {
        e['lines'] = 'Quantité nulle : « ${zero.first.description} ».';
      } else if (_lines.any((l) => l.discountPct < 0)) {
        e['lines'] = 'Remise négative refusée.';
      } else if (cfg.isReception) {
        for (final l in _lines) {
          final p = l.product;
          if (p == null) continue;
          if (p.trackLots && l.lotCtrl.text.trim().isEmpty) {
            e['lines'] = 'Le n° de lot est obligatoire pour « ${p.name} ».';
            break;
          }
          if (p.trackExpiry &&
              (l.expiryDate == null || l.expiryDate!.isEmpty)) {
            e['lines'] =
                'La date de péremption est obligatoire pour « ${p.name} ».';
            break;
          }
        }
      }
    }
    return e;
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
    return confirmAction(context,
        title: 'Vente à perte ?',
        message:
            'Prix de vente sous le coût de revient pour :\n• ${bad.join('\n• ')}',
        confirmLabel: 'Valider quand même',
        danger: true);
  }

  /// Saves the draft without leaving (needed before adding an attachment).
  Future<String?> _saveSilently() async {
    try {
      final payload = _payload();
      final d = _docId == null
          ? await widget.api.createDraft(payload)
          : await widget.api.updateDraft(_docId!, payload);
      _docId = d.id;
      _initialSig = _signature();
      return d.id;
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
      return null;
    }
  }

  Future<void> _save({required bool post}) async {
    final errs = _validate(post: post);
    setState(() => _errors = errs);
    if (errs.isNotEmpty) return;
    if (post && !await _confirmBelowCost()) return;
    setState(() => _busy = true);
    var acceptShort = false;
    var acceptOver = false;
    try {
      while (true) {
        final payload =
            _payload(acceptShort: acceptShort, acceptOver: acceptOver);
        final DocDetail draft = _docId == null
            ? await widget.api.createDraft(payload)
            : await widget.api.updateDraft(_docId!, payload);
        _docId = draft.id;
        if (!post) {
          if (!mounted) return;
          final nav = Navigator.of(context);
          showToast(context, 'Brouillon enregistré');
          nav.pop(true);
          return;
        }
        try {
          final posted = await widget.api.postDocument(draft.id);
          if (!mounted) return;
          final changed = posted.lines
              .where((l) => l.newSalePrice != null)
              .map((l) => l.description)
              .toList();
          showToast(
              context,
              cfg.isTransfer
                  ? '${posted.number}  ·  ${_lines.length} lignes transférées'
                  : '${posted.number}  ·  ${fmtDA(posted.totalTTC)}'
                      '${changed.isEmpty ? '' : '\nPrix de vente mis à jour : ${changed.join(', ')}'}');
          Navigator.of(context).pop(true);
          return;
        } on ApiException catch (e) {
          // Les acceptations explicites de la spec : courte durée de vie et
          // sur-réception. Refus propre → confirmation → revalidation.
          if (!mounted) return;
          if (e.message.contains('durée de vie') && !acceptShort) {
            final ok = await confirmAction(context,
                title: 'Durée de vie insuffisante',
                message: e.message,
                confirmLabel: 'Accepter le lot court');
            if (ok) {
              acceptShort = true;
              continue;
            }
            return;
          }
          if (e.message.contains('sur-réception') && !acceptOver) {
            final ok = await confirmAction(context,
                title: 'Sur-réception',
                message: e.message,
                confirmLabel: 'Accepter la sur-réception');
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
      _showServerError(e.message);
    } catch (e) {
      if (mounted) showToast(context, 'Erreur : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Routes a server refusal to the field it concerns when we can tell.
  void _showServerError(String msg) {
    if (!mounted) return;
    final m = msg.toLowerCase();
    String? field;
    if (m.contains('partner') || m.contains('partenaire')) {
      field = 'partner';
    } else if (m.contains('destination')) {
      field = 'dest';
    } else if (m.contains('warehouse') || m.contains('dépôt')) {
      field = 'warehouse';
    } else if (m.contains('n° fournisseur') || m.contains('facture en double')) {
      field = 'supplierRef';
    } else if (m.contains('lot') ||
        m.contains('péremption') ||
        m.contains('stock') ||
        m.contains('lines')) {
      field = 'lines';
    }
    if (field != null) {
      setState(() => _errors = {..._errors, field!: msg});
    } else {
      showToast(context, msg, kind: ToastKind.error);
    }
  }

  // ---- leaving with unsaved changes ----
  Future<void> _maybeLeave() async {
    if (_busy) return;
    if (_searching && _results.isNotEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        title: const Text('Enregistrer le brouillon ?', style: T.h2),
        content: Text(
            'Le document contient des modifications non enregistrées.',
            style: T.bodyMuted),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'stay'),
              child: const Text('Rester')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              style: TextButton.styleFrom(foregroundColor: T.dangerDark),
              child: const Text('Abandonner')),
          FilledButton(
              autofocus: true,
              style: FilledButton.styleFrom(
                  backgroundColor: T.mint, foregroundColor: T.ink),
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Enregistrer')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'discard') {
      Navigator.of(context).pop(_docId != null && widget.existing == null);
    } else if (choice == 'save') {
      await _save(post: false);
    }
  }

  // ---- attachments ----
  Future<void> _addAttachment() async {
    final path = pickFile('Tous les fichiers', '*.*');
    if (path == null) return;
    final file = File(path);
    final size = await file.length();
    if (size > 5 * 1024 * 1024) {
      if (mounted) {
        showToast(context, 'Fichier trop volumineux (5 Mo maximum).',
            kind: ToastKind.warning);
      }
      return;
    }
    final id = _docId ?? await _saveSilently();
    if (id == null) return;
    try {
      await widget.api.addDocumentAttachment(
          id, path.split(RegExp(r'[\\/]')).last, await file.readAsBytes());
      await _loadAttachments();
      if (mounted) showToast(context, 'Pièce jointe ajoutée');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _attachmentsMenu(BuildContext btnCtx) async {
    final box = btnCtx.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height));
    final choice = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: RelativeRect.fromRect(
          pos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final a in _attachments)
          PopupMenuItem<Object>(
            value: a,
            height: 36,
            child: Row(children: [
              const Icon(Icons.insert_drive_file_outlined,
                  size: 16, color: T.muted),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(a.name,
                      overflow: TextOverflow.ellipsis,
                      style: T.body.copyWith(fontSize: 13))),
              Text(fmtFileSize(a.size), style: T.monoSmall),
            ]),
          ),
        if (_attachments.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: 'add',
          height: 36,
          child: Row(children: [
            const Icon(Icons.add_rounded, size: 16, color: T.mintDark),
            const SizedBox(width: 8),
            Text(
                _docId == null
                    ? 'Ajouter un fichier (enregistre le brouillon)'
                    : 'Ajouter un fichier…',
                style: T.body.copyWith(fontSize: 13)),
          ]),
        ),
      ],
    );
    if (choice == 'add') {
      await _addAttachment();
    } else if (choice is DocAttachment && _docId != null && mounted) {
      await openAttachment(context, widget.api, _docId!, choice);
    }
  }

  // ---- pickers ----
  Future<void> _pickPartner() async {
    final p =
        await showPartnerPicker(context, widget.api, kind: cfg.partnerKind);
    if (p != null) {
      setState(() {
        _partner = p;
        _errors = {..._errors}..remove('partner');
      });
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
    if (d == null) return;
    setState(() {
      _date = d;
      final days = int.tryParse(_termCtrl.text.trim());
      if (_hasDueDate && days != null) {
        _dueDate = _dayOf(d).add(Duration(days: days));
      }
    });
  }

  Future<void> _pickDueDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? _date.add(const Duration(days: 30)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        _dueDate = d;
        _termCtrl.text = '${_dayOf(d).difference(_dayOf(_date)).inDays}';
      });
    }
  }

  void _onTermChanged(String v) {
    final days = int.tryParse(v.trim());
    setState(() {
      _dueDate = days == null ? null : _dayOf(_date).add(Duration(days: days));
    });
  }

  void _onPaymentChanged(String? v) {
    setState(() {
      _paymentMethod = v ?? 'cash';
      if (_paymentMethod == 'credit' && _dueDate == null) {
        final days = int.tryParse(_termCtrl.text.trim()) ??
            Features.instance.paymentTermDays;
        if (days > 0) {
          _termCtrl.text = '$days';
          _dueDate = _dayOf(_date).add(Duration(days: days));
        }
      }
      if (_paymentMethod != 'credit') _errors = {..._errors}..remove('partner');
    });
  }

  // ---- UI ----
  Widget _warehouseDropdown(String? value, ValueChanged<String?> onChanged,
      {String? exclude}) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _warehouses.any((w) => w.id == value) ? value : null,
        isDense: true,
        isExpanded: true,
        style: T.body,
        hint: Text('— choisir —', style: T.bodyMuted.copyWith(color: T.ghost)),
        icon: const Icon(Icons.expand_more, size: 15, color: T.faint),
        items: [
          for (final w in _warehouses)
            DropdownMenuItem(
                value: w.id,
                enabled: w.id != exclude,
                child: Text(w.name,
                    style: w.id == exclude
                        ? T.body.copyWith(color: T.ghost)
                        : T.body)),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _plainField(TextEditingController c, String hint,
          {ValueChanged<String>? onChanged, TextInputType? keyboard}) =>
      TextField(
        controller: c,
        onChanged: onChanged,
        keyboardType: keyboard,
        style: T.monoBody,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: T.monoSmall.copyWith(color: T.ghost),
          contentPadding: EdgeInsets.zero,
        ),
      );

  Widget _headerFields() {
    final partnerLabel =
        cfg.partnerKind == 'supplier' ? 'Fournisseur' : 'Client';
    final partnerNeeded = cfg.partnerRequired ||
        (cfg.hasPaymentMethod && _paymentMethod == 'credit');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HeaderField(
          label: 'Date',
          child: InkWell(
            onTap: _pickDate,
            child: Row(children: [
              const Icon(Icons.calendar_today_outlined,
                  size: 14, color: T.faint),
              const SizedBox(width: 8),
              Text(_frDate(_date), style: T.monoBody),
            ]),
          ),
        ),
        if (!cfg.isTransfer) ...[
          const SizedBox(width: 12),
          _HeaderField(
            label: partnerLabel + (partnerNeeded ? ' *' : ''),
            flex: 2,
            error: _errors['partner'],
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
                  Tooltip(
                    message: 'Retirer',
                    child: InkWell(
                      onTap: () => setState(() => _partner = null),
                      child: const Icon(Icons.close, size: 14, color: T.faint),
                    ),
                  ),
              ]),
            ),
          ),
        ],
        if (cfg.needsWarehouse) ...[
          const SizedBox(width: 12),
          _HeaderField(
            label: cfg.isTransfer ? 'Dépôt source *' : 'Dépôt',
            error: _errors['warehouse'],
            child: _warehouseDropdown(_warehouseId, (v) {
              setState(() {
                _warehouseId = v;
                _errors = {..._errors}..remove('warehouse');
              });
              if (cfg.isReception) _loadStockNow();
            }),
          ),
        ],
        if (cfg.isTransfer) ...[
          const SizedBox(width: 12),
          _HeaderField(
            label: 'Dépôt de destination *',
            error: _errors['dest'],
            child: _warehouseDropdown(
              _destWarehouseId,
              (v) => setState(() {
                _destWarehouseId = v;
                _errors = {..._errors}..remove('dest');
              }),
              exclude: _warehouseId,
            ),
          ),
        ],
        if (cfg.isPurchase &&
            (cfg.isReception || cfg.isSupplierInvoice)) ...[
          const SizedBox(width: 12),
          _HeaderField(
            label: cfg.isReception ? 'N° BL fournisseur' : 'N° facture *',
            error: _errors['supplierRef'],
            child: _plainField(
                _supplierRefCtrl, cfg.isReception ? 'BL-…' : 'FAC-…',
                onChanged: (_) {
              if (_errors.containsKey('supplierRef')) {
                setState(() => _errors = {..._errors}..remove('supplierRef'));
              }
            }),
          ),
        ],
        if (cfg.isReception) ...[
          const SizedBox(width: 12),
          _HeaderField(
            label: 'Frais (transport…)',
            child: _plainField(_freightCtrl, '0,00',
                onChanged: (_) => setState(() {})),
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
                icon: const Icon(Icons.expand_more, size: 15, color: T.faint),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Espèces')),
                  DropdownMenuItem(value: 'credit', child: Text('Crédit')),
                  DropdownMenuItem(value: 'cib', child: Text('Carte CIB')),
                  DropdownMenuItem(value: 'cheque', child: Text('Chèque')),
                  DropdownMenuItem(value: 'transfer', child: Text('Virement')),
                ],
                onChanged: _onPaymentChanged,
              ),
            ),
          ),
        ],
        if (_hasDueDate) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 104,
            child: _HeaderFieldBox(
              label: 'Échéance (jours)',
              child: _plainField(_termCtrl, '30',
                  onChanged: _onTermChanged,
                  keyboard: TextInputType.number),
            ),
          ),
          const SizedBox(width: 12),
          _HeaderField(
            label: 'Échéance',
            child: InkWell(
              onTap: _pickDueDate,
              child: Row(children: [
                const Icon(Icons.event_outlined, size: 14, color: T.faint),
                const SizedBox(width: 8),
                Text(_dueDate == null ? '— aucune —' : _frDate(_dueDate!),
                    style: _dueDate == null
                        ? T.bodyMuted.copyWith(color: T.ghost)
                        : T.monoBody),
              ]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _notesSection() {
    if (!_showNotes) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _showNotes = true),
          icon: const Icon(Icons.notes_rounded, size: 15, color: T.muted),
          label: Text('Notes', style: T.small.copyWith(color: T.muted)),
        ),
      );
    }
    Widget box(String label, TextEditingController c, String hint) => Expanded(
          child: _HeaderFieldBox(
            label: label,
            height: 64,
            child: TextField(
              controller: c,
              maxLines: 2,
              style: T.body.copyWith(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: T.small.copyWith(color: T.ghost),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(children: [
        if (!cfg.isTransfer) ...[
          box('Note (imprimée)', _notesCtrl,
              'Conditions, référence client… — figure sur le PDF'),
          const SizedBox(width: 12),
        ],
        box('Note interne', _internalNotesCtrl,
            'Jamais imprimée — visible seulement ici'),
      ]),
    );
  }

  Widget _linesHeader() {
    if (cfg.isTransfer) {
      return const Row(children: [
        Expanded(flex: 5, child: MicroLabel('Produit')),
        SizedBox(width: 120, child: MicroLabel('Quantité')),
        SizedBox(width: 34),
      ]);
    }
    if (cfg.isReception) {
      return const Row(children: [
        Expanded(flex: 4, child: MicroLabel('Produit')),
        SizedBox(width: 92, child: MicroLabel('Unité')),
        SizedBox(width: 70, child: MicroLabel('Qté')),
        SizedBox(width: 70, child: MicroLabel('Gratuit')),
        SizedBox(width: 100, child: MicroLabel('Coût HT')),
        SizedBox(width: 62, child: MicroLabel('Rem. %')),
        SizedBox(width: 64, child: MicroLabel('TVA')),
        SizedBox(
            width: 104,
            child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: MicroLabel('Total TTC'))),
        SizedBox(width: 34),
      ]);
    }
    return Row(children: [
      const Expanded(flex: 5, child: MicroLabel('Produit')),
      const SizedBox(width: 86, child: MicroLabel('Qté')),
      SizedBox(
          width: 110,
          child: MicroLabel(cfg.isPurchase ? 'Coût HT' : 'PU HT')),
      const SizedBox(width: 70, child: MicroLabel('Rem. %')),
      const SizedBox(width: 70, child: MicroLabel('TVA')),
      const SizedBox(
          width: 110,
          child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: MicroLabel('Total TTC'))),
      const SizedBox(width: 34),
    ]);
  }

  Widget _lineRow(int i) {
    final l = _lines[i];
    void changed() => setState(() {
          if (_errors.containsKey('lines')) {
            _errors = {..._errors}..remove('lines');
          }
        });
    if (cfg.isTransfer) {
      return _TransferLineRow(
          line: l, onChanged: changed, onRemove: () => _removeLine(i));
    }
    if (cfg.isReception && !l.isFree) {
      return _ReceptionLineRow(
        line: l,
        margin: _lineMargin(l),
        suggested: _suggestedPrice(l),
        variance: _costVariance(l),
        lastPrice: l.productId == null ? null : _lastPrices[l.productId],
        onChanged: changed,
        onRemove: () => _removeLine(i),
        onPickExpiry: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: DateTime.tryParse(l.expiryDate ?? '') ??
                DateTime.now().add(const Duration(days: 365)),
            firstDate: DateTime(2020),
            lastDate: DateTime(2100),
          );
          if (d != null) setState(() => l.expiryDate = _isoDate(d));
        },
      );
    }
    return _LineRow(line: l, onChanged: changed, onRemove: () => _removeLine(i));
  }

  Widget _totalsBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, -2)),
        ],
      ),
      child: Row(
        children: [
          MicroLabel(
              '${_lines.length} ligne${_lines.length > 1 ? 's' : ''}'),
          if (cfg.isReception && _freight > 0) ...[
            const SizedBox(width: 16),
            MintChip('Frais ${fmtDA(_freight)} répartis',
                color: T.cream, fg: T.faint),
          ],
          const Spacer(),
          if (cfg.isTransfer) ...[
            const MicroLabel('Quantité totale'),
            const SizedBox(width: 10),
            Text(fmtQty(_totalQty), style: T.monoBig),
          ] else ...[
            _Total('HT', _totalHT),
            _Total('TVA', _totalVAT),
            if (_timbre > 0) _Total('Timbre', _timbre),
            const SizedBox(width: 22),
            Text(fmtDA(_totalTTC), style: T.monoBig),
          ],
          const SizedBox(width: 24),
          SizedBox(
            width: 140,
            height: 42,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _refDocNumber != null
        ? (widget.receiveFrom != null
            ? 'Réception de $_refDocNumber'
            : 'Depuis $_refDocNumber')
        : widget.existing?.number ??
            (_docId != null ? 'Brouillon' : 'Nouveau document');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybeLeave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _maybeLeave,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (!_busy) _save(post: false);
          },
        },
        child: Scaffold(
          backgroundColor: T.bg,
          body: Column(
            children: [
              // ---- Top bar ----
              Container(
                color: T.surface,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Retour (Échap)',
                      onPressed: _busy ? null : _maybeLeave,
                      icon: const Icon(Icons.arrow_back,
                          size: 20, color: T.muted),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(cfg.title, style: T.h2),
                          Text(subtitle, style: T.monoSmall),
                        ],
                      ),
                    ),
                    Builder(
                      builder: (btnCtx) => Tooltip(
                        message: _attachments.isEmpty
                            ? 'Pièces jointes'
                            : '${_attachments.length} pièce(s) jointe(s)',
                        child: TextButton.icon(
                          onPressed:
                              _busy ? null : () => _attachmentsMenu(btnCtx),
                          icon: const Icon(Icons.attach_file_rounded,
                              size: 17, color: T.muted),
                          label: Text(
                              _attachments.isEmpty
                                  ? 'Joindre'
                                  : '${_attachments.length}',
                              style: T.small.copyWith(
                                  color: T.muted,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              // ---- Header fields ----
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Column(children: [
                  _headerFields(),
                  _notesSection(),
                ]),
              ),
              // ---- Add product ----
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Column(
                  children: [
                    Row(children: [
                      Expanded(
                        child: Focus(
                          onKeyEvent: _onSearchKey,
                          skipTraversal: true,
                          child: SearchField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                            autofocus: true,
                            hint: cfg.isReception
                                ? 'Scanner (EAN-13 ou GS1-128) ou rechercher — code inconnu = création en ligne'
                                : 'Ajouter un produit — scanner ou rechercher… (↑ ↓ Entrée)',
                            onChanged: _onQueryChanged,
                            onSubmitted: _onSearchSubmitted,
                          ),
                        ),
                      ),
                      if (!cfg.isTransfer) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 42,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: T.border),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(T.rInner)),
                            ),
                            onPressed: _addFreeLine,
                            icon: const Icon(Icons.add_rounded,
                                size: 16, color: T.muted),
                            label: Text('Ligne libre',
                                style: T.small.copyWith(
                                    color: T.ink,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ]),
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
                              child: Container(
                                color: i == _hi ? T.mintTint : null,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 9),
                                child: Row(children: [
                                  Expanded(child: Text(p.name, style: T.body)),
                                  if (!cfg.isTransfer)
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_errors['lines'] != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: FieldError(_errors['lines']),
                        ),
                      Expanded(
                        child: Container(
                          decoration: _errors['lines'] != null
                              ? BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(T.rCard),
                                  border: Border.all(color: T.danger))
                              : null,
                          child: Card14(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(
                                      14, 10, 14, 8),
                                  child: _linesHeader(),
                                ),
                                const Divider(),
                                Expanded(
                                  child: _lines.isEmpty
                                      ? EmptyState(
                                          icon: Icons.playlist_add,
                                          text:
                                              'Aucune ligne.\nScannez ou recherchez un produit ci-dessus.',
                                          actions: [
                                            if (!cfg.isTransfer)
                                              ('Ligne libre', _addFreeLine),
                                          ],
                                        )
                                      : ListView.separated(
                                          itemCount: _lines.length,
                                          separatorBuilder: (_, _) =>
                                              const Divider(),
                                          itemBuilder: (context, i) =>
                                              _lineRow(i),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---- Sticky totals + actions ----
              _totalsBar(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Human file size (« 1,2 Mo »).
String fmtFileSize(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} Mo';
}

/// Downloads an attachment to the temp folder and opens it with the
/// default Windows application.
Future<void> openAttachment(BuildContext context, ApiClient api, String docId,
    DocAttachment a) async {
  try {
    final bytes = await api.documentAttachmentBytes(docId, a.id);
    final dir = Directory(
        '${Directory.systemTemp.path}\\elixir_pieces\\${a.id.substring(0, 8)}');
    await dir.create(recursive: true);
    final safe = a.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final f = File('${dir.path}\\$safe');
    await f.writeAsBytes(bytes);
    await Process.run('cmd', ['/c', 'start', '', f.path]);
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Ouverture impossible : $e', kind: ToastKind.error);
    }
  }
}

/// Labelled box of the header row (fixed height), with an optional error
/// shown under it and an outlined red border.
class _HeaderField extends StatelessWidget {
  const _HeaderField(
      {required this.label, required this.child, this.error, this.flex = 1});
  final String label;
  final Widget child;
  final String? error;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: _HeaderFieldBox(label: label, error: error, child: child),
    );
  }
}

class _HeaderFieldBox extends StatelessWidget {
  const _HeaderFieldBox(
      {required this.label, required this.child, this.error, this.height = 54});
  final String label;
  final Widget child;
  final String? error;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(
                color: error != null ? T.danger : T.border,
                width: error != null ? 1.4 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MicroLabel(label),
              const SizedBox(height: 3),
              Expanded(
                  child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: child)),
            ],
          ),
        ),
        FieldError(error),
      ],
    );
  }
}

/// TVA selectable per line: 19 / 9 / 0 % (plus the line's own rate if other).
class _VatDropdown extends StatelessWidget {
  const _VatDropdown({required this.line, required this.onChanged});
  final _EditLine line;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final rates = {1900, 900, 0, line.vatRate}.toList();
    return DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        value: line.vatRate,
        isDense: true,
        style: T.monoSmall.copyWith(color: T.ink),
        icon: const Icon(Icons.expand_more, size: 13, color: T.faint),
        items: [
          for (final r in rates)
            DropdownMenuItem(value: r, child: Text('${r ~/ 100}%')),
        ],
        onChanged: (v) {
          if (v == null) return;
          line.vatRate = v;
          onChanged();
        },
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
          child: Row(children: [
            Flexible(
              child: Text(line.description,
                  style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (line.isFree) ...[
              const SizedBox(width: 6),
              const Tooltip(
                message: 'Ligne libre : ni produit ni mouvement de stock',
                child: MintChip('libre', color: T.cream, fg: T.faint),
              ),
            ],
          ]),
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
            width: 70, child: _VatDropdown(line: line, onChanged: onChanged)),
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

/// Transfer line: product + quantity only (the cost follows the source
/// depot's weighted average).
class _TransferLineRow extends StatelessWidget {
  const _TransferLineRow(
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
            width: 120,
            child: _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
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
              width: 64, child: _VatDropdown(line: line, onChanged: onChanged)),
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
              child:
                  _CellField(controller: line.saleCtrl, onChanged: onChanged)),
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

// ---------------- « + Ligne libre » ----------------

class _FreeLineResult {
  const _FreeLineResult(
      this.description, this.qtyMilli, this.unitPrice, this.vatRate);
  final String description;
  final int qtyMilli;
  final int unitPrice;
  final int vatRate;
}

class _FreeLineDialog extends StatefulWidget {
  const _FreeLineDialog({required this.defaultVat});
  final int defaultVat;

  @override
  State<_FreeLineDialog> createState() => _FreeLineDialogState();
}

class _FreeLineDialogState extends State<_FreeLineDialog> {
  final _desc = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _price = TextEditingController();
  late int _vat = {1900, 900, 0}.contains(widget.defaultVat)
      ? widget.defaultVat
      : 1900;
  Map<String, String> _err = const {};

  @override
  void dispose() {
    _desc.dispose();
    _qty.dispose();
    _price.dispose();
    super.dispose();
  }

  void _ok() {
    final e = <String, String>{};
    final q = parseQty(_qty.text);
    final p = parseDA(_price.text);
    if (_desc.text.trim().isEmpty) e['desc'] = 'La description est obligatoire.';
    if (q == null || q <= 0) e['qty'] = 'Quantité invalide.';
    if (p == null || p < 0) e['price'] = 'Prix invalide.';
    if (e.isNotEmpty) {
      setState(() => _err = e);
      return;
    }
    Navigator.of(context).pop(_FreeLineResult(_desc.text.trim(), q!, p!, _vat));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: const Text('Ligne libre', style: T.h2),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Service, transport, frais… — sans produit ni mouvement de stock.',
                style: T.small),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              autofocus: true,
              style: T.body,
              decoration: InputDecoration(
                  labelText: 'Description *',
                  errorText: _err['desc']),
              onSubmitted: (_) => _ok(),
            ),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  style: T.body,
                  decoration: InputDecoration(
                      labelText: 'Quantité', errorText: _err['qty']),
                  onSubmitted: (_) => _ok(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _price,
                  style: T.body,
                  decoration: InputDecoration(
                      labelText: 'Prix unitaire HT', errorText: _err['price']),
                  onSubmitted: (_) => _ok(),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: DropdownButton<int>(
                  value: _vat,
                  items: const [
                    DropdownMenuItem(value: 1900, child: Text('TVA 19%')),
                    DropdownMenuItem(value: 900, child: Text('TVA 9%')),
                    DropdownMenuItem(value: 0, child: Text('TVA 0%')),
                  ],
                  onChanged: (v) => setState(() => _vat = v ?? 1900),
                ),
              ),
            ]),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(label: 'Ajouter', onPressed: _ok),
      ],
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
            Text(
                'Code-barres ${widget.barcode} — créez-le sans quitter la réception.',
                style: T.small.copyWith(height: 1.4)),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              style: T.body,
              decoration: InputDecoration(
                  labelText: 'Désignation *', errorText: _error),
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
                value: {0, 900, 1900}.contains(_vat) ? _vat : 1900,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('TVA 0%')),
                  DropdownMenuItem(value: 900, child: Text('TVA 9%')),
                  DropdownMenuItem(value: 1900, child: Text('TVA 19%')),
                ],
                onChanged: (v) => setState(() => _vat = v ?? 1900),
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
            label: _busy ? '…' : 'Créer et ajouter',
            onPressed: _busy ? null : _create),
      ],
    );
  }
}

// ---------------- Partner picker ----------------

/// Shared partner picker dialog (search + list, ↑ ↓ Entrée, « + Nouveau
/// client / fournisseur »). Returns the chosen — or just created — partner.
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
  final _scroll = ScrollController();
  Timer? _debounce;
  List<Partner> _items = const [];
  bool _loading = true;
  int _hi = 0;

  String get _newLabel =>
      widget.kind == 'supplier' ? 'Nouveau fournisseur' : 'Nouveau client';

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load(String q) async {
    try {
      final items = await widget.api.partners(q: q, kind: widget.kind);
      if (mounted) {
        setState(() {
          _items = items;
          _hi = 0;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _move(int delta) {
    if (_items.isEmpty) return;
    setState(() => _hi = (_hi + delta).clamp(0, _items.length - 1));
    if (_scroll.hasClients) {
      const h = 58.0;
      final top = _hi * h;
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top);
      } else if (top + h > _scroll.offset + view) {
        _scroll.jumpTo(
            (top + h - view).clamp(0, _scroll.position.maxScrollExtent));
      }
    }
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _create() async {
    final p = await showDialog<Partner>(
      context: context,
      builder: (_) => PartnerQuickCreateDialog(
          api: widget.api,
          kind: widget.kind == 'supplier' ? 'supplier' : 'customer',
          initialName: _ctrl.text.trim()),
    );
    if (p != null && mounted) Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 440,
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Focus(
                onKeyEvent: _onKey,
                skipTraversal: true,
                child: SearchField(
                  controller: _ctrl,
                  autofocus: true,
                  hint: widget.kind == 'supplier'
                      ? 'Rechercher un fournisseur… (↑ ↓ Entrée)'
                      : 'Rechercher un client… (↑ ↓ Entrée)',
                  onChanged: (q) {
                    _debounce?.cancel();
                    _debounce = Timer(
                        const Duration(milliseconds: 250), () => _load(q));
                  },
                  onSubmitted: (_) {
                    if (_items.isNotEmpty) {
                      Navigator.of(context)
                          .pop(_items[_hi.clamp(0, _items.length - 1)]);
                    }
                  },
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: _items.isEmpty
                  ? EmptyState(
                      icon: Icons.person_search,
                      text: _loading ? 'Chargement…' : 'Aucun résultat',
                      actions: [
                        if (!_loading) ('+ $_newLabel', _create),
                      ],
                    )
                  : ListView.separated(
                      controller: _scroll,
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = _items[i];
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(p),
                          child: Container(
                            height: 57,
                            color: i == _hi ? T.mintTint : null,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(children: [
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.name,
                                        style: T.body,
                                        overflow: TextOverflow.ellipsis),
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
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(children: [
                TextButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add_rounded,
                      size: 16, color: T.mintDark),
                  label: Text(_newLabel,
                      style: T.small.copyWith(
                          color: T.mintDark, fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minimal partner creation (Nom*, Téléphone, NIF, Adresse) with errors
/// under each field. Returns the created partner.
class PartnerQuickCreateDialog extends StatefulWidget {
  const PartnerQuickCreateDialog(
      {super.key, required this.api, required this.kind, this.initialName = ''});
  final ApiClient api;
  final String kind; // customer | supplier
  final String initialName;

  @override
  State<PartnerQuickCreateDialog> createState() =>
      _PartnerQuickCreateDialogState();
}

class _PartnerQuickCreateDialogState extends State<PartnerQuickCreateDialog> {
  late final _name = TextEditingController(
      text: RegExp(r'^[\d\s+]+$').hasMatch(widget.initialName)
          ? ''
          : widget.initialName);
  late final _phone = TextEditingController(
      text: RegExp(r'^[\d\s+]+$').hasMatch(widget.initialName)
          ? widget.initialName
          : '');
  final _nif = TextEditingController();
  final _address = TextEditingController();
  Map<String, String> _err = const {};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _nif, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final e = partnerFieldErrors(
        name: _name.text, phone: _phone.text, nif: _nif.text);
    setState(() => _err = e);
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    String? v(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final p = await widget.api.savePartner({
        'kind': widget.kind,
        'name': _name.text.trim(),
        'phone': v(_phone),
        'nif': v(_nif),
        'address': v(_address),
        'price_level': 'retail',
      });
      if (mounted) Navigator.of(context).pop(p);
    } on ApiException catch (ex) {
      setState(() {
        _busy = false;
        _err = {
          ex.message.toLowerCase().contains('name') ? 'name' : 'form':
              ex.message
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final supplier = widget.kind == 'supplier';
    InputDecoration deco(String label, String key) =>
        InputDecoration(labelText: label, errorText: _err[key]);
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(supplier ? 'Nouveau fournisseur' : 'Nouveau client',
          style: T.h2),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: _name,
                autofocus: true,
                style: T.body,
                decoration: deco('Nom / Raison sociale *', 'name'),
                onSubmitted: (_) => _save()),
            const SizedBox(height: 6),
            TextField(
                controller: _phone,
                style: T.body,
                decoration: deco('Téléphone', 'phone'),
                onSubmitted: (_) => _save()),
            const SizedBox(height: 6),
            TextField(
                controller: _nif,
                style: T.body,
                decoration: deco('NIF', 'nif'),
                onSubmitted: (_) => _save()),
            const SizedBox(height: 6),
            TextField(
                controller: _address,
                style: T.body,
                decoration: deco('Adresse', 'address'),
                onSubmitted: (_) => _save()),
            if (_err['form'] != null) FieldError(_err['form']),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : 'Créer', onPressed: _busy ? null : _save),
      ],
    );
  }
}

/// Field-level checks shared by the partner forms. Returns field → message.
Map<String, String> partnerFieldErrors(
    {required String name, String phone = '', String nif = ''}) {
  final e = <String, String>{};
  if (name.trim().isEmpty) e['name'] = 'Le nom est obligatoire.';
  final ph = phone.replaceAll(RegExp(r'[\s.\-]'), '');
  if (ph.isNotEmpty && !RegExp(r'^\+?\d{9,13}$').hasMatch(ph)) {
    e['phone'] = 'Numéro invalide (ex. 0550 12 34 56).';
  }
  final n = nif.replaceAll(' ', '');
  if (n.isNotEmpty && !RegExp(r'^\d{15,20}$').hasMatch(n)) {
    e['nif'] = 'Le NIF compte 15 à 20 chiffres.';
  }
  return e;
}
