import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../util/list_export.dart';
import '../../util/analysis_links.dart';
import '../../widgets/analyze_button.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_editor.dart';
import '../../widgets/doc_list.dart';
import '../../widgets/ui.dart';

/// « client » / « fournisseur » / « client et fournisseur ».
String partnerKindWord(String kind) => switch (kind) {
      'customer' => 'client',
      'supplier' => 'fournisseur',
      _ => 'client et fournisseur',
    };

/// Crumb of the list a partner belongs to.
String partnerListLabel(String kind) =>
    kind == 'supplier' ? 'Fournisseurs' : 'Clients';

/// Plain sentence about a balance (positive = the partner owes us).
String partnerBalanceSentence(Partner p) {
  final who = switch (p.kind) {
    'supplier' => 'Ce fournisseur',
    'customer' => 'Ce client',
    _ => p.name,
  };
  final whom = switch (p.kind) {
    'supplier' => 'ce fournisseur',
    'customer' => 'ce client',
    _ => p.name,
  };
  if (p.balance > 0) return '$who vous doit ${fmtDA(p.balance)}.';
  if (p.balance < 0) return 'Vous devez ${fmtDA(-p.balance)} à $whom.';
  return 'Compte à jour : personne ne doit rien.';
}

/// Opens the partner detail page. Returns true if something changed.
Future<bool> openPartnerDetail(
    BuildContext context, ApiClient api, Partner partner) async {
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => PartnerDetailPage(api: api, partner: partner),
  ));
  return changed == true;
}

/// Opens the create / edit page. Returns the saved partner, or null.
Future<Partner?> openPartnerForm(BuildContext context, ApiClient api,
    {Partner? existing, String kind = 'customer'}) {
  return Navigator.of(context).push<Partner>(MaterialPageRoute(
    builder: (_) =>
        PartnerFormPage(api: api, existing: existing, initialKind: kind),
  ));
}

/// Encaisser (client) / Payer (fournisseur) — a single quick action, so a
/// small dialog. [outgoing] forces the direction (partners that are both).
Future<bool> showPartnerPaymentDialog(
    BuildContext context, ApiClient api, Partner p,
    {bool? outgoing}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _PaymentDialog(
        api: api, partner: p, outgoing: outgoing ?? p.kind == 'supplier'),
  );
  return done == true;
}

// ---------------------------------------------------------------------------
// Detail page
// ---------------------------------------------------------------------------

