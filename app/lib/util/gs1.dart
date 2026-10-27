/// GS1-128 parsing: a single scan of the carton fills product, lot, expiry date and
/// quantity — the difference between a forty-minute receipt and a
/// five-minute one. Application identifiers handled:
///   (01) GTIN-14  → product code
///   (10) lot number (variable length, terminated by GS)
///   (17) expiry date YYMMDD
///   (37) quantity (variable length)
/// The FNC1 separator comes from the scanner as ASCII 29 (GS); some
/// scanners prefix «]C1».
class Gs1Data {
  Gs1Data({this.gtin, this.lot, this.expiry, this.qty});
  final String? gtin;
  final String? lot;
  final String? expiry; // YYYY-MM-DD
  final int? qty; // whole units

  bool get hasAnything => gtin != null || lot != null || expiry != null || qty != null;
}

const _gs = '';

/// Fixed-length AIs have no separator; variable ones end
/// at GS or at the end of the string.
const _fixedLen = {
  '01': 14, '02': 14, '11': 6, '13': 6, '15': 6, '17': 6, '20': 2,
};

/// Tries to read a GS1-128 string. Returns null if it is clearly not
/// GS1 (a bare EAN-13, for example).
Gs1Data? parseGs1(String raw) {
  var s = raw.trim();
  if (s.startsWith(']C1') || s.startsWith(']c1')) s = s.substring(3);
  s = s.replaceAll('', _gs);
  // A plausible GS1 starts with a known AI and is longer than an EAN-13.
  if (s.length <= 14 || !RegExp(r'^\(?\d\d').hasMatch(s)) return null;

  // Human-readable format «(01)0613...(10)L25»: remove the parentheses, inserting
  // GS before each variable AI.
  if (s.contains('(')) {
    s = s.replaceAllMapped(RegExp(r'\((\d{2,4})\)'), (m) => _gs + m.group(1)!);
    if (s.startsWith(_gs)) s = s.substring(1);
    s = s.replaceAll(RegExp('$_gs+'), _gs);
  }

  String? gtin, lot, expiry;
  int? qty;
  var i = 0;
  var matched = false;
  while (i < s.length) {
    if (s[i] == _gs) {
      i++;
      continue;
    }
    if (i + 2 > s.length) break;
    final ai = s.substring(i, i + 2);
    final fixed = _fixedLen[ai];
    if (fixed != null) {
      if (i + 2 + fixed > s.length) break;
      final v = s.substring(i + 2, i + 2 + fixed);
      if (!RegExp(r'^\d+$').hasMatch(v)) break;
      if (ai == '01' || ai == '02') gtin = v;
      if (ai == '17') expiry = _yymmdd(v);
      i += 2 + fixed;
      matched = true;
    } else if (ai == '10' || ai == '37' || ai == '21' || ai == '30') {
      final end = s.indexOf(_gs, i + 2);
      final v = s.substring(i + 2, end == -1 ? s.length : end);
      if (ai == '10') lot = v;
      if (ai == '37' || ai == '30') qty = int.tryParse(v);
      i = end == -1 ? s.length : end + 1;
      matched = true;
    } else {
      // Unknown AI: we can no longer advance reliably.
      break;
    }
  }
  if (!matched || (gtin == null && lot == null)) return null;
  return Gs1Data(gtin: gtin, lot: lot, expiry: expiry, qty: qty);
}

String? _yymmdd(String v) {
  if (v.length != 6) return null;
  final yy = int.tryParse(v.substring(0, 2));
  final mm = int.tryParse(v.substring(2, 4));
  var dd = int.tryParse(v.substring(4, 6));
  if (yy == null || mm == null || dd == null || mm < 1 || mm > 12) return null;
  // GS1: day 00 = end of month.
  if (dd == 0) dd = DateTime(2000 + yy, mm + 1, 0).day;
  return '${2000 + yy}-${mm.toString().padLeft(2, '0')}-${dd.toString().padLeft(2, '0')}';
}

/// The GTIN-14 of a GS1 scan against the stored barcodes (EAN-13): compared
/// without the leading logistic indicator or the leading zeros.
bool gtinMatches(String gtin14, String barcode) {
  String norm(String v) {
    var s = v.replaceAll(RegExp(r'\D'), '');
    while (s.length > 13 && s.startsWith('0')) {
      s = s.substring(1);
    }
    if (s.length == 14) s = s.substring(1); // logistic indicator
    while (s.startsWith('0') && s.length > 8) {
      s = s.substring(1);
    }
    return s;
  }

  return norm(gtin14) == norm(barcode);
}
