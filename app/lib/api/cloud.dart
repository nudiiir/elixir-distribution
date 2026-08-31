import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Cloud service configuration, served by the shop server so every workstation
/// agrees without local setup.
class CloudConfig {
  CloudConfig({
    this.enrolled = false,
    this.relayEnabled = false,
    this.relayConnected = false,
    this.relayBase = '',
    this.relaySubdomain = '',
    this.llmUrl = '',
    this.invoiceUrl = '',
    this.webUrl = '',
  });

  final bool enrolled;
  final bool relayEnabled;
  final bool relayConnected;
  final String relayBase;
  final String relaySubdomain;
  final String llmUrl;
  final String invoiceUrl;
  final String webUrl;

  CloudConfig.fromJson(Map<String, dynamic> j)
      : enrolled = j['enrolled'] == true,
        relayEnabled = j['relay_enabled'] == true,
        relayConnected = j['relay_connected'] == true,
        relayBase = (j['relay_base'] as String?) ?? '',
        relaySubdomain = (j['relay_subdomain'] as String?) ?? '',
        llmUrl = (j['llm_url'] as String?) ?? '',
        invoiceUrl = (j['invoice_url'] as String?) ?? '',
        webUrl = (j['web_url'] as String?) ?? '';

  /// Cloud features route through the tunnel, so they need it actually up —
  /// not merely switched on.
  bool get llmReady =>
      llmUrl.isNotEmpty && relaySubdomain.isNotEmpty && relayConnected;

  bool get invoiceReady =>
      invoiceUrl.isNotEmpty && relaySubdomain.isNotEmpty && relayConnected;

  bool get webReady =>
      webUrl.isNotEmpty && relaySubdomain.isNotEmpty && relayConnected;
}

// ---------------- Webstore models ----------------

/// The shop's online store as stock-web knows it.
class WebStore {
  WebStore.fromJson(Map<String, dynamic> j)
      : slug = (j['slug'] as String?) ?? '',
        name = (j['name'] as String?) ?? '',
        url = (j['url'] as String?) ?? '',
        theme = (j['theme'] as Map<String, dynamic>?) ?? {},
        policy = (j['policy'] as Map<String, dynamic>?) ?? {},
        hasLogo = j['has_logo'] == true,
        hasCover = j['has_cover'] == true,
        publishedAt = j['published_at'] as String?,
        productCount = (j['product_count'] as num?)?.toInt() ?? 0,
        visibleCount = (j['visible_count'] as num?)?.toInt() ?? 0,
        pendingOrders = (j['pending_orders'] as num?)?.toInt() ?? 0;

  final String slug;
  final String name;
  final String url;
  final Map<String, dynamic> theme;
  final Map<String, dynamic> policy;
  final bool hasLogo;
  final bool hasCover;
  final String? publishedAt;
  final int productCount;
  final int visibleCount;
  final int pendingOrders;
}

/// One published product with its merchant flags.
class WebStoreProduct {
  WebStoreProduct.fromJson(Map<String, dynamic> j)
      : productId = (j['product_id'] as String?) ?? '',
        name = (j['name'] as String?) ?? '',
        category = j['category'] as String?,
        priceCentimes = (j['price_centimes'] as num?)?.toInt() ?? 0,
        promoPriceCentimes = (j['promo_price_centimes'] as num?)?.toInt(),
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        visible = j['visible'] == true,
        hidePrice = j['hide_price'] == true,
        featured = j['featured'] == true;

  final String productId;
  final String name;
  final String? category;
  final int priceCentimes;
  final int? promoPriceCentimes;
  final int qtyMilli;
  bool visible;
  bool hidePrice;
  bool featured;
}

class WebOrderLine {
  WebOrderLine.fromJson(Map<String, dynamic> j)
      : productId = (j['product_id'] as String?) ?? '',
        name = (j['name'] as String?) ?? '',
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        priceCentimes = (j['price_centimes'] as num?)?.toInt() ?? 0;

  final String productId;
  final String name;
  final int qtyMilli;
  final int priceCentimes;
}