class PartnerDetailPage extends StatefulWidget {
  const PartnerDetailPage(
      {super.key, required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<PartnerDetailPage> createState() => _PartnerDetailPageState();
}

class _PartnerDetailPageState extends State<PartnerDetailPage> {
  late Partner _p = widget.partner;
  PartnerOpenItems? _open;
  List<DocSummary> _docs = const [];
  List<InstallmentPlan> _plans = const [];
  bool _docsLoading = true;
  bool _busy = false;
  bool _changed = false;

  bool get _isCustomer => _p.kind != 'supplier';
  bool get _isSupplier => _p.kind != 'customer';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.getPartner(_p.id);
      if (mounted) setState(() => _p = p);
    } catch (_) {}
    try {
      final o = await widget.api.partnerOpenItems(_p.id);
      if (mounted) setState(() => _open = o);
    } catch (_) {}
    try {
      final d = await widget.api.documents(partnerId: _p.id, limit: 20);
      if (mounted) {
        setState(() {
          _docs = d;
          _docsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _docsLoading = false);
    }
    if (_isCustomer) {
      try {
        final plans = await widget.api.installmentPlans(partnerId: _p.id);
        if (mounted) setState(() => _plans = plans);
      } catch (_) {}
    }
  }

  void _back() => Navigator.of(context).pop(_changed);

  Future<void> _edit() async {
    final saved = await openPartnerForm(context, widget.api,
        existing: _p, kind: _p.kind);
    if (saved != null && mounted) {
      setState(() {
        _p = saved;
        _changed = true;
      });
      _load();
    }
  }

  Future<void> _pay({required bool outgoing}) async {
    if (await showPartnerPaymentDialog(context, widget.api, _p,
        outgoing: outgoing)) {
      _changed = true;
      _load();
    }
  }

  Future<void> _newDoc(DocEditorConfig cfg) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, initialPartner: _p),
    ));
    if (changed == true && mounted) {
      _changed = true;
      _load();
    }
  }

  Future<void> _openDoc(String id) async {
    final changed = await showDocDetailDialog(context, widget.api, id);
    if (changed == true && mounted) {
      _changed = true;
      _load();
    }
  }

  Future<void> _statementPdf() async {
    final o = _open;
    if (o == null || _busy) return;
    setState(() => _busy = true);
    try {
      Map<String, String> company = const {};
      try {
        company = await widget.api.settings();
      } catch (_) {}
      final table = ExportTable(
        title: 'Relevé — ${_p.name} — ${todayISO()}',
        baseName: 'releve-${_p.name.replaceAll(RegExp(r'[^\w-]+'), '_')}',
        headers: const [
          'Document',
          'Date',
          'Échéance',
          'Total',
          'Reste à payer',
          'Retard (jours)'
        ],
        numeric: const {3, 4, 5},
        rows: [
          for (final it in o.items)
            [
              it.number,
              it.docDate,
              it.dueDate,
              it.total / 100,
              it.outstanding / 100,
              _lateDays(it) ?? '',
            ],
          ['Total ouvert', '', '', '', o.totalOpen / 100, ''],
        ],
      );
      await exportTable(table, ExportFormat.pdf, company: company);
    } catch (e) {
      if (mounted) {
        showToast(context, 'Relevé impossible : $e', kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int? _lateDays(OpenItem it) {
    if (!it.overdue || it.dueDate.isEmpty) return null;
    final due = DateTime.tryParse(it.dueDate);
    if (due == null) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).difference(due).inDays;
  }

  Future<void> _newPlan() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _NewPlanDialog(api: widget.api, partner: _p),
    );
    if (created == true && mounted) {
      _changed = true;
      _load();
    }
  }

  /// Encaisser une échéance : encaissement espèces + échéance pointée.
  Future<void> _payDue(InstallmentDue d) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.createPayment(
        docType: 'PAYMENT_IN',
        partnerId: _p.id,
        amount: d.remaining,
        method: 'cash',
      );
      await widget.api.payInstallmentDue(d.id);
      _changed = true;
      if (mounted) showToast(context, 'Échéance de ${fmtDA(d.remaining)} encaissée.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- sections ----

  Widget _contactSection() => PageSection(
        title: 'Coordonnées',
        child: FactGrid(columns: 3, facts: [
          ('Type', partnerKindWord(_p.kind)),
          ('Téléphone', _p.phone ?? ''),
          ('Adresse', _p.address ?? ''),
          ('NIF', _p.nif ?? ''),
          ('NIS', _p.nis ?? ''),
          ('RC', _p.rc ?? ''),
          ('Article d’imposition (AI)', _p.ai ?? ''),
          if (_isCustomer)
            ('Tarif', _p.priceLevel == 'wholesale' ? 'Demi-gros' : 'Détail'),
          if ((_p.notes ?? '').isNotEmpty) ('Notes', _p.notes!),
        ]),
      );

  Widget _balanceSection() {
    final color = _p.balance > 0
        ? T.warnDark
        : _p.balance < 0
            ? T.mintDark
            : T.ink;
    final credit = _open?.unallocatedCredit ?? 0;
    return PageSection(
      title: 'Solde',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(fmtDA(_p.balance.abs()),
            style: T.monoBig.copyWith(color: color)),
        const SizedBox(height: 6),
        Text(partnerBalanceSentence(_p),
            style: T.body.copyWith(fontWeight: FontWeight.w600)),
        if (credit > 0) ...[
          const SizedBox(height: 6),
          Text(
              'Avoir pas encore utilisé : ${fmtDA(credit)} (il sera déduit des '
              'prochaines factures).',
              style: T.bodyMuted),
        ],
      ]),
    );
  }

  Widget _openItemsSection() {
    final o = _open;
    Widget head(String s, double? w, {bool end = false}) {
      final t = Text(s,
          style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return PageSection(
      title: 'Factures non payées',
      trailing: o != null && o.items.isNotEmpty
          ? Text('Total : ${fmtDA(o.totalOpen)}',
              style: T.monoBody.copyWith(
                  color: T.warnDark, fontWeight: FontWeight.w700))
          : null,
      child: o == null
          ? const SkeletonBar(width: 260, height: 14)
          : o.items.isEmpty
              ? Text('Aucune facture en attente de paiement : compte à jour.',
                  style: T.bodyMuted)
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      head('Document', null),
                      head('Date', 120),
                      head('Échéance', 120),
                      head('Total', 140, end: true),
                      head('Reste à payer', 150, end: true),
                      head('Retard', 100, end: true),
                    ]),
                  ),
                  const Divider(),
                  for (final it in o.items) ...[
                    InkWell(
                      onTap: it.documentId.isEmpty
                          ? null
                          : () => _openDoc(it.documentId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(children: [
                          Expanded(
                              child: Text(it.number.isEmpty ? '—' : it.number,
                                  style: T.monoBody)),
                          SizedBox(
                              width: 120,
                              child: Text(it.docDate, style: T.monoSmall)),
                          SizedBox(
                              width: 120,
                              child: Text(
                                  it.dueDate.isEmpty ? '—' : it.dueDate,
                                  style: T.monoSmall.copyWith(
                                      color: it.overdue ? T.warnDark : T.muted,
                                      fontWeight: it.overdue
                                          ? FontWeight.w800
                                          : FontWeight.w400))),
                          SizedBox(
                              width: 140,
                              child: Text(fmtDA(it.total),
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall)),
                          SizedBox(
                              width: 150,
                              child: Text(fmtDA(it.outstanding),
                                  textAlign: TextAlign.end,
                                  style: T.monoBody.copyWith(
                                      color: it.overdue ? T.warnDark : T.ink,
                                      fontWeight: FontWeight.w700))),
                          SizedBox(
                              width: 100,
                              child: Text(
                                  _lateDays(it) == null
                                      ? '—'
                                      : '${_lateDays(it)} j',
                                  textAlign: TextAlign.end,
                                  style: T.monoSmall.copyWith(
                                      color: it.overdue
                                          ? T.warnDark
                                          : T.muted))),
                        ]),
                      ),
                    ),
                    const Divider(),
                  ],
                ]),
    );
  }

  Widget _docsSection() {
    Widget head(String s, double? w, {bool end = false}) {
      final t = Text(s,
          style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return PageSection(
      title: 'Derniers documents',
      child: _docsLoading
          ? const SkeletonBar(width: 260, height: 14)
          : _docs.isEmpty
              ? EmptyState(
                  icon: Icons.receipt_long_outlined,
                  text: 'Aucun document avec ${_p.name} pour l’instant.',
                  actions: [
                    if (_isSupplier)
                      ('Nouveau bon de réception',
                          () => _newDoc(purchaseReceiptConfig)),
                    if (_isCustomer)
                      ('Nouvelle facture', () => _newDoc(saleInvoiceConfig)),
                  ],
                )
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      head('Date', 120),
                      head('Document', null),
                      head('Numéro', 180),
                      head('Total TTC', 150, end: true),
                      const SizedBox(width: 16),
                      head('Statut', 220),
                    ]),
                  ),
                  const Divider(),
                  for (final d in _docs) ...[
                    InkWell(
                      onTap: () => _openDoc(d.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(children: [
                          SizedBox(
                              width: 120,
                              child: Text(d.docDate, style: T.monoSmall)),
                          Expanded(
                              child: Text(
                                  docTypeLabels[d.docType] ?? d.docType,
                                  style: T.body,
                                  overflow: TextOverflow.ellipsis)),
                          SizedBox(
                              width: 180,
                              child: Text(d.number ?? 'Brouillon',
                                  overflow: TextOverflow.ellipsis,
                                  style: d.number == null
                                      ? T.small
                                      : T.monoSmall.copyWith(color: T.ink))),
                          SizedBox(
                              width: 150,
                              child: Text(
                                  fmtDA(docAmountOf(
                                      d.docType, d.totalTTC, d.amount)),
                                  textAlign: TextAlign.end,
                                  style: T.monoBody)),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 220,
                            child: Row(children: [
                              StatusChip(
                                  status: d.status, orderStatus: d.orderStatus),
                              if (d.paymentStatus.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                Flexible(
                                    child: PaymentChip(
                                        status: d.paymentStatus,
                                        overdue: d.dueDate != null &&
                                            d.remaining > 0 &&
                                            d.dueDate!.compareTo(todayISO()) <
                                                0)),
                              ],
                            ]),
                          ),
                        ]),
                      ),
                    ),
                    const Divider(),
                  ],
                ]),
    );
  }

  Widget _plansSection() {
    final today = todayISO();
    return PageSection(
      title: 'Paiement échelonné',
      trailing: TextButton.icon(
        onPressed: _busy ? null : _newPlan,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Nouveau plan'),
      ),
      child: _plans.isEmpty
          ? Text(
              'Aucun plan. Un plan découpe une dette en mensualités égales '
              '(vente à crédit).',
              style: T.bodyMuted)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final plan in _plans) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 6),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                          '${fmtDA(plan.total)} en ${plan.months} mois'
                          '${plan.docNumber != null ? ' · ${plan.docNumber}' : ''}',
                          style: T.body.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Text('Payé ${fmtDA(plan.totalPaid)} sur ${fmtDA(plan.total)}',
                        style: T.monoSmall),
                  ]),
                ),
                for (final d in plan.dues)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Icon(
                          d.settled
                              ? Icons.check_circle_rounded
                              : d.dueDate.compareTo(today) < 0
                                  ? Icons.error_rounded
                                  : Icons.schedule_rounded,
                          size: 18,
                          color: d.settled
                              ? T.mintDeep
                              : d.dueDate.compareTo(today) < 0
                                  ? T.danger
                                  : T.faint),
                      const SizedBox(width: 10),
                      SizedBox(
                          width: 120,
                          child: Text(d.dueDate, style: T.monoSmall)),
                      Expanded(child: Text(fmtDA(d.amount), style: T.monoBody)),
                      if (d.settled)
                        const DocChip(
                            label: 'Payée', bg: T.mintTint, fg: T.mintDark)
                      else
                        TextButton(
                          onPressed: _busy ? null : () => _payDue(d),
                          child: Text('Encaisser ${fmtDA(d.remaining)}',
                              style: T.body.copyWith(
                                  color: T.mintDark,
                                  fontWeight: FontWeight.w700)),
                        ),
                    ]),
                  ),
                const Divider(height: 18),
              ],
            ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return AppPage(
      crumbs: [
        Crumb(partnerListLabel(p.kind), _back),
        Crumb(p.name),
      ],
      title: p.name,
      subtitle: Text(
          [
            partnerKindWord(p.kind)[0].toUpperCase() +
                partnerKindWord(p.kind).substring(1),
            if ((p.phone ?? '').isNotEmpty) p.phone!,
          ].join(' · '),
          style: T.bodyMuted),
      onBack: _back,
      actions: [
        Flexible(
          child: Wrap(alignment: WrapAlignment.end, runSpacing: 8, children: [
            if (_isCustomer)
              PageAction(
                  label: 'Encaisser',
                  icon: Icons.payments_outlined,
                  onPressed: () => _pay(outgoing: false)),
            if (_isSupplier)
              PageAction(
                  label: 'Payer',
                  icon: Icons.payments_outlined,
                  onPressed: () => _pay(outgoing: true)),
            if (_isCustomer)
              PageAction(
                  label: 'Nouvelle facture',
                  icon: Icons.note_add_outlined,
                  onPressed: () => _newDoc(saleInvoiceConfig)),
            if (_isSupplier)
              PageAction(
                  label: 'Nouveau bon de réception',
                  icon: Icons.move_to_inbox_outlined,
                  onPressed: () => _newDoc(purchaseReceiptConfig)),
            AnalyzeButton(seeds: [
              if (_isCustomer) ...[
                AnalysisLinks.customer(_p.id, _p.name),
                AnalysisLinks.customerProducts(_p.id, _p.name),
              ],
              if (_isSupplier) AnalysisLinks.supplier(_p.id, _p.name),
            ]),
            PageAction(
                label: 'Relevé (PDF)',
                icon: Icons.picture_as_pdf_outlined,
                onPressed: _open == null || _busy ? null : _statementPdf),
            PageAction(
                label: 'Modifier',
                icon: Icons.edit_outlined,
                primary: true,
                onPressed: _edit),
          ]),
        ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _balanceSection(),
        _contactSection(),
        _openItemsSection(),
        _docsSection(),
        if (_isCustomer && (_plans.isNotEmpty || _p.balance > 0))
          _plansSection(),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Create / edit page
// ---------------------------------------------------------------------------

class PartnerFormPage extends StatefulWidget {
  const PartnerFormPage(
      {super.key, required this.api, this.existing, this.initialKind = 'customer'});
  final ApiClient api;
  final Partner? existing;
  final String initialKind;

  @override
  State<PartnerFormPage> createState() => _PartnerFormPageState();
}

class _PartnerFormPageState extends State<PartnerFormPage> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _address =
      TextEditingController(text: widget.existing?.address ?? '');
  late final _nif = TextEditingController(text: widget.existing?.nif ?? '');
  late final _nis = TextEditingController(text: widget.existing?.nis ?? '');
  late final _rc = TextEditingController(text: widget.existing?.rc ?? '');
  late final _ai = TextEditingController(text: widget.existing?.ai ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late String _kind = widget.existing?.kind ?? widget.initialKind;
  late String _priceLevel = widget.existing?.priceLevel ?? 'retail';
  bool _busy = false;
  Map<String, String> _err = const {};
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The page frame autofocuses for Échap: put the cursor in « Nom ».
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.existing == null) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _nif, _nis, _rc, _ai, _notes]) {
      c.dispose();
    }
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final e = partnerFieldErrors(
        name: _name.text, phone: _phone.text, nif: _nif.text);
    final nis = _nis.text.replaceAll(' ', '');
    if (nis.isNotEmpty && !RegExp(r'^\d{12,20}$').hasMatch(nis)) {
      e['nis'] = 'Le NIS ne contient que des chiffres (12 à 20).';
    }
    setState(() => _err = e);
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    String? v(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final saved = await widget.api.savePartner({
        'kind': _kind,
        'name': _name.text.trim(),
        'phone': v(_phone),
        'address': v(_address),
        'nif': v(_nif),
        'nis': v(_nis),
        'rc': v(_rc),
        'ai': v(_ai),
        'notes': v(_notes),
        'price_level': _kind == 'supplier' ? 'retail' : _priceLevel,
      }, id: widget.existing?.id);
      if (!mounted) return;
      final word = partnerKindWord(_kind);
      showToast(
          context,
          widget.existing == null
              ? '${word[0].toUpperCase()}${word.substring(1)} « ${saved.name} » créé.'
              : 'Modifications enregistrées.');
      Navigator.of(context).pop(saved);
    } on ApiException catch (ex) {
      final m = ex.message.toLowerCase();
      setState(() => _err = {
            m.contains('name') || m.contains('nom')
                ? 'name'
                : m.contains('nif')
                    ? 'nif'
                    : 'form': ex.message
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _choices(List<(String, String)> options, String value,
      ValueChanged<String> onSelect) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (label, v) in options)
        ChoiceChip(
          label: Text(label,
              style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: value == v ? T.mintDark : T.ink)),
          selected: value == v,
          selectedColor: T.mintTint2,
          backgroundColor: T.surface,
          side: BorderSide(color: value == v ? T.mintDeep : T.border3),
          showCheckmark: false,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          onSelected: (_) => setState(() => onSelect(v)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ex = widget.existing;
    final isNew = ex == null;
    final listLabel = partnerListLabel(ex?.kind ?? _kind);
    final showTarif = _kind != 'supplier' &&
        (Features.instance.wholesale || _priceLevel == 'wholesale');
    return AppPage(
      crumbs: [
        Crumb(listLabel, () => Navigator.of(context).pop()),
        if (!isNew) Crumb(ex.name, () => Navigator.of(context).pop()),
        Crumb(isNew ? (_kind == 'supplier' ? 'Nouveau fournisseur' : 'Nouveau client') : 'Modifier'),
      ],
      title: isNew
          ? (_kind == 'supplier' ? 'Nouveau fournisseur' : 'Nouveau client')
          : 'Modifier ${ex.name}',
      maxWidth: 760,
      actions: [
        PageAction(
            label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageSection(
          title: 'Type',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _choices(const [
              ('Client', 'customer'),
              ('Fournisseur', 'supplier'),
              ('Les deux', 'both'),
            ], _kind, (v) => _kind = v),
            const SizedBox(height: 6),
            Text(
                'Un « client » achète chez vous, un « fournisseur » vous vend '
                'de la marchandise.',
                style: T.small),
          ]),
        ),
        PageSection(
          title: 'Coordonnées',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormFieldBlock(
                label: 'Nom ou raison sociale',
                required: true,
                controller: _name,
                error: _err['name'],
                focusNode: _nameFocus,
                onSubmitted: _save),
            FormFieldBlock(
                label: 'Téléphone',
                controller: _phone,
                error: _err['phone'],
                helper: 'Ex. 0550 12 34 56',
                keyboard: TextInputType.phone,
                onSubmitted: _save),
            FormFieldBlock(
                label: 'Adresse', controller: _address, onSubmitted: _save),
          ]),
        ),
        PageSection(
          title: 'Informations fiscales',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                  'Utiles pour les factures à une entreprise. Laissez vide pour '
                  'un particulier.',
                  style: T.small),
            ),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: FormFieldBlock(
                      label: 'NIF',
                      controller: _nif,
                      error: _err['nif'],
                      helper: '15 à 20 chiffres',
                      onSubmitted: _save)),
              const SizedBox(width: 14),
              Expanded(
                  child: FormFieldBlock(
                      label: 'NIS',
                      controller: _nis,
                      error: _err['nis'],
                      onSubmitted: _save)),
            ]),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: FormFieldBlock(
                      label: 'RC (registre du commerce)',
                      controller: _rc,
                      onSubmitted: _save)),
              const SizedBox(width: 14),
              Expanded(
                  child: FormFieldBlock(
                      label: 'AI (article d’imposition)',
                      controller: _ai,
                      onSubmitted: _save)),
            ]),
          ]),
        ),
        if (showTarif)
          PageSection(
            title: 'Tarif',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _choices(const [
                ('Détail', 'retail'),
                ('Demi-gros', 'wholesale'),
              ], _priceLevel, (v) => _priceLevel = v),
              const SizedBox(height: 6),
              Text('Les prix proposés sur ses factures.', style: T.small),
            ]),
          ),
        PageSection(
          title: 'Notes',
          child: FormFieldBlock(
              label: 'Notes',
              controller: _notes,
              maxLines: 4,
              helper: 'Visible seulement dans le logiciel.'),
        ),
        if (_err['form'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FieldError(_err['form']),
          ),
      ]),
    );
  }
}

