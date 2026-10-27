import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../screens/documents/doc_detail_page.dart' show DocDetailPage;
import '../theme/tokens.dart';
import '../util/approval.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import '../util/gs1.dart';
import 'app_page.dart';
import 'doc_list.dart' show docModuleLabel;
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

  /// Transfer between depots: no partner, quantities only.
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
// The supplier is mandatory when posting a receipt: without it there is
// no purchase history, no price comparison, no account.
const purchaseReceiptConfig = DocEditorConfig(
    docType: 'PURCHASE_RECEIPT',
    title: 'Bon de réception',
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
// Transfer between depots: no partner, source + destination depot,
// quantities only (the cost follows the source depot's weighted average cost).
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
  final Product? product; // carries lot/expiry tracking, packagings, current price
  final String description;
  final TextEditingController qtyCtrl;
  final TextEditingController priceCtrl;
  final TextEditingController discCtrl;
  final TextEditingController freeCtrl;
  final TextEditingController lotCtrl;
  final TextEditingController saleCtrl;
  String? expiryDate; // YYYY-MM-DD
  Packaging? packaging; // null = base unit
  int vatRate;

  /// Free line (service, transport…): no product, no stock.
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

  /// Base units entering stock (qty + free units, converted by the pack).
  int get baseUnits => roundDiv((qtyMilli + qtyFreeMilli) * packFactor, 1000);

  /// Effective cost per base unit: the net excl. VAT diluted by the free units.
  /// THE figure that keeps the margin honest (79.17, not 100).
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

  /// Purchase order to receive: pre-fills the lines with the outstanding quantity
  /// and links the receipt (tracking of partial receipts).
  final DocDetail? receiveFrom;

  /// New document pre-filled from another one (Dupliquer, Convertir en…):
  /// partner, lines and notes carried over, today's date.
  final DocDetail? copyFrom;

  /// With [copyFrom]: the new document references the original
  /// (quote → invoice, delivery note → invoice: stock does not go out twice).
  final bool linkToCopy;

  /// Pre-selected partner (« Nouvelle facture » from Partners).
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
  int _hi = -1; // result highlighted with the keyboard

  final List<_EditLine> _lines = [];
  final List<_EditLine> _removed = []; // kept for « Annuler », released at the end
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

  /// Server-side id of the draft, as soon as it exists.
  String? _docId;
  List<DocAttachment> _attachments = const [];

  /// Errors per field (partner, warehouse, dest, supplierRef, lines).
  Map<String, String> _errors = const {};

  /// Fingerprint of the document when opened: used to detect changes.
  String? _initialSig;

  /// Last price paid to this supplier, per product (cost variance).
  Map<String, int> _lastPrices = const {};

  /// Current stock and weighted average cost per product — for the live « nouveau CMUP » margin.
  final Map<String, (int, int)> _stockNow = {}; // productId -> (qty, avg)

  int _targetMarginPct = 3000; // target margin (pct x100) for the suggested price

  DocEditorConfig get cfg => widget.config;

  /// Proposed due date: credit invoices and supplier invoices.
  bool get _hasDueDate =>
      cfg.isSupplierInvoice ||
      (cfg.isSaleInvoice && cfg.hasPaymentMethod && _paymentMethod == 'credit');

  @override
  void initState() {
    super.initState();
    _docId = widget.existing?.id;
    _init();
    // The page frame also autofocuses (for Escape): the scanner field wins.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
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
      // Reload the lines' products to recover lot tracking/packagings.
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

    // Receiving a purchase order: outstanding quantity pre-filled, link kept.
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

    // Default payment term (Paramètres → payment_term_days).
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
    // A duplicated/converted document is not saved yet: it counts
    // as modified from the moment it opens.
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
        // same depot: one line per product, otherwise keep the first one
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
    // Enter on a highlighted result: add it.
    if (_searching && _hi >= 0 && _hi < _results.length) {
      _addProduct(_results[_hi]);
      return;
    }
    final raw = q.trim();
    if (raw.isEmpty) return;

    // GS1-128: one scan fills product, lot, expiry date and quantity.
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
        // The carton's barcode pre-selects the packaging.
        Packaging? pack;
        final hit = pick.packagings.where((k) => k.barcode == raw);
        if (hit.isNotEmpty) pack = hit.first;
        if (exact.isNotEmpty) SystemSound.play(SystemSoundType.alert);
        _addProduct(pick, packaging: pack);
        return;
      }
      if (items.isEmpty && RegExp(r'^\d{6,14}$').hasMatch(raw)) {
        // Unknown barcode: inline creation, without leaving the receipt.
        // The highest-friction moment of the whole flow — spec §7.2.
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
      // Search by the last 13 significant digits of the GTIN.
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
          'Code GS1 : ${p.name} — lot ${gs1.lot ?? '—'}, péremption ${gs1.expiry ?? '—'}',
          kind: ToastKind.info);
    } catch (_) {}
  }

  /// Quick creation of an unknown product in the middle of a receipt.
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
    // Sale to a customer in a group: the group's price tier (semi-wholesale) and discount.
    final sale = !cfg.isPurchase && !cfg.isTransfer && cfg.partnerKind == 'customer';
    final wholesale = sale &&
        _partner?.effectivePriceLevel == 'wholesale' &&
        p.priceWholesale != null &&
        Features.instance.wholesale;
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
                : wholesale
                    ? roundDiv(p.priceWholesale! * 10000, 10000 + p.vatRate)
                    : p.unitPriceHT,
        discountPct: sale ? (_partner?.groupDiscountPct ?? 0) : 0,
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

  /// « + Ligne libre »: service, transport, fees… with no product or stock.
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

  /// Live margin of a receipt line against the NEW weighted average cost, free
  /// units and fees included — the figure that makes you think before posting.
  ({int? newCmup, int? marginPct}) _lineMargin(_EditLine l) {
    var cost = l.effectiveCost;
    if (cost == null || l.productId == null) {
      return (newCmup: null, marginPct: null);
    }
    // Landed costs prorated by value.
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
    // PV_HT = PV_TTC / (1 + tva) — never a VAT-inclusive margin against a cost excl. VAT.
    final pvHT = roundDiv(sale * 10000, 10000 + l.vatRate);
    return (
      newCmup: newCmup,
      marginPct: roundDiv((pvHT - newCmup) * 10000, newCmup)
    );
  }

  /// Suggested price: new weighted average cost × (1 + target margin) × (1 + VAT). Never
  /// applied on its own — one tap accepts it.
  int? _suggestedPrice(_EditLine l) {
    final m = _lineMargin(l);
    if (m.newCmup == null || m.newCmup! <= 0) return null;
    final ht = roundDiv(m.newCmup! * (10000 + _targetMarginPct), 10000);
    final ttc = roundDiv(ht * (10000 + l.vatRate), 10000);
    // Sale-price rounding from Settings (5 / 10 DA), otherwise to the dinar.
    if (Features.instance.priceRounding > 0) return Features.instance.roundPrice(ttc);
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

  /// A sale price below the new weighted average cost warns, does not block.
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
        if (!mounted) return;
        // Discount / date / credit note without the right → « Code du gérant » (approval.dart).
        final DocDetail draft = await withApproval(
            context,
            widget.api,
            () => _docId == null
                ? widget.api.createDraft(payload)
                : widget.api.updateDraft(_docId!, payload));
        _docId = draft.id;
        // Next step offered by the toast: open the saved document (not when
        // we came from its own page — that page reloads by itself).
        if (!mounted) return;
        final nav = Navigator.of(context);
        final offerOpen = widget.existing == null;
        void openSaved(String id) => nav.push(MaterialPageRoute<bool>(
            builder: (_) => DocDetailPage(api: widget.api, docId: id)));
        if (!post) {
          if (!mounted) return;
          showToast(context, 'Brouillon enregistré',
              actionLabel: offerOpen ? 'Ouvrir' : null,
              onAction: offerOpen ? () => openSaved(draft.id) : null);
          nav.pop(true);
          return;
        }
        try {
          final posted = await withApproval(
              context, widget.api, () => widget.api.postDocument(draft.id));
          if (!mounted) return;
          final changed = posted.lines
              .where((l) => l.newSalePrice != null)
              .map((l) => l.description)
              .toList();
          showToast(
              context,
              cfg.isTransfer
                  ? '${posted.number} validé  ·  ${_lines.length} lignes transférées'
                  : '${posted.number} validé  ·  ${fmtDA(posted.totalTTC)}'
                      '${changed.isEmpty ? '' : '\nPrix de vente mis à jour : ${changed.join(', ')}'}',
              actionLabel: offerOpen ? 'Ouvrir' : null,
              onAction: offerOpen ? () => openSaved(posted.id) : null);
          nav.pop(true);
          return;
        } on ApiException catch (e) {
          // The explicit acceptances of the spec: short shelf life and
          // over-receipt. Clean refusal → confirmation → revalidation.
          if (!mounted) return;
          if (e.message.contains('durée de vie') && !acceptShort) {
            final ok = await confirmAction(context,
                title: 'Date de péremption trop proche',
                message: e.message,
                confirmLabel: 'Accepter ce lot quand même');
            if (ok) {
              acceptShort = true;
              continue;
            }
            return;
          }
          if (e.message.contains('sur-réception') && !acceptOver) {
            final ok = await confirmAction(context,
                title: 'Plus de marchandise que commandé',
                message: e.message,
                confirmLabel: 'Accepter quand même');
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
                      style: T.body.copyWith(fontSize: 14))),
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
                style: T.body.copyWith(fontSize: 14)),
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
        hint: Text('Choisir…', style: T.bodyMuted),
        icon: const Icon(Icons.expand_more, size: 18, color: T.faint),
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
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _HeaderField(
          label: 'Date',
          required: true,
          width: 170,
          onTap: _pickDate,
          child: Row(children: [
            const Icon(Icons.calendar_today_outlined, size: 16, color: T.faint),
            const SizedBox(width: 8),
            Text(_frDate(_date), style: T.monoBody),
          ]),
        ),
        if (!cfg.isTransfer)
          _HeaderField(
            label: partnerLabel,
            required: partnerNeeded,
            width: 320,
            error: _errors['partner'],
            onTap: _pickPartner,
            child: Row(children: [
              Icon(
                  cfg.partnerKind == 'supplier'
                      ? Icons.local_shipping_outlined
                      : Icons.person_outline,
                  size: 17,
                  color: T.faint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    _partner?.name ??
                        (cfg.partnerKind == 'supplier'
                            ? 'Choisir un fournisseur…'
                            : 'Choisir un client…'),
                    overflow: TextOverflow.ellipsis,
                    style: _partner == null ? T.bodyMuted : T.body),
              ),
              if (_partner != null)
                Tooltip(
                  message: 'Retirer',
                  child: InkWell(
                    onTap: () => setState(() => _partner = null),
                    child: const Icon(Icons.close, size: 17, color: T.faint),
                  ),
                ),
            ]),
          ),
        if (cfg.needsWarehouse)
          _HeaderField(
            label: cfg.isTransfer ? 'Dépôt de départ' : 'Dépôt',
            required: true,
            width: 220,
            error: _errors['warehouse'],
            child: _warehouseDropdown(_warehouseId, (v) {
              setState(() {
                _warehouseId = v;
                _errors = {..._errors}..remove('warehouse');
              });
              if (cfg.isReception) _loadStockNow();
            }),
          ),
        if (cfg.isTransfer)
          _HeaderField(
            label: 'Dépôt d’arrivée',
            required: true,
            width: 220,
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
        if (cfg.isPurchase && (cfg.isReception || cfg.isSupplierInvoice))
          _HeaderField(
            label: cfg.isReception
                ? 'N° du bon de livraison fournisseur'
                : 'N° de la facture fournisseur',
            required: cfg.isSupplierInvoice,
            width: 260,
            error: _errors['supplierRef'],
            child: _plainField(
                _supplierRefCtrl, cfg.isReception ? 'Ex. BL-1234' : 'Ex. FAC-1234',
                onChanged: (_) {
              if (_errors.containsKey('supplierRef')) {
                setState(() => _errors = {..._errors}..remove('supplierRef'));
              }
            }),
          ),
        if (cfg.isReception)
          _HeaderField(
            label: 'Frais (transport…) en DA',
            width: 200,
            child: _plainField(_freightCtrl, '0,00',
                onChanged: (_) => setState(() {})),
          ),
        if (cfg.hasPaymentMethod)
          _HeaderField(
            label: 'Paiement',
            width: 190,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _paymentMethod,
                isDense: true,
                isExpanded: true,
                style: T.body,
                icon: const Icon(Icons.expand_more, size: 18, color: T.faint),
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
        if (_hasDueDate) ...[
          _HeaderField(
            label: 'Délai de paiement (jours)',
            width: 190,
            child: _plainField(_termCtrl, '30',
                onChanged: _onTermChanged, keyboard: TextInputType.number),
          ),
          _HeaderField(
            label: 'Échéance',
            width: 170,
            onTap: _pickDueDate,
            child: Row(children: [
              const Icon(Icons.event_outlined, size: 16, color: T.faint),
              const SizedBox(width: 8),
              Text(_dueDate == null ? 'Aucune' : _frDate(_dueDate!),
                  style: _dueDate == null ? T.bodyMuted : T.monoBody),
            ]),
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
          icon: const Icon(Icons.notes_rounded, size: 18, color: T.muted),
          label: Text('Ajouter une note',
              style: T.body.copyWith(color: T.muted, fontWeight: FontWeight.w600)),
        ),
      );
    }
    Widget box(String label, TextEditingController c, String hint) => Expanded(
          child: _HeaderField(
            label: label,
            height: 70,
            child: TextField(
              controller: c,
              maxLines: 2,
              style: T.body.copyWith(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: T.bodyMuted.copyWith(color: T.ghost),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!cfg.isTransfer) ...[
          box('Note imprimée sur le document', _notesCtrl,
              'Conditions, référence client… — figure sur le PDF'),
          const SizedBox(width: 14),
        ],
        box('Note interne (jamais imprimée)', _internalNotesCtrl,
            'Visible seulement dans le logiciel'),
      ]),
    );
  }

  Widget _linesHeader() {
    if (cfg.isTransfer) {
      return const Row(children: [
        Expanded(flex: 5, child: MicroLabel('Produit')),
        SizedBox(width: 130, child: MicroLabel('Quantité')),
        SizedBox(width: _W.del),
      ]);
    }
    if (cfg.isReception) {
      return const Row(children: [
        Expanded(flex: 4, child: MicroLabel('Produit')),
        SizedBox(width: _W.rUnit, child: MicroLabel('Unité')),
        SizedBox(width: _W.rQty, child: MicroLabel('Quantité')),
        SizedBox(width: _W.rFree, child: MicroLabel('Gratuit')),
        SizedBox(width: _W.rPrice, child: MicroLabel('Prix d’achat HT')),
        SizedBox(width: _W.rDisc, child: MicroLabel('Remise %')),
        SizedBox(width: _W.rVat, child: MicroLabel('TVA')),
        SizedBox(
            width: _W.rTotal,
            child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: MicroLabel('Total TTC'))),
        SizedBox(width: _W.del),
      ]);
    }
    return Row(children: [
      const Expanded(flex: 5, child: MicroLabel('Produit')),
      const SizedBox(width: _W.qty, child: MicroLabel('Quantité')),
      SizedBox(
          width: _W.price,
          child: MicroLabel(
              cfg.isPurchase ? 'Prix d’achat HT' : 'Prix unitaire HT')),
      const SizedBox(width: _W.disc, child: MicroLabel('Remise %')),
      const SizedBox(width: _W.vat, child: MicroLabel('TVA')),
      const SizedBox(
          width: _W.total,
          child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: MicroLabel('Total TTC'))),
      const SizedBox(width: _W.del),
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

  /// Sticky bottom bar: line count and live totals (the actions are in the
  /// page header, always visible).
  Widget _totalsBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _editorMaxWidth),
        child: _totalsCard(),
      ),
    );
  }

  Widget _totalsCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 0, 28, 16),
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
            _Total('Total HT', _totalHT),
            _Total('TVA', _totalVAT),
            if (_timbre > 0) _Total('Droit de timbre', _timbre),
            const SizedBox(width: 26),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                const MicroLabel('Total TTC'),
                Text(fmtDA(_totalTTC), style: T.monoBig),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _refDocNumber != null
        ? (widget.receiveFrom != null
            ? 'Réception de la commande $_refDocNumber'
            : 'Créé depuis $_refDocNumber')
        : widget.existing?.number ??
            (_docId != null ? 'Brouillon enregistré' : 'Nouveau document — pas encore enregistré');
    final editing = widget.existing != null;
    final title = editing
        ? 'Modifier : ${cfg.title.toLowerCase()}'
        : (_newTitles[cfg.docType] ?? cfg.title);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybeLeave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (!_busy) _save(post: false);
          },
        },
        child: AppPage(
          crumbs: [
            Crumb(docModuleLabel(cfg.docType), _busy ? null : _maybeLeave),
            Crumb(editing ? (widget.existing!.number ?? 'Brouillon') : title),
          ],
          title: title,
          subtitle: Text(subtitle, style: T.bodyMuted),
          onBack: _maybeLeave,
          scroll: false,
          maxWidth: _editorMaxWidth - 56,
          actions: [
            Builder(
              builder: (btnCtx) => PageAction(
                label: _attachments.isEmpty
                    ? 'Pièces jointes'
                    : 'Pièces jointes (${_attachments.length})',
                icon: Icons.attach_file_rounded,
                onPressed: _busy ? null : () => _attachmentsMenu(btnCtx),
              ),
            ),
            PageAction(
              label: 'Enregistrer le brouillon',
              icon: Icons.save_outlined,
              onPressed: _busy ? null : () => _save(post: false),
            ),
            PageAction(
              label: _busy ? 'Validation…' : 'Valider',
              icon: Icons.task_alt_rounded,
              primary: true,
              onPressed: _busy ? null : () => _save(post: true),
            ),
          ],
          bottomBar: _totalsBar(),
          body: Column(
            children: [
              // ---- Header fields ----
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _headerFields(),
                      _notesSection(),
                    ]),
              ),
              // ---- Add product ----
              Padding(
                padding: const EdgeInsets.only(top: 10),
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
                        Tooltip(
                          message:
                              'Service, transport, frais… sans produit ni stock',
                          child: SizedBox(
                            height: 44,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: T.border3),
                                backgroundColor: T.surface,
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(T.rInner)),
                              ),
                              onPressed: _addFreeLine,
                              icon: const Icon(Icons.add_rounded,
                                  size: 18, color: T.ink),
                              label: Text('Ligne libre',
                                  style: T.body.copyWith(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                            ),
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
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// Width of the editor frame (the totals bar follows it).
const double _editorMaxWidth = 1456;

/// Title of a new document per type (« Ventes / Nouvelle facture »).
const _newTitles = {
  'SALE_INVOICE': 'Nouvelle facture',
  'QUOTE': 'Nouveau devis',
  'DELIVERY_NOTE': 'Nouveau bon de livraison',
  'SALE_CREDIT_NOTE': 'Nouvel avoir client',
  'PURCHASE_ORDER': 'Nouveau bon de commande',
  'PURCHASE_RECEIPT': 'Nouveau bon de réception',
  'PURCHASE_INVOICE': 'Nouvelle facture fournisseur',
  'PURCHASE_CREDIT_NOTE': 'Nouvel avoir fournisseur',
  'STOCK_TRANSFER': 'Nouveau transfert de stock',
};

/// Column widths of the line table (header and rows share them).
abstract final class _W {
  static const qty = 96.0;
  static const price = 136.0;
  static const disc = 90.0;
  static const vat = 80.0;
  static const total = 130.0;
  static const del = 40.0;
  static const rUnit = 110.0;
  static const rQty = 90.0;
  static const rFree = 84.0;
  static const rPrice = 130.0;
  static const rDisc = 90.0;
  static const rVat = 76.0;
  static const rTotal = 124.0;
}

/// Human-readable file size (« 1,2 Mo »).
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

/// Header field laid out plainly: the label ABOVE (red « * » when required),
/// a 44 px box, the error under it (red border too).
class _HeaderField extends StatelessWidget {
  const _HeaderField({
    required this.label,
    required this.child,
    this.error,
    this.required = false,
    this.width,
    this.height = 44,
    this.onTap,
  });
  final String label;
  final Widget child;
  final String? error;
  final bool required;
  final double? width;
  final double height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: AlignmentDirectional.centerStart,
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(
            color: error != null ? T.danger : T.border3,
            width: error != null ? 1.4 : 1),
      ),
      child: child,
    );
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(text: label, style: T.label),
            if (required)
              const TextSpan(
                  text: ' *',
                  style: TextStyle(
                      fontFamily: T.sans,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: T.danger)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 5),
        onTap == null
            ? box
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(T.rInner),
                child: box),
        FieldError(error),
      ],
    );
    return width == null ? col : SizedBox(width: width, child: col);
  }
}

