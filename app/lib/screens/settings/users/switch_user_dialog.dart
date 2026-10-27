import 'package:flutter/material.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../theme/tokens.dart';
import '../../../util/approval.dart';
import '../../../util/feedback.dart';

/// « Changer de caissier »: pick a user who has a till code, type the code.
/// Returns the new [Session] (its token is already installed on [api]), or
/// null when closed. The caller swaps the app's session.
Future<Session?> showSwitchUserDialog(BuildContext context, ApiClient api) {
  return showDialog<Session>(
    context: context,
    builder: (_) => _SwitchUserDialog(api: api),
  );
}

class _SwitchUserDialog extends StatefulWidget {
  const _SwitchUserDialog({required this.api});
  final ApiClient api;

  @override
  State<_SwitchUserDialog> createState() => _SwitchUserDialogState();
}

class _SwitchUserDialogState extends State<_SwitchUserDialog> {
  List<PinUser>? _users;
  String? _loadError;
  PinUser? _picked;
  String _pin = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final u = await widget.api.pinUsers();
      if (!mounted) return;
      setState(() {
        _users = u;
        if (u.length == 1) _picked = u.first;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _submit() async {
    final u = _picked;
    if (u == null || _pin.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.api.pinLogin(u.id, _pin);
      if (mounted) Navigator.of(context).pop(s);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _pin = '';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Widget _body() {
    if (_loadError != null) return FieldError(_loadError);
    final users = _users;
    if (users == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (users.isEmpty) {
      return const Text(
          'Personne n’a encore de code caisse. Un administrateur peut en donner un dans '
          'Paramètres › Utilisateurs.',
          style: T.bodyMuted);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Qui prend la caisse ?', style: T.label),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final u in users)
          ChoiceChip(
            label: Text(u.roleName.isEmpty ? u.displayName : '${u.displayName} · ${u.roleName}',
                style: T.body),
            selected: _picked?.id == u.id,
            selectedColor: T.mintTint2,
            onSelected: (_) => setState(() {
              _picked = u;
              _pin = '';
              _error = null;
            }),
          ),
      ]),
      if (_picked != null) ...[
        const SizedBox(height: 18),
        Text('Code caisse de ${_picked!.displayName}', style: T.label),
        const SizedBox(height: 8),
        Center(
          child: PinPad(
            key: ValueKey(_picked!.id),
            value: _pin,
            enabled: !_busy,
            onChanged: (v) => setState(() {
              _pin = v;
              _error = null;
            }),
            onSubmit: _submit,
          ),
        ),
        FieldError(_error),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: const Row(children: [
        Icon(Icons.switch_account_outlined, color: T.mintDark),
        SizedBox(width: 10),
        Text('Changer de caissier', style: T.h2),
      ]),
      content: SizedBox(width: 380, child: SingleChildScrollView(child: _body())),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _picked != null && _pin.length >= 4 && !_busy ? _submit : null,
          child: Text(_busy ? 'Vérification…' : 'Prendre la caisse'),
        ),
      ],
    );
  }
}
