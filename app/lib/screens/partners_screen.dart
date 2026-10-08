import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/prefs.dart';
import '../widgets/data_table.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart' show paymentLabels, showDocDetailDialog;
import '../widgets/list_toolbar.dart';
import '../widgets/ui.dart';

const _prefs = 'partners';

class PartnersScreen extends StatefulWidget {
  const PartnersScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<PartnersScreen> createState() => _PartnersScreenState();
}

class _PartnersScreenState extends State<PartnersScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String? _kind; // null | customer | supplier
  bool _onlyDebtors = false;
  List<Partner> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final k = UiPrefs.instance.get<String>(_prefs, 'kind');
    _kind = k == 'customer' || k == 'supplier' ? k : null;
    _onlyDebtors = UiPrefs.instance.get<bool>(_prefs, 'with_balance') ?? false;
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api
          .partners(q: _searchCtrl.text.trim(), kind: _kind, limit: 500);
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger les partenaires : $e';
        });
      }
    }
  }

  void _setKind(String? k, {bool debtors = false}) {
    setState(() {
      _kind = k;
      _onlyDebtors = debtors;
    });
    UiPrefs.instance.set(_prefs, 'kind', k);
    UiPrefs.instance.set(_prefs, 'with_balance', debtors);
    _load();
  }

  List<Partner> get _visible =>
      _onlyDebtors ? _items.where((p) => p.balance != 0).toList() : _items;

  Future<void> _openForm({Partner? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PartnerFormDialog(api: widget.api, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _openPayment(Partner p) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _PaymentDialog(api: widget.api, partner: p),
    );
    if (done == true) _load();
  }

  Future<void> _openInstallments(Partner p) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _InstallmentsDialog(api: widget.api, partner: p),
    );
    _load();
  }

  Future<void> _openStatement(Partner p) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _StatementDialog(api: widget.api, partner: p),
    );
    _load();
  }

  Future<void> _newDoc(Partner p, DocEditorConfig cfg) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, initialPartner: p),
    ));
    if (changed == true) _load();
  }

  List<RowAction<Partner>> _rowMenu(Partner p) => [
        RowAction('Modifier', Icons.edit_outlined, (p) => _openForm(existing: p)),
        RowAction(p.kind == 'supplier' ? 'Régler' : 'Encaisser',
            Icons.payments_outlined, _openPayment),
        RowAction('Relevé (factures ouvertes)', Icons.receipt_long_outlined,
            _openStatement),
        if (p.kind != 'supplier')
          RowAction('Échéancier', Icons.event_repeat_rounded, _openInstallments),
        if (p.kind != 'supplier')
          RowAction('Nouvelle facture', Icons.note_add_outlined,
              (p) => _newDoc(p, saleInvoiceConfig)),
        if (p.kind != 'customer')
          RowAction('Nouvelle réception', Icons.move_to_inbox_outlined,
              (p) => _newDoc(p, purchaseReceiptConfig)),
      ];

  String _kindLabel(String k) => switch (k) {
        'customer' => 'client',
        'supplier' => 'fournisseur',
        _ => 'mixte',
      };

  @override
  Widget build(BuildContext context) {
    final searching = _searchCtrl.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Partenaires',
            primaryLabel: 'Nouveau partenaire',
            primaryIcon: Icons.person_add_alt_1_outlined,
            onPrimary: () => _openForm(),
          ),
          const SizedBox(height: 16),
          ListToolbar(
            search: _searchCtrl,
            searchHint: 'Rechercher par nom ou téléphone…',
            onSearchChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), _load);
            },
            quickFilters: [
              FilterPill(
                  label: 'Tous',
                  active: _kind == null && !_onlyDebtors,
                  onTap: () => _setKind(null)),
              FilterPill(
                  label: 'Clients',
                  active: _kind == 'customer',
                  onTap: () => _setKind('customer', debtors: _onlyDebtors)),
              FilterPill(
                  label: 'Fournisseurs',
                  active: _kind == 'supplier',
                  onTap: () => _setKind('supplier', debtors: _onlyDebtors)),
              FilterPill(
                  label: 'Avec solde',
                  icon: Icons.account_balance_wallet_outlined,
                  active: _onlyDebtors,
                  onTap: () => _setKind(_kind, debtors: !_onlyDebtors)),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Partner>(
              items: _visible,
              prefsKey: _prefs,
              loading: _loading,
              error: _error,
              onRetry: _load,
              rowId: (p) => p.id,
              rowMenu: _rowMenu,
              onTap: (p) => _openForm(existing: p),
              exportTitle: 'Partenaires',
              exportBaseName: 'partenaires',
              empty: EmptyState(
                icon: Icons.people_alt_outlined,
                text: searching || _kind != null || _onlyDebtors
                    ? 'Aucun partenaire ne correspond.'
                    : 'Aucun partenaire pour l’instant.',
                actions: [
                  if (searching || _kind != null || _onlyDebtors)
                    ('Effacer les filtres', () {
                      _searchCtrl.clear();
                      _setKind(null);
                    }),
                  ('Nouveau partenaire', () => _openForm()),
                ],
              ),
              aggregates: (rows) {
                final owedToUs = rows
                    .where((p) => p.balance > 0)
                    .fold(0, (s, p) => s + p.balance);
                final weOwe = rows
                    .where((p) => p.balance < 0)
                    .fold(0, (s, p) => s - p.balance);
                return [
                  ('Créances', fmtDA(owedToUs)),
                  ('Dettes', fmtDA(weOwe)),
                ];
              },
              columns: [
                ColumnSpec(
                  id: 'name',
                  label: 'Nom',
                  flex: 4,
                  hideable: false,
                  sortKey: (p) => p.name.toLowerCase(),
                  exportValue: (p) => p.name,
                  cell: (context, p) => Text(p.name,
                      style: T.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'phone',
                  label: 'Téléphone',
                  flex: 2,
                  sortKey: (p) => p.phone ?? '',
                  exportValue: (p) => p.phone ?? '',
                  cell: (context, p) =>
                      Text(p.phone ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'kind',
                  label: 'Type',
                  width: 110,
                  sortKey: (p) => p.kind,
                  exportValue: (p) => _kindLabel(p.kind),
                  cell: (context, p) => _KindChip(kind: p.kind),
                ),
                ColumnSpec(
                  id: 'address',
                  label: 'Adresse',
                  flex: 3,
                  visibleByDefault: false,
                  sortKey: (p) => (p.address ?? '').toLowerCase(),
                  exportValue: (p) => p.address ?? '',
                  cell: (context, p) => Text(p.address ?? '—',
                      style: T.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  id: 'nif',
                  label: 'NIF',
                  width: 150,
                  visibleByDefault: false,
                  exportValue: (p) => p.nif ?? '',
                  cell: (context, p) => Text(p.nif ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'rc',
                  label: 'RC',
                  width: 120,
                  visibleByDefault: false,
                  exportValue: (p) => p.rc ?? '',
                  cell: (context, p) => Text(p.rc ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  id: 'balance',
                  label: 'Solde',
                  width: 125,
                  numeric: true,
                  sortKey: (p) => p.balance,
                  exportValue: (p) => p.balance / 100,
                  cell: (context, p) => Text(fmtDA(p.balance),
                      style: T.monoBody.copyWith(
                        color: p.balance > 0
                            ? T.warnDark
                            : p.balance < 0
                                ? T.mintDark
                                : T.faint,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final label = switch (kind) {
      'customer' => 'client',
      'supplier' => 'fournisseur',
      _ => 'mixte',
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: T.cream, borderRadius: BorderRadius.circular(T.rChip)),
        child: Text(label.toUpperCase(),
            style: T.label.copyWith(fontSize: 9, color: T.muted)),
      ),
    );
  }
}

// ---------------- Relevé (factures ouvertes, FIFO) ----------------

class _StatementDialog extends StatefulWidget {
  const _StatementDialog({required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<_StatementDialog> createState() => _StatementDialogState();
}

class _StatementDialogState extends State<_StatementDialog> {
  PartnerOpenItems? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.partnerOpenItems(widget.partner.id);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 640,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text('Relevé — ${widget.partner.name}',
                      style: T.h2, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
              ]),
              Text(
                  'Factures encore ouvertes : règlements et avoirs imputés aux '
                  'plus anciennes d’abord.',
                  style: T.small),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  Expanded(flex: 3, child: MicroLabel('Document')),
                  SizedBox(width: 90, child: MicroLabel('Date')),
                  SizedBox(width: 90, child: MicroLabel('Échéance')),
                  SizedBox(
                      width: 110,
                      child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: MicroLabel('Total'))),
                  SizedBox(
                      width: 110,
                      child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: MicroLabel('Reste'))),
                  SizedBox(
                      width: 60,
                      child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: MicroLabel('Âge'))),
                ]),
              ),
              const Divider(),
              Expanded(
                child: d == null
                    ? Center(
                        child: _error != null
                            ? Text(_error!, style: T.bodyMuted)
                            : const CircularProgressIndicator(color: T.mint))
                    : d.items.isEmpty
                        ? const EmptyState(
                            icon: Icons.check_circle_outline_rounded,
                            text: 'Aucune facture ouverte : compte à jour.')
                        : ListView.separated(
                            itemCount: d.items.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) {
                              final it = d.items[i];
                              final c = it.overdue ? T.warnDark : T.ink;
                              return InkWell(
                                onTap: it.documentId.isEmpty
                                    ? null
                                    : () async {
                                        final changed =
                                            await showDocDetailDialog(context,
                                                widget.api, it.documentId);
                                        if (changed == true) _load();
                                      },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 9),
                                  child: Row(children: [
                                    Expanded(
                                        flex: 3,
                                        child: Text(
                                            it.number.isEmpty ? '—' : it.number,
                                            style: T.monoBody
                                                .copyWith(fontSize: 12))),
                                    SizedBox(
                                        width: 90,
                                        child:
                                            Text(it.docDate, style: T.monoSmall)),
                                    SizedBox(
                                        width: 90,
                                        child: Text(
                                            it.dueDate.isEmpty ? '—' : it.dueDate,
                                            style: T.monoSmall.copyWith(
                                                color: it.overdue
                                                    ? T.warnDark
                                                    : T.muted,
                                                fontWeight: it.overdue
                                                    ? FontWeight.w800
                                                    : FontWeight.w500))),
                                    SizedBox(
                                        width: 110,
                                        child: Text(fmtDA(it.total),
                                            textAlign: TextAlign.end,
                                            style: T.monoSmall)),
                                    SizedBox(
                                        width: 110,
                                        child: Text(fmtDA(it.outstanding),
                                            textAlign: TextAlign.end,
                                            style: T.monoBody.copyWith(
                                                color: c,
                                                fontWeight: FontWeight.w700))),
                                    SizedBox(
                                        width: 60,
                                        child: Text('${it.ageDays} j',
                                            textAlign: TextAlign.end,
                                            style: T.monoSmall
                                                .copyWith(color: c))),
                                  ]),
                                ),
                              );
                            },
                          ),
              ),
              if (d != null) ...[
                const Divider(),
                const SizedBox(height: 8),
                Row(children: [
                  if (d.unallocatedCredit > 0)
                    MintChip('Avoir non affecté ${fmtDA(d.unallocatedCredit)}',
                        color: T.mintTint, fg: T.mintDark),
                  const Spacer(),
                  const MicroLabel('Total ouvert'),
                  const SizedBox(width: 10),
                  Text(fmtDA(d.totalOpen),
                      style: T.monoBig.copyWith(
                          fontSize: 18,
                          color: d.totalOpen > 0 ? T.warnDark : T.ink)),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- Partner form ----------------

class _PartnerFormDialog extends StatefulWidget {
  const _PartnerFormDialog({required this.api, this.existing});
  final ApiClient api;
  final Partner? existing;

  @override
  State<_PartnerFormDialog> createState() => _PartnerFormDialogState();
}

class _PartnerFormDialogState extends State<_PartnerFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _address =
      TextEditingController(text: widget.existing?.address ?? '');
  late final _nif = TextEditingController(text: widget.existing?.nif ?? '');
  late final _nis = TextEditingController(text: widget.existing?.nis ?? '');
  late final _rc = TextEditingController(text: widget.existing?.rc ?? '');
  late final _ai = TextEditingController(text: widget.existing?.ai ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late String _kind = widget.existing?.kind ?? 'customer';
  late String _priceLevel = widget.existing?.priceLevel ?? 'retail';
  bool _busy = false;
  Map<String, String> _err = const {};

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _nif, _nis, _rc, _ai, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
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
      await widget.api.savePartner({
        'kind': _kind,
        'name': _name.text.trim(),
        'phone': v(_phone),
        'address': v(_address),
        'nif': v(_nif),
        'nis': v(_nis),
        'rc': v(_rc),
        'ai': v(_ai),
        'notes': v(_notes),
        'price_level': _priceLevel,
      }, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context,
          widget.existing == null ? 'Partenaire créé' : 'Partenaire enregistré');
      Navigator.of(context).pop(true);
    } on ApiException catch (ex) {
      final m = ex.message.toLowerCase();
      setState(() => _err = {
            m.contains('name')
                ? 'name'
                : m.contains('nif')
                    ? 'nif'
                    : 'form': ex.message
          });
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
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  widget.existing == null
                      ? 'Nouveau partenaire'
                      : widget.existing!.name,
                  style: T.h2),
              const SizedBox(height: 16),
              Row(children: [
                for (final (label, value) in [
                  ('Client', 'customer'),
                  ('Fournisseur', 'supplier'),
                  ('Les deux', 'both')
                ])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(
                      label: Text(label,
                          style: TextStyle(
                              fontFamily: T.sans,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _kind == value ? T.mintDark : T.muted)),
                      selected: _kind == value,
                      selectedColor: T.mintTint,
                      backgroundColor: T.bg,
                      side: BorderSide(
                          color: _kind == value ? T.mintDeep : T.border),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _kind = value),
                    ),
                  ),
              ]),
              const SizedBox(height: 12),
              _FormField(
                  label: 'Nom / Raison sociale *',
                  controller: _name,
                  error: _err['name'],
                  autofocus: widget.existing == null,
                  onSubmitted: _save),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: _FormField(
                        label: 'Téléphone',
                        controller: _phone,
                        error: _err['phone'],
                        onSubmitted: _save)),
                const SizedBox(width: 10),
                Expanded(
                    child: _FormField(label: 'Adresse', controller: _address)),
              ]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: _FormField(
                        label: 'NIF', controller: _nif, error: _err['nif'])),
                const SizedBox(width: 10),
                Expanded(
                    child: _FormField(
                        label: 'NIS', controller: _nis, error: _err['nis'])),
              ]),
              Row(children: [
                Expanded(child: _FormField(label: 'RC', controller: _rc)),
                const SizedBox(width: 10),
                Expanded(
                    child: _FormField(
                        label: "Article d'imposition", controller: _ai)),
              ]),
              _FormField(label: 'Notes', controller: _notes),
              if (_kind != 'supplier') ...[
                const MicroLabel('Tarif appliqué'),
                const SizedBox(height: 6),
                Row(children: [
                  for (final (label, value) in [
                    ('Détail', 'retail'),
                    ('Demi-gros', 'wholesale')
                  ])
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ChoiceChip(
                        label: Text(label,
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _priceLevel == value
                                    ? T.mintDark
                                    : T.muted)),
                        selected: _priceLevel == value,
                        selectedColor: T.mintTint,
                        backgroundColor: T.bg,
                        side: BorderSide(
                            color: _priceLevel == value
                                ? T.mintDeep
                                : T.border),
                        showCheckmark: false,
                        onSelected: (_) =>
                            setState(() => _priceLevel = value),
                      ),
                    ),
                ]),
                const SizedBox(height: 6),
              ],
              if (_err['form'] != null) FieldError(_err['form']),
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Enregistrer',
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