/// VAT selectable per line: 19 / 9 / 0 % (plus the line's own rate if other).
class _VatDropdown extends StatelessWidget {
  const _VatDropdown({required this.line, required this.onChanged});
  final _EditLine line;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // Rates from Paramètres › Taxes (+ the line's own if no longer listed there).
    final rates = {...Features.instance.vatRates, line.vatRate}.toList();
    return DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        value: line.vatRate,
        isDense: true,
        style: T.monoSmall.copyWith(color: T.ink),
        icon: const Icon(Icons.expand_more, size: 16, color: T.faint),
        items: [
          for (final r in rates)
            DropdownMenuItem(value: r, child: Text(_vatPct(r))),
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
            width: _W.qty,
            child: _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
        SizedBox(
            width: _W.price,
            child:
                _CellField(controller: line.priceCtrl, onChanged: onChanged)),
        SizedBox(
            width: _W.disc,
            child: _CellField(
                controller: line.discCtrl, onChanged: onChanged, hint: '0')),
        SizedBox(
            width: _W.vat, child: _VatDropdown(line: line, onChanged: onChanged)),
        SizedBox(
          width: _W.total,
          child: Text(fmtDA(line.lineTTC),
              textAlign: TextAlign.end, style: T.monoBody),
        ),
        SizedBox(
          width: _W.del,
          child: IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18, color: T.faint),
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
            width: 130,
            child: _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
        SizedBox(
          width: _W.del,
          child: IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18, color: T.faint),
            tooltip: 'Supprimer la ligne',
          ),
        ),
      ]),
    );
  }
}

