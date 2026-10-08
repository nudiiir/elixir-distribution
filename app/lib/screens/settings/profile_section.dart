import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// The shop's features, in plain words: (setting key, title, explanation).
const _featureTexts = <(String, String, String)>[
  ('feature_lots', 'Lots et dates de péremption',
      'Pour ce qui périme (alimentation, cosmétique, entretien) : numéro de lot et date de '
          'péremption saisis à la réception, alerte avant la péremption.'),
  ('feature_serials', 'Numéros de série / IMEI',
      'Pour les téléphones, l’électroménager… : chaque appareil garde son numéro, de l’achat à '
          'la vente (garantie, retour).'),
  ('feature_weighed', 'Produits au poids (balance)',
      'Vente au kilo et lecture à la caisse des étiquettes imprimées par la balance.'),
  ('feature_variants', 'Variantes (taille, couleur…)',
      'Un même article en plusieurs tailles ou couleurs, chacune avec son stock (vêtements, chaussures).'),
  ('feature_packagings', 'Emballage (carton, pack…)',
      'Acheter ou vendre par carton ou par pack : par exemple 1 carton = 24 pièces.'),
  ('feature_wholesale', 'Prix de gros',
      'Un deuxième prix de vente, pour les revendeurs et les clients qui achètent en quantité.'),
  ('feature_services', 'Services',
      'Main-d’œuvre, livraison, réparation… : vendus comme des produits mais sans stock.'),
  ('feature_webstore', 'Boutique en ligne',
      'Une vitrine sur Internet avec vos produits ; les commandes des clients arrivent ici.'),
];

/// Paramètres → Profil du magasin: switch off what the shop does not use
/// (hidden everywhere at once) + selling beyond the stock.
class ProfileSection extends StatefulWidget {
  const ProfileSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<ProfileSection> {
  final Map<String, bool> _flags = {};
  bool _allowNegative = false;
  Map<String, bool> _saved = {};
  bool _loading = true;
  bool _saving = false;

  ApiClient get _api => widget.ctx.api;
  bool get _admin => widget.ctx.isAdmin;

  bool get _dirty =>
      _saved.isNotEmpty &&
      (_flags.entries.any((e) => _saved[e.key] != e.value) || _saved['allow_negative_stock'] != _allowNegative);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _api.settings();
      if (!mounted) return;
      setState(() {
        for (final (k, _, _) in _featureTexts) {
          _flags[k] = (s[k] ?? '1') != '0';
        }
        _allowNegative = s['allow_negative_stock'] == '1';
        _saved = {..._flags, 'allow_negative_stock': _allowNegative};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        for (final (k, _, _) in _featureTexts) {
          _flags[k] = Features.instance.flag(k);
        }
        _saved = {..._flags, 'allow_negative_stock': _allowNegative};
        _loading = false;
      });
      showToast(context, 'Lecture des réglages impossible : $e', kind: ToastKind.error);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _api.saveSettings({
        for (final e in _flags.entries) e.key: e.value ? '1' : '0',
        'allow_negative_stock': _allowNegative ? '1' : '0',
      });
      await Features.instance.load(_api);
      if (!mounted) return;
      setState(() => _saved = {..._flags, 'allow_negative_stock': _allowNegative});
      showToast(context, 'Profil du magasin enregistré. Les menus et les écrans sont mis à jour.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPage(
          title: 'Profil du magasin', children: [Center(child: CircularProgressIndicator(color: T.mint))]);
    }
    return SettingsPage(
      title: 'Profil du magasin',
      intro: 'Désactivez ce que votre commerce n’utilise pas : les menus, colonnes et champs '
          'correspondants disparaissent pour tout le monde. Vous pouvez les réactiver à tout moment, '
          'rien n’est effacé.',
      actions: [
        if (_admin)
          PageAction(
            label: _saving ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _saving || !_dirty ? null : _save,
          ),
      ],
      children: [
        if (!_admin) const AdminOnlyNotice(),
        PageSection(
          title: 'Fonctions utilisées',
          child: Column(children: [
            for (final (k, title, text) in _featureTexts) ...[
              SwitchRow(
                title: title,
                explanation: text,
                value: _flags[k] ?? true,
                onChanged: _admin ? (v) => setState(() => _flags[k] = v) : null,
              ),
              if (k != _featureTexts.last.$1) const Divider(height: 8),
            ],
          ]),
        ),
        PageSection(
          title: 'Stock',
          child: SwitchRow(
            title: 'Autoriser la vente en stock négatif',
            explanation: _allowNegative
                ? 'Activé : on peut vendre ou transférer plus que le stock affiché (le stock devient '
                    'négatif). Pratique si les achats ne sont pas toujours saisis à temps, mais le coût moyen '
                    'et les marges deviennent moins justes.'
                : 'Désactivé (recommandé) : une vente ou un transfert supérieur au stock disponible est '
                    'refusé. Le stock, le coût moyen et les marges restent exacts.',
            value: _allowNegative,
            onChanged: _admin ? (v) => setState(() => _allowNegative = v) : null,
          ),
        ),
        if (_dirty)
          const InfoBanner(
            kind: ToastKind.warning,
            icon: Icons.edit_note_rounded,
            text: 'Modifications non enregistrées — cliquez sur « Enregistrer » en haut de la page.',
          ),
      ],
    );
  }
}
