import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/approval.dart';
import '../settings/users/switch_user_dialog.dart';

/// Rights at the till (Paramètres › Rôles et permissions) and the manager
/// code. One place so the till reads the same everywhere:
/// - server-enforced actions (discount, price, credit, return, X/Z report) run
///   inside [posWithApproval]: the server answers 403 needs_approval, the
///   manager types his code and the request is replayed with X-Approval;
/// - till-only actions (open the drawer, change a price) ask the code up
///   front with [posRequireRight].
class PosRights {
  PosRights(this.user);
  final User user;

  /// Admins have every right; the others follow their role.
  bool can(String key) => user.isAdmin || user.can(key);

  bool get discount => can('discount');
  bool get priceEdit => can('price_edit');
  bool get creditSale => can('credit_sale');
  bool get refund => can('refund');
  bool get openDrawer => can('open_drawer');
  bool get closeTill => can('close_till');
  bool get viewToday => can('view_today');

  /// Highest discount this user may give alone (percent × 100), null = no cap.
  int? get maxDiscountPct =>
      user.isAdmin ? null : posUserLimit(user, 'max_discount_pct');
}

/// A limit of the user's role (`user.limits`), null when absent or 0
/// (0 = no limit).
int? posUserLimit(User user, String name) {
  final v = user.limit(name);
  return v > 0 ? v : null;
}

/// Runs [run]; when the server asks for the manager code (403
/// needs_approval) the code is asked and [run] replayed with X-Approval.
/// [preApproved]: a token the manager already gave for this sale (sent
/// with the first try; the server asks again if it no longer covers it).
Future<V> posWithApproval<V>(
  BuildContext context,
  ApiClient api,
  Future<V> Function() run, {
  String? preApproved,
}) {
  var first = true;
  return withApproval(context, api, () {
    if (first && preApproved != null) api.approvalToken = preApproved;
    first = false;
    return run();
  });
}

/// The answer of [posRequireRight]: allowed, with the manager's token when
/// the code was typed (null token = the user has the right himself).
class PosGrant {
  const PosGrant([this.token]);
  final String? token;
}

/// Till action that needs [right]: granted when the user has it, or when a
/// manager types his code for it (« Code du gérant »). Null = refused.
Future<PosGrant?> posRequireRight(
  BuildContext context,
  ApiClient api,
  PosRights rights,
  String right, {
  int amount = 0,
}) async {
  if (rights.can(right)) return const PosGrant();
  final a = await showManagerCodeDialog(
    context,
    api,
    action: right,
    amount: amount,
  );
  return a == null ? null : PosGrant(a.token);
}

/// « Changer de caissier » — PIN of another user. Null when cancelled.
Future<Session?> posSwitchUser(BuildContext context, ApiClient api) =>
    showSwitchUserDialog(context, api);

/// Whether « Changer de caissier » is available in this build.
const bool posSwitchUserAvailable = true;
