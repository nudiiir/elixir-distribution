import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/config.dart';
import '../../util/prefs.dart';
import 'audit_section.dart';
import 'backups_section.dart';
import 'cloud_section.dart';
import 'company_section.dart';
import 'customers_section.dart';
import 'documents_section.dart';
import 'hardware_section.dart';
import 'maintenance_section.dart';
import 'pos_section.dart';
import 'preferences_section.dart';
import 'products_stock_section.dart';
import 'profile_section.dart';
import 'roles_section.dart';
import 'taxes_section.dart';
import 'updates_section.dart';
import 'users_section.dart';
import 'warehouses_section.dart';

/// What every settings section receives.
class SettingsContext {
  const SettingsContext({required this.api, required this.session, required this.config});
  final ApiClient api;
  final Session session;
  final LocalConfig config;

  bool get isAdmin => session.user.isAdmin;
}

/// One entry of the Paramètres menu.
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.group,
    required this.title,
    required this.icon,
    required this.builder,
    this.keywords = '',
    this.adminOnly = false,
    this.subtitle = '',
  });
  final String id;
  final String group;
  final String title;
  final String subtitle;
  final IconData icon;
  final String keywords; // extra words the search box matches
  final bool adminOnly;
  final Widget Function(SettingsContext) builder;
}

final settingsEntries = <SettingsEntry>[
  // ---- Mon magasin
  SettingsEntry(
      id: 'company', group: 'Mon magasin', title: 'Entreprise', icon: Icons.storefront_outlined,
      subtitle: 'Nom, logo, NIF, coordonnées, mentions',
      keywords: 'raison sociale logo nif nis rc ai adresse téléphone email rib banque pied de page mentions',
      builder: (c) => CompanySection(ctx: c)),
  SettingsEntry(
      id: 'warehouses', group: 'Mon magasin', title: 'Dépôts', icon: Icons.warehouse_outlined,
      subtitle: 'Créer, renommer, dépôt par défaut',
      keywords: 'dépôt magasin entrepôt stockage', builder: (c) => WarehousesSection(ctx: c)),
  SettingsEntry(
      id: 'profile', group: 'Mon magasin', title: 'Profil du magasin', icon: Icons.tune_rounded,
      subtitle: 'Fonctions utilisées par votre commerce', adminOnly: true,
      keywords: 'modules fonctions lots péremption série imei poids variantes emballage demi-gros services boutique',
      builder: (c) => ProfileSection(ctx: c)),
  // ---- Utilisateurs
  SettingsEntry(
      id: 'users', group: 'Utilisateurs', title: 'Utilisateurs', icon: Icons.people_alt_outlined,
      subtitle: 'Comptes, mots de passe, code caisse', adminOnly: true,
      keywords: 'utilisateur compte mot de passe pin code caisse caissier vendeur dépôt connexion',
      builder: (c) => UsersSection(ctx: c)),
  SettingsEntry(
      id: 'roles', group: 'Utilisateurs', title: 'Rôles et permissions', icon: Icons.admin_panel_settings_outlined,
      subtitle: 'Qui peut faire quoi', adminOnly: true,
      keywords: 'rôle droits permissions accès remise crédit gérant code gérant approbation',
      builder: (c) => RolesSection(ctx: c)),
  // ---- Ventes et documents
  SettingsEntry(
      id: 'pos', group: 'Ventes et documents', title: 'Caisse', icon: Icons.point_of_sale_rounded,
      subtitle: 'Paiements, fond de caisse, ticket, arrondi',
      keywords: 'caisse ticket paiement espèces fond tiroir bip arrondi client z clôture',
      builder: (c) => PosSettingsSection(ctx: c)),
  SettingsEntry(
      id: 'documents', group: 'Ventes et documents', title: 'Documents et numérotation', icon: Icons.receipt_long_outlined,
      subtitle: 'Numéros, factures, devis, impression',
      keywords: 'numérotation numéro préfixe facture devis validité langue arabe papier a4 a5 colonnes montant en lettres',
      builder: (c) => DocumentsSection(ctx: c)),
  SettingsEntry(
      id: 'customers', group: 'Ventes et documents', title: 'Clients et fidélité', icon: Icons.loyalty_outlined,
      subtitle: 'Groupes de clients, crédit, points, cartes cadeaux',
      keywords: 'client groupe tarif remise crédit plafond fidélité points carte cadeau',
      builder: (c) => CustomersSection(ctx: c)),
  // ---- Produits
  SettingsEntry(
      id: 'products', group: 'Produits', title: 'Produits et stock', icon: Icons.inventory_2_outlined,
      subtitle: 'Prix, péremption, unités, marques, codes-barres',
      keywords: 'prix arrondi marge péremption stock minimum négatif unités marques code-barres étiquette',
      builder: (c) => ProductsStockSection(ctx: c)),
  SettingsEntry(
      id: 'taxes', group: 'Produits', title: 'Taxes', icon: Icons.percent_rounded,
      subtitle: 'Taux de TVA, timbre fiscal',
      keywords: 'tva taxe timbre fiscal taux', builder: (c) => TaxesSection(ctx: c)),
  // ---- Matériel et connexions
  SettingsEntry(
      id: 'hardware', group: 'Matériel et connexions', title: 'Impression et matériel', icon: Icons.print_outlined,
      subtitle: 'Imprimantes, tiroir-caisse, balance (ce poste)',
      keywords: 'imprimante ticket a4 étiquette tiroir balance test serveur adresse',
      builder: (c) => HardwareSection(ctx: c)),
  SettingsEntry(
      id: 'cloud', group: 'Matériel et connexions', title: 'Cloud et téléphone', icon: Icons.cloud_outlined,
      subtitle: 'Connexion du magasin, téléphones, boutique en ligne', adminOnly: true,
      keywords: 'cloud relais téléphone mobile appairage qr boutique en ligne',
      builder: (c) => CloudSection(ctx: c)),
  // ---- Données
  SettingsEntry(
      id: 'backups', group: 'Données', title: 'Sauvegardes', icon: Icons.backup_outlined,
      subtitle: 'Sauvegarder, restaurer', adminOnly: true,
      keywords: 'sauvegarde restauration restaurer backup', builder: (c) => BackupsSection(ctx: c)),
  SettingsEntry(
      id: 'audit', group: 'Données', title: 'Journal d’activité', icon: Icons.history_rounded,
      subtitle: 'Qui a fait quoi, quand', adminOnly: true,
      keywords: 'journal audit historique activité', builder: (c) => AuditSection(ctx: c)),
  SettingsEntry(
      id: 'maintenance', group: 'Données', title: 'Maintenance', icon: Icons.cleaning_services_outlined,
      subtitle: 'Exporter toutes les données, réinitialiser', adminOnly: true,
      keywords: 'maintenance réinitialiser effacer export données démonstration',
      builder: (c) => MaintenanceSection(ctx: c)),
  SettingsEntry(
      id: 'updates', group: 'Données', title: 'Mise à jour', icon: Icons.system_update_alt_rounded,
      subtitle: 'Version installée, rechercher une mise à jour',
      keywords: 'version mise à jour', builder: (c) => UpdatesSection(ctx: c)),
  // ---- Moi
  SettingsEntry(
      id: 'preferences', group: 'Moi', title: 'Mes préférences', icon: Icons.person_outline_rounded,
      subtitle: 'Taille du texte, page d’accueil, raccourcis',
      keywords: 'préférences texte taille police page accueil raccourcis clavier affichage',
      builder: (c) => PreferencesSection(ctx: c)),
];

