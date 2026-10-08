import 'dart:convert';
import 'dart:io';

import '../../api/models.dart';

/// A ticket put on hold (« Mettre en attente ») so the cashier can serve the
/// next customer. Kept on THIS machine only, in
/// %APPDATA%\ElixirGestion\parked_tickets.json: a parked cart is not shop
/// data yet — nothing is reserved, nothing is posted.
class ParkedTicket {
  ParkedTicket({
    required this.number,
    required this.parkedAt,
    required this.lines,
    this.client,
    this.paymentMethod = 'cash',
    this.cashier = '',
  });

  final int number;
  final DateTime parkedAt;
  final List<ParkedLine> lines;
  final Map<String, dynamic>? client; // Partner JSON (carries the price level)
  final String paymentMethod;
  final String cashier;

  Partner? get partner {
    final c = client;
    if (c == null) return null;
    try {
      return Partner.fromJson(c);
    } catch (_) {
      return null;
    }
  }

  int get itemCount => lines.fold(0, (s, l) => s + (l.qtyMilli / 1000).ceil());

  Map<String, dynamic> toJson() => {
    'number': number,
    'parked_at': parkedAt.toIso8601String(),
    'lines': [for (final l in lines) l.toJson()],
    'client': client,
    'payment_method': paymentMethod,
    'cashier': cashier,
  };

  static ParkedTicket? fromJson(Map<String, dynamic> j) {
    try {
      return ParkedTicket(
        number: (j['number'] as num).toInt(),
        parkedAt:
            DateTime.tryParse(j['parked_at'] as String? ?? '') ??
            DateTime.now(),
        lines: [
          for (final e in (j['lines'] as List? ?? const []))
            ?ParkedLine.fromJson(e as Map<String, dynamic>),
        ],
        client: j['client'] as Map<String, dynamic>?,
        paymentMethod: (j['payment_method'] as String?) ?? 'cash',
        cashier: (j['cashier'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

class ParkedLine {
  ParkedLine(
    this.product,
    this.qtyMilli,
    this.discountPct, {
    this.priceOverride,
  });
  final Product product;
  final int qtyMilli;
  final int discountPct;
  final int? priceOverride; // price typed at the till (TTC)

  Map<String, dynamic> toJson() => {
    'product': productToJson(product),
    'qty_milli': qtyMilli,
    'discount_pct': discountPct,
    if (priceOverride != null) 'price_override': priceOverride,
  };

  static ParkedLine? fromJson(Map<String, dynamic> j) {
    try {
      return ParkedLine(
        Product.fromJson(j['product'] as Map<String, dynamic>),
        (j['qty_milli'] as num).toInt(),
        (j['discount_pct'] as num?)?.toInt() ?? 0,
        priceOverride: (j['price_override'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The fields [Product.fromJson] reads — enough to rebuild the cart line
/// (price tiers, promo, VAT, weight/serial flags, photo).
Map<String, dynamic> productToJson(Product p) => {
  'id': p.id,
  'barcode': p.barcode,
  'name': p.name,
  'name_ar': p.nameAr,
  'category_id': p.categoryId,
  'unit': p.unit,
  'is_weighable': p.isWeighable,
  'price_wholesale': p.priceWholesale,
  'track_serials': p.trackSerials,
  'vat_rate': p.vatRate,
  'purchase_price': p.purchasePrice,
  'price_retail': p.priceRetail,
  'min_stock_milli': p.minStockMilli,
  'active': p.active,
  'promo_price': p.promoPrice,
  'promo_start': p.promoStart,
  'promo_end': p.promoEnd,
  'parent_product_id': p.parentProductId,
  'variant_label': p.variantLabel,
  'warranty_months': p.warrantyMonths,
  'brand': p.brand,
  'track_lots': p.trackLots,
  'track_expiry': p.trackExpiry,
  'barcodes': p.barcodes,
  'image_rev': p.imageRev,
  'kind': p.kind,
};

Map<String, dynamic> partnerToJson(Partner p) => {
  'id': p.id,
  'kind': p.kind,
  'name': p.name,
  'phone': p.phone,
  'credit_limit': p.creditLimit,
  'price_level': p.priceLevel,
  'balance': p.balance,
  'active': p.active,
  // customer group: price level + discount must survive « mettre en attente »
  'group_id': p.groupId,
  'group_name': p.groupName,
  'group_price_level': p.groupPriceLevel,
  'group_discount_pct': p.groupDiscountPct,
};

/// Load/save of the parked tickets file. Every call re-reads the file so two
/// POS windows on one PC never overwrite each other's list.
class ParkedTicketStore {
  ParkedTicketStore._();
  static final ParkedTicketStore instance = ParkedTicketStore._();

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\ElixirGestion\\parked_tickets.json');
  }

  Future<(int, List<ParkedTicket>)> _read() async {
    try {
      final f = _file();
      if (!await f.exists()) return (1, <ParkedTicket>[]);
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final items = [
        for (final e in (j['items'] as List? ?? const []))
          ?ParkedTicket.fromJson(e as Map<String, dynamic>),
      ];
      return ((j['next'] as num?)?.toInt() ?? 1, items);
    } catch (_) {
      return (1, <ParkedTicket>[]);
    }
  }

  Future<void> _write(int next, List<ParkedTicket> items) async {
    final f = _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode({
        'next': next,
        'items': [for (final t in items) t.toJson()],
      }),
    );
  }

  Future<List<ParkedTicket>> list() async => (await _read()).$2;

  /// Parks a cart; returns the ticket with its number.
  Future<ParkedTicket> park({
    required List<ParkedLine> lines,
    Partner? client,
    String paymentMethod = 'cash',
    String cashier = '',
  }) async {
    final (next, items) = await _read();
    // Numbers restart at 1 once the list is empty: « attente n° 1, 2… ».
    final number = items.isEmpty ? 1 : next;
    final t = ParkedTicket(
      number: number,
      parkedAt: DateTime.now(),
      lines: lines,
      client: client == null ? null : partnerToJson(client),
      paymentMethod: paymentMethod,
      cashier: cashier,
    );
    await _write(number + 1, [...items, t]);
    return t;
  }

  Future<void> remove(int number) async {
    final (next, items) = await _read();
    await _write(next, [
      for (final t in items)
        if (t.number != number) t,
    ]);
  }

  /// Puts back a ticket removed by mistake (undo).
  Future<void> restore(ParkedTicket t) async {
    final (next, items) = await _read();
    if (items.any((x) => x.number == t.number)) return;
    await _write(next, [...items, t]..sort((a, b) => a.number - b.number));
  }
}
