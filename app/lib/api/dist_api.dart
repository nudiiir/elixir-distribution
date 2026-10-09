import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'dist_models.dart';

export 'dist_models.dart';

/// Error of the Distribution routes: the usual [ApiException] (so
/// `withApproval` keeps working) plus the extra keys the screens need.
class DistApiException extends ApiException {
  DistApiException(super.status, super.message,
      {super.needsApproval,
      super.action,
      super.amount,
      super.field,
      this.warnings = const [],
      this.needsOverride = false,
      this.wrongProduct = false});

  /// 409 « validation bloquée » : the account alerts.
  final List<String> warnings;
  final bool needsOverride;

  /// 422 of a scan: unknown barcode / product not in the order.
  final bool wrongProduct;
}

final _http = http.Client();
const _timeout = Duration(seconds: 30);

String _q(Map<String, String?> m) {
  final parts = [
    for (final e in m.entries)
      if (e.value != null && e.value!.isNotEmpty)
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value!)}'
  ];
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

/// Distribution API (docs/API_DISTRIBUTION.md) on the shop server. Kept in
/// its own file so the shared client stays small.
extension DistApi on ApiClient {
  Map<String, String> _dh() {
    final approval = approvalToken;
    approvalToken = null;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      'X-Approval': ?approval,
    };
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl/api/v1$path'))..headers.addAll(_dh());
    if (body != null) req.bodyBytes = utf8.encode(jsonEncode(body));
    final http.Response res;
    try {
      final streamed = await _http.send(req).timeout(_timeout);
      res = await http.Response.fromStream(streamed).timeout(_timeout);
    } on TimeoutException {
      throw ApiException(0, 'Le serveur ne répond pas (délai dépassé).');
    } catch (e) {
      throw ApiException(0, 'Serveur injoignable : $e');
    }
    dynamic j;
    if (res.bodyBytes.isNotEmpty) {
      try {
        j = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {}
    }
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode >= 400) {
      final m = j is Map ? j : const {};
      final msg = m['error'] is String
          ? m['error'] as String
          : res.statusCode == 404
              ? 'Introuvable (le serveur doit peut-être être mis à jour).'
              : 'Erreur ${res.statusCode}';
      throw DistApiException(res.statusCode, msg,
          needsApproval: m['needs_approval'] == true,
          action: m['action'] as String?,
          amount: (m['amount'] as num?)?.toInt() ?? 0,
          field: m['field'] as String?,
          warnings: [for (final w in (m['warnings'] as List? ?? const [])) '$w'],
          needsOverride: m['needs_override'] == true,
          wrongProduct: m['wrong_product'] == true);
    }
    return j;
  }

  Future<Map<String, dynamic>> _dget(String path, [Map<String, String?> q = const {}]) async =>
      Map<String, dynamic>.from((await _send('GET', path + _q(q))) as Map? ?? const {});
  Future<Map<String, dynamic>> _dpost(String path, [Object? body]) async =>
      Map<String, dynamic>.from((await _send('POST', path, body)) as Map? ?? const {});
  Future<Map<String, dynamic>> _dput(String path, Object body) async =>
      Map<String, dynamic>.from((await _send('PUT', path, body)) as Map? ?? const {});
  Future<Map<String, dynamic>> _dpatch(String path, Object body) async =>
      Map<String, dynamic>.from((await _send('PATCH', path, body)) as Map? ?? const {});
  Future<Map<String, dynamic>> _ddel(String path) async =>
      Map<String, dynamic>.from((await _send('DELETE', path)) as Map? ?? const {});

  List<Map<String, dynamic>> _items(Map<String, dynamic> j) => [
        for (final e in (j['items'] as List? ?? const []))
          if (e is Map) Map<String, dynamic>.from(e)
      ];

  // ---------------- Commandes ----------------

  Future<OrderPage> orders({
    List<String> statuses = const [],
    String? partnerId,
    String? repUserId,
    String? wilaya,
    String? routeId,
    String? source,
    String? priority,
    String? from,
    String? to,
    bool backorderOnly = false,
    String? q,
    bool sortPriority = false,
    int limit = 100,
    int offset = 0,
  }) async =>
      OrderPage.fromJson(await _dget('/orders', {
        'status': statuses.join(','),
        'partner_id': partnerId,
        'rep_user_id': repUserId,
        'wilaya': wilaya,
        'route_id': routeId,
        'source': source,
        'priority': priority,
        'from': from,
        'to': to,
        if (backorderOnly) 'has_backorder': '1',
        'q': q?.trim(),
        if (sortPriority) 'sort': 'priority',
        'limit': '$limit',
        if (offset > 0) 'offset': '$offset',
      }));

  Future<CustomerOrder> order(String id) async => CustomerOrder.fromJson(await _dget('/orders/$id'));

  Future<CustomerOrder> createOrder(Map<String, dynamic> body) async =>
      CustomerOrder.fromJson(await _dpost('/orders', body));

  Future<CustomerOrder> updateOrder(String id, Map<String, dynamic> body) async =>
      CustomerOrder.fromJson(await _dput('/orders/$id', body));

  Future<CustomerOrder> addOrderLines(String id, List<Map<String, dynamic>> lines) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/lines', {'lines': lines}));

  Future<CustomerOrder> patchOrderLine(String id, String lineId, Map<String, dynamic> body) async =>
      CustomerOrder.fromJson(await _dpatch('/orders/$id/lines/$lineId', body));

  Future<CustomerOrder> deleteOrderLine(String id, String lineId) async =>
      CustomerOrder.fromJson(await _ddel('/orders/$id/lines/$lineId'));

  Future<CustomerOrder> substituteOrderLine(String id, String lineId,
          {required String productId, int? qtyMilli, bool keepPrice = false}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/lines/$lineId/substitute', {
        'product_id': productId,
        'qty_milli': ?qtyMilli,
        if (keepPrice) 'keep_price': true,
      }));

  /// Answers the order; its `raw['validation']` holds warnings / backorders.
  Future<CustomerOrder> validateOrder(String id,
          {bool overrideCredit = false, bool? partial, List<Map<String, dynamic>>? lines}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/validate', {
        if (overrideCredit) 'override_credit': true,
        'partial': ?partial,
        'lines': ?lines,
      }));

  Future<CustomerOrder> reopenOrder(String id) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/reopen'));

  Future<CustomerOrder> startPreparation(String id) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/start-preparation'));

  Future<PickingList> pickingList(String id) async =>
      PickingList.fromJson(await _dget('/orders/$id/picking-list'));

  Future<PickingList> batchPickingList(List<String> ids) async =>
      PickingList.fromJson(await _dget('/orders/picking-list', {'ids': ids.join(',')}));

  Future<PickResult> addPick(String id, {required String lineId, String? lotId, required int qtyMilli}) async =>
      PickResult.fromJson(await _dpost(
          '/orders/$id/picks', {'line_id': lineId, 'lot_id': ?lotId, 'qty_milli': qtyMilli}));

  Future<CustomerOrder> deletePick(String id, String pickId) async =>
      CustomerOrder.fromJson(await _ddel('/orders/$id/picks/$pickId'));

  Future<PickResult> scanPick(String id, String barcode, {int? qtyMilli, String? lotNumber}) async =>
      PickResult.fromJson(await _dpost('/orders/$id/scan', {
        'barcode': barcode,
        'qty_milli': ?qtyMilli,
        if (lotNumber != null && lotNumber.isNotEmpty) 'lot_number': lotNumber,
      }));

  Future<CustomerOrder> markReady(String id, {bool acceptPartial = false, bool autoPick = false}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/ready', {
        if (acceptPartial) 'accept_partial': true,
        if (autoPick) 'auto_pick': true,
      }));

  Future<CustomerOrder> orderDeliveryNote(String id) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/delivery-note'));

  Future<CustomerOrder> shipOrder(String id, {String? note}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/ship', {if (note != null && note.isNotEmpty) 'note': note}));

  Future<CustomerOrder> deliverOrder(String id,
          {int codAmount = 0, String? paymentMethod, String? receiverName, String? note}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/deliver', {
        if (codAmount > 0) 'cod_amount': codAmount,
        if (codAmount > 0) 'payment_method': ?paymentMethod,
        if (receiverName != null && receiverName.isNotEmpty) 'receiver_name': receiverName,
        if (note != null && note.isNotEmpty) 'note': note,
      }));

  Future<CustomerOrder> invoiceOrder(String id, {String? paymentMethod}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/invoice', {'payment_method': ?paymentMethod}));

  Future<CustomerOrder> cancelOrder(String id, String reason) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/cancel', {'reason': reason}));

  Future<CustomerOrder> releaseBackorder(String id, {List<String>? lineIds}) async =>
      CustomerOrder.fromJson(await _dpost('/orders/$id/release-backorder', {'line_ids': ?lineIds}));

  Future<(List<BackorderRow>, int)> backorders(
      {String? partnerId, String? productId, bool fulfillable = false}) async {
    final j = await _dget('/orders/backorders', {
      'partner_id': partnerId,
      'product_id': productId,
      if (fulfillable) 'fulfillable': '1',
    });
    return (
      [for (final e in _items(j)) BackorderRow.fromJson(e)],
      (j['fulfillable_count'] as num?)?.toInt() ?? 0
    );
  }

  Future<CustomerOrder> backorderNewOrder(String partnerId, {List<String>? lineIds}) async =>
      CustomerOrder.fromJson(
          await _dpost('/orders/backorders/new-order', {'partner_id': partnerId, 'line_ids': ?lineIds}));

  /// « Qui attend ce produit ».
  Future<List<BackorderRow>> waitingCustomers(String productId) async =>
      [for (final e in _items(await _dget('/products/$productId/waiting-customers'))) BackorderRow.fromJson(e)];

  // ---------------- Boutique web ----------------

  /// POST /orders/import-web → (order, created, partnerCreated, warnings).
  Future<({CustomerOrder order, bool created, bool partnerCreated, List<String> warnings})> importWebOrder(
      Map<String, dynamic> payload) async {
    final j = await _dpost('/orders/import-web', payload);
    return (
      order: CustomerOrder.fromJson(j),
      created: j['created'] == true,
      partnerCreated: j['partner_created'] == true,
      warnings: [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
    );
  }

  Future<List<WebSyncItem>> webSyncList() async =>
      [for (final e in _items(await _dget('/orders/web-sync'))) WebSyncItem.fromJson(e)];

  Future<int> webSyncAck(List<({String id, String status})> items) async {
    final j = await _dpost('/orders/web-sync/ack', {
      'items': [for (final i in items) {'id': i.id, 'status': i.status}]
    });
    return (j['cleared'] as num?)?.toInt() ?? 0;
  }

  // ---------------- Client ----------------

  Future<PartnerCredit> partnerCredit(String partnerId) async =>
      PartnerCredit.fromJson(await _dget('/partners/$partnerId/credit'));

  Future<OrderClient> orderClient(String partnerId) async =>
      OrderClient.fromJson(await _dget('/partners/$partnerId'));

  /// Raw users list (admin only); empty when not allowed.
  Future<List<({String id, String name})>> staffList() async {
    try {
      final j = await _send('GET', '/users');
      final items = j is Map ? (j['items'] as List? ?? const []) : const [];
      return [
        for (final u in items)
          if (u is Map && u['active'] != false)
            (
              id: '${u['id']}',
              name: '${(u['full_name'] ?? '').toString().isEmpty ? u['username'] : u['full_name']}'
            )
      ];
    } catch (_) {
      return const [];
    }
  }

  // ---------------- Tarifs ----------------

  Future<(PriceQuote, List<QuotaRow>)> resolvePrice(String productId,
      {String? partnerId, int qtyMilli = 1000, String? channel}) async {
    final j = await _dget('/pricing/resolve', {
      'product_id': productId,
      'partner_id': partnerId,
      'qty_milli': '$qtyMilli',
      'channel': channel,
    });
    return (
      PriceQuote.fromJson(Map<String, dynamic>.from(j['quote'] as Map? ?? const {})),
      [
        for (final e in (j['quotas'] as List? ?? const []))
          if (e is Map) QuotaRow.fromJson(Map<String, dynamic>.from(e))
      ]
    );
  }

  Future<List<CustomerPrice>> customerPrices({String? partnerId, String? groupId, String? productId, String? q}) async => [
        for (final e in _items(await _dget('/customer-prices',
            {'partner_id': partnerId, 'group_id': groupId, 'product_id': productId, 'q': q})))
          CustomerPrice.fromJson(e)
      ];

  Future<CustomerPrice> saveCustomerPrice(Map<String, dynamic> body, {String? id}) async =>
      CustomerPrice.fromJson(
          id == null ? await _dpost('/customer-prices', body) : await _dput('/customer-prices/$id', body));

  Future<void> deleteCustomerPrice(String id) => _ddel('/customer-prices/$id');

  Future<List<PromoRule>> promoRules({bool activeOnly = false, String? productId, String? type}) async => [
        for (final e in _items(await _dget('/promo-rules',
            {if (activeOnly) 'active': '1', 'product_id': productId, 'type': type})))
          PromoRule.fromJson(e)
      ];

  Future<PromoRule> savePromoRule(Map<String, dynamic> body, {String? id}) async =>
      PromoRule.fromJson(id == null ? await _dpost('/promo-rules', body) : await _dput('/promo-rules/$id', body));

  Future<void> deletePromoRule(String id) => _ddel('/promo-rules/$id');

  Future<List<Quota>> quotas({String? productId, String? partnerId}) async => [
        for (final e in _items(await _dget('/product-quotas', {'product_id': productId, 'partner_id': partnerId})))
          Quota.fromJson(e)
      ];

  Future<List<QuotaRow>> quotaUsage(String partnerId, {String? productId}) async => [
        for (final e in _items(
            await _dget('/product-quotas/usage', {'partner_id': partnerId, 'product_id': productId})))
          QuotaRow.fromJson(e)
      ];

  Future<Quota> saveQuota(Map<String, dynamic> body, {String? id}) async =>
      Quota.fromJson(id == null ? await _dpost('/product-quotas', body) : await _dput('/product-quotas/$id', body));

  Future<void> deleteQuota(String id) => _ddel('/product-quotas/$id');

  // ---------------- Livraisons ----------------

  Future<List<Vehicle>> vehicles() async => [for (final e in _items(await _dget('/vehicles'))) Vehicle.fromJson(e)];

  Future<Vehicle> saveVehicle(Map<String, dynamic> body, {String? id}) async =>
      Vehicle.fromJson(id == null ? await _dpost('/vehicles', body) : await _dput('/vehicles/$id', body));

  Future<void> deleteVehicle(String id) => _ddel('/vehicles/$id');

  Future<List<DeliveryRoute>> deliveryRoutes() async =>
      [for (final e in _items(await _dget('/delivery-routes'))) DeliveryRoute.fromJson(e)];

  Future<DeliveryRoute> saveDeliveryRoute(Map<String, dynamic> body, {String? id}) async => DeliveryRoute.fromJson(
      id == null ? await _dpost('/delivery-routes', body) : await _dput('/delivery-routes/$id', body));

  Future<void> deleteDeliveryRoute(String id) => _ddel('/delivery-routes/$id');

  Future<List<DeliveryRun>> deliveryRuns(
          {String? from, String? to, List<String> statuses = const [], String? routeId}) async =>
      [
        for (final e in _items(await _dget('/delivery-runs',
            {'from': from, 'to': to, 'status': statuses.join(','), 'route_id': routeId})))
          DeliveryRun.fromJson(e)
      ];

  Future<DeliveryRun> deliveryRun(String id) async => DeliveryRun.fromJson(await _dget('/delivery-runs/$id'));

  Future<DeliveryRun> createDeliveryRun(Map<String, dynamic> body) async =>
      DeliveryRun.fromJson(await _dpost('/delivery-runs', body));

  Future<DeliveryRun> updateDeliveryRun(String id, Map<String, dynamic> body) async =>
      DeliveryRun.fromJson(await _dput('/delivery-runs/$id', body));

  Future<void> addRunStops(String id, List<String> orderIds) => _dpost('/delivery-runs/$id/stops', {'order_ids': orderIds});

  Future<void> reorderRunStops(String id, List<String> stopIds) =>
      _dput('/delivery-runs/$id/stops/order', {'stop_ids': stopIds});

  Future<void> patchRunStop(String id, String stopId, {int? codExpected, String? note}) =>
      _dpatch('/delivery-runs/$id/stops/$stopId', {'cod_expected': ?codExpected, 'note': ?note});

  Future<void> removeRunStop(String id, String stopId) => _ddel('/delivery-runs/$id/stops/$stopId');

  Future<DeliveryRun> startDeliveryRun(String id) async =>
      DeliveryRun.fromJson(await _dpost('/delivery-runs/$id/start'));

  Future<void> recordRunStop(String id, String stopId, Map<String, dynamic> body) =>
      _dpost('/delivery-runs/$id/stops/$stopId/result', body);

  Future<DeliveryRun> closeDeliveryRun(String id, {int? countedCash, String? notes}) async =>
      DeliveryRun.fromJson(await _dpost('/delivery-runs/$id/close', {
        'counted_cash': ?countedCash,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }));

  Future<void> cancelDeliveryRun(String id) => _dpost('/delivery-runs/$id/cancel');
}
