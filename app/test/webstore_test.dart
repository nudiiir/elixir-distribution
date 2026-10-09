import 'package:elixir_app/api/models.dart';
import 'package:elixir_app/screens/webstore/alerts_section.dart' show waNumber;
import 'package:elixir_app/screens/webstore/catalog_sync.dart';
import 'package:elixir_app/screens/webstore/pages_section.dart' show slugify;
import 'package:elixir_app/screens/webstore/web_common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('promo rules → storefront volume rules', () {
    final (rules, skipped) = mapPromoRulesToVolumeRules([
      {'id': 'a1', 'name': 'UG Amox', 'scope': 'product', 'product_id': 'P1',
        'type': 'free_goods', 'min_qty_milli': 10000, 'free_qty_milli': 1000,
        'start_date': '2026-10-01', 'end_date': '2026-12-31'},
      {'id': 'a2', 'name': 'Vol', 'scope': 'category', 'category_id': 'C1',
        'category_name': 'Antalgiques', 'type': 'qty_discount',
        'min_qty_milli': 20000, 'discount_pct': 750},
      {'id': 'a3', 'name': 'Demi', 'scope': 'all', 'type': 'free_goods',
        'min_qty_milli': 2500, 'free_qty_milli': 500},
      {'id': 'a4', 'name': 'Sans marque', 'scope': 'brand', 'brand': '',
        'type': 'qty_discount', 'min_qty_milli': 1000, 'discount_pct': 500},
    ]);
    expect(rules, hasLength(2));
    expect(rules[0], {
      'id': 'a1', 'scope': 'product', 'scope_value': 'P1', 'starts': '2026-10-01',
      'ends': '2026-12-31', 'type': 'free_goods', 'buy_qty': 10, 'free_qty': 1,
    });
    expect(rules[1]['scope_value'], 'Antalgiques');
    expect(rules[1]['percent'], 8); // 7,5 % rounded
    expect(rules[1]['min_qty'], 20);
    expect(skipped, hasLength(2));
  });

  test('links, colours, phone numbers, slugs', () {
    expect(checkLink(''), isNull);
    expect(checkLink('/l?promo=1'), isNull);
    expect(checkLink('https://exemple.dz'), isNull);
    expect(checkLink('tel:0550'), isNull);
    expect(checkLink('//evil.com'), isNotNull);
    expect(checkLink('javascript:alert(1)'), isNotNull);
    expect(checkLink('a b'), isNotNull);
    expect(isHexColor('#00A87C'), isTrue);
    expect(isHexColor('00A87C'), isFalse);
    expect(waNumber('0661 22 33 44'), '213661223344');
    expect(slugify('Conditions de vente'), 'conditions-de-vente');
    expect(slugify('À propos !'), 'a-propos');
  });

  test('catalogue snapshot carries brand, packs and wholesale price', () {
    final p = Product.fromJson({
      'id': 'P1', 'name': 'Doliprane', 'brand': 'Sanofi', 'price_retail': 25000,
      'price_wholesale': 18000, 'unit': 'piece', 'active': true,
      'packagings': [
        {'name': 'Palette', 'factor_milli': 480000},
        {'name': 'Carton', 'factor_milli': 24000},
      ],
    });
    final s = snapshotProduct(p, const {}, {'P1': 5000});
    expect(s['brand'], 'Sanofi');
    expect(s['pack_size'], 'Carton de 24');
    expect(s['packaging'], 'Carton de 24 · Palette de 480');
    expect(s['wholesale_price_centimes'], 18000);
    expect(s['qty_milli'], 5000);
  });
}
