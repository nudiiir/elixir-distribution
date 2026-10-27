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

  bool lots = true; // lots and expiry dates
  bool serials = true; // serial no. / IMEI
  bool weighed = true; // sold-by-weight products, scales 21/22
  bool variants = true; // variants (size, colour…)
  bool packagings = true; // packagings (carton = 24)
  bool webstore = true; // online shop
  bool wholesale = true; // semi-wholesale price list
  bool services = true; // service-type products

  int defaultVat = 1900; // percent × 100
  int targetMarginPct = 30; // target margin for the suggested price
  int paymentTermDays = 0; // default due date for invoices on credit

  // ---- Taxes
  List<int> vatRates = const [1900, 900, 0]; // ×100, the choices offered everywhere
  bool timbreEnabled = true; // stamp duty on cash sales
  /// Optional name of each rate (`vat_labels` = "1900=Normal|900=Réduit").
  Map<int, String> vatLabels = const {};

  /// « 19 % » or « 19 % — Normal ».
  String vatLabel(int rate) {
    final p = rate % 100 == 0 ? '${rate ~/ 100}' : (rate / 100).toString().replaceAll('.', ',');
    final name = vatLabels[rate];
    return name == null || name.isEmpty ? '$p %' : '$p % — $name';
  }

  static Map<int, String> _labels(String? s) {
    if (s == null || s.trim().isEmpty) return const {};
    final out = <int, String>{};
    for (final part in s.split('|')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final r = int.tryParse(part.substring(0, i).trim());
      if (r != null) out[r] = part.substring(i + 1).trim();
    }
    return out;
  }

  // ---- Products and stock
  int priceRounding = 0; // centimes: 0 = none, 500 = 5 DA, 1000 = 10 DA (selling price)
  int expiryAlertDays = 90; // « périme bientôt » window
  int defaultMinStockMilli = 0; // default minimum stock of a new product
  List<String> units = const ['pièce', 'kg', 'litre', 'mètre', 'carton', 'paquet'];
  List<String> brands = const []; // managed brand list (free text still allowed)
  String barcodePrefix = '200'; // internal EAN-13 prefix

  // ---- Documents
  int quoteValidityDays = 15;

  // ---- Customers and loyalty
  int defaultCreditLimit = 0; // centimes, 0 = no ceiling
  bool loyaltyEnabled = false;
  int loyaltyEarnPer = 10000; // centimes spent for 1 point (100 DA)
  int loyaltyPointValue = 100; // centimes a point is worth when redeemed (1 DA)
  int loyaltyMinRedeem = 100; // points needed before redeeming
  int giftCardValidityDays = 365; // 0 = no expiry

  // ---- Till
  String? posDefaultCustomerId;
  String? posDefaultWarehouseId;
  List<String> posPaymentMethods = const ['cash', 'cib', 'edahabia', 'cheque', 'credit', 'gift'];
  int posDefaultFloat = 0; // centimes
  bool posAutoPrint = true;
  bool posOpenDrawer = true;
  bool posBeep = true;
  int posCashRounding = 0; // centimes: 0, 50, 100, 500
  int posAskCustomerAbove = 0; // centimes, 0 = never
  bool posRequireDailyZ = true; // a till opened on a previous day must be closed first

  static List<int> _ints(String? s, List<int> fallback) {
    if (s == null || s.trim().isEmpty) return fallback;
    final out = [for (final p in s.split(',')) int.tryParse(p.trim())].whereType<int>().toList();
    return out.isEmpty ? fallback : out;
  }

  static List<String> _strs(String? s, List<String> fallback) {
    if (s == null) return fallback;
    final out = [for (final p in s.split('|')) p.trim()].where((e) => e.isNotEmpty).toList();
    return out.isEmpty && s.trim().isEmpty ? fallback : out;
  }

  static const keys = <String, String>{
    'feature_lots': 'Lots et dates de péremption',
    'feature_serials': 'N° de série / IMEI',
    'feature_weighed': 'Produits au poids (balance)',
    'feature_variants': 'Déclinaisons (taille, couleur…)',
    'feature_packagings': 'Conditionnements (carton, pack)',
    'feature_wholesale': 'Tarif demi-gros',
    'feature_services': 'Services (main-d’œuvre, livraison…)',
    'feature_webstore': 'Boutique en ligne',
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
    defaultVat = int.tryParse(s['default_vat'] ?? '') ?? 1900;
    targetMarginPct = int.tryParse(s['target_margin_pct'] ?? '') ?? 30;
    paymentTermDays = int.tryParse(s['payment_term_days'] ?? '') ?? 0;
    int i(String k, int d) => int.tryParse(s[k] ?? '') ?? d;
    bool b(String k, bool d) => s[k] == null ? d : s[k] == '1';
    String? str(String k) => (s[k] ?? '').trim().isEmpty ? null : s[k]!.trim();
    vatRates = _ints(s['vat_rates'], const [1900, 900, 0]);
    timbreEnabled = b('timbre_enabled', true);
    vatLabels = _labels(s['vat_labels']);
    priceRounding = i('price_rounding', 0);
    expiryAlertDays = i('expiry_alert_days', 90);
    defaultMinStockMilli = i('default_min_stock_milli', 0);
    units = _strs(s['units'], const ['pièce', 'kg', 'litre', 'mètre', 'carton', 'paquet']);
    brands = _strs(s['brands'], const []);
    barcodePrefix = str('barcode_prefix') ?? '200';
    quoteValidityDays = i('quote_validity_days', 15);
    defaultCreditLimit = i('default_credit_limit', 0);
    loyaltyEnabled = b('loyalty_enabled', false);
    loyaltyEarnPer = i('loyalty_earn_per', 10000);
    loyaltyPointValue = i('loyalty_point_value', 100);
    loyaltyMinRedeem = i('loyalty_min_redeem', 100);
    giftCardValidityDays = i('gift_card_validity_days', 365);
    posDefaultCustomerId = str('pos_default_customer_id');
    posDefaultWarehouseId = str('pos_default_warehouse_id');
    posPaymentMethods = _strs(s['pos_payment_methods'],
        const ['cash', 'cib', 'edahabia', 'cheque', 'credit', 'gift']);
    posDefaultFloat = i('pos_default_float', 0);
    posAutoPrint = b('pos_auto_print', true);
    posOpenDrawer = b('pos_open_drawer', true);
    posBeep = b('pos_beep', true);
    posCashRounding = i('pos_cash_rounding', 0);
    posAskCustomerAbove = i('pos_ask_customer_above', 0);
    posRequireDailyZ = b('pos_require_daily_z', true);
    notifyListeners();
  }

  /// Applies the shop's selling-price rounding (centimes, rounded UP).
  int roundPrice(int centimes) {
    final r = priceRounding;
    if (r <= 0 || centimes <= 0) return centimes;
    return ((centimes + r - 1) ~/ r) * r;
  }

  Future<void> load(ApiClient api) async {
    try {
      apply(await api.settings());
    } catch (_) {}
  }
}
