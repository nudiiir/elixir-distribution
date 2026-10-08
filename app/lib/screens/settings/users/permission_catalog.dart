import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../../util/feedback.dart';

/// One row of the permission grid.
class PermModule {
  const PermModule(this.key, this.label, this.actions);
  final String key;
  final String label;
  final List<String> actions; // subset of [permActions]
}

/// Grid columns, in order.
const permActions = <(String, String)>[
  ('view', 'Voir'),
  ('create', 'Créer'),
  ('edit', 'Modifier'),
  ('cancel', 'Annuler'),
  ('validate', 'Valider'),
  ('export', 'Exporter'),
  ('print', 'Imprimer'),
];

/// Same keys as the server (auth.go ModuleActions).
const permModules = <PermModule>[
  PermModule('pos', 'Caisse', ['view']),
  PermModule('sales', 'Ventes', ['view', 'create', 'edit', 'cancel', 'validate', 'export', 'print']),
  PermModule('purchases', 'Achats', ['view', 'create', 'edit', 'cancel', 'validate', 'export', 'print']),
  PermModule('stock', 'Stock', ['view', 'create', 'edit', 'cancel', 'validate', 'export', 'print']),
  PermModule('products', 'Produits', ['view', 'create', 'edit', 'export', 'print']),
  PermModule('partners', 'Clients et fournisseurs', ['view', 'create', 'edit', 'export', 'print']),
  PermModule('reports', 'Rapports', ['view', 'export', 'print']),
  PermModule('dashboard', 'Tableau de bord', ['view']),
  PermModule('assistant', 'Assistant', ['view']),
  PermModule('webstore', 'Boutique en ligne', ['view']),
  PermModule('settings', 'Paramètres', ['view']),
];

/// A special right with its plain sentence and, optionally, its limit.
class SpecialRight {
  const SpecialRight(this.key, this.title, this.sentence, {this.limitKey, this.limitLabel, this.limitUnit});
  final String key;
  final String title;
  final String sentence;
  final String? limitKey;
  final String? limitLabel;
  final String? limitUnit; // '%' or 'DA'
}

const specialRights = <SpecialRight>[
  SpecialRight('view_cost', 'Voir les coûts', 'Voit le prix d’achat, le coût moyen et les marges.'),
  SpecialRight('discount', 'Remises', 'Peut accorder une remise sur une vente.',
      limitKey: 'max_discount_pct', limitLabel: 'Remise maximale', limitUnit: '%'),
  SpecialRight('price_edit', 'Changer le prix', 'Peut changer le prix d’un article à la caisse.'),
  SpecialRight('credit_sale', 'Vente à crédit', 'Peut vendre à crédit à un client.',
      limitKey: 'max_credit', limitLabel: 'Crédit maximum par vente', limitUnit: 'DA'),
  SpecialRight('negative_stock', 'Vendre sans stock', 'Peut vendre plus que le stock disponible.'),
  SpecialRight('refund', 'Avoirs et retours', 'Peut faire un avoir ou reprendre un article.'),
  SpecialRight('void_document', 'Annuler un document validé',
      'Peut annuler une facture ou un ticket déjà validé (une trace est gardée).'),
  SpecialRight('change_date', 'Changer la date', 'Peut mettre une autre date que celle du jour sur un document.'),
  SpecialRight('open_drawer', 'Ouvrir le tiroir', 'Peut ouvrir le tiroir-caisse sans faire de vente.'),
  SpecialRight('close_till', 'Clôturer la caisse', 'Peut clôturer la caisse et imprimer le rapport Z.'),
  SpecialRight('view_today', 'Chiffre du jour', 'Voit le chiffre d’affaires et le bénéfice du jour.'),
  SpecialRight('stock_adjust', 'Ajuster le stock', 'Peut corriger le stock et faire un inventaire.'),
  SpecialRight('import_data', 'Importer', 'Peut importer des produits, clients ou fournisseurs.'),
  SpecialRight('export_data', 'Exporter', 'Peut exporter des listes et des données.'),
];

const scopeLabels = <String, String>{
  'all': 'Tout',
  'own': 'Seulement ses propres documents',
  'warehouse': 'Seulement son dépôt',
};

/// Label above a field, red « * » when required, helper and error under it.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
    this.helper,
    this.error,
  });
  final String label;
  final Widget child;
  final bool required;
  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(text: label, style: T.label, children: [
          if (required) const TextSpan(text: ' *', style: TextStyle(color: T.dangerDark)),
        ])),
        const SizedBox(height: 6),
        child,
        if (helper != null && (error == null || error!.isEmpty)) ...[
          const SizedBox(height: 4),
          Text(helper!, style: T.small),
        ],
        FieldError(error),
      ]),
    );
  }
}

InputDecoration fieldDecoration({String? hint, Widget? suffix, String? suffixText}) => InputDecoration(
      isDense: true,
      hintText: hint,
      suffixIcon: suffix,
      suffixText: suffixText,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
    );

/// « 12 oct. 2026 à 09:14 » from an ISO timestamp (local time).
String formatWhen(String? iso) {
  if (iso == null || iso.isEmpty) return 'Jamais';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]} ${d.year} à ${two(d.hour)}:${two(d.minute)}';
}
