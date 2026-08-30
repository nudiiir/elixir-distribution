class User {
  final String id;
  final String username;
  final String fullName;
  final String role;
  final bool active;
  final Map<String, bool> perms;

  User.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        username = j['username'] as String,
        fullName = (j['full_name'] as String?) ?? '',
        role = j['role'] as String,
        active = j['active'] == true,
        perms = {
          for (final e in (j['perms'] as Map<String, dynamic>? ?? {}).entries)
            e.key: e.value == true
        };

  bool can(String perm) => perms[perm] == true;
  bool get isAdmin => role == 'admin';

  String get roleLabel => switch (role) {
        'admin' => 'Administrateur',
        'manager' => 'Gérant',
        _ => 'Caissier',
      };
}

class Session {
  Session(this.token, this.user);
  final String token;
  final User user;
}

class Product {
  final String id;
  final String? barcode;
  final String name;
  final String? nameAr;
  final String unit;
  final bool isWeighable;
  final int vatRate; // percent * 100
  final int purchasePrice; // centimes HT
  final int priceRetail; // centimes TTC
  final int minStockMilli;
  final bool active;
  final int? promoPrice; // centimes TTC, active between promoStart/promoEnd
  final String? promoStart; // YYYY-MM-DD inclusive
  final String? promoEnd; // YYYY-MM-DD inclusive
  final String? parentProductId;
  final String? variantLabel;
  final int warrantyMonths; // 0 = sold without warranty
  final List<String> barcodes; // additional barcodes

  Product.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        barcode = j['barcode'] as String?,
        name = j['name'] as String,
        nameAr = j['name_ar'] as String?,
        unit = (j['unit'] as String?) ?? 'piece',
        isWeighable = j['is_weighable'] == true,
        vatRate = (j['vat_rate'] as num?)?.toInt() ?? 0,
        purchasePrice = (j['purchase_price'] as num?)?.toInt() ?? 0,
        priceRetail = (j['price_retail'] as num?)?.toInt() ?? 0,
        minStockMilli = (j['min_stock_milli'] as num?)?.toInt() ?? 0,
        active = j['active'] == true,
        promoPrice = (j['promo_price'] as num?)?.toInt(),
        promoStart = j['promo_start'] as String?,
        promoEnd = j['promo_end'] as String?,
        parentProductId = j['parent_product_id'] as String?,
        variantLabel = j['variant_label'] as String?,
        warrantyMonths = (j['warranty_months'] as num?)?.toInt() ?? 0,
        barcodes = [
          for (final b in (j['barcodes'] as List? ?? const [])) b.toString()
        ];

  /// Is the promotion running today?
  bool get promoActive {
    if (promoPrice == null || promoPrice! <= 0) return false;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (promoStart != null && promoStart!.isNotEmpty && today.compareTo(promoStart!) < 0) {
      return false;
    }
    if (promoEnd != null && promoEnd!.isNotEmpty && today.compareTo(promoEnd!) > 0) {
      return false;
    }
    return true;
  }

  /// What the customer pays today (TTC centimes).
  int get effectivePriceTTC => promoActive ? promoPrice! : priceRetail;

  /// Unit price HT in centimes, derived from today's effective TTC price.
  int get unitPriceHT =>
      ((effectivePriceTTC * 10000) + (10000 + vatRate) ~/ 2) ~/
      (10000 + vatRate);

  bool matchesBarcode(String code) =>
      barcode == code || barcodes.contains(code);
}

class StockLevel {
  final String productId;
  final String productName;
  final String? barcode;
  final String warehouseId;
  final int qtyMilli;
  final int avgCost; // centimes

  StockLevel.fromJson(Map<String, dynamic> j)
      : productId = j['product_id'] as String,
        productName = j['product_name'] as String,
        barcode = j['barcode'] as String?,
        warehouseId = j['warehouse_id'] as String,
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        avgCost = (j['avg_cost'] as num?)?.toInt() ?? 0;

  int get valuation => (qtyMilli * avgCost) ~/ 1000;
}

class Warehouse {
  final String id;
  final String name;
  final bool isDefault;

  Warehouse.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        isDefault = j['is_default'] == true;
}

