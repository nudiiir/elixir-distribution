import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../api/client.dart';

/// What the till needs to know about the chosen customer beyond [Partner]:
/// his group (price list + discount, Paramètres › Clients et fidélité) and his
/// loyalty points. Read straight from the server JSON so the till works with
/// or without the newer Partner model fields.
class PosCustomerInfo {
  const PosCustomerInfo({
    this.groupName,
    this.groupPriceLevel,
    this.groupDiscountPct = 0,
    this.loyaltyEnabled = false,
    this.points = 0,
    this.pointValue = 0,
    this.minRedeem = 0,
    this.canRedeem = false,
  });

  final String? groupName;
  final String? groupPriceLevel; // retail | wholesale, null = no group
  final int groupDiscountPct; // pct × 100
  final bool loyaltyEnabled;
  final int points;
  final int pointValue; // centimes per point
  final int minRedeem;
  final bool canRedeem;

  int get pointsValue => points > 0 ? points * pointValue : 0;
}

Future<dynamic> _getJson(ApiClient api, String path) async {
  final res = await http.get(
    Uri.parse('${api.baseUrl}$path'),
    headers: api.authHeaders,
  );
  final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
  if (res.statusCode >= 400) {
    throw ApiException(
      res.statusCode,
      body is Map && body['error'] != null
          ? '${body['error']}'
          : 'HTTP ${res.statusCode}',
    );
  }
  return body;
}

Future<dynamic> _postJson(ApiClient api, String path, Object? data) async {
  final res = await http.post(
    Uri.parse('${api.baseUrl}$path'),
    headers: {...api.authHeaders, 'Content-Type': 'application/json'},
    body: data == null ? null : jsonEncode(data),
  );
  final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
  if (res.statusCode >= 400) {
    throw ApiException(
      res.statusCode,
      body is Map && body['error'] != null
          ? '${body['error']}'
          : 'HTTP ${res.statusCode}',
    );
  }
  return body;
}

int _int(Object? v) => v is num ? v.toInt() : 0;

/// Group and loyalty of a customer. Missing pieces (older server) read as
/// « no group, no points ».
Future<PosCustomerInfo> loadPosCustomerInfo(
  ApiClient api,
  String partnerId, {
  bool loyalty = true,
}) async {
  String? groupName, groupLevel;
  var groupDiscount = 0;
  try {
    final p = await _getJson(api, '/api/v1/partners/$partnerId');
    if (p is Map) {
      groupName = p['group_name'] as String?;
      groupLevel = p['group_price_level'] as String?;
      groupDiscount = _int(p['group_discount_pct']);
    }
  } catch (_) {}
  var enabled = false, canRedeem = false;
  var points = 0, value = 0, minRedeem = 0;
  if (loyalty) {
    try {
      final l = await _getJson(api, '/api/v1/partners/$partnerId/loyalty');
      if (l is Map) {
        enabled = l['enabled'] == true;
        points = _int(l['balance']);
        value = _int(l['point_value']);
        minRedeem = _int(l['min_redeem']);
        canRedeem = l['can_redeem'] == true;
      }
    } catch (_) {}
  }
  return PosCustomerInfo(
    groupName: groupName,
    groupPriceLevel: groupLevel,
    groupDiscountPct: groupDiscount,
    loyaltyEnabled: enabled,
    points: points,
    pointValue: value,
    minRedeem: minRedeem,
    canRedeem: canRedeem,
  );
}

/// Points used on the current ticket (a « Points fidélité » line).
class PosLoyaltyUse {
  const PosLoyaltyUse(this.redemptionId, this.points, this.value);
  final String redemptionId;
  final int points;
  final int value; // centimes taken off the ticket
}

/// Debits [points] from the customer; the value comes off the ticket.
Future<PosLoyaltyUse> redeemPosPoints(
  ApiClient api,
  String partnerId,
  int points,
) async {
  final j = await _postJson(api, '/api/v1/partners/$partnerId/loyalty/redeem', {
    'points': points,
  });
  return PosLoyaltyUse(
    '${j['redemption_id']}',
    _int(j['points']),
    _int(j['value']),
  );
}

/// Gives the points back (ticket emptied or abandoned).
Future<void> cancelPosPoints(ApiClient api, String redemptionId) async {
  await _postJson(
    api,
    '/api/v1/loyalty/redemptions/$redemptionId/cancel',
    null,
  );
}
