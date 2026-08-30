import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
import '../util/invoice_pdf.dart';
import 'data_table.dart';
import 'doc_editor.dart';
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
  const StatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (status) {
      'posted' => ('validé', T.mintTint, T.mintDark),
      'cancelled' => ('annulé', T.dangerTint, T.dangerDark),
      _ => ('brouillon', T.cream, T.faint),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(T.rChip)),
      child: Text(label.toUpperCase(),
          style: T.label.copyWith(color: fg, fontSize: 9)),
    );
  }
}

/// Filterable, sortable, exportable document list — the list archetype for
/// documents, shared by Ventes and Achats.
class DocListPane extends StatefulWidget {
  const DocListPane({
    super.key,
    required this.api,
    required this.allTypes,
    required this.editorFor,
    required this.exportName,
    this.partnerNames = const {},
  });

  final ApiClient api;
  final List<String> allTypes;
  final Map<String, String>? partnerNames;
  final String exportName;

  /// Returns the editor config for a draft of the given type, or null.
  final DocEditorConfig? Function(String docType) editorFor;

  @override
  State<DocListPane> createState() => DocListPaneState();
}

class DocListPaneState extends State<DocListPane> {
  String? _typeFilter;
  String? _statusFilter;
  DateTime? _from;
  DateTime? _to;
  List<DocSummary> _docs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fr(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  Future<void> refresh() async {
    setState(() => _loading = true);
    try {
      final from = _from == null ? null : _iso(_from!);
      final to = _to == null ? null : _iso(_to!);
      List<DocSummary> docs;
      if (_typeFilter != null) {
        docs = await widget.api.documents(
            type: _typeFilter,
            status: _statusFilter,
            from: from,
            to: to,
            limit: 500);
      } else {
        final all = await Future.wait([
          for (final t in widget.allTypes)
            widget.api.documents(
                type: t, status: _statusFilter, from: from, to: to, limit: 200),
        ]);
        docs = all.expand((e) => e).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
      if (mounted) {
        setState(() {
          _docs = docs;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDetail(DocSummary d) async {
    final changed = await showDocDetailDialog(context, widget.api, d.id,
        editorFor: widget.editorFor);
    if (changed == true) refresh();
  }

  Future<void> _pickRange() async {
    final range = await showDialog<(DateTime, DateTime)>(
      context: context,
      builder: (_) => _PeriodDialog(from: _from, to: _to),
    );
    if (range != null) {
      setState(() {
        _from = range.$1;
        _to = range.$2;
      });
      refresh();
    }
  }

  Future<void> _export(List<DocSummary> rows) async {
    final path = await exportCsv(
      baseName: widget.exportName,
      headers: [
        'Numéro',
        'Type',
        'Partenaire',
        'Statut',
        'Date',
        'Total TTC (DA)'
      ],
      rows: [
        for (final d in rows)
          [
            d.number ?? '',
            docTypeLabels[d.docType] ?? d.docType,
            widget.partnerNames?[d.partnerId] ?? '',
            d.status,
            d.docDate,
            editDA(d.docType.startsWith('PAYMENT') ? d.amount : d.totalTTC),
          ]
      ],
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Text('Exporté : $path',
            style: const TextStyle(
                fontFamily: T.mono, fontSize: 12, color: Colors.white)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _FilterPill(
            label: 'Tous',
            selected: _typeFilter == null,
            onTap: () {
              setState(() => _typeFilter = null);
              refresh();
            },
          ),
          for (final t in widget.allTypes)
            _FilterPill(
              label: docTypeLabels[t] ?? t,
              selected: _typeFilter == t,
              onTap: () {
                setState(() => _typeFilter = t);
                refresh();
              },
            ),
          const Spacer(),
          // Date range
          InkWell(
            onTap: _pickRange,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: _from != null ? T.mintTint : T.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                    color: _from != null ? T.mintDeep : T.border),
              ),
              child: Row(children: [
                Icon(Icons.calendar_today_outlined,
                    size: 13,
                    color: _from != null ? T.mintDark : T.faint),
                const SizedBox(width: 6),
                Text(
                  _from == null
                      ? 'Période'
                      : '${_fr(_from!)} → ${_fr(_to!)}',
                  style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _from != null ? T.mintDark : T.muted,
                  ),
                ),
                if (_from != null) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _from = null;
                        _to = null;
                      });
                      refresh();
                    },
                    child:
                        const Icon(Icons.close, size: 13, color: T.mintDark),
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(width: 6),
          _FilterPill(
            label: 'Brouillons',
            selected: _statusFilter == 'draft',
            onTap: () {
              setState(() =>
                  _statusFilter = _statusFilter == 'draft' ? null : 'draft');
              refresh();
            },
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: DataListView<DocSummary>(
            items: _docs,
            onTap: _openDetail,
            onExport: _export,
            empty: EmptyState(
                icon: Icons.receipt_long_outlined,
                text: _loading ? 'Chargement…' : 'Aucun document'),
            aggregates: (rows) => [
              (
                'Total TTC',
                fmtDA(rows.fold(
                    0,
                    (s, d) =>
                        s +
                        (d.docType.startsWith('PAYMENT')
                            ? d.amount
                            : d.totalTTC)))
              ),
              (
                'Brouillons',
                '${rows.where((d) => d.status == 'draft').length}'
              ),
            ],
            columns: [
              ColumnSpec(
                label: 'Numéro',
                width: 140,
                sortKey: (d) => d.number ?? '',
                cell: (context, d) => Text(d.number ?? '—',
                    style: T.monoBody.copyWith(
                        fontSize: 12,
                        color: d.number == null ? T.ghost : T.ink)),
              ),
              ColumnSpec(
                label: 'Type',
                flex: 2,
                sortKey: (d) => docTypeLabels[d.docType] ?? d.docType,
                cell: (context, d) => Text(
                    docTypeLabels[d.docType] ?? d.docType,
                    style: T.body),
              ),
              ColumnSpec(
                label: 'Partenaire',
                flex: 3,
                sortKey: (d) =>
                    (widget.partnerNames?[d.partnerId] ?? '').toLowerCase(),
                cell: (context, d) => Text(
                    widget.partnerNames?[d.partnerId] ?? '—',
                    style: T.bodyMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec(
                label: 'Règlement',
                width: 90,
                sortKey: (d) => d.paymentMethod ?? '',
                cell: (context, d) => Text(
                    paymentLabels[d.paymentMethod] ?? '—',
                    style: T.small.copyWith(fontSize: 11)),
              ),
              ColumnSpec(
                label: 'Statut',
                width: 88,
                sortKey: (d) => d.status,
                cell: (context, d) => StatusChip(status: d.status),
              ),
              ColumnSpec(
                label: 'Total TTC',
                width: 120,
                numeric: true,
                sortKey: (d) =>
                    d.docType.startsWith('PAYMENT') ? d.amount : d.totalTTC,
                cell: (context, d) => Text(
                    fmtDA(d.docType.startsWith('PAYMENT')
                        ? d.amount
                        : d.totalTTC),
                    style: T.monoBody),
              ),
              ColumnSpec(
                label: 'Date',
                width: 95,
                numeric: true,
                sortKey: (d) => d.docDate,
                cell: (context, d) =>
                    Text(d.docDate, style: T.monoSmall),
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

  List<(String, DateTime, DateTime)> get _presets {
    final today = _day(DateTime.now());
    final monthStart = DateTime(today.year, today.month, 1);
    final lastMonthStart = DateTime(today.year, today.month - 1, 1);
    final lastMonthEnd = monthStart.subtract(const Duration(days: 1));
    return [
      ("Aujourd'hui", today, today),
      ('Hier', today.subtract(const Duration(days: 1)),
          today.subtract(const Duration(days: 1))),
      ('7 derniers jours', today.subtract(const Duration(days: 6)), today),
      ('30 derniers jours', today.subtract(const Duration(days: 29)), today),
      ('Ce mois', monthStart, today),
      ('Mois dernier', lastMonthStart, lastMonthEnd),
      ('Cette année', DateTime(today.year, 1, 1), today),
    ];
  }

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
              const MicroLabel('Période'),
              const SizedBox(height: 8),
              for (final (label, from, to) in _presets)
                InkWell(
                  onTap: () => Navigator.of(context).pop((from, to)),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 7),
                    child: Row(children: [
                      Expanded(child: Text(label, style: T.body)),
                      Text(
                          from == to
                              ? _fr(from)
                              : '${_fr(from).substring(0, 5)} → ${_fr(to).substring(0, 5)}',
                          style: T.monoSmall),
                    ]),
                  ),
                ),
              const Divider(height: 18),
              const MicroLabel('Personnalisée'),
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
                  child: Text('Annuler',
                      style: T.small.copyWith(color: T.muted)),
                ),
                const Spacer(),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(
                    label: 'Appliquer',
                    onPressed: _from != null && _to != null
                        ? () =>
                            Navigator.of(context).pop((_from!, _to!))
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

class _FilterPill extends StatelessWidget {
  const _FilterPill(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : T.muted,
              )),
        ),
      ),
    );
  }
}

/// Document detail dialog with actions. Returns true if the document changed.
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
  String? _error;
  bool _busy = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.getDocument(widget.docId);
      if (mounted) setState(() => _doc = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _post() async {
    setState(() => _busy = true);
    try {
      await widget.api.postDocument(widget.docId);
      _changed = true;
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    try {
      await widget.api.cancelDocument(widget.docId);
      _changed = true;
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final cfg = widget.editorFor?.call(_doc!.docType);
    if (cfg == null) return;
    final nav = Navigator.of(context);
    nav.pop(true);
    await nav.push(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, existing: _doc),
    ));
  }

  Future<void> _pdf() async {
    final d = _doc;
    if (d == null || _busy) return;
    setState(() => _busy = true);
    try {
      final company = await widget.api.settings();
      Partner? partner;
      if (d.partnerId != null) {
        try {
          partner = await widget.api.getPartner(d.partnerId!);
        } catch (_) {}
      }
      await openDocumentPdf(company: company, doc: d, partner: partner);
    } catch (e) {
      if (mounted) setState(() => _error = 'PDF impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return Dialog(
      backgroundColor: T.bg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 640,
        height: 560,
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
                            Text('${d.number ?? 'brouillon'} · ${d.docDate}',
                                style: T.monoSmall),
                          ],
                        ),
                      ),
                      StatusChip(status: d.status),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(_changed),
                        icon:
                            const Icon(Icons.close, size: 18, color: T.muted),
                      ),
                    ]),
                  ),
                  const Divider(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: Text(_error!,
                          style: T.small.copyWith(color: T.dangerDark)),
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
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(l.description,
                                          style: T.body,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis)),
                                  SizedBox(
                                      width: 70,
                                      child: Text('×${fmtQty(l.qtyMilli)}',
                                          style: T.monoSmall)),
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
                      if (d.timbre > 0) ...[
                        MicroLabel('Timbre ${fmtDA(d.timbre)}'),
                        const SizedBox(width: 16),
                      ],
                      MicroLabel(
                          'HT ${fmtDA(d.totalHT)} · TVA ${fmtDA(d.totalVAT)}'),
                      const Spacer(),
                      if (canPdf(d.docType)) ...[
                        TextButton.icon(
                          onPressed: _busy ? null : _pdf,
                          icon: const Icon(Icons.picture_as_pdf_outlined,
                              size: 14, color: T.muted),
                          label: Text('PDF',
                              style: T.small.copyWith(color: T.muted)),
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
                        if (widget.editorFor?.call(d.docType) != null) ...[
                          TextButton(
                            onPressed: _busy ? null : _edit,
                            child: Text('Modifier',
                                style: T.small.copyWith(color: T.muted)),
                          ),
                          const SizedBox(width: 6),
                        ],
                        SizedBox(
                          width: 130,
                          child: PrimaryButton(
                            label: 'Valider',
                            onPressed: _busy ? null : _post,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      Text(
                          fmtDA(d.docType.startsWith('PAYMENT')
                              ? d.amount
                              : d.totalTTC),
                          style: T.monoBig.copyWith(fontSize: 20)),
                    ]),
                  ),
                ],
              ),
      ),
    );
  }
}