class WebOrder {
  WebOrder.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        number = (j['number'] as String?) ?? '',
        customerName = (j['customer_name'] as String?) ?? '',
        phone = (j['phone'] as String?) ?? '',
        wilaya = (j['wilaya'] as String?) ?? '',
        commune = j['commune'] as String?,
        address = j['address'] as String?,
        note = j['note'] as String?,
        totalCentimes = (j['total_centimes'] as num?)?.toInt() ?? 0,
        status = (j['status'] as String?) ?? 'new',
        createdAt = (j['created_at'] as String?) ?? '',
        lines = [
          for (final l in (j['items'] as List? ?? const []))
            WebOrderLine.fromJson(l as Map<String, dynamic>)
        ];

  final String id;
  final String number;
  final String customerName;
  final String phone;
  final String wilaya;
  final String? commune;
  final String? address;
  final String? note;
  final int totalCentimes;
  final String status;
  final String createdAt;
  final List<WebOrderLine> lines;
}

/// One scan waiting in the cloud inbox for this shop.
class InboxItem {
  InboxItem.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        source = (j['source'] as String?) ?? 'mobile',
        supplierName = j['supplier_name'] as String?,
        invoiceNumber = j['invoice_number'] as String?,
        invoiceDate = j['invoice_date'] as String?,
        lineCount = (j['line_count'] as num?)?.toInt() ?? 0,
        createdBy = j['created_by'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';

  final String id;
  final String source;
  final String? supplierName;
  final String? invoiceNumber;
  final String? invoiceDate;
  final int lineCount;
  final String? createdBy;
  final String createdAt;
}

/// A line extracted from a supplier invoice. Only name/qty/price are
/// guaranteed; the rest is whatever the paper happened to carry.
class ScannedLine {
  ScannedLine.fromJson(Map<String, dynamic> j)
      : designation = (j['Designation'] as String?) ?? '',
        qty = ((j['Quantite'] as num?)?.toDouble() ?? 0),
        unitPrice = ((j['PrixUnitaire'] as num?)?.toDouble() ?? 0),
        expiry = j['DatePeremption'] as String?,
        lot = j['Lot'] as String?,
        barcode = j['CodeBarres'] as String?;

  final String designation;
  final double qty;
  final double unitPrice;
  final String? expiry;
  final String? lot;
  final String? barcode;

  int get qtyMilli => (qty * 1000).round();
  int get unitPriceCentimes => (unitPrice * 100).round();
}

class ScannedInvoice {
  ScannedInvoice.fromJson(Map<String, dynamic> j)
      : supplierName = (j['Entete']?['NomFournisseur'] as String?),
        invoiceNumber = (j['Entete']?['NumeroFacture'] as String?),
        invoiceDate = (j['Entete']?['DateFacture'] as String?),
        lines = [
          for (final l in (j['Lignes'] as List? ?? const []))
            ScannedLine.fromJson(l as Map<String, dynamic>)
        ];

  final String? supplierName;
  final String? invoiceNumber;
  final String? invoiceDate;
  final List<ScannedLine> lines;
}

class CloudException implements Exception {
  CloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Client for the cloud services. Every call carries the user's own shop token
/// plus X-Shop-Id; the services verify it against this shop's server, so the
/// same permissions apply as in the desktop app.
class CloudClient {
  CloudClient({required this.config, required this.token});

  final CloudConfig config;
  final String token;
  final _client = http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'X-Shop-Id': config.relaySubdomain,
        'Accept': 'application/json',
      };

  // ---------------- Invoice inbox ----------------

