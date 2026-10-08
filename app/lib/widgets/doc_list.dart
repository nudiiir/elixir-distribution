import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import '../util/invoice_pdf.dart';
import '../util/prefs.dart';
import 'data_table.dart';
import 'doc_editor.dart';
import 'list_toolbar.dart';
import 'ui.dart';

const docTypeLabels = {
  'QUOTE': 'Devis',
  'SALE_TICKET': 'Ticket',
  'SALE_INVOICE': 'Facture',
  'SALE_CREDIT_NOTE': 'Avoir',
  'DELIVERY_NOTE': 'BL',
  'PURCHASE_ORDER': 'Commande',
  'PURCHASE_RECEIPT': 'Réception',
  'PURCHASE_INVOICE': 'Facture fourn.',
  'PURCHASE_CREDIT_NOTE': 'Avoir fourn.',
  'STOCK_ADJUSTMENT': 'Ajustement',
  'STOCK_TRANSFER': 'Transfert',
  'INVENTORY_COUNT': 'Inventaire',
  'PAYMENT_IN': 'Encaissement',
  'PAYMENT_OUT': 'Règlement',
};

const paymentLabels = {
  'cash': 'Espèces',
  'cib': 'Carte CIB',
  'edahabia': 'Edahabia',
  'cheque': 'Chèque',
  'transfer': 'Virement',
  'credit': 'Crédit',
};

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.orderStatus});
  final String status;

  /// Statut de réception d'un bon de commande (partial/received/closed).
  final String? orderStatus;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch ((status, orderStatus)) {
      ('posted', 'partial') => ('partiel', T.warnTint, T.warnDark),
      ('posted', 'received') => ('reçu', T.mintTint, T.mintDark),
      ('posted', 'closed') => ('clôturé', T.cream, T.faint),
      ('posted', _) => ('validé', T.mintTint, T.mintDark),
      ('cancelled', _) => ('annulé', T.dangerTint, T.dangerDark),
      _ => ('brouillon', T.cream, T.faint),
    };
    return _Chip(label: label, bg: bg, fg: fg);
  }
}

/// Règlement d'un document : payé / partiel / à payer (rien si sans objet).
class PaymentChip extends StatelessWidget {
  const PaymentChip({super.key, required this.status, this.overdue = false});
  final String status; // paid | partial | due | ''
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    if (status.isEmpty) return const SizedBox.shrink();
    final (label, bg, fg) = switch (status) {
      'paid' => ('payé', T.mintTint, T.mintDark),
      'partial' => (overdue ? 'partiel · retard' : 'partiel', T.warnTint, T.warnDark),
      _ => (overdue ? 'en retard' : 'à payer', T.warnTint, T.warnDark),
    };
    return _Chip(label: label, bg: bg, fg: fg);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(T.rChip)),
      child: Text(label.toUpperCase(),
          style: T.label.copyWith(color: fg, fontSize: 9)),
    );
  }
}

int _amountOf(String docType, int totalTTC, int amount) =>
    docType.startsWith('PAYMENT') ? amount : totalTTC;

// ---------------------------------------------------------------------------
// Shared document actions (list row menu + detail dialog + other screens)
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
      const [('Réception', 'RECEIVE')],
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
      'Stock : déjà entré par la réception (seul l’écart entre).',
    'PURCHASE_RECEIPT' ||
    'PURCHASE_INVOICE' =>
      'Stock : entrée de $q unité(s), le coût moyen est recalculé.',
    'PURCHASE_CREDIT_NOTE' =>
      'Stock : sortie de $q unité(s) (retour fournisseur).',
    'STOCK_TRANSFER' => 'Stock : $q unité(s) passent d’un dépôt à l’autre.',
    'STOCK_ADJUSTMENT' => 'Stock : ajustement des quantités saisies.',
    'INVENTORY_COUNT' => 'Stock : les écarts d’inventaire sont appliqués.',
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

