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
  final String? categoryId;
  final String unit;
  final bool isWeighable;
  final int? priceWholesale; // centimes TTC, null = no wholesale tier
  final bool trackSerials;
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
  final String description; // fiche produit (lignes « Clé: Valeur » = specs web)
  final String brand;
  final bool trackLots; // n° de lot obligatoire à la réception
  final bool trackExpiry; // DLC obligatoire à la réception
  final String? defaultSupplierId; // fournisseur habituel
  final List<String> barcodes; // additional barcodes
  final List<BarcodeEntry> barcodesEx; // barcodes avec libellé
  final List<Packaging> packagings; // conditionnements (carton = 24)

  Product.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        barcode = j['barcode'] as String?,
        name = j['name'] as String,
        nameAr = j['name_ar'] as String?,
        categoryId = j['category_id'] as String?,
        unit = (j['unit'] as String?) ?? 'piece',
        isWeighable = j['is_weighable'] == true,
        priceWholesale = (j['price_wholesale'] as num?)?.toInt(),
        trackSerials = j['track_serials'] == true,
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
        description = (j['description'] as String?) ?? '',
        brand = (j['brand'] as String?) ?? '',
        trackLots = j['track_lots'] == true,
        trackExpiry = j['track_expiry'] == true,
        defaultSupplierId = j['default_supplier_id'] as String?,
        barcodes = [
          for (final b in (j['barcodes'] as List? ?? const [])) b.toString()
        ],
        barcodesEx = [
          for (final e in (j['barcodes_ex'] as List? ?? const []))
            BarcodeEntry.fromJson(e as Map<String, dynamic>)
        ],
        packagings = [
          for (final e in (j['packagings'] as List? ?? const []))
            Packaging.fromJson(e as Map<String, dynamic>)
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

  /// Price for a wholesale-tier customer (promo wins if lower).
  int priceFor(String priceLevel) {
    if (priceLevel == 'wholesale' &&
        priceWholesale != null &&
        priceWholesale! > 0) {
      return promoActive && promoPrice! < priceWholesale!
          ? promoPrice!
          : priceWholesale!;
    }
    return effectivePriceTTC;
  }

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
  final String priceLevel; // retail | wholesale
  final int minShelfDays; // durée de vie restante minimale exigée
  final int overReceiptPct; // tolérance de sur-réception, pct x100
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
        priceLevel = (j['price_level'] as String?) ?? 'retail',
        minShelfDays = (j['min_shelf_days'] as num?)?.toInt() ?? 0,
        overReceiptPct = (j['over_receipt_pct'] as num?)?.toInt() ?? 500,
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
  final int? unitCost;
  final int qtyFreeMilli;
  final String? lotNumber;
  final String? expiryDate;
  final int packFactorMilli;
  final int? newSalePrice;
  final int qtyReceivedMilli;
  final int qtyCancelledMilli;

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
        lineTTC = (j['line_ttc'] as num?)?.toInt() ?? 0,
        unitCost = (j['unit_cost'] as num?)?.toInt(),
        qtyFreeMilli = (j['qty_free_milli'] as num?)?.toInt() ?? 0,
        lotNumber = j['lot_number'] as String?,
        expiryDate = j['expiry_date'] as String?,
        packFactorMilli = (j['pack_factor_milli'] as num?)?.toInt() ?? 1000,
        newSalePrice = (j['new_sale_price'] as num?)?.toInt(),
        qtyReceivedMilli = (j['qty_received_milli'] as num?)?.toInt() ?? 0,
        qtyCancelledMilli = (j['qty_cancelled_milli'] as num?)?.toInt() ?? 0;
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
  final String? refDocumentId;
  final String? supplierRef;
  final String? dueDate;
  final int freightCost;
  final String? reason;
  final String? orderStatus;
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
        refDocumentId = j['ref_document_id'] as String?,
        supplierRef = j['supplier_ref'] as String?,
        dueDate = j['due_date'] as String?,
        freightCost = (j['freight_cost'] as num?)?.toInt() ?? 0,
        reason = j['reason'] as String?,
        orderStatus = j['order_status'] as String?,
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
  final String? orderStatus;
  final String? dueDate;
  final String? supplierRef;

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
        createdAt = (j['created_at'] as String?) ?? '',
        orderStatus = j['order_status'] as String?,
        dueDate = j['due_date'] as String?,
        supplierRef = j['supplier_ref'] as String?;
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
  final int cashRefunds;
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
        cashRefunds = (j['cash_refunds'] as num?)?.toInt() ?? 0,
        expectedCash = (j['expected_cash'] as num?)?.toInt() ?? 0;
}

class Category {
  final String id;
  final String name;
  final String? parentId;

  Category.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        parentId = j['parent_id'] as String?;
}

