import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/config.dart';
import '../widgets/ui.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.api,
    required this.config,
    required this.onLoggedIn,
  });
  final ApiClient api;
  final LocalConfig config;
  final ValueChanged<Session> onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session =
          await widget.api.login(_username.text.trim(), _password.text);
      widget.onLoggedIn(session);
    } on ApiException catch (e) {
      setState(() => _error =
          e.status == 401 ? 'Identifiants invalides.' : e.message);
    } catch (_) {
      setState(() =>
          _error = 'Serveur injoignable. Vérifiez que le serveur est lancé.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      body: Stack(children: [
        // Frameless window: the top edge drags, and a close button sits in
        // the corner.
        const Positioned(
          top: 0,
          left: 0,
          right: 48,
          height: 44,
          child: DragToMoveArea(child: SizedBox.expand()),
        ),
        PositionedDirectional(
          top: 8,
          end: 8,
          child: IconButton(
            onPressed: () => windowManager.close(),
            tooltip: 'Fermer',
            icon: const Icon(Icons.close, size: 18, color: T.faint),
          ),
        ),
        // Soft mint glow at the bottom, echoes the brand.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 220,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    T.mint.withValues(alpha: 0.12),
                    T.mint.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 380,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: T.border),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x14141414),
                    blurRadius: 30,
                    offset: Offset(0, 10)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Image.asset('assets/images/elixir-logo.png',
                      height: 96, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text('Gestion commerciale',
                      style: T.label.copyWith(fontSize: 14)),
                ),
                const SizedBox(height: 26),
                const MicroLabel('Utilisateur'),
                const SizedBox(height: 5),
                _LoginField(
                  controller: _username,
                  autofocus: true,
                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                ),
                const SizedBox(height: 12),
                const MicroLabel('Mot de passe'),
                const SizedBox(height: 5),
                _LoginField(
                  controller: _password,
                  focusNode: _passwordFocus,
                  obscure: true,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: T.small.copyWith(color: T.dangerDark),
                      textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                PrimaryButton(
                  label: _busy ? 'Connexion…' : 'Se connecter',
                  big: true,
                  onPressed: _busy ? null : _submit,
                ),
                const SizedBox(height: 16),
                Center(
                  child: InkWell(
                    onTap: _editServer,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.dns_outlined,
                            size: 15, color: T.faint),
                        const SizedBox(width: 6),
                        Text('Serveur : ', style: T.small),
                        Text(
                            widget.api.baseUrl
                                .replaceFirst('http://', ''),
                            style: T.monoSmall),
                        const SizedBox(width: 8),
                        Text('Modifier',
                            style: T.small.copyWith(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: T.mintDark)),
                      ]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _editServer() async {
    final ctrl = TextEditingController(
        text: widget.api.baseUrl.replaceFirst('http://', ''));
    String? testResult;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDlg) => Dialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rCard)),
          child: SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Adresse du serveur', style: T.h2),
                  const SizedBox(height: 4),

                  Text(
                      "L'adresse IP du PC qui héberge le serveur Elixir "
                      '(ex. 192.168.1.10).',
                      style: T.small),
                  const SizedBox(height: 10),
                  Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: TextField(
                      controller: ctrl,
                      autofocus: true,
                      style: T.monoBody,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '192.168.1.10:8543',
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 13, vertical: 13),
                      ),
                    ),
                  ),
                  if (testResult != null) ...[
                    const SizedBox(height: 8),
                    Text(testResult!,
                        style: T.small.copyWith(
                            color: testResult!.startsWith('✓')
                                ? T.mintDark
                                : T.dangerDark)),
                  ],
                  const SizedBox(height: 14),
                  Row(children: [
                    TextButton(
                      onPressed: () async {
                        final url =
                            LocalConfig.normalizeServer(ctrl.text);
                        final probe = ApiClient(baseUrl: url);
                        final ok = await probe.health();
                        setDlg(() => testResult = ok
                            ? '✓ Serveur joignable'
                            : '✗ Aucun serveur à cette adresse');
                      },
                      child: Text('Tester la connexion',
                          style: T.body.copyWith(color: T.ink)),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 140,
                      child: PrimaryButton(
                        label: 'Enregistrer',
                        onPressed: () async {
                          final url =
                              LocalConfig.normalizeServer(ctrl.text);
                          widget.api.baseUrl = url;
                          widget.config.server = url;
                          await widget.config.save();
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (mounted) setState(() {});
  }
}

class _LoginField extends StatelessWidget {
  const _LoginField({
    required this.controller,
    this.focusNode,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool obscure;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        obscureText: obscure,
        onSubmitted: onSubmitted,
        style: obscure ? T.monoBody : T.body,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        ),
      ),
    );
  }
}
