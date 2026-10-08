import '../../api/models.dart';
import '../../theme/tokens.dart';

class CartLine {
  CartLine(this.product) : qtyMilli = 1000;
  final Product product;
  int qtyMilli;
  int discountPct = 0; // percent * 100, typed at the till

  /// Remise of the customer's group (Paramètres › Clients et fidélité),
  /// applied to lines that carry no remise of their own. Set by the till.
  int groupDiscountPct = 0;

  /// Price typed at the till (TTC centimes, right `price_edit`), null = the
  /// product's price for the customer's tier.
  int? priceOverride;

  CartLine copy() => CartLine(product)
    ..qtyMilli = qtyMilli
    ..discountPct = discountPct
    ..groupDiscountPct = groupDiscountPct
    ..priceOverride = priceOverride;

  /// The remise actually applied: the line's own, else the group's.
  int get effectiveDiscountPct =>
      discountPct != 0 ? discountPct : groupDiscountPct;

  /// All money math depends on the customer's price tier, resolved at
  /// render/checkout time so picking the client later reprices the cart.
  int unitTTC(String level) => priceOverride ?? product.priceFor(level);
  int unitHT(String level) =>
      ((unitTTC(level) * 10000) + (10000 + product.vatRate) ~/ 2) ~/
      (10000 + product.vatRate);
  int lineHT(String level) {
    final gross = roundDiv(unitHT(level) * qtyMilli, 1000);
    return roundDiv(gross * (10000 - effectiveDiscountPct), 10000);
  }

  int lineVAT(String level) => roundDiv(lineHT(level) * product.vatRate, 10000);
  int lineTTC(String level) => lineHT(level) + lineVAT(level);
}
