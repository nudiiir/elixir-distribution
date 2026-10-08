import '../../api/models.dart';
import '../../theme/tokens.dart';

class CartLine {
  CartLine(this.product) : qtyMilli = 1000;
  final Product product;
  int qtyMilli;
  int discountPct = 0; // percent * 100

  CartLine copy() => CartLine(product)
    ..qtyMilli = qtyMilli
    ..discountPct = discountPct;

  /// All money math depends on the customer's price tier, resolved at
  /// render/checkout time so picking the client later reprices the cart.
  int unitTTC(String level) => product.priceFor(level);
  int unitHT(String level) =>
      ((unitTTC(level) * 10000) + (10000 + product.vatRate) ~/ 2) ~/
      (10000 + product.vatRate);
  int lineHT(String level) {
    final gross = roundDiv(unitHT(level) * qtyMilli, 1000);
    return roundDiv(gross * (10000 - discountPct), 10000);
  }

  int lineVAT(String level) => roundDiv(lineHT(level) * product.vatRate, 10000);
  int lineTTC(String level) => lineHT(level) + lineVAT(level);
}
