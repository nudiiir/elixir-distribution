import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../templates/template_defaults.dart';
import '../../templates/template_model.dart';
import '../../templates/template_render.dart';
import '../../theme/tokens.dart';
import '../../util/approval.dart';
import '../../util/feedback.dart';
import '../../util/file_dialog.dart';
import '../../util/invoice_pdf.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_editor.dart';
import '../../widgets/doc_list.dart';
import '../../widgets/ui.dart';
import '../partners/partner_pages.dart';

/// One labelled header button that opens a small menu (« Convertir en… »,
/// « Plus »). Entries: (label, icon, action, danger).
class PageMenuAction extends StatelessWidget {
  const PageMenuAction(
      {super.key, required this.label, required this.entries, this.icon});
  final String label;
  final IconData? icon;
  final List<(String, IconData, VoidCallback, bool)> entries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: PopupMenuButton<VoidCallback>(
        tooltip: '',
        color: T.surface,
        position: PopupMenuPosition.under,
        onSelected: (f) => f(),
        itemBuilder: (_) => [
          for (final (l, i, f, danger) in entries)
            PopupMenuItem<VoidCallback>(
              value: f,
              height: 42,
              child: Row(children: [
                Icon(i, size: 18, color: danger ? T.dangerDark : T.muted),
                const SizedBox(width: 10),
                Text(l,
                    style: T.body
                        .copyWith(color: danger ? T.dangerDark : T.ink)),
              ]),
            ),
        ],
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: T.ink),
              const SizedBox(width: 7),
            ],
            Text(label,
                style: const TextStyle(
                    fontFamily: T.sans,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: T.ink)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more_rounded, size: 18, color: T.muted),
          ]),
        ),
      ),
    );
  }
}

/// Document detail page: breadcrumb « Ventes / Factures / FV-… », status and
/// payment, labelled actions chosen by state, then the sections Client,
/// Informations, Lignes, Totaux, Paiement, Notes, Pièces jointes.
/// Pops with true when the document changed.
class DocDetailPage extends StatefulWidget {
  const DocDetailPage(
      {super.key, required this.api, required this.docId, this.editorFor});
  final ApiClient api;
  final String docId;
  final DocEditorConfig? Function(String docType)? editorFor;

  @override
  State<DocDetailPage> createState() => _DocDetailPageState();
}

class _DocDetailPageState extends State<DocDetailPage> {
  DocDetail? _doc;
  Partner? _partner;
  Map<String, String> _warehouses = const {};
  List<DocAttachment> _attachments = const [];
  String? _error;
  String? _loadError;
  bool _busy = false;
  bool _changed = false;

  DocEditorConfig? Function(String) get _editorFor =>
      widget.editorFor ?? docEditorConfigFor;

