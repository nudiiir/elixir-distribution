import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import '../widgets/ui.dart';

/// One keyboard shortcut: the binding AND its line in the help sheet come
/// from the same object, so the sheet can never lie.
class AppShortcut {
  const AppShortcut(this.group, this.keys, this.label, this.activator);
  final String group; // « Partout », « Caisse », « Listes »…
  final String keys; // as printed: « Ctrl+K », « F9 »
  final String label;
  final ShortcutActivator? activator; // null = documented only (e.g. list keys)
}

/// Every shortcut of the app, grouped. Screens bind the ones of their group
/// with [bindingsFor]; the « Raccourcis clavier » sheet lists them all.
abstract final class AppShortcuts {
  // Partout
  static const search = AppShortcut('Partout', 'Ctrl+K', 'Recherche globale',
      SingleActivator(LogicalKeyboardKey.keyK, control: true));
  static const newDoc = AppShortcut('Partout', 'Ctrl+N', 'Nouveau (menu « + Nouveau »)',
      SingleActivator(LogicalKeyboardKey.keyN, control: true));
  static const pos = AppShortcut('Partout', 'F2', 'Ouvrir la caisse',
      SingleActivator(LogicalKeyboardKey.f2));
  static const help = AppShortcut('Partout', 'F1', 'Afficher les raccourcis',
      SingleActivator(LogicalKeyboardKey.f1));
  static const closeDialog =
      AppShortcut('Partout', 'Échap', 'Fermer la fenêtre ou le panneau', null);
  static const submit = AppShortcut('Partout', 'Ctrl+Entrée',
      'Enregistrer (formulaires)',
      SingleActivator(LogicalKeyboardKey.enter, control: true));
  static const saveAndNew = AppShortcut('Partout', 'Ctrl+Maj+Entrée',
      'Enregistrer et nouveau (fiche produit)',
      SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true));

  // Listes
  static const listMove = AppShortcut('Listes', '↑ ↓', 'Changer de ligne', null);
  static const listOpen = AppShortcut('Listes', 'Entrée', 'Ouvrir la ligne', null);
  static const listSelect =
      AppShortcut('Listes', 'Espace / Ctrl+A', 'Sélectionner / tout sélectionner', null);
  static const listClear = AppShortcut('Listes', 'Échap', 'Vider la sélection', null);
  static const panelNext = AppShortcut('Fiche produit', 'Alt+↓ / Alt+↑',
      'Produit suivant / précédent',
      SingleActivator(LogicalKeyboardKey.arrowDown, alt: true));

  // Caisse
  static const posSearch = AppShortcut('Caisse', 'F3', 'Aller à la recherche',
      SingleActivator(LogicalKeyboardKey.f3));
  static const posHold = AppShortcut('Caisse', 'F4', 'Mettre le ticket en attente',
      SingleActivator(LogicalKeyboardKey.f4));
  static const posParked = AppShortcut('Caisse', 'F5', 'Tickets en attente',
      SingleActivator(LogicalKeyboardKey.f5));
  static const posCustomer = AppShortcut('Caisse', 'F6', 'Choisir le client',
      SingleActivator(LogicalKeyboardKey.f6));
  static const posRecent = AppShortcut('Caisse', 'F7', 'Derniers tickets',
      SingleActivator(LogicalKeyboardKey.f7));
  static const posMixed = AppShortcut('Caisse', 'F8', 'Paiement mixte',
      SingleActivator(LogicalKeyboardKey.f8));
  static const posPay = AppShortcut('Caisse', 'F9', 'Encaisser',
      SingleActivator(LogicalKeyboardKey.f9));
  static const posPlus = AppShortcut('Caisse', '+ / −',
      'Quantité de la dernière ligne', null);
  static const posDelete = AppShortcut('Caisse', 'Suppr',
      'Retirer la dernière ligne', null);

  static const all = <AppShortcut>[
    search, newDoc, pos, help, closeDialog, submit, saveAndNew,
    listMove, listOpen, listSelect, listClear, panelNext,
    posSearch, posHold, posParked, posCustomer, posRecent, posMixed, posPay,
    posPlus, posDelete,
  ];
}

/// Builds the bindings map for [CallbackShortcuts].
Map<ShortcutActivator, VoidCallback> bindingsFor(
        Map<AppShortcut, VoidCallback> handlers) =>
    {
      for (final e in handlers.entries)
        if (e.key.activator != null) e.key.activator!: e.value,
    };

/// « Raccourcis clavier » sheet (F1 or the « ? » of the top bar).
Future<void> showShortcutsSheet(BuildContext context) {
  final groups = <String, List<AppShortcut>>{};
  for (final s in AppShortcuts.all) {
    groups.putIfAbsent(s.group, () => []).add(s);
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Raccourcis clavier', style: T.h2)),
              IconButton(
                tooltip: 'Fermer (Échap)',
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: [
                for (final g in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 6),
                    child: MicroLabel(g.key),
                  ),
                  for (final s in g.value)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(child: Text(s.label, style: T.body)),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: T.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: T.border),
                          ),
                          child: Text(s.keys,
                              style: T.monoBody.copyWith(fontSize: 12)),
                        ),
                      ]),
                    ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    ),
  );
}
