import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/file_dialog.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_list.dart' show showDocDetailDialog, DocChip;
import '../../widgets/ui.dart';
import '../crm/crm_common.dart';
import '../crm/tags_page.dart';
import '../orders/orders_screen.dart' show openOrderDetail;

// Sections / tabs of the client 360 page (docs/API_DISTRIBUTION.md §5).

// ---------------------------------------------------------------------------
// Vue d'ensemble : indicateurs
// ---------------------------------------------------------------------------

class PartnerKpisSection extends StatefulWidget {
  const PartnerKpisSection({super.key, required this.api, required this.partnerId, this.refresh = 0});
  final ApiClient api;
  final String partnerId;

  /// Bump to reload.
  final int refresh;

  @override
  State<PartnerKpisSection> createState() => _PartnerKpisSectionState();
}

class _PartnerKpisSectionState extends State<PartnerKpisSection> {
  PartnerKpis? _k;
  CrmPartnerCredit? _c;
  bool _loading = true;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PartnerKpisSection old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) _load();
  }

  Future<void> _load() async {
    try {
      final k = await widget.api.crmPartnerKpis(widget.partnerId);
      if (mounted) setState(() => _k = k);
    } on ApiException catch (e) {
      if (e.status == 403 && mounted) setState(() => _denied = true);
    } catch (_) {}
    try {
      final c = await widget.api.crmPartnerCredit(widget.partnerId);
      if (mounted) setState(() => _c = c);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _days(double? d) => d == null ? '—' : '${d.round()} j';

  @override
  Widget build(BuildContext context) {
    if (_denied) return const SizedBox.shrink();
    final k = _k;
    final c = _c;
    return PageSection(
      title: 'Indicateurs',
      child: _loading && k == null
          ? const SkeletonBar(width: 300, height: 14)
          : k == null
              ? Text('Indicateurs indisponibles.', style: T.bodyMuted)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    KpiTile(label: 'Achats 30 jours', value: fmtDA(k.turnover30)),
                    KpiTile(label: 'Achats 90 jours', value: fmtDA(k.turnover90)),
                    KpiTile(label: 'Achats 12 mois', value: fmtDA(k.turnover365),
                        note: '${k.purchasesCount365} jour(s) d’achat'),
                    KpiTile(label: 'Panier moyen', value: fmtDA(k.avgBasket)),
                    KpiTile(
                        label: 'Achète tous les',
                        value: k.orderFrequencyDays == null ? '—' : '${k.orderFrequencyDays!.round()} jours',
                        note: 'En moyenne'),
                    KpiTile(
                        label: 'Dernier achat',
                        value: k.lastOrderDate == null ? 'Jamais' : crmDate(k.lastOrderDate),
                        note: daysAgo(k.daysSinceLastOrder),
                        color: k.daysSinceLastOrder > 60 ? T.warnDark : null),
                    KpiTile(
                        label: 'Paie ses factures en',
                        value: _days(k.paymentDelayAvgDays),
                        note: 'Délai moyen facture → paiement'),
                    KpiTile(
                        label: 'Crédit utilisé',
                        value: k.creditLimit > 0 ? '${k.creditUsagePct} %' : 'Sans plafond',
                        note: k.creditLimit > 0 ? 'Plafond ${fmtDA(k.creditLimit)}' : null,
                        color: k.creditUsagePct >= 100
                            ? T.dangerDark
                            : k.creditUsagePct >= 80
                                ? T.warnDark
                                : null),
                    KpiTile(
                        label: 'Impayés échus',
                        value: fmtDA(k.overdueAmount),
                        note: c != null && c.overdueCount > 0 ? '${c.overdueCount} facture(s)' : null,
                        color: k.overdueAmount > 0 ? T.dangerDark : null),
                    KpiTile(
                        label: 'Commandes en cours',
                        value: '${k.openOrdersCount}',
                        note: k.openOrdersAmount > 0 ? fmtDA(k.openOrdersAmount) : null),
                    if (c?.availableCredit != null)
                      KpiTile(label: 'Crédit encore disponible', value: fmtDA(c!.availableCredit!)),
                    if (k.backorderLines > 0)
                      KpiTile(
                          label: 'Reliquats en attente',
                          value: '${k.backorderLines} ligne(s)',
                          note: '${fmtQty(k.backorderQtyMilli)} unité(s)',
                          color: T.warnDark),
                  ]),
                  if (k.topProducts.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text('Ce qu’il achète le plus (12 mois)', style: T.label),
                    const SizedBox(height: 8),
                    for (final p in k.topProducts)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(child: Text(p.name, style: T.body, overflow: TextOverflow.ellipsis)),
                          SizedBox(
                              width: 110,
                              child: Text('${fmtQty(p.qtyMilli)} u.', textAlign: TextAlign.end, style: T.monoSmall)),
                          SizedBox(
                              width: 150,
                              child: Text(fmtDA(p.amount), textAlign: TextAlign.end, style: T.monoBody)),
                        ]),
                      ),
                  ],
                ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Chronologie
