import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
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
    needsWarehouse: false,
    isPurchase: true);
const purchaseReceiptConfig = DocEditorConfig(
    docType: 'PURCHASE_RECEIPT',
    title: 'Réception fournisseur',
    partnerKind: 'supplier',
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

class _EditLine {
  _EditLine({
    this.productId,
    required this.description,
    required int qtyMilli,
    required int unitPrice,
    required int discountPct,
    required this.vatRate,
  })  : qtyCtrl = TextEditingController(text: fmtQty(qtyMilli)),
        priceCtrl = TextEditingController(text: editDA(unitPrice)),
        discCtrl = TextEditingController(
            text: discountPct == 0 ? '' : fmtQty(discountPct * 10));

  final String? productId;
  final String description;
  final TextEditingController qtyCtrl;
  final TextEditingController priceCtrl;
  final TextEditingController discCtrl;
  int vatRate;

  int get qtyMilli => parseQty(qtyCtrl.text) ?? 0;
  int get unitPrice => parseDA(priceCtrl.text) ?? 0;
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

  void dispose() {
    qtyCtrl.dispose();
    priceCtrl.dispose();
    discCtrl.dispose();
  }
}

/// Full-screen document editor. Returns true if a document was saved/posted.
class DocEditorScreen extends StatefulWidget {
  const DocEditorScreen({
    super.key,
    required this.api,
    required this.config,
    this.existing,
  });

  final ApiClient api;
  final DocEditorConfig config;
  final DocDetail? existing; // draft being edited

  @override
  State<DocEditorScreen> createState() => _DocEditorScreenState();
}

class _DocEditorScreenState extends State<DocEditorScreen> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  List<Product> _results = const [];
  bool _searching = false;

  final List<_EditLine> _lines = [];
  DateTime _date = DateTime.now();
  Partner? _partner;
  String? _warehouseId;
  List<Warehouse> _warehouses = const [];
  String _paymentMethod = 'cash';
  bool _busy = false;

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

    final ex = widget.existing;
    if (ex != null) {
      _date = DateTime.tryParse(ex.docDate) ?? DateTime.now();
      _paymentMethod = ex.paymentMethod ?? 'cash';
      for (final l in ex.lines) {
        _lines.add(_EditLine(
          productId: l.productId,
          description: l.description,
          qtyMilli: l.qtyMilli,
          unitPrice: l.unitPrice,
          discountPct: l.discountPct,
          vatRate: l.vatRate,
        ));
      }
      if (ex.partnerId != null) {
        try {
          final all = await widget.api.partners(limit: 500);
          final match = all.where((p) => p.id == ex.partnerId);
          if (match.isNotEmpty && mounted) {
            setState(() => _partner = match.first);
          }
        } catch (_) {}
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
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
    if (q.trim().isEmpty) return;
    try {
      final items = await widget.api.products(q: q.trim(), limit: 5);
      final exact = items.where((p) => p.barcode == q.trim()).toList();
      final pick = exact.isNotEmpty
          ? exact.first
          : (items.length == 1 ? items.first : null);
      if (pick != null) {
        _addProduct(pick);
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

  void _addProduct(Product p) {
    setState(() {
      _lines.add(_EditLine(
        productId: p.id,
        description: p.name,
        qtyMilli: 1000,
        unitPrice: cfg.isPurchase ? p.purchasePrice : p.unitPriceHT,
        discountPct: 0,
        vatRate: p.vatRate,
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
    var t = roundDiv(_totalHT + _totalVAT, 100);
    if (t < 500) t = 500;
    if (t > 250000) t = 250000;
    return t;
  }

  int get _totalTTC => _totalHT + _totalVAT + _timbre;

  // ---- save/post ----
  Map<String, dynamic> _payload() => {
        'doc_type': cfg.docType,
        'doc_date':
            '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
        'partner_id': _partner?.id,
        'warehouse_id': cfg.needsWarehouse ? _warehouseId : null,
        'payment_method': cfg.hasPaymentMethod ? _paymentMethod : null,
        'lines': [
          for (final l in _lines)
            {
              'product_id': l.productId,
              'description': l.description,
              'qty_milli': l.qtyMilli,
              'unit_price': l.unitPrice,
              'discount_pct': l.discountPct,
              'vat_rate': l.vatRate,
            }
        ],
      };

  String? _validate() {
    if (_lines.isEmpty) return 'Ajoutez au moins une ligne.';
    if (cfg.needsWarehouse && _warehouseId == null) {
      return 'Aucun dépôt disponible.';
    }
    final needPartner = cfg.partnerRequired ||
        (cfg.hasPaymentMethod && _paymentMethod == 'credit');
    if (needPartner && _partner == null) {
      return cfg.partnerKind == 'supplier'
          ? 'Sélectionnez un fournisseur.'
          : 'Sélectionnez un client.';
    }
    if (_lines.any((l) => l.qtyMilli == 0)) {
      return 'Une ligne a une quantité nulle.';
    }
    return null;
  }

  Future<void> _save({required bool post}) async {
    final msg = _validate();
    if (msg != null) {
      _snack(msg, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final DocDetail draft;
      if (widget.existing != null) {
        draft = await widget.api.updateDraft(widget.existing!.id, _payload());
      } else {
        draft = await widget.api.createDraft(_payload());
      }
      if (post) {
        final posted = await widget.api.postDocument(draft.id);
        if (!mounted) return;
        Navigator.of(context).pop(true);
        _snackGlobal('${posted.number}  ·  ${fmtDA(posted.totalTTC)}');
      } else {
        if (!mounted) return;
        Navigator.of(context).pop(true);
        _snackGlobal('Brouillon enregistré');
      }
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('Erreur : $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        Text(msg,
            style: const TextStyle(
                fontFamily: T.mono, fontSize: 13, color: Colors.white)),
      ]),
    ));
  }

  Future<void> _pickPartner() async {
    final p = await showPartnerPicker(context, widget.api,
        kind: cfg.partnerKind);
    if (p != null) setState(() => _partner = p);
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
                          widget.existing?.number ??
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
                  label: partnerLabel,
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
                        onChanged: (v) => setState(() => _warehouseId = v),
                      ),
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
                  hint: 'Ajouter un produit — scanner ou rechercher…',
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
                      child: Row(children: [
                        const Expanded(flex: 5, child: MicroLabel('Produit')),
                        const SizedBox(width: 86, child: MicroLabel('Qté')),
                        SizedBox(
                            width: 110,
                            child: MicroLabel(
                                cfg.isPurchase ? 'Coût HT' : 'PU HT')),
                        const SizedBox(width: 70, child: MicroLabel('Rem. %')),
                        const SizedBox(width: 56, child: MicroLabel('TVA')),
                        const SizedBox(
                            width: 110,
                            child: Align(
                                alignment: AlignmentDirectional.centerEnd,
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
                              itemBuilder: (context, i) => _LineRow(
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
