import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import 'ui.dart';

/// Fiche produit — l'écran où le commerçant répond à la question qui décide
/// s'il fait confiance au logiciel : « pourquoi ça dit 45 quand je compte
/// 43 ». Tout est recalculé, rien n'est stocké, et chaque chiffre remonte aux
/// documents en deux clics.
Future<void> showFicheProduit(
  BuildContext context,
  ApiClient api,
  String productId, {
  required bool canCost,
  VoidCallback? onChanged,
  void Function(Product)? onEdit,
  void Function(Product)? onLabel,
}) {
  return showDialog(
    context: context,
    builder: (_) => _FicheDialog(
      api: api,
      productId: productId,
      canCost: canCost,
      onChanged: onChanged,
      onEdit: onEdit,
      onLabel: onLabel,
    ),
  );
}

class _FicheDialog extends StatefulWidget {
  const _FicheDialog({
    required this.api,
    required this.productId,
    required this.canCost,
    this.onChanged,
    this.onEdit,
    this.onLabel,
  });
  final ApiClient api;
  final String productId;
  final bool canCost;
  final VoidCallback? onChanged;
  final void Function(Product)? onEdit;
  final void Function(Product)? onLabel;

  @override
  State<_FicheDialog> createState() => _FicheDialogState();
}

class _FicheDialogState extends State<_FicheDialog> {
  FicheData? _data;
  String? _error;
  bool _fullHistory = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d =
          await widget.api.ficheProduct(widget.productId, full: _fullHistory);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Marge sur PV_HT contre CMUP — jamais TTC contre HT (spec §2.4).
  String _marginText(int saleTTC, int vatRate, int? cmup) {
    if (cmup == null || cmup <= 0 || saleTTC <= 0) return '—';
    final pvHT = roundDiv(saleTTC * 10000, 10000 + vatRate);
    final m = roundDiv((pvHT - cmup) * 10000, cmup);
    return '${(m / 100).toStringAsFixed(2).replaceAll('.', ',')} %';
  }

