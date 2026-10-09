import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'cloud.dart';

/// Merchant API of the online store (stock-web v3) — see
/// stock-web/docs/DESKTOP_API.md. Kept apart from cloud.dart so the
/// storefront customisation can grow without touching the shared client.
///
/// Every call carries the shop session (Bearer + X-Shop-Id) like the v0.3.0
/// calls of [CloudClient].

/// Error returned by stock-web: the French message to show as-is, plus the
/// detailed validation list (`errors`) and the unknown image ids
/// (`missing_assets`) when the server sent them.
class WebApiException extends CloudException {
  WebApiException(super.message,
      {this.status = 0, this.errors = const [], this.missingAssets = const []});
  final int status;
  final List<String> errors;
  final List<String> missingAssets;
}

/// GET /store/sections.
class WebSectionsInfo {
  WebSectionsInfo.fromJson(Map<String, dynamic> j)
      : sections = [
          for (final s in (j['sections'] as List? ?? const []))
            Map<String, dynamic>.from(s as Map)
        ],
        isDefault = j['is_default'] == true,
        types = [for (final t in (j['types'] as List? ?? const [])) '$t'],
        maxSections = (j['max_sections'] as num?)?.toInt() ?? 30,
        featureIcons = [
          for (final t in (j['feature_icons'] as List? ?? const [])) '$t'
        ];

  final List<Map<String, dynamic>> sections;
  final bool isDefault;
  final List<String> types;
  final int maxSections;
  final List<String> featureIcons;
}

/// One image of the store's media library.
class WebAsset {
  WebAsset.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        name = (j['name'] as String?) ?? '',
        contentType = (j['content_type'] as String?) ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0,
        sha256 = (j['sha256'] as String?) ?? '',
        createdAt = (j['created_at'] as String?) ?? '',
        url = (j['url'] as String?) ?? '';

  final String id;
  final String name;
  final String contentType;
  final int size;
  final String sha256;
  final String createdAt;
  final String url;
}

class WebAssetsInfo {
  WebAssetsInfo.fromJson(Map<String, dynamic> j)
      : items = [
          for (final a in (j['items'] as List? ?? const []))
            WebAsset.fromJson(a as Map<String, dynamic>)
        ],
        usedBytes = (j['used_bytes'] as num?)?.toInt() ?? 0,
        quotaBytes = (j['quota_bytes'] as num?)?.toInt() ?? 209715200,
        maxCount = (j['max_count'] as num?)?.toInt() ?? 300;

  final List<WebAsset> items;
  final int usedBytes;
  final int quotaBytes;
  final int maxCount;
}

/// POST /store/product-images/check result.
class WebImageCheck {
  WebImageCheck.fromJson(Map<String, dynamic> j)
      : upload = [
          for (final e in (j['upload'] as List? ?? const []))
            (
              productId: '${(e as Map)['product_id']}',
              position: (e['position'] as num).toInt(),
              sha256: '${e['sha256']}',
            )
        ],
        delete = [
          for (final e in (j['delete'] as List? ?? const []))
            (
              productId: '${(e as Map)['product_id']}',
              position: (e['position'] as num).toInt(),
            )
        ],
        unchanged = (j['unchanged'] as num?)?.toInt() ?? 0;

  final List<({String productId, int position, String sha256})> upload;
  final List<({String productId, int position})> delete;
  final int unchanged;
}

class WebPromoCode {
  WebPromoCode.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        code = (j['code'] as String?) ?? '',
        type = (j['type'] as String?) ?? 'percent',
        value = (j['value'] as num?)?.toInt() ?? 0,
        minOrderCentimes = (j['min_order_centimes'] as num?)?.toInt() ?? 0,
        startsAt = j['starts_at'] as String?,
        endsAt = j['ends_at'] as String?,
        maxUses = (j['max_uses'] as num?)?.toInt(),
        uses = (j['uses'] as num?)?.toInt() ?? 0,
        active = j['active'] != false;

  final String id;
  final String code;
  final String type; // percent | fixed | free_shipping
  final int value;
  final int minOrderCentimes;
  final String? startsAt;
  final String? endsAt;
  final int? maxUses;
  final int uses;
  final bool active;
}

