/// Converts amounts to French words — the legally required
/// "montant en lettres" on Algerian invoices (décret 05-468).
library;

const _units = [
  '', 'un', 'deux', 'trois', 'quatre', 'cinq', 'six', 'sept', 'huit', 'neuf',
  'dix', 'onze', 'douze', 'treize', 'quatorze', 'quinze', 'seize',
  'dix-sept', 'dix-huit', 'dix-neuf'
];

String _under100(int n) {
  if (n < 20) return _units[n];
  const tens = {20: 'vingt', 30: 'trente', 40: 'quarante', 50: 'cinquante'};
  if (n < 60) {
    final t = n ~/ 10 * 10;
    final u = n % 10;
    if (u == 0) return tens[t]!;
    if (u == 1) return '${tens[t]!} et un';
    return '${tens[t]!}-${_units[u]}';
  }
  if (n < 80) {
    // 60–79 : soixante, soixante et onze, soixante-douze…
    final u = n - 60;
    if (u == 11) return 'soixante et onze';
    if (u == 1) return 'soixante et un';
    return u == 0 ? 'soixante' : 'soixante-${_units[u]}';
  }
  // 80–99 : quatre-vingts, quatre-vingt-un, quatre-vingt-onze…
  final u = n - 80;
  if (u == 0) return 'quatre-vingts';
  return 'quatre-vingt-${_units[u]}';
}

String _under1000(int n) {
  if (n < 100) return _under100(n);
  final c = n ~/ 100;
  final rest = n % 100;
  final head = c == 1
      ? 'cent'
      : rest == 0
          ? '${_units[c]} cents'
          : '${_units[c]} cent';
  return rest == 0 ? head : '$head ${_under100(rest)}';
}

/// Integer to French words (0 ≤ n < 1e12).
String nombreEnLettres(int n) {
  if (n == 0) return 'zéro';
  final parts = <String>[];
  final milliards = n ~/ 1000000000;
  final millions = (n ~/ 1000000) % 1000;
  final milliers = (n ~/ 1000) % 1000;
  final reste = n % 1000;
  if (milliards > 0) {
    parts.add(milliards == 1
        ? 'un milliard'
        : '${_under1000(milliards)} milliards');
  }
  if (millions > 0) {
    parts.add(
        millions == 1 ? 'un million' : '${_under1000(millions)} millions');
  }
  if (milliers > 0) {
    if (milliers == 1) {
      parts.add('mille');
    } else {
      // "cent" et "quatre-vingt" perdent leur s devant "mille".
      var head = _under1000(milliers);
      if (head.endsWith('cents') || head.endsWith('vingts')) {
        head = head.substring(0, head.length - 1);
      }
      parts.add('$head mille');
    }
  }
  if (reste > 0) parts.add(_under1000(reste));
  return parts.join(' ');
}

/// Centimes → "mille deux cent trente-quatre dinars algériens et cinquante centimes".
String montantEnLettres(int centimes) {
  final dinars = centimes ~/ 100;
  final cents = centimes % 100;
  final d = dinars == 0
      ? 'zéro dinar algérien'
      : '${nombreEnLettres(dinars)} dinar${dinars > 1 ? 's' : ''} algérien${dinars > 1 ? 's' : ''}';
  if (cents == 0) return d;
  return '$d et ${nombreEnLettres(cents)} centime${cents > 1 ? 's' : ''}';
}