  Future<void> _adjust() async {
    final d = _data!;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustDialog(api: widget.api, fiche: d),
    );
    if (done == true) {
      _load();
      widget.onChanged?.call();
    }
  }

  Future<void> _split() async {
    final d = _data!;
    final codes = <BarcodeEntry>[
      if (d.product.barcode != null && d.product.barcode!.isNotEmpty)
        BarcodeEntry(code: d.product.barcode!, label: 'principal'),
      ...d.product.barcodesEx,
    ];
    if (codes.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: T.danger,
          content: Text(
              'Il faut au moins deux codes-barres pour séparer en déclinaisons.',
              style: TextStyle(color: Colors.white))));
      return;
    }
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _SplitDialog(api: widget.api, fiche: d, codes: codes),
    );
    if (done == true) {
      _load();
      widget.onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Dialog(
      backgroundColor: T.bg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 860,
        height: 640,
        child: d == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: T.body)
                    : const CircularProgressIndicator(
                        strokeWidth: 2.6, color: T.mintDeep))
            : Column(children: [
                _header(d),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _alerts(d),
                      _indicators(d),
                      const SizedBox(height: 12),
                      _levels(d),
                      if (d.variants.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _variants(d),
                      ],
                      if (d.lots.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _lots(d),
                      ],
                      const SizedBox(height: 12),
                      _moves(d),
                      if (widget.canCost && d.suppliers.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _suppliers(d),
                      ],
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _header(FicheData d) {
    final p = d.product;
    return Container(
      color: T.surface,
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                  child: Text(p.name,
                      style: T.h2.copyWith(fontSize: 17),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 10),
              if (!p.active)
                const MintChip('inactif', color: T.cream, fg: T.faint),
            ]),
            const SizedBox(height: 5),
            Wrap(spacing: 6, runSpacing: 4, children: [
              if (p.brand.isNotEmpty)
                MintChip(p.brand, color: T.cream, fg: T.faint),
              MintChip('TVA ${p.vatRate ~/ 100}%', color: T.cream, fg: T.faint),
              if (p.trackLots)
                const MintChip('suivi lot', color: T.mintTint, fg: T.mintDark),
              if (p.trackExpiry)
                const MintChip('DLC', color: T.mintTint, fg: T.mintDark),
              if (p.trackSerials)
                const MintChip('n° série', color: T.mintTint, fg: T.mintDark),
              if (p.barcode != null)
                MintChip(p.barcode!, color: T.cream, fg: T.faint),
              if (p.barcodesEx.isNotEmpty)
                MintChip('+${p.barcodesEx.length} codes',
                    color: T.cream, fg: T.faint),
            ]),
          ]),
        ),
        // ---- Actions ----
        if (widget.onEdit != null)
          IconButton(
            tooltip: 'Modifier',
            onPressed: () => widget.onEdit!(d.product),
            icon: const Icon(Icons.edit_outlined, size: 18, color: T.muted),
          ),
        IconButton(
          tooltip: 'Ajuster le stock (motif obligatoire)',
          onPressed: _adjust,
          icon: const Icon(Icons.tune_rounded, size: 18, color: T.muted),
        ),
        if (widget.onLabel != null)
          IconButton(
            tooltip: 'Étiquettes',
            onPressed: () => widget.onLabel!(d.product),
            icon: const Icon(Icons.qr_code_2_rounded, size: 18, color: T.muted),
          ),
        if (d.variants.isEmpty)
          IconButton(
            tooltip: 'Séparer en déclinaisons',
            onPressed: _split,
            icon: const Icon(Icons.call_split_rounded, size: 18, color: T.muted),
          ),
        IconButton(
          tooltip: 'Fermer',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 18, color: T.muted),
        ),
      ]),
    );
  }

  Widget _alerts(FicheData d) {
    final alerts = <Widget>[];
    final today = DateTime.now();
    for (final l in d.lots) {
      if (l.qtyMilli <= 0 || l.expiryDate == null) continue;
      final exp = DateTime.tryParse(l.expiryDate!);
      if (exp == null) continue;
      final days = exp.difference(today).inDays;
      if (days < 0) {
        alerts.add(_alertRow(Icons.dangerous_outlined, T.dangerDark,
            'Lot ${l.lotNumber} PÉRIMÉ depuis ${-days} j (${fmtQty(l.qtyMilli)} u.)'));
      } else if (days <= 90) {
        alerts.add(_alertRow(Icons.hourglass_bottom_rounded, T.warnDark,
            'Lot ${l.lotNumber} expire dans $days j (${fmtQty(l.qtyMilli)} u.)'));
      }
    }
    if (d.stockTotal <= 0) {
      alerts.add(_alertRow(
          Icons.remove_shopping_cart_outlined, T.dangerDark, 'En rupture'));
    } else if (d.product.minStockMilli > 0 &&
        d.stockTotal < d.product.minStockMilli) {
      alerts.add(_alertRow(Icons.trending_down_rounded, T.warnDark,
          'Sous le minimum (${fmtQty(d.product.minStockMilli)})'));
    }
    // Pool à ventiler : du stock sur le parent alors que des déclinaisons
    // existent — le stock n'est vendable sur aucune teinte tant que le
    // commerçant n'a pas réparti.
    if (d.variants.isNotEmpty && d.stockTotal > 0) {
      alerts.add(_alertRow(Icons.call_split_rounded, T.warnDark,
          '${fmtQty(d.stockTotal)} u. à ventiler entre les déclinaisons'));
    }
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Card14(
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('ALERTES'),
        const SizedBox(height: 8),
        ...alerts,
      ]),
    );
  }

  Widget _alertRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: T.body.copyWith(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _indicators(FicheData d) {
    // Quand stock_total est nul, chaque moyenne affiche un tiret, jamais un
    // zéro : une moyenne de rien n'est pas zéro dinar.
    final stock = d.stockTotal;
    final achat = d.achatPondere;
    int? ventePonderee;
    if (stock > 0) {
      var v = 0;
      if (d.variants.isEmpty) {
        v = d.product.priceRetail;
        ventePonderee = v;
      } else {
        var sum = 0;
        var qty = 0;
        for (final va in d.variants) {
          sum += (va.stockMilli * va.product.priceRetail) ~/ 1000;
          qty += va.stockMilli;
        }
        if (qty > 0) ventePonderee = (sum * 1000) ~/ qty;
      }
    }
    final margin = achat == null
        ? '—'
        : _marginText(ventePonderee ?? d.product.priceRetail,
            d.product.vatRate, achat);

    Widget card(String label, String value) => Expanded(
          child: Container(
            margin: const EdgeInsetsDirectional.only(end: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MicroLabel(label),
              const SizedBox(height: 5),
              Text(value, style: T.monoBody.copyWith(fontSize: 15)),
            ]),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        card('STOCK TOTAL', fmtQty(stock)),
        card('VALEUR DU STOCK',
            widget.canCost ? (stock > 0 ? fmtDA(d.valeurStock) : '—') : '···'),
        card('ACHAT PONDÉRÉ',
            widget.canCost ? (achat == null ? '—' : fmtDA(achat)) : '···'),
        card('VENTE PONDÉRÉE',
            ventePonderee == null ? '—' : fmtDA(ventePonderee)),
        card('MARGE MOYENNE', widget.canCost ? margin : '···'),
      ]),
    );
  }

  Widget _levels(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('STOCK PAR DÉPÔT'),
        const SizedBox(height: 8),
        if (d.levels.isEmpty)
          Text('Aucun mouvement.', style: T.bodyMuted)
        else
          for (final l in d.levels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(l.warehouse, style: T.body)),
                SizedBox(
                  width: 90,
                  child: Text(fmtQty(l.qtyMilli),
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          color: l.qtyMilli <= 0 ? T.dangerDark : T.ink)),
                ),
                SizedBox(
                  width: 130,
                  child: Text(
                      widget.canCost
                          ? 'CMUP ${l.qtyMilli == 0 ? '—' : fmtDA(l.avgCost)}'
                          : '',
                      textAlign: TextAlign.end, style: T.monoSmall),
                ),
              ]),
            ),
      ]),
    );
  }

  Widget _variants(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('DÉCLINAISONS'),
        const SizedBox(height: 8),
        for (final v in d.variants)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(
                  child: Text(v.product.variantLabel ?? v.product.name,
                      style: T.body)),
              if (v.product.barcode != null)
                SizedBox(
                    width: 130,
                    child: Text(v.product.barcode!, style: T.monoSmall)),
              SizedBox(
                width: 90,
                child: Text(fmtDA(v.product.priceRetail),
                    textAlign: TextAlign.end, style: T.monoSmall),
              ),
              SizedBox(
                width: 80,
                child: Text(fmtQty(v.stockMilli),
                    textAlign: TextAlign.end,
                    style: T.monoBody.copyWith(
                        color: v.stockMilli <= 0 ? T.dangerDark : T.ink)),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _lots(FicheData d) {
    final today = DateTime.now();
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('LOTS — triés par péremption'),
        const SizedBox(height: 8),
        for (final l in d.lots.where((l) => l.qtyMilli != 0))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 140, child: Text(l.lotNumber, style: T.monoBody)),
              Expanded(
                child: Builder(builder: (context) {
                  if (l.expiryDate == null) {
                    return Text('sans DLC', style: T.small);
                  }
                  final exp = DateTime.tryParse(l.expiryDate!);
                  final days = exp?.difference(today).inDays;
                  final color = days == null
                      ? T.muted
                      : days < 0
                          ? T.dangerDark
                          : days <= 90
                              ? T.warnDark
                              : T.muted;
                  return Text(
                      'DLC ${l.expiryDate}${days != null ? '  (J${days >= 0 ? '-' : '+'}${days.abs()})' : ''}',
                      style: T.monoSmall.copyWith(color: color));
                }),
              ),
              Text(fmtQty(l.qtyMilli), style: T.monoBody),
            ]),
          ),
      ]),
    );
  }

  Widget _moves(FicheData d) {
    const typeLabels = {
      'SALE_TICKET': 'Ticket',
      'SALE_INVOICE': 'Facture',
      'SALE_CREDIT_NOTE': 'Avoir client',
      'DELIVERY_NOTE': 'BL',
      'PURCHASE_RECEIPT': 'Réception',
      'PURCHASE_INVOICE': 'Facture fourn.',
      'PURCHASE_CREDIT_NOTE': 'Retour fourn.',
      'STOCK_ADJUSTMENT': 'Ajustement',
      'STOCK_TRANSFER': 'Transfert',
      'INVENTORY_COUNT': 'Inventaire',
    };
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: MicroLabel('MOUVEMENTS')),
          InkWell(
            onTap: () {
              setState(() => _fullHistory = !_fullHistory);
              _load();
            },
            child: Text(_fullHistory ? 'Réduire' : 'Historique complet',
                style: T.small.copyWith(
                    color: T.mintDark, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 8),
        if (d.moves.isEmpty)
          Text('Aucun mouvement.', style: T.bodyMuted)
        else
          for (final m in d.moves)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(
                    width: 84,
                    child: Text(m.date.length >= 10 ? m.date.substring(0, 10) : m.date,
                        style: T.monoSmall)),
                SizedBox(
                    width: 110,
                    child: Text(typeLabels[m.docType] ?? m.docType,
                        style: T.small)),
                SizedBox(
                    width: 130,
                    child: Text(m.docNumber ?? '—', style: T.monoSmall)),
                Expanded(child: Text(m.warehouse, style: T.small)),
                Text(
                  '${m.qtyMilli > 0 ? '+' : ''}${fmtQty(m.qtyMilli)}',
                  style: T.monoBody.copyWith(
                      color: m.qtyMilli >= 0 ? T.mintDark : T.dangerDark),
                ),
              ]),
            ),
      ]),
    );
  }

  Widget _suppliers(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('FOURNISSEURS — dernier prix payé'),
        const SizedBox(height: 8),
        for (final s in d.suppliers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(s.partner, style: T.body)),
              SizedBox(
                  width: 84,
                  child: Text(
                      s.date.length >= 10 ? s.date.substring(0, 10) : s.date,
                      style: T.monoSmall)),
              SizedBox(
                width: 110,
                child: Text(fmtDA(s.unitCost),
                    textAlign: TextAlign.end, style: T.monoBody),
              ),
            ]),
          ),
      ]),
    );
  }
}

