import '../api/models.dart';
import '../theme/tokens.dart' show fmtQty, roundDiv;

/// ESC p 0 — fires the cash-drawer solenoid on the printer's RJ11 port.
const List<int> drawerKick = [0x1B, 0x70, 0x00, 0x19, 0xFA];

/// ESC/POS ticket builder for 80mm thermal printers (42 columns, Font A).
/// Text is ASCII-folded so every cheap printer renders it correctly.
class EscPos {
  static const _width = 42;
  final List<int> _b = [];

  EscPos() {
    _b.addAll([0x1B, 0x40]); // init
  }

  static String fold(String s) {
    const map = {
      'à': 'a', 'â': 'a', 'ä': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'î': 'i', 'ï': 'i', 'ô': 'o', 'ö': 'o', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'À': 'A', 'Â': 'A', 'É': 'E', 'È': 'E', 'Ê': 'E', 'Î': 'I',
      'Ô': 'O', 'Ù': 'U', 'Û': 'U', 'Ç': 'C', 'œ': 'oe', '’': "'",
      '…': '...', '—': '-', '–': '-', '·': '.', '×': 'x', '€': 'EUR',
    };
    final out = StringBuffer();
    for (final ch in s.split('')) {
      final m = map[ch];
      if (m != null) {
        out.write(m);
      } else if (ch.codeUnitAt(0) < 128) {
        out.write(ch);
      } else {
        out.write('?');
      }
    }
    return out.toString();
  }

  void _raw(List<int> bytes) => _b.addAll(bytes);

  void align(int a) => _raw([0x1B, 0x61, a]); // 0 left, 1 center, 2 right
  void bold(bool on) => _raw([0x1B, 0x45, on ? 1 : 0]);
  void doubleSize(bool on) => _raw([0x1D, 0x21, on ? 0x11 : 0x00]);

  void text(String s) {
    _raw(fold(s).codeUnits);
    _raw([0x0A]);
  }

  void row(String left, String right) {
    final l = fold(left);
    final r = fold(right);
    final pad = _width - l.length - r.length;
    text(pad > 0 ? '$l${' ' * pad}$r' : '$l $r');
  }

  void divider([String ch = '-']) => text(ch * _width);

  void feed(int n) => _raw([0x1B, 0x64, n]);
  void cut() => _raw([0x1D, 0x56, 0x42, 0x00]);

  List<int> get bytes => _b;
}

String _da(int centimes) {
  final units = centimes ~/ 100;
  final cents = centimes % 100;
  final s = units.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '$buf,${cents.toString().padLeft(2, '0')}';
}

/// Builds the full 80mm ticket for a posted sale document.
List<int> buildTicket({
  required Map<String, String> company,
  required DocDetail doc,
  required String cashierName,
  int? received,
  int? change,
  List<PosPayment> payments = const [], // paiement mixte : une ligne par moyen
}) {
  final p = EscPos();

  p.align(1);
  p.doubleSize(true);
  p.bold(true);
  p.text(company['company_name']?.isNotEmpty == true
      ? company['company_name']!
      : 'ELIXIR');
  p.doubleSize(false);
  p.bold(false);
  if ((company['company_address'] ?? '').isNotEmpty) {
    p.text(company['company_address']!);
  }
  if ((company['company_phone'] ?? '').isNotEmpty) {
    p.text('Tel: ${company['company_phone']}');
  }
  if ((company['company_nif'] ?? '').isNotEmpty) {
    p.text('NIF: ${company['company_nif']}');
  }
  p.divider('=');

  p.align(0);
  final date = doc.docDate;
  p.row(doc.number ?? '', date);
  p.row('Caisse: $cashierName', '');
  p.divider();

  for (final l in doc.lines) {
    p.text(l.description);
    final unitTTC =
        l.qtyMilli == 0 ? 0 : roundDiv(l.lineTTC * 1000, l.qtyMilli);
    p.row('  ${fmtQty(l.qtyMilli)} x ${_da(unitTTC)}', _da(l.lineTTC));
  }
  p.divider();

  p.row('Sous-total HT', _da(doc.totalHT));
  p.row('TVA', _da(doc.totalVAT));
  if (doc.timbre > 0) p.row('Timbre fiscal', _da(doc.timbre));
  p.bold(true);
  p.doubleSize(true);
  p.row('TOTAL', _da(doc.totalTTC));
  p.doubleSize(false);
  p.bold(false);

  const methods = {
    'cash': 'Especes',
    'cib': 'Carte CIB',
    'edahabia': 'Edahabia',
    'cheque': 'Cheque',
    'transfer': 'Virement',
    'credit': 'Credit',
    'gift': 'Carte cadeau',
  };
  if (payments.isNotEmpty) {
    p.row('Paiement', 'Mixte');
    for (final pay in payments) {
      p.row('  ${methods[pay.method] ?? pay.method}', _da(pay.amount));
    }
  } else {
    p.row('Paiement', methods[doc.paymentMethod] ?? '');
  }
  if (received != null && received > 0) {
    p.row('Recu', _da(received));
    p.row('A rendre', _da(change ?? 0));
  }
  p.divider();
  p.align(1);
  p.text('Merci de votre visite !');
  p.feed(4);
  p.cut();
  return p.bytes;
}
