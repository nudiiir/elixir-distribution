import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import 'ui.dart';

/// Connexion cloud — one button, no fields.
///
/// The service addresses are baked into the build and the shop enrolls itself,
/// so a shopkeeper never sees a URL or a token. Connecting and pairing both ask
/// for the admin password again, because both widen who can reach the shop.
class CloudCard extends StatefulWidget {
  const CloudCard({super.key, required this.api});
  final ApiClient api;

  @override
  State<CloudCard> createState() => _CloudCardState();
}

class _CloudCardState extends State<CloudCard> {
  CloudConfig? _status;
  bool _busy = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The tunnel comes up a few seconds after connecting; keep the light honest.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await widget.api.cloudStatus();
      if (mounted) setState(() => _status = st);
    } catch (_) {}
  }

  Future<String?> _askPassword(String title, String explanation) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
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
                Text(title, style: T.h2),
                const SizedBox(height: 6),
                Text(explanation, style: T.bodyMuted),
                const SizedBox(height: 14),
                const MicroLabel('Votre mot de passe'),
                const SizedBox(height: 5),
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
                    obscureText: true,
                    style: T.monoBody,
                    onSubmitted: (v) => Navigator.of(context).pop(v),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 13, vertical: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('Annuler',
                          style: T.small.copyWith(color: T.muted)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: PrimaryButton(
                      label: 'Confirmer',
                      onPressed: () => Navigator.of(context).pop(ctrl.text),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  Future<void> _connect() async {
    final pwd = await _askPassword(
      'Connecter le magasin',
      'Le magasin deviendra accessible depuis votre téléphone et '
          'l’assistant pourra répondre sur vos données.',
    );
    if (pwd == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final st = await widget.api.cloudConnect(pwd);
      if (mounted) setState(() => _status = st);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await confirmAction(context,
        title: 'Déconnecter le magasin ?',
        message: 'Les téléphones, l’assistant, le scan de factures et la boutique en ligne ne '
            'pourront plus joindre ce magasin. Vous pourrez le reconnecter ensuite.',
        confirmLabel: 'Déconnecter',
        danger: true);
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final st = await widget.api.cloudDisconnect();
      if (mounted) setState(() => _status = st);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair() async {
    final pwd = await _askPassword(
      'Connecter un téléphone',
      'Un code à usage unique sera affiché pendant 5 minutes. '
          'Scannez-le avec l’application Elixir Stock.',
    );
    if (pwd == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = await widget.api.cloudPair(pwd);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _PairingDialog(
          payload: pairing.payload,
          code: pairing.code,
          seconds: pairing.expiresIn,
        ),
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final connected = st?.relayConnected == true;
    final enabled = st?.relayEnabled == true;

    return Card14(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: MicroLabel('Connexion cloud')),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: connected
                    ? T.mintTint
                    : enabled
                        ? T.warnTint
                        : T.cream,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: connected
                        ? T.mint
                        : enabled
                            ? T.warn
                            : T.ghost,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                    connected
                        ? 'Connecté'
                        : enabled
                            ? 'Connexion…'
                            : 'Non connecté',
                    style: T.label.copyWith(
                        fontSize: 13,
                        color: connected
                            ? T.mintDark
                            : enabled
                                ? T.warnDark
                                : T.faint)),
              ]),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              connected
                  ? 'Votre téléphone peut atteindre ce magasin, l’assistant '
                      'répond sur vos données et les factures scannées arrivent ici.'
                  : 'Connectez le magasin pour utiliser l’application mobile, '
                      'l’assistant intelligent et le scan de factures. '
                      'Le logiciel fonctionne normalement sans.',
              style: T.bodyMuted),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: T.body.copyWith(color: T.dangerDark)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            if (!enabled)
              SizedBox(
                width: 200,
                child: PrimaryButton(
                  label: _busy ? 'Connexion…' : 'Connecter le magasin',
                  big: true,
                  onPressed: _busy ? null : _connect,
                ),
              )
            else ...[
              SizedBox(
                width: 220,
                child: PrimaryButton(
                  label: 'Connecter un téléphone',
                  big: true,
                  onPressed: _busy || !connected ? null : _pair,
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _busy ? null : _disconnect,
                child: Text('Déconnecter',
                    style: T.body.copyWith(color: T.dangerDark, fontWeight: FontWeight.w600)),
              ),
            ],
          ]),
        ],
      ),
    );
  }
}

/// Shows the QR the phone scans, with a live countdown so nobody wonders why
/// an old screenshot stopped working.
class _PairingDialog extends StatefulWidget {
  const _PairingDialog(
      {required this.payload, required this.code, required this.seconds});
  final String payload;
  final String code;
  final int seconds;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  late int _left = widget.seconds;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expired = _left <= 0;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Connecter un téléphone', style: T.h2),
              const SizedBox(height: 6),
              Text(
                  'Ouvrez Elixir Stock sur le téléphone et scannez ce code.',
                  style: T.bodyMuted,
                  textAlign: TextAlign.center),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: T.border),
                ),
                child: expired
                    ? const SizedBox(
                        width: 220,
                        height: 220,
                        child: Center(
                          child: Text('Code expiré',
                              style: TextStyle(
                                  fontFamily: T.sans,
                                  fontWeight: FontWeight.w700,
                                  color: T.faint)),
                        ),
                      )
                    : QrImageView(
                        data: widget.payload,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square, color: T.ink),
                        dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: T.ink),
                      ),
              ),
              const SizedBox(height: 14),
              const MicroLabel('Ou saisissez ce code'),
              const SizedBox(height: 5),
              Text(widget.code,
                  style: const TextStyle(
                      fontFamily: T.mono,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 4,
                      color: T.ink)),
              const SizedBox(height: 10),
              Text(
                  expired
                      ? 'Fermez et réessayez pour obtenir un nouveau code.'
                      : 'Expire dans ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}',
                  style: T.small.copyWith(
                      color: expired ? T.dangerDark : T.faint)),
              const SizedBox(height: 18),
              SizedBox(
                width: 140,
                child: PrimaryButton(
                  label: 'Fermer',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
