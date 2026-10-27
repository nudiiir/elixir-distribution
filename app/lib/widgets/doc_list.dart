import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../screens/documents/doc_detail_page.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../util/approval.dart';
import '../util/feedback.dart';
import '../util/invoice_pdf.dart';
import '../util/prefs.dart';
import 'data_table.dart';
import 'doc_editor.dart';
import 'list_toolbar.dart';
import 'ui.dart';

/// Short name of each document type (list column, titles).
const docTypeLabels = {
  'QUOTE': 'Devis',
  'SALE_TICKET': 'Ticket',
  'SALE_INVOICE': 'Facture',
  'SALE_CREDIT_NOTE': 'Avoir',
  'DELIVERY_NOTE': 'Bon de livraison',
  'PURCHASE_ORDER': 'Bon de commande',
  'PURCHASE_RECEIPT': 'Bon de réception',
  'PURCHASE_INVOICE': 'Facture fournisseur',
  'PURCHASE_CREDIT_NOTE': 'Avoir fournisseur',
  'STOCK_ADJUSTMENT': 'Ajustement',
  'STOCK_TRANSFER': 'Transfert',
  'INVENTORY_COUNT': 'Inventaire',
  'PAYMENT_IN': 'Encaissement',
  'PAYMENT_OUT': 'Paiement',
};

/// Plural names (quick filters, breadcrumbs).
const docTypePlurals = {
  'QUOTE': 'Devis',
  'SALE_TICKET': 'Tickets',
  'SALE_INVOICE': 'Factures',
  'SALE_CREDIT_NOTE': 'Avoirs',
  'DELIVERY_NOTE': 'Bons de livraison',
  'PURCHASE_ORDER': 'Bons de commande',
  'PURCHASE_RECEIPT': 'Bons de réception',
  'PURCHASE_INVOICE': 'Factures fournisseur',
  'PURCHASE_CREDIT_NOTE': 'Avoirs fournisseur',
  'STOCK_ADJUSTMENT': 'Ajustements',
  'STOCK_TRANSFER': 'Transferts',
  'INVENTORY_COUNT': 'Inventaires',
  'PAYMENT_IN': 'Encaissements',
  'PAYMENT_OUT': 'Paiements',
};

/// Module a document type belongs to (first breadcrumb step).
String docModuleLabel(String docType) {
  if (docType.startsWith('PURCHASE')) return 'Achats';
  if (docType.startsWith('STOCK') || docType == 'INVENTORY_COUNT') {
    return 'Stock';
  }
  if (docType == 'PAYMENT_IN') return 'Clients';
  if (docType == 'PAYMENT_OUT') return 'Fournisseurs';
  return 'Ventes';
}

const paymentLabels = {
  'cash': 'Espèces',
  'cib': 'Carte CIB',
  'edahabia': 'Edahabia',
  'cheque': 'Chèque',
  'transfer': 'Virement',
  'credit': 'Crédit',
};

/// Pops the module navigator back to its first page (the list). Stops at a
/// page that refuses to close (an editor with unsaved changes) and asks it to
/// close itself, which shows its « Enregistrer le brouillon ? » question.
/// Returns true when the list is now on top.
bool popToModuleRoot(BuildContext context) {
  final nav = Navigator.of(context);
  var blocked = false;
  nav.popUntil((r) {
    if (r.isFirst) return true;
    if (r is ModalRoute && r.popDisposition == RoutePopDisposition.doNotPop) {
      blocked = true;
      return true;
    }
    return false;
  });
  if (blocked) nav.maybePop();
  return !blocked;
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.orderStatus});
  final String status;

  /// Receipt status of a purchase order (partial/received/closed).
  final String? orderStatus;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch ((status, orderStatus)) {
      ('posted', 'partial') => ('Reçu en partie', T.warnTint, T.warnDark),
      ('posted', 'received') => ('Reçu', T.mintTint, T.mintDark),
      ('posted', 'closed') => ('Clôturé', T.cream, T.muted),
      ('posted', _) => ('Validé', T.mintTint, T.mintDark),
      ('cancelled', _) => ('Annulé', T.dangerTint, T.dangerDark),
      _ => ('Brouillon', T.cream, T.muted),
    };
    return DocChip(label: label, bg: bg, fg: fg);
  }
}

