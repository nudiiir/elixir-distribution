/// Analyse GS1-128 : un seul scan du carton remplit produit, lot, DLC et
/// quantité — la différence entre une réception de quarante minutes et une de
/// cinq. Identifiants d'application gérés :
///   (01) GTIN-14  → code produit
///   (10) n° de lot (longueur variable, terminé par GS)
///   (17) DLC AAMMJJ
///   (37) quantité (longueur variable)
/// Le séparateur FNC1 arrive du scanner comme ASCII 29 (GS) ; certains
/// scanners préfixent «]C1».
class Gs1Data {
  Gs1Data({this.gtin, this.lot, this.expiry, this.qty});
  final String? gtin;
  final String? lot;
  final String? expiry; // YYYY-MM-DD
  final int? qty; // unités entières

  bool get hasAnything => gtin != null || lot != null || expiry != null || qty != null;
}

const _gs = '';

/// Les AI à longueur fixe n'ont pas de séparateur ; les variables se terminent
/// au GS ou à la fin de chaîne.
const _fixedLen = {
  '01': 14, '02': 14, '11': 6, '13': 6, '15': 6, '17': 6, '20': 2,
};

/// Tente de lire une chaîne GS1-128. Renvoie null si ce n'est visiblement pas
/// du GS1 (un EAN-13 nu, par exemple).
Gs1Data? parseGs1(String raw) {
  var s = raw.trim();
  if (s.startsWith(']C1') || s.startsWith(']c1')) s = s.substring(3);
  s = s.replaceAll('', _gs);
  // Un GS1 plausible commence par un AI connu et fait plus long qu'un EAN-13.
  if (s.length <= 14 || !RegExp(r'^\(?\d\d').hasMatch(s)) return null;

  // Format lisible «(01)0613...(10)L25» : retirer les parenthèses en insérant
  // des GS avant chaque AI variable.
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
      // AI inconnu : on ne peut plus avancer de façon fiable.
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
  // GS1 : jour 00 = fin de mois.
  if (dd == 0) dd = DateTime(2000 + yy, mm + 1, 0).day;
  return '${2000 + yy}-${mm.toString().padLeft(2, '0')}-${dd.toString().padLeft(2, '0')}';
}

/// Le GTIN-14 d'un scan GS1 contre les codes-barres stockés (EAN-13) : on
/// compare sans l'indicateur logistique de tête ni les zéros de gauche.
bool gtinMatches(String gtin14, String barcode) {
  String norm(String v) {
    var s = v.replaceAll(RegExp(r'\D'), '');
    while (s.length > 13 && s.startsWith('0')) {
      s = s.substring(1);
    }
    if (s.length == 14) s = s.substring(1); // indicateur logistique
    while (s.startsWith('0') && s.length > 8) {
      s = s.substring(1);
    }
    return s;
  }

  return norm(gtin14) == norm(barcode);
}
