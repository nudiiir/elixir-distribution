import 'dart:convert';
import 'dart:io';

/// Per-machine configuration (server address, ticket printer…), stored in
/// %APPDATA%\ElixirGestion\config.json — NOT on the server, because these
/// differ from one PC to another.
class LocalConfig {
  LocalConfig({this.server = 'http://127.0.0.1:8543', this.ticketPrinter});

  String server;
  String? ticketPrinter;

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\ElixirGestion\\config.json');
  }

  static Future<LocalConfig> load() async {
    try {
      final f = _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return LocalConfig(
          server: (j['server'] as String?) ?? 'http://127.0.0.1:8543',
          ticketPrinter: j['ticket_printer'] as String?,
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
      }));
    } catch (_) {}
  }

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
