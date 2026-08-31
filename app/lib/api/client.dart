import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cloud.dart';
import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

/// HTTP client for the Elixir shop server.
class ApiClient {
  ApiClient({this.baseUrl = 'http://127.0.0.1:8543'});

  /// Mutable so the "server address" setting can repoint the client.
  String baseUrl;
  final _client = http.Client();

  /// Bearer token attached to every request once logged in.
  String? token;

  /// Called on any 401 so the app can drop back to the login screen.
  void Function()? onUnauthorized;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final res = await _client.get(_u(path, query), headers: _headers);
    return _handle(res);
  }

  Future<dynamic> _post(String path, [Object? body]) async {
    final res = await _client.post(_u(path),
        headers: _headers, body: body == null ? null : jsonEncode(body));
    return _handle(res);
  }

  dynamic _handle(http.Response res) {
    final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 401 && token != null) {
      onUnauthorized?.call();
    }
    if (res.statusCode >= 400) {
      final msg = body is Map && body['error'] != null
          ? body['error'] as String
          : 'HTTP ${res.statusCode}';
      throw ApiException(res.statusCode, msg);
    }
    return body;
  }

  /// Authenticates and installs the token on this client.
  Future<Session> login(String username, String password) async {
    final j = await _post('/api/v1/auth/login',
        {'username': username, 'password': password});
    final session = Session(j['token'] as String, User.fromJson(j['user']));
    token = session.token;
    return session;
  }

  Future<User> me() async =>
      User.fromJson(await _get('/api/v1/auth/me'));

  Future<List<User>> users() async {
    final j = await _get('/api/v1/users');
    return [for (final e in j['items'] as List) User.fromJson(e)];
  }

  Future<User> saveUser(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/users', data)
        : await _put('/api/v1/users/$id', data);
    return User.fromJson(j);
  }

  Future<bool> health() async {
    try {
      final j = await _get('/health');
      return j is Map && j['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<List<Product>> products({String? q, int limit = 100}) async {
    final j = await _get('/api/v1/products', {
      if (q != null && q.isNotEmpty) 'q': q,
      'limit': '$limit',
    });
    return [for (final e in j['items'] as List) Product.fromJson(e)];
  }

  /// Pages through the whole catalogue (the server caps a page at 500).
  Future<List<Product>> allProducts() async {
    final out = <Product>[];
    var offset = 0;
    while (true) {
      final j = await _get('/api/v1/products', {
        'limit': '500',
        'offset': '$offset',
      });
      final page = [for (final e in j['items'] as List) Product.fromJson(e)];
      out.addAll(page);
      if (page.length < 500) return out;
      offset += 500;
    }
  }

  Future<List<Warehouse>> warehouses() async {
    final j = await _get('/api/v1/warehouses');
    return [for (final e in j['items'] as List) Warehouse.fromJson(e)];
  }

  Future<Warehouse> createWarehouse(String name) async =>
      Warehouse.fromJson(await _post('/api/v1/warehouses', {'name': name}));

  Future<List<StockLevel>> stockLevels({String? warehouseId, String? q}) async {
    final j = await _get('/api/v1/stock/levels', {
      'warehouse_id': ?warehouseId,
      if (q != null && q.isNotEmpty) 'q': q,
    });
    return [for (final e in j['items'] as List) StockLevel.fromJson(e)];
  }

  Future<List<StockMovement>> stockMovements({int limit = 20}) async {
    final j = await _get('/api/v1/stock/movements', {'limit': '$limit'});
    return [for (final e in j['items'] as List) StockMovement.fromJson(e)];
  }

  Future<List<DocSummary>> documents({
    String? type,
    String? status,
    String? from,
    String? to,
    int limit = 100,
  }) async {
    final j = await _get('/api/v1/documents', {
      'type': ?type,
      'status': ?status,
      'from': ?from,
      'to': ?to,
      'limit': '$limit',
    });
    return [for (final e in j['items'] as List) DocSummary.fromJson(e)];
  }

  Future<dynamic> _put(String path, Object body) async {
    final res = await _client.put(_u(path),
        headers: _headers, body: jsonEncode(body));
    return _handle(res);
  }

  Future<List<Partner>> partners({String? q, String? kind, int limit = 200}) async {
    final j = await _get('/api/v1/partners', {
      if (q != null && q.isNotEmpty) 'q': q,
      'kind': ?kind,
      'limit': '$limit',
    });
    return [for (final e in j['items'] as List) Partner.fromJson(e)];
  }

  Future<Partner> getPartner(String id) async =>
      Partner.fromJson(await _get('/api/v1/partners/$id'));

  Future<Partner> savePartner(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/partners', data)
        : await _put('/api/v1/partners/$id', data);
    return Partner.fromJson(j);
  }

  Future<Product> getProduct(String id) async =>
      Product.fromJson(await _get('/api/v1/products/$id'));

  Future<Product> saveProduct(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/products', data)
        : await _put('/api/v1/products/$id', data);
    return Product.fromJson(j);
  }

  Future<DocDetail> getDocument(String id) async =>
      DocDetail.fromJson(await _get('/api/v1/documents/$id'));

  Future<DocDetail> createDraft(Map<String, dynamic> doc) async =>
      DocDetail.fromJson(await _post('/api/v1/documents', doc));

  Future<DocDetail> updateDraft(String id, Map<String, dynamic> doc) async =>
      DocDetail.fromJson(await _put('/api/v1/documents/$id', doc));

  Future<DocDetail> postDocument(String id) async =>
      DocDetail.fromJson(await _post('/api/v1/documents/$id/post'));

  Future<DocDetail> cancelDocument(String id) async =>
      DocDetail.fromJson(await _post('/api/v1/documents/$id/cancel'));

  /// Creates and posts a payment document (PAYMENT_IN / PAYMENT_OUT).
  Future<DocDetail> createPayment({
    required String docType,
    required String partnerId,
    required int amount,
    required String method,
  }) async {
    final draft = await createDraft({
      'doc_type': docType,
      'doc_date': todayISO(),
      'partner_id': partnerId,
      'amount': amount,
      'payment_method': method,
    });
    return postDocument(draft.id);
  }

  /// Cloud service configuration, as the server knows it.
  Future<CloudConfig> cloudStatus() async =>
      CloudConfig.fromJson(await _get('/api/v1/cloud/status'));

  /// Enrolls this shop with the cloud (once) and turns remote access on.
  /// Requires the caller's own password again.
  Future<CloudConfig> cloudConnect(String password) async =>
      CloudConfig.fromJson(
          await _post('/api/v1/cloud/connect', {'password': password}));

  Future<CloudConfig> cloudDisconnect() async =>
      CloudConfig.fromJson(await _post('/api/v1/cloud/disconnect'));

  /// Mints a one-time pairing code for the QR shown to a phone.
  Future<({String code, int expiresIn, String payload})> cloudPair(
      String password) async {
    final j = await _post('/api/v1/cloud/pair', {'password': password});
    return (
      code: j['code'] as String,
      expiresIn: (j['expires_in'] as num?)?.toInt() ?? 300,
      payload: jsonEncode(j['payload']),
    );
  }

  Future<Map<String, String>> settings() async {
    final j = await _get('/api/v1/settings') as Map<String, dynamic>;
    return j.map((k, v) => MapEntry(k, v as String));
  }

  Future<void> saveSettings(Map<String, String> values) async {
    await _put('/api/v1/settings', values);
  }

  /// Creates a draft sale ticket and posts it. Returns the full posted document.
  /// [paymentMethod] null = paid by gift card (not cash in the drawer).
  Future<DocDetail> checkoutTicket({
    required String warehouseId,
    required String? paymentMethod,
    required List<Map<String, dynamic>> lines,
    String? partnerId,
    String? caisseSessionId,
  }) async {
    final draft = await _post('/api/v1/documents', {
      'doc_type': 'SALE_TICKET',
      'doc_date': todayISO(),
      'warehouse_id': warehouseId,
      'payment_method': paymentMethod,
      'partner_id': partnerId,
      'caisse_session_id': caisseSessionId,
      'lines': lines,
    });
    final posted = await _post('/api/v1/documents/${draft['id']}/post');
    return DocDetail.fromJson(posted);
  }

  // ---- Gift cards ----

  Future<GiftCard> createGiftCard(int amount,
      {String? expiresAt, String? notes}) async {
    return GiftCard.fromJson(await _post('/api/v1/gift-cards', {
      'amount': amount,
      'expires_at': expiresAt,
      'notes': notes,
    }));
  }

  Future<GiftCard> giftCard(String code) async =>
      GiftCard.fromJson(await _get('/api/v1/gift-cards/code/$code'));

  /// Debits the card; returns (useId, newBalance).
  Future<(String, int)> redeemGiftCard(String code, int amount,
      {String? documentId}) async {
    final j = await _post('/api/v1/gift-cards/code/$code/redeem', {
      'amount': amount,
      'document_id': documentId,
    });
    return (j['use_id'] as String, (j['balance'] as num).toInt());
  }

  Future<void> refundGiftCardUse(String useId) async {
    await _post('/api/v1/gift-card-uses/$useId/refund');
  }

  // ---- Caisse sessions ----

  Future<CaisseSession?> caisseCurrent() async {
    final j = await _get('/api/v1/caisse/current');
    final s = j['session'];
    return s == null ? null : CaisseSession.fromJson(s);
  }

  Future<CaisseSession> caisseOpen(int openingCash) async {
    final j = await _post('/api/v1/caisse/open', {'opening_cash': openingCash});
    return CaisseSession.fromJson(j['session']);
  }

  Future<(CaisseSession, CaisseReport)> caisseReport() async {
    final j = await _get('/api/v1/caisse/report');
    return (
      CaisseSession.fromJson(j['session']),
      CaisseReport.fromJson(j['report'])
    );
  }

  Future<(CaisseSession, CaisseReport)> caisseClose(
      int countedCash, String? notes) async {
    final j = await _post('/api/v1/caisse/close',
        {'counted_cash': countedCash, 'notes': notes});
    return (
      CaisseSession.fromJson(j['session']),
      CaisseReport.fromJson(j['report'])
    );
  }

  Future<dynamic> _delete(String path) async {
    final res = await _client.delete(_u(path), headers: _headers);
    return _handle(res);
  }

  /// Mints an unused internal EAN-13 (200-prefix, in-store range).
  Future<String> generateBarcode() async {
    final j = await _post('/api/v1/products/generate-barcode');
    return j['barcode'] as String;
  }

  // ---- Categories ----

  Future<List<Category>> categories() async {
    final j = await _get('/api/v1/categories');
    return [for (final e in j['items'] as List) Category.fromJson(e)];
  }

  Future<Category> createCategory(String name) async =>
      Category.fromJson(await _post('/api/v1/categories', {'name': name}));

  Future<void> renameCategory(String id, String name) async {
    await _put('/api/v1/categories/$id', {'name': name});
  }

  Future<void> deleteCategory(String id) async {
    await _delete('/api/v1/categories/$id');
  }

  // ---- Serialized units (IMEI) ----

  Future<List<ProductUnit>> units(
      {String? productId, String? status, String? q}) async {
    final j = await _get('/api/v1/units', {
      'product_id': ?productId,
      'status': ?status,
      if (q != null && q.isNotEmpty) 'q': q,
    });
    return [for (final e in j['items'] as List) ProductUnit.fromJson(e)];
  }

  Future<ProductUnit> unitBySerial(String serial) async =>
      ProductUnit.fromJson(
          await _get('/api/v1/units/serial/${Uri.encodeComponent(serial)}'));

  /// Registers serials; returns (added, duplicates).
  Future<(int, List<String>)> addUnits(String productId, List<String> serials,
      {bool isUsed = false}) async {
    final j = await _post('/api/v1/units', {
      'product_id': productId,
      'serials': serials,
      'is_used': isUsed,
    });
    return (
      (j['added'] as num?)?.toInt() ?? 0,
      [for (final d in (j['duplicates'] as List? ?? const [])) d.toString()]
    );
  }

  Future<void> sellUnit(String serial,
      {required String productId, String? saleDocId, String? partnerId}) async {
    await _post('/api/v1/units/sell', {
      'serial': serial,
      'product_id': productId,
      'sale_doc_id': saleDocId,
      'partner_id': partnerId,
    });
  }

  Future<void> updateUnit(String id,
      {required String status, String? notes}) async {
    await _put('/api/v1/units/$id', {'status': status, 'notes': notes});
  }

  // ---- SAV (repairs) ----

  Future<List<Repair>> repairs({String? status, String? q}) async {
    final j = await _get('/api/v1/repairs', {
      'status': ?status,
      if (q != null && q.isNotEmpty) 'q': q,
    });
    return [for (final e in j['items'] as List) Repair.fromJson(e)];
  }

  Future<Repair> saveRepair(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/repairs', data)
        : await _put('/api/v1/repairs/$id', data);
    return Repair.fromJson(j);
  }

  // ---- Installments ----

  Future<List<InstallmentPlan>> installmentPlans({String? partnerId}) async {
    final j =
        await _get('/api/v1/installment-plans', {'partner_id': ?partnerId});
    return [for (final e in j['items'] as List) InstallmentPlan.fromJson(e)];
  }

  Future<void> createInstallmentPlan({
    required String partnerId,
    required int total,
    required int months,
    required String startDate,
    String? documentId,
    String? notes,
  }) async {
    await _post('/api/v1/installment-plans', {
      'partner_id': partnerId,
      'total': total,
      'months': months,
      'start_date': startDate,
      'document_id': documentId,
      'notes': notes,
    });
  }

  Future<void> payInstallmentDue(String dueId, {int? amount}) async {
    await _post('/api/v1/installment-dues/$dueId/pay', {'amount': amount});
  }

  Future<void> deleteInstallmentPlan(String id) async {
    await _delete('/api/v1/installment-plans/$id');
  }

  // ---- Lots (DLC) ----

  Future<List<Lot>> lots({String? productId, int? expiringDays}) async {
    final j = await _get('/api/v1/lots', {
      'product_id': ?productId,
      if (expiringDays != null) 'expiring_days': '$expiringDays',
    });
    return [for (final e in j['items'] as List) Lot.fromJson(e)];
  }

  Future<void> saveLot(Map<String, dynamic> data, {String? id}) async {
    if (id == null) {
      await _post('/api/v1/lots', data);
    } else {
      await _put('/api/v1/lots/$id', data);
    }
  }

  Future<void> deleteLot(String id) async {
    await _delete('/api/v1/lots/$id');
  }

  // ---- Reports & audit ----

  Future<Map<String, dynamic>> reportSummary(
      {required String from, required String to}) async {
    return await _get('/api/v1/reports/summary', {'from': from, 'to': to})
        as Map<String, dynamic>;
  }

  Future<List<BreakdownRow>> reportBreakdown(
      {required String from, required String to, required String by}) async {
    final j = await _get(
        '/api/v1/reports/breakdown', {'from': from, 'to': to, 'by': by});
    return [for (final e in j['items'] as List) BreakdownRow.fromJson(e)];
  }

  Future<List<AuditEntry>> auditLog({int limit = 150}) async {
    final j = await _get('/api/v1/audit', {'limit': '$limit'});
    return [for (final e in j['items'] as List) AuditEntry.fromJson(e)];
  }

  // ---- Print templates ----

  Future<List<Template>> templates({String? kind}) async {
    final j = await _get('/api/v1/templates', {'kind': ?kind});
    return [for (final e in j['items'] as List) Template.fromJson(e)];
  }

  /// The default template of a kind, or null if none is stored yet.
  Future<Template?> defaultTemplate(String kind) async {
    final all = await templates(kind: kind);
    for (final t in all) {
      if (t.isDefault) return t;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<Template> saveTemplate(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/templates', data)
        : await _put('/api/v1/templates/$id', data);
    return Template.fromJson(j);
  }

  Future<void> deleteTemplate(String id) async {
    await _delete('/api/v1/templates/$id');
  }

  Future<Template> setDefaultTemplate(String id) async =>
      Template.fromJson(await _post('/api/v1/templates/$id/default'));

  // ---- Presence (connected posts) ----

  Future<void> presenceBeat({required String device, required String screen}) async {
    await _post('/api/v1/presence',
        {'device': device, 'screen': screen, 'kind': 'desktop'});
  }

  Future<List<PresenceEntry>> presenceList() async {
    final j = await _get('/api/v1/presence');
    return [for (final e in j['items'] as List) PresenceEntry.fromJson(e)];
  }

  // ---- Backups ----

  Future<(String, List<BackupInfo>)> backups() async {
    final j = await _get('/api/v1/backups');
    return (
      (j['dir'] as String?) ?? '',
      [for (final e in j['items'] as List) BackupInfo.fromJson(e)]
    );
  }

  Future<String> runBackup() async {
    final j = await _post('/api/v1/backups/run');
    return (j['path'] as String?) ?? '';
  }
}

String todayISO() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}
