/// « Analyser » buttons of the modules: they open the Explorateur on a ready
/// analysis of the object in front of the user (this product, this customer,
/// this supplier, the stock…). The shell installs [AnalysisLinks.open]; the
/// modules only build the seed with the helpers below.
///
/// Specs are the explorer's FLAT JSON: source, dimensions, measures, filters,
/// range, sort, limit (see server/internal/analytics).
class AnalysisLinks {
  AnalysisLinks._();

  /// Installed by the shell: switches to the Explorateur with this seed.
  static void Function(Map<String, dynamic> spec, {String? title, String? origin})? open;

  static bool get available => open != null;

  static void launch(AnalysisSeed s) =>
      open?.call(s.spec, title: s.title, origin: s.origin);

  // ---- ready analyses ------------------------------------------------------

  static Map<String, dynamic> _range(String type, [int? n]) =>
      {'type': type, 'n': ?n};

  static Map<String, dynamic> _eq(String field, Object value) =>
      {'field': field, 'op': 'eq', 'value': value};

  /// Sales of one product, week by week over 6 months.
  static AnalysisSeed product(String productId, String name, {bool canCost = false}) =>
      AnalysisSeed(
        title: 'Ventes de $name',
        origin: 'Depuis la fiche produit',
        spec: {
          'source': 'sale_lines',
          'dimensions': ['doc_date:week'],
          'measures': [
            {'name': 'ca_ttc'},
            {'name': 'qty'},
            if (canCost) {'name': 'margin'},
          ],
          'filters': [_eq('product_id', productId)],
          'range': _range('last_n_months', 6),
          'limit': 500,
        },
      );

  /// Who buys this product (customers), last 6 months.
  static AnalysisSeed productCustomers(String productId, String name) => AnalysisSeed(
        title: 'Qui achète $name',
        origin: 'Depuis la fiche produit',
        spec: {
          'source': 'sale_lines',
          'dimensions': ['partner_name'],
          'measures': [
            {'name': 'qty'},
            {'name': 'ca_ttc'},
          ],
          'filters': [_eq('product_id', productId)],
          'range': _range('last_n_months', 6),
          'sort': [
            {'field': 'm0', 'dir': 'desc'}
          ],
          'limit': 50,
        },
      );

  /// One customer's purchases, month by month over a year.
  static AnalysisSeed customer(String partnerId, String name) => AnalysisSeed(
        title: 'Achats de $name',
        origin: 'Depuis la fiche client',
        spec: {
          'source': 'sale_lines',
          'dimensions': ['doc_date:month'],
          'measures': [
            {'name': 'ca_ttc'},
            {'name': 'sales_count'},
            {'name': 'avg_basket'},
          ],
          'filters': [_eq('partner_id', partnerId)],
          'range': _range('last_n_months', 12),
          'limit': 500,
        },
      );

  /// What a customer buys (products), last 12 months.
  static AnalysisSeed customerProducts(String partnerId, String name) => AnalysisSeed(
        title: 'Produits achetés par $name',
        origin: 'Depuis la fiche client',
        spec: {
          'source': 'sale_lines',
          'dimensions': ['product_name'],
          'measures': [
            {'name': 'qty'},
            {'name': 'ca_ttc'},
          ],
          'filters': [_eq('partner_id', partnerId)],
          'range': _range('last_n_months', 12),
          'sort': [
            {'field': 'm1', 'dir': 'desc'}
          ],
          'limit': 100,
        },
      );

  /// What we buy from a supplier, by product, last 12 months.
  static AnalysisSeed supplier(String partnerId, String name) => AnalysisSeed(
        title: 'Achats chez $name',
        origin: 'Depuis la fiche fournisseur',
        spec: {
          'source': 'purchase_lines',
          'dimensions': ['product_name'],
          'measures': [
            {'name': 'qty'},
            {'name': 'total_ht'},
            {'name': 'avg_unit_cost'},
          ],
          'filters': [_eq('supplier_id', partnerId)],
          'range': _range('last_n_months', 12),
          'sort': [
            {'field': 'm1', 'dir': 'desc'}
          ],
          'limit': 200,
        },
      );

  /// Sales of the period, day by day (Ventes list).
  static AnalysisSeed sales() => AnalysisSeed(
        title: 'Ventes par jour',
        origin: 'Depuis les ventes',
        spec: {
          'source': 'sale_lines',
          'dimensions': ['doc_date:day'],
          'measures': [
            {'name': 'ca_ttc'},
            {'name': 'sales_count'},
          ],
          'range': _range('this_month'),
          'limit': 500,
        },
      );

  /// Purchases by supplier (Achats list).
  static AnalysisSeed purchases() => AnalysisSeed(
        title: 'Achats par fournisseur',
        origin: 'Depuis les achats',
        spec: {
          'source': 'purchase_lines',
          'dimensions': ['supplier_name'],
          'measures': [
            {'name': 'total_ttc'},
            {'name': 'receipts_count'},
          ],
          'range': _range('last_n_months', 3),
          'sort': [
            {'field': 'm0', 'dir': 'desc'}
          ],
          'limit': 100,
        },
      );

  /// Stock value by category (Stock screen).
  static AnalysisSeed stock() => const AnalysisSeed(
        title: 'Valeur du stock par catégorie',
        origin: 'Depuis le stock',
        spec: {
          'source': 'stock_snapshot',
          'dimensions': ['category_name'],
          'measures': [
            {'name': 'stock_value'},
            {'name': 'retail_value'},
            {'name': 'references'},
          ],
          'range': {'type': 'all'},
          'sort': [
            {'field': 'm0', 'dir': 'desc'}
          ],
          'limit': 200,
        },
      );

  /// Stock movements of one product, week by week (stock ledger).
  static AnalysisSeed productMovements(String productId, String name) => AnalysisSeed(
        title: 'Entrées et sorties de $name',
        origin: 'Depuis le stock',
        spec: {
          'source': 'stock_movements',
          'dimensions': ['movement_date:week'],
          'measures': [
            {'name': 'qty_in'},
            {'name': 'qty_out'},
          ],
          'filters': [_eq('product_id', productId)],
          'range': _range('last_n_months', 6),
          'limit': 500,
        },
      );

  /// Customer balances (who owes us).
  static AnalysisSeed receivables() => const AnalysisSeed(
        title: 'Clients qui vous doivent',
        origin: 'Depuis les clients',
        spec: {
          'source': 'partner_ledger',
          'dimensions': ['partner_name'],
          'measures': [
            {'name': 'balance'}
          ],
          'filters': [
            {'field': 'partner_kind', 'op': 'in', 'value': ['customer', 'both']}
          ],
          'having': [
            {'measure': 'm0', 'op': 'gt', 'value': 0}
          ],
          'range': {'type': 'all'},
          'sort': [
            {'field': 'm0', 'dir': 'desc'}
          ],
          'limit': 100,
        },
      );
}

class AnalysisSeed {
  const AnalysisSeed({required this.title, required this.spec, this.origin});
  final String title;
  final String? origin;
  final Map<String, dynamic> spec;
}
