// Models of the business configuration (Paramètres › Documents, Clients et
// fidélité): numbering, customer groups, loyalty points.

/// Numbering of one document type (GET /config/numbering).
class NumberingRow {
  NumberingRow.fromJson(Map<String, dynamic> j)
      : docType = j['doc_type'] as String,
        label = (j['label'] as String?) ?? '',
        prefix = (j['prefix'] as String?) ?? '',
        includeYear = j['include_year'] == true,
        digits = (j['digits'] as num?)?.toInt() ?? 6,
        resetYearly = j['reset_yearly'] == true,
        year = (j['year'] as num?)?.toInt() ?? DateTime.now().year,
        nextNumber = (j['next_number'] as num?)?.toInt() ?? 1,
        lastIssued = (j['last_issued'] as num?)?.toInt() ?? 0,
        minNext = (j['min_next'] as num?)?.toInt() ?? 1,
        preview = (j['preview'] as String?) ?? '';

  final String docType;
  final String label;
  final String prefix;
  final bool includeYear;
  final int digits;
  final bool resetYearly;
  final int year;
  final int nextNumber;
  final int lastIssued; // 0 = nothing issued yet in this series
  final int minNext;
  final String preview;

  /// Same rule as the server: « FV-2026-000124 ».
  static String format(String prefix, bool year, int digits, int n, {int? y}) => [
        if (prefix.isNotEmpty) prefix,
        if (year) '${y ?? DateTime.now().year}',
        '$n'.padLeft(digits, '0'),
      ].join('-');
}

/// A customer group: price level + default discount.
class CustomerGroup {
  CustomerGroup.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = (j['name'] as String?) ?? '',
        priceLevel = (j['price_level'] as String?) ?? 'retail',
        discountPct = (j['discount_pct'] as num?)?.toInt() ?? 0,
        members = (j['members'] as num?)?.toInt() ?? 0;

  final String id;
  final String name;
  final String priceLevel; // retail | wholesale
  final int discountPct; // ×100
  final int members;
}

/// One line of a customer's points history.
class LoyaltyEntry {
  LoyaltyEntry.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        points = (j['points'] as num?)?.toInt() ?? 0,
        kind = (j['kind'] as String?) ?? '',
        documentId = j['document_id'] as String?,
        number = j['number'] as String?,
        note = j['note'] as String?,
        createdAt = (j['created_at'] as String?) ?? '';

  final String id;
  final int points;
  final String kind; // earn | redeem | void | adjust
  final String? documentId;
  final String? number;
  final String? note;
  final String createdAt;

  String get kindLabel => switch (kind) {
        'earn' => 'Gagnés',
        'redeem' => 'Utilisés',
        'void' => 'Annulation',
        _ => 'Correction',
      };
}

/// GET /partners/{id}/loyalty.
class LoyaltyAccount {
  LoyaltyAccount.fromJson(Map<String, dynamic> j)
      : enabled = j['enabled'] == true,
        balance = (j['balance'] as num?)?.toInt() ?? 0,
        value = (j['value'] as num?)?.toInt() ?? 0,
        pointValue = (j['point_value'] as num?)?.toInt() ?? 0,
        earnPer = (j['earn_per'] as num?)?.toInt() ?? 0,
        minRedeem = (j['min_redeem'] as num?)?.toInt() ?? 0,
        canRedeem = j['can_redeem'] == true,
        history = [
          for (final e in (j['history'] as List? ?? const [])) LoyaltyEntry.fromJson(e as Map<String, dynamic>)
        ];

  final bool enabled;
  final int balance; // points
  final int value; // centimes the balance is worth
  final int pointValue;
  final int earnPer;
  final int minRedeem;
  final bool canRedeem;
  final List<LoyaltyEntry> history;
}

/// POST /partners/{id}/loyalty/redeem.
class LoyaltyRedemption {
  LoyaltyRedemption.fromJson(Map<String, dynamic> j)
      : id = j['redemption_id'] as String,
        points = (j['points'] as num?)?.toInt() ?? 0,
        value = (j['value'] as num?)?.toInt() ?? 0,
        balance = (j['balance'] as num?)?.toInt() ?? 0;

  final String id;
  final int points;
  final int value; // centimes to take off the ticket
  final int balance; // points left
}