  @override
  void initState() {
    super.initState();
    _load();
    _loadWarehouses();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.getDocument(widget.docId);
      if (!mounted) return;
      setState(() {
        _doc = d;
        _loadError = null;
      });
      _loadAttachments();
      if (d.partnerId != null && _partner?.id != d.partnerId) {
        try {
          final p = await widget.api.getPartner(d.partnerId!);
          if (mounted) setState(() => _partner = p);
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  Future<void> _loadWarehouses() async {
    try {
      final whs = await widget.api.warehouses();
      if (mounted) setState(() => _warehouses = {for (final w in whs) w.id: w.name});
    } catch (_) {}
  }

  Future<void> _loadAttachments() async {
    try {
      final a = await widget.api.documentAttachments(widget.docId);
      if (mounted) setState(() => _attachments = a);
    } catch (_) {}
  }

  void _back() => Navigator.of(context).pop(_changed);

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- actions ----

  Future<void> _post() async {
    final d = _doc!;
    final lines = d.lines.length;
    final ok = await confirmAction(context,
        title: 'Valider ${docTypeLabels[d.docType]?.toLowerCase() ?? 'ce document'} ?',
        message: '$lines ligne${lines > 1 ? 's' : ''} · total TTC '
            '${fmtDA(docAmountOf(d.docType, d.totalTTC, d.amount))}\n'
            '${stockImpactText(d.docType, d.lines, onReference: d.refDocumentId != null)}\n'
            'Un document validé reçoit son numéro et ne se modifie plus. '
            'En cas d’erreur, on l’annule (une trace est gardée).',
        confirmLabel: 'Valider',
        icon: Icons.task_alt_rounded);
    if (!ok || !mounted) return;
    await _run(() async {
      // Without « Valider » (or beyond a limit): manager code.
      final posted = await withApproval(
          context, widget.api, () => widget.api.postDocument(widget.docId));
      _changed = true;
      await _load();
      if (!mounted) return;
      showToast(context, '${posted.number ?? 'Document'} validé.',
          actionLabel: canPdf(posted.docType) ? 'Imprimer' : null,
          onAction: canPdf(posted.docType) ? _pdf : null);
    });
  }

  Future<void> _cancelDraft() async {
    if (await cancelDraftFlow(context, widget.api, widget.docId)) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _void() async {
    if (await voidDocumentFlow(context, widget.api, widget.docId,
        docType: _doc?.docType)) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _edit() async {
    final cfg = _editorFor(_doc!.docType);
    if (cfg == null) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, existing: _doc),
    ));
    if (!mounted) return;
    if (changed == true) _changed = true;
    await _load();
  }

  /// Opens an editor on top (duplicate / convert / receive); when something
  /// was saved, back to the list, where the new document sits on top.
  Future<void> _leaveTo(Future<bool> Function(BuildContext) open) async {
    final saved = await open(context);
    if (saved && mounted) Navigator.of(context).pop(true);
  }

  /// Closing the outstanding quantity: the normal end of most purchase orders.
  Future<void> _closeOrder() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: const Text('Clôturer le reste de la commande', style: T.h2),
        content: SizedBox(
          width: 380,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Les quantités pas encore reçues seront annulées. La commande '
                    'ne pourra plus rien recevoir.',
                    style: T.body.copyWith(height: 1.4)),
                const SizedBox(height: 14),
                Text('Motif', style: T.label),
                const SizedBox(height: 5),
                TextField(
                    controller: reason,
                    style: T.body,
                    decoration:
                        const InputDecoration(border: OutlineInputBorder())),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clôturer')),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (ok != true) return;
    await _run(() async {
      await widget.api.closeOrder(widget.docId, reason: text);
      _changed = true;
      await _load();
    });
  }

  /// Differences against the linked document (invoice vs goods receipt, goods
  /// receipt vs order).
  Future<void> _match() async {
    List<MatchExceptionRow> items = const [];
    await _run(() async {
      items = await widget.api.matchDocument(widget.docId);
    });
    if (!mounted || _error != null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: const Text('Comparer avec le document d’origine', style: T.h2),
        content: SizedBox(
          width: 480,
          child: items.isEmpty
              ? Text('Aucune différence : les documents concordent.',
                  style: T.body)
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final x in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                                switch (x.kind) {
                                  'price' => Icons.price_change_outlined,
                                  'qty' => Icons.exposure_outlined,
                                  _ => Icons.help_outline,
                                },
                                size: 18,
                                color: T.warnDark),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(x.product, style: T.body),
                                    Text(
                                        x.kind == 'price'
                                            ? '${x.detail} : ${fmtDA(x.thisValue)} au lieu de ${fmtDA(x.refValue)}'
                                            : x.kind == 'qty'
                                                ? '${x.detail} : ${fmtQty(x.thisValue)} au lieu de ${fmtQty(x.refValue)}'
                                                : x.detail,
                                        style: T.small),
                                  ]),
                            ),
                          ]),
                    ),
                ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> _pdf() async {
    final d = _doc;
    if (d == null || _busy) return;
    await _run(() async {
      try {
        await printDocumentPdf(widget.api, d);
      } catch (e) {
        throw ApiException(0, 'PDF impossible : $e');
      }
    });
  }

  /// One "bon de garantie" (warranty slip) per product of the document sold with a warranty.
  Future<void> _printWarranty() async {
    final d = _doc;
    if (d == null || _busy) return;
    await _run(() async {
      final products = <Product>[];
      for (final id in {
        for (final l in d.lines)
          if (l.productId != null) l.productId!
      }) {
        try {
          products.add(await widget.api.getProduct(id));
        } catch (_) {}
      }
      final withWarranty = products.where((p) => p.warrantyMonths > 0).toList();
      if (withWarranty.isEmpty) {
        throw ApiException(0, 'Aucun produit sous garantie dans ce document.');
      }
      final company = await widget.api.settings();
      final rec = await widget.api.defaultTemplate('warranty');
      final tpl =
          rec == null ? defaultTplDoc('warranty', 'fr') : TplDoc.fromJson(rec.body);
      for (final p in withWarranty) {
        final bytes = await renderTemplateBytes(tpl,
            lang: rec?.lang ?? 'fr',
            data: warrantyData(
                product: p, doc: d, client: _partner, company: company));
        await saveAndOpenPdf(
            bytes, 'garantie-${d.number ?? d.id.substring(0, 8)}-${p.name}');
      }
    });
  }

  Future<void> _addAttachment() async {
    final path = pickFile('Tous les fichiers', '*.*');
    if (path == null) return;
    await _run(() async {
      final f = File(path);
      if (await f.length() > 5 * 1024 * 1024) {
        throw ApiException(0, 'Fichier trop volumineux (5 Mo maximum).');
      }
      await widget.api.addDocumentAttachment(widget.docId,
          path.split(RegExp(r'[\\/]')).last, await f.readAsBytes());
      await _loadAttachments();
      if (mounted) showToast(context, 'Pièce jointe ajoutée');
    });
  }

  Future<void> _deleteAttachment(DocAttachment a) async {
    final ok = await confirmAction(context,
        title: 'Supprimer la pièce jointe ?',
        message: '« ${a.name} » sera supprimée définitivement.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    await _run(() async {
      await widget.api.deleteDocumentAttachment(widget.docId, a.id);
      await _loadAttachments();
    });
  }

  Future<void> _openPartner() async {
    final p = _partner;
    if (p == null) return;
    await openPartnerDetail(context, widget.api, p);
    if (mounted) _load();
  }

  Future<void> _openOrigin() async {
    final id = _doc?.refDocumentId;
    if (id == null) return;
    final changed = await showDocDetailDialog(context, widget.api, id,
        editorFor: widget.editorFor);
    if (changed == true && mounted) {
      _changed = true;
      _load();
    }
  }

  // ---- header actions by state ----

  List<Widget> _actions(DocDetail d) {
    final draft = d.status == 'draft';
    final posted = d.status == 'posted';
    final pdf = canPdf(d.docType);
    final conversions = docConversions(d.docType, d.status, d.orderStatus);
    final receive = conversions.where((c) => c.$2 == 'RECEIVE').toList();
    final converts = conversions.where((c) => c.$2 != 'RECEIVE').toList();
    final canDuplicate = docEditorConfigFor(d.docType) != null;
    final canEdit = draft && _editorFor(d.docType) != null;
    final isPayment = d.docType.startsWith('PAYMENT');
    VoidCallback? guard(VoidCallback f) => _busy ? null : f;

    // The ONE primary action, chosen by state.
    final String primary;
    if (draft && !isPayment) {
      primary = 'post';
    } else if (posted && receive.isNotEmpty) {
      primary = 'receive';
    } else if (pdf && !draft) {
      primary = 'pdf';
    } else if (converts.isNotEmpty) {
      primary = 'convert';
    } else if (canDuplicate) {
      primary = 'duplicate';
    } else {
      primary = '';
    }

    final more = <(String, IconData, VoidCallback, bool)>[
      if (pdf && draft)
        ('Imprimer (PDF)', Icons.picture_as_pdf_outlined, _pdf, false),
      if (posted &&
          (d.docType == 'SALE_TICKET' ||
              d.docType == 'SALE_INVOICE' ||
              d.docType == 'DELIVERY_NOTE'))
        ('Bon de garantie', Icons.verified_user_outlined, _printWarranty, false),
      if (posted &&
          d.refDocumentId != null &&
          (d.docType == 'PURCHASE_INVOICE' || d.docType == 'PURCHASE_RECEIPT'))
        ('Comparer avec le document d’origine', Icons.rule_rounded, _match,
            false),
      if (posted &&
          d.docType == 'PURCHASE_ORDER' &&
          d.orderStatus != 'closed' &&
          d.orderStatus != 'received')
        ('Clôturer le reste de la commande', Icons.lock_clock_outlined,
            _closeOrder, false),
    ];

    void convert(String target) =>
        _leaveTo((c) => convertDocument(c, widget.api, d, target));

    return [
      if (canEdit)
        PageAction(
            label: 'Modifier',
            icon: Icons.edit_outlined,
            onPressed: guard(_edit)),
      if (pdf && !draft)
        PageAction(
            label: 'Imprimer (PDF)',
            icon: Icons.picture_as_pdf_outlined,
            primary: primary == 'pdf',
            onPressed: guard(_pdf)),
      if (receive.isNotEmpty)
        PageAction(
            label: 'Recevoir la marchandise',
            icon: Icons.move_to_inbox_outlined,
            primary: primary == 'receive',
            onPressed: guard(() => convert('RECEIVE'))),
      if (converts.length == 1)
        PageAction(
            label: 'Convertir en ${converts.first.$1.toLowerCase()}',
            icon: Icons.transform_rounded,
            primary: primary == 'convert',
            onPressed: guard(() => convert(converts.first.$2)))
      else if (converts.length > 1)
        PageMenuAction(
            label: 'Convertir en…',
            icon: Icons.transform_rounded,
            entries: [
              for (final (label, target) in converts)
                (label, Icons.transform_rounded, () => convert(target), false),
            ]),
      if (canDuplicate)
        PageAction(
            label: 'Dupliquer',
            icon: Icons.copy_all_rounded,
            primary: primary == 'duplicate',
            onPressed: guard(() =>
                _leaveTo((c) => duplicateDocument(c, widget.api, d)))),
      if (more.isNotEmpty)
        PageMenuAction(label: 'Plus', entries: more),
      if (posted && !isPayment)
        PageAction(
            label: switch (d.docType) {
              'SALE_INVOICE' || 'PURCHASE_INVOICE' => 'Annuler la facture',
              _ => 'Annuler le document',
            },
            // Lock = the manager code will be asked (no void_document right).
            icon: canDocAlone(widget.api.user, d.docType, 'void')
                ? Icons.undo_rounded
                : Icons.lock_outline_rounded,
            danger: true,
            onPressed: guard(_void)),
      if (draft)
        PageAction(
            label: 'Annuler le brouillon',
            icon: Icons.block_rounded,
            danger: true,
            onPressed: guard(_cancelDraft)),
      if (primary == 'post')
        PageAction(
            label: _busy ? 'Validation…' : 'Valider',
            icon: canDocAlone(widget.api.user, d.docType, 'validate')
                ? Icons.task_alt_rounded
                : Icons.lock_outline_rounded,
            primary: true,
            onPressed: guard(_post)),
    ];
  }

  // ---- sections ----

  Widget _partnerSection(DocDetail d) {
    final supplier = d.docType.startsWith('PURCHASE') || d.docType == 'PAYMENT_OUT';
    final p = _partner;
    return PageSection(
      title: supplier ? 'Fournisseur' : 'Client',
      trailing: p == null
          ? null
          : TextButton.icon(
              onPressed: _openPartner,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              label: Text(supplier ? 'Voir le fournisseur' : 'Voir le client'),
            ),
      child: d.partnerId == null
          ? Text(
              supplier
                  ? 'Aucun fournisseur sur ce document.'
                  : 'Aucun client sur ce document (client de passage).',
              style: T.bodyMuted)
          : p == null
              ? const SkeletonBar(width: 220, height: 14)
              : FactGrid(facts: [
                  ('Nom', p.name),
                  ('Téléphone', p.phone ?? ''),
                  ('Adresse', p.address ?? ''),
                  ('NIF', p.nif ?? ''),
                ]),
    );
  }

  Widget _infoSection(DocDetail d) {
    final transfer = d.docType == 'STOCK_TRANSFER';
    final facts = <(String, String)>[
      ('Date', d.docDate),
      if (d.number == null) ('Numéro', 'Donné à la validation'),
      if (d.warehouseId != null)
        (transfer ? 'Dépôt de départ' : 'Dépôt',
            _warehouses[d.warehouseId] ?? '…'),
      if (d.destWarehouseId != null)
        ('Dépôt d’arrivée', _warehouses[d.destWarehouseId] ?? '…'),
      if ((d.supplierRef ?? '').isNotEmpty)
        (d.docType == 'PURCHASE_RECEIPT'
            ? 'N° du bon de livraison fournisseur'
            : 'N° de facture du fournisseur',
            d.supplierRef!),
      if (d.status == 'cancelled' && (d.reason ?? '').isNotEmpty)
        ('Motif de l’annulation', d.reason!),
      if (d.status != 'cancelled' && (d.reason ?? '').isNotEmpty)
        ('Motif', d.reason!),
    ];
    return PageSection(
      title: 'Informations',
      trailing: d.refDocumentId == null
          ? null
          : TextButton.icon(
              onPressed: _openOrigin,
              icon: const Icon(Icons.link_rounded, size: 17),
              label: const Text('Ouvrir le document d’origine'),
            ),
      child: FactGrid(columns: 3, facts: facts),
    );
  }

  Widget _linesSection(DocDetail d) {
    final transfer = d.docType == 'STOCK_TRANSFER';
    final order = d.docType == 'PURCHASE_ORDER' && d.status == 'posted';
    Widget head(String s, {double? w, bool end = false}) {
      final t = Text(s,
          style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return PageSection(
      title: 'Lignes (${d.lines.length})',
      child: d.lines.isEmpty
          ? Text('Aucune ligne.', style: T.bodyMuted)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  head('Produit'),
                  head('Quantité', w: 100, end: true),
                  if (order) head('Reçu', w: 110, end: true),
                  if (!transfer) ...[
                    head('Prix unitaire HT', w: 150, end: true),
                    head('Remise', w: 80, end: true),
                    head('TVA', w: 60, end: true),
                    head('Total TTC', w: 150, end: true),
                  ],
                ]),
              ),
              const Divider(),
              for (final l in d.lines) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l.description,
                                    style: T.body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                if (_lineExtras(d, l).isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(_lineExtras(d, l).join('  ·  '),
                                        style: T.small),
                                  ),
                              ]),
                        ),
                        SizedBox(
                            width: 100,
                            child: Text(fmtQty(l.qtyMilli),
                                textAlign: TextAlign.end, style: T.monoBody)),
                        if (order)
                          SizedBox(
                              width: 110,
                              child: Text(
                                  '${fmtQty(l.qtyReceivedMilli)} / ${fmtQty(l.qtyMilli)}',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                        if (!transfer) ...[
                          SizedBox(
                              width: 150,
                              child: Text(fmtDA(l.unitPrice),
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                          SizedBox(
                              width: 80,
                              child: Text(
                                  l.discountPct == 0
                                      ? '—'
                                      : '${fmtQty(l.discountPct * 10)} %',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                          SizedBox(
                              width: 60,
                              child: Text('${l.vatRate ~/ 100} %',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                          SizedBox(
                              width: 150,
                              child: Text(fmtDA(l.lineTTC),
                                  textAlign: TextAlign.end,
                                  style: T.monoBody)),
                        ],
                      ]),
                ),
                const Divider(),
              ],
            ]),
    );
  }

  List<String> _lineExtras(DocDetail d, DocLine l) => [
        if (l.productId == null) 'Ligne libre (sans stock)',
        if (l.qtyFreeMilli > 0) '+${fmtQty(l.qtyFreeMilli)} gratuit',
        if (l.packFactorMilli != 1000)
          'Emballage de ${fmtQty(l.packFactorMilli)}',
        if ((l.lotNumber ?? '').isNotEmpty) 'Lot ${l.lotNumber}',
        if ((l.expiryDate ?? '').isNotEmpty) 'Péremption ${l.expiryDate}',
        if (l.qtyCancelledMilli > 0)
          'Annulé ${fmtQty(l.qtyCancelledMilli)}',
        if (l.newSalePrice != null)
          'Nouveau prix de vente ${fmtDA(l.newSalePrice!)}',
      ];

  Widget _totalsSection(DocDetail d) {
    Widget row(String k, int v, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Spacer(),
            Text(k, style: big ? T.h2 : T.bodyMuted),
            const SizedBox(width: 24),
            SizedBox(
              width: 200,
              child: Text(fmtDA(v),
                  textAlign: TextAlign.end,
                  style: big ? T.monoBig.copyWith(fontSize: 24) : T.monoBody),
            ),
          ]),
        );
    return PageSection(
      title: 'Totaux',
      child: Column(children: [
        if (d.totalDiscount > 0) row('Remise', d.totalDiscount),
        row('Total HT', d.totalHT),
        row('TVA', d.totalVAT),
        if (d.timbre > 0) row('Droit de timbre', d.timbre),
        if (d.freightCost > 0) row('Frais (transport…)', d.freightCost),
        const Divider(height: 16),
        row('Total TTC', d.totalTTC, big: true),
      ]),
    );
  }

  Widget _paymentSection(DocDetail d) {
    final overdue = d.dueDate != null &&
        d.remaining > 0 &&
        d.dueDate!.compareTo(todayISO()) < 0;
    final sentence = d.remaining <= 0
        ? 'Ce document est entièrement payé.'
        : overdue
            ? 'Reste ${fmtDA(d.remaining)} à payer — l’échéance du ${d.dueDate} est dépassée.'
            : d.dueDate != null
                ? 'Reste ${fmtDA(d.remaining)} à payer avant le ${d.dueDate}.'
                : 'Reste ${fmtDA(d.remaining)} à payer.';
    return PageSection(
      title: 'Paiement',
      trailing: PaymentChip(status: d.paymentStatus, overdue: overdue),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(sentence,
            style: T.body.copyWith(
                color: overdue ? T.warnDark : T.ink,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        FactGrid(columns: 4, facts: [
          ('Mode de paiement', paymentLabels[d.paymentMethod] ?? ''),
          ('Payé', fmtDA(d.paid)),
          ('Reste à payer', fmtDA(d.remaining)),
          ('Échéance', d.dueDate ?? ''),
        ]),
      ]),
    );
  }

  Widget _paymentDocSection(DocDetail d) => PageSection(
        title: 'Montant',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(fmtDA(d.amount), style: T.monoBig),
          const SizedBox(height: 8),
          Text(
              'Mode de paiement : ${paymentLabels[d.paymentMethod] ?? d.paymentMethod ?? '—'}',
              style: T.bodyMuted),
        ]),
      );

  Widget _notesSection(DocDetail d) => PageSection(
        title: 'Notes',
        child: FactGrid(columns: 1, facts: [
          if ((d.notes ?? '').isNotEmpty)
            ('Note imprimée sur le document', d.notes!),
          if ((d.internalNotes ?? '').isNotEmpty)
            ('Note interne (jamais imprimée)', d.internalNotes!),
        ]),
      );

  Widget _attachmentsSection() => PageSection(
        title: 'Pièces jointes',
        trailing: TextButton.icon(
          onPressed: _busy ? null : _addAttachment,
          icon: const Icon(Icons.attach_file_rounded, size: 17),
          label: const Text('Joindre un fichier'),
        ),
        child: _attachments.isEmpty
            ? Text(
                'Aucune pièce jointe. Joignez la facture scannée, un bon signé…',
                style: T.bodyMuted)
            : Column(children: [
                for (final a in _attachments)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.insert_drive_file_outlined,
                          size: 18, color: T.faint),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(a.name,
                              style: T.body,
                              overflow: TextOverflow.ellipsis)),
                      Text(fmtFileSize(a.size), style: T.monoSmall),
                      const SizedBox(width: 12),
                      TextButton(
                          onPressed: () => openAttachment(
                              context, widget.api, widget.docId, a),
                          child: const Text('Ouvrir')),
                      TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor: T.dangerDark),
                          onPressed:
                              _busy ? null : () => _deleteAttachment(a),
                          child: const Text('Supprimer')),
                    ]),
                  ),
              ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    if (d == null) {
      return AppPage(
        crumbs: [Crumb('Documents', _back)],
        title: 'Document',
        onBack: _back,
        body: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(
            child: _loadError != null
                ? EmptyState(
                    icon: Icons.error_outline_rounded,
                    text: 'Impossible d’ouvrir ce document.\n$_loadError',
                    actions: [('Réessayer', _load)],
                  )
                : const CircularProgressIndicator(color: T.mint),
          ),
        ),
      );
    }
    final label = docTypeLabels[d.docType] ?? d.docType;
    final isPayment = d.docType.startsWith('PAYMENT');
    final transfer = d.docType == 'STOCK_TRANSFER';
    final overdue = d.dueDate != null &&
        d.remaining > 0 &&
        d.dueDate!.compareTo(todayISO()) < 0;
    final hasNotes =
        (d.notes ?? '').isNotEmpty || (d.internalNotes ?? '').isNotEmpty;
    return AppPage(
      crumbs: [
        Crumb(docModuleLabel(d.docType), _back),
        Crumb(docTypePlurals[d.docType] ?? label, _back),
        Crumb(d.number ?? 'Brouillon'),
      ],
      title: d.number == null ? '$label (brouillon)' : '$label ${d.number}',
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusChip(status: d.status, orderStatus: d.orderStatus),
          PaymentChip(status: d.paymentStatus, overdue: overdue),
          Text('du ${d.docDate}', style: T.bodyMuted),
          if (!transfer)
            Text('· ${fmtDA(docAmountOf(d.docType, d.totalTTC, d.amount))}',
                style: T.monoBody.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
      onBack: _back,
      actions: [
        Flexible(
          child: Wrap(
            alignment: WrapAlignment.end,
            runSpacing: 8,
            children: _actions(d),
          ),
        ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: T.dangerTint,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.danger),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded,
                  color: T.dangerDark, size: 20),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(_error!,
                      style: T.body.copyWith(color: T.dangerDark))),
              TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('Fermer')),
            ]),
          ),
        if (!transfer) _partnerSection(d),
        _infoSection(d),
        if (isPayment)
          _paymentDocSection(d)
        else ...[
          _linesSection(d),
          if (!transfer) _totalsSection(d),
        ],
        if (d.paymentStatus.isNotEmpty) _paymentSection(d),
        if (hasNotes) _notesSection(d),
        _attachmentsSection(),
      ]),
    );
  }
}
