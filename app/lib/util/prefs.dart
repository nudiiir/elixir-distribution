import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Per-user, per-screen UI preferences (visible columns, density, last
/// filters, last period…), kept on THIS machine in
/// %APPDATA%\ElixirGestion\ui_prefs.json. Never sent to the server: they are
/// comfort settings, not shop data.
///
/// Keys are namespaced `<userId>/<screen>/<key>`. Reads are synchronous once
/// [load] has run; writes are debounced to disk.
class UiPrefs {
  UiPrefs._();
  static final UiPrefs instance = UiPrefs._();

  /// Set at login so two cashiers on one PC keep their own layouts.
  String user = 'default';

  Map<String, dynamic> _data = {};
  Timer? _flush;

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\ElixirGestion\\ui_prefs.json');
  }

  Future<void> load() async {
    try {
      final f = _file();
      if (await f.exists()) {
        _data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      _data = {};
    }
  }

  String _k(String screen, String key) => '$user/$screen/$key';

  T? get<T>(String screen, String key) {
    final v = _data[_k(screen, key)];
    return v is T ? v : null;
  }

  List<String>? getList(String screen, String key) {
    final v = _data[_k(screen, key)];
    return v is List ? [for (final e in v) e.toString()] : null;
  }

  void set(String screen, String key, Object? value) {
    if (value == null) {
      _data.remove(_k(screen, key));
    } else {
      _data[_k(screen, key)] = value;
    }
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    try {
      final f = _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_data));
    } catch (_) {}
  }
}
