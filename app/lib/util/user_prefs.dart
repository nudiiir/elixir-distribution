import 'package:flutter/foundation.dart';

import 'prefs.dart';

/// « Mes préférences » — per user, on this PC (stored through [UiPrefs]
/// under the screen key 'prefs').
///
/// - text_scale: 1.0 (Normal) | 1.15 (Grand) | 1.3 (Très grand) — applied
///   app-wide by main.dart through [textScale].
/// - start_module: module key opened after login ('' = default).
/// - compact_lists: default density of every list (DataListView), until the
///   user changes a list's own density.
class UserPrefs {
  UserPrefs._();
  static final UserPrefs instance = UserPrefs._();

  static const screen = 'prefs';

  static const textScales = <(double, String)>[
    (1.0, 'Normal'),
    (1.15, 'Grand'),
    (1.3, 'Très grand'),
  ];

  /// Live text size of the whole app.
  final textScale = ValueNotifier<double>(1.0);

  /// Re-reads the values of the current [UiPrefs.user] (call after login /
  /// logout).
  void reload() {
    final v = UiPrefs.instance.get<num>(screen, 'text_scale')?.toDouble() ?? 1.0;
    textScale.value = textScales.any((e) => e.$1 == v) ? v : 1.0;
  }

  void setTextScale(double v) {
    textScale.value = v;
    UiPrefs.instance.set(screen, 'text_scale', v);
  }

  String get startModule => UiPrefs.instance.get<String>(screen, 'start_module') ?? '';
  set startModule(String v) => UiPrefs.instance.set(screen, 'start_module', v.isEmpty ? null : v);

  bool get compactLists => UiPrefs.instance.get<bool>(screen, 'compact_lists') ?? false;
  set compactLists(bool v) => UiPrefs.instance.set(screen, 'compact_lists', v);
}