// ---------------------------------------------------------------------------

class PartnerTimelineTab extends StatefulWidget {
  const PartnerTimelineTab({super.key, required this.api, required this.partnerId});
  final ApiClient api;
  final String partnerId;

  @override
  State<PartnerTimelineTab> createState() => _PartnerTimelineTabState();
}

class _PartnerTimelineTabState extends State<PartnerTimelineTab> {
  static const _pageSize = 30;
  final Set<String> _kinds = {};
  int _offset = 0;
  TimelinePage? _page;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api
          .crmTimeline(widget.partnerId, limit: _pageSize, offset: _offset, kinds: _kinds.toList());
      if (mounted) setState(() => _page = p);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toggle(String k) {
    setState(() {
      _kinds.contains(k) ? _kinds.remove(k) : _kinds.add(k);
      _offset = 0;
    });
    _load();
  }

  /// Orders open only for people who can see them (orders.view).
  bool get _canOrders => crmCan(widget.api, 'orders');

  bool _clickable(TimelineItem it) {
    if (it.refId == null) return false;
    return switch (it.kind) {
      'document' || 'payment' => true,
      'order' || 'order_event' => _canOrders,
      _ => false,
    };
  }

  Future<void> _openItem(TimelineItem it) async {
    if (!_clickable(it)) return;
    if (it.kind == 'order' || it.kind == 'order_event') {
      final user = widget.api.user;
      if (user == null) return;
      final changed = await openOrderDetail(context, widget.api, user, it.refId!);
      if (changed && mounted) _load();
      return;
    }
    await showDocDetailDialog(context, widget.api, it.refId!);
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    final total = p?.total ?? 0;
    return PageSection(
      title: 'Chronologie',
      trailing: Text(total == 0 ? '' : '$total événement(s)', style: T.bodyMuted),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 0, runSpacing: 6, children: [
          FilterPillLite(
              label: 'Tout',
              active: _kinds.isEmpty,
              onTap: () {
                setState(() {
                  _kinds.clear();
                  _offset = 0;
                });
                _load();
              }),
          for (final e in timelineKindLabels.entries)
            FilterPillLite(
                label: e.value, icon: crmKindIcon(e.key), active: _kinds.contains(e.key), onTap: () => _toggle(e.key)),
        ]),
        const SizedBox(height: 14),
        if (_loading && p == null)
          const SkeletonBar(width: 260, height: 14)
        else if (_error != null)
          FieldError(_error)
        else if (p == null || p.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('Rien à afficher pour l’instant.', style: T.bodyMuted),
          )
        else ...[
          for (final it in p.items) _row(it),
          const SizedBox(height: 10),
          Row(children: [
            Text('${_offset + 1}–${_offset + p.items.length} sur $total', style: T.small),
            const Spacer(),
            OutlinedButton(
              onPressed: _offset == 0 || _loading
                  ? null
                  : () {
                      setState(() => _offset = (_offset - _pageSize).clamp(0, 1 << 30));
                      _load();
                    },
              child: const Text('Précédent'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _offset + p.items.length >= total || _loading
                  ? null
                  : () {
                      setState(() => _offset += _pageSize);
                      _load();
                    },
              child: const Text('Suivant'),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _row(TimelineItem it) {
    final clickable = _clickable(it);
    return InkWell(
      onTap: clickable ? () => _openItem(it) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(999)),
            child: Icon(crmKindIcon(it.kind, it.subType), size: 17, color: T.mintDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(it.title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
              if (it.detail.isNotEmpty) Text(it.detail, style: T.bodyMuted, maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                  [
                    crmDateTime(it.at),
                    if (it.userName.isNotEmpty) it.userName,
                    if (it.status.isNotEmpty) it.status,
                  ].join(' · '),
                  style: T.small),
            ]),
          ),
          if (it.amount != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(fmtDA(it.amount!), style: T.monoBody),
            ),
          if (clickable)
            const Padding(
              padding: EdgeInsets.only(left: 6, top: 4),
              child: Icon(Icons.chevron_right_rounded, size: 18, color: T.ghost),
            ),
        ]),
      ),
    );
  }
}

/// Compact filter pill (same look as [FilterPill] of the list toolbar).
class FilterPillLite extends StatelessWidget {
  const FilterPillLite({super.key, required this.label, required this.active, required this.onTap, this.icon});
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: active ? T.ink : T.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: active ? Colors.white : T.muted),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: T.small.copyWith(
                    fontSize: 13.5, fontWeight: FontWeight.w600, color: active ? Colors.white : T.ink)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Contacts
// ---------------------------------------------------------------------------

class PartnerContactsTab extends StatefulWidget {
  const PartnerContactsTab({super.key, required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<PartnerContactsTab> createState() => _PartnerContactsTabState();
}

class _PartnerContactsTabState extends State<PartnerContactsTab> {
  List<PartnerContact> _items = const [];
  bool _loading = true;
  String? _error;

  bool get _canEdit => crmEditFiche(widget.api);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await widget.api.crmContacts(widget.partner.id);
      if (mounted) setState(() => _items = c);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([PartnerContact? c]) async {
    final saved = await Navigator.of(context).push<PartnerContact>(MaterialPageRoute(
        builder: (_) => ContactFormPage(api: widget.api, partner: widget.partner, existing: c)));
    if (saved != null) _load();
  }

  Future<void> _delete(PartnerContact c) async {
    final ok = await confirmAction(context,
        title: 'Supprimer le contact « ${c.name} » ?', confirmLabel: 'Supprimer', danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteContact(c.id);
      _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _makePrimary(PartnerContact c) async {
    try {
      await widget.api.crmSaveContact(widget.partner.id, _contactBody(c, primary: true), id: c.id);
      _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;
    final reach = contactButtons(context, phone: p.phone ?? '', whatsapp: p.whatsapp, email: p.email ?? '');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageSection(
        title: 'Joindre ${p.name}',
        child: reach.isEmpty
            ? Text('Pas de téléphone ni d’e-mail sur la fiche.', style: T.bodyMuted)
            : Wrap(spacing: 8, runSpacing: 8, children: reach),
      ),
      PageSection(
        title: 'Contacts',
        trailing: _canEdit
            ? TextButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                label: const Text('Nouveau contact'))
            : null,
        child: _loading
            ? const SkeletonBar(width: 240, height: 14)
            : _error != null
                ? FieldError(_error)
                : _items.isEmpty
                    ? EmptyState(
                        icon: Icons.contact_phone_outlined,
                        text: 'Aucun contact : ajoutez le gérant, l’acheteur, le comptable…',
                        actions: [if (_canEdit) ('Nouveau contact', () => _edit())])
                    : Column(children: [
                        for (final c in _items) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Flexible(
                                        child: Text(c.name, style: T.body.copyWith(fontWeight: FontWeight.w700))),
                                    if (c.isPrimary) ...[
                                      const SizedBox(width: 8),
                                      const DocChip(label: 'Principal', bg: T.mintTint, fg: T.mintDark),
                                    ],
                                  ]),
                                  Text(
                                      [c.role, c.phone, if (c.whatsapp.isNotEmpty) 'WhatsApp ${c.whatsapp}', c.email]
                                          .where((s) => s.isNotEmpty)
                                          .join(' · '),
                                      style: T.bodyMuted),
                                  if (c.notes.isNotEmpty) Text(c.notes, style: T.small),
                                  const SizedBox(height: 8),
                                  Wrap(spacing: 8, runSpacing: 8, children: [
                                    ...contactButtons(context, phone: c.phone, whatsapp: c.whatsapp, email: c.email),
                                  ]),
                                ]),
                              ),
                              if (_canEdit)
                                PopupMenuButton<String>(
                                  tooltip: 'Plus',
                                  onSelected: (v) => switch (v) {
                                    'edit' => _edit(c),
                                    'primary' => _makePrimary(c),
                                    _ => _delete(c),
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(value: 'edit', child: Text('Modifier')),
                                    if (!c.isPrimary)
                                      const PopupMenuItem(value: 'primary', child: Text('Mettre en principal')),
                                    const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Supprimer', style: TextStyle(color: T.dangerDark))),
                                  ],
                                ),
                            ]),
                          ),
                          const Divider(),
                        ],
                      ]),
      ),
    ]);
  }
}

