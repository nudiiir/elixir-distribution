import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'cloud.dart';
import 'dist_api.dart';

/// Web orders ⇄ customer orders (stock-web/docs/DESKTOP_API.md §11 and
/// docs/API_DISTRIBUTION.md §2.9):
/// - « Importer » sends a storefront order to POST /orders/import-web
///   (idempotent on the storefront id), then acknowledges it on the site;
/// - the status of imported orders is pushed back to the site in batch
///   (POST /store/orders/status), then cleared on the shop server.

final _http = http.Client();
const _timeout = Duration(seconds: 25);

/// Shop setting: import new web orders automatically ('1').
const webAutoImportSetting = 'web_orders_auto_import';

Map<String, String> _headers(CloudClient c) => {
      'Authorization': 'Bearer ${c.token}',
      'X-Shop-Id': c.config.relaySubdomain,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };

String _err(http.Response r) {
  try {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map && j['error'] is String) return j['error'] as String;
  } catch (_) {}
  return switch (r.statusCode) {
    401 => 'Session expirée — reconnectez-vous.',
    403 => 'Droit insuffisant pour gérer la boutique.',
    503 => 'Service boutique indisponible (magasin hors ligne ?).',
    _ => 'Erreur ${r.statusCode} de la boutique.',
  };
}

/// Storefront orders, raw JSON (every field of §11 kept).
/// [status]: new | open | all… ; [kind]: all | order | quote_request.
Future<List<Map<String, dynamic>>> fetchStoreOrders(CloudClient c,
    {String status = 'new', String kind = 'all', int limit = 200}) async {
  final uri = Uri.parse('${c.config.webUrl}/api/v1/store/orders')
      .replace(queryParameters: {'status': status, 'kind': kind, 'limit': '$limit'});
  final res = await _http.get(uri, headers: _headers(c)).timeout(_timeout);
  if (res.statusCode != 200) throw CloudException(_err(res));
  final j = jsonDecode(utf8.decode(res.bodyBytes));
  return [
    for (final e in (j is Map ? (j['items'] as List? ?? const []) : const []))
      if (e is Map) Map<String, dynamic>.from(e)
  ];
}

Future<void> ackStoreOrder(CloudClient c, String id, {bool accept = true}) async {
  final res = await _http
      .post(Uri.parse('${c.config.webUrl}/api/v1/store/orders/$id/ack'),
          headers: _headers(c), body: jsonEncode({'action': accept ? 'accept' : 'reject'}))
      .timeout(_timeout);
  // 404 = already handled on the site: nothing to do.
  if (res.statusCode != 200 && res.statusCode != 404) throw CloudException(_err(res));
}

/// POST /store/orders/status — returns the ids (as sent) that succeeded.
Future<Set<String>> pushStoreStatuses(CloudClient c, List<Map<String, dynamic>> updates) async {
  if (updates.isEmpty) return const {};
  final res = await _http
      .post(Uri.parse('${c.config.webUrl}/api/v1/store/orders/status'),
          headers: _headers(c), body: jsonEncode({'updates': updates}))
      .timeout(_timeout);
  if (res.statusCode != 200) throw CloudException(_err(res));
  final j = jsonDecode(utf8.decode(res.bodyBytes));
  return {
    for (final r in (j is Map ? (j['results'] as List? ?? const []) : const []))
      if (r is Map && r['ok'] == true) '${r['order_id']}'
  };
}

bool isQuoteRequest(Map<String, dynamic> o) => o['kind'] == 'quote_request';

/// Storefront order → WebOrderPayload of the shop server.
/// Free-goods lines (`is_free`) are dropped: the server adds its own UG.
/// A quote request carries no reliable price: the shop prices it.
Map<String, dynamic> webImportPayload(Map<String, dynamic> o) {
  final quote = isQuoteRequest(o);
  final notes = <String>[
    if (quote) 'Demande de devis du site — prix à confirmer au client.',
    if ((o['note'] ?? '').toString().trim().isNotEmpty) '${o['note']}'.trim(),
    if (o['preferred_date'] != null) 'Date souhaitée : ${o['preferred_date']}',
    if (o['delivery_method'] == 'pickup') 'Retrait en magasin.',
    if (o['shipping_centimes'] == null && !quote) 'Frais de livraison à confirmer par téléphone.',
  ];
  return {
    'id': '${o['id']}',
    'number': '${o['number'] ?? ''}',
    'customer_name': o['customer_name'] ?? '',
    'phone': o['phone'] ?? '',
    'email': o['email'] ?? '',
    'customer_type': o['customer_type'] ?? '',
    'business_name': o['business_name'] ?? '',
    'nif': o['nif'] ?? '',
    'wilaya': o['wilaya'] ?? '',
    'commune': o['commune'] ?? '',
    'address': o['address'] ?? '',
    'note': notes.join('\n'),
    'items': [
      for (final l in (o['items'] as List? ?? const []))
        if (l is Map && l['is_free'] != true)
          {
            'product_id': '${l['product_id']}',
            'name': l['name'] ?? '',
            'qty_milli': (l['qty_milli'] as num?)?.toInt() ?? 0,
            if (!quote && l['price_centimes'] is num) 'price_centimes': (l['price_centimes'] as num).toInt(),
          }
    ],
    'shipping_fee_centimes': quote ? 0 : (o['shipping_centimes'] as num?)?.toInt() ?? 0,
    'discount_centimes': quote ? 0 : (o['discount_centimes'] as num?)?.toInt() ?? 0,
    'promo_code': o['promo_code'] ?? '',
    'created_at': o['created_at'] ?? '',
    if (!quote) 'total_centimes': (o['total_centimes'] as num?)?.toInt() ?? 0,
  };
}

