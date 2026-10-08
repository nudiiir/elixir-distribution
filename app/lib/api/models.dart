class User {
  final String id;
  final String username;
  final String fullName;
  final String role;
  final bool active;
  final Map<String, bool> perms;

  /// Editable role (Paramètres › Rôles et permissions).
  final String roleId;
  final String roleName;

  /// max_discount_pct (×100), max_credit (centimes), approval_above
  /// (centimes) — 0 = no limit.
  final Map<String, int> limits;

  /// 'all' | 'own' (his own documents) | 'warehouse' (his depots).
  final String scope;
  final List<String> warehouseIds;
  final String? defaultWarehouseId;
  final bool hasPin;
  final String phone;
  final String email;
  final String? lastLoginAt;

  User.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        username = j['username'] as String,
        fullName = (j['full_name'] as String?) ?? '',
        role = j['role'] as String,
        active = j['active'] == true,
        perms = {
          for (final e in (j['perms'] as Map<String, dynamic>? ?? {}).entries)
            e.key: e.value == true
        },
        roleId = (j['role_id'] as String?) ?? '',
        roleName = (j['role_name'] as String?) ?? '',
        limits = {
          for (final e in (j['limits'] as Map<String, dynamic>? ?? {}).entries)
            e.key: (e.value as num?)?.toInt() ?? 0
        },
        scope = (j['scope'] as String?) ?? 'all',
        warehouseIds = [
          for (final e in (j['warehouse_ids'] as List? ?? const [])) e as String
        ],
        defaultWarehouseId = j['default_warehouse_id'] as String?,
        hasPin = j['has_pin'] == true,
        phone = (j['phone'] as String?) ?? '',
        email = (j['email'] as String?) ?? '',
        lastLoginAt = j['last_login_at'] as String?;

  /// Any permission key: module (`sales`), action (`sales.validate`) or
  /// special right (`discount`, `void_document`…).
  bool can(String perm) => perms[perm] == true;
  bool get isAdmin => role == 'admin';

  /// A limit of the role (0 = no limit).
  int limit(String name) => limits[name] ?? 0;

  String get displayName => fullName.isEmpty ? username : fullName;

  String get roleLabel => roleName.isNotEmpty
      ? roleName
      : switch (role) {
          'admin' => 'Administrateur',
          'manager' => 'Gérant',
          _ => 'Caissier',
        };
}

/// An editable role: permission set + limits + data scope.
class Role {
  final String id;
  final String name;
  final String description;
  final Map<String, bool> perms;
  final Map<String, int> limits;
  final String scope; // all | own | warehouse
  final bool isSystem;
  final int userCount;

  Role.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = (j['name'] as String?) ?? '',
        description = (j['description'] as String?) ?? '',
        perms = {
          for (final e in (j['perms'] as Map<String, dynamic>? ?? {}).entries)
            e.key: e.value == true
        },
        limits = {
          for (final e in (j['limits'] as Map<String, dynamic>? ?? {}).entries)
            e.key: (e.value as num?)?.toInt() ?? 0
        },
        scope = (j['scope'] as String?) ?? 'all',
        isSystem = j['is_system'] == true,
        userCount = (j['user_count'] as num?)?.toInt() ?? 0;
}

/// A user who can log in with a code caisse.
class PinUser {
  final String id;
  final String username;
  final String fullName;
  final String roleName;
  PinUser.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        username = (j['username'] as String?) ?? '',
        fullName = (j['full_name'] as String?) ?? '',
        roleName = (j['role_name'] as String?) ?? '';
  String get displayName => fullName.isEmpty ? username : fullName;
}

/// Answer of POST /auth/approve.
class Approval {
  final String token;
  final String approverId;
  final String approverName;
  final int expiresIn;
  Approval.fromJson(Map<String, dynamic> j)
      : token = j['approval_token'] as String,
        approverId = (j['approver_id'] as String?) ?? '',
        approverName = (j['approver_name'] as String?) ?? '',
        expiresIn = (j['expires_in'] as num?)?.toInt() ?? 120;
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
  final int imageRev; // 0 = pas de photo ; change à chaque nouvelle photo
  final String kind; // 'standard' | 'service' (un service ne bouge pas le stock)
  final int imageCount; // nombre de photos (galerie)

  bool get hasImage => imageRev > 0;
  bool get isService => kind == 'service';

  Product.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        imageRev = (j['image_rev'] as num?)?.toInt() ?? 0,
        imageCount = (j['image_count'] as num?)?.toInt() ??
            (((j['image_rev'] as num?)?.toInt() ?? 0) > 0 ? 1 : 0),
        kind = (j['kind'] as String?) ?? 'standard',
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
  // Contexte produit (écran Stock) — absent des anciens serveurs.
  final int? value; // valeur au coût calculée par le serveur (centimes)
  final String warehouseName;
  final String? categoryId;
  final String? categoryName;
  final String brand;
  final int priceRetail; // TTC
  final int minStockMilli;
  final String unit;
  final String? defaultSupplierId;
  final String? defaultSupplierName;
  final int imageRev;
  final String kind;

