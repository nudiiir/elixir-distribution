import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../pos/cash_rounding.dart';
import 'settings_shell.dart';

/// Paramètres › Caisse : how the till behaves for every PC of the shop.
/// Administrators change it; the others read it.
class PosSettingsSection extends StatefulWidget {
  const PosSettingsSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<PosSettingsSection> createState() => _PosSettingsSectionState();
}

/// The payment methods the till can offer, in tile order.
const _methods = <(String, String, String)>[
  ('cash', 'Espèces', 'Billets et pièces, avec le rendu de monnaie.'),
  ('cib', 'CIB', 'Carte bancaire sur le terminal de paiement.'),
  ('edahabia', 'Edahabia', 'Carte Algérie Poste sur le terminal.'),
  ('cheque', 'Chèque', ''),
  (
    'credit',
    'Crédit client',
    'Le client paie plus tard : la somme va sur son compte.',
  ),
  (
    'gift',
    'Carte cadeau',
    'Le client paie avec le solde d’une carte cadeau du magasin.',
  ),
  (
    'loyalty',
    'Points fidélité',
    'Le client utilise ses points : leur valeur est déduite du ticket.',
  ),
];

class _PosSettingsSectionState extends State<PosSettingsSection> {
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  List<Warehouse> _warehouses = const [];
  Partner? _customer; // default customer
  String? _customerId;
  String? _warehouseId;
  Set<String> _payments = {};
  final _float = TextEditingController();
  final _askAbove = TextEditingController();
  bool _autoPrint = true;
  bool _openDrawer = true;
  bool _beep = true;
  int _rounding = 0;
  bool _dailyZ = true;
  int _quickKeys = 0;
  String? _floatError;
  String? _askError;
  String? _paymentsError;

