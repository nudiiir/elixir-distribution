import 'dart:io';

String _two(int n) => n.toString().padLeft(2, '0');

/// Writes a semicolon-separated CSV (UTF-8 BOM, Excel-FR friendly) into
/// Documents\Elixir\exports and reveals it in the Explorer.
/// Returns the file path.
Future<String> exportCsv({
  required String baseName,
  required List<String> headers,
  required List<List<String>> rows,
}) async {
  final home = Platform.environment['USERPROFILE'] ?? '.';
  final dir = Directory('$home\\Documents\\Elixir\\exports');
  await dir.create(recursive: true);
  final t = DateTime.now();
  final stamp =
      '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
  final file = File('${dir.path}\\$baseName-$stamp.csv');

  String esc(String v) =>
      v.contains(';') || v.contains('"') || v.contains('\n')
          ? '"${v.replaceAll('"', '""')}"'
          : v;

  final buf = StringBuffer('﻿');
  buf.writeln(headers.map(esc).join(';'));
  for (final r in rows) {
    buf.writeln(r.map(esc).join(';'));
  }
  await file.writeAsString(buf.toString());
  unawaited(Process.run('explorer.exe', ['/select,${file.path}']));
  return file.path;
}

void unawaited(Future<dynamic> f) {}
