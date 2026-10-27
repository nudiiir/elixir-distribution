/// Models of the Distribution module (docs/API_DISTRIBUTION.md):
/// customer orders, preparation, backorders, price lists, deliveries.
/// Parsing is tolerant: a missing key gives an empty value, never a crash.
library;

int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
int? _ni(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
double? _nd(Object? v) => v is num ? v.toDouble() : null;
String _s(Object? v) => v == null ? '' : '$v';
String? _ns(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

bool _b(Object? v) => v == true || v == 1 || v == '1';
List<Map<String, dynamic>> _list(Object? v) => [
      for (final e in (v as List? ?? const []))
        if (e is Map) Map<String, dynamic>.from(e)
    ];
List<String> _strs(Object? v) => [for (final e in (v as List? ?? const [])) '$e'];

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------

class CustomerOrder {
  CustomerOrder.fromJson(Map<String, dynamic> j)
      : raw = j,
        id = _s(j['id']),
        number = _s(j['number']),
        orderDate = _s(j['order_date']),
        partnerId = _s(j['partner_id']),
        partnerName = _s(j['partner_name']),
        partnerPhone = _s(j['partner_phone']),
        partnerClientType = _s(j['partner_client_type']),
        source = _s(j['source']).isEmpty ? 'manual' : _s(j['source']),
        externalRef = _ns(j['external_ref']),
        externalNumber = _ns(j['external_number']),
        status = _s(j['status']),
        statusLabel = _s(j['status_label']),
        isPartial = _b(j['is_partial']),
        hasBackorder = _b(j['has_backorder']),
        creditOverride = _b(j['credit_override']),
        webStatusDirty = _b(j['web_status_dirty']),
        warehouseId = _s(j['warehouse_id']),
        warehouseName = _s(j['warehouse_name']),
        repUserId = _ns(j['rep_user_id']),
        repName = _s(j['rep_name']),
        routeId = _ns(j['route_id']),
        routeName = _s(j['route_name']),
        priority = _i(j['priority']),
        paymentMode = _s(j['payment_mode']).isEmpty ? 'account' : _s(j['payment_mode']),
        requestedDate = _ns(j['requested_date']),
        deliveryAddress = _s(j['delivery_address']),
        wilaya = _s(j['wilaya']),
        commune = _s(j['commune']),
        contactName = _s(j['contact_name']),
        contactPhone = _s(j['contact_phone']),
        notes = _s(j['notes']),
        internalNotes = _s(j['internal_notes']),
        totalHT = _i(j['total_ht']),
        totalVAT = _i(j['total_vat']),
        totalDiscount = _i(j['total_discount']),
        shippingFee = _i(j['shipping_fee']),
        extraDiscount = _i(j['extra_discount']),
        totalTTC = _i(j['total_ttc']),
        promoCode = _s(j['promo_code']),
        cancelReason = _s(j['cancel_reason']),
        deliveryNoteId = _ns(j['delivery_note_id']),
        deliveryNoteNumber = _ns(j['delivery_note_number']),
        invoiceId = _ns(j['invoice_id']),
        invoiceNumber = _ns(j['invoice_number']),
        paymentId = _ns(j['payment_id']),
        paymentNumber = _ns(j['payment_number']),
        createdByName = _s(j['created_by_name']),
        validatedAt = _ns(j['validated_at']),
        deliveredAt = _ns(j['delivered_at']),
        createdAt = _s(j['created_at']),
        updatedAt = _s(j['updated_at']),
        linesCount = _i(j['lines_count']),
        lines = [for (final l in _list(j['lines'])) OrderLine.fromJson(l)],
        events = [for (final e in _list(j['events'])) OrderEvent.fromJson(e)],
        picks = [for (final p in _list(j['picks'])) OrderPick.fromJson(p)],
        allowedTransitions = _strs(j['allowed_transitions']);

  /// The whole JSON (extra keys of action answers: validation, document_id…).
  final Map<String, dynamic> raw;
  final String id;
  final String number;
  final String orderDate;
  final String partnerId;
  final String partnerName;
  final String partnerPhone;
  final String partnerClientType;
  final String source;
  final String? externalRef;
  final String? externalNumber;
  final String status;
  final String statusLabel;
  final bool isPartial;
  final bool hasBackorder;
  final bool creditOverride;
  final bool webStatusDirty;
  final String warehouseId;
  final String warehouseName;
  final String? repUserId;
  final String repName;
  final String? routeId;
  final String routeName;
  final int priority;
  final String paymentMode;
  final String? requestedDate;
  final String deliveryAddress;
  final String wilaya;
  final String commune;
  final String contactName;
  final String contactPhone;
  final String notes;
  final String internalNotes;
  final int totalHT;
  final int totalVAT;
  final int totalDiscount;
  final int shippingFee;
  final int extraDiscount;
  final int totalTTC;
  final String promoCode;
  final String cancelReason;
  final String? deliveryNoteId;
  final String? deliveryNoteNumber;
  final String? invoiceId;
  final String? invoiceNumber;
  final String? paymentId;
  final String? paymentNumber;
  final String createdByName;
  final String? validatedAt;
  final String? deliveredAt;
  final String createdAt;
  final String updatedAt;
  final int linesCount;
  final List<OrderLine> lines;
  final List<OrderEvent> events;
  final List<OrderPick> picks;
  final List<String> allowedTransitions;

  /// Lines still in the order (a substituted / moved line stays with 0).
  List<OrderLine> get activeLines => [
        for (final l in lines)
          if (l.qtyOrderedMilli > 0 || l.qtyValidatedMilli > 0 || l.qtyFreeMilli > 0) l
      ];

  bool can(String to) => allowedTransitions.contains(to);
}

class OrderLine {
  OrderLine.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        position = _i(j['position']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        barcode = _ns(j['barcode']),
        isService = _b(j['is_service']),
        trackLots = _b(j['track_lots']),
        qtyOrderedMilli = _i(j['qty_ordered_milli']),
        qtyValidatedMilli = _i(j['qty_validated_milli']),
        qtyPreparedMilli = _i(j['qty_prepared_milli']),
        qtyDeliveredMilli = _i(j['qty_delivered_milli']),
        qtyBackorderMilli = _i(j['qty_backorder_milli']),
        qtyFreeMilli = _i(j['qty_free_milli']),
        qtyToPrepareMilli = _i(j['qty_to_prepare_milli']),
        unitPrice = _i(j['unit_price']),
        discountPct = _i(j['discount_pct']),
        vatRate = _i(j['vat_rate']),
        lineHT = _i(j['line_ht']),
        lineVAT = _i(j['line_vat']),
        lineTTC = _i(j['line_ttc']),
        priceSource = _s(j['price_source']),
        promoRuleId = _ns(j['promo_rule_id']),
        substitutedFromLineId = _ns(j['substituted_from_line_id']),
        substitutedFromProductId = _ns(j['substituted_from_product_id']),
        backorderFromLineId = _ns(j['backorder_from_line_id']),
        notes = _s(j['notes']),
        stockMilli = _i(j['stock_milli']),
        availableMilli = _i(j['available_milli']);

  final String id;
  final int position;
  final String productId;
  final String productName;
  final String? barcode;
  final bool isService;
  final bool trackLots;
  final int qtyOrderedMilli;
  final int qtyValidatedMilli;
  final int qtyPreparedMilli;
  final int qtyDeliveredMilli;
  final int qtyBackorderMilli;
  final int qtyFreeMilli;
  final int qtyToPrepareMilli;
  final int unitPrice; // HT
  final int discountPct; // ×100
  final int vatRate; // ×100
  final int lineHT;
  final int lineVAT;
  final int lineTTC;
  final String priceSource;
  final String? promoRuleId;
  final String? substitutedFromLineId;
  final String? substitutedFromProductId;
  final String? backorderFromLineId;
  final String notes;
  final int stockMilli;
  final int availableMilli;

  bool get inactive => qtyOrderedMilli == 0 && qtyValidatedMilli == 0 && qtyFreeMilli == 0;
}

class OrderEvent {
  OrderEvent.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        action = _s(j['action']),
        fromStatus = _ns(j['from_status']),
        toStatus = _ns(j['to_status']),
        userName = _s(j['user_name']),
        note = _s(j['note']),
        createdAt = _s(j['created_at']);

  final String id;
  final String action;
  final String? fromStatus;
  final String? toStatus;
  final String userName;
  final String note;
  final String createdAt;
}

class OrderPick {
  OrderPick.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        lineId = _s(j['line_id']),
        productId = _s(j['product_id']),
        lotId = _ns(j['lot_id']),
        lotNumber = _ns(j['lot_number']),
        expiryDate = _ns(j['expiry_date']),
        qtyMilli = _i(j['qty_milli']),
        barcode = _s(j['barcode']),
        pickedByName = _s(j['picked_by_name']),
        createdAt = _s(j['created_at']);

  final String id;
  final String lineId;
  final String productId;
  final String? lotId;
  final String? lotNumber;
  final String? expiryDate;
  final int qtyMilli;
  final String barcode;
  final String pickedByName;
  final String createdAt;
}

/// GET /orders → items + counts per status + total.
class OrderPage {
  OrderPage.fromJson(Map<String, dynamic> j)
      : items = [for (final o in _list(j['items'])) CustomerOrder.fromJson(o)],
        counts = {
          for (final e in ((j['counts'] as Map?) ?? const {}).entries) '${e.key}': _i(e.value)
        },
        total = _i(j['total']);

  final List<CustomerOrder> items;
  final Map<String, int> counts;
  final int total;
}

/// The `validation` key of POST /orders/{id}/validate.
class ValidationInfo {
  ValidationInfo.fromJson(Map<String, dynamic> j)
      : warnings = _strs(j['warnings']),
        partial = _b(j['partial']),
        backorders = [
          for (final b in _list(j['backorders']))
            (
              lineId: _s(b['line_id']),
              productName: _s(b['product_name']),
              qtyMilli: _i(b['qty_backorder_milli']),
            )
        ];

  final List<String> warnings;
  final bool partial;
  final List<({String lineId, String productName, int qtyMilli})> backorders;
}

// ---------------------------------------------------------------------------
// Preparation
// ---------------------------------------------------------------------------

class LotSuggestion {
  LotSuggestion.fromJson(Map<String, dynamic> j)
      : lotId = _s(j['lot_id']),
        lotNumber = _s(j['lot_number']),
        expiryDate = _ns(j['expiry_date']),
        qtyAvailableMilli = _i(j['qty_available_milli']),
        qtySuggestedMilli = _i(j['qty_suggested_milli']);

  final String lotId;
  final String lotNumber;
  final String? expiryDate;
  final int qtyAvailableMilli;
  final int qtySuggestedMilli;
}

class PickingLine {
  PickingLine.fromJson(Map<String, dynamic> j)
      : lineId = _s(j['line_id']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        barcode = _ns(j['barcode']),
        categoryName = _s(j['category_name']),
        brand = _s(j['brand']),
        isService = _b(j['is_service']),
        trackLots = _b(j['track_lots']),
        qtyValidatedMilli = _i(j['qty_validated_milli']),
        qtyFreeMilli = _i(j['qty_free_milli']),
        qtyToPrepareMilli = _i(j['qty_to_prepare_milli']),
        qtyPreparedMilli = _i(j['qty_prepared_milli']),
        qtyRemainingMilli = _i(j['qty_remaining_milli']),
        stock = [
          for (final s in _list(j['stock']))
            (warehouseName: _s(s['warehouse_name']), qtyMilli: _i(s['qty_milli']))
        ],
        lots = [for (final l in _list(j['lot_suggestions'])) LotSuggestion.fromJson(l)],
        orders = [
          for (final o in _list(j['orders']))
            (
              orderNumber: _s(o['order_number']),
              partnerName: _s(o['partner_name']),
              qtyRemainingMilli: _i(o['qty_remaining_milli']),
            )
        ];

  final String lineId;
  final String productId;
  final String productName;
  final String? barcode;
  final String categoryName;
  final String brand;
  final bool isService;
  final bool trackLots;
  final int qtyValidatedMilli;
  final int qtyFreeMilli;
  final int qtyToPrepareMilli;
  final int qtyPreparedMilli;
  final int qtyRemainingMilli;
  final List<({String warehouseName, int qtyMilli})> stock;
  final List<LotSuggestion> lots;
  final List<({String orderNumber, String partnerName, int qtyRemainingMilli})> orders;
}

class PickingList {
  PickingList.fromJson(Map<String, dynamic> j)
      : order = j['order'] is Map
            ? CustomerOrder.fromJson(Map<String, dynamic>.from(j['order'] as Map))
            : null,
        lines = [for (final l in _list(j['lines'] ?? j['items'])) PickingLine.fromJson(l)],
        picks = [for (final p in _list(j['picks'])) OrderPick.fromJson(p)];

  final CustomerOrder? order;
  final List<PickingLine> lines;
  final List<OrderPick> picks;
}

class PickResult {
  PickResult.fromJson(Map<String, dynamic> j)
      : lineId = _s(j['line_id']),
        productName = _s(j['product_name']),
        qtyMilli = _i(j['qty_milli']),
        qtyPreparedMilli = _i(j['qty_prepared_milli']),
        qtyToPrepareMilli = _i(j['qty_to_prepare_milli']),
        lineComplete = _b(j['line_complete']),
        orderComplete = _b(j['order_complete']),
        lots = _strs(j['lots']);

  final String lineId;
  final String productName;
  final int qtyMilli;
  final int qtyPreparedMilli;
  final int qtyToPrepareMilli;
  final bool lineComplete;
  final bool orderComplete;
  final List<String> lots;
}

// ---------------------------------------------------------------------------
// Backorders
// ---------------------------------------------------------------------------

class BackorderRow {
  BackorderRow.fromJson(Map<String, dynamic> j)
      : lineId = _s(j['line_id']),
        orderId = _s(j['order_id']),
        orderNumber = _s(j['order_number']),
        orderStatus = _s(j['order_status']),
        orderDate = _s(j['order_date']),
        partnerId = _s(j['partner_id']),
        partnerName = _s(j['partner_name']),
        partnerPhone = _s(j['partner_phone']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        qtyBackorderMilli = _i(j['qty_backorder_milli']),
        unitPrice = _i(j['unit_price']),
        availableMilli = _i(j['available_milli']),
        fulfillableMilli = _i(j['fulfillable_milli']);

  final String lineId;
  final String orderId;
  final String orderNumber;
  final String orderStatus;
  final String orderDate;
  final String partnerId;
  final String partnerName;
  final String partnerPhone;
  final String productId;
  final String productName;
  final int qtyBackorderMilli;
  final int unitPrice;
  final int availableMilli;
  final int fulfillableMilli;
}

// ---------------------------------------------------------------------------
// Customer: credit
// ---------------------------------------------------------------------------

class PartnerCredit {
  PartnerCredit.fromJson(Map<String, dynamic> j)
      : balance = _i(j['balance']),
        creditLimit = _i(j['credit_limit']),
        openOrdersTotal = _i(j['open_orders_total']),
        openOrdersCount = _i(j['open_orders_count']),
        availableCredit = _ni(j['available_credit']),
        overdueAmount = _i(j['overdue_amount']),
        overdueCount = _i(j['overdue_count']),
        crmStatus = _s(j['crm_status']),
        paymentTermsDays = _ni(j['payment_terms_days']);

  final int balance;
  final int creditLimit;
  final int openOrdersTotal;
  final int openOrdersCount;
  final int? availableCredit;
  final int overdueAmount;
  final int overdueCount;
  final String crmStatus;
  final int? paymentTermsDays;
}

/// The bits of a client card the order screens need (GET /partners/{id}).
class OrderClient {
  OrderClient.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        phone = _s(j['phone']),
        address = _s(j['address']),
        wilaya = _s(j['wilaya']),
        commune = _s(j['commune']),
        priceLevel = _s(j['price_level']),
        groupId = _ns(j['group_id']),
        groupName = _ns(j['group_name']),
        groupPriceLevel = _ns(j['group_price_level']),
        groupDiscountPct = _i(j['group_discount_pct']),
        repUserId = _ns(j['rep_user_id']),
        repName = _s(j['rep_name']),
        routeId = _ns(j['route_id']),
        routeName = _s(j['route_name']),
        clientType = _s(j['client_type']),
        crmStatus = _s(j['crm_status']),
        latitude = _nd(j['latitude']),
        longitude = _nd(j['longitude']);

  final String id;
  final String name;
  final String phone;
  final String address;
  final String wilaya;
  final String commune;
  final String priceLevel;
  final String? groupId;
  final String? groupName;
  final String? groupPriceLevel;
  final int groupDiscountPct;
  final String? repUserId;
  final String repName;
  final String? routeId;
  final String routeName;
  final String clientType;
  final String crmStatus;
  final double? latitude;
  final double? longitude;

  String get priceLevelLabel {
    final lvl = groupPriceLevel ?? priceLevel;
    final base = lvl == 'wholesale' ? 'Tarif demi-gros' : 'Tarif détail';
    return groupName == null ? base : '$base (groupe $groupName)';
  }
}

// ---------------------------------------------------------------------------
// Price lists
// ---------------------------------------------------------------------------

class PriceQuote {
  PriceQuote.fromJson(Map<String, dynamic> j)
      : productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        qtyMilli = _i(j['qty_milli']),
        unitPrice = _i(j['unit_price']),
        discountPct = _i(j['discount_pct']),
        vatRate = _i(j['vat_rate']),
        priceSource = _s(j['price_source']),
        qtyFreeMilli = _i(j['qty_free_milli']),
        promoRuleName = _ns(j['promo_rule_name']),
        basePriceTTC = _i(j['base_price_ttc']),
        lineHT = _i(j['line_ht']),
        lineTTC = _i(j['line_ttc']);

  final String productId;
  final String productName;
  final int qtyMilli;
  final int unitPrice;
  final int discountPct;
  final int vatRate;
  final String priceSource;
  final int qtyFreeMilli;
  final String? promoRuleName;
  final int basePriceTTC;
  final int lineHT;
  final int lineTTC;
}

class QuotaRow {
  QuotaRow.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        partnerId = _s(j['partner_id']),
        maxQtyMilli = _i(j['max_qty_milli']),
        period = _s(j['period']),
        periodStart = _s(j['period_start']),
        usedMilli = _i(j['used_milli']),
        remainingMilli = _i(j['remaining_milli']);

  final String id;
  final String productId;
  final String productName;
  final String partnerId;
  final int maxQtyMilli;
  final String period;
  final String periodStart;
  final int usedMilli;
  final int remainingMilli;
}

class CustomerPrice {
  CustomerPrice.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        partnerId = _ns(j['partner_id']),
        partnerName = _ns(j['partner_name']),
        groupId = _ns(j['group_id']),
        groupName = _ns(j['group_name']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        priceHT = _i(j['price_ht']),
        minQtyMilli = _i(j['min_qty_milli']),
        startDate = _ns(j['start_date']),
        endDate = _ns(j['end_date']),
        notes = _s(j['notes']);

  final String id;
  final String? partnerId;
  final String? partnerName;
  final String? groupId;
  final String? groupName;
  final String productId;
  final String productName;
  final int priceHT;
  final int minQtyMilli;
  final String? startDate;
  final String? endDate;
  final String notes;

  String get who => partnerName ?? (groupName == null ? '—' : 'Groupe $groupName');
}

class PromoRule {
  PromoRule.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        scope = _s(j['scope']).isEmpty ? 'all' : _s(j['scope']),
        productId = _ns(j['product_id']),
        productName = _ns(j['product_name']),
        categoryId = _ns(j['category_id']),
        categoryName = _ns(j['category_name']),
        brand = _ns(j['brand']),
        type = _s(j['type']),
        freeQtyMilli = _i(j['free_qty_milli']),
        discountPct = _i(j['discount_pct']),
        minQtyMilli = _i(j['min_qty_milli']),
        startDate = _ns(j['start_date']),
        endDate = _ns(j['end_date']),
        audience = _s(j['audience']).isEmpty ? 'all' : _s(j['audience']),
        groupId = _ns(j['group_id']),
        partnerId = _ns(j['partner_id']),
        partnerName = _ns(j['partner_name']),
        groupName = _ns(j['group_name']),
        channel = _s(j['channel']).isEmpty ? 'all' : _s(j['channel']),
        active = j['active'] != false,
        notes = _s(j['notes']),
        label = _s(j['label']);

  final String id;
  final String name;
  final String scope;
  final String? productId;
  final String? productName;
  final String? categoryId;
  final String? categoryName;
  final String? brand;
  final String type;
  final int freeQtyMilli;
  final int discountPct;
  final int minQtyMilli;
  final String? startDate;
  final String? endDate;
  final String audience;
  final String? groupId;
  final String? partnerId;
  final String? partnerName;
  final String? groupName;
  final String channel;
  final bool active;
  final String notes;
  final String label;
}

class Quota {
  Quota.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        productId = _s(j['product_id']),
        productName = _s(j['product_name']),
        partnerId = _ns(j['partner_id']),
        partnerName = _ns(j['partner_name']),
        maxQtyMilli = _i(j['max_qty_milli']),
        period = _s(j['period']),
        active = j['active'] != false,
        notes = _s(j['notes']);

  final String id;
  final String productId;
  final String productName;
  final String? partnerId;
  final String? partnerName;
  final int maxQtyMilli;
  final String period;
  final bool active;
  final String notes;
}

// ---------------------------------------------------------------------------
// Deliveries
// ---------------------------------------------------------------------------

class Vehicle {
  Vehicle.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        plate = _s(j['plate']),
        capacityKg = _i(j['capacity_kg']),
        active = j['active'] != false,
        notes = _s(j['notes']);

  final String id;
  final String name;
  final String plate;
  final int capacityKg;
  final bool active;
  final String notes;

  String get label => plate.isEmpty ? name : '$name ($plate)';
}

class DeliveryRoute {
  DeliveryRoute.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        wilayas = _strs(j['wilayas']),
        communes = _strs(j['communes']),
        weekdays = [for (final d in (j['weekdays'] as List? ?? const [])) _i(d)],
        defaultDriverUserId = _ns(j['default_driver_user_id']),
        defaultDriverName = _s(j['default_driver_name']),
        defaultVehicleId = _ns(j['default_vehicle_id']),
        active = j['active'] != false,
        notes = _s(j['notes']),
        partnersCount = _i(j['partners_count']),
        readyOrdersCount = _i(j['ready_orders_count']);

  final String id;
  final String name;
  final List<String> wilayas;
  final List<String> communes;
  final List<int> weekdays;
  final String? defaultDriverUserId;
  final String defaultDriverName;
  final String? defaultVehicleId;
  final bool active;
  final String notes;
  final int partnersCount;
  final int readyOrdersCount;
}

class RunStop {
  RunStop.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        orderId = _s(j['order_id']),
        orderNumber = _s(j['order_number']),
        orderStatus = _s(j['order_status']),
        partnerId = _s(j['partner_id']),
        partnerName = _s(j['partner_name']),
        partnerPhone = _s(j['partner_phone']),
        deliveryAddress = _s(j['delivery_address']),
        wilaya = _s(j['wilaya']),
        commune = _s(j['commune']),
        latitude = _nd(j['latitude']),
        longitude = _nd(j['longitude']),
        totalTTC = _i(j['total_ttc']),
        deliveryNoteNumber = _ns(j['delivery_note_number']),
        sequence = _i(j['sequence']),
        status = _s(j['status']),
        failureReason = _s(j['failure_reason']),
        codExpected = _i(j['cod_expected']),
        codCollected = _i(j['cod_collected']),
        paymentMethod = _s(j['payment_method']),
        paymentNumber = _ns(j['payment_number']),
        receiverName = _s(j['receiver_name']),
        deliveredAt = _ns(j['delivered_at']),
        note = _s(j['note']);

  final String id;
  final String orderId;
  final String orderNumber;
  final String orderStatus;
  final String partnerId;
  final String partnerName;
  final String partnerPhone;
  final String deliveryAddress;
  final String wilaya;
  final String commune;
  final double? latitude;
  final double? longitude;
  final int totalTTC;
  final String? deliveryNoteNumber;
  final int sequence;
  final String status;
  final String failureReason;
  final int codExpected;
  final int codCollected;
  final String paymentMethod;
  final String? paymentNumber;
  final String receiverName;
  final String? deliveredAt;
  final String note;

  String get place => [deliveryAddress, commune, wilaya].where((s) => s.trim().isNotEmpty).join(', ');
}

class DeliveryRun {
  DeliveryRun.fromJson(Map<String, dynamic> j)
      : raw = j,
        id = _s(j['id']),
        runDate = _s(j['run_date']),
        routeId = _ns(j['route_id']),
        routeName = _s(j['route_name']),
        driverUserId = _ns(j['driver_user_id']),
        driverName = _s(j['driver_name']),
        vehicleId = _ns(j['vehicle_id']),
        vehicleName = _s(j['vehicle_name']),
        status = _s(j['status']),
        departedAt = _ns(j['departed_at']),
        closedAt = _ns(j['closed_at']),
        cashExpected = _i(j['cash_expected']),
        cashCollected = _i(j['cash_collected']),
        cashDifference = _i(j['cash_difference']),
        countedCash = _ni(j['counted_cash']),
        notes = _s(j['notes']),
        stopsCount = _i(j['stops_count']),
        pendingCount = _i(j['pending_count']),
        codExpectedTotal = _i(j['cod_expected_total']),
        codCollectedTotal = _i(j['cod_collected_total']),
        stops = [for (final s in _list(j['stops'])) RunStop.fromJson(s)];

  final Map<String, dynamic> raw;
  final String id;
  final String runDate;
  final String? routeId;
  final String routeName;
  final String? driverUserId;
  final String driverName;
  final String? vehicleId;
  final String vehicleName;
  final String status;
  final String? departedAt;
  final String? closedAt;
  final int cashExpected;
  final int cashCollected;
  final int cashDifference;
  final int? countedCash;
  final String notes;
  final int stopsCount;
  final int pendingCount;
  final int codExpectedTotal;
  final int codCollectedTotal;
  final List<RunStop> stops;

  bool get open => status == 'planned' || status == 'out';
}

/// GET /orders/web-sync row.
class WebSyncItem {
  WebSyncItem.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        number = _s(j['number']),
        externalRef = _s(j['external_ref']),
        externalNumber = _s(j['external_number']),
        status = _s(j['status']),
        cancelReason = _s(j['cancel_reason']),
        lastEventNote = _s(j['last_event_note']),
        lastEventAt = _s(j['last_event_at']);

  final String id;
  final String number;
  final String externalRef;
  final String externalNumber;
  final String status;
  final String cancelReason;
  final String lastEventNote;
  final String lastEventAt;
}
