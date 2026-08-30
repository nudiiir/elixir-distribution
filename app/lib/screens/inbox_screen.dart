import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../widgets/ui.dart';

/// Factures scannées — supplier invoices photographed on a phone land here and
/// become draft réceptions. The shop pulls them; nothing is pushed at the PC,
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
                          .copyWith(color: T.mintDark, fontSize: 9.5)),
                ),
              ),
            const Spacer(),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18, color: T.muted),
              tooltip: 'Actualiser',
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              'Photographiez une facture fournisseur depuis le téléphone : '
              'elle arrive ici, prête à devenir une réception.',
              style: T.bodyMuted),
          const SizedBox(height: 16),
          Expanded(
            child: cloud != null && !cloud.invoiceReady
                ? Card14(
                    child: EmptyState(
                      icon: Icons.cloud_off,
                      text: 'Services cloud non configurés.\n'
                          'Renseignez-les dans Paramètres → Services cloud.',
                    ),
                  )
                : _error != null
                    ? Card14(
                        child: EmptyState(
                            icon: Icons.error_outline,
                            text: 'Impossible de lire les scans\n$_error'))
                    : Card14(
                        padding: EdgeInsets.zero,
                        child: _items.isEmpty && !_loading
                            ? const EmptyState(
                                icon: Icons.inbox_outlined,
                                text: 'Aucun scan en attente.')
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

/// Review a scan, then turn it into a draft réception in one click.
class _ScanDetailDialog extends StatefulWidget {
  const _ScanDetailDialog(
      {required this.api, required this.cloud, required this.item});
  final ApiClient api;
  final CloudConfig cloud;
  final InboxItem item;

  @override
  State<_ScanDetailDialog> createState() => _ScanDetailDialogState();
}

class _ScanDetailDialogState extends State<_ScanDetailDialog> {
  ScannedInvoice? _scan;
  String? _error;
  bool _busy = false;

  /// productId per line, resolved by barcode then name. null = will be created
  /// as a free-text line the user can attach to a product later.
  final Map<int, Product?> _matched = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client =
        CloudClient(config: widget.cloud, token: widget.api.token!);
    try {
      final scan = await client.inboxItem(widget.item.id);
      if (!mounted) return;
      setState(() => _scan = scan);
      await _match(scan);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      client.close();
    }
  }

  /// Best-effort matching against the catalogue: barcode is authoritative,
  /// otherwise the first name hit. Anything unmatched stays a free-text line
  /// rather than silently attaching to the wrong product.
  Future<void> _match(ScannedInvoice scan) async {
    for (var i = 0; i < scan.lines.length; i++) {
      final l = scan.lines[i];
      Product? hit;
      try {
        if (l.barcode != null && l.barcode!.isNotEmpty) {
          final byCode = await widget.api.products(q: l.barcode!, limit: 3);
          hit = byCode.where((p) => p.barcode == l.barcode).firstOrNull;
        }
        hit ??= (await widget.api.products(q: l.designation, limit: 1))
            .firstOrNull;
      } catch (_) {}
      if (!mounted) return;
      setState(() => _matched[i] = hit);
    }
  }

  Future<void> _createDraft() async {
    final scan = _scan;
    if (scan == null || _busy) return;
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
          for (var i = 0; i < scan.lines.length; i++)
            {
              'product_id': _matched[i]?.id,
              'description': scan.lines[i].designation,
              'qty_milli': scan.lines[i].qtyMilli,
              'unit_price': scan.lines[i].unitPriceCentimes,
              'vat_rate': _matched[i]?.vatRate ?? 0,
            }
        ],
      });

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
              'Réception brouillon créée · ${draft.lines.length} lignes — '
              'à vérifier puis valider dans Achats',
              style: const TextStyle(
                  fontFamily: T.sans, fontSize: 13, color: Colors.white)),
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
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close, size: 18, color: T.muted),
                    ),
                  ]),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8),
                  child: Row(children: [
                    Expanded(flex: 5, child: MicroLabel('Désignation scannée')),
                    Expanded(flex: 4, child: MicroLabel('Produit du catalogue')),
                    SizedBox(width: 70, child: MicroLabel('Qté')),
                    SizedBox(
                        width: 100,
                        child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: MicroLabel('Coût HT'))),
                  ]),
                ),
                const Divider(),
                Expanded(
                  child: ListView.separated(
                    itemCount: scan.lines.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, i) {
                      final l = scan.lines[i];
                      final hit = _matched[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 9),
                        child: Row(children: [
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.designation,
                                    style: T.body,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                if (l.expiry != null || l.lot != null)
                                  Text(
                                      [
                                        if (l.lot != null) 'lot ${l.lot}',
                                        if (l.expiry != null) 'exp. ${l.expiry}',
                                      ].join(' · '),
                                      style: T.monoSmall
                                          .copyWith(fontSize: 10)),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: hit == null
                                ? Text('— nouveau produit —',
                                    style: T.small
                                        .copyWith(color: T.warnDark))
                                : Text(hit.name,
                                    style: T.bodyMuted,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                          ),
                          SizedBox(
                              width: 70,
                              child: Text(fmtQty(l.qtyMilli),
                                  style: T.monoBody)),
                          SizedBox(
                            width: 100,
                            child: Text(fmtDA(l.unitPriceCentimes),
                                textAlign: TextAlign.end,
                                style: T.monoBody),
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
                      Expanded(
                        child: Text(_error!,
                            style: T.small.copyWith(color: T.dangerDark)),
                      )
                    else
                      Expanded(
                        child: MicroLabel(
                            'Total ${fmtDA(scan.lines.fold(0, (s, l) => s + (l.qtyMilli * l.unitPriceCentimes) ~/ 1000))}'),
                      ),
                    TextButton(
                      onPressed: _busy ? null : _discard,
                      child: Text('Ignorer',
                          style: T.small.copyWith(color: T.dangerDark)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 210,
                      child: PrimaryButton(
                        label: _busy ? '…' : 'Créer la réception',
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