class Partner {
  final String id;
  final String kind;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? nif;
  final String? nis;
  final String? rc;
  final String? ai;
  final int? creditLimit;
  final String? notes;
  final int balance; // positive = the partner owes us
  final bool active;

  Partner.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        kind = j['kind'] as String,
        name = j['name'] as String,
        phone = j['phone'] as String?,
        email = j['email'] as String?,
        address = j['address'] as String?,
        nif = j['nif'] as String?,
        nis = j['nis'] as String?,
        rc = j['rc'] as String?,
        ai = j['ai'] as String?,
        creditLimit = (j['credit_limit'] as num?)?.toInt(),
        notes = j['notes'] as String?,
        balance = (j['balance'] as num?)?.toInt() ?? 0,
        active = j['active'] == true;
}

class DocLine {
  final String? id;
  final String? productId;
  final String description;
  final int qtyMilli;
  final int unitPrice;
  final int discountPct;
  final int vatRate;
  final int lineHT;
  final int lineVAT;
  final int lineTTC;

  DocLine.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String?,
        productId = j['product_id'] as String?,
        description = (j['description'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        unitPrice = (j['unit_price'] as num?)?.toInt() ?? 0,
        discountPct = (j['discount_pct'] as num?)?.toInt() ?? 0,
        vatRate = (j['vat_rate'] as num?)?.toInt() ?? 0,
        lineHT = (j['line_ht'] as num?)?.toInt() ?? 0,
        lineVAT = (j['line_vat'] as num?)?.toInt() ?? 0,
        lineTTC = (j['line_ttc'] as num?)?.toInt() ?? 0;
}

class DocDetail {
  final String id;
  final String docType;
  final String? number;
  final String status;
  final String docDate;
  final String? partnerId;
  final String? warehouseId;
  final int totalHT;
  final int totalVAT;
  final int totalDiscount;
  final int timbre;
  final int totalTTC;
  final int amount;
  final String? paymentMethod;
  final String? notes;
  final List<DocLine> lines;

  DocDetail.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        docType = j['doc_type'] as String,
        number = j['number'] as String?,
        status = j['status'] as String,
        docDate = j['doc_date'] as String,
        partnerId = j['partner_id'] as String?,
        warehouseId = j['warehouse_id'] as String?,
        totalHT = (j['total_ht'] as num?)?.toInt() ?? 0,
        totalVAT = (j['total_vat'] as num?)?.toInt() ?? 0,
        totalDiscount = (j['total_discount'] as num?)?.toInt() ?? 0,
        timbre = (j['timbre'] as num?)?.toInt() ?? 0,
        totalTTC = (j['total_ttc'] as num?)?.toInt() ?? 0,
        amount = (j['amount'] as num?)?.toInt() ?? 0,
        paymentMethod = j['payment_method'] as String?,
        notes = j['notes'] as String?,
        lines = [
          for (final e in (j['lines'] as List? ?? const []))
            DocLine.fromJson(e)
        ];
}

class DocSummary {
  final String id;
  final String docType;
  final String? number;
  final String status;
  final String docDate;
  final String? partnerId;
  final int totalTTC;
  final int amount;
  final String? paymentMethod;
  final String createdAt;

  DocSummary.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        docType = j['doc_type'] as String,
        number = j['number'] as String?,
        status = j['status'] as String,
        docDate = j['doc_date'] as String,
        partnerId = j['partner_id'] as String?,
        totalTTC = (j['total_ttc'] as num?)?.toInt() ?? 0,
        amount = (j['amount'] as num?)?.toInt() ?? 0,
        paymentMethod = j['payment_method'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';
}

class CaisseSession {
  final String id;
  final String userId;
  final String userName;
  final String status;
  final String openedAt;
  final String? closedAt;
  final int openingCash;
  final int? expectedCash;
  final int? countedCash;
  final String? notes;

  CaisseSession.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        userId = j['user_id'] as String,
        userName = (j['user_name'] as String?) ?? '',
        status = j['status'] as String,
        openedAt = j['opened_at'] as String,
        closedAt = j['closed_at'] as String?,
        openingCash = (j['opening_cash'] as num?)?.toInt() ?? 0,
        expectedCash = (j['expected_cash'] as num?)?.toInt(),
        countedCash = (j['counted_cash'] as num?)?.toInt(),
        notes = j['notes'] as String?;
}

class CaisseReport {
  final int openingCash;
  final int ticketCount;
  final int totalSales;
  final int cashSales;
  final int cardSales;
  final int creditSales;
  final int cashIn;
  final int cashOut;
  final int expectedCash;

  CaisseReport.fromJson(Map<String, dynamic> j)
      : openingCash = (j['opening_cash'] as num?)?.toInt() ?? 0,
        ticketCount = (j['ticket_count'] as num?)?.toInt() ?? 0,
        totalSales = (j['total_sales'] as num?)?.toInt() ?? 0,
        cashSales = (j['cash_sales'] as num?)?.toInt() ?? 0,
        cardSales = (j['card_sales'] as num?)?.toInt() ?? 0,
        creditSales = (j['credit_sales'] as num?)?.toInt() ?? 0,
        cashIn = (j['cash_in'] as num?)?.toInt() ?? 0,
        cashOut = (j['cash_out'] as num?)?.toInt() ?? 0,
        expectedCash = (j['expected_cash'] as num?)?.toInt() ?? 0;
}

class BackupInfo {
  final String name;
  final int sizeBytes;
  final String modTime;

  BackupInfo.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String,
        sizeBytes = (j['size_bytes'] as num?)?.toInt() ?? 0,
        modTime = (j['mod_time'] as String?) ?? '';
}

class GiftCard {
  final String id;
  final String code;
  final int initialAmount;
  final int balance;
  final String status; // active | depleted | cancelled | expired
  final String? expiresAt;

  GiftCard.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        code = j['code'] as String,
        initialAmount = (j['initial_amount'] as num?)?.toInt() ?? 0,
        balance = (j['balance'] as num?)?.toInt() ?? 0,
        status = (j['status'] as String?) ?? 'active',
        expiresAt = j['expires_at'] as String?;

  bool get usable => status == 'active' && balance > 0;
}

class StockMovement {
  final String id;
  final String productName;
  final int qtyMilli; // signed
  final String docType;
  final String? docNumber;
  final String createdAt;

  StockMovement.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        productName = j['product_name'] as String,
        qtyMilli = (j['qty_delta_milli'] as num?)?.toInt() ?? 0,
        docType = j['doc_type'] as String,
        docNumber = j['doc_number'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';
}

/// A printable document design stored on the server; body is the layout JSON
/// the designer edits and the renderer consumes.
class Template {
  final String id;
  final String kind; // label | invoice | warranty
  final String name;
  final String lang; // fr | ar
  final Map<String, dynamic> body;
  final bool isDefault;

  Template.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        kind = j['kind'] as String,
        name = j['name'] as String,
        lang = (j['lang'] as String?) ?? 'fr',
        body = (j['body'] as Map<String, dynamic>?) ?? {},
        isDefault = j['is_default'] == true;
}

/// A client app currently running against the server (heartbeat-based).
class PresenceEntry {
  final String device;
  final String username;
  final String fullName;
  final String screen;
  final String kind; // desktop | mobile
  final int secondsAgo;

  PresenceEntry.fromJson(Map<String, dynamic> j)
      : device = (j['device'] as String?) ?? '',
        username = (j['username'] as String?) ?? '',
        fullName = (j['full_name'] as String?) ?? '',
        screen = (j['screen'] as String?) ?? '',
        kind = (j['kind'] as String?) ?? 'desktop',
        secondsAgo = (j['seconds_ago'] as num?)?.toInt() ?? 0;

  String get who => fullName.isEmpty ? username : fullName;
}

class PostedDoc {
  final String id;
  final String? number;
  final int totalHT;
  final int totalVAT;
  final int timbre;
  final int totalTTC;

  PostedDoc.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = j['number'] as String?,
        totalHT = (j['total_ht'] as num?)?.toInt() ?? 0,
        totalVAT = (j['total_vat'] as num?)?.toInt() ?? 0,
        timbre = (j['timbre'] as num?)?.toInt() ?? 0,
        totalTTC = (j['total_ttc'] as num?)?.toInt() ?? 0;
}