Map<String, dynamic> _contactBody(PartnerContact c, {bool? primary}) => {
      'name': c.name,
      'role': c.role,
      'phone': c.phone,
      'whatsapp': c.whatsapp,
      'email': c.email,
      'is_primary': primary ?? c.isPrimary,
      'notes': c.notes,
    };

/// « Appeler », « WhatsApp », « E-mail » buttons (only those that apply).
List<Widget> contactButtons(BuildContext context,
    {required String phone, required String whatsapp, required String email}) {
  final wa = whatsapp.isNotEmpty ? whatsapp : phone;
  return [
    if (phone.isNotEmpty)
      OutlinedButton.icon(
        onPressed: () => openExternal(context, 'tel:${phone.replaceAll(' ', '')}'),
        icon: const Icon(Icons.call_outlined, size: 16),
        label: Text('Appeler $phone'),
      ),
    if (wa.isNotEmpty)
      OutlinedButton.icon(
        onPressed: () => openExternal(context, 'https://wa.me/${phoneIntl(wa)}'),
        icon: const Icon(Icons.chat_outlined, size: 16),
        label: const Text('WhatsApp'),
      ),
    if (email.isNotEmpty)
      OutlinedButton.icon(
        onPressed: () => openExternal(context, 'mailto:$email'),
        icon: const Icon(Icons.email_outlined, size: 16),
        label: const Text('E-mail'),
      ),
  ];
}