/// Imports one storefront order into the shop (idempotent) and accepts it
/// on the site when it was still « new ».
Future<({CustomerOrder order, bool created, bool partnerCreated, List<String> warnings})> importStoreOrder(
    ApiClient api, CloudClient c, Map<String, dynamic> o) async {
  final r = await api.importWebOrder(webImportPayload(o));
  if (o['status'] == 'new') {
    try {
      await ackStoreOrder(c, '${o['id']}');
    } catch (_) {
      // The status sync will push « accepted » later.
    }
  }
  return r;
}

/// Shop status → storefront status.
String storeStatusFor(String s) => s == 'new' ? 'accepted' : s;

/// Customer-friendly note for the tracking page (never internal notes).
String _publicNote(WebSyncItem i) => switch (i.status) {
      'cancelled' => i.cancelReason.isEmpty ? 'Commande annulée' : 'Commande annulée : ${i.cancelReason}',
      'validated' => 'Commande confirmée',
      'preparing' => 'Commande en préparation',
      'ready' => 'Commande prête',
      'shipping' => 'En cours de livraison',
      'delivered' => 'Commande livrée',
      'invoiced' => 'Commande facturée',
      _ => '',
    };

/// Pushes the changed statuses of imported web orders to the site, then
/// clears them on the shop server. Returns how many were synced. Never
/// throws for « nothing to do ».
Future<int> syncWebOrderStatuses(ApiClient api, CloudClient c) async {
  final items = await api.webSyncList();
  if (items.isEmpty) return 0;
  final todo = [for (final i in items) if (i.externalRef.isNotEmpty || i.externalNumber.isNotEmpty) i];
  if (todo.isEmpty) return 0;
  final updates = [
    for (final i in todo)
      {
        'order_id': i.externalRef.isNotEmpty ? i.externalRef : i.externalNumber,
        'status': storeStatusFor(i.status),
        if (_publicNote(i).isNotEmpty) 'note': _publicNote(i),
        if (i.lastEventAt.isNotEmpty) 'at': i.lastEventAt,
      }
  ];
  final ok = <String>{};
  for (var k = 0; k < updates.length; k += 500) {
    ok.addAll(await pushStoreStatuses(c, updates.sublist(k, (k + 500).clamp(0, updates.length))));
  }
  final done = [
    for (final i in todo)
      if (ok.contains(i.externalRef) || ok.contains(i.externalNumber)) (id: i.id, status: i.status)
  ];
  if (done.isEmpty) return 0;
  return api.webSyncAck(done);
}

/// Imports every « new » storefront order (orders and quote requests).
/// Returns the numbers created.
Future<List<String>> autoImportWebOrders(ApiClient api, CloudClient c) async {
  final orders = await fetchStoreOrders(c, status: 'new');
  final created = <String>[];
  for (final o in orders) {
    try {
      final r = await importStoreOrder(api, c, o);
      if (r.created) created.add(r.order.number);
    } catch (_) {
      // One bad order must not block the others; it stays « new » on the
      // site and is shown in Boutique › Commandes.
    }
  }
  return created;
}

/// One heartbeat of the shell: optional auto-import, then status push.
/// Silent: offline / no store / no right → nothing happens.
Future<void> webOrdersHeartbeat(ApiClient api, {required bool canManage}) async {
  try {
    if (api.token == null) return;
    final cloud = await api.cloudStatus();
    if (!cloud.webReady) return;
    final c = CloudClient(config: cloud, token: api.token!);
    if (canManage) {
      try {
        final s = await api.settings();
        if (s[webAutoImportSetting] == '1') await autoImportWebOrders(api, c);
      } catch (_) {}
    }
    await syncWebOrderStatuses(api, c);
  } catch (_) {
    // Hors ligne, pas de boutique… le prochain battement réessaiera.
  }
}