// ---------------- Ajuster le stock ----------------

const kAdjustReasons = [
  'inventaire',
  'casse',
  'vol',
  'péremption',
  'erreur de saisie',
  'consommation interne',
  'échantillon',
];

/// Il n'existe aucun champ de stock modifiable : le stock change par un
/// document d'ajustement avec quantité comptée et motif. Deux clics de plus
/// qui gardent chaque chiffre du système explicable.
class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.api, required this.fiche});
  final ApiClient api;
  final FicheData fiche;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  String _reason = 'inventaire';
  String? _warehouseId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final levels = widget.fiche.levels;
    _warehouseId = levels.isNotEmpty ? levels.first.warehouseId : null;
  }

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _current {
    final l =
        widget.fiche.levels.where((l) => l.warehouseId == _warehouseId);
    return l.isEmpty ? 0 : l.first.qtyMilli;
  }

  Future<void> _apply() async {
    final counted = parseQty(_counted.text);
    if (counted == null) {
      setState(() => _error = 'Saisissez la quantité comptée.');
      return;
    }
    if (_warehouseId == null) {
      setState(() => _error = 'Aucun dépôt.');
      return;
    }
    final delta = counted - _current;
    if (delta == 0) {
      setState(() => _error = 'La quantité comptée égale le stock actuel.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = _note.text.trim();
      final draft = await widget.api.createDraft({
        'doc_type': 'STOCK_ADJUSTMENT',
        'doc_date': todayISO(),
        'warehouse_id': _warehouseId,
        'reason': _reason,
        'notes': note.isEmpty ? null : note,
        'lines': [
          {
            'product_id': widget.fiche.product.id,
            'description': widget.fiche.product.name,
            'qty_milli': delta,
            'unit_price': 0,
            'discount_pct': 0,
            'vat_rate': 0,
          }
        ],
      });
      await widget.api.postDocument(draft.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final warehouses = widget.fiche.levels;
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Ajuster le stock', style: T.h2),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fiche.product.name,
                style: T.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (warehouses.length > 1) ...[
              DropdownButton<String>(
                value: _warehouseId,
                isExpanded: true,
                items: [
                  for (final l in warehouses)
                    DropdownMenuItem(
                        value: l.warehouseId,
                        child:
                            Text('${l.warehouse} — ${fmtQty(l.qtyMilli)} u.')),
                ],
                onChanged: (v) => setState(() => _warehouseId = v),
              ),
              const SizedBox(height: 8),
            ],
            Text('Stock actuel : ${fmtQty(_current)}', style: T.small),
            const SizedBox(height: 10),
            TextField(
              controller: _counted,
              autofocus: true,
              style: T.monoBody,
              decoration:
                  const InputDecoration(labelText: 'Quantité comptée *'),
              onChanged: (_) => setState(() {}),
            ),
            if (parseQty(_counted.text) != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Écart : ${(parseQty(_counted.text)! - _current) > 0 ? '+' : ''}${fmtQty(parseQty(_counted.text)! - _current)}',
                    style: T.monoSmall.copyWith(
                        color: parseQty(_counted.text)! - _current >= 0
                            ? T.mintDark
                            : T.dangerDark)),
              ),
            const SizedBox(height: 12),
            const MicroLabel('MOTIF *'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in kAdjustReasons)
                ChoiceChip(
                  label: Text(r),
                  selected: _reason == r,
                  selectedColor: T.mintTint,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              style: T.body,
              decoration: const InputDecoration(
                  labelText: 'Note (optionnelle — jamais un substitut au motif)'),
            ),
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
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : "Valider l'ajustement",
            onPressed: _busy ? null : _apply),
      ],
    );
  }
}