  bool get _admin => widget.ctx.isAdmin;
  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _float.dispose();
    _askAbove.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final s = await _api.settings();
      Features.instance.apply(s);
      final f = Features.instance;
      List<Warehouse> whs = const [];
      try {
        whs = await _api.warehouses();
      } catch (_) {}
      Partner? cust;
      if (f.posDefaultCustomerId != null) {
        try {
          cust = await _api.getPartner(f.posDefaultCustomerId!);
        } catch (_) {}
      }
      int keys = 0;
      try {
        keys = (jsonDecode(s['pos_quick_keys'] ?? '[]') as List).length;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _warehouses = whs;
        _customer = cust;
        _customerId = cust?.id;
        _warehouseId = whs.any((w) => w.id == f.posDefaultWarehouseId)
            ? f.posDefaultWarehouseId
            : null;
        _payments = {...f.posPaymentMethods};
        _float.text = f.posDefaultFloat > 0 ? editDA(f.posDefaultFloat) : '';
        _askAbove.text = f.posAskCustomerAbove > 0
            ? editDA(f.posAskCustomerAbove)
            : '';
        _autoPrint = f.posAutoPrint;
        _openDrawer = f.posOpenDrawer;
        _beep = f.posBeep;
        _rounding = const [0, 50, 100, 500].contains(f.posCashRounding)
            ? f.posCashRounding
            : 0;
        _dailyZ = f.posRequireDailyZ;
        _quickKeys = keys;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickCustomer() async {
    final p = await showPartnerPicker(context, _api, kind: 'customer');
    if (p != null && mounted) {
      setState(() {
        _customer = p;
        _customerId = p.id;
      });
    }
  }

  Future<void> _save() async {
    final float = _float.text.trim().isEmpty ? 0 : parseDA(_float.text);
    final ask = _askAbove.text.trim().isEmpty ? 0 : parseDA(_askAbove.text);
    setState(() {
      _floatError = float == null || float < 0
          ? 'Montant invalide (ex. 5000).'
          : null;
      _askError = ask == null || ask < 0
          ? 'Montant invalide (ex. 20000), 0 = jamais.'
          : null;
      _paymentsError = _payments.isEmpty
          ? 'Cochez au moins un moyen de paiement.'
          : null;
    });
    if (_floatError != null || _askError != null || _paymentsError != null) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _api.saveSettings({
        'pos_default_customer_id': _customerId ?? '',
        'pos_default_warehouse_id': _warehouseId ?? '',
        'pos_payment_methods': [
          for (final m in _methods)
            if (_payments.contains(m.$1)) m.$1,
        ].join('|'),
        'pos_default_float': '$float',
        'pos_auto_print': _autoPrint ? '1' : '0',
        'pos_open_drawer': _openDrawer ? '1' : '0',
        'pos_beep': _beep ? '1' : '0',
        'pos_cash_rounding': '$_rounding',
        'pos_ask_customer_above': '$ask',
        'pos_require_daily_z': _dailyZ ? '1' : '0',
      });
      await Features.instance.load(_api);
      if (mounted) showToast(context, 'Réglages de la caisse enregistrés.');
    } on ApiException catch (e) {
      if (mounted) {
        showToast(
          context,
          'Enregistrement impossible : ${e.message}',
          kind: ToastKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearQuickKeys() async {
    final ok = await confirmAction(
      context,
      title: 'Retirer toutes les touches rapides ?',
      message:
          'Les $_quickKeys produits épinglés ne seront plus en tête de la grille de la caisse. '
          'Vous pourrez les épingler à nouveau (clic droit sur un produit dans la caisse).',
      confirmLabel: 'Retirer',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.saveSettings({'pos_quick_keys': '[]'});
      if (mounted) {
        setState(() => _quickKeys = 0);
        showToast(context, 'Touches rapides retirées.');
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  // ---- small building blocks (label above, help under) ----

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: T.label),
  );

  Widget _help(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: T.small),
  );

  Widget _amountField(
    TextEditingController c, {
    String? error,
    String hint = '0,00',
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 220,
        height: 44,
        child: TextField(
          controller: c,
          enabled: _admin,
          style: T.monoBody,
          textAlign: TextAlign.end,
          decoration: InputDecoration(
            hintText: hint,
            suffixText: 'DA',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
        ),
      ),
      if (error != null) FieldError(error),
    ],
  );

  Widget _switch(
    String title,
    String help,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(help, style: T.small),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: T.mintDark,
          onChanged: _admin ? onChanged : null,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPage(
        title: 'Caisse',
        children: [
          Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(color: T.mint),
            ),
          ),
        ],
      );
    }
    if (_loadError != null) {
      return SettingsPage(
        title: 'Caisse',
        children: [
          Text(
            'Impossible de lire les réglages : $_loadError',
            style: T.body.copyWith(color: T.dangerDark),
          ),
          const SizedBox(height: 10),
          PageAction(label: 'Réessayer', icon: Icons.refresh, onPressed: _load),
        ],
      );
    }
    final loyalty = Features.instance.loyaltyEnabled;
    final example = 12345; // 123,45 DA
    final exD = cashRoundingDelta(example, _rounding, timbre: false);
    return SettingsPage(
      title: 'Caisse',
      intro:
          'Comment la caisse se comporte sur tous les postes du magasin : client et dépôt proposés, '
          'moyens de paiement, tiroir, arrondi des espèces et clôture du jour.',
      actions: [
        if (_admin)
          PageAction(
            label: _saving ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check,
            primary: true,
            onPressed: _saving ? null : _save,
          ),
      ],
      children: [
        if (!_admin)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'Seul un administrateur peut modifier ces réglages.',
              style: T.body.copyWith(color: T.warnDark),
            ),
          ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Nouveau ticket',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('Client par défaut'),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: Text(
                        _customer?.name ?? 'Client de passage',
                        style: T.body.copyWith(
                          color: _customer == null ? T.muted : T.ink,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (_admin) ...[
                    PageAction(
                      label: 'Choisir',
                      icon: Icons.person_search_outlined,
                      onPressed: _pickCustomer,
                    ),
                    if (_customerId != null)
                      PageAction(
                        label: 'Client de passage',
                        onPressed: () => setState(() {
                          _customer = null;
                          _customerId = null;
                        }),
                      ),
                  ],
                ],
              ),
              _help(
                'Chaque nouveau ticket commence avec ce client (ex. « Comptoir »). '
                'Sans client par défaut, le ticket est au nom de « Client de passage ». '
                'Le caissier peut toujours en choisir un autre (F6).',
              ),
              const SizedBox(height: 16),
              _label('Dépôt de la caisse'),
              SizedBox(
                width: 360,
                child: DropdownButtonFormField<String?>(
                  initialValue: _warehouseId,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Dépôt par défaut du magasin'),
                    ),
                    for (final w in _warehouses)
                      DropdownMenuItem<String?>(
                        value: w.id,
                        child: Text(w.name),
                      ),
                  ],
                  onChanged: _admin
                      ? (v) => setState(() => _warehouseId = v)
                      : null,
                ),
              ),
              _help('Le stock vendu à la caisse sort de ce dépôt.'),
              const SizedBox(height: 16),
              _label('Demander le client au-delà de'),
              _amountField(_askAbove, error: _askError, hint: '0 = jamais'),
              _help(
                'Pour un ticket plus élevé, la caisse demande à quel client il appartient avant le paiement '
                '(le caissier peut continuer sans client). Laissez vide ou 0 pour ne jamais demander.',
              ),
            ],
          ),
        ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Moyens de paiement proposés',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Seuls les moyens cochés apparaissent sur l’écran de caisse.',
                style: T.bodyMuted,
              ),
              const SizedBox(height: 8),
              for (final (id, label, help) in _methods)
                if (id != 'loyalty' || loyalty)
                  CheckboxListTile(
                    value: _payments.contains(id),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: T.mintDark,
                    title: Text(
                      label,
                      style: T.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    subtitle: help.isEmpty ? null : Text(help, style: T.small),
                    onChanged: _admin
                        ? (v) => setState(() {
                            if (v == true) {
                              _payments.add(id);
                            } else {
                              _payments.remove(id);
                            }
                          })
                        : null,
                  ),
              if (!loyalty)
                _help(
                  '« Points fidélité » apparaît ici quand la fidélité est activée '
                  '(Paramètres › Clients et fidélité).',
                ),
              if (_paymentsError != null) FieldError(_paymentsError!),
            ],
          ),
        ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Espèces et tiroir',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('Fond de caisse proposé'),
              _amountField(_float, error: _floatError),
              _help(
                'Montant proposé à l’ouverture de la caisse (l’argent laissé dans le tiroir pour rendre la monnaie). '
                'Le caissier peut le corriger.',
              ),
              const SizedBox(height: 16),
              _label('Arrondi des espèces'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final step in const [0, 50, 100, 500])
                    ChoiceChip(
                      label: Text(cashRoundingLabel(step)),
                      selected: _rounding == step,
                      selectedColor: T.mintTint,
                      labelStyle: T.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: _rounding == step ? T.mintDark : T.ink,
                      ),
                      onSelected: _admin
                          ? (_) => setState(() => _rounding = step)
                          : null,
                    ),
                ],
              ),
              _help(
                _rounding == 0
                    ? 'Le client paie le montant exact, au centime près.'
                    : 'Quand le client paie en espèces, le montant à payer est arrondi au ${cashRoundingLabel(_rounding)} le plus proche '
                          '(ex. 123,45 DA → ${fmtDA(example + exD)}). La différence apparaît sur le ticket en ligne « Arrondi » : '
                          'le total du ticket est exactement l’argent reçu, les rapports restent justes. '
                          'Les paiements par carte ne sont jamais arrondis.',
              ),
              const SizedBox(height: 16),
              _switch(
                'Ouvrir le tiroir après une vente en espèces',
                'Le tiroir-caisse branché sur l’imprimante ticket s’ouvre tout seul quand le client paie en espèces.',
                _openDrawer,
                (v) => setState(() => _openDrawer = v),
              ),
            ],
          ),
        ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Ticket et scanner',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _switch(
                'Imprimer le ticket automatiquement',
                'Le ticket sort après chaque vente. Désactivé, la caisse propose « Imprimer le ticket » après la vente.',
                _autoPrint,
                (v) => setState(() => _autoPrint = v),
              ),
              _switch(
                'Bip au scan',
                'Un petit son confirme chaque code-barres scanné ajouté au ticket.',
                _beep,
                (v) => setState(() => _beep = v),
              ),
              _help(
                'L’imprimante ticket et le tiroir se règlent pour chaque poste dans Paramètres › Impression et matériel.',
              ),
            ],
          ),
        ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Clôture du jour',
          child: _switch(
            'Exiger le rapport Z chaque jour',
            'Si la caisse est restée ouverte depuis un jour précédent, aucune vente n’est possible avant sa clôture '
                '(rapport Z). Un caissier sans le droit « Clôturer la caisse » doit appeler un gérant.',
            _dailyZ,
            (v) => setState(() => _dailyZ = v),
          ),
        ),
        // ---------------------------------------------------------------
        PageSection(
          title: 'Touches rapides (favoris)',
          trailing: _admin && _quickKeys > 0
              ? PageAction(
                  label: 'Tout retirer',
                  danger: true,
                  onPressed: _clearQuickKeys,
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _quickKeys == 0
                    ? 'Aucun produit épinglé pour l’instant.'
                    : '$_quickKeys produit${_quickKeys > 1 ? 's' : ''} épinglé${_quickKeys > 1 ? 's' : ''}.',
                style: T.body,
              ),
              _help(
                'Dans la caisse, un administrateur fait un clic droit sur un produit pour l’épingler : '
                'les produits épinglés s’affichent en premier et sous le filtre « Favoris ».',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