/// Payment of a document: paid / partial / to pay (nothing if not applicable).
class PaymentChip extends StatelessWidget {
  const PaymentChip({super.key, required this.status, this.overdue = false});
  final String status; // paid | partial | due | ''
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    if (status.isEmpty) return const SizedBox.shrink();
    final (label, bg, fg) = switch (status) {
      'paid' => ('Payé', T.mintTint, T.mintDark),
      'partial' => (overdue ? 'Payé en partie · en retard' : 'Payé en partie',
          T.warnTint, T.warnDark),
      _ => (overdue ? 'En retard' : 'À payer', T.warnTint, T.warnDark),
    };
    return DocChip(label: label, bg: bg, fg: fg);
  }
}

/// Small coloured badge (status, payment…).
class DocChip extends StatelessWidget {
  const DocChip(
      {super.key, required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(T.rChip)),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.label.copyWith(color: fg, fontSize: 12.5)),
    );
  }
}

int docAmountOf(String docType, int totalTTC, int amount) =>
    docType.startsWith('PAYMENT') ? amount : totalTTC;

// ---------------------------------------------------------------------------
// Shared document actions (list row menu + detail page + other screens)
// ---------------------------------------------------------------------------

/// Editor configuration for a document type (every editable type).
DocEditorConfig? docEditorConfigFor(String docType) => switch (docType) {
      'SALE_INVOICE' => saleInvoiceConfig,
      'QUOTE' => quoteConfig,
      'DELIVERY_NOTE' => deliveryNoteConfig,
      'SALE_CREDIT_NOTE' => saleCreditNoteConfig,
      'PURCHASE_ORDER' => purchaseOrderConfig,
      'PURCHASE_RECEIPT' => purchaseReceiptConfig,
      'PURCHASE_INVOICE' => purchaseInvoiceConfig,
      'PURCHASE_CREDIT_NOTE' => purchaseCreditNoteConfig,
      'STOCK_TRANSFER' => stockTransferConfig,
      _ => null,
    };

/// « Convertir en… » targets: (label, target doc type). 'RECEIVE' means the
/// existing receive-the-order flow.
List<(String, String)> docConversions(
    String docType, String status, String? orderStatus) {
  if (status == 'cancelled') return const [];
  return switch (docType) {
    'QUOTE' => const [
        ('Facture', 'SALE_INVOICE'),
        ('Bon de livraison', 'DELIVERY_NOTE')
      ],
    'DELIVERY_NOTE' when status == 'posted' => const [('Facture', 'SALE_INVOICE')],
    'PURCHASE_ORDER'
        when status == 'posted' &&
            orderStatus != 'closed' &&
            orderStatus != 'received' =>
      const [('Bon de réception', 'RECEIVE')],
    'PURCHASE_RECEIPT' when status == 'posted' =>
      const [('Facture fournisseur', 'PURCHASE_INVOICE')],
    _ => const [],
  };
}

/// Stock impact of validating a document, in words.
String stockImpactText(String docType, List<DocLine> lines,
    {bool onReference = false}) {
  final qty = lines
      .where((l) => l.productId != null)
      .fold<int>(0, (s, l) => s + l.qtyMilli + l.qtyFreeMilli);
  final q = fmtQty(qty);
  return switch (docType) {
    'SALE_TICKET' || 'SALE_INVOICE' when onReference =>
      'Stock : déjà sorti par le bon de livraison (seul l’excédent sort).',
    'SALE_TICKET' || 'SALE_INVOICE' || 'DELIVERY_NOTE' =>
      'Stock : sortie de $q unité(s) du dépôt.',
    'SALE_CREDIT_NOTE' => 'Stock : retour de $q unité(s) en stock.',
    'PURCHASE_INVOICE' when onReference =>
      'Stock : déjà entré par le bon de réception (seule la différence entre).',
    'PURCHASE_RECEIPT' ||
    'PURCHASE_INVOICE' =>
      'Stock : entrée de $q unité(s), le coût moyen est recalculé.',
    'PURCHASE_CREDIT_NOTE' =>
      'Stock : sortie de $q unité(s) (retour fournisseur).',
    'STOCK_TRANSFER' => 'Stock : $q unité(s) passent d’un dépôt à l’autre.',
    'STOCK_ADJUSTMENT' => 'Stock : ajustement des quantités saisies.',
    'INVENTORY_COUNT' => 'Stock : les différences d’inventaire sont appliquées.',
    _ => 'Aucun mouvement de stock.',
  };
}

/// Opens the editor pre-filled from [d] (same type, new draft).
Future<bool> duplicateDocument(
    BuildContext context, ApiClient api, DocDetail d) async {
  final cfg = docEditorConfigFor(d.docType);
  if (cfg == null) {
    showToast(context, 'Ce type de document ne se duplique pas.',
        kind: ToastKind.warning);
    return false;
  }
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => DocEditorScreen(api: api, config: cfg, copyFrom: d),
  ));
  return changed == true;
}