class WebAlert {
  WebAlert.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as String?) ?? '',
        productId = '${j['product_id'] ?? ''}',
        productName = (j['product_name'] as String?) ?? '',
        phone = (j['phone'] as String?) ?? '',
        name = j['name'] as String?,
        status = (j['status'] as String?) ?? 'open',
        createdAt = (j['created_at'] as String?) ?? '',
        handledAt = j['handled_at'] as String?,
        qtyMilli = (j['qty_milli'] as num?)?.toInt() ?? 0,
        backInStock = j['back_in_stock'] == true;

  final String id;
  final String productId;
  final String productName;
  final String phone;
  final String? name;
  final String status;
  final String createdAt;
  final String? handledAt;
  final int qtyMilli;
  final bool backInStock;
}

class WebPage {
  WebPage.fromJson(Map<String, dynamic> j)
      : slug = (j['slug'] as String?) ?? '',
        title = (j['title'] as String?) ?? '',
        body = (j['body'] as String?) ?? '',
        showInMenu = j['show_in_menu'] == true,
        showInFooter = j['show_in_footer'] != false,
        position = (j['position'] as num?)?.toInt() ?? 0,
        published = j['published'] != false,
        updatedAt = j['updated_at'] as String?;

  final String slug;
  final String title;
  final String body;
  final bool showInMenu;
  final bool showInFooter;
  final int position;
  final bool published;
  final String? updatedAt;
}

class WebPagesInfo {
  WebPagesInfo.fromJson(Map<String, dynamic> j)
      : items = [
          for (final p in (j['items'] as List? ?? const []))
            WebPage.fromJson(p as Map<String, dynamic>)
        ],
        suggestions = [
          for (final p in (j['suggestions'] as List? ?? const []))
            WebPage.fromJson(p as Map<String, dynamic>)
        ],
        maxPages = (j['max_pages'] as num?)?.toInt() ?? 30;

  final List<WebPage> items;
  final List<WebPage> suggestions;
  final int maxPages;
}

class WebDomain {
  WebDomain.fromJson(Map<String, dynamic> j)
      : domain = j['domain'] as String?,
        status = (j['status'] as String?) ?? 'none',
        txtName = (j['txt'] as Map?)?['name'] as String?,
        txtValue = (j['txt'] as Map?)?['value'] as String?,
        cnameName = (j['cname'] as Map?)?['name'] as String?,
        cnameTarget = (j['cname'] as Map?)?['target'] as String?,
        checkedAt = j['checked_at'] as String?,
        verifiedAt = j['verified_at'] as String?,
        url = j['url'] as String?,
        check = j['check'] is Map
            ? Map<String, dynamic>.from(j['check'] as Map)
            : (j['last_check'] is Map
                ? Map<String, dynamic>.from(j['last_check'] as Map)
                : null);

  final String? domain;
  final String status; // none | pending | verified
  final String? txtName;
  final String? txtValue;
  final String? cnameName;
  final String? cnameTarget;
  final String? checkedAt;
  final String? verifiedAt;
  final String? url;

  /// `{txt_ok, cname_ok, points_to_platform, details[]}` of the last check.
  final Map<String, dynamic>? check;
}

class WebStatsDay {
  WebStatsDay.fromJson(Map<String, dynamic> j)
      : day = (j['day'] as String?) ?? '',
        homeViews = (j['home_views'] as num?)?.toInt() ?? 0,
        listingViews = (j['listing_views'] as num?)?.toInt() ?? 0,
        productViews = (j['product_views'] as num?)?.toInt() ?? 0,
        addToCart = (j['add_to_cart'] as num?)?.toInt() ?? 0,
        orders = (j['orders'] as num?)?.toInt() ?? 0,
        quotes = (j['quotes'] as num?)?.toInt() ?? 0;

  final String day;
  final int homeViews;
  final int listingViews;
  final int productViews;
  final int addToCart;
  final int orders;
  final int quotes;

  int get views => homeViews + listingViews + productViews;
}

class WebStats {
  WebStats.fromJson(Map<String, dynamic> j)
      : days = (j['days'] as num?)?.toInt() ?? 30,
        daily = [
          for (final d in (j['daily'] as List? ?? const []))
            WebStatsDay.fromJson(d as Map<String, dynamic>)
        ],
        totals = WebStatsDay.fromJson(
            (j['totals'] as Map<String, dynamic>?) ?? const {}),
        topProducts = [
          for (final p in (j['top_products'] as List? ?? const []))
            (
              productId: '${(p as Map)['product_id']}',
              name: '${p['name'] ?? ''}',
              views: (p['views'] as num?)?.toInt() ?? 0,
              addToCart: (p['add_to_cart'] as num?)?.toInt() ?? 0,
            )
        ];