/// A plain form field: label above (red « * » when required), the field
/// (≥ 42 px), helper text, error under it.
class FormFieldBlock extends StatelessWidget {
  const FormFieldBlock({
    super.key,
    required this.label,
    required this.controller,
    this.required = false,
    this.error,
    this.helper,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboard,
    this.onSubmitted,
    this.hint,
    this.focusNode,
  });
  final String label;
  final TextEditingController controller;
  final bool required;
  final String? error;
  final String? helper;
  final String? hint;
  final FocusNode? focusNode;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboard;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: label, style: T.label),
          if (required)
            const TextSpan(
                text: ' *',
                style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: T.danger)),
        ])),
        const SizedBox(height: 5),
        Container(
          constraints: const BoxConstraints(minHeight: 44),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(
                color: error != null ? T.danger : T.border3,
                width: error != null ? 1.4 : 1),
          ),
          alignment: AlignmentDirectional.centerStart,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            maxLines: maxLines,
            keyboardType: maxLines > 1 ? TextInputType.multiline : keyboard,
            style: T.body,
            onSubmitted: onSubmitted == null || maxLines > 1
                ? null
                : (_) => onSubmitted!(),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: T.bodyMuted.copyWith(color: T.ghost),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        if (helper != null && error == null) ...[
          const SizedBox(height: 4),
          Text(helper!, style: T.small),
        ],
        FieldError(error),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Small dialogs: payment, new installment plan
