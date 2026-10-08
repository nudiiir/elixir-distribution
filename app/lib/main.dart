import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:window_manager/window_manager.dart';

import 'api/client.dart';
import 'api/models.dart';
import 'screens/login_screen.dart';
import 'shell/app_shell.dart';
import 'theme/tokens.dart';
import 'util/config.dart';
import 'util/prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr');

  // Frameless: the app draws its own top bar, no Windows chrome.
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1280, 820),
    minimumSize: Size(1000, 640),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Elixir Gestion',
  );
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  await UiPrefs.instance.load();
  runApp(const ElixirApp());
}

File _sessionFile() {
  final appData = Platform.environment['APPDATA'] ?? '.';
  return File('$appData\\ElixirGestion\\session.json');
}

class ElixirApp extends StatefulWidget {
  const ElixirApp({super.key});

  @override
  State<ElixirApp> createState() => _ElixirAppState();
}

class _ElixirAppState extends State<ElixirApp> {
  final _api = ApiClient();
  LocalConfig _config = LocalConfig();
  Session? _session;
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    _api.onUnauthorized = () {
      if (_session != null) {
        Future.microtask(() => _logout());
      }
    };
    _restore();
  }

  Future<void> _restore() async {
    _config = await LocalConfig.load();
    _api.baseUrl = _config.server;
    try {
      final f = _sessionFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        final tok = j['token'] as String?;
        if (tok != null && tok.isNotEmpty) {
          _api.token = tok;
          final user = await _api.me();
          _session = Session(tok, user);
        }
      }
    } catch (_) {
      _api.token = null;
      _session = null;
    }
    if (mounted) setState(() => _restoring = false);
  }

  Future<void> _onLoggedIn(Session session) async {
    setState(() => _session = session);
    try {
      final f = _sessionFile();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'token': session.token}));
    } catch (_) {}
  }

  Future<void> _logout() async {
    _api.token = null;
    setState(() => _session = null);
    try {
      final f = _sessionFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_restoring) {
      home = const Scaffold(
        backgroundColor: T.bg,
        body: Center(child: CircularProgressIndicator(color: T.mint)),
      );
    } else if (_session == null) {
      home = LoginScreen(
        api: _api,
        config: _config,
        onLoggedIn: _onLoggedIn,
      );
    } else {
      home = AppShell(
        key: ValueKey(_session!.user.id),
        api: _api,
        config: _config,
        session: _session!,
        onLogout: _logout,
      );
    }
    return MaterialApp(
      title: 'Elixir',
      debugShowCheckedModeBanner: false,
      theme: T.theme(),
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr'), Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );
  }
}
