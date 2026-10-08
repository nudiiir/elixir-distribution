import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'config_widgets.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres › Clients et fidélité : customer groups (price level + discount),
/// default credit ceiling, loyalty points, gift-card validity.
class CustomersSection extends StatefulWidget {
  const CustomersSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<CustomersSection> createState() => _CustomersSectionState();
}

class _CustomersSectionState extends State<CustomersSection> {
  final f = Features.instance;
  late final _credit = TextEditingController(text: f.defaultCreditLimit == 0 ? '' : editDA(f.defaultCreditLimit));
  late bool _loyalty = f.loyaltyEnabled;
  late final _earnPer = TextEditingController(text: editDA(f.loyaltyEarnPer));
  late final _pointValue = TextEditingController(text: editDA(f.loyaltyPointValue));
  late final _minRedeem = TextEditingController(text: '${f.loyaltyMinRedeem}');
  late final _giftDays = TextEditingController(text: '${f.giftCardValidityDays}');
  final Map<String, String?> _err = {};
  bool _busy = false;

  List<CustomerGroup>? _groups;
  String? _groupsError;

  bool get _edit => widget.ctx.isAdmin;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  void dispose() {
    _credit.dispose();
    _earnPer.dispose();
    _pointValue.dispose();
    _minRedeem.dispose();
    _giftDays.dispose();
    super.dispose();
  }

  Future<void> _loadGroups() async {
    setState(() => _groupsError = null);
    try {
      final g = await widget.ctx.api.customerGroups();
      if (mounted) setState(() => _groups = g);
    } on ApiException catch (e) {
      if (mounted) setState(() => _groupsError = e.message);
    }
  }

  Future<void> _save() async {
    final credit = _credit.text.trim().isEmpty ? 0 : parseDA(_credit.text);
    final earn = parseDA(_earnPer.text);
    final value = parseDA(_pointValue.text);
    final minR = int.tryParse(_minRedeem.text.trim());
    final days = int.tryParse(_giftDays.text.trim());
    setState(() {
      _err['credit'] = credit == null || credit < 0 ? 'Montant invalide' : null;
      _err['earn'] = _loyalty && (earn == null || earn <= 0) ? 'Montant supérieur à 0' : null;
      _err['value'] = _loyalty && (value == null || value <= 0) ? 'Montant supérieur à 0' : null;
      _err['min'] = _loyalty && (minR == null || minR < 1) ? 'Au moins 1 point' : null;
      _err['gift'] = days == null || days < 0 || days > 3650 ? 'Entre 0 et 3 650 jours' : null;
    });
    if (_err.values.any((v) => v != null)) return;
    setState(() => _busy = true);
    await saveShopSettings(context, widget.ctx, {
      'default_credit_limit': '$credit',
      'loyalty_enabled': _loyalty ? '1' : '0',
      if (earn != null) 'loyalty_earn_per': '$earn',
      if (value != null) 'loyalty_point_value': '$value',
      if (minR != null) 'loyalty_min_redeem': '$minR',
      'gift_card_validity_days': '$days',
    }, done: 'Réglages des clients enregistrés.');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editGroup([CustomerGroup? g]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _GroupDialog(api: widget.ctx.api, group: g),
    );
    if (saved == true) {
      await _loadGroups();
      if (mounted) showToast(context, g == null ? 'Groupe créé.' : 'Groupe modifié.');
    }
  }

