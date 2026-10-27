import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../widgets/ui.dart';

/// Scanned invoices — supplier invoices photographed on a phone land here and
/// become draft receipts. The shop pulls them; nothing is pushed at the PC,
/// so a scan made while the shop was closed is still waiting in the morning.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  CloudConfig? _cloud;
  List<InboxItem> _items = const [];
  bool _loading = true;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(minutes: 2), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final cloud = await widget.api.cloudStatus();
      if (!mounted) return;
      setState(() => _cloud = cloud);
      if (!cloud.invoiceReady || widget.api.token == null) {
        setState(() {
          _items = const [];
          _loading = false;
          _error = null;
        });
        return;
      }
      final client = CloudClient(config: cloud, token: widget.api.token!);
      try {
        final items = await client.inbox();
        if (mounted) {
          setState(() {
            _items = items;
            _loading = false;
            _error = null;
          });
        }
      } finally {
        client.close();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _open(InboxItem item) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _ScanDetailDialog(
        api: widget.api,
        cloud: _cloud!,
        item: item,
      ),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Factures scannées', style: T.h1),
            const SizedBox(width: 12),
            if (_items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: T.mintTint,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${_items.length} en attente',
                      style: T.label
                          .copyWith(color: T.mintDark, fontSize: 13)),
                ),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Actualiser'),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              'Photographiez une facture fournisseur depuis le téléphone : '
              'elle arrive ici, prête à devenir un bon de réception.',
              style: T.bodyMuted),
          const SizedBox(height: 16),
          Expanded(
            child: cloud != null && !cloud.invoiceReady
                ? Card14(
                    child: EmptyState(
                      icon: Icons.cloud_off,
                      text: 'Services cloud non configurés.\n'
                          'Renseignez-les dans Paramètres → Services cloud.',
                      actions: [('Vérifier à nouveau', _load)],
                    ),
                  )
                : _error != null
                    ? Card14(
                        child: EmptyState(
                            icon: Icons.error_outline,
                            text: 'Impossible de lire les scans\n$_error',
                            actions: [('Réessayer', _load)]))
                    : Card14(
                        padding: EdgeInsets.zero,
                        child: _items.isEmpty && !_loading
                            ? EmptyState(
                                icon: Icons.inbox_outlined,
                                text: 'Aucun scan en attente.\n'
                                    'Ouvrez l’application Elixir sur le téléphone, '
                                    'photographiez la facture : elle arrivera ici.',
                                actions: [('Actualiser', _load)])
                            : ListView.separated(
                                itemCount: _items.length,
                                separatorBuilder: (_, _) => const Divider(),
                                itemBuilder: (context, i) {
                                  final it = _items[i];
                                  return InkWell(
                                    onTap: () => _open(it),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 12),
                                      child: Row(children: [
                                        Container(
                                          width: 34,
                                          height: 34,
                                          decoration: const BoxDecoration(
                                              color: T.mintTint,
                                              shape: BoxShape.circle),
                                          child: Icon(
                                              it.source == 'mobile'
                                                  ? Icons
                                                      .phone_iphone_rounded
                                                  : Icons.computer_rounded,
                                              size: 16,
                                              color: T.mintDark),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                  it.supplierName ??
                                                      'Fournisseur inconnu',
                                                  style: T.body.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700)),
                                              const SizedBox(height: 2),
                                              Text(
                                                  [
                                                    if (it.invoiceNumber !=
                                                        null)
                                                      it.invoiceNumber!,
                                                    if (it.invoiceDate != null)
                                                      it.invoiceDate!,
                                                    '${it.lineCount} lignes',
                                                  ].join('  ·  '),
                                                  style: T.monoSmall),
                                            ],
                                          ),
                                        ),
                                        Text(
                                            it.createdAt.length >= 16
                                                ? it.createdAt
                                                    .substring(0, 16)
                                                    .replaceFirst('T', ' ')
                                                : '',
                                            style: T.monoSmall),
                                        const SizedBox(width: 12),
                                        const Icon(Icons.chevron_right,
                                            size: 18, color: T.faint),
                                      ]),
                                    ),
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Review a scan, then turn it into a draft receipt in one click.
class _ScanDetailDialog extends StatefulWidget {
  const _ScanDetailDialog(
      {required this.api, required this.cloud, required this.item});
  final ApiClient api;
  final CloudConfig cloud;
  final InboxItem item;

  @override
  State<_ScanDetailDialog> createState() => _ScanDetailDialogState();
}