  Future<List<InboxItem>> inbox() async {
    final res = await _client
        .get(Uri.parse('${config.invoiceUrl}/api/v1/inbox'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final e in (j['items'] as List? ?? const []))
        InboxItem.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<ScannedInvoice> inboxItem(String id) async {
    final res = await _client
        .get(Uri.parse('${config.invoiceUrl}/api/v1/inbox/$id'),
            headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return ScannedInvoice.fromJson(j['result'] as Map<String, dynamic>);
  }

  Future<void> inboxAck(String id, {bool discard = false}) async {
    final action = discard ? 'discard' : 'ack';
    final res = await _client
        .post(Uri.parse('${config.invoiceUrl}/api/v1/inbox/$id/$action'),
            headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw CloudException(_err(res));
  }

  // ---------------- Webstore ----------------

  Future<WebStore?> webStore() async {
    final res = await _client
        .get(Uri.parse('${config.webUrl}/api/v1/store'), headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final s = j['store'];
    return s == null ? null : WebStore.fromJson(s as Map<String, dynamic>);
  }

  Future<(bool, String?)> webCheckSlug(String slug) async {
    final res = await _client
        .post(Uri.parse('${config.webUrl}/api/v1/store/check'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'slug': slug}))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (j['available'] == true, j['reason'] as String?);
  }

  Future<WebStore> webClaim(String slug, String name) async {
    final res = await _client
        .post(Uri.parse('${config.webUrl}/api/v1/store/claim'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'slug': slug, 'name': name}))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 201) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return WebStore.fromJson(j['store'] as Map<String, dynamic>);
  }

  Future<WebStore> webPutConfig(
      {String? name,
      Map<String, dynamic>? theme,
      Map<String, dynamic>? policy}) async {
    final res = await _client
        .put(Uri.parse('${config.webUrl}/api/v1/store/config'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': ?name,
              'theme': ?theme,
              'policy': ?policy,
            }))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return WebStore.fromJson(j['store'] as Map<String, dynamic>);
  }

  Future<void> webUploadImage(
      String kind, List<int> bytes, String contentType) async {
    final res = await _client
        .post(Uri.parse('${config.webUrl}/api/v1/store/$kind'),
            headers: {..._headers, 'Content-Type': contentType},
            body: bytes)
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) throw CloudException(_err(res));
  }

  Future<int> webPublishCatalog(List<Map<String, dynamic>> products) async {
    final res = await _client
        .put(Uri.parse('${config.webUrl}/api/v1/store/catalog'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'products': products}))
        .timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (j['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> webPushStock(List<Map<String, dynamic>> items) async {
    final res = await _client
        .put(Uri.parse('${config.webUrl}/api/v1/store/stock'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'items': items}))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw CloudException(_err(res));
  }

  Future<List<WebStoreProduct>> webStoreProducts() async {
    final res = await _client
        .get(Uri.parse('${config.webUrl}/api/v1/store/products'),
            headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final e in (j['items'] as List? ?? const []))
        WebStoreProduct.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<void> webPutFlags(List<Map<String, dynamic>> items) async {
    final res = await _client
        .put(Uri.parse('${config.webUrl}/api/v1/store/products'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'items': items}))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw CloudException(_err(res));
  }

  Future<List<WebOrder>> webOrders({String status = 'new'}) async {
    final res = await _client
        .get(Uri.parse('${config.webUrl}/api/v1/store/orders?status=$status'),
            headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw CloudException(_err(res));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final e in (j['items'] as List? ?? const []))
        WebOrder.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<void> webAckOrder(String id, {bool accept = true}) async {
    final res = await _client
        .post(Uri.parse('${config.webUrl}/api/v1/store/orders/$id/ack'),
            headers: {..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'action': accept ? 'accept' : 'reject'}))
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw CloudException(_err(res));
  }

  // ---------------- Assistant (SSE) ----------------

  /// Streams the assistant's answer. Yields ('text', delta) for content and
  /// ('tool', name) when a tool runs, so the UI can show what it is doing.
  Stream<(String, String)> chat(
      List<({String role, String content})> history) async* {
    final req = http.Request('POST', Uri.parse('${config.llmUrl}/chat'))
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'messages': [
          for (final m in history) {'role': m.role, 'content': m.content}
        ],
      });

    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw CloudException(_errBody(res.statusCode, body));
    }

    var event = '';
    await for (final chunk
        in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (chunk.startsWith('event:')) {
        event = chunk.substring(6).trim();
      } else if (chunk.startsWith('data:')) {
        final raw = chunk.substring(5).trim();
        if (raw.isEmpty) continue;
        Map<String, dynamic> data;
        try {
          data = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        switch (event) {
          case 'text':
            final d = data['delta'] as String?;
            if (d != null && d.isNotEmpty) yield ('text', d);
          case 'tool-start':
            yield ('tool', (data['name'] as String?) ?? '');
          case 'error':
            throw CloudException(
                (data['message'] as String?) ?? 'erreur de l\'assistant');
          case 'done':
            return;
        }
      }
    }
  }

  String _err(http.Response res) =>
      _errBody(res.statusCode, utf8.decode(res.bodyBytes));

  String _errBody(int status, String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final msg = j['error'] ?? j['detail'];
      if (msg is String) return msg;
    } catch (_) {}
    return switch (status) {
      401 => 'Session expirée.',
      403 => 'Droit insuffisant.',
      503 => 'Service indisponible.',
      _ => 'Erreur $status.',
    };
  }

  void close() => _client.close();
}
