import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../api/dist_api.dart' show CustomerOrder;
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
import '../crm/crm_common.dart';
import '../crm/send_message.dart';
import '../orders/order_form_page.dart';
import '../orders/orders_screen.dart' show openOrderDetail;
import '../pricing/product_pricing_page.dart' show openClientPricing;
import 'partner_crm_tabs.dart';
import 'partner_orders_tab.dart';

/// Tabs of the client 360 page.
enum PartnerTab { overview, orders, timeline, contacts, tasks, activities, files, tags }

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

/// Opens the partner detail page (optionally on a given [tab]). Returns true
/// if something changed.
Future<bool> openPartnerDetail(
    BuildContext context, ApiClient api, Partner partner, {PartnerTab? tab}) async {
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => PartnerDetailPage(api: api, partner: partner, initialTab: tab),
  ));
  return changed == true;
}

/// Same, from a partner id only (task lists, segments…).
Future<bool> openPartnerDetailById(BuildContext context, ApiClient api, String partnerId,
    {PartnerTab? tab}) async {
  try {
    final p = await api.getPartner(partnerId);
    if (!context.mounted) return false;
    return openPartnerDetail(context, api, p, tab: tab);
  } catch (e) {
    if (context.mounted) showToast(context, errText(e), kind: ToastKind.error);
    return false;
  }
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
      {super.key, required this.api, required this.partner, this.initialTab});
  final ApiClient api;
  final Partner partner;
  final PartnerTab? initialTab;

  @override
  State<PartnerDetailPage> createState() => _PartnerDetailPageState();
}

class _PartnerDetailPageState extends State<PartnerDetailPage> {
  late Partner _p = widget.partner;
  PartnerOpenItems? _open;
  List<DocSummary> _docs = const [];
  List<InstallmentPlan> _plans = const [];
  LoyaltyAccount? _loyalty;
  bool _docsLoading = true;
  bool _busy = false;
  bool _changed = false;
  late PartnerTab _tab = widget.initialTab ?? PartnerTab.overview;
  List<CrmTag> _allTags = const [];
  int _refresh = 0;

  bool get _isCustomer => _p.kind != 'supplier';
  bool get _isSupplier => _p.kind != 'customer';

  /// CRM reading (KPI, timeline, contacts, files work with partners.view too).
  bool get _crm => crmView(widget.api);

  /// Messages: crm.view | orders.view.
  bool get _canMessage => _crm || crmCan(widget.api, 'orders.view');

  /// Customer orders: list (orders.view), create (orders.manage).
  bool get _canOrders => crmCan(widget.api, 'orders');
  bool get _canNewOrder => _canOrders && crmCan(widget.api, 'orders.manage');

  /// Special prices / quotas of this client.
  bool get _canPricing => crmCan(widget.api, 'pricing');

  List<(PartnerTab, String)> get _tabs => [
        (PartnerTab.overview, 'Vue d’ensemble'),
        if (_isCustomer && _canOrders) (PartnerTab.orders, 'Commandes'),
        if (_isCustomer) (PartnerTab.timeline, 'Chronologie'),
        (PartnerTab.contacts, 'Contacts'),
        if (_isCustomer && _crm) (PartnerTab.tasks, 'Tâches'),
        if (_isCustomer && _crm) (PartnerTab.activities, 'Activités'),
        (PartnerTab.files, 'Pièces'),
        if (_isCustomer) (PartnerTab.tags, 'Étiquettes'),
      ];

