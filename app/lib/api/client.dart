import 'dart:convert';

import 'package:http/http.dart' as http;

import 'analytics_models.dart';
import 'cloud.dart';
import 'models.dart';
import 'shell_models.dart';
import 'stock_models.dart';

export 'shell_models.dart';
export 'stock_models.dart';

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

  /// Headers for widgets that fetch on their own (Image.network).
  Map<String, String> get authHeaders =>
      {if (token != null) 'Authorization': 'Bearer $token'};

  /// Photo of a product. `rev` busts the image cache when the photo changes.
  String productImageUrl(String productId, int rev,
          {bool thumb = true, int index = 0}) =>
      '$baseUrl/api/v1/products/$productId/images/$index'
      '?thumb=${thumb ? 1 : 0}&v=$rev';

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

  /// What needs attention today (alerts bell of the top bar).
  Future<List<AlertItem>> alerts() async {
    final j = await _get('/api/v1/alerts');
    return [
      for (final e in (j['items'] as List? ?? const []))
        AlertItem.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<bool> health() async {
    try {
      final j = await _get('/health');
      return j is Map && j['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<List<Product>> products(
      {String? q, int limit = 100, bool includeInactive = false}) async {
    final j = await _get('/api/v1/products', {
      if (q != null && q.isNotEmpty) 'q': q,
      'limit': '$limit',
      if (includeInactive) 'include_inactive': 'true',
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

  // ---- Fiche produit + réception pro ----

  Future<FicheData> ficheProduct(String id, {bool full = false}) async =>
      FicheData.fromJson(
          await _get('/api/v1/products/$id/fiche', {if (full) 'full': '1'}));

  /// « Séparer en déclinaisons » — items: [{barcode, suffix, qty_milli}].
  Future<Product> splitProduct(String id, String warehouseId,
          List<Map<String, dynamic>> items) async =>
      Product.fromJson(await _post('/api/v1/products/$id/split',
          {'warehouse_id': warehouseId, 'items': items}));

  /// Dernier prix payé à ce fournisseur, par produit (centimes/unité de base).
  Future<Map<String, int>> lastSupplierPrices(String partnerId) async {
    final j = await _get('/api/v1/purchases/last-prices', {'partner_id': partnerId});
    return {
      for (final e in (j['prices'] as Map<String, dynamic>? ?? {}).entries)
        e.key: (e.value as num).toInt()
    };
  }

  /// Contrepassation d'un document validé (le numéro reste, l'erreur se voit).
  Future<DocDetail> voidDocument(String id, {String reason = ''}) async =>
      DocDetail.fromJson(
          await _post('/api/v1/documents/$id/void', {'reason': reason}));

  /// Clôture du reliquat d'un bon de commande.
  Future<DocDetail> closeOrder(String id, {String reason = ''}) async =>
      DocDetail.fromJson(
          await _post('/api/v1/documents/$id/close', {'reason': reason}));

  /// Écarts de rapprochement contre le document lié.
  Future<List<MatchExceptionRow>> matchDocument(String id) async {
    final j = await _get('/api/v1/documents/$id/match');
    return [
      for (final e in (j['items'] as List? ?? const []))
        MatchExceptionRow.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<List<Warehouse>> warehouses() async {
    final j = await _get('/api/v1/warehouses');
    return [for (final e in j['items'] as List) Warehouse.fromJson(e)];
  }

  Future<Warehouse> createWarehouse(String name) async =>
      Warehouse.fromJson(await _post('/api/v1/warehouses', {'name': name}));

  /// [full] = one row per active stocked product (zeros included), summed
  /// over the depots unless [warehouseId] is given — the Stock screen mode.
  Future<List<StockLevel>> stockLevels(
      {String? warehouseId, String? q, bool full = false}) async {
    final j = await _get('/api/v1/stock/levels', {
      'warehouse_id': ?warehouseId,
      if (q != null && q.isNotEmpty) 'q': q,
      if (full) 'full': '1',
    });
    return [for (final e in j['items'] as List) StockLevel.fromJson(e)];
  }

  // ---- Écran Stock : journal, réapprovisionnement, documents de stock ----

  Future<StockLedger> stockLedger({
    String? from,
    String? to,
    String? warehouseId,
    String? productId,
    List<String> kinds = const [],
    String? q,
    int? limit,
  }) async =>
      StockLedger.fromJson(await _get('/api/v1/stock/ledger', {
        'from': ?from,
        'to': ?to,
        'warehouse_id': ?warehouseId,
        'product_id': ?productId,
        if (kinds.isNotEmpty) 'kind': kinds.join(','),
        if (q != null && q.isNotEmpty) 'q': q,
        if (limit != null) 'limit': '$limit',
      }) as Map<String, dynamic>);

  Future<List<ReorderRow>> stockReorder({String? warehouseId}) async {
    final j = await _get('/api/v1/stock/reorder', {'warehouse_id': ?warehouseId});
    return [
      for (final e in j['items'] as List)
        ReorderRow.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<List<StockDoc>> stockDocuments({
    List<String> types = const [],
    String? from,
    String? to,
    String? warehouseId,
    String? status,
  }) async {
    final j = await _get('/api/v1/stock/documents', {
      if (types.isNotEmpty) 'types': types.join(','),
      'from': ?from,
      'to': ?to,
      'warehouse_id': ?warehouseId,
      'status': ?status,
    });
    return [
      for (final e in j['items'] as List)
        StockDoc.fromJson(e as Map<String, dynamic>)
    ];
  }

  /// A saved inventory session (draft INVENTORY_COUNT) with its expected qty.
  Future<InvDraft> inventoryDraft(String id) async => InvDraft.fromJson(
      await _get('/api/v1/stock/inventory/$id') as Map<String, dynamic>);

  Future<List<StockMovement>> stockMovements({int limit = 20}) async {
    final j = await _get('/api/v1/stock/movements', {'limit': '$limit'});
    return [for (final e in j['items'] as List) StockMovement.fromJson(e)];
  }

  Future<List<DocSummary>> documents({
    String? type,
    String? status,
    String? from,
    String? to,
    String? q,
    int limit = 100,
    List<String>? types,
    String? partnerId,
    String? paymentMethod,
    int offset = 0,
  }) async {
    final j = await _get('/api/v1/documents', {
      'type': ?type,
      if (type == null && types != null && types.isNotEmpty)
        'types': types.join(','),
      'status': ?status,
      'from': ?from,
      'to': ?to,
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      'partner_id': ?partnerId,
      'payment_method': ?paymentMethod,
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
    });
    return [for (final e in j['items'] as List) DocSummary.fromJson(e)];
  }

  // ---- Pièces jointes des documents ----

  Future<List<DocAttachment>> documentAttachments(String docId) async {
    final j = await _get('/api/v1/documents/$docId/attachments');
    return [
      for (final e in (j['items'] as List? ?? const []))
        DocAttachment.fromJson(e as Map<String, dynamic>)
    ];
  }

  /// Envoie un fichier (5 Mo max) en pièce jointe d'un document.
  Future<DocAttachment> addDocumentAttachment(
      String docId, String name, List<int> bytes) async {
    final res = await _client.post(
        _u('/api/v1/documents/$docId/attachments', {'name': name}),
        headers: {
          ...authHeaders,
          'Content-Type': 'application/octet-stream'
        },
        body: bytes);
    return DocAttachment.fromJson(_handle(res) as Map<String, dynamic>);
  }

  Future<List<int>> documentAttachmentBytes(String docId, String id) async {
    final res = await _client.get(
        _u('/api/v1/documents/$docId/attachments/$id'),
        headers: authHeaders);
    if (res.statusCode >= 400) _handle(res);
    return res.bodyBytes;
  }

  Future<void> deleteDocumentAttachment(String docId, String id) async {
    await _delete('/api/v1/documents/$docId/attachments/$id');
  }

  /// Échéancier d'un partenaire (FIFO) : factures ouvertes + avoir non affecté.
  Future<PartnerOpenItems> partnerOpenItems(String partnerId) async =>
      PartnerOpenItems.fromJson(
          await _get('/api/v1/partners/$partnerId/open-items')
              as Map<String, dynamic>);

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

  // ---- Analyses -----------------------------------------------------------------
  Future<ASchema> analyticsSchema() async =>
      ASchema.fromJson((await _get('/api/v1/analytics/schema')) as Map<String, dynamic>);

  Future<AResult> analyticsQuery(Map<String, dynamic> spec) async =>
      AResult.fromJson((await _post('/api/v1/analytics/query', spec)) as Map<String, dynamic>);

  /// Retourne, par identifiant de tuile, soit un AResult soit un message d'erreur.
  Future<Map<String, Object>> analyticsBatch(List<MapEntry<String, Map<String, dynamic>>> queries,
      {Map<String, dynamic>? globalRange, String? globalWarehouseId}) async {
    final j = await _post('/api/v1/analytics/query/batch', {
      'queries': [for (final q in queries) {'id': q.key, 'request': q.value}],
      if (globalRange != null) 'global_range': globalRange,
      if (globalWarehouseId != null) 'global_warehouse_id': globalWarehouseId,
    }) as Map<String, dynamic>;
    final out = <String, Object>{};
    for (final r in (j['results'] as List)) {
      final m = r as Map<String, dynamic>;
      if (m['ok'] == true) {
        out[m['id'] as String] = AResult.fromJson(m['result'] as Map<String, dynamic>);
      } else {
        final e = (m['error'] as Map?) ?? const {};
        out[m['id'] as String] = ApiException(
            e['code'] == 'forbidden' ? 403 : e['code'] == 'timeout' || e['code'] == 'budget_exceeded' ? 504 : 400,
            (e['message'] as String?) ?? 'erreur');
      }
    }
    return out;
  }

  Future<List<GalleryItem>> analyticsGallery() async {
    final j = await _get('/api/v1/analytics/gallery') as Map<String, dynamic>;
    return [for (final e in j['items'] as List) GalleryItem.fromJson(e as Map<String, dynamic>)];
  }

  /// Question en langage naturel → spec + résultat. Un 422 porte quand même
  /// la réponse (spec proposée, clarification ou erreur) : on la rend telle
  /// quelle plutôt que de lever.
  Future<AskAnswer> analyticsAsk(String question) async {
    final res = await _client.post(_u('/api/v1/analytics/ask'),
        headers: _headers, body: jsonEncode({'question': question}));
    final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode == 200 || res.statusCode == 422) {
      return AskAnswer.fromJson(body as Map<String, dynamic>);
    }
    final msg = body is Map && body['error'] != null ? body['error'] as String : 'HTTP ${res.statusCode}';
    throw ApiException(res.statusCode, msg);
  }

  Future<List<SavedReport>> savedReports() async {
    final j = await _get('/api/v1/analytics/reports') as Map<String, dynamic>;
    return [for (final e in j['items'] as List) SavedReport.fromJson(e as Map<String, dynamic>)];
  }

  Future<SavedReport> saveReport(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/analytics/reports', data)
        : await _put('/api/v1/analytics/reports/$id', data);
    return SavedReport.fromJson(j as Map<String, dynamic>);
  }

  Future<void> deleteReport(String id) => _delete('/api/v1/analytics/reports/$id');

  Future<List<Dashboard>> dashboards() async {
    final j = await _get('/api/v1/analytics/dashboards') as Map<String, dynamic>;
    return [for (final e in j['items'] as List) Dashboard.fromJson(e as Map<String, dynamic>)];
  }

  Future<Dashboard> saveDashboard(Map<String, dynamic> data, {String? id}) async {
    final j = id == null
        ? await _post('/api/v1/analytics/dashboards', data)
        : await _put('/api/v1/analytics/dashboards/$id', data);
    return Dashboard.fromJson(j as Map<String, dynamic>);
  }

  Future<void> deleteDashboard(String id) => _delete('/api/v1/analytics/dashboards/$id');


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

  /// POS: creates AND posts a sale ticket in one call. Either one
  /// [paymentMethod] or several [payments] rows (paiement mixte; the cash row
  /// includes the timbre due on the cash part). A refused sale leaves no draft.
  Future<(DocDetail, List<PosPayment>)> posCheckout({
    required String warehouseId,
    required List<Map<String, dynamic>> lines,
    String? paymentMethod,
    List<PosPayment> payments = const [],
    String? partnerId,
    String? caisseSessionId,
  }) async {
    final j = await _post('/api/v1/pos/checkout', {
      'doc_date': todayISO(),
      'warehouse_id': warehouseId,
      'payment_method': paymentMethod,
      'payments': [for (final p in payments) p.toJson()],
      'partner_id': partnerId,
      'caisse_session_id': caisseSessionId,
      'lines': lines,
    });
    return (
      DocDetail.fromJson(j['document'] as Map<String, dynamic>),
      [
        for (final e in (j['payments'] as List? ?? const []))
          PosPayment.fromJson(e as Map<String, dynamic>)
      ],
    );
  }

  /// POS: last tickets of the open caisse session (with their payment rows).
  Future<List<PosRecentTicket>> posRecentTickets({int limit = 20}) async {
    final j = await _get('/api/v1/pos/recent', {'limit': '$limit'});
    return [
      for (final e in j['items'] as List)
        PosRecentTicket.fromJson(e as Map<String, dynamic>)
    ];
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

  /// Number of caisse sessions ever opened (the server returns the last 60).
  Future<int> caisseSessionCount() async {
    final j = await _get('/api/v1/caisse/sessions');
    return (j['items'] as List? ?? const []).length;
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

  // ---- Produits : photos + modifications groupées ----

  /// Uploads a JPEG/PNG photo (max 2 Mo); returns the updated product.
  Future<Product> uploadProductImage(
      String productId, List<int> bytes, String mime) async {
    final res = await _client.post(
        _u('/api/v1/products/$productId/images'),
        headers: {...authHeaders, 'Content-Type': mime},
        body: bytes);
    return Product.fromJson(_handle(res));
  }

  Future<Product> deleteProductImage(String productId, int index) async =>
      Product.fromJson(
          await _delete('/api/v1/products/$productId/images/$index'));

  Future<Product> setMainProductImage(String productId, int index) async =>
      Product.fromJson(
          await _post('/api/v1/products/$productId/images/$index/main'));

  /// op: set_category | set_vat | set_promo | clear_promo | deactivate |
  /// activate. Returns the number of products updated.
  Future<int> bulkProducts(List<String> ids, String op,
      {Map<String, dynamic> extra = const {}}) async {
    final j = await _post(
        '/api/v1/products/bulk', {'ids': ids, 'op': op, ...extra});
    return (j['updated'] as num?)?.toInt() ?? 0;
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