  StockLevel.fromJson(Map<String, dynamic> j)
      : productId = j['product_id'] as String,
        productName = j['product_name'] as String,
        barcode = j['barcode'] as String?,
        warehouseId = (j['warehouse_id'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        avgCost = (j['avg_cost'] as num?)?.toInt() ?? 0,
        value = (j['value'] as num?)?.toInt(),
        warehouseName = (j['warehouse_name'] as String?) ?? '',
        categoryId = j['category_id'] as String?,
        categoryName = j['category_name'] as String?,
        brand = (j['brand'] as String?) ?? '',
        priceRetail = (j['price_retail'] as num?)?.toInt() ?? 0,
        minStockMilli = (j['min_stock_milli'] as num?)?.toInt() ?? 0,
        unit = (j['unit'] as String?) ?? 'piece',
        defaultSupplierId = j['default_supplier_id'] as String?,
        defaultSupplierName = j['default_supplier_name'] as String?,
        imageRev = (j['image_rev'] as num?)?.toInt() ?? 0,
        kind = (j['kind'] as String?) ?? 'standard',
        vatRate = (j['vat_rate'] as num?)?.toInt() ?? 0;

  final int vatRate; // ×100

  int get valuation => value ?? (qtyMilli * avgCost) ~/ 1000;

  /// LA règle « stock faible » de toute l'application.
  bool get isRupture => qtyMilli <= 0;
  bool get isUnderMin => !isRupture && minStockMilli > 0 && qtyMilli < minStockMilli;
  bool get isLow => isRupture || isUnderMin;
}

class Warehouse {
  final String id;
  final String name;
  final bool isDefault;
  final String address;
  final String phone;

  Warehouse.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        isDefault = j['is_default'] == true,
        address = (j['address'] as String?) ?? '',
        phone = (j['phone'] as String?) ?? '';
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
  // Groupe de clients (Paramètres › Clients et fidélité). When set, the
  // group's price level and discount apply as soon as the customer is chosen.
  final String? groupId;
  final String? groupName;
  final String? groupPriceLevel; // retail | wholesale, null = no group
  final int groupDiscountPct; // ×100, 0 = none

  /// Price level to sell at: the group's when the customer has one.
  String get effectivePriceLevel => groupPriceLevel ?? priceLevel;

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
        active = j['active'] == true,
        groupId = j['group_id'] as String?,
        groupName = j['group_name'] as String?,
        groupPriceLevel = j['group_price_level'] as String?,
        groupDiscountPct = (j['group_discount_pct'] as num?)?.toInt() ?? 0;
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
  final String? destWarehouseId;
  final String? internalNotes; // jamais imprimée
  final int paid;
  final int remaining;
  final String paymentStatus; // paid | partial | due | ''
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
        destWarehouseId = j['dest_warehouse_id'] as String?,
        internalNotes = j['internal_notes'] as String?,
        paid = (j['paid'] as num?)?.toInt() ?? 0,
        remaining = (j['remaining'] as num?)?.toInt() ?? 0,
        paymentStatus = (j['payment_status'] as String?) ?? '',
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
  final String? notes;
  final int paid;
  final int remaining;
  final String paymentStatus; // paid | partial | due | ''

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
        supplierRef = j['supplier_ref'] as String?,
        notes = j['notes'] as String?,
        paid = (j['paid'] as num?)?.toInt() ?? 0,
        remaining = (j['remaining'] as num?)?.toInt() ?? 0,
        paymentStatus = (j['payment_status'] as String?) ?? '';
}

/// Pièce jointe d'un document (les octets se téléchargent à part).
class DocAttachment {
  final String id;
  final String documentId;
  final String name;
  final String mime;
  final int size;
  final String createdAt;

  DocAttachment.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        documentId = (j['document_id'] as String?) ?? '',
        name = (j['name'] as String?) ?? '',
        mime = (j['mime'] as String?) ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0,
        createdAt = (j['created_at'] as String?) ?? '';
}

/// Une facture encore ouverte (FIFO sur le compte partenaire).
class OpenItem {
  final String documentId;
  final String number;
  final String docDate;
  final String dueDate;
  final int total;
  final int outstanding;
  final int ageDays;
  final bool overdue;

  OpenItem.fromJson(Map<String, dynamic> j)
      : documentId = (j['document_id'] as String?) ?? '',
        number = (j['number'] as String?) ?? '',
        docDate = (j['doc_date'] as String?) ?? '',
        dueDate = (j['due_date'] as String?) ?? '',
        total = (j['total'] as num?)?.toInt() ?? 0,
        outstanding = (j['outstanding'] as num?)?.toInt() ?? 0,
        ageDays = (j['age_days'] as num?)?.toInt() ?? 0,
        overdue = j['overdue'] == true;
}

class PartnerOpenItems {
  final List<OpenItem> items;
  final int totalOpen;
  final int unallocatedCredit;

  PartnerOpenItems.fromJson(Map<String, dynamic> j)
      : items = [
          for (final e in (j['open_items'] as List? ?? const []))
            OpenItem.fromJson(e as Map<String, dynamic>)
        ],
        totalOpen = (j['total_open'] as num?)?.toInt() ?? 0,
        unallocatedCredit = (j['unallocated_credit'] as num?)?.toInt() ?? 0;
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
  final int otherSales; // chèque, virement, carte cadeau
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
        otherSales = (j['other_sales'] as num?)?.toInt() ?? 0,
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
  final String id;
  final String? userId;
  final String username;
  final String fullName;
  final String action;
  final String entity;
  final String? entityId;
  final String? detail;
  final String createdAt;

  AuditEntry.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        userId = j['user_id'] as String?,
        username = (j['username'] as String?) ?? '',
        fullName = (j['full_name'] as String?) ?? '',
        action = (j['action'] as String?) ?? '',
        entity = (j['entity'] as String?) ?? '',
        entityId = j['entity_id'] as String?,
        detail = j['detail'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';
}

/// What the last startup restore did (or why it failed).
class LastRestore {
  final String backup;
  final String before;
  final String at;
  final String error;

  LastRestore.fromJson(Map<String, dynamic> j)
      : backup = (j['backup'] as String?) ?? '',
        before = (j['before'] as String?) ?? '',
        at = (j['at'] as String?) ?? '',
        error = (j['error'] as String?) ?? '';
}

/// GET /backups: the copies, where they live, the pending restore.
class BackupsStatus {
  final String dir;
  final List<BackupInfo> items;
  final String pendingRestore; // '' = none
  final LastRestore? lastRestore;

  BackupsStatus.fromJson(Map<String, dynamic> j)
      : dir = (j['dir'] as String?) ?? '',
        items = [
          for (final e in (j['items'] as List? ?? const []))
            BackupInfo.fromJson(e as Map<String, dynamic>)
        ],
        pendingRestore = (j['pending_restore'] as String?) ?? '',
        lastRestore = j['last_restore'] is Map<String, dynamic>
            ? LastRestore.fromJson(j['last_restore'] as Map<String, dynamic>)
            : null;
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

  /// auto (daily / manual) | before_restore | before_reset
  final String kind;

  BackupInfo.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String,
        sizeBytes = (j['size_bytes'] as num?)?.toInt() ?? 0,
        modTime = (j['mod_time'] as String?) ?? '',
        kind = (j['kind'] as String?) ?? 'auto';
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
        unitCost = (j['unit_cost'] as num?)?.toInt() ?? 0,
        warehouseId = (j['warehouse_id'] as String?) ?? '',
        balanceAfter = (j['balance_after'] as num?)?.toInt(),
        reason = j['reason'] as String?;
  final String date;
  final String docType;
  final String? docNumber;
  final String docId;
  final String warehouse;
  final int qtyMilli;
  final int unitCost;
  final String warehouseId;

  /// Stock du dépôt juste après ce mouvement (solde courant).
  final int? balanceAfter;
  final String? reason; // motif d'un ajustement
}

/// Un jour du graphe « Ventes 30 jours ».
class SalesDay {
  SalesDay.fromJson(Map<String, dynamic> j)
      : date = (j['date'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0;
  final String date;
  final int qtyMilli;
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
        ],
        sales30d = [
          for (final e in (j['sales_30d'] as List? ?? const []))
            SalesDay.fromJson(e as Map<String, dynamic>)
        ],
        avgDailySalesMilli =
            (j['avg_daily_sales_milli'] as num?)?.toInt() ?? 0,
        coverageDays = (j['coverage_days'] as num?)?.toInt();

  final Product product;
  final List<FicheLevel> levels;
  final List<FicheLot> lots;
  final List<FicheMove> moves;
  final List<FicheSupplier> suppliers;
  final List<FicheVariant> variants;
  final List<SalesDay> sales30d;
  final int avgDailySalesMilli;

  /// Stock ÷ ventes moyennes par jour ; null sans ventes.
  final int? coverageDays;

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

/// One row of a mixed payment at the till (POS « Paiement mixte »).
class PosPayment {
  const PosPayment(this.method, this.amount);
  final String method; // cash | cib | edahabia | cheque | transfer | credit | gift
  final int amount; // centimes

  PosPayment.fromJson(Map<String, dynamic> j)
      : method = j['method'] as String,
        amount = (j['amount'] as num?)?.toInt() ?? 0;

  Map<String, dynamic> toJson() => {'method': method, 'amount': amount};
}

/// A ticket of the open caisse session (POS « Derniers tickets »).
class PosRecentTicket {
  final String id;
  final String? number;
  final String? postedAt;
  final int totalTTC;
  final String? paymentMethod;
  final String? partnerId;
  final String? partnerName;
  final String status;
  final List<PosPayment> payments;

  PosRecentTicket.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = j['number'] as String?,
        postedAt = j['posted_at'] as String?,
        totalTTC = (j['total_ttc'] as num?)?.toInt() ?? 0,
        paymentMethod = j['payment_method'] as String?,
        partnerId = j['partner_id'] as String?,
        partnerName = j['partner_name'] as String?,
        status = (j['status'] as String?) ?? 'posted',
        payments = [
          for (final e in (j['payments'] as List? ?? const []))
            PosPayment.fromJson(e as Map<String, dynamic>)
        ];
}