/// Converts [d] into [targetType] (see [docConversions]): a new draft that
/// references the original.
Future<bool> convertDocument(BuildContext context, ApiClient api, DocDetail d,
    String targetType) async {
  final Widget page;
  if (targetType == 'RECEIVE') {
    page = DocEditorScreen(
        api: api, config: purchaseReceiptConfig, receiveFrom: d);
  } else {
    final cfg = docEditorConfigFor(targetType);
    if (cfg == null) return false;
    page = DocEditorScreen(
        api: api, config: cfg, copyFrom: d, linkToCopy: true);
  }
  final changed = await Navigator.of(context)
      .push<bool>(MaterialPageRoute(builder: (_) => page));
  return changed == true;
}

/// « Annuler le document » for a validated document: the reason is asked, the
/// stock and accounts are put back, the document stays visible marked
/// « Annulé » (a trace is kept). True if done.
Future<bool> voidDocumentFlow(BuildContext context, ApiClient api, String docId,
    {String? docType}) async {
  final what = switch (docType) {
    'SALE_INVOICE' || 'PURCHASE_INVOICE' => 'la facture',
    'SALE_CREDIT_NOTE' || 'PURCHASE_CREDIT_NOTE' => 'l’avoir',
    'SALE_TICKET' => 'le ticket',
    _ => 'le document',
  };
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: T.surface,
      title: Text('Annuler $what ?', style: T.h2),
      content: SizedBox(
        width: 400,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Le stock et les comptes sont remis comme avant. Une trace est '
                  'gardée : le document garde son numéro et reste visible, marqué '
                  '« Annulé ». Créez ensuite le document corrigé.',
                  style: T.body.copyWith(height: 1.4)),
              const SizedBox(height: 14),
              Text('Motif de l’annulation', style: T.label),
              const SizedBox(height: 5),
              TextField(
                  controller: reason,
                  autofocus: true,
                  style: T.body,
                  decoration: const InputDecoration(
                      hintText: 'Ex. erreur de quantité, client parti…',
                      border: OutlineInputBorder())),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Ne pas annuler')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Annuler $what')),
      ],
    ),
  );
  final text = reason.text.trim();
  reason.dispose();
  if (ok != true || !context.mounted) return false;
  try {
    // Without the « annuler un document validé » right: manager's code.
    await withApproval(
        context, api, () => api.voidDocument(docId, reason: text));
    if (context.mounted) {
      showToast(context, 'Document annulé (une trace est gardée).');
    }
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showToast(context, e.message, kind: ToastKind.error);
    return false;
  }
}

/// « Annuler le brouillon » with confirmation. True if cancelled.
Future<bool> cancelDraftFlow(
    BuildContext context, ApiClient api, String docId) async {
  final ok = await confirmAction(context,
      title: 'Annuler ce brouillon ?',
      message:
          'Le brouillon reste visible, marqué annulé. Il ne pourra plus être validé.',
      confirmLabel: 'Annuler le brouillon',
      danger: true);
  if (!ok || !context.mounted) return false;
  try {
    await withApproval(context, api, () => api.cancelDocument(docId));
    if (context.mounted) showToast(context, 'Brouillon annulé');
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showToast(context, e.message, kind: ToastKind.error);
    return false;
  }
}

/// PDF of a document: the custom invoice design when one exists, the
/// built-in layout otherwise (tickets keep their receipt shape).
Future<void> printDocumentPdf(ApiClient api, DocDetail d) async {
  final company = await api.settings();
  Partner? partner;
  if (d.partnerId != null) {
    try {
      partner = await api.getPartner(d.partnerId!);
    } catch (_) {}
  }
  Template? custom;
  if (d.docType != 'SALE_TICKET') {
    try {
      custom = await api.defaultTemplate('invoice');
    } catch (_) {}
  }
  if (custom != null) {
    final bytes = await renderTemplateBytes(
      TplDoc.fromJson(custom.body),
      lang: custom.lang,
      data: invoiceData(
          doc: d,
          client: partner,
          company: company,
          title: (docTypeLabels[d.docType] ?? 'Document').toUpperCase()),
      tableRows: invoiceTableRows(d),
    );
    await saveAndOpenPdf(bytes, d.number ?? 'brouillon-${d.id.substring(0, 8)}');
  } else {
    await openDocumentPdf(company: company, doc: d, partner: partner, api: api);
  }
}

// ---------------------------------------------------------------------------
// Document list
// ---------------------------------------------------------------------------