// ---------------- Séparer en déclinaisons ----------------

/// Le logiciel ne connaît pas la répartition par parfum : le commerçant
/// compte, et la séparation est refusée tant que la somme ne tombe pas juste.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog(
      {required this.api, required this.fiche, required this.codes});
  final ApiClient api;
  final FicheData fiche;
  final List<BarcodeEntry> codes;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  late final List<TextEditingController> _suffixes;
  late final List<TextEditingController> _qtys;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suffixes = [
      for (final c in widget.codes)
        TextEditingController(text: c.label == 'principal' ? '' : c.label)
    ];
    _qtys = [for (final _ in widget.codes) TextEditingController()];
  }

  @override
  void dispose() {
    for (final c in [..._suffixes, ..._qtys]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _sum =>
      _qtys.fold(0, (s, c) => s + (parseQty(c.text) ?? 0));

  Future<void> _apply() async {
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < widget.codes.length; i++) {
      final suffix = _suffixes[i].text.trim();
      if (suffix.isEmpty) {
        setState(() => _error = 'Chaque déclinaison exige un suffixe.');
        return;
      }
      items.add({
        'barcode': widget.codes[i].code,
        'suffix': suffix,
        'qty_milli': parseQty(_qtys[i].text) ?? 0,
      });
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wh = widget.fiche.levels.isNotEmpty
          ? widget.fiche.levels.first.warehouseId
          : '';
      await widget.api.splitProduct(widget.fiche.product.id, wh, items);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.fiche.stockTotal;
    final ok = _sum == total;
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Séparer en déclinaisons', style: T.h2),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Chaque code-barres devient sa propre déclinaison. Comptez la '
                'répartition : la somme doit égaler le stock actuel (${fmtQty(total)}).',
                style: T.small.copyWith(height: 1.4)),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.codes.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  SizedBox(
                      width: 130,
                      child:
                          Text(widget.codes[i].code, style: T.monoSmall)),
                  Expanded(
                    child: TextField(
                      controller: _suffixes[i],
                      style: T.body,
                      decoration:
                          const InputDecoration(hintText: 'Suffixe (Pomme…)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: _qtys[i],
                      style: T.monoBody,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: 'Qté'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ]),
              ),
            Row(children: [
              Text('Somme : ${fmtQty(_sum)} / ${fmtQty(total)}',
                  style: T.monoBody.copyWith(
                      color: ok ? T.mintDark : T.dangerDark,
                      fontWeight: FontWeight.w700)),
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
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : 'Séparer',
            onPressed: _busy || !ok ? null : _apply),
      ],
    );
  }
}
