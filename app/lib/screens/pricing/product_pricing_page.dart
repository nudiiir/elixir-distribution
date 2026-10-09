import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_page.dart';
import '../orders/order_common.dart';
import 'pricing_screen.dart';

/// Opened from a product page: its special prices, offers and quotas, and
/// the customers waiting for it (reliquats).
Future<void> openProductPricing(BuildContext context, ApiClient api, Product p) {
  final user = api.user;
  if (user == null) return Future.value();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ProductPricingPage(api: api, user: user, productId: p.id, productName: p.name),
  ));
}

class ProductPricingPage extends StatefulWidget {
  const ProductPricingPage(
      {super.key, required this.api, required this.user, required this.productId, required this.productName});
  final ApiClient api;
  final User user;
  final String productId;
  final String productName;

  @override
  State<ProductPricingPage> createState() => _ProductPricingPageState();
}

class _ProductPricingPageState extends State<ProductPricingPage> {
  List<BackorderRow> _waiting = const [];

  @override
  void initState() {
    super.initState();
    if (widget.user.isAdmin || widget.user.can('orders')) {
      widget.api.waitingCustomers(widget.productId).then((w) {
        if (mounted) setState(() => _waiting = w);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _waiting.fold(0, (s, r) => s + r.qtyBackorderMilli);
    return AppPage(
      crumbs: [Crumb('Produits', () => Navigator.of(context).pop()), Crumb(widget.productName), const Crumb('Tarifs et offres')],
      title: widget.productName,
      scroll: false,
      maxWidth: 1280,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_waiting.isNotEmpty)
          InfoBanner(
            text: '${_waiting.length} client${_waiting.length > 1 ? 's' : ''} attend${_waiting.length > 1 ? 'ent' : ''} '
                'ce produit (${fmtQty(total)} en reliquat)',
            lines: [
              for (final r in _waiting.take(6))
                '${r.partnerName} — ${fmtQty(r.qtyBackorderMilli)} (commande ${r.orderNumber} du ${frDate(r.orderDate)})',
              if (_waiting.length > 6) '… et ${_waiting.length - 6} autres (voir Commandes clients › Reliquats)',
            ],
          ),
        Expanded(
          child: PricingScreen(
              api: widget.api, user: widget.user, product: (widget.productId, widget.productName)),
        ),
      ]),
    );
  }
}

/// Opened from a client page: the special prices of this client, its quotas
/// (and their consumption), and the offers it can get.
Future<void> openClientPricing(BuildContext context, ApiClient api, String partnerId, String partnerName) {
  final user = api.user;
  if (user == null) return Future.value();
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => AppPage(
      crumbs: [
        const Crumb('Clients'),
        Crumb(partnerName, () => Navigator.of(context).pop()),
        const Crumb('Prix spéciaux'),
      ],
      title: partnerName,
      scroll: false,
      maxWidth: 1280,
      body: PricingScreen(api: api, user: user, client: (partnerId, partnerName)),
    ),
  ));
}