  final int days;
  final List<WebStatsDay> daily;
  final WebStatsDay totals;
  final List<({String productId, String name, int views, int addToCart})>
      topProducts;
}

extension WebstoreApi on CloudClient {
  Map<String, String> get _h => {
        'Authorization': 'Bearer $token',
        'X-Shop-Id': config.relaySubdomain,
        'Accept': 'application/json',
      };

  Uri _u(String path, [Map<String, String>? query]) {
    final u = Uri.parse('${config.webUrl}/api/v1$path');
    return query == null ? u : u.replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    String? contentType,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final req = http.Request(method, _u(path, query))..headers.addAll(_h);
    if (extraHeaders != null) req.headers.addAll(extraHeaders);
    if (json != null) {
      req.headers['Content-Type'] = 'application/json';
      req.bodyBytes = utf8.encode(jsonEncode(json));
    } else if (bytes != null) {
      req.headers['Content-Type'] = contentType ?? 'application/octet-stream';
      req.bodyBytes = bytes;
    }
    final streamed = await req.send().timeout(timeout);
    final res = await http.Response.fromStream(streamed).timeout(timeout);
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(text);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final msg = j?['error'] is String
          ? j!['error'] as String
          : switch (res.statusCode) {
              401 => 'Session expirée — reconnectez-vous.',
              403 => 'Droit insuffisant pour gérer la boutique.',
              404 => 'Introuvable sur la boutique.',
              413 => 'Fichier trop lourd.',
              429 => 'Trop d’essais — patientez quelques minutes.',
              503 => 'Service boutique indisponible (magasin hors ligne ?).',
              _ => 'Erreur ${res.statusCode}.',
            };
      throw WebApiException(msg,
          status: res.statusCode,
          errors: [for (final e in (j?['errors'] as List? ?? const [])) '$e'],
          missingAssets: [
            for (final e in (j?['missing_assets'] as List? ?? const [])) '$e'
          ]);
    }
    return j ?? const {};
  }

  // ---------------- store ----------------

  Future<WebStore> webSetStatus(String status,
      {String? message, bool clearMessage = false}) async {
    final j = await _call('PUT', '/store/status', json: {
      'status': status,
      'message': ?message,
      if (message == null && clearMessage) 'message': null,
    });
    return WebStore.fromJson(j['store'] as Map<String, dynamic>);
  }

  /// PUT /store/config with any keys (theme/policy are merged server-side).
  Future<WebStore> webConfig(Map<String, dynamic> body) async {
    final j = await _call('PUT', '/store/config', json: body);
    return WebStore.fromJson(j['store'] as Map<String, dynamic>);
  }

  // ---------------- sections ----------------

  Future<WebSectionsInfo> webSections() async =>
      WebSectionsInfo.fromJson(await _call('GET', '/store/sections'));

  /// [sections] null = back to the default layout.
  Future<WebSectionsInfo> webPutSections(
      List<Map<String, dynamic>>? sections) async {
    final j = await _call('PUT', '/store/sections', json: {'sections': sections});
    return WebSectionsInfo.fromJson(j);
  }

  Future<String> webMarkdownPreview(String text) async {
    final j = await _call('POST', '/store/markdown/preview', json: {'text': text});
    return (j['html'] as String?) ?? '';
  }

  // ---------------- assets ----------------

  Future<WebAssetsInfo> webAssets() async =>
      WebAssetsInfo.fromJson(await _call('GET', '/store/assets'));

  Future<WebAsset> webUploadAsset(
      List<int> bytes, String contentType, String name) async {
    final j = await _call('POST', '/store/assets',
        bytes: bytes,
        contentType: contentType,
        query: {'name': name},
        timeout: const Duration(seconds: 60));
    return WebAsset.fromJson(j['asset'] as Map<String, dynamic>);
  }

  Future<void> webDeleteAsset(String id, {bool force = false}) =>
      _call('DELETE', '/store/assets/${Uri.encodeComponent(id)}',
          query: force ? {'force': '1'} : null);

  // ---------------- catalog photos ----------------

  Future<WebImageCheck> webCheckProductImages(
          List<Map<String, dynamic>> items) async =>
      WebImageCheck.fromJson(await _call(
          'POST', '/store/product-images/check',
          json: {'items': items}, timeout: const Duration(minutes: 2)));

  Future<void> webPutProductImage(String productId, int position,
          List<int> bytes, String contentType, String sha256) =>
      _call(
          'PUT',
          '/store/products/${Uri.encodeComponent(productId)}/images/$position',
          bytes: bytes,
          contentType: contentType,
          extraHeaders: {'X-Content-SHA256': sha256},
          timeout: const Duration(seconds: 60));

  Future<void> webDeleteProductImage(String productId, int position) => _call(
      'DELETE',
      '/store/products/${Uri.encodeComponent(productId)}/images/$position');

  // ---------------- promotions ----------------

  Future<List<WebPromoCode>> webPromoCodes() async {
    final j = await _call('GET', '/store/promo-codes');
    return [
      for (final e in (j['items'] as List? ?? const []))
        WebPromoCode.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<WebPromoCode> webSavePromoCode(Map<String, dynamic> body,
      {String? id}) async {
    final j = id == null
        ? await _call('POST', '/store/promo-codes', json: body)
        : await _call('PUT', '/store/promo-codes/${Uri.encodeComponent(id)}',
            json: body);
    return WebPromoCode.fromJson(j['promo'] as Map<String, dynamic>);
  }

  Future<void> webDeletePromoCode(String id) =>
      _call('DELETE', '/store/promo-codes/${Uri.encodeComponent(id)}');

  Future<List<Map<String, dynamic>>> webVolumeRules() async {
    final j = await _call('GET', '/store/volume-rules');
    return [
      for (final r in (j['rules'] as List? ?? const []))
        Map<String, dynamic>.from(r as Map)
    ];
  }

  /// Replaces the whole list of quantity offers shown on the site.
  Future<int> webPutVolumeRules(List<Map<String, dynamic>> rules) async {
    final j = await _call('PUT', '/store/volume-rules', json: {'rules': rules});
    return (j['count'] as num?)?.toInt() ?? rules.length;
  }

  // ---------------- delivery ----------------

  /// (delivery settings or null, wilayas [(code, name)]).
  Future<(Map<String, dynamic>?, List<(String, String)>)> webDelivery() async {
    final j = await _call('GET', '/store/delivery');
    return (
      j['delivery'] is Map
          ? Map<String, dynamic>.from(j['delivery'] as Map)
          : null,
      [
        for (final w in (j['wilayas'] as List? ?? const []))
          ('${(w as Map)['code']}', '${w['name']}')
      ]
    );
  }

  Future<void> webPutDelivery(Map<String, dynamic>? delivery) =>
      _call('PUT', '/store/delivery', json: {'delivery': delivery});

  // ---------------- alerts ----------------

  Future<List<WebAlert>> webAlerts({String status = 'open'}) async {
    final j = await _call('GET', '/store/alerts', query: {'status': status});
    return [
      for (final e in (j['items'] as List? ?? const []))
        WebAlert.fromJson(e as Map<String, dynamic>)
    ];
  }

  Future<void> webHandleAlerts(List<String> ids, {bool reopen = false}) =>
      _call('POST', '/store/alerts/handle',
          json: {'ids': ids, 'status': reopen ? 'open' : 'handled'});

  // ---------------- pages ----------------

  Future<WebPagesInfo> webPages() async =>
      WebPagesInfo.fromJson(await _call('GET', '/store/pages'));

  Future<WebPage> webPutPage(String slug, Map<String, dynamic> body) async {
    final j = await _call('PUT', '/store/pages/${Uri.encodeComponent(slug)}',
        json: body);
    return WebPage.fromJson(j['page'] as Map<String, dynamic>);
  }

  Future<void> webDeletePage(String slug) =>
      _call('DELETE', '/store/pages/${Uri.encodeComponent(slug)}');

  // ---------------- domain ----------------

  Future<WebDomain> webDomain() async =>
      WebDomain.fromJson(await _call('GET', '/store/domain'));

  Future<WebDomain> webPutDomain(String domain) async =>
      WebDomain.fromJson(
          await _call('PUT', '/store/domain', json: {'domain': domain}));

  Future<WebDomain> webVerifyDomain() async => WebDomain.fromJson(
      await _call('POST', '/store/domain/verify',
          timeout: const Duration(seconds: 45)));

  Future<void> webDeleteDomain() => _call('DELETE', '/store/domain');

  // ---------------- stats ----------------

  Future<WebStats> webStats({int days = 30}) async => WebStats.fromJson(
      await _call('GET', '/store/stats', query: {'days': '$days'}));
}

// ---------------------------------------------------------------------------
// Volume rules from the shop server (promo_rules)
// ---------------------------------------------------------------------------

/// Reads the shop's quantity promotions that may be shown on the web
/// (docs/API_DISTRIBUTION.md §3.3 — GET /api/v1/promo-rules/web on the shop
/// server, `{items: PromoRule[], date}`: active today, channel
/// all|web, audience all) and maps them to the storefront's volume-rule shape
/// (§9 of DESKTOP_API.md). Returns (rules, skipped) — skipped explains the
/// rows the site cannot express (fractional quantities…).
Future<(List<Map<String, dynamic>>, List<String>)> fetchWebVolumeRules(
    ApiClient api) async {
  final res = await http
      .get(Uri.parse('${api.baseUrl}/api/v1/promo-rules/web'),
          headers: {...api.authHeaders, 'Accept': 'application/json'})
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    String msg = 'Erreur ${res.statusCode}';
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['error'] is String) msg = j['error'] as String;
    } catch (_) {}
    if (res.statusCode == 404) {
      msg = 'Le serveur du magasin ne connaît pas encore les promotions '
          '(mise à jour nécessaire).';
    }
    throw CloudException(msg);
  }
  final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  return mapPromoRulesToVolumeRules(j['items'] as List? ?? const []);
}