class _FormField extends StatelessWidget {
  const _FormField({
    required this.label,
    required this.controller,
    this.error,
    this.autofocus = false,
    this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final String? error;
  final bool autofocus;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MicroLabel(label),
          const SizedBox(height: 4),
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(
                  color: error != null ? T.danger : T.border,
                  width: error != null ? 1.4 : 1),
            ),
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              style: T.body,
              onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          FieldError(error),
        ],
      ),
    );
  }
}

// ---------------- Installments (facilité de paiement) ----------------

class _InstallmentsDialog extends StatefulWidget {
  const _InstallmentsDialog({required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<_InstallmentsDialog> createState() => _InstallmentsDialogState();
}

class _InstallmentsDialogState extends State<_InstallmentsDialog> {
  List<InstallmentPlan> _plans = const [];
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
      final plans =
          await widget.api.installmentPlans(partnerId: widget.partner.id);
      if (mounted) {
        setState(() {
          _plans = plans;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newPlan() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _NewPlanDialog(api: widget.api, partner: widget.partner),
    );
    if (created == true) _load();
  }

  /// Encaisser une échéance : PAYMENT_IN espèces + pointage de l'échéance.
  Future<void> _payDue(InstallmentDue d) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.createPayment(
        docType: 'PAYMENT_IN',
        partnerId: widget.partner.id,
        amount: d.remaining,
        method: 'cash',
      );
      await widget.api.payInstallmentDue(d.id);
      _load();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 540,
        height: 500,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('Échéances — ${widget.partner.name}',
                        style: T.h2, overflow: TextOverflow.ellipsis),
                  ),
                  SizedBox(
                    width: 140,
                    child: PrimaryButton(
                        label: 'Nouveau plan', onPressed: _newPlan),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ]),
                if (_error != null)
                  Text(_error!,
                      style: T.small.copyWith(color: T.dangerDark)),
                const SizedBox(height: 8),
                Expanded(
                  child: _plans.isEmpty
                      ? EmptyState(
                          icon: Icons.event_repeat_rounded,
                          text: _loading
                              ? 'Chargement…'
                              : 'Aucune facilité de paiement.\nCréez un plan pour étaler une vente à crédit.')
                      : ListView(children: [
                          for (final plan in _plans) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 4),
                              child: Row(children: [
                                Expanded(
                                  child: Text(
                                      '${fmtDA(plan.total)} sur ${plan.months} mois'
                                      '${plan.docNumber != null ? ' · ${plan.docNumber}' : ''}',
                                      style: T.body.copyWith(
                                          fontWeight: FontWeight.w700)),
                                ),
                                Text(
                                    '${fmtDA(plan.totalPaid)} / ${fmtDA(plan.total)}',
                                    style: T.monoSmall),
                              ]),
                            ),
                            for (final d in plan.dues)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(children: [
                                  Icon(
                                      d.settled
                                          ? Icons.check_circle_rounded
                                          : d.dueDate.compareTo(today) < 0
                                              ? Icons.error_rounded
                                              : Icons.schedule_rounded,
                                      size: 15,
                                      color: d.settled
                                          ? T.mintDeep
                                          : d.dueDate.compareTo(today) < 0
                                              ? T.danger
                                              : T.faint),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                      width: 95,
                                      child: Text(d.dueDate,
                                          style: T.monoSmall
                                              .copyWith(fontSize: 11))),
                                  Expanded(
                                      child: Text(fmtDA(d.amount),
                                          style: T.monoBody
                                              .copyWith(fontSize: 12))),
                                  if (d.settled)
                                    const MintChip('payée',
                                        color: T.mintTint, fg: T.mintDark)
                                  else
                                    TextButton(
                                      onPressed:
                                          _busy ? null : () => _payDue(d),
                                      child: Text(
                                          'Encaisser ${fmtDA(d.remaining)}',
                                          style: T.small.copyWith(
                                              color: T.mintDark,
                                              fontWeight: FontWeight.w700)),
                                    ),
                                ]),
                              ),
                            const Divider(height: 16),
                          ],
                        ]),
                ),
              ]),
        ),
      ),
    );
  }
}

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
  String? _error;

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
    if (total == null || total <= 0 || months == null || months < 1) {
      setState(() => _error = 'Montant et nombre de mois obligatoires.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.createInstallmentPlan(
        partnerId: widget.partner.id,
        total: total,
        months: months,
        startDate: _start,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
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
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nouveau plan de paiement', style: T.h2),
              const SizedBox(height: 4),
              Text(
                  'La dette vient de la vente à crédit ; le plan la découpe '
                  'en mensualités égales.',
                  style: T.small),
              const SizedBox(height: 14),
              _FormField(label: 'Montant total (DA)', controller: _total),
              Row(children: [
                Expanded(
                    child: _FormField(
                        label: 'Nombre de mois', controller: _months)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const MicroLabel('1re échéance'),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: _pickStart,
                          borderRadius: BorderRadius.circular(T.rInner),
                          child: Container(
                            height: 38,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            alignment: AlignmentDirectional.centerStart,
                            decoration: BoxDecoration(
                              color: T.bg,
                              borderRadius: BorderRadius.circular(T.rInner),
                              border: Border.all(color: T.border),
                            ),
                            child: Text(_start, style: T.monoBody),
                          ),
                        ),
                      ]),
                ),
              ]),
              if (_error != null)
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              const SizedBox(height: 14),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child:
                      Text('Annuler', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Créer',
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

// ---------------- Payment dialog ----------------

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.api, required this.partner});
  final ApiClient api;
  final Partner partner;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final _amount = TextEditingController();
  String _method = 'cash';
  bool _busy = false;
  String? _error;

  bool get isOut => widget.partner.kind == 'supplier';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = parseDA(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Montant invalide.');
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Text('${doc.number}  ·  ${fmtDA(doc.amount)}',
            style: const TextStyle(
                fontFamily: T.mono, fontSize: 13, color: Colors.white)),
      ));
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
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isOut ? 'Régler ${p.name}' : 'Encaisser ${p.name}',
                  style: T.h2),
              const SizedBox(height: 4),
              Text(
                  p.balance == 0
                      ? 'Solde à jour'
                      : p.balance > 0
                          ? 'Vous doit ${fmtDA(p.balance)}'
                          : 'Vous lui devez ${fmtDA(-p.balance)}',
                  style: T.bodyMuted),
              const SizedBox(height: 16),
              const MicroLabel('Montant (DA)'),
              const SizedBox(height: 4),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: _amount,
                  autofocus: true,
                  style: T.monoBig.copyWith(fontSize: 20),
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
              const SizedBox(height: 12),
              const MicroLabel('Mode de règlement'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final m in ['cash', 'cib', 'cheque', 'transfer'])
                    ChoiceChip(
                      label: Text(paymentLabels[m]!,
                          style: TextStyle(
                              fontFamily: T.sans,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _method == m ? T.mintDark : T.muted)),
                      selected: _method == m,
                      selectedColor: T.mintTint,
                      backgroundColor: T.bg,
                      side: BorderSide(
                          color: _method == m ? T.mintDeep : T.border),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child:
                      Text('Fermer', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Confirmer',
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