/// One editable row of the scan: designation, quantity, cost and the
/// catalogue product it will feed. Everything the OCR read can be corrected
/// here before the receipt exists.
class _EditLine {
  _EditLine(ScannedLine l)
      : designation = TextEditingController(text: l.designation),
        qty = TextEditingController(text: fmtQty(l.qtyMilli)),
        price = TextEditingController(text: editDA(l.unitPriceCentimes)),
        lot = l.lot,
        expiry = l.expiry,
        barcode = l.barcode;

  final TextEditingController designation;
  final TextEditingController qty;
  final TextEditingController price;
  final String? lot;
  final String? expiry;
  final String? barcode;

  Product? product; // matched catalogue product
  bool createNew = false; // create it in the catalogue at validation

  int get qtyMilli => parseQty(qty.text) ?? 0;
  int get priceCentimes => parseDA(price.text) ?? 0;
  int get lineTotal => (qtyMilli * priceCentimes) ~/ 1000;

  void dispose() {
    designation.dispose();
    qty.dispose();
    price.dispose();
  }
}

class _ScanDetailDialogState extends State<_ScanDetailDialog> {
  ScannedInvoice? _scan;
  String? _error;
  bool _busy = false;
  int _lastCreatedCount = 0;
  final List<_EditLine> _lines = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final client =
        CloudClient(config: widget.cloud, token: widget.api.token!);
    try {
      final scan = await client.inboxItem(widget.item.id);
      if (!mounted) return;
      setState(() {
        _scan = scan;
        _lines.addAll(scan.lines.map(_EditLine.new));
        for (final l in _lines) {
          l.qty.addListener(_refresh);
          l.price.addListener(_refresh);
        }
      });
      await _match();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      client.close();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Best-effort matching against the catalogue: barcode is authoritative,
  /// otherwise the first name hit. Anything unmatched stays "nouveau produit"
  /// until the user decides — never silently attached to the wrong product.
  Future<void> _match() async {
    for (final line in _lines) {
      Product? hit;
      try {
        if (line.barcode != null && line.barcode!.isNotEmpty) {
          final byCode = await widget.api.products(q: line.barcode!, limit: 3);
          hit = byCode.where((p) => p.barcode == line.barcode).firstOrNull;
        }
        hit ??= (await widget.api
                .products(q: line.designation.text.trim(), limit: 1))
            .firstOrNull;
      } catch (_) {}
      if (!mounted) return;
      if (line.product == null && !line.createNew) {
        setState(() {
          line.product = hit;
          line.createNew = hit == null;
        });
      }
    }
  }

  Future<void> _pickProduct(_EditLine line) async {
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _ProductPickDialog(
        api: widget.api,
        initialQuery: line.designation.text.trim(),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result is Product) {
        line.product = result;
        line.createNew = false;
      } else if (result == 'new') {
        line.product = null;
        line.createNew = true;
      } else if (result == 'free') {
        line.product = null;
        line.createNew = false;
      }
    });
  }

  void _deleteLine(_EditLine line) {
    setState(() => _lines.remove(line));
  }

  Future<void> _createDraft() async {
    final scan = _scan;
    if (scan == null || _busy) return;
    if (_lines.isEmpty) {
      setState(() => _error = 'Aucune ligne — utilisez « Ignorer » pour jeter le scan.');
      return;
    }
    for (final l in _lines) {
      if (l.designation.text.trim().isEmpty ||
          l.qtyMilli <= 0 ||
          l.priceCentimes < 0) {
        setState(() =>
            _error = 'Vérifiez les lignes : désignation, quantité et coût.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final warehouses = await widget.api.warehouses();
      final wh = warehouses.isEmpty
          ? null
          : warehouses
              .firstWhere((w) => w.isDefault, orElse: () => warehouses.first)
              .id;
      if (wh == null) throw Exception('aucun dépôt configuré');

      // Reuse the supplier when the name matches one we already know.
      String? partnerId;
      if ((scan.supplierName ?? '').isNotEmpty) {
        final found = await widget.api
            .partners(q: scan.supplierName!, kind: 'supplier', limit: 1);
        partnerId = found.firstOrNull?.id;
      }

      // Lines flagged "nouveau produit" (new product) enter the catalogue first, so the
      // receipt feeds real stock instead of free-text lines.
      var created = 0;
      for (final l in _lines) {
        if (!l.createNew) continue;
        try {
          l.product = await widget.api.saveProduct({
            'name': l.designation.text.trim(),
            'barcode':
                (l.barcode ?? '').isEmpty ? null : l.barcode,
            'vat_rate': 0,
            'purchase_price': l.priceCentimes,
            'price_retail': 0,
            'min_stock_milli': 0,
            'is_weighable': false,
            'unit': 'piece',
            'barcodes': const <String>[],
          });
          l.createNew = false;
          created++;
        } catch (_) {
          // A duplicate barcode or similar must not block the receipt —
          // the line simply stays free-text.
        }
      }

      final draft = await widget.api.createDraft({
        'doc_type': 'PURCHASE_RECEIPT',
        'doc_date': _isoDate(scan.invoiceDate) ?? todayISO(),
        'partner_id': partnerId,
        'warehouse_id': wh,
        'notes': [
          'Scan',
          if (scan.invoiceNumber != null) 'facture ${scan.invoiceNumber}',
          if (scan.supplierName != null && partnerId == null)
            'fournisseur ${scan.supplierName}',
        ].join(' · '),
        'lines': [
          for (final l in _lines)
            {
              'product_id': l.product?.id,
              'description': l.designation.text.trim(),
              'qty_milli': l.qtyMilli,
              'unit_price': l.priceCentimes,
              'vat_rate': l.product?.vatRate ?? 0,
            }
        ],
      });
      _lastCreatedCount = created;

      // Only acknowledge once the draft exists, so a failure here leaves the
      // scan in the inbox to try again rather than losing it.
      final client =
          CloudClient(config: widget.cloud, token: widget.api.token!);
      try {
        await client.inboxAck(widget.item.id);
      } finally {
        client.close();
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Row(children: [
          const Icon(Icons.check_circle, color: T.mint, size: 18),
          const SizedBox(width: 10),
          Text(
              'Bon de réception brouillon créé · ${draft.lines.length} lignes'
              '${_lastCreatedCount > 0 ? ' · $_lastCreatedCount produit(s) ajouté(s) au catalogue' : ''}'
              ' — à vérifier puis valider dans Achats',
              style: const TextStyle(
                  fontFamily: T.sans, fontSize: 14, color: Colors.white)),
        ]),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _discard() async {
    setState(() => _busy = true);
    final client =
        CloudClient(config: widget.cloud, token: widget.api.token!);
    try {
      await client.inboxAck(widget.item.id, discard: true);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    } finally {
      client.close();
    }
  }

  /// The scan gives DD/MM/YYYY or similar; the server wants YYYY-MM-DD.
  String? _isoDate(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$').firstMatch(raw.trim());
    if (m == null) return null;
    return '${m.group(3)}-${m.group(2)!.padLeft(2, '0')}-${m.group(1)!.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    return Dialog(
      backgroundColor: T.bg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 720,
        height: 580,
        child: scan == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: T.bodyMuted)
                    : const CircularProgressIndicator(color: T.mint))
            : Column(children: [
                Container(
                  decoration: const BoxDecoration(
                    color: T.surface,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(T.rCard)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(scan.supplierName ?? 'Fournisseur inconnu',
                              style: T.h2),
                          const SizedBox(height: 3),
                          Text(
                              [
                                if (scan.invoiceNumber != null)
                                  scan.invoiceNumber!,
                                if (scan.invoiceDate != null)
                                  scan.invoiceDate!,
                                '${scan.lines.length} lignes',
                              ].join('  ·  '),
                              style: T.monoSmall),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fermer (Échap)',
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close, size: 18, color: T.muted),
                    ),
                  ]),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8),
                  child: Row(children: [
                    Expanded(flex: 5, child: MicroLabel('Désignation')),
                    SizedBox(width: 10),
                    Expanded(flex: 4, child: MicroLabel('Produit du catalogue')),
                    SizedBox(width: 10),
                    SizedBox(width: 74, child: MicroLabel('Quantité')),
                    SizedBox(width: 10),
                    SizedBox(
                        width: 124,
                        child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: MicroLabel('Prix d’achat HT'))),
                    SizedBox(width: 30),
                  ]),
                ),
                const Divider(),
                Expanded(
                  child: ListView.separated(
                    itemCount: _lines.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, i) {
                      final l = _lines[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 7),
                        child: Row(children: [
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _CellField(controller: l.designation),
                                if (l.expiry != null || l.lot != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                        [
                                          if (l.lot != null) 'lot ${l.lot}',
                                          if (l.expiry != null)
                                            'exp. ${l.expiry}',
                                        ].join(' · '),
                                        style: T.monoSmall
                                            .copyWith(fontSize: 12)),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 4,
                            child: InkWell(
                              onTap: () => _pickProduct(l),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                height: 34,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 9),
                                decoration: BoxDecoration(
                                  color: l.product != null
                                      ? T.mintTint
                                      : l.createNew
                                          ? T.warnTint
                                          : T.bg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: l.product != null
                                          ? T.mintDeep
                                          : T.border),
                                ),
                                child: Row(children: [
                                  Expanded(
                                    child: Text(
                                        l.product?.name ??
                                            (l.createNew
                                                ? 'Créer ce produit'
                                                : 'Ligne libre'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: T.small.copyWith(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: l.product != null
                                                ? T.mintDark
                                                : l.createNew
                                                    ? T.warnDark
                                                    : T.muted)),
                                  ),
                                  const Icon(Icons.expand_more,
                                      size: 14, color: T.faint),
                                ]),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                              width: 74,
                              child: _CellField(
                                  controller: l.qty, mono: true)),
                          const SizedBox(width: 10),
                          SizedBox(
                              width: 124,
                              child: _CellField(
                                  controller: l.price,
                                  mono: true,
                                  alignEnd: true)),
                          SizedBox(
                            width: 30,
                            child: IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Supprimer la ligne',
                              onPressed: () => _deleteLine(l),
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 16, color: T.faint),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
                const Divider(),
                Container(
                  decoration: const BoxDecoration(
                    color: T.surface,
                    borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(T.rCard)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    if (_error != null)
                      Expanded(child: FieldError(_error!))
                    else
                      Expanded(
                        child: MicroLabel(
                            'Total ${fmtDA(_lines.fold(0, (s, l) => s + l.lineTotal))}'
                            ' · ${_lines.where((l) => l.createNew).length} nouveau(x) produit(s)'),
                      ),
                    TextButton(
                      onPressed: _busy ? null : _discard,
                      child: Text('Ignorer ce scan',
                          style: T.body.copyWith(color: T.dangerDark)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 250,
                      child: PrimaryButton(
                        label: _busy ? '…' : 'Créer le bon de réception',
                        onPressed: _busy ? null : _createDraft,
                      ),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }
}

/// Compact editable cell used by the scan review table.
class _CellField extends StatelessWidget {
  const _CellField(
      {required this.controller, this.mono = false, this.alignEnd = false});
  final TextEditingController controller;
  final bool mono;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: T.border),
      ),
      child: TextField(
        controller: controller,
        textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        style: (mono ? T.monoBody : T.body).copyWith(fontSize: 13.5),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        ),
      ),
    );
  }
}

/// Attach a scanned line to the catalogue: search an existing product,
/// create it as a new one, or keep the line free.
class _ProductPickDialog extends StatefulWidget {
  const _ProductPickDialog({required this.api, required this.initialQuery});
  final ApiClient api;
  final String initialQuery;

  @override
  State<_ProductPickDialog> createState() => _ProductPickDialogState();
}

class _ProductPickDialogState extends State<_ProductPickDialog> {
  late final _search = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  List<Product> _results = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items =
          await widget.api.products(q: _search.text.trim(), limit: 25);
      if (mounted) {
        setState(() {
          _results = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 460,
        height: 480,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(
                      child: Text('Associer un produit', style: T.h2)),
                  IconButton(
                    tooltip: 'Fermer (Échap)',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ]),
                const SizedBox(height: 8),
                SearchField(
                  controller: _search,
                  hint: 'Rechercher dans le catalogue…',
                  autofocus: true,
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce =
                        Timer(const Duration(milliseconds: 250), _load);
                  },
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: _QuickChoice(
                      icon: Icons.add_circle_outline,
                      label: 'Créer comme nouveau produit',
                      color: T.warnDark,
                      onTap: () => Navigator.of(context).pop('new'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _QuickChoice(
                      icon: Icons.short_text_rounded,
                      label: 'Ligne libre (aucun produit)',
                      color: T.muted,
                      onTap: () => Navigator.of(context).pop('free'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                const Divider(),
                Expanded(
                  child: _results.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off_rounded,
                          text: _loading
                              ? 'Chargement…'
                              : 'Aucun produit ne correspond.',
                          actions: _loading
                              ? const []
                              : [
                                  ('+ Créer comme nouveau produit',
                                      () => Navigator.of(context).pop('new')),
                                ])
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (context, i) {
                            final p = _results[i];
                            return InkWell(
                              onTap: () => Navigator.of(context).pop(p),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 9),
                                child: Row(children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(p.name,
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow.ellipsis,
                                            style: T.body),
                                        if (p.barcode != null)
                                          Text(p.barcode!,
                                              style: T.monoSmall),

                                      ],
                                    ),
                                  ),
                                  Text(fmtDA(p.priceRetail),
                                      style: T.monoSmall),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
              ]),
        ),
      ),
    );
  }
}

class _QuickChoice extends StatelessWidget {
  const _QuickChoice(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rInner),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.small.copyWith(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
      ),
    );
  }
}