const _periodLabels = {
  'today': "Aujourd'hui",
  'yesterday': 'Hier',
  '7d': '7 derniers jours',
  '30d': '30 derniers jours',
  'month': 'Ce mois',
  'lastmonth': 'Mois dernier',
  'year': 'Cette année',
  'custom': 'Choisir les dates…',
};

(DateTime, DateTime)? _periodRange(String? key) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final monthStart = DateTime(today.year, today.month, 1);
  return switch (key) {
    'today' => (today, today),
    'yesterday' => (
        today.subtract(const Duration(days: 1)),
        today.subtract(const Duration(days: 1))
      ),
    '7d' => (today.subtract(const Duration(days: 6)), today),
    '30d' => (today.subtract(const Duration(days: 29)), today),
    'month' => (monthStart, today),
    'lastmonth' => (
        DateTime(today.year, today.month - 1, 1),
        monthStart.subtract(const Duration(days: 1))
      ),
    'year' => (DateTime(today.year, 1, 1), today),
    _ => null,
  };
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _frShort(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

/// Searchable, filterable, exportable document list — the list archetype for
/// documents, shared by Sales and Purchases. Filters are remembered per screen.
class DocListPane extends StatefulWidget {
  const DocListPane({
    super.key,
    required this.api,
    required this.allTypes,
    required this.editorFor,
    required this.exportName,
    this.quickTypes = const [],
    this.partnerNames = const {},
    this.prefsKey,
    this.partnerKind,
    this.exportTitle,
    this.emptyActions = const [],
  });

  final ApiClient api;
  final List<String> allTypes;

  /// At most three types offered as quick pills (the rest is in « Type »).
  final List<String> quickTypes;
  final Map<String, String>? partnerNames;
  final String exportName;

  /// Remembers filters, columns and sort (defaults to `docs_<exportName>`).
  final String? prefsKey;

  /// Restricts the partner filter picker ('customer' | 'supplier').
  final String? partnerKind;
  final String? exportTitle;

  /// Next steps offered by the empty state (last = primary).
  final List<(String, VoidCallback)> emptyActions;

  /// Returns the editor config for a draft of the given type, or null.
  final DocEditorConfig? Function(String docType) editorFor;

  @override
  State<DocListPane> createState() => DocListPaneState();
}

class DocListPaneState extends State<DocListPane> {
  final _qCtrl = TextEditingController();
  Timer? _debounce;
  String? _typeFilter;
  String? _statusFilter; // draft | posted | cancelled
  String? _paymentFilter;
  String? _partnerFilter;
  String? _partnerName;
  String? _period; // preset key, 'custom' or null
  DateTime? _from;
  DateTime? _to;
  List<DocSummary> _docs = const [];
  bool _loading = true;
  String? _error;
  int _seq = 0;

  String get _pk => widget.prefsKey ?? 'docs_${widget.exportName}';
  bool get _supplier => widget.partnerKind == 'supplier';
  String get _partnerWord => _supplier ? 'Fournisseur' : 'Client';

  @override
  void initState() {
    super.initState();
    final p = UiPrefs.instance;
    final t = p.get<String>(_pk, 'type');
    _typeFilter = widget.allTypes.contains(t) ? t : null;
    _statusFilter = p.get<String>(_pk, 'status');
    _paymentFilter = p.get<String>(_pk, 'payment');
    _partnerFilter = p.get<String>(_pk, 'partner');
    _partnerName = p.get<String>(_pk, 'partner_name');
    _period = p.get<String>(_pk, 'period');
    if (_period == 'custom') {
      _from = DateTime.tryParse(p.get<String>(_pk, 'from') ?? '');
      _to = DateTime.tryParse(p.get<String>(_pk, 'to') ?? '');
      if (_from == null || _to == null) _period = null;
    } else {
      final r = _periodRange(_period);
      if (r == null) {
        _period = null;
      } else {
        _from = r.$1;
        _to = r.$2;
      }
    }
    refresh();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _qCtrl.dispose();
    super.dispose();
  }

  void _remember() {
    final p = UiPrefs.instance;
    p.set(_pk, 'type', _typeFilter);
    p.set(_pk, 'status', _statusFilter);
    p.set(_pk, 'payment', _paymentFilter);
    p.set(_pk, 'partner', _partnerFilter);
    p.set(_pk, 'partner_name', _partnerName);
    p.set(_pk, 'period', _period);
    p.set(_pk, 'from', _period == 'custom' && _from != null ? _iso(_from!) : null);
    p.set(_pk, 'to', _period == 'custom' && _to != null ? _iso(_to!) : null);
  }

  void _apply(VoidCallback change) {
    setState(change);
    _remember();
    refresh();
  }

  /// Shows the list filtered on [docType] (null = every type) — used by the
  /// menu commands `type:…` and `list`.
  void setType(String? docType) {
    if (!mounted) return;
    _apply(() => _typeFilter =
        docType != null && widget.allTypes.contains(docType) ? docType : null);
  }

  Future<void> refresh() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final docs = await widget.api.documents(
        type: _typeFilter,
        types: _typeFilter == null ? widget.allTypes : null,
        status: _statusFilter,
        from: _from == null ? null : _iso(_from!),
        to: _to == null ? null : _iso(_to!),
        q: _qCtrl.text,
        partnerId: _partnerFilter,
        paymentMethod: _paymentFilter,
        limit: 500,
      );
      if (mounted && seq == _seq) {
        setState(() {
          _docs = docs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && seq == _seq) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger les documents : $e';
        });
      }
    }
  }

  String _partnerOf(DocSummary d) =>
      widget.partnerNames?[d.partnerId] ??
      (d.partnerId != null && d.partnerId == _partnerFilter
          ? _partnerName ?? ''
          : '');

  Future<void> _openDetail(DocSummary d) async {
    final changed = await showDocDetailDialog(context, widget.api, d.id,
        editorFor: widget.editorFor);
    if (changed == true && mounted) refresh();
  }

  Future<DocDetail?> _detail(DocSummary d) async {
    try {
      return await widget.api.getDocument(d.id);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
      return null;
    }
  }

  Future<void> _rowPdf(DocSummary s) async {
    final d = await _detail(s);
    if (d == null) return;
    try {
      await printDocumentPdf(widget.api, d);
    } catch (e) {
      if (mounted) {
        showToast(context, 'PDF impossible : $e', kind: ToastKind.error);
      }
    }
  }

  Future<void> _rowDuplicate(DocSummary s) async {
    final d = await _detail(s);
    if (d == null || !mounted) return;
    if (await duplicateDocument(context, widget.api, d)) refresh();
  }

  Future<void> _rowConvert(DocSummary s, String target) async {
    final d = await _detail(s);
    if (d == null || !mounted) return;
    if (await convertDocument(context, widget.api, d, target)) refresh();
  }

  List<RowAction<DocSummary>> _rowMenu(DocSummary d) => [
        RowAction('Ouvrir', Icons.open_in_new_rounded, _openDetail),
        if (canPdf(d.docType))
          RowAction('Imprimer (PDF)', Icons.picture_as_pdf_outlined, _rowPdf),
        if (docEditorConfigFor(d.docType) != null)
          RowAction('Dupliquer', Icons.copy_all_rounded, _rowDuplicate),
        for (final (label, target)
            in docConversions(d.docType, d.status, d.orderStatus))
          RowAction(
              target == 'RECEIVE'
                  ? 'Recevoir (bon de réception)'
                  : 'Convertir en ${label.toLowerCase()}',
              Icons.transform_rounded,
              (x) => _rowConvert(x, target)),
        if (d.status == 'posted' && !d.docType.startsWith('PAYMENT'))
          RowAction(
              'Annuler le document…',
              canDocAlone(widget.api.user, d.docType, 'void')
                  ? Icons.undo_rounded
                  : Icons.lock_outline_rounded, (x) async {
            if (await voidDocumentFlow(context, widget.api, x.id,
                docType: x.docType)) {
              refresh();
            }
          }, danger: true),
        if (d.status == 'draft')
          RowAction('Annuler le brouillon', Icons.block_rounded, (x) async {
            if (await cancelDraftFlow(context, widget.api, x.id)) refresh();
          }, danger: true),
      ];

  Future<void> _pickPartner() async {
    final p = await showPartnerPicker(context, widget.api,
        kind: widget.partnerKind);
    if (p == null) return;
    _apply(() {
      _partnerFilter = p.id;
      _partnerName = p.name;
    });
  }

  Future<void> _setPeriod(String? key) async {
    if (key == 'custom') {
      final range = await showDialog<(DateTime, DateTime)>(
        context: context,
        builder: (_) => _PeriodDialog(from: _from, to: _to),
      );
      if (range == null) return;
      _apply(() {
        _period = 'custom';
        _from = range.$1;
        _to = range.$2;
      });
      return;
    }
    _apply(() {
      _period = key;
      final r = _periodRange(key);
      _from = r?.$1;
      _to = r?.$2;
    });
  }

  String get _periodChip {
    if (_period == null || _from == null || _to == null) return '';
    if (_period != 'custom') return _periodLabels[_period]!;
    return _from == _to
        ? _frShort(_from!)
        : '${_frShort(_from!)} → ${_frShort(_to!)}';
  }

  void _clearFilters() => _apply(() {
        _typeFilter = null;
        _period = null;
        _from = null;
        _to = null;
        _partnerFilter = null;
        _partnerName = null;
        _paymentFilter = null;
        _statusFilter = null;
      });

  Widget _panel() {
    return Wrap(spacing: 14, runSpacing: 12, children: [
      FilterField<String>(
        label: 'Type',
        value: _typeFilter,
        allLabel: 'Tous les types',
        options: [
          for (final t in widget.allTypes) (t, docTypePlurals[t] ?? t)
        ],
        onChanged: (v) => _apply(() => _typeFilter = v),
      ),
      FilterField<String>(
        label: 'Période',
        value: _period,
        allLabel: 'Toutes les dates',
        options: [
          for (final e in _periodLabels.entries)
            (
              e.key,
              e.key == 'custom' && _period == 'custom'
                  ? _periodChip
                  : e.value
            )
        ],
        onChanged: _setPeriod,
      ),
      SizedBox(
        width: 240,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MicroLabel(_partnerWord),
          const SizedBox(height: 5),
          InkWell(
            onTap: _pickPartner,
            borderRadius: BorderRadius.circular(T.rInner),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(T.rInner),
                border: Border.all(
                    color: _partnerFilter == null ? T.border : T.mintDeep),
              ),
              child: Row(children: [
                const Icon(Icons.person_search_rounded,
                    size: 17, color: T.faint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      _partnerFilter == null
                          ? 'Tous — choisir…'
                          : (_partnerName ?? _partnerWord),
                      overflow: TextOverflow.ellipsis,
                      style: T.body.copyWith(
                          fontSize: 14,
                          color: _partnerFilter == null ? T.muted : T.ink)),
                ),
                if (_partnerFilter != null)
                  Tooltip(
                    message: 'Retirer le filtre',
                    child: InkWell(
                      onTap: () => _apply(() {
                        _partnerFilter = null;
                        _partnerName = null;
                      }),
                      child: const Icon(Icons.close, size: 16, color: T.faint),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      ),
      FilterField<String>(
        label: 'Paiement',
        value: _paymentFilter,
        allLabel: 'Tous les paiements',
        options: [for (final e in paymentLabels.entries) (e.key, e.value)],
        onChanged: (v) => _apply(() => _paymentFilter = v),
      ),
      FilterField<String>(
        label: 'Statut',
        value: _statusFilter,
        allLabel: 'Tous les statuts',
        options: const [
          ('draft', 'Brouillons'),
          ('posted', 'Validés'),
          ('cancelled', 'Annulés'),
        ],
        onChanged: (v) => _apply(() => _statusFilter = v),
      ),
    ]);
  }

  List<ActiveFilter> get _active => [
        if (_typeFilter != null && !widget.quickTypes.contains(_typeFilter))
          ActiveFilter('Type : ${docTypePlurals[_typeFilter] ?? _typeFilter}',
              () => _apply(() => _typeFilter = null)),
        if (_period != null && _from != null)
          ActiveFilter('Période : $_periodChip', () => _setPeriod(null)),
        if (_partnerFilter != null)
          ActiveFilter('$_partnerWord : ${_partnerName ?? '—'}', () => _apply(() {
                _partnerFilter = null;
                _partnerName = null;
              })),
        if (_paymentFilter != null)
          ActiveFilter(
              'Paiement : ${paymentLabels[_paymentFilter] ?? _paymentFilter}',
              () => _apply(() => _paymentFilter = null)),
        if (_statusFilter != null)
          ActiveFilter(
              'Statut : ${const {
                    'draft': 'brouillons',
                    'posted': 'validés',
                    'cancelled': 'annulés'
                  }[_statusFilter] ?? _statusFilter}',
              () => _apply(() => _statusFilter = null)),
      ];

  bool _overdue(DocSummary d) =>
      d.dueDate != null &&
      d.remaining > 0 &&
      d.dueDate!.compareTo(todayISO()) < 0;

  @override
  Widget build(BuildContext context) {
    final filtered = _qCtrl.text.trim().isNotEmpty ||
        _active.isNotEmpty ||
        _typeFilter != null;
    final typeWord = _typeFilter == null
        ? 'document'
        : (docTypeLabels[_typeFilter] ?? 'document').toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListToolbar(
          search: _qCtrl,
          searchHint: _supplier
              ? 'Numéro, fournisseur, référence, note ou montant…'
              : 'Numéro, client, note ou montant…',
          onSearchChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), refresh);
          },
          onSearchSubmitted: (_) {
            _debounce?.cancel();
            refresh();
          },
          quickFilters: [
            for (final t in widget.quickTypes.take(3))
              FilterPill(
                label: docTypePlurals[t] ?? t,
                active: _typeFilter == t,
                onTap: () =>
                    _apply(() => _typeFilter = _typeFilter == t ? null : t),
              ),
          ],
          panel: _panel(),
          active: _active,
          onClearAll: _clearFilters,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DataListView<DocSummary>(
            items: _docs,
            prefsKey: _pk,
            loading: _loading,
            error: _error,
            onRetry: refresh,
            rowId: (d) => d.id,
            rowMenu: _rowMenu,
            onTap: _openDetail,
            exportTitle: widget.exportTitle ?? 'Documents',
            exportBaseName: widget.exportName,
            empty: EmptyState(
              icon: Icons.receipt_long_outlined,
              text: filtered
                  ? 'Aucun $typeWord ne correspond à ces filtres.'
                  : 'Aucun document pour l’instant.',
              actions: [
                if (filtered)
                  ('Effacer les filtres', () {
                    _qCtrl.clear();
                    _clearFilters();
                  }),
                ...widget.emptyActions,
              ],
            ),
            aggregates: (rows) => [
              (
                'Total TTC',
                fmtDA(rows.fold(0,
                    (s, d) => s + docAmountOf(d.docType, d.totalTTC, d.amount)))
              ),
              ('Reste à payer', fmtDA(rows.fold(0, (s, d) => s + d.remaining))),
            ],
            columns: [
              ColumnSpec(
                id: 'number',
                label: 'Numéro',
                width: 160,
                hideable: false,
                sortKey: (d) => d.number ?? '',
                exportValue: (d) => d.number ?? 'brouillon',
                cell: (context, d) => Text(d.number ?? 'Brouillon',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: d.number == null
                        ? T.small.copyWith(fontStyle: FontStyle.italic)
                        : T.monoBody.copyWith(fontSize: 13)),
              ),
              ColumnSpec(
                id: 'type',
                label: 'Type',
                flex: 2,
                sortKey: (d) => docTypeLabels[d.docType] ?? d.docType,
                exportValue: (d) => docTypeLabels[d.docType] ?? d.docType,
                cell: (context, d) => Text(docTypeLabels[d.docType] ?? d.docType,
                    style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec(
                id: 'partner',
                label: _partnerWord,
                flex: 3,
                sortKey: (d) => _partnerOf(d).toLowerCase(),
                exportValue: _partnerOf,
                cell: (context, d) {
                  final n = _partnerOf(d);
                  return Text(n.isEmpty ? '—' : n,
                      style: T.bodyMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis);
                },
              ),
              ColumnSpec(
                id: 'date',
                label: 'Date',
                width: 110,
                sortKey: (d) => d.docDate,
                exportValue: (d) => d.docDate,
                cell: (context, d) => Text(d.docDate, style: T.monoSmall),
              ),
              ColumnSpec(
                id: 'due',
                label: 'Échéance',
                width: 110,
                sortKey: (d) => d.dueDate ?? '',
                exportValue: (d) => d.dueDate ?? '',
                cell: (context, d) {
                  if (d.dueDate == null) {
                    return Text('—', style: T.monoSmall);
                  }
                  final late = _overdue(d);
                  return Text(d.dueDate!,
                      style: T.monoSmall.copyWith(
                          color: late ? T.warnDark : T.muted,
                          fontWeight: late ? FontWeight.w800 : FontWeight.w500));
                },
              ),
              ColumnSpec(
                id: 'total',
                label: 'Total TTC',
                width: 135,
                numeric: true,
                sortKey: (d) => docAmountOf(d.docType, d.totalTTC, d.amount),
                exportValue: (d) =>
                    docAmountOf(d.docType, d.totalTTC, d.amount) / 100,
                cell: (context, d) => Text(
                    fmtDA(docAmountOf(d.docType, d.totalTTC, d.amount)),
                    style: T.monoBody),
              ),
              ColumnSpec(
                id: 'paid',
                label: 'Payé',
                width: 125,
                numeric: true,
                sortKey: (d) => d.paid,
                exportValue: (d) => d.paymentStatus.isEmpty ? '' : d.paid / 100,
                cell: (context, d) => d.paymentStatus.isEmpty
                    ? Text('—', style: T.monoSmall)
                    : Text(fmtDA(d.paid), style: T.monoSmall),
              ),
              ColumnSpec(
                id: 'remaining',
                label: 'Reste à payer',
                width: 135,
                numeric: true,
                sortKey: (d) => d.remaining,
                exportValue: (d) =>
                    d.paymentStatus.isEmpty ? '' : d.remaining / 100,
                cell: (context, d) {
                  if (d.paymentStatus.isEmpty) {
                    return Text('—', style: T.monoSmall);
                  }
                  return Text(fmtDA(d.remaining),
                      style: T.monoBody.copyWith(
                          color: d.remaining > 0 ? T.warnDark : T.faint,
                          fontWeight:
                              _overdue(d) ? FontWeight.w800 : FontWeight.w500));
                },
              ),
              ColumnSpec(
                id: 'status',
                label: 'Statut',
                width: 230,
                sortKey: (d) =>
                    '${d.status}:${d.orderStatus ?? ''}:${d.paymentStatus}',
                exportValue: (d) => [
                  switch (d.status) {
                    'posted' => 'validé',
                    'cancelled' => 'annulé',
                    _ => 'brouillon'
                  },
                  if (d.orderStatus != null) d.orderStatus!,
                  if (d.paymentStatus.isNotEmpty)
                    {'paid': 'payé', 'partial': 'payé en partie', 'due': 'à payer'}[
                            d.paymentStatus] ??
                        '',
                ].join(' · '),
                cell: (context, d) => Row(children: [
                  StatusChip(status: d.status, orderStatus: d.orderStatus),
                  if (d.paymentStatus.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Flexible(
                        child: PaymentChip(
                            status: d.paymentStatus, overdue: _overdue(d))),
                  ],
                ]),
              ),
              ColumnSpec(
                id: 'supplier_ref',
                label: 'Réf. fournisseur',
                width: 140,
                visibleByDefault: false,
                sortKey: (d) => d.supplierRef ?? '',
                exportValue: (d) => d.supplierRef ?? '',
                cell: (context, d) =>
                    Text(d.supplierRef ?? '—', style: T.monoSmall),
              ),
              ColumnSpec(
                id: 'payment',
                label: 'Paiement',
                width: 110,
                visibleByDefault: false,
                sortKey: (d) => d.paymentMethod ?? '',
                exportValue: (d) => paymentLabels[d.paymentMethod] ?? '',
                cell: (context, d) => Text(
                    paymentLabels[d.paymentMethod] ?? '—',
                    style: T.small),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact period picker: from/to — a small popup, not a full-screen calendar.
class _PeriodDialog extends StatefulWidget {
  const _PeriodDialog({this.from, this.to});
  final DateTime? from;
  final DateTime? to;

  @override
  State<_PeriodDialog> createState() => _PeriodDialogState();
}

class _PeriodDialogState extends State<_PeriodDialog> {
  late DateTime? _from = widget.from;
  late DateTime? _to = widget.to;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  String _fr(DateTime? d) => d == null
      ? '—'
      : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> _pickDate(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        if (isFrom) {
          _from = _day(d);
          if (_to == null || _to!.isBefore(_from!)) _to = _from;
        } else {
          _to = _day(d);
          if (_from == null || _from!.isAfter(_to!)) _from = _to;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Choisir les dates', style: T.h2),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _DateBtn(
                      label: 'Du',
                      value: _fr(_from),
                      onTap: () => _pickDate(true)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DateBtn(
                      label: 'Au',
                      value: _fr(_to),
                      onTap: () => _pickDate(false)),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Annuler',
                      style: T.body.copyWith(color: T.muted)),
                ),
                const Spacer(),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(
                    label: 'Appliquer',
                    onPressed: _from != null && _to != null
                        ? () => Navigator.of(context).pop((_from!, _to!))
                        : null,
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

class _DateBtn extends StatelessWidget {
  const _DateBtn(
      {required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MicroLabel(label),
      const SizedBox(height: 5),
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.rInner),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: AlignmentDirectional.centerStart,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: Row(children: [
            const Icon(Icons.calendar_today_outlined, size: 15, color: T.faint),
            const SizedBox(width: 8),
            Text(value, style: T.monoBody),
          ]),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Detail page
// ---------------------------------------------------------------------------

/// Opens the document detail PAGE (pushed in the current module navigator,
/// the menu stays visible). Returns true if the document changed (or a new
/// document was created from it). The name is kept for the many callers.
Future<bool?> showDocDetailDialog(
    BuildContext context, ApiClient api, String docId,
    {DocEditorConfig? Function(String docType)? editorFor}) {
  return Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => DocDetailPage(api: api, docId: docId, editorFor: editorFor),
  ));
}