/// Paramètres: a left menu of grouped sections with a search box, the
/// chosen section on the right.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, required this.session, required this.config});
  final ApiClient api;
  final Session session;
  final LocalConfig config;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  late String _current;

  SettingsContext get _ctx =>
      SettingsContext(api: widget.api, session: widget.session, config: widget.config);

  List<SettingsEntry> get _allowed => [
        for (final e in settingsEntries)
          if (!e.adminOnly || widget.session.user.isAdmin) e,
      ];

  @override
  void initState() {
    super.initState();
    final saved = UiPrefs.instance.get<String>('settings', 'section');
    _current = _allowed.any((e) => e.id == saved) ? saved! : _allowed.first.id;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String id) {
    setState(() => _current = id);
    UiPrefs.instance.set('settings', 'section', id);
  }

  bool _matches(SettingsEntry e, String q) {
    if (q.isEmpty) return true;
    final hay = '${e.title} ${e.subtitle} ${e.keywords} ${e.group}'.toLowerCase();
    return q.toLowerCase().split(RegExp(r'\s+')).every(hay.contains);
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim();
    final entries = [for (final e in _allowed) if (_matches(e, q)) e];
    final current = _allowed.firstWhere((e) => e.id == _current, orElse: () => _allowed.first);
    final groups = <String, List<SettingsEntry>>{};
    for (final e in entries) {
      groups.putIfAbsent(e.group, () => []).add(e);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: 290,
        decoration: const BoxDecoration(
          color: T.surface,
          border: BorderDirectional(end: BorderSide(color: T.border)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Text('Paramètres', style: T.h1),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: T.body,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Chercher un réglage…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: q.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Effacer',
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () => setState(_search.clear)),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                ),
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Aucun réglage ne correspond à « $q ».', style: T.bodyMuted),
                  )
                : ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                    for (final g in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                        child: Text(g.key, style: T.label),
                      ),
                      for (final e in g.value)
                        InkWell(
                          onTap: () => _open(e.id),
                          child: Container(
                            color: e.id == current.id ? T.mintTint : Colors.transparent,
                            padding: const EdgeInsets.fromLTRB(20, 9, 16, 9),
                            child: Row(children: [
                              Icon(e.icon, size: 19, color: e.id == current.id ? T.mintDeep : T.muted),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(e.title,
                                      style: T.body.copyWith(
                                          fontSize: 14,
                                          fontWeight: e.id == current.id ? FontWeight.w700 : FontWeight.w600)),
                                  if (e.subtitle.isNotEmpty)
                                    Text(e.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: T.small.copyWith(fontSize: 12.5)),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ]),
          ),
        ]),
      ),
      Expanded(
        child: KeyedSubtree(
          key: ValueKey(current.id),
          child: current.builder(_ctx),
        ),
      ),
    ]);
  }
}

/// Standard frame of a settings section: title, one-line explanation,
/// scrolling body, max width for readability.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.intro,
    this.actions = const [],
  });
  final String title;
  final String? intro;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: T.h1)),
              ...actions,
            ]),
            if (intro != null) ...[
              const SizedBox(height: 6),
              Text(intro!, style: T.bodyMuted),
            ],
            const SizedBox(height: 18),
            ...children,
          ]),
        ),
      ),
    );
  }
}