/// One physical serialized unit (IMEI / N° de série).
class ProductUnit {
  final String id;
  final String productId;
  final String productName;
  final String serial;
  final String status; // in_stock | sold | returned | repair | scrapped
  final bool isUsed;
  final String? saleDocNumber;
  final String? saleDate;
  final String? partnerName;
  final String? notes;

  ProductUnit.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        productId = j['product_id'] as String,
        productName = (j['product_name'] as String?) ?? '',
        serial = j['serial'] as String,
        status = (j['status'] as String?) ?? 'in_stock',
        isUsed = j['is_used'] == true,
        saleDocNumber = j['sale_doc_number'] as String?,
        saleDate = j['sale_date'] as String?,
        partnerName = j['partner_name'] as String?,
        notes = j['notes'] as String?;
}

class Repair {
  final String id;
  final String number;
  final String customerName;
  final String? customerPhone;
  final String device;
  final String? serial;
  final String fault;
  final int deposit;
  final int? quote;
  final String status;
  final String? notes;
  final String createdAt;

  Repair.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = (j['number'] as String?) ?? '',
        customerName = j['customer_name'] as String,
        customerPhone = j['customer_phone'] as String?,
        device = j['device'] as String,
        serial = j['serial'] as String?,
        fault = j['fault'] as String,
        deposit = (j['deposit'] as num?)?.toInt() ?? 0,
        quote = (j['quote'] as num?)?.toInt(),
        status = (j['status'] as String?) ?? 'received',
        notes = j['notes'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';
}

class InstallmentDue {
  final String id;
  final String dueDate;
  final int amount;
  final int paid;
  final String? paidAt;

  InstallmentDue.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        dueDate = j['due_date'] as String,
        amount = (j['amount'] as num?)?.toInt() ?? 0,
        paid = (j['paid'] as num?)?.toInt() ?? 0,
        paidAt = j['paid_at'] as String?;

  int get remaining => amount - paid;
  bool get settled => paid >= amount;
}

class InstallmentPlan {
  final String id;
  final String partnerId;
  final String partnerName;
  final String? docNumber;
  final int total;
  final int months;
  final String startDate;
  final List<InstallmentDue> dues;

  InstallmentPlan.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        partnerId = j['partner_id'] as String,
        partnerName = (j['partner_name'] as String?) ?? '',
        docNumber = j['doc_number'] as String?,
        total = (j['total'] as num?)?.toInt() ?? 0,
        months = (j['months'] as num?)?.toInt() ?? 0,
        startDate = (j['start_date'] as String?) ?? '',
        dues = [
          for (final d in (j['dues'] as List? ?? const []))
            InstallmentDue.fromJson(d)
        ];

  int get totalPaid => dues.fold(0, (s, d) => s + d.paid);
}

class Lot {
  final String id;
  final String productId;
  final String productName;
  final String lotNumber;
  final String? expiryDate;
  final int qtyMilli;

  Lot.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        productId = j['product_id'] as String,
        productName = (j['product_name'] as String?) ?? '',
        lotNumber = (j['lot_number'] as String?) ?? '',
        expiryDate = j['expiry_date'] as String?,
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0;

  /// Days until expiry (negative = expired).
  int? get daysLeft {
    final e = DateTime.tryParse(expiryDate ?? '');
    if (e == null) return null;
    final now = DateTime.now();
    return e.difference(DateTime(now.year, now.month, now.day)).inDays;
  }
}

class AuditEntry {
  final String username;
  final String action;
  final String? detail;
  final String createdAt;

  AuditEntry.fromJson(Map<String, dynamic> j)
      : username = (j['username'] as String?) ?? '',
        action = (j['action'] as String?) ?? '',
        detail = j['detail'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';
}

class BreakdownRow {
  final String label;
  final int count;
  final int qtyMilli;
  final int totalHT;
  final int totalTTC;
  final int? margin;

  BreakdownRow.fromJson(Map<String, dynamic> j)
      : label = (j['label'] as String?) ?? '',
        count = (j['count'] as num?)?.toInt() ?? 0,
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        totalHT = (j['total_ht'] as num?)?.toInt() ?? 0,
        totalTTC = (j['total_ttc'] as num?)?.toInt() ?? 0,
        margin = (j['margin'] as num?)?.toInt();
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

/// Un code-barres supplémentaire avec son libellé descriptif optionnel.
class BarcodeEntry {
  BarcodeEntry({required this.code, this.label = ''});
  final String code;
  final String label;

  BarcodeEntry.fromJson(Map<String, dynamic> j)
      : code = (j['code'] as String?) ?? '',
        label = (j['label'] as String?) ?? '';