/// Pure mapping PromoRule (shop server) → storefront volume rule.
(List<Map<String, dynamic>>, List<String>) mapPromoRulesToVolumeRules(
    List<dynamic> items) {
  final rules = <Map<String, dynamic>>[];
  final skipped = <String>[];
  final idOk = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
  for (final e in items) {
    final r = Map<String, dynamic>.from(e as Map);
    final name = '${r['name'] ?? r['id']}';
    final scope = '${r['scope'] ?? 'all'}';
    String? scopeValue;
    switch (scope) {
      case 'product':
        scopeValue = r['product_id'] as String?;
      case 'category':
        // The site matches category NAMES (category or parent).
        scopeValue = r['category_name'] as String?;
      case 'brand':
        scopeValue = r['brand'] as String?;
      case 'all':
        scopeValue = null;
      default:
        skipped.add('$name : portée inconnue');
        continue;
    }
    if (scope != 'all' && (scopeValue == null || scopeValue.trim().isEmpty)) {
      skipped.add('$name : cible manquante');
      continue;
    }
    var id = '${r['id'] ?? ''}';
    if (!idOk.hasMatch(id)) {
      id = id.replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '-');
      if (id.length > 64) id = id.substring(0, 64);
      if (id.isEmpty) id = 'R-${rules.length + 1}';
    }
    final minMilli = (r['min_qty_milli'] as num?)?.toInt() ?? 0;
    final out = <String, dynamic>{
      'id': id,
      'scope': scope,
      'scope_value': ?scopeValue,
    };
    final start = r['start_date'] as String?;
    final end = r['end_date'] as String?;
    if (start != null && start.length >= 10) out['starts'] = start.substring(0, 10);
    if (end != null && end.length >= 10) out['ends'] = end.substring(0, 10);
    if (r['type'] == 'free_goods') {
      final freeMilli = (r['free_qty_milli'] as num?)?.toInt() ?? 0;
      if (minMilli % 1000 != 0 || freeMilli % 1000 != 0 ||
          minMilli <= 0 || freeMilli <= 0) {
        skipped.add('$name : unités gratuites non entières');
        continue;
      }
      out['type'] = 'free_goods';
      out['buy_qty'] = minMilli ~/ 1000;
      out['free_qty'] = freeMilli ~/ 1000;
    } else if (r['type'] == 'qty_discount') {
      // discount_pct is in hundredths of a percent (700 = 7 %); the site
      // takes whole percents 1–90.
      final pct = (((r['discount_pct'] as num?)?.toInt() ?? 0) / 100).round();
      final minQty = (minMilli / 1000).ceil();
      if (pct < 1 || minQty < 1) {
        skipped.add('$name : remise trop faible');
        continue;
      }
      out['type'] = 'qty_discount';
      out['min_qty'] = minQty;
      out['percent'] = pct > 90 ? 90 : pct;
    } else {
      skipped.add('$name : type inconnu');
      continue;
    }
    rules.add(out);
  }
  return (rules, skipped);
}

/// « Publier les offres » : fetches the shop's web promotions
/// ([fetchWebVolumeRules]) and replaces the storefront's volume rules with
/// them. Returns (published count, skipped explanations).
Future<(int, List<String>)> publishVolumeRulesFromServer(
    ApiClient api, CloudClient client) async {
  final (rules, skipped) = await fetchWebVolumeRules(api);
  final n = await client.webPutVolumeRules(rules);
  return (n, skipped);
}