class ContactFormPage extends StatefulWidget {
  const ContactFormPage({super.key, required this.api, required this.partner, this.existing});
  final ApiClient api;
  final Partner partner;
  final PartnerContact? existing;

  @override
  State<ContactFormPage> createState() => _ContactFormPageState();
}

class _ContactFormPageState extends State<ContactFormPage> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _role = TextEditingController(text: widget.existing?.role ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _wa = TextEditingController(text: widget.existing?.whatsapp ?? '');
  late final _email = TextEditingController(text: widget.existing?.email ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late bool _primary = widget.existing?.isPrimary ?? false;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    for (final c in [_name, _role, _phone, _wa, _email, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _err = 'Le nom est obligatoire.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final c = await widget.api.crmSaveContact(
          widget.partner.id,
          {
            'name': _name.text.trim(),
            'role': _role.text.trim(),
            'phone': _phone.text.trim(),
            'whatsapp': _wa.text.trim(),
            'email': _email.text.trim(),
            'is_primary': _primary,
            'notes': _notes.text.trim(),
          },
          id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, 'Contact enregistré.');
      Navigator.of(context).pop(c);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AppPage(
      crumbs: [Crumb(widget.partner.name, () => Navigator.of(context).pop()), Crumb(isNew ? 'Nouveau contact' : 'Modifier')],
      title: isNew ? 'Nouveau contact' : 'Modifier ${widget.existing!.name}',
      maxWidth: 760,
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: PageSection(
        title: 'Contact chez ${widget.partner.name}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextBlock(label: 'Nom', required: true, controller: _name, autofocus: isNew, error: _err),
          TextBlock(label: 'Fonction', controller: _role, hint: 'Ex. Gérant, acheteur, comptable…'),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: TextBlock(label: 'Téléphone', controller: _phone, keyboard: TextInputType.phone)),
            const SizedBox(width: 14),
            Expanded(child: TextBlock(label: 'WhatsApp', controller: _wa, keyboard: TextInputType.phone, helper: 'Vide = même numéro')),
          ]),
          TextBlock(label: 'E-mail', controller: _email, keyboard: TextInputType.emailAddress),
          TextBlock(label: 'Notes', controller: _notes, maxLines: 3),
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
            value: _primary,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: T.mintDeep,
            title: Text('Contact principal', style: T.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text('Utilisé pour les messages quand la fiche n’a pas de numéro.', style: T.small),
            onChanged: (v) => setState(() => _primary = v ?? false),
          ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tâches du client
// ---------------------------------------------------------------------------

class PartnerTasksTab extends StatefulWidget {
  const PartnerTasksTab({super.key, required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<PartnerTasksTab> createState() => _PartnerTasksTabState();
}

class _PartnerTasksTabState extends State<PartnerTasksTab> {
  List<CrmTask> _open = const [];
  List<CrmTask> _closed = const [];
  bool _showClosed = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await widget.api.crmTasks(partnerId: widget.partner.id, status: 'open');
      final c = _showClosed ? await widget.api.crmTasks(partnerId: widget.partner.id, status: 'all') : const <CrmTask>[];
      if (mounted) {
        setState(() {
          _open = o;
          _closed = [for (final t in c) if (!t.isOpen) t];
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    final t = await openTaskForm(context, widget.api, partnerId: widget.partner.id, partnerName: widget.partner.name);
    if (t != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEdit(widget.api);
    return PageSection(
      title: 'Tâches',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          onPressed: () {
            setState(() => _showClosed = !_showClosed);
            _load();
          },
          child: Text(_showClosed ? 'Masquer les tâches terminées' : 'Voir les tâches terminées'),
        ),
        if (canEdit)
          TextButton.icon(
              onPressed: _new, icon: const Icon(Icons.add_task_rounded, size: 18), label: const Text('Nouvelle tâche')),
      ]),
      child: _loading
          ? const SkeletonBar(width: 240, height: 14)
          : _error != null
              ? FieldError(_error)
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_open.isEmpty)
                    EmptyState(
                        icon: Icons.task_alt_rounded,
                        text: 'Aucune tâche en cours pour ce client.',
                        actions: [if (canEdit) ('Nouvelle tâche', _new)])
                  else
                    for (final t in _open) TaskRow(api: widget.api, task: t, onChanged: _load, showPartner: false),
                  if (_showClosed && _closed.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text('Terminées ou annulées', style: T.label),
                    for (final t in _closed) TaskRow(api: widget.api, task: t, onChanged: _load, showPartner: false),
                  ],
                ]),
    );
  }
}

/// One task line: check to complete, title, client, due date, assignee,
/// labelled actions. Shared by « Mes tâches » and the client page.
class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.api,
    required this.task,
    required this.onChanged,
    this.showPartner = true,
    this.onOpenPartner,
  });
  final ApiClient api;
  final CrmTask task;
  final VoidCallback onChanged;
  final bool showPartner;
  final void Function(CrmTask)? onOpenPartner;

  Future<void> _complete(BuildContext context) async {
    final r = await askTaskResult(context, task);
    if (r == null) return;
    try {
      await api.crmCompleteTask(task.id, result: r);
      if (context.mounted) showToast(context, 'Tâche faite : « ${task.title} ».');
      onChanged();
    } catch (e) {
      if (context.mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _cancel(BuildContext context) async {
    final r = await askTaskResult(context, task, cancel: true);
    if (r == null) return;
    try {
      await api.crmCancelTask(task.id, result: r);
      onChanged();
    } catch (e) {
      if (context.mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  Future<void> _edit(BuildContext context) async {
    final t = await openTaskForm(context, api, existing: task);
    if (t != null) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = task;
    final canEdit = crmEdit(api);
    final dueColor = !t.isOpen
        ? T.faint
        : t.overdue
            ? T.dangerDark
            : (t.dueDate == isoDate(DateTime.now()) ? T.warnDark : T.muted);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: t.isOpen && canEdit
              ? Tooltip(
                  message: 'Marquer comme faite',
                  child: InkWell(
                    onTap: () => _complete(context),
                    borderRadius: BorderRadius.circular(999),
                    child: const Icon(Icons.radio_button_unchecked_rounded, size: 22, color: T.mintDeep),
                  ),
                )
              : Icon(
                  t.status == 'done'
                      ? Icons.check_circle_rounded
                      : t.status == 'cancelled'
                          ? Icons.cancel_outlined
                          : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: t.status == 'done' ? T.mintDeep : T.ghost),
        ),
        const SizedBox(width: 12),
        Icon(taskTypeIcon(t.type), size: 18, color: T.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
              Text(t.title,
                  style: T.body.copyWith(
                      fontWeight: FontWeight.w700,
                      decoration: t.isOpen ? null : TextDecoration.lineThrough,
                      color: t.isOpen ? T.ink : T.faint)),
              if (t.priority == 2)
                const DocChip(label: 'Urgente', bg: T.dangerTint, fg: T.dangerDark)
              else if (t.priority == 1)
                const DocChip(label: 'Haute', bg: T.warnTint, fg: T.warnDark),
              if (t.source != 'manual')
                DocChip(label: taskSourceLabels[t.source] ?? t.source, bg: T.cream, fg: T.muted),
            ]),
            const SizedBox(height: 2),
            Wrap(spacing: 14, runSpacing: 2, children: [
              if (showPartner && t.partnerName != null)
                InkWell(
                  onTap: onOpenPartner == null ? null : () => onOpenPartner!(t),
                  child: Text(t.partnerName!,
                      style: T.small.copyWith(
                          color: onOpenPartner == null ? T.faint : T.mintDark, fontWeight: FontWeight.w700)),
                ),
              Text(t.dueDate.isEmpty ? 'Sans échéance' : 'Pour le ${crmDate(t.dueDate)}${t.overdue && t.isOpen ? ' (en retard)' : ''}',
                  style: T.small.copyWith(color: dueColor, fontWeight: t.overdue ? FontWeight.w700 : null)),
              Text(t.assigneeName.isEmpty ? 'Non attribuée' : t.assigneeName, style: T.small),
              if (t.orderNumber != null) Text('Commande ${t.orderNumber}', style: T.small),
              Text(taskTypeLabels[t.type] ?? t.type, style: T.small),
            ]),
            if (t.description.isNotEmpty) Text(t.description, style: T.bodyMuted),
            if (!t.isOpen && t.result.isNotEmpty) Text('Résultat : ${t.result}', style: T.small),
          ]),
        ),
        if (t.isOpen) ...[
          if (showPartner && (t.partnerPhone ?? '').isNotEmpty)
            TextButton.icon(
              onPressed: () => openExternal(context, 'tel:${t.partnerPhone!.replaceAll(' ', '')}'),
              icon: const Icon(Icons.call_outlined, size: 16),
              label: const Text('Appeler'),
            ),
          if (canEdit)
            TextButton.icon(
              onPressed: () => _complete(context),
              icon: const Icon(Icons.check_rounded, size: 16),
              label: const Text('Faite'),
            ),
          if (canEdit)
            PopupMenuButton<String>(
              tooltip: 'Plus',
              onSelected: (v) => v == 'edit' ? _edit(context) : _cancel(context),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Modifier')),
                PopupMenuItem(value: 'cancel', child: Text('Annuler la tâche')),
              ],
            ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Activités
// ---------------------------------------------------------------------------

class PartnerActivitiesTab extends StatefulWidget {
  const PartnerActivitiesTab({super.key, required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<PartnerActivitiesTab> createState() => _PartnerActivitiesTabState();
}

class _PartnerActivitiesTabState extends State<PartnerActivitiesTab> {
  static const _pageSize = 30;
  List<CrmActivity> _items = const [];
  String? _type;
  int _offset = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final a = await widget.api
          .crmActivities(partnerId: widget.partner.id, type: _type, limit: _pageSize, offset: _offset);
      if (mounted) setState(() => _items = a);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new(String type) async {
    final a = await openActivityForm(context, widget.api,
        partnerId: widget.partner.id, partnerName: widget.partner.name, type: type);
    if (a != null) _load();
  }

  Future<void> _edit(CrmActivity a) async {
    final r = await openActivityForm(context, widget.api,
        partnerId: widget.partner.id, partnerName: widget.partner.name, existing: a);
    if (r != null) _load();
  }

  Future<void> _delete(CrmActivity a) async {
    final ok = await confirmAction(context, title: 'Supprimer cette activité ?', confirmLabel: 'Supprimer', danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteActivity(a.id);
      _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEdit(widget.api);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (canEdit)
        PageSection(
          title: 'Noter une activité',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in activityTypeLabels.entries)
              OutlinedButton.icon(
                onPressed: () => _new(e.key),
                icon: Icon(activityIcon(e.key), size: 17),
                label: Text(e.value),
              ),
          ]),
        ),
      PageSection(
        title: 'Activités',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(runSpacing: 6, children: [
            FilterPillLite(
                label: 'Tout',
                active: _type == null,
                onTap: () {
                  setState(() {
                    _type = null;
                    _offset = 0;
                  });
                  _load();
                }),
            for (final e in activityTypeLabels.entries)
              FilterPillLite(
                  label: e.value,
                  icon: activityIcon(e.key),
                  active: _type == e.key,
                  onTap: () {
                    setState(() {
                      _type = _type == e.key ? null : e.key;
                      _offset = 0;
                    });
                    _load();
                  }),
          ]),
          const SizedBox(height: 12),
          if (_loading && _items.isEmpty)
            const SkeletonBar(width: 240, height: 14)
          else if (_error != null)
            FieldError(_error)
          else if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Aucune activité notée.', style: T.bodyMuted),
            )
          else ...[
            for (final a in _items)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(999)),
                    child: Icon(activityIcon(a.type), size: 17, color: T.mintDark),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                          '${activityTypeLabels[a.type] ?? a.type}${a.outcome.isNotEmpty ? ' — ${a.outcome}' : ''}',
                          style: T.body.copyWith(fontWeight: FontWeight.w700)),
                      if (a.summary.isNotEmpty) Text(a.summary, style: T.bodyMuted),
                      if (a.nextAction.isNotEmpty) Text('Ensuite : ${a.nextAction}', style: T.small.copyWith(color: T.mintDark)),
                      Text(
                          [
                            crmDateTime(a.at),
                            if (a.userName.isNotEmpty) a.userName,
                            if (a.durationMin > 0) '${a.durationMin} min',
                            if (a.orderNumber != null) 'Commande ${a.orderNumber}',
                          ].join(' · '),
                          style: T.small),
                    ]),
                  ),
                  if (a.latitude != null && a.longitude != null)
                    TextButton(onPressed: () => openMaps(context, a.latitude!, a.longitude!), child: const Text('Carte')),
                  if (canEdit)
                    PopupMenuButton<String>(
                      tooltip: 'Plus',
                      onSelected: (v) => v == 'edit' ? _edit(a) : _delete(a),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Modifier')),
                        PopupMenuItem(value: 'delete', child: Text('Supprimer', style: TextStyle(color: T.dangerDark))),
                      ],
                    ),
                ]),
              ),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              OutlinedButton(
                onPressed: _offset == 0 || _loading
                    ? null
                    : () {
                        setState(() => _offset = (_offset - _pageSize).clamp(0, 1 << 30));
                        _load();
                      },
                child: const Text('Plus récentes'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _items.length < _pageSize || _loading
                    ? null
                    : () {
                        setState(() => _offset += _pageSize);
                        _load();
                      },
                child: const Text('Plus anciennes'),
              ),
            ]),
          ],
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Pièces (fichiers du dossier client)
// ---------------------------------------------------------------------------

