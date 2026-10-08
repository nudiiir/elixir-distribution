import 'dart:convert';
import 'dart:io';

/// Per-machine configuration (server address, printers, cash drawer, scale
/// barcodes…), stored in %APPDATA%\ElixirGestion\config.json — NOT on the
/// server, because these differ from one PC to another.
class LocalConfig {
  LocalConfig({
    this.server = 'http://127.0.0.1:8543',
    this.ticketPrinter,
    this.a4Printer,
    this.labelPrinter,
    this.openDrawerOnCash = true,
    this.scaleWeightPrefix = '21',
    this.scalePricePrefix = '22',
  });

  String server;

  /// Thermal 80 mm printer (raw ESC/POS). Null = no ticket printing.
  String? ticketPrinter;

  /// Printer for A4 documents (invoices, quotes…). Null = Windows default.
  String? a4Printer;

  /// Label printer (product labels). Null = Windows default.
  String? labelPrinter;

  /// Pop the cash drawer (wired to the ticket printer) after a cash sale.
  /// Combined with the shop-wide `pos_open_drawer` setting.
  bool openDrawerOnCash;

  /// Scale barcodes (EAN-13 "2P PPPPP VVVVV C"): prefix whose value is a
  /// weight in grams, and prefix whose value is a price in centimes.
  String scaleWeightPrefix;
  String scalePricePrefix;

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\ElixirGestion\\config.json');
  }

  static String _prefix(Object? v, String fallback) {
    final s = (v as String?)?.trim() ?? '';
    return RegExp(r'^\d{2}$').hasMatch(s) ? s : fallback;
  }

  static Future<LocalConfig> load() async {
    try {
      final f = _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return LocalConfig(
          server: (j['server'] as String?) ?? 'http://127.0.0.1:8543',
          ticketPrinter: j['ticket_printer'] as String?,
          a4Printer: j['a4_printer'] as String?,
          labelPrinter: j['label_printer'] as String?,
          openDrawerOnCash: j['open_drawer_on_cash'] as bool? ?? true,
          scaleWeightPrefix: _prefix(j['scale_weight_prefix'], '21'),
          scalePricePrefix: _prefix(j['scale_price_prefix'], '22'),
        );
      }
    } catch (_) {}
    return LocalConfig();
  }

  Future<void> save() async {
    try {
      final f = _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'server': server,
        'ticket_printer': ticketPrinter,
        'a4_printer': a4Printer,
        'label_printer': labelPrinter,
        'open_drawer_on_cash': openDrawerOnCash,
        'scale_weight_prefix': scaleWeightPrefix,
        'scale_price_prefix': scalePricePrefix,
      }));
    } catch (_) {}
  }

  /// Regex matching a scale barcode with this PC's prefixes: group 1 =
  /// prefix, 2 = article code (PLU), 3 = value (grams or centimes).
  RegExp get scaleBarcode => RegExp(
      '^(${RegExp.escape(scaleWeightPrefix)}|${RegExp.escape(scalePricePrefix)})(\\d{5})(\\d{5})\\d\$');

  /// True when [prefix] (group 1 of [scaleBarcode]) carries a weight.
  bool isWeightPrefix(String prefix) => prefix == scaleWeightPrefix;

  /// Normalizes user input ("192.168.1.10", "pc-magasin:8543"…) to a base URL.
  static String normalizeServer(String input) {
    var s = input.trim();
    if (s.isEmpty) return 'http://127.0.0.1:8543';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    final uri = Uri.parse(s);
    final port = uri.hasPort ? uri.port : 8543;
    return '${uri.scheme}://${uri.host}:$port';
  }
}
