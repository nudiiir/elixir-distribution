import 'package:flutter/foundation.dart';

import '../api/client.dart';

/// « Profil du magasin » : the features this shop actually uses, plus the
/// shop-wide defaults the forms need. Stored as server settings (shared by
/// every PC of the shop), read once at start and after Paramètres saves.
///
/// A feature that is OFF is hidden everywhere — menu, columns, form fields —
/// so a grocery never sees IMEI fields and a phone shop never sees DLC.
class Features extends ChangeNotifier {
  Features._();
  static final Features instance = Features._();

  bool lots = true; // lots et dates de péremption
  bool serials = true; // n° de série / IMEI
  bool weighed = true; // produits au poids, balances 21/22
  bool variants = true; // déclinaisons (taille, couleur…)
  bool packagings = true; // conditionnements (carton = 24)
  bool webstore = true; // boutique en ligne
  bool repairs = true; // réparations / SAV
  bool wholesale = true; // tarif demi-gros
  bool services = true; // produits de type service

  int defaultVat = 1900; // percent × 100
  int targetMarginPct = 30; // marge cible pour le prix suggéré
  int paymentTermDays = 0; // échéance par défaut des factures à crédit

  static const keys = <String, String>{
    'feature_lots': 'Lots et dates de péremption',
    'feature_serials': 'N° de série / IMEI',
    'feature_weighed': 'Produits au poids (balance)',
    'feature_variants': 'Déclinaisons (taille, couleur…)',
    'feature_packagings': 'Conditionnements (carton, pack)',
    'feature_wholesale': 'Tarif demi-gros',
    'feature_services': 'Services (main-d’œuvre, livraison…)',
    'feature_webstore': 'Boutique en ligne',
    'feature_repairs': 'Réparations / SAV',
  };

  bool flag(String key) => switch (key) {
        'feature_lots' => lots,
        'feature_serials' => serials,
        'feature_weighed' => weighed,
        'feature_variants' => variants,
        'feature_packagings' => packagings,
        'feature_wholesale' => wholesale,
        'feature_services' => services,
        'feature_webstore' => webstore,
        'feature_repairs' => repairs,
        _ => true,
      };

  void apply(Map<String, String> s) {
    bool on(String k) => (s[k] ?? '1') != '0';
    lots = on('feature_lots');
    serials = on('feature_serials');
    weighed = on('feature_weighed');
    variants = on('feature_variants');
    packagings = on('feature_packagings');
    wholesale = on('feature_wholesale');
    services = on('feature_services');
    webstore = on('feature_webstore');
    repairs = on('feature_repairs');
    defaultVat = int.tryParse(s['default_vat'] ?? '') ?? 1900;
    targetMarginPct = int.tryParse(s['target_margin_pct'] ?? '') ?? 30;
    paymentTermDays = int.tryParse(s['payment_term_days'] ?? '') ?? 0;
    notifyListeners();
  }

  Future<void> load(ApiClient api) async {
    try {
      apply(await api.settings());
    } catch (_) {}
  }
}