String _fileSize(int bytes) {
  if (bytes < 1024) return '$bytes o';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} Mo';
}

class PartnerFilesTab extends StatefulWidget {
  const PartnerFilesTab({super.key, required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<PartnerFilesTab> createState() => _PartnerFilesTabState();
}

class _PartnerFilesTabState extends State<PartnerFilesTab> {
  List<PartnerFile> _items = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await widget.api.crmFiles(widget.partner.id);
      if (mounted) setState(() => _items = f);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final path = pickFile('Documents (PDF, images)', '*.pdf;*.png;*.jpg;*.jpeg;*.webp;*.doc;*.docx;*.*');
    if (path == null || !mounted) return;
    final f = File(path);
    final size = await f.length();
    if (size > 5 * 1024 * 1024) {
      if (mounted) showToast(context, 'Fichier trop volumineux (5 Mo maximum).', kind: ToastKind.error);
      return;
    }
    if (!mounted) return;
    final name = path.split(RegExp(r'[\\/]')).last;
    final info = await showDialog<(String, String?, String)>(
        context: context, builder: (_) => _FileInfoDialog(name: name));
    if (info == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.crmUploadFile(widget.partner.id,
          name: name, kind: info.$1, expiresAt: info.$2, notes: info.$3, bytes: await f.readAsBytes());
      if (mounted) showToast(context, 'Pièce ajoutée.');
      await _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File?> _download(PartnerFile p, Directory dir) async {
    try {
      final bytes = await widget.api.crmFileBytes(widget.partner.id, p.id);
      await dir.create(recursive: true);
      final safe = p.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final f = File('${dir.path}\\$safe');
      await f.writeAsBytes(bytes);
      return f;
    } catch (e) {
      if (mounted) showToast(context, 'Téléchargement impossible : ${errText(e)}', kind: ToastKind.error);
      return null;
    }
  }

  Future<void> _open(PartnerFile p) async {
    final f = await _download(
        p, Directory('${Directory.systemTemp.path}\\elixir_pieces\\${p.id.length > 8 ? p.id.substring(0, 8) : p.id}'));
    if (f != null) await Process.run('cmd', ['/c', 'start', '', f.path]);
  }

  Future<void> _save(PartnerFile p) async {
    final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    final f = await _download(p, Directory('$home\\Downloads'));
    if (f != null && mounted) showToast(context, 'Enregistré : ${f.path}', kind: ToastKind.info);
  }

  Future<void> _delete(PartnerFile p) async {
    final ok = await confirmAction(context,
        title: 'Supprimer « ${p.name} » ?', message: 'La pièce sera supprimée définitivement.', confirmLabel: 'Supprimer', danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteFile(widget.partner.id, p.id);
      _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEditFiche(widget.api);
    return PageSection(
      title: 'Pièces du dossier',
      trailing: canEdit
          ? TextButton.icon(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: Text(_busy ? 'Envoi…' : 'Ajouter une pièce'))
          : null,
      child: _loading
          ? const SkeletonBar(width: 240, height: 14)
          : _error != null
              ? FieldError(_error)
              : _items.isEmpty
                  ? EmptyState(
                      icon: Icons.folder_open_outlined,
                      text: 'Aucune pièce : agrément, registre du commerce, NIF, contrat… (5 Mo maximum par fichier).',
                      actions: [if (canEdit) ('Ajouter une pièce', _add)])
                  : Column(children: [
                      for (final p in _items)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
                          child: Row(children: [
                            Icon(p.mime.contains('pdf') ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined,
                                size: 22, color: T.muted),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(p.name, style: T.body.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                                Text(
                                    [
                                      fileKindLabels[p.kind] ?? p.kind,
                                      _fileSize(p.size),
                                      'ajouté le ${crmDate(p.createdAt)}',
                                      if (p.notes.isNotEmpty) p.notes,
                                    ].join(' · '),
                                    style: T.small),
                              ]),
                            ),
                            if (p.expiresAt != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: DocChip(
                                    label: p.expired ? 'Expiré le ${crmDate(p.expiresAt)}' : 'Valable jusqu’au ${crmDate(p.expiresAt)}',
                                    bg: p.expired ? T.dangerTint : T.mintTint,
                                    fg: p.expired ? T.dangerDark : T.mintDark),
                              ),
                            TextButton(onPressed: () => _open(p), child: const Text('Ouvrir')),
                            TextButton(onPressed: () => _save(p), child: const Text('Télécharger')),
                            if (canEdit)
                              TextButton(
                                  onPressed: () => _delete(p),
                                  child: const Text('Supprimer', style: TextStyle(color: T.dangerDark))),
                          ]),
                        ),
                    ]),
    );
  }
}

class _FileInfoDialog extends StatefulWidget {
  const _FileInfoDialog({required this.name});
  final String name;