  Map<String, dynamic> toJson() => {'code': code, 'label': label};
}

/// Un conditionnement d'achat : carton = 24 pièces.
class Packaging {
  Packaging({this.id, required this.name, required this.factorMilli, this.barcode});
  final String? id;
  final String name;
  final int factorMilli; // unités de base par pack (milli)
  final String? barcode;

  Packaging.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String?,
        name = (j['name'] as String?) ?? '',
        factorMilli = (j['factor_milli'] as num?)?.toInt() ?? 1000,
        barcode = j['barcode'] as String?;

  Map<String, dynamic> toJson() =>
      {'name': name, 'factor_milli': factorMilli, 'barcode': barcode};
}

// ---------------- Fiche produit ----------------

class FicheLevel {
  FicheLevel.fromJson(Map<String, dynamic> j)
      : warehouseId = (j['warehouse_id'] as String?) ?? '',
        warehouse = (j['warehouse'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        avgCost = (j['avg_cost'] as num?)?.toInt() ?? 0;
  final String warehouseId;
  final String warehouse;
  final int qtyMilli;
  final int avgCost;
}

class FicheLot {
  FicheLot.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        lotNumber = (j['lot_number'] as String?) ?? '',
        expiryDate = j['expiry_date'] as String?,
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0;
  final String id;
  final String lotNumber;
  final String? expiryDate;
  final int qtyMilli;
}

class FicheMove {
  FicheMove.fromJson(Map<String, dynamic> j)
      : date = (j['date'] as String?) ?? '',
        docType = (j['doc_type'] as String?) ?? '',
        docNumber = j['doc_number'] as String?,
        docId = (j['doc_id'] as String?) ?? '',
        warehouse = (j['warehouse'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        unitCost = (j['unit_cost'] as num?)?.toInt() ?? 0;
  final String date;
  final String docType;
  final String? docNumber;
  final String docId;
  final String warehouse;
  final int qtyMilli;
  final int unitCost;
}

class FicheSupplier {
  FicheSupplier.fromJson(Map<String, dynamic> j)
      : partnerId = (j['partner_id'] as String?) ?? '',
        partner = (j['partner'] as String?) ?? '',
        unitCost = (j['unit_cost'] as num?)?.toInt() ?? 0,
        date = (j['date'] as String?) ?? '';
  final String partnerId;
  final String partner;
  final int unitCost;
  final String date;
}

class FicheVariant {
  FicheVariant.fromJson(Map<String, dynamic> j)
      : product = Product.fromJson(j),
        stockMilli = (j['stock_milli'] as num?)?.toInt() ?? 0;
  final Product product;
  final int stockMilli;
}

/// La fiche produit complète : rien ici n'est stocké, tout est recalculé.
class FicheData {
  FicheData.fromJson(Map<String, dynamic> j)
      : product = Product.fromJson(j['product'] as Map<String, dynamic>),
        levels = [
          for (final e in (j['levels'] as List? ?? const []))
            FicheLevel.fromJson(e as Map<String, dynamic>)
        ],
        lots = [
          for (final e in (j['lots'] as List? ?? const []))
            FicheLot.fromJson(e as Map<String, dynamic>)
        ],
        moves = [
          for (final e in (j['moves'] as List? ?? const []))
            FicheMove.fromJson(e as Map<String, dynamic>)
        ],
        suppliers = [
          for (final e in (j['suppliers'] as List? ?? const []))
            FicheSupplier.fromJson(e as Map<String, dynamic>)
        ],
        variants = [
          for (final e in (j['variants'] as List? ?? const []))
            FicheVariant.fromJson(e as Map<String, dynamic>)
        ];

  final Product product;
  final List<FicheLevel> levels;
  final List<FicheLot> lots;
  final List<FicheMove> moves;
  final List<FicheSupplier> suppliers;
  final List<FicheVariant> variants;

  int get stockTotal => levels.fold(0, (s, l) => s + l.qtyMilli);
  int get valeurStock =>
      levels.fold(0, (s, l) => s + (l.qtyMilli * l.avgCost) ~/ 1000);

  /// Achat pondéré — null quand le stock est nul (jamais zéro : une moyenne
  /// de rien n'est pas zéro dinar).
  int? get achatPondere =>
      stockTotal <= 0 ? null : (valeurStock * 1000) ~/ stockTotal;
}

/// Une exception de rapprochement (facture vs réception, réception vs BC).
class MatchExceptionRow {
  MatchExceptionRow.fromJson(Map<String, dynamic> j)
      : kind = (j['kind'] as String?) ?? '',
        product = (j['product'] as String?) ?? '',
        thisValue = (j['this_value'] as num?)?.toInt() ?? 0,
        refValue = (j['ref_value'] as num?)?.toInt() ?? 0,
        detail = (j['detail'] as String?) ?? '';
  final String kind;
  final String product;
  final int thisValue;
  final int refValue;
  final String detail;
}