/// Contrepassation d'un document validé (motif demandé). True if done.
Future<bool> voidDocumentFlow(
    BuildContext context, ApiClient api, String docId) async {
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: T.surface,
      title: Text('Contrepasser ce document ?', style: T.h2),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Des écritures inverses seront créées (stock et comptes). Le '
              'document garde son numéro et reste visible, marqué annulé. '
              'Créez ensuite le document corrigé.',
              style: T.body.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          TextField(
              controller: reason,
              autofocus: true,
              style: T.body,
              decoration: const InputDecoration(labelText: 'Motif')),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Non')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Contrepasser')),
      ],
    ),
  );
  final text = reason.text.trim();
  reason.dispose();
  if (ok != true) return false;
  try {
    await api.voidDocument(docId, reason: text);
    if (context.mounted) showToast(context, 'Document contrepassé');
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
  if (!ok) return false;
  try {
    await api.cancelDocument(docId);
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
    await openDocumentPdf(company: company, doc: d, partner: partner);
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
  'custom': 'Personnalisée…',
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
/// documents, shared by Ventes and Achats. Filters are remembered per screen.
class DocListPane extends StatefulWidget {
  const DocListPane({
    super.key,
    required this.api,
    required this.allTypes,
    required this.editorFor,
    required this.exportName,
    this.partnerNames = const {},
    this.prefsKey,
    this.partnerKind,
    this.exportTitle,
    this.emptyActions = const [],
  });

  final ApiClient api;
  final List<String> allTypes;
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
    if (changed == true) refresh();
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
          RowAction('PDF', Icons.picture_as_pdf_outlined, _rowPdf),
        if (docEditorConfigFor(d.docType) != null)
          RowAction('Dupliquer', Icons.copy_all_rounded, _rowDuplicate),
        for (final (label, target)
            in docConversions(d.docType, d.status, d.orderStatus))
          RowAction('Convertir en $label', Icons.transform_rounded,
              (x) => _rowConvert(x, target)),
        if (d.status == 'posted' && !d.docType.startsWith('PAYMENT'))
          RowAction('Contrepasser…', Icons.undo_rounded, (x) async {
            if (await voidDocumentFlow(context, widget.api, x.id)) refresh();
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

  Widget _panel() {
    return Wrap(spacing: 14, runSpacing: 12, children: [
      FilterField<String>(
        label: 'Période',
        value: _period,
        allLabel: 'Toutes les dates',
        options: [for (final e in _periodLabels.entries) (e.key, e.value)],
        onChanged: _setPeriod,
      ),
      SizedBox(
        width: 230,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const MicroLabel('Partenaire'),
          const SizedBox(height: 5),
          InkWell(
            onTap: _pickPartner,
            borderRadius: BorderRadius.circular(T.rInner),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(T.rInner),
                border: Border.all(
                    color: _partnerFilter == null ? T.border : T.mintDeep),
              ),
              child: Row(children: [
                const Icon(Icons.person_search_rounded,
                    size: 16, color: T.faint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      _partnerFilter == null
                          ? 'Tous — rechercher…'
                          : (_partnerName ?? 'Partenaire'),
                      overflow: TextOverflow.ellipsis,
                      style: T.body.copyWith(
                          fontSize: 13,
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
                      child: const Icon(Icons.close, size: 14, color: T.faint),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      ),
      FilterField<String>(
        label: 'Règlement',
        value: _paymentFilter,
        options: [for (final e in paymentLabels.entries) (e.key, e.value)],
        onChanged: (v) => _apply(() => _paymentFilter = v),
      ),
      FilterField<String>(
        label: 'Statut',
        value: _statusFilter,
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
        if (_period != null && _from != null)
          ActiveFilter('Période : $_periodChip', () => _setPeriod(null)),
        if (_partnerFilter != null)
          ActiveFilter('Partenaire : ${_partnerName ?? '—'}', () => _apply(() {
                _partnerFilter = null;
                _partnerName = null;
              })),
        if (_paymentFilter != null)
          ActiveFilter(
              'Règlement : ${paymentLabels[_paymentFilter] ?? _paymentFilter}',
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
    final filtered = _qCtrl.text.trim().isNotEmpty || _active.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListToolbar(
          search: _qCtrl,
          searchHint: 'N°, partenaire, réf., note ou montant…',
          onSearchChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), refresh);
          },
          onSearchSubmitted: (_) {
            _debounce?.cancel();
            refresh();
          },
          quickFilters: [
            FilterPill(
              label: 'Tous',
              active: _typeFilter == null,
              onTap: () => _apply(() => _typeFilter = null),
            ),
            for (final t in widget.allTypes)
              FilterPill(
                label: docTypeLabels[t] ?? t,
                active: _typeFilter == t,
                onTap: () => _apply(() => _typeFilter = t),
              ),
          ],
          panel: _panel(),
          active: _active,
          onClearAll: () => _apply(() {
            _period = null;
            _from = null;
            _to = null;
            _partnerFilter = null;
            _partnerName = null;
            _paymentFilter = null;
            _statusFilter = null;
          }),
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
                  ? 'Aucun document ne correspond à ces filtres.'
                  : 'Aucun document pour l’instant.',
              actions: [
                if (filtered)
                  ('Effacer les filtres', () {
                    _qCtrl.clear();
                    _apply(() {
                      _period = null;
                      _from = null;
                      _to = null;
                      _partnerFilter = null;
                      _partnerName = null;
                      _paymentFilter = null;
                      _statusFilter = null;
                    });
                  }),
                ...widget.emptyActions,
              ],
            ),
            aggregates: (rows) => [
              (
                'Total TTC',
                fmtDA(rows.fold(0,
                    (s, d) => s + _amountOf(d.docType, d.totalTTC, d.amount)))
              ),
              ('Reste à payer', fmtDA(rows.fold(0, (s, d) => s + d.remaining))),
            ],
            columns: [
              ColumnSpec(
                id: 'number',
                label: 'Numéro',
                width: 140,
                hideable: false,
                sortKey: (d) => d.number ?? '',
                exportValue: (d) => d.number ?? 'brouillon',
                cell: (context, d) => Text(d.number ?? '—',
                    style: T.monoBody.copyWith(
                        fontSize: 12,
                        color: d.number == null ? T.ghost : T.ink)),
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
                label: 'Partenaire',
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
                width: 95,
                sortKey: (d) => d.docDate,
                exportValue: (d) => d.docDate,
                cell: (context, d) => Text(d.docDate, style: T.monoSmall),
              ),
              ColumnSpec(
                id: 'due',
                label: 'Échéance',
                width: 92,
                sortKey: (d) => d.dueDate ?? '',
                exportValue: (d) => d.dueDate ?? '',
                cell: (context, d) {
                  if (d.dueDate == null) {
                    return Text('—', style: T.monoSmall.copyWith(color: T.ghost));
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
                width: 120,
                numeric: true,
                sortKey: (d) => _amountOf(d.docType, d.totalTTC, d.amount),
                exportValue: (d) =>
                    _amountOf(d.docType, d.totalTTC, d.amount) / 100,
                cell: (context, d) => Text(
                    fmtDA(_amountOf(d.docType, d.totalTTC, d.amount)),
                    style: T.monoBody),
              ),
              ColumnSpec(
                id: 'paid',
                label: 'Payé',
                width: 110,
                numeric: true,
                sortKey: (d) => d.paid,
                exportValue: (d) => d.paymentStatus.isEmpty ? '' : d.paid / 100,
                cell: (context, d) => d.paymentStatus.isEmpty
                    ? Text('—', style: T.monoSmall.copyWith(color: T.ghost))
                    : Text(fmtDA(d.paid),
                        style: T.monoSmall.copyWith(color: T.muted)),
              ),
              ColumnSpec(
                id: 'remaining',
                label: 'Reste à payer',
                width: 120,
                numeric: true,
                sortKey: (d) => d.remaining,
                exportValue: (d) =>
                    d.paymentStatus.isEmpty ? '' : d.remaining / 100,
                cell: (context, d) {
                  if (d.paymentStatus.isEmpty) {
                    return Text('—', style: T.monoSmall.copyWith(color: T.ghost));
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
                width: 178,
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
                    {'paid': 'payé', 'partial': 'partiel', 'due': 'à payer'}[
                            d.paymentStatus] ??
                        '',
                ].join(' · '),
                cell: (context, d) => Wrap(spacing: 4, children: [
                  StatusChip(status: d.status, orderStatus: d.orderStatus),
                  PaymentChip(status: d.paymentStatus, overdue: _overdue(d)),
                ]),
              ),
              ColumnSpec(
                id: 'supplier_ref',
                label: 'Réf. fournisseur',
                width: 120,
                visibleByDefault: false,
                sortKey: (d) => d.supplierRef ?? '',
                exportValue: (d) => d.supplierRef ?? '',
                cell: (context, d) =>
                    Text(d.supplierRef ?? '—', style: T.monoSmall),
              ),
              ColumnSpec(
                id: 'payment',
                label: 'Règlement',
                width: 90,
                visibleByDefault: false,
                sortKey: (d) => d.paymentMethod ?? '',
                exportValue: (d) => paymentLabels[d.paymentMethod] ?? '',
                cell: (context, d) => Text(
                    paymentLabels[d.paymentMethod] ?? '—',
                    style: T.small.copyWith(fontSize: 11)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact period picker: quick presets + custom from/to — a small popup,
/// not a full-screen calendar.
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
        width: 320,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MicroLabel('Période personnalisée'),
              const SizedBox(height: 8),
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
              const SizedBox(height: 12),
              Row(children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Annuler', style: T.small.copyWith(color: T.muted)),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rInner),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MicroLabel(label),
            const SizedBox(height: 2),
            Text(value, style: T.monoBody.copyWith(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail dialog
// ---------------------------------------------------------------------------

/// Document detail dialog with actions. Returns true if the document changed
/// (or a new document was created from it). Public: other screens (stock,
/// partners…) open documents through it.
Future<bool?> showDocDetailDialog(
    BuildContext context, ApiClient api, String docId,
    {DocEditorConfig? Function(String docType)? editorFor}) {
  return showDialog<bool>(
    context: context,
    builder: (context) =>
        _DocDetailDialog(api: api, docId: docId, editorFor: editorFor),
  );
}

class _DocDetailDialog extends StatefulWidget {
  const _DocDetailDialog(
      {required this.api, required this.docId, this.editorFor});
  final ApiClient api;
  final String docId;
  final DocEditorConfig? Function(String docType)? editorFor;

  @override
  State<_DocDetailDialog> createState() => _DocDetailDialogState();
}

class _DocDetailDialogState extends State<_DocDetailDialog> {
  DocDetail? _doc;
  List<DocAttachment> _attachments = const [];
  String? _error;
  bool _busy = false;
  bool _changed = false;

  DocEditorConfig? Function(String) get _editorFor =>
      widget.editorFor ?? docEditorConfigFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.getDocument(widget.docId);
      if (mounted) setState(() => _doc = d);
      _loadAttachments();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadAttachments() async {
    try {
      final a = await widget.api.documentAttachments(widget.docId);
      if (mounted) setState(() => _attachments = a);
    } catch (_) {}
  }

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

  Future<void> _post() async {
    final d = _doc!;
    final lines = d.lines.length;
    final ok = await confirmAction(context,
        title: 'Valider ${docTypeLabels[d.docType] ?? 'ce document'} ?',
        message: '$lines ligne${lines > 1 ? 's' : ''} · total TTC '
            '${fmtDA(_amountOf(d.docType, d.totalTTC, d.amount))}\n'
            '${stockImpactText(d.docType, d.lines, onReference: d.refDocumentId != null)}\n'
            'Un document validé reçoit son numéro et ne se modifie plus '
            '(il se contrepasse).',
        confirmLabel: 'Valider',
        icon: Icons.task_alt_rounded);
    if (!ok) return;
    await _run(() async {
      await widget.api.postDocument(widget.docId);
      _changed = true;
      await _load();
    });
  }

  Future<void> _cancel() async {
    if (await cancelDraftFlow(context, widget.api, widget.docId)) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _void() async {
    if (await voidDocumentFlow(context, widget.api, widget.docId)) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _edit() async {
    final cfg = _editorFor(_doc!.docType);
    if (cfg == null) return;
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DocEditorScreen(api: widget.api, config: cfg, existing: _doc),
    ));
    if (!mounted) return;
    if (changed == true) {
      Navigator.of(context).pop(true);
    } else {
      await _load();
    }
  }

  /// Opens an editor over the dialog (duplicate / convert / receive); when
  /// something was saved, the dialog closes so the list refreshes.
  Future<void> _leaveTo(Future<bool> Function(BuildContext) open) async {
    final saved = await open(context);
    if (saved && mounted) Navigator.of(context).pop(true);
  }

  /// Clôture du reliquat : la fin normale de la plupart des BC de ce marché.
  Future<void> _closeOrder() async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: Text('Clôturer le reliquat', style: T.h2),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                'Les quantités non reçues seront annulées. La commande ne '
                'pourra plus recevoir.',
                style: T.body.copyWith(height: 1.4)),
            const SizedBox(height: 10),
            TextField(
                controller: reason,
                style: T.body,
                decoration: const InputDecoration(labelText: 'Motif')),
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

  /// Écarts de rapprochement contre le document lié (facture vs réception,
  /// réception vs commande).
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
        title: Text('Rapprochement', style: T.h2),
        content: SizedBox(
          width: 460,
          child: items.isEmpty
              ? Text('Aucun écart : les documents concordent.', style: T.body)
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final x in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Icon(
                            switch (x.kind) {
                              'price' => Icons.price_change_outlined,
                              'qty' => Icons.exposure_outlined,
                              _ => Icons.help_outline,
                            },
                            size: 16,
                            color: T.warnDark),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(x.product, style: T.body),
                                Text(
                                    x.kind == 'price'
                                        ? '${x.detail} : ${fmtDA(x.thisValue)} vs ${fmtDA(x.refValue)}'
                                        : x.kind == 'qty'
                                            ? '${x.detail} : ${fmtQty(x.thisValue)} vs ${fmtQty(x.refValue)}'
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

  /// One "bon de garantie" per product of the document sold with a warranty.
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
      Partner? partner;
      if (d.partnerId != null) {
        try {
          partner = await widget.api.getPartner(d.partnerId!);
        } catch (_) {}
      }
      final rec = await widget.api.defaultTemplate('warranty');
      final tpl =
          rec == null ? defaultTplDoc('warranty', 'fr') : TplDoc.fromJson(rec.body);
      for (final p in withWarranty) {
        final bytes = await renderTemplateBytes(tpl,
            lang: rec?.lang ?? 'fr',
            data: warrantyData(
                product: p, doc: d, client: partner, company: company));
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

  Widget _infoSection(DocDetail d) {
    final rows = <Widget>[
      if (d.paymentStatus.isNotEmpty)
        Row(children: [
          const MicroLabel('Règlement'),
          const SizedBox(width: 8),
          PaymentChip(
              status: d.paymentStatus,
              overdue: d.dueDate != null &&
                  d.remaining > 0 &&
                  d.dueDate!.compareTo(todayISO()) < 0),
          const SizedBox(width: 10),
          Text('payé ${fmtDA(d.paid)}', style: T.monoSmall),
          if (d.remaining > 0) ...[
            const SizedBox(width: 10),
            Text('reste ${fmtDA(d.remaining)}',
                style: T.monoSmall.copyWith(
                    color: T.warnDark, fontWeight: FontWeight.w700)),
          ],
          if (d.dueDate != null) ...[
            const SizedBox(width: 10),
            Text('échéance ${d.dueDate}', style: T.monoSmall),
          ],
        ]),
      if ((d.notes ?? '').isNotEmpty)
        _noteLine(Icons.print_outlined, 'Note (imprimée)', d.notes!),
      if ((d.internalNotes ?? '').isNotEmpty)
        _noteLine(Icons.lock_outline_rounded, 'Note interne', d.internalNotes!),
      Row(children: [
        const Icon(Icons.attach_file_rounded, size: 14, color: T.faint),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final a in _attachments)
              InputChip(
                label: Text('${a.name} · ${fmtFileSize(a.size)}',
                    style: T.small.copyWith(fontSize: 11.5, color: T.ink)),
                onPressed: () =>
                    openAttachment(context, widget.api, widget.docId, a),
                onDeleted: _busy ? null : () => _deleteAttachment(a),
                deleteButtonTooltipMessage: 'Supprimer',
                tooltip: 'Ouvrir',
                visualDensity: VisualDensity.compact,
                backgroundColor: T.bg,
                side: const BorderSide(color: T.border),
              ),
            TextButton.icon(
              onPressed: _busy ? null : _addAttachment,
              icon: const Icon(Icons.add_rounded, size: 15, color: T.muted),
              label: Text(
                  _attachments.isEmpty ? 'Joindre un fichier' : 'Joindre',
                  style: T.small.copyWith(color: T.muted)),
            ),
          ]),
        ),
      ]),
    ];
    return Container(
      color: T.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in rows)
            Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: r),
        ],
      ),
    );
  }

  Widget _noteLine(IconData icon, String label, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: T.faint),
          const SizedBox(width: 6),
          SizedBox(width: 110, child: MicroLabel(label)),
          Expanded(
              child: Text(text,
                  style: T.body.copyWith(fontSize: 12.5), maxLines: 3)),
        ],
      );

  List<PopupMenuEntry<VoidCallback>> _moreItems(DocDetail d) {
    PopupMenuItem<VoidCallback> item(
            String label, IconData icon, VoidCallback onTap) =>
        PopupMenuItem<VoidCallback>(
          value: onTap,
          height: 36,
          child: Row(children: [
            Icon(icon, size: 16, color: T.muted),
            const SizedBox(width: 10),
            Text(label, style: T.body.copyWith(fontSize: 13)),
          ]),
        );
    return [
      if (docEditorConfigFor(d.docType) != null)
        item('Dupliquer', Icons.copy_all_rounded,
            () => _leaveTo((c) => duplicateDocument(c, widget.api, d))),
      for (final (label, target)
          in docConversions(d.docType, d.status, d.orderStatus))
        item('Convertir en $label', Icons.transform_rounded,
            () => _leaveTo((c) => convertDocument(c, widget.api, d, target))),
      if (d.status == 'posted' &&
          (d.docType == 'SALE_TICKET' ||
              d.docType == 'SALE_INVOICE' ||
              d.docType == 'DELIVERY_NOTE'))
        item('Bon de garantie', Icons.verified_user_outlined, _printWarranty),
      if (d.status == 'posted' &&
          d.refDocumentId != null &&
          (d.docType == 'PURCHASE_INVOICE' || d.docType == 'PURCHASE_RECEIPT'))
        item('Écarts (rapprochement)', Icons.rule_rounded, _match),
      if (d.status == 'posted' &&
          d.docType == 'PURCHASE_ORDER' &&
          d.orderStatus != 'closed' &&
          d.orderStatus != 'received')
        item('Clôturer le reliquat', Icons.lock_clock_outlined, _closeOrder),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return Dialog(
      backgroundColor: T.bg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 680,
        height: 620,
        child: d == null
            ? Center(
                child: _error != null
                    ? Text(_error!, style: T.bodyMuted)
                    : const CircularProgressIndicator(color: T.mint))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                            Text(docTypeLabels[d.docType] ?? d.docType,
                                style: T.h2),
                            const SizedBox(height: 3),
                            Text(
                                '${d.number ?? 'brouillon'} · ${d.docDate}'
                                '${d.supplierRef != null ? ' · réf. ${d.supplierRef}' : ''}'
                                '${d.reason != null ? ' · motif : ${d.reason}' : ''}',
                                style: T.monoSmall),
                          ],
                        ),
                      ),
                      StatusChip(status: d.status, orderStatus: d.orderStatus),
                      IconButton(
                        tooltip: 'Fermer',
                        onPressed: () => Navigator.of(context).pop(_changed),
                        icon: const Icon(Icons.close, size: 18, color: T.muted),
                      ),
                    ]),
                  ),
                  const Divider(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: FieldError(_error),
                    ),
                  Expanded(
                    child: d.docType == 'PAYMENT_IN' ||
                            d.docType == 'PAYMENT_OUT'
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const MicroLabel('Montant'),
                                const SizedBox(height: 6),
                                Text(fmtDA(d.amount), style: T.monoBig),
                                const SizedBox(height: 6),
                                Text(
                                    paymentLabels[d.paymentMethod] ??
                                        d.paymentMethod ??
                                        '',
                                    style: T.bodyMuted),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: d.lines.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) {
                              final l = d.lines[i];
                              final extras = <String>[
                                if (l.productId == null) 'ligne libre',
                                if (l.qtyFreeMilli > 0)
                                  '+${fmtQty(l.qtyFreeMilli)} gratuit',
                                if (l.packFactorMilli != 1000)
                                  'pack ×${fmtQty(l.packFactorMilli)}',
                                if ((l.lotNumber ?? '').isNotEmpty)
                                  'lot ${l.lotNumber}',
                                if ((l.expiryDate ?? '').isNotEmpty)
                                  'DLC ${l.expiryDate}',
                                if (d.docType == 'PURCHASE_ORDER' &&
                                    d.status == 'posted')
                                  'reçu ${fmtQty(l.qtyReceivedMilli)}/${fmtQty(l.qtyMilli)}'
                                      '${l.qtyCancelledMilli > 0 ? ' · annulé ${fmtQty(l.qtyCancelledMilli)}' : ''}',
                              ];
                              final transfer = d.docType == 'STOCK_TRANSFER';
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(children: [
                                        Expanded(
                                            child: Text(l.description,
                                                style: T.body,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        SizedBox(
                                            width: 70,
                                            child: Text('×${fmtQty(l.qtyMilli)}',
                                                style: T.monoSmall)),
                                        if (!transfer) ...[
                                          SizedBox(
                                              width: 100,
                                              child: Text(fmtDA(l.unitPrice),
                                                  textAlign: TextAlign.end,
                                                  style: T.monoSmall)),
                                          SizedBox(
                                              width: 110,
                                              child: Text(fmtDA(l.lineTTC),
                                                  textAlign: TextAlign.end,
                                                  style: T.monoBody)),
                                        ],
                                      ]),
                                      if (extras.isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 2),
                                          child: Text(extras.join('  ·  '),
                                              style: T.small
                                                  .copyWith(fontSize: 10.5)),
                                        ),
                                    ]),
                              );
                            },
                          ),
                  ),
                  const Divider(),
                  _infoSection(d),
                  const Divider(),
                  Container(
                    decoration: const BoxDecoration(
                      color: T.surface,
                      borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(T.rCard)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      if (d.docType != 'STOCK_TRANSFER') ...[
                        if (d.timbre > 0) ...[
                          MicroLabel('Timbre ${fmtDA(d.timbre)}'),
                          const SizedBox(width: 16),
                        ],
                        MicroLabel(
                            'HT ${fmtDA(d.totalHT)} · TVA ${fmtDA(d.totalVAT)}'),
                      ],
                      const Spacer(),
                      if (canPdf(d.docType)) ...[
                        TextButton.icon(
                          onPressed: _busy ? null : _pdf,
                          icon: const Icon(Icons.picture_as_pdf_outlined,
                              size: 14, color: T.muted),
                          label: Text('PDF',
                              style: T.small.copyWith(color: T.muted)),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (_moreItems(d).isNotEmpty)
                        PopupMenuButton<VoidCallback>(
                          tooltip: 'Plus d’actions',
                          enabled: !_busy,
                          color: T.surface,
                          position: PopupMenuPosition.over,
                          itemBuilder: (_) => _moreItems(d),
                          onSelected: (f) => f(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('Plus',
                                  style: T.small.copyWith(color: T.muted)),
                              const Icon(Icons.expand_more_rounded,
                                  size: 16, color: T.muted),
                            ]),
                          ),
                        ),
                      if (d.status == 'posted' &&
                          d.docType == 'PURCHASE_ORDER' &&
                          d.orderStatus != 'closed' &&
                          d.orderStatus != 'received') ...[
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _leaveTo((c) =>
                                  convertDocument(c, widget.api, d, 'RECEIVE')),
                          icon: const Icon(Icons.move_to_inbox_outlined,
                              size: 14, color: T.mintDark),
                          label: Text('Recevoir',
                              style: T.small.copyWith(
                                  color: T.mintDark,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (d.status == 'posted' &&
                          !d.docType.startsWith('PAYMENT')) ...[
                        TextButton(
                          onPressed: _busy ? null : _void,
                          child: Text('Contrepasser',
                              style: T.small.copyWith(color: T.dangerDark)),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (d.status == 'draft') ...[
                        TextButton(
                          onPressed: _busy ? null : _cancel,
                          child: Text('Annuler',
                              style: T.small.copyWith(color: T.dangerDark)),
                        ),
                        const SizedBox(width: 6),
                        if (_editorFor(d.docType) != null) ...[
                          TextButton(
                            onPressed: _busy ? null : _edit,
                            child: Text('Modifier',
                                style: T.small.copyWith(color: T.muted)),
                          ),
                          const SizedBox(width: 6),
                        ],
                        SizedBox(
                          width: 120,
                          child: PrimaryButton(
                            label: 'Valider',
                            onPressed: _busy ? null : _post,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      if (d.docType != 'STOCK_TRANSFER')
                        Text(fmtDA(_amountOf(d.docType, d.totalTTC, d.amount)),
                            style: T.monoBig.copyWith(fontSize: 20)),
                    ]),
                  ),
                ],
              ),
      ),
    );
  }
}
