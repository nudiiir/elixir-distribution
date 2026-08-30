import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/export.dart';
import '../widgets/data_table.dart';
import '../widgets/doc_list.dart' show paymentLabels;
import '../widgets/ui.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.api
          .partners(q: _searchCtrl.text.trim(), kind: _kind, limit: 500);
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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

  Future<void> _export(List<Partner> rows) async {
    final path = await exportCsv(
      baseName: 'partenaires',
      headers: [
        'Nom',
        'Type',
        'Téléphone',
        'Adresse',
        'NIF',
        'NIS',
        'RC',
        'AI',
        'Solde (DA)'
      ],
      rows: [
        for (final p in rows)
          [
            p.name,
            p.kind,
            p.phone ?? '',
            p.address ?? '',
            p.nif ?? '',
            p.nis ?? '',
            p.rc ?? '',
            p.ai ?? '',
            editDA(p.balance),
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Partenaires', style: T.h1)),
            SizedBox(
              width: 190,
              child: PrimaryButton(
                label: 'Nouveau partenaire',
                onPressed: () => _openForm(),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            for (final (label, value) in [
              ('Tous', null),
              ('Clients', 'customer'),
              ('Fournisseurs', 'supplier')
            ])
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: InkWell(
                  onTap: () {
                    setState(() => _kind = value);
                    _load();
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 13, vertical: 7),
                    decoration: BoxDecoration(
                      color: _kind == value ? T.ink : T.surface,
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: _kind == value ? T.ink : T.border),
                    ),
                    child: Text(label,
                        style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _kind == value ? Colors.white : T.muted,
                        )),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: InkWell(
                onTap: () => setState(() => _onlyDebtors = !_onlyDebtors),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: _onlyDebtors ? T.warnTint : T.surface,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: _onlyDebtors ? T.warn : T.border),
                  ),
                  child: Text('Avec solde',
                      style: TextStyle(
                        fontFamily: T.sans,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _onlyDebtors ? T.warnDark : T.muted,
                      )),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SearchField(
                controller: _searchCtrl,
                hint: 'Rechercher par nom ou téléphone…',
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 250), _load);
                },
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Expanded(
            child: DataListView<Partner>(
              items: _visible,
              onTap: (p) => _openForm(existing: p),
              onExport: _export,
              empty: EmptyState(
                  icon: Icons.people_alt_outlined,
                  text: _loading ? 'Chargement…' : 'Aucun partenaire'),
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
                  label: 'Nom',
                  flex: 4,
                  sortKey: (p) => p.name.toLowerCase(),
                  cell: (context, p) => Text(p.name,
                      style: T.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                ColumnSpec(
                  label: 'Téléphone',
                  flex: 2,
                  cell: (context, p) =>
                      Text(p.phone ?? '—', style: T.monoSmall),
                ),
                ColumnSpec(
                  label: 'Type',
                  width: 110,
                  sortKey: (p) => p.kind,
                  cell: (context, p) => _KindChip(kind: p.kind),
                ),
                ColumnSpec(
                  label: 'Solde',
                  width: 125,
                  numeric: true,
                  sortKey: (p) => p.balance,
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
                ColumnSpec(
                  label: '',
                  width: 105,
                  numeric: true,
                  cell: (context, p) => TextButton(
                    onPressed: () => _openPayment(p),
                    child: Text(
                        p.kind == 'supplier' ? 'Régler' : 'Encaisser',
                        style: T.small.copyWith(
                            color: T.mintDark,
                            fontWeight: FontWeight.w700)),
                  ),
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
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _nif, _nis, _rc, _ai, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Le nom est obligatoire.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
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
      }, id: widget.existing?.id);
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
              _FormField(label: 'Nom / Raison sociale', controller: _name),
              Row(children: [
                Expanded(
                    child: _FormField(label: 'Téléphone', controller: _phone)),
                const SizedBox(width: 10),
                Expanded(
                    child: _FormField(label: 'Adresse', controller: _address)),
              ]),
              Row(children: [
                Expanded(child: _FormField(label: 'NIF', controller: _nif)),
                const SizedBox(width: 10),
                Expanded(child: _FormField(label: 'NIS', controller: _nis)),
              ]),
              Row(children: [
                Expanded(child: _FormField(label: 'RC', controller: _rc)),
                const SizedBox(width: 10),
                Expanded(
                    child: _FormField(
                        label: "Article d'imposition", controller: _ai)),
              ]),
              _FormField(label: 'Notes', controller: _notes),
              if (_error != null) ...[
                const SizedBox(height: 6),
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
  const _FormField({required this.label, required this.controller});
  final String label;
  final TextEditingController controller;

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
              border: Border.all(color: T.border),
            ),
            child: TextField(
              controller: controller,
              style: T.body,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
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