// ---------------------------------------------------------------------------

class _NewPlanDialog extends StatefulWidget {
  const _NewPlanDialog({required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<_NewPlanDialog> createState() => _NewPlanDialogState();
}

class _NewPlanDialogState extends State<_NewPlanDialog> {
  late final _total = TextEditingController(
      text: widget.partner.balance > 0 ? editDA(widget.partner.balance) : '');
  final _months = TextEditingController(text: '3');
  late String _start = DateTime.now()
      .add(const Duration(days: 30))
      .toIso8601String()
      .substring(0, 10);
  bool _busy = false;
  Map<String, String> _err = const {};

  @override
  void dispose() {
    _total.dispose();
    _months.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_start) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _start =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    final total = parseDA(_total.text);
    final months = int.tryParse(_months.text.trim());
    final e = <String, String>{
      if (total == null || total <= 0) 'total': 'Indiquez le montant à étaler.',
      if (months == null || months < 1) 'months': 'Au moins 1 mois.',
    };
    setState(() => _err = e);
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.api.createInstallmentPlan(
        partnerId: widget.partner.id,
        total: total!,
        months: months!,
        startDate: _start,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (ex) {
      setState(() => _err = {'form': ex.message});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nouveau plan de paiement', style: T.h2),
              const SizedBox(height: 4),
              Text(
                  'La dette vient d’une vente à crédit ; le plan la découpe en '
                  'mensualités égales.',
                  style: T.small),
              const SizedBox(height: 16),
              FormFieldBlock(
                  label: 'Montant total (DA)',
                  required: true,
                  controller: _total,
                  error: _err['total'],
                  autofocus: true,
                  onSubmitted: _save),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: FormFieldBlock(
                        label: 'Nombre de mois',
                        required: true,
                        controller: _months,
                        error: _err['months'],
                        keyboard: TextInputType.number,
                        onSubmitted: _save)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Première échéance', style: T.label),
                        const SizedBox(height: 5),
                        InkWell(
                          onTap: _pickStart,
                          borderRadius: BorderRadius.circular(T.rInner),
                          child: Container(
                            height: 44,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            alignment: AlignmentDirectional.centerStart,
                            decoration: BoxDecoration(
                              color: T.surface,
                              borderRadius: BorderRadius.circular(T.rInner),
                              border: Border.all(color: T.border3),
                            ),
                            child: Row(children: [
                              const Icon(Icons.calendar_today_outlined,
                                  size: 16, color: T.faint),
                              const SizedBox(width: 8),
                              Text(_start, style: T.monoBody),
                            ]),
                          ),
                        ),
                      ]),
                ),
              ]),
              FieldError(_err['form']),
              const SizedBox(height: 10),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Annuler', style: T.body.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Créer le plan',
                    onPressed: _busy ? null : _save,
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

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog(
      {required this.api, required this.partner, required this.outgoing});
  final ApiClient api;
  final Partner partner;
  final bool outgoing;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final _amount = TextEditingController();
  String _method = 'cash';
  bool _busy = false;
  String? _error;

  bool get isOut => widget.outgoing;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = parseDA(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Indiquez un montant (ex. 12 500).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final doc = await widget.api.createPayment(
        docType: isOut ? 'PAYMENT_OUT' : 'PAYMENT_IN',
        partnerId: widget.partner.id,
        amount: cents,
        method: _method,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showToast(
          context,
          isOut
              ? 'Paiement de ${fmtDA(doc.amount)} enregistré (${doc.number ?? ''}).'
              : 'Encaissement de ${fmtDA(doc.amount)} enregistré (${doc.number ?? ''}).');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 440,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isOut ? 'Payer ${p.name}' : 'Encaisser ${p.name}',
                  style: T.h2),
              const SizedBox(height: 4),
              Text(partnerBalanceSentence(p), style: T.bodyMuted),
              const SizedBox(height: 16),
              Text.rich(TextSpan(children: [
                TextSpan(text: 'Montant (DA)', style: T.label),
                const TextSpan(
                    text: ' *',
                    style: TextStyle(
                        fontFamily: T.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: T.danger)),
              ])),
              const SizedBox(height: 5),
              Container(
                height: 52,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(
                      color: _error != null ? T.danger : T.border3),
                ),
                child: TextField(
                  controller: _amount,
                  autofocus: true,
                  style: T.monoBig.copyWith(fontSize: 22),
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => _save(),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '0,00',
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              FieldError(_error),
              const SizedBox(height: 14),
              Text('Mode de paiement', style: T.label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in ['cash', 'cib', 'cheque', 'transfer'])
                    ChoiceChip(
                      label: Text(paymentLabels[m]!,
                          style: TextStyle(
                              fontFamily: T.sans,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: _method == m ? T.mintDark : T.ink)),
                      selected: _method == m,
                      selectedColor: T.mintTint2,
                      backgroundColor: T.surface,
                      side: BorderSide(
                          color: _method == m ? T.mintDeep : T.border3),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Annuler', style: T.body.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: PrimaryButton(
                    label: _busy ? '…' : (isOut ? 'Payer' : 'Encaisser'),
                    onPressed: _busy ? null : _save,
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
