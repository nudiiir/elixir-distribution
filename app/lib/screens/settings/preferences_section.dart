import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/shortcuts.dart';
import '../../util/user_prefs.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Modules offered as start page: (module key, label).
const _startModules = <(String, String)>[
  ('dashboard', 'Tableau de bord'),
  ('pos', 'Caisse'),
  ('sales', 'Ventes'),
  ('purchases', 'Achats'),
  ('products', 'Produits'),
  ('stock', 'Stock'),
  ('partners', 'Clients et fournisseurs'),
  ('reports', 'Rapports'),
  ('webstore', 'Boutique en ligne'),
  ('assistant', 'Assistant'),
];

/// Paramètres → Mes préférences (per user, on this PC). Applied at once.
class PreferencesSection extends StatefulWidget {
  const PreferencesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<PreferencesSection> createState() => _PreferencesSectionState();
}

class _PreferencesSectionState extends State<PreferencesSection> {
  final _prefs = UserPrefs.instance;
  late String _start = _prefs.startModule;
  late bool _compact = _prefs.compactLists;

  @override
  Widget build(BuildContext context) {
    final user = widget.ctx.session.user;
    final modules = [
      for (final m in _startModules)
        if (user.isAdmin || user.can(m.$1))
          if (m.$1 != 'webstore' || Features.instance.webstore) m,
    ];
    final name = user.fullName.isEmpty ? user.username : user.fullName;
    return SettingsPage(
      title: 'Mes préférences',
      intro: 'Vos réglages personnels ($name), sur ce poste. Ils s’appliquent tout de suite et '
          'ne changent rien pour les autres utilisateurs.',
      children: [
        PageSection(
          title: 'Taille du texte',
          child: ValueListenableBuilder<double>(
            valueListenable: _prefs.textScale,
            builder: (context, scale, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final (v, label) in UserPrefs.textScales)
                  ChoiceChip(
                    label: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text(label,
                          style: T.body.copyWith(
                              fontWeight: FontWeight.w700, color: scale == v ? T.mintDark : T.ink)),
                    ),
                    selected: scale == v,
                    showCheckmark: false,
                    selectedColor: T.mintTint,
                    backgroundColor: T.surface,
                    side: BorderSide(color: scale == v ? T.mintDeep : T.border3),
                    onSelected: (_) => _prefs.setTextScale(v),
                  ),
              ]),
              const SizedBox(height: 12),
              Text('Aperçu : Facture FA-2026-0042 — 3 articles — Total 12 450,00 DA', style: T.body),
              const SizedBox(height: 4),
              Text('« Grand » ou « Très grand » si vous lisez mal à distance de l’écran.', style: T.bodyMuted),
            ]),
          ),
        ),
        PageSection(
          title: 'Page d’accueil',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const FieldLabel('Écran ouvert après la connexion'),
            const SizedBox(height: 6),
            Container(
              height: 44,
              width: 360,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(T.rInner),
                border: Border.all(color: T.border3),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: modules.any((m) => m.$1 == _start) ? _start : '',
                  isExpanded: true,
                  style: T.body,
                  icon: const Icon(Icons.expand_more, size: 18, color: T.muted),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Par défaut')),
                    for (final (k, l) in modules) DropdownMenuItem(value: k, child: Text(l)),
                  ],
                  onChanged: (v) {
                    setState(() => _start = v ?? '');
                    _prefs.startModule = _start;
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text('Par exemple « Caisse » pour un poste de vente.', style: T.small),
          ]),
        ),
        PageSection(
          title: 'Listes',
          child: SwitchRow(
            title: 'Listes compactes',
            explanation: 'Des lignes plus serrées pour voir plus de lignes à l’écran. Chaque liste peut '
                'aussi être réglée à part (menu « Colonnes » de la liste).',
            value: _compact,
            onChanged: (v) {
              setState(() => _compact = v);
              _prefs.compactLists = v;
            },
          ),
        ),
        PageSection(
          title: 'Raccourcis clavier',
          child: Row(children: [
            Expanded(
              child: Text('Les touches qui font gagner du temps, à la caisse et dans les listes. '
                  'Tout reste aussi faisable à la souris.', style: T.bodyMuted),
            ),
            PageAction(
              label: 'Voir les raccourcis clavier',
              icon: Icons.keyboard_outlined,
              onPressed: () => showShortcutsSheet(context),
            ),
          ]),
        ),
      ],
    );
  }
}