/// Two-tier receipt line: quantities/costs on top, lot/expiry and
/// sale price + live margin below — the margin includes free units and fees.
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
            width: _W.rUnit,
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
              width: _W.rQty,
              child:
                  _CellField(controller: line.qtyCtrl, onChanged: onChanged)),
          SizedBox(
              width: _W.rFree,
              child: _CellField(
                  controller: line.freeCtrl, onChanged: onChanged, hint: '0')),
          SizedBox(
            width: _W.rPrice,
            child: Row(children: [
              Expanded(
                  child: _CellField(
                      controller: line.priceCtrl, onChanged: onChanged)),
              if (variance)
                Tooltip(
                  message:
                      'Différence de plus de 15 % avec le dernier prix payé (${fmtDA(lastPrice ?? 0)})',
                  child: const Padding(
                    padding: EdgeInsetsDirectional.only(end: 6),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 15, color: T.warnDark),
                  ),
                ),
            ]),
          ),
          SizedBox(
              width: _W.rDisc,
              child: _CellField(
                  controller: line.discCtrl, onChanged: onChanged, hint: '0')),
          SizedBox(
              width: _W.rVat, child: _VatDropdown(line: line, onChanged: onChanged)),
          SizedBox(
            width: _W.rTotal,
            child: Text(fmtDA(line.lineTTC),
                textAlign: TextAlign.end, style: T.monoBody),
          ),
          SizedBox(
            width: _W.del,
            child: IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18, color: T.faint),
              tooltip: 'Supprimer la ligne',
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: 12),
          // Lot
          SizedBox(
            width: 150,
            child: Row(children: [
              Icon(Icons.qr_code_2_rounded,
                  size: 16, color: needsLot ? T.warnDark : T.faint),
              const SizedBox(width: 4),
              Expanded(
                child: _CellField(
                    controller: line.lotCtrl,
                    onChanged: onChanged,
                    hint: needsLot ? 'Lot *' : 'Lot'),
              ),
            ]),
          ),
          // Expiry date
          InkWell(
            onTap: onPickExpiry,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
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
                const Icon(Icons.event_outlined, size: 16, color: T.faint),
                const SizedBox(width: 6),
                Text(
                    line.expiryDate == null || line.expiryDate!.isEmpty
                        ? (needsExpiry ? 'Péremption *' : 'Péremption')
                        : 'Péremption ${line.expiryDate!}',
                    style: T.small.copyWith(
                        color: line.expiryDate == null ? T.muted : T.ink)),
              ]),
            ),
          ),
          if (line.baseUnits > 0 && line.effectiveCost != null)
            Flexible(
              child: Tooltip(
                message: 'Unités qui entrent en stock et nouveau coût moyen',
                child: MintChip(
                    '${fmtQty(line.baseUnits)} unités · coût moyen ${fmtDA(margin.newCmup ?? line.effectiveCost!)}',
                    color: T.cream,
                    fg: T.muted),
              ),
            ),
          const Spacer(),
          // Sale price incl. VAT — pre-filled, never empty; applies to ALL the
          // stock of this product in this depot (single-price logic).
          const MicroLabel('Prix de vente TTC'),
          const SizedBox(width: 8),
          SizedBox(
              width: 110,
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
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  margin: const EdgeInsetsDirectional.only(end: 8),
                  decoration: BoxDecoration(
                    color: T.bg,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: T.border3),
                  ),
                  alignment: Alignment.center,
                  child: Text('Suggéré ${fmtDA(suggested!)}',
                      style: T.monoSmall),
                ),
              ),
            ),
          SizedBox(
            width: 120,
            child: m == null
                ? Text('—', style: T.monoSmall)
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
      height: 38,
      margin: const EdgeInsetsDirectional.only(end: 8),
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: T.border2),
      ),
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged(),
        style: T.monoBody.copyWith(fontSize: 14),
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
  late int _vat = Features.instance.vatRates.contains(widget.defaultVat)
      ? widget.defaultVat
      : Features.instance.vatRates.first;
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
                  items: [
                    for (final r in {...Features.instance.vatRates, _vat})
                      DropdownMenuItem(value: r, child: Text('TVA ${_vatPct(r)}')),
                  ],
                  onChanged: (v) => setState(() => _vat = v ?? _vat),
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

/// Quick creation of an unknown product scanned mid-receipt: two
/// essential fields, the rest is completed later on the product page.
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
  int _vat = Features.instance.defaultVat;
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
                value: _vat,
                items: [
                  for (final r in {...Features.instance.vatRates, _vat})
                    DropdownMenuItem(value: r, child: Text('TVA ${_vatPct(r)}')),
                ],
                onChanged: (v) => setState(() => _vat = v ?? _vat),
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

/// Shared partner picker dialog (search + list, ↑ ↓ Enter, « + Nouveau
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

/// 1900 → « 19% », 950 → « 9,5% ».
String _vatPct(int r) =>
    r % 100 == 0 ? '${r ~/ 100}%' : '${(r / 100).toString().replaceAll('.', ',')}%';