  Future<void> _deleteGroup(CustomerGroup g) async {
    final ok = await confirmAction(context,
        title: 'Supprimer le groupe « ${g.name} » ?',
        message: g.members == 0
            ? 'Aucun client n’est dans ce groupe.'
            : '${g.members} client(s) quitteront ce groupe et reprendront leur propre tarif.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await widget.ctx.api.deleteCustomerGroup(g.id);
      await _loadGroups();
      if (mounted) showToast(context, 'Groupe supprimé.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  String _loyaltyExample() {
    final earn = parseDA(_earnPer.text) ?? 0;
    final value = parseDA(_pointValue.text) ?? 0;
    final minR = int.tryParse(_minRedeem.text.trim()) ?? 0;
    if (earn <= 0 || value <= 0) return '';
    const spend = 250000; // 2 500 DA
    final pts = spend ~/ earn;
    return 'Exemple : un achat de ${fmtDA(spend)} rapporte $pts point(s). '
        '$minR points valent ${fmtDA(minR * value)} de réduction.';
  }

  Widget _groupsView() {
    if (_groupsError != null) {
      return Row(children: [
        Expanded(child: FieldError(_groupsError)),
        TextButton(onPressed: _loadGroups, child: const Text('Réessayer')),
      ]);
    }
    final gs = _groups;
    if (gs == null) {
      return const Column(children: [SkeletonBar(width: 400, height: 14), SizedBox(height: 10), SkeletonBar(width: 300, height: 14)]);
    }
    if (gs.isEmpty) {
      return EmptyState(
        icon: Icons.groups_2_outlined,
        text: 'Aucun groupe. Un groupe donne à ses clients un tarif (détail ou demi-gros) et une remise, '
            'appliqués dès que le client est choisi sur une vente.',
        actions: [if (_edit) ('Nouveau groupe', () => _editGroup())],
      );
    }
    return Column(children: [
      for (final g in gs)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: Text(g.name, style: T.body.copyWith(fontWeight: FontWeight.w700)),
            ),
            Expanded(
              flex: 2,
              child: Text(g.priceLevel == 'wholesale' ? 'Tarif demi-gros' : 'Tarif détail', style: T.body),
            ),
            Expanded(
              flex: 2,
              child: Text(g.discountPct == 0 ? 'Sans remise' : 'Remise ${editPct(g.discountPct)} %', style: T.body),
            ),
            Expanded(flex: 2, child: Text('${g.members} client(s)', style: T.bodyMuted)),
            if (_edit) ...[
              TextButton.icon(
                onPressed: () => _editGroup(g),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('Modifier'),
              ),
              TextButton.icon(
                onPressed: () => _deleteGroup(g),
                style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
                label: const Text('Supprimer'),
              ),
            ],
          ]),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ex = _loyaltyExample();
    return SettingsPage(
      title: 'Clients et fidélité',
      intro: 'Tarifs par groupe de clients, plafond de crédit, points de fidélité et cartes cadeaux.',
      actions: [
        if (_edit)
          PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _busy ? null : _save),
      ],
      children: [
        if (!_edit) const AdminOnlyNotice(),
        PageSection(
          title: 'Groupes de clients',
          trailing: _edit && (_groups?.isNotEmpty ?? false)
              ? OutlinedButton.icon(
                  onPressed: () => _editGroup(),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Nouveau groupe'))
              : null,
          child: _groupsView(),
        ),
        PageSection(
          title: 'Crédit',
          child: NumberField(
            label: 'Plafond de crédit par défaut',
            controller: _credit,
            suffix: 'DA',
            decimals: true,
            enabled: _edit,
            error: _err['credit'],
            help: 'Dette maximale d’un client qui n’a pas son propre plafond (nouveaux clients compris). '
                'Au-delà, la vente à crédit demande le code du gérant. Vide ou 0 = pas de plafond.',
          ),
        ),
        PageSection(
          title: 'Fidélité',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchRow(
              title: 'Activer les points de fidélité',
              explanation: 'Chaque vente validée avec un client lui rapporte des points, '
                  'qu’il peut utiliser comme réduction à la caisse.',
              value: _loyalty,
              onChanged: _edit ? (v) => setState(() => _loyalty = v) : null,
            ),
            if (_loyalty) ...[
              const SizedBox(height: 10),
              NumberField(
                label: '1 point pour chaque',
                controller: _earnPer,
                suffix: 'DA dépensés',
                decimals: true,
                required: true,
                enabled: _edit,
                error: _err['earn'],
                onChanged: (_) => setState(() {}),
              ),
              NumberField(
                label: 'Valeur d’un point',
                controller: _pointValue,
                suffix: 'DA',
                decimals: true,
                required: true,
                enabled: _edit,
                error: _err['value'],
                onChanged: (_) => setState(() {}),
              ),
              NumberField(
                label: 'Minimum de points pour les utiliser',
                controller: _minRedeem,
                suffix: 'points',
                required: true,
                enabled: _edit,
                error: _err['min'],
                onChanged: (_) => setState(() {}),
              ),
              if (ex.isNotEmpty) InfoBanner(icon: Icons.lightbulb_outline_rounded, text: ex),
              Text('Annuler une vente retire les points qu’elle a rapportés et rend ceux qui y ont été utilisés.',
                  style: T.small),
            ],
          ]),
        ),
        PageSection(
          title: 'Cartes cadeaux',
          child: NumberField(
            label: 'Validité d’une carte cadeau',
            controller: _giftDays,
            suffix: 'jours',
            enabled: _edit,
            error: _err['gift'],
            help: 'À partir du jour de la vente de la carte. 0 = sans date limite. '
                'Une carte expirée est refusée à la caisse.',
          ),
        ),
      ],
    );
  }
}

/// Quick create / edit of a customer group (three fields).
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.api, this.group});
  final ApiClient api;
  final CustomerGroup? group;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final _disc = TextEditingController(
      text: widget.group == null || widget.group!.discountPct == 0 ? '' : editPct(widget.group!.discountPct));
  late String _level = widget.group?.priceLevel ?? 'retail';
  String? _nameErr;
  String? _discErr;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _disc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final d = _disc.text.trim().isEmpty ? 0 : parsePct(_disc.text);
    setState(() {
      _nameErr = name.isEmpty ? 'Le nom est obligatoire' : null;
      _discErr = d == null || d > 10000 ? 'Entre 0 et 100 %' : null;
    });
    if (_nameErr != null || _discErr != null) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveCustomerGroup(id: widget.group?.id, name: name, priceLevel: _level, discountPct: d!);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          if (e.message.contains('nom')) {
            _nameErr = e.message;
          } else {
            _discErr = e.message;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(widget.group == null ? 'Nouveau groupe de clients' : 'Modifier le groupe', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
              label: 'Nom du groupe',
              controller: _name,
              required: true,
              error: _nameErr,
              hint: 'ex. Revendeurs, Fidèles, Entreprises',
              onSubmitted: (_) => _save()),
          OptionChips<String>(
            label: 'Tarif appliqué',
            value: _level,
            options: [('retail', 'Détail'), if (Features.instance.wholesale) ('wholesale', 'Demi-gros')],
            onChanged: (v) => setState(() => _level = v),
          ),
          NumberField(
            label: 'Remise automatique',
            controller: _disc,
            suffix: '%',
            decimals: true,
            width: 140,
            error: _discErr,
            help: 'Appliquée sur chaque ligne de la vente. Vide = sans remise.',
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Enregistrement…' : 'Enregistrer'),
        ),
      ],
    );
  }
}