  @override
  State<_FileInfoDialog> createState() => _FileInfoDialogState();
}

class _FileInfoDialogState extends State<_FileInfoDialog> {
  String _kind = 'license';
  String? _expires;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: const Text('Ajouter une pièce', style: T.h2),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.name, style: T.body.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          DropdownBlock<String>(
            label: 'Type de pièce',
            value: _kind,
            options: [for (final e in fileKindLabels.entries) (e.key, e.value)],
            onChanged: (v) => setState(() => _kind = v ?? 'other'),
          ),
          DateBlock(
              label: 'Date d’expiration (facultatif)',
              value: _expires,
              onChanged: (v) => setState(() => _expires = v),
              helper: 'Pour être prévenu quand l’agrément ou le contrat expire.'),
          TextBlock(label: 'Notes', controller: _notes),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: () => Navigator.of(context).pop((_kind, _expires, _notes.text.trim())),
          child: const Text('Envoyer'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Étiquettes
// ---------------------------------------------------------------------------

class PartnerTagsTab extends StatefulWidget {
  const PartnerTagsTab({super.key, required this.api, required this.partner, required this.onPartner});
  final ApiClient api;
  final Partner partner;
  final ValueChanged<Partner> onPartner;

  @override
  State<PartnerTagsTab> createState() => _PartnerTagsTabState();
}

class _PartnerTagsTabState extends State<PartnerTagsTab> {
  List<CrmTag> _all = const [];
  late List<String> _ids = [...widget.partner.tagIds];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void didUpdateWidget(PartnerTagsTab old) {
    super.didUpdateWidget(old);
    if (old.partner != widget.partner) _ids = [...widget.partner.tagIds];
  }

  Future<void> _loadTags({bool refresh = false}) async {
    final t = await CrmDirectory.tags(widget.api, refresh: refresh);
    if (mounted) setState(() => _all = t);
  }

  Future<void> _set(List<String> ids) async {
    setState(() => _busy = true);
    try {
      final p = await widget.api.crmSetPartnerTags(widget.partner.id, ids);
      setState(() => _ids = [...p.tagIds]);
      widget.onPartner(p);
      CrmDirectory.forgetTags();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newTag() async {
    final t = await showTagDialog(context, widget.api);
    if (t == null) return;
    await _loadTags(refresh: true);
    await _set([..._ids, t.id]);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEditFiche(widget.api);
    final mine = [for (final t in _all) if (_ids.contains(t.id)) t];
    final others = [for (final t in _all) if (!_ids.contains(t.id)) t];
    return PageSection(
      title: 'Étiquettes',
      trailing: TextButton.icon(
        onPressed: () async {
          if (await openTagsPage(context, widget.api)) _loadTags(refresh: true);
        },
        icon: const Icon(Icons.settings_outlined, size: 17),
        label: const Text('Gérer les étiquettes'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (mine.isEmpty)
          Text('Aucune étiquette sur ce client.', style: T.bodyMuted)
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in mine)
              TagChip(
                  name: t.name,
                  colour: t.colour,
                  onRemove: canEdit && !_busy ? () => _set([for (final i in _ids) if (i != t.id) i]) : null),
          ]),
        if (canEdit) ...[
          const SizedBox(height: 18),
          Text('Ajouter une étiquette', style: T.label),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final t in others)
              ActionChip(
                avatar: Icon(Icons.add_rounded, size: 16, color: hexColour(t.colour)),
                label: Text(t.name, style: T.small.copyWith(color: T.ink)),
                backgroundColor: T.surface,
                side: const BorderSide(color: T.border3),
                onPressed: _busy ? null : () => _set([..._ids, t.id]),
              ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 16, color: T.mintDark),
              label: Text('Nouvelle étiquette…', style: T.small.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
              backgroundColor: T.mintTint,
              side: const BorderSide(color: T.mintTint2),
              onPressed: _busy ? null : _newTag,
            ),
          ]),
        ],
      ]),
    );
  }
}