  @override
  void initState() {
    super.initState();
    _load();
    CrmDirectory.tags(widget.api).then((t) {
      if (mounted) setState(() => _allTags = t);
    });
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.getPartner(_p.id);
      if (mounted) setState(() => _p = p);
    } catch (_) {}
    if (mounted) setState(() => _refresh++);
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
      try {
        final l = await widget.api.partnerLoyalty(_p.id);
        if (mounted) setState(() => _loyalty = l);
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

  Future<void> _message() async {
    final sent = await showSendMessagePanel(context, widget.api,
        partnerId: _p.id, partnerName: _p.name, templateCode: _p.balance > 0 ? 'payment_reminder' : null);
    if (sent && mounted) setState(() => _refresh++);
  }

  /// « Nouvelle commande » : the order form, already on this client; once
  /// saved, the order page opens.
  Future<void> _newOrder() async {
    final user = widget.api.user;
    if (user == null) return;
    final created = await Navigator.of(context).push<CustomerOrder>(MaterialPageRoute(
      builder: (_) => OrderFormPage(api: widget.api, user: user, initialPartner: _p),
    ));
    if (created == null || !mounted) return;
    _changed = true;
    setState(() {
      _tab = PartnerTab.orders;
      _refresh++;
    });
    await openOrderDetail(context, widget.api, user, created.id);
    if (mounted) setState(() => _refresh++);
  }

  Future<void> _activity() async {
    final a = await openActivityForm(context, widget.api, partnerId: _p.id, partnerName: _p.name);
    if (a != null && mounted) {
      setState(() {
        _tab = PartnerTab.activities;
        _refresh++;
      });
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

  Widget _crmSection() {
    final p = _p;
    final terms = p.paymentTermsDays == null
        ? 'Délai du magasin'
        : (p.paymentTermsDays == 0 ? 'Comptant' : '${p.paymentTermsDays} jours');
    return PageSection(
      title: 'Relation client',
      trailing: p.latitude != null && p.longitude != null
          ? TextButton.icon(
              onPressed: () => openMaps(context, p.latitude!, p.longitude!),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('Ouvrir dans Maps'))
          : null,
      child: FactGrid(columns: 3, facts: [
        ('Type de client', clientTypeLabels[p.clientType] ?? p.clientType),
        ('Statut', crmStatusLabels[p.crmStatus] ?? p.crmStatus),
        ('Commercial', p.repName),
        ('Tournée', p.routeName),
        ('Wilaya', wilayaLabel(p.wilaya)),
        ('Commune', p.commune),
        ('Horaires', p.openingHours),
        ('N° d’agrément / licence', p.licenseNo),
        ('Délai de paiement', terms),
        ('Origine', partnerSourceLabels[p.source] ?? p.source),
        ('Position GPS',
            p.latitude != null && p.longitude != null ? '${p.latitude}, ${p.longitude}' : ''),
        if (p.createdAt.isNotEmpty) ('Client depuis le', crmDate(p.createdAt)),
      ]),
    );
  }

  Widget _contactSection() => PageSection(
        title: 'Coordonnées',
        child: FactGrid(columns: 3, facts: [
          ('Type', partnerKindWord(_p.kind)),
          ('Téléphone', _p.phone ?? ''),
          ('WhatsApp', _p.whatsapp),
          ('E-mail', _p.email ?? ''),
          ('Site web', _p.website),
          ('Adresse', _p.address ?? ''),
          ('NIF', _p.nif ?? ''),
          ('NIS', _p.nis ?? ''),
          ('RC', _p.rc ?? ''),
          ('Article d’imposition (AI)', _p.ai ?? ''),
          if (_isCustomer)
            ('Tarif', _p.effectivePriceLevel == 'wholesale' ? 'Demi-gros' : 'Détail'),
          if (_isCustomer && _p.groupName != null)
            ('Groupe',
                '${_p.groupName}${_p.groupDiscountPct > 0 ? ' — remise ${_fmtPct(_p.groupDiscountPct)} %' : ''}'),
          if (_isCustomer)
            ('Plafond de crédit',
                (_p.creditLimit ?? 0) > 0
                    ? fmtDA(_p.creditLimit!)
                    : Features.instance.defaultCreditLimit > 0
                        ? '${fmtDA(Features.instance.defaultCreditLimit)} (plafond du magasin)'
                        : 'Aucun'),
          if ((_p.notes ?? '').isNotEmpty) ('Notes', _p.notes!),
        ]),
      );

  Widget _loyaltySection() {
    final l = _loyalty!;
    return PageSection(
      title: 'Points de fidélité',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${l.balance} point${l.balance.abs() > 1 ? 's' : ''}', style: T.monoBig),
        const SizedBox(height: 6),
        Text(
            l.balance <= 0
                ? 'Pas encore de points : chaque achat en rapporte.'
                : 'Valeur : ${fmtDA(l.value)} de réduction. '
                    '${l.canRedeem ? 'Utilisables à la caisse.' : 'Utilisables à partir de ${l.minRedeem} points.'}',
            style: T.body.copyWith(fontWeight: FontWeight.w600)),
        if (l.history.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final h in l.history.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 150, child: Text(_shortDate(h.createdAt), style: T.bodyMuted)),
                SizedBox(width: 120, child: Text(h.kindLabel, style: T.body)),
                Expanded(child: Text(h.number ?? h.note ?? '', style: T.monoSmall)),
                Text('${h.points > 0 ? '+' : ''}${h.points}',
                    style: T.monoBody.copyWith(color: h.points >= 0 ? T.mintDark : T.warnDark)),
              ]),
            ),
          if (l.history.length > 8)
            Text('… et ${l.history.length - 8} mouvements plus anciens', style: T.small),
        ],
      ]),
    );
  }

  static String _shortDate(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  static String _fmtPct(int x100) =>
      x100 % 100 == 0 ? '${x100 ~/ 100}' : (x100 / 100).toString().replaceAll('.', ',');

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

  Widget _subtitle() {
    final p = _p;
    final tags = [for (final t in _allTags) if (p.tagIds.contains(t.id)) t];
    return Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(
          [
            _isCustomer && p.clientType != 'other'
                ? (clientTypeLabels[p.clientType] ?? p.clientType)
                : partnerKindWord(p.kind)[0].toUpperCase() + partnerKindWord(p.kind).substring(1),
            if ((p.phone ?? '').isNotEmpty) p.phone!,
            if (p.wilaya.isNotEmpty) p.commune.isEmpty ? p.wilaya : '${p.commune}, ${p.wilaya}',
            if (p.repName.isNotEmpty) 'Commercial : ${p.repName}',
          ].join(' · '),
          style: T.bodyMuted),
      if (_isCustomer && p.crmStatus != 'active') CrmStatusChip(p.crmStatus),
      for (final t in tags) TagChip(name: t.name, colour: t.colour),
    ]);
  }

  Widget _tabBar() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (t, label) in _tabs)
            CrmTab(label: label, selected: _tab == t, onTap: () => setState(() => _tab = t)),
        ]),
      );

  Widget _tabBody() {
    final p = _p;
    switch (_tab) {
      case PartnerTab.overview:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _balanceSection(),
          if (_isCustomer) PartnerKpisSection(api: widget.api, partnerId: p.id, refresh: _refresh),
          if (_isCustomer && _loyalty != null && (_loyalty!.enabled || _loyalty!.balance != 0))
            _loyaltySection(),
          _contactSection(),
          if (_isCustomer) _crmSection(),
          _openItemsSection(),
          _docsSection(),
          if (_isCustomer && (_plans.isNotEmpty || p.balance > 0)) _plansSection(),
        ]);
      case PartnerTab.orders:
        return PartnerOrdersTab(
            key: ValueKey('or$_refresh'),
            api: widget.api,
            partnerId: p.id,
            onNewOrder: _canNewOrder ? _newOrder : null);
      case PartnerTab.timeline:
        return PartnerTimelineTab(key: ValueKey('tl$_refresh'), api: widget.api, partnerId: p.id);
      case PartnerTab.contacts:
        return PartnerContactsTab(api: widget.api, partner: p);
      case PartnerTab.tasks:
        return PartnerTasksTab(key: ValueKey('tk$_refresh'), api: widget.api, partner: p);
      case PartnerTab.activities:
        return PartnerActivitiesTab(key: ValueKey('ac$_refresh'), api: widget.api, partner: p);
      case PartnerTab.files:
        return PartnerFilesTab(api: widget.api, partner: p);
      case PartnerTab.tags:
        return PartnerTagsTab(
            api: widget.api,
            partner: p,
            onPartner: (np) {
              _changed = true;
              setState(() => _p = np);
              CrmDirectory.tags(widget.api, refresh: true).then((t) {
                if (mounted) setState(() => _allTags = t);
              });
            });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (!_tabs.any((t) => t.$1 == _tab)) _tab = PartnerTab.overview;
    return AppPage(
      crumbs: [
        Crumb(partnerListLabel(p.kind), _back),
        Crumb(p.name),
      ],
      title: p.name,
      subtitle: _subtitle(),
      onBack: _back,
      actions: [
        Flexible(
          child: Wrap(alignment: WrapAlignment.end, runSpacing: 8, children: [
            if (_isCustomer)
              PageAction(
                  label: 'Encaisser',
                  icon: Icons.payments_outlined,
                  onPressed: () => _pay(outgoing: false)),
            if (_isCustomer && _canNewOrder)
              PageAction(
                  label: 'Nouvelle commande',
                  icon: Icons.add_shopping_cart_rounded,
                  onPressed: _newOrder),
            if (_isCustomer && _canPricing)
              PageAction(
                  label: 'Prix spéciaux',
                  icon: Icons.sell_outlined,
                  onPressed: () => openClientPricing(context, widget.api, _p.id, _p.name)),
            if (_isCustomer && _canMessage)
              PageAction(
                  label: 'Envoyer un message',
                  icon: Icons.chat_outlined,
                  onPressed: _message),
            if (_isCustomer && crmEdit(widget.api))
              PageAction(
                  label: 'Noter une activité',
                  icon: Icons.edit_note_rounded,
                  onPressed: _activity),
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
        _tabBar(),
        const SizedBox(height: 16),
        _tabBody(),
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
  // Groupe de clients + plafond de crédit propre (vide = plafond du magasin).
  late String? _groupId = widget.existing?.groupId;
  List<CustomerGroup> _groups = const [];
  late final _creditLimit = TextEditingController(
      text: (widget.existing?.creditLimit ?? 0) > 0 ? editDA(widget.existing!.creditLimit!) : '');
  bool _busy = false;
  Map<String, String> _err = const {};
  final _nameFocus = FocusNode();

  // ---- Fiche distribution / CRM ----
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late final _whatsapp = TextEditingController(text: widget.existing?.whatsapp ?? '');
  late final _website = TextEditingController(text: widget.existing?.website ?? '');
  late final _commune = TextEditingController(text: widget.existing?.commune ?? '');
  late final _hours = TextEditingController(text: widget.existing?.openingHours ?? '');
  late final _license = TextEditingController(text: widget.existing?.licenseNo ?? '');
  late final _gps = TextEditingController(
      text: widget.existing?.latitude != null && widget.existing?.longitude != null
          ? '${widget.existing!.latitude}, ${widget.existing!.longitude}'
          : '');
  late final _terms = TextEditingController(
      text: widget.existing?.paymentTermsDays == null ? '' : '${widget.existing!.paymentTermsDays}');
  late String _clientType = widget.existing?.clientType ?? 'supermarket';
  late String _crmStatus = widget.existing?.crmStatus ?? 'active';
  late String _source = widget.existing?.source ?? 'manual';
  late String? _wilaya = (widget.existing?.wilaya ?? '').isEmpty ? null : widget.existing!.wilaya;
  late String? _repId = widget.existing?.repUserId;
  late String? _routeId = widget.existing?.routeId;
  List<CrmUser> _users = const [];
  List<CrmRoute> _routes = const [];

  @override
  void initState() {
    super.initState();
    widget.api.customerGroups().then((g) {
      if (mounted) setState(() => _groups = g);
    }).catchError((_) {});
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
    CrmDirectory.routes(widget.api).then((r) {
      if (mounted) setState(() => _routes = r);
    });
    // The page frame autofocuses for Échap: put the cursor in « Nom ».
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.existing == null) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in [
      _name, _phone, _address, _nif, _nis, _rc, _ai, _notes, _creditLimit,
      _email, _whatsapp, _website, _commune, _hours, _license, _gps, _terms,
    ]) {
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
    final credit = _creditLimit.text.trim().isEmpty ? 0 : parseDA(_creditLimit.text);
    if (credit == null || credit < 0) e['credit'] = 'Montant invalide.';
    final email = _email.text.trim();
    if (email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      e['email'] = 'Adresse e-mail invalide.';
    }
    final gps = parseGps(_gps.text);
    if (_gps.text.trim().isNotEmpty && gps == null) {
      e['gps'] = 'Écrivez « latitude, longitude », ex. 36.7525, 3.0420.';
    }
    final termsText = _terms.text.trim();
    final terms = termsText.isEmpty ? -1 : int.tryParse(termsText);
    if (terms == null || terms < -1 || terms > 3650) e['terms'] = 'Nombre de jours invalide.';
    setState(() => _err = e);
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    String? v(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final isClient = _kind != 'supplier';
    try {
      final saved = await widget.api.savePartner({
        'email': v(_email),
        'whatsapp': _whatsapp.text.trim(),
        'website': _website.text.trim(),
        'wilaya': _wilaya ?? '',
        'commune': _commune.text.trim(),
        'opening_hours': _hours.text.trim(),
        'license_no': _license.text.trim(),
        if (gps != null) 'latitude': gps.$1,
        if (gps != null) 'longitude': gps.$2,
        if (isClient) ...{
          'client_type': _clientType,
          'crm_status': _crmStatus,
          'source': _source,
          'rep_user_id': _repId ?? '',
          'route_id': _routeId ?? '',
          'payment_terms_days': terms,
        },
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
        // null = suit le plafond par défaut du magasin.
        'credit_limit': _kind == 'supplier' || (credit ?? 0) == 0 ? null : credit,
        'group_id': _kind == 'supplier' ? '' : (_groupId ?? ''),
        // Réglages fournisseur gardés tels quels (le formulaire ne les montre pas).
        if (widget.existing != null) 'min_shelf_days': widget.existing!.minShelfDays,
        if (widget.existing != null) 'over_receipt_pct': widget.existing!.overReceiptPct,
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
                    : m.contains('latitude') || m.contains('longitude')
                        ? 'gps'
                        : m.contains('délai')
                            ? 'terms'
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
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: FormFieldBlock(
                      label: 'WhatsApp',
                      controller: _whatsapp,
                      helper: 'Vide = même numéro que le téléphone',
                      keyboard: TextInputType.phone,
                      onSubmitted: _save)),
              const SizedBox(width: 14),
              Expanded(
                  child: FormFieldBlock(
                      label: 'E-mail',
                      controller: _email,
                      error: _err['email'],
                      keyboard: TextInputType.emailAddress,
                      onSubmitted: _save)),
            ]),
            FormFieldBlock(
                label: 'Site web', controller: _website, hint: 'www.exemple.dz', onSubmitted: _save),
          ]),
        ),
        if (_kind != 'supplier')
          PageSection(
            title: 'Relation client',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: DropdownBlock<String>(
                    label: 'Type de client',
                    value: _clientType,
                    options: [for (final e in clientTypeLabels.entries) (e.key, e.value)],
                    onChanged: (v) => setState(() => _clientType = v ?? 'other'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownBlock<String>(
                    label: 'Origine du client',
                    value: _source,
                    options: [for (final e in partnerSourceLabels.entries) (e.key, e.value)],
                    onChanged: (v) => setState(() => _source = v ?? 'manual'),
                  ),
                ),
              ]),
              Text('Statut', style: T.label),
              const SizedBox(height: 6),
              ChoiceRow<String>(
                options: [for (final e in crmStatusLabels.entries) (e.key, e.value)],
                value: _crmStatus,
                onSelect: (v) => setState(() => _crmStatus = v),
              ),
              const SizedBox(height: 4),
              Text(
                  _crmStatus == 'blocked'
                      ? 'Bloqué : ses commandes demandent une autorisation à la validation.'
                      : _crmStatus == 'prospect'
                          ? 'Prospect : pas encore client, à démarcher.'
                          : _crmStatus == 'dormant'
                              ? 'Inactif : n’achète plus, à relancer.'
                              : 'Actif : achète régulièrement.',
                  style: T.small),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: DropdownBlock<String>(
                    label: 'Commercial',
                    value: _repId,
                    noneLabel: 'Aucun',
                    options: [
                      for (final u in _users) (u.id, u.name),
                      if (_repId != null && !_users.any((u) => u.id == _repId))
                        (_repId!, widget.existing?.repName ?? 'Commercial actuel'),
                    ],
                    onChanged: (v) => setState(() => _repId = v),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownBlock<String>(
                    label: 'Tournée de livraison',
                    value: _routeId,
                    noneLabel: 'Aucune',
                    helper: _routes.isEmpty ? 'Les tournées se créent dans Livraisons.' : null,
                    options: [
                      for (final r in _routes) if (r.active || r.id == _routeId) (r.id, r.name),
                      if (_routeId != null && !_routes.any((r) => r.id == _routeId))
                        (_routeId!, widget.existing?.routeName ?? 'Tournée actuelle'),
                    ],
                    onChanged: (v) => setState(() => _routeId = v),
                  ),
                ),
              ]),
              SizedBox(
                width: 380,
                child: FormFieldBlock(
                  label: 'Délai de paiement (jours)',
                  controller: _terms,
                  error: _err['terms'],
                  keyboard: TextInputType.number,
                  helper: 'Vide = délai du magasin. 0 = paiement comptant.',
                  onSubmitted: _save,
                ),
              ),
            ]),
          ),
        PageSection(
          title: 'Adresse et localisation',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormFieldBlock(label: 'Adresse', controller: _address, onSubmitted: _save),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: DropdownBlock<String>(
                  label: 'Wilaya',
                  value: _wilaya,
                  noneLabel: 'Non renseignée',
                  options: [
                    for (final (c, n) in wilayas) (n, '$c · $n'),
                    if (_wilaya != null && !wilayas.any((w) => w.$2 == _wilaya)) (_wilaya!, _wilaya!),
                  ],
                  onChanged: (v) => setState(() => _wilaya = v),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(child: FormFieldBlock(label: 'Commune', controller: _commune, onSubmitted: _save)),
            ]),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: FormFieldBlock(
                  label: 'Position GPS',
                  controller: _gps,
                  error: _err['gps'],
                  hint: '36.7525, 3.0420',
                  helper: 'Dans Google Maps : clic droit sur le lieu → copiez les chiffres et collez-les ici.',
                  onSubmitted: _save,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 22),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () {
                    final g = parseGps(_gps.text);
                    if (g == null) {
                      setState(() => _err = {..._err, 'gps': 'Position GPS absente ou invalide.'});
                    } else {
                      openMaps(context, g.$1, g.$2);
                    }
                  },
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Ouvrir dans Maps'),
                ),
              ),
            ]),
          ]),
        ),
        PageSection(
          title: 'Horaires et agrément',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormFieldBlock(
                label: 'Horaires d’ouverture',
                controller: _hours,
                hint: 'Ex. 8h–20h, fermé le vendredi',
                onSubmitted: _save),
            FormFieldBlock(
                label: 'N° d’agrément / licence',
                controller: _license,
                helper: 'N° d’agrément ou d’autorisation, si le client en a un.',
                onSubmitted: _save),
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
              Text(
                  _groupId != null && _groups.any((g) => g.id == _groupId)
                      ? 'Les prix proposés sur ses factures. Son groupe impose son propre tarif.'
                      : 'Les prix proposés sur ses factures.',
                  style: T.small),
            ]),
          ),
        if (_kind != 'supplier')
          PageSection(
            title: 'Groupe et crédit',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Groupe de clients', style: T.label),
              const SizedBox(height: 5),
              SizedBox(
                width: 380,
                child: DropdownButtonFormField<String?>(
                  initialValue: _groups.any((g) => g.id == _groupId) ? _groupId : null,
                  key: ValueKey('grp-${_groups.length}'),
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                  ),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('Aucun groupe', style: T.body)),
                    for (final g in _groups)
                      DropdownMenuItem<String?>(
                        value: g.id,
                        child: Text(
                            '${g.name} — ${g.priceLevel == 'wholesale' ? 'demi-gros' : 'détail'}'
                            '${g.discountPct > 0 ? ', remise ${(g.discountPct / 100).toString().replaceAll('.0', '').replaceAll('.', ',')} %' : ''}',
                            style: T.body),
                      ),
                  ],
                  onChanged: (v) => setState(() => _groupId = v),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                  _groups.isEmpty
                      ? 'Aucun groupe pour l’instant : créez-en dans Paramètres › Clients et fidélité.'
                      : 'Le tarif et la remise du groupe s’appliquent dès que ce client est choisi sur une vente.',
                  style: T.small),
              const SizedBox(height: 14),
              SizedBox(
                width: 380,
                child: FormFieldBlock(
                  label: 'Plafond de crédit (DA)',
                  controller: _creditLimit,
                  error: _err['credit'],
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  helper: Features.instance.defaultCreditLimit > 0
                      ? 'Vide = plafond du magasin (${fmtDA(Features.instance.defaultCreditLimit)}).'
                      : 'Dette maximale autorisée. Vide = pas de plafond.',
                  onSubmitted: _save,
                ),
              ),
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
