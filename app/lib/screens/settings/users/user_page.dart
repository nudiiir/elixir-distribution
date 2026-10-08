import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../theme/tokens.dart';
import '../../../util/approval.dart';
import '../../../util/feedback.dart';
import '../../../widgets/app_page.dart';
import 'permission_catalog.dart';

/// Page of one user (inside Paramètres › Utilisateurs). [user] null = new.
class UserPage extends StatefulWidget {
  const UserPage({
    super.key,
    required this.api,
    required this.me,
    required this.user,
    required this.roles,
    required this.warehouses,
    required this.onBack,
    required this.onSaved,
  });
  final ApiClient api;
  final User me;
  final User? user;
  final List<Role> roles;
  final List<Warehouse> warehouses;
  final VoidCallback onBack;
  final ValueChanged<User> onSaved;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  late final TextEditingController _fullName;
  late final TextEditingController _username;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  final _password = TextEditingController();
  late String? _roleId;
  late Set<String> _warehouses;
  String? _defaultWarehouse;
  late bool _active;
  User? _user; // last saved state
  bool _resetPassword = false;
  String? _generated; // shown once, readable
  final _errors = <String, String>{};
  bool _busy = false;
  bool _dirty = false;

  bool get _isNew => _user == null;
  bool get _isMe => _user?.id == widget.me.id;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _user = u;
    _fullName = TextEditingController(text: u?.fullName ?? '');
    _username = TextEditingController(text: u?.username ?? '');
    _phone = TextEditingController(text: u?.phone ?? '');
    _email = TextEditingController(text: u?.email ?? '');
    final known = {for (final r in widget.roles) r.id};
    _roleId = u != null && known.contains(u.roleId)
        ? u.roleId
        : (known.contains('role-cashier') ? 'role-cashier' : (widget.roles.isEmpty ? null : widget.roles.first.id));
    _warehouses = {...?u?.warehouseIds};
    _defaultWarehouse = u?.defaultWarehouseId;
    _active = u?.active ?? true;
  }

  @override
  void dispose() {
    for (final c in [_fullName, _username, _phone, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _touch() => _dirty = true;

  Role? get _role {
    for (final r in widget.roles) {
      if (r.id == _roleId) return r;
    }
    return null;
  }

  static String generatePassword() {
    // Readable: no 0/O, 1/l/I. Two syllable blocks + digits, e.g. « Kabo-Remi-47 ».
    const cons = 'bcdfghjkmnprstvz';
    const vow = 'aeiou';
    final r = Random.secure();
    String syl() => cons[r.nextInt(cons.length)] + vow[r.nextInt(vow.length)];
    String word() {
      final w = syl() + syl();
      return w[0].toUpperCase() + w.substring(1);
    }

    return '${word()}-${word()}-${20 + r.nextInt(79)}';
  }

  void _generate() {
    final p = generatePassword();
    setState(() {
      _password.text = p;
      _generated = p;
      _resetPassword = true;
      _errors.remove('password');
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    _errors.clear();
    if (_username.text.trim().isEmpty) _errors['username'] = 'L’identifiant est obligatoire.';
    if (_roleId == null) _errors['role_id'] = 'Choisissez un rôle.';
    if (_isNew && _password.text.length < 4) {
      _errors['password'] = 'Mot de passe obligatoire (4 caractères minimum) — ou « Générer ».';
    } else if (_resetPassword && _password.text.isNotEmpty && _password.text.length < 4) {
      _errors['password'] = '4 caractères minimum.';
    }
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() => _busy = true);
    try {
      final data = <String, dynamic>{
        'username': _username.text.trim(),
        'full_name': _fullName.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'role_id': _roleId,
        'active': _active,
        'warehouse_ids': _warehouses.toList(),
        'default_warehouse_id': _defaultWarehouse,
        if ((_isNew || _resetPassword) && _password.text.isNotEmpty) 'password': _password.text,
      };
      final saved = await widget.api.saveUser(data, id: _user?.id);
      if (!mounted) return;
      final wasNew = _isNew;
      setState(() {
        _user = saved;
        _busy = false;
        _dirty = false;
        _resetPassword = false;
        _password.clear();
      });
      showToast(context, wasNew ? 'Utilisateur créé' : 'Utilisateur enregistré',
          kind: ToastKind.success,
          actionLabel: wasNew && !saved.hasPin ? 'Donner un code caisse' : null,
          onAction: wasNew && !saved.hasPin ? _editPin : null);
      widget.onSaved(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.field != null) _errors[e.field!] = e.message;
      });
      if (e.field == null) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _editPin() async {
    final u = _user;
    if (u == null) return;
    final pin = await showDialog<String>(context: context, builder: (_) => const _PinSetDialog());
    if (pin == null || !mounted) return;
    try {
      final saved = await widget.api.setUserPin(u.id, pin);
      if (!mounted) return;
      setState(() => _user = saved);
      showToast(context, 'Code caisse enregistré', kind: ToastKind.success);
      widget.onSaved(saved);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _removePin() async {
    final u = _user;
    if (u == null) return;
    final ok = await confirmAction(context,
        title: 'Retirer le code caisse ?',
        message: '${u.displayName} ne pourra plus prendre la caisse ni donner son accord avec un code.',
        confirmLabel: 'Retirer',
        danger: true);
    if (!ok) return;
    try {
      final saved = await widget.api.setUserPin(u.id, '');
      if (!mounted) return;
      setState(() => _user = saved);
      showToast(context, 'Code caisse retiré', kind: ToastKind.success);
      widget.onSaved(saved);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _logoutAll() async {
    final u = _user;
    if (u == null) return;
    final ok = await confirmAction(context,
        title: 'Déconnecter ${u.displayName} partout ?',
        message: _isMe
            ? 'Toutes vos sessions se ferment, celle-ci aussi : vous devrez vous reconnecter.'
            : 'Toutes ses sessions se ferment, sur tous les postes et téléphones. '
                'Il devra se reconnecter.',
        confirmLabel: 'Déconnecter partout',
        danger: true);
    if (!ok) return;
    try {
      await widget.api.logoutAll(u.id);
      if (mounted) showToast(context, '${u.displayName} est déconnecté partout', kind: ToastKind.success);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _activity() async {
    final u = _user;
    if (u == null) return;
    await showDialog<void>(context: context, builder: (_) => _ActivityDialog(api: widget.api, user: u));
  }

  Future<void> _back() async {
    if (_dirty) {
      final leave = await confirmAction(context,
          title: 'Quitter sans enregistrer ?',
          message: 'Les changements de cet utilisateur seront perdus.',
          confirmLabel: 'Quitter');
      if (!leave) return;
    }
    widget.onBack();
  }

  Widget _text(TextEditingController c, {String? hint, bool autofocus = false, TextInputType? type}) => SizedBox(
        height: 42,
        child: TextField(
          controller: c,
          autofocus: autofocus,
          keyboardType: type,
          onChanged: (_) => _touch(),
          onSubmitted: (_) => _save(),
          style: T.body,
          decoration: fieldDecoration(hint: hint),
        ),
      );

  Widget _passwordBlock() {
    final show = _isNew || _resetPassword;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!show)
        Row(children: [
          const Expanded(
              child: Text('Le mot de passe sert à se connecter au logiciel. Il n’est jamais affiché.',
                  style: T.bodyMuted)),
          OutlinedButton.icon(
            onPressed: () => setState(() => _resetPassword = true),
            icon: const Icon(Icons.lock_reset_rounded, size: 18),
            label: const Text('Réinitialiser'),
          ),
        ])
      else
        LabeledField(
          label: _isNew ? 'Mot de passe' : 'Nouveau mot de passe',
          required: _isNew,
          error: _errors['password'],
          helper: 'Au moins 4 caractères. « Générer » propose un mot de passe facile à lire.',
          child: Row(children: [
            Expanded(child: _text(_password, hint: 'Mot de passe')),
            const SizedBox(width: 8),
            SizedBox(
              height: 42,
              child: OutlinedButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Générer'),
              ),
            ),
            if (!_isNew) ...[
              const SizedBox(width: 8),
              TextButton(
                  onPressed: () => setState(() {
                        _resetPassword = false;
                        _generated = null;
                        _password.clear();
                        _errors.remove('password');
                      }),
                  child: const Text('Annuler')),
            ],
          ]),
        ),
      if (_generated != null && show)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: T.warnTint,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.warn),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Notez ce mot de passe et donnez-le à la personne :', style: T.body),
                const SizedBox(height: 4),
                SelectableText(_generated!, style: T.monoBig),
                const SizedBox(height: 2),
                const Text('Il ne sera plus affiché après l’enregistrement.', style: T.small),
              ]),
            ),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _generated!));
                showToast(context, 'Mot de passe copié', kind: ToastKind.info);
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copier'),
            ),
          ]),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final u = _user;
    final title = u == null ? 'Nouvel utilisateur' : u.displayName;
    final role = _role;
    return AppPage(
      crumbs: [Crumb('Utilisateurs', _back), Crumb(title)],
      title: title,
      subtitle: u == null
          ? null
          : Text('${u.roleLabel} · ${u.active ? 'actif' : 'désactivé'} · dernière connexion : ${formatWhen(u.lastLoginAt)}',
              style: T.bodyMuted),
      onBack: _back,
      maxWidth: 900,
      actions: [
        if (u != null) PageAction(label: 'Voir son activité', icon: Icons.history_rounded, onPressed: _activity),
        if (u != null) PageAction(label: 'Déconnecter partout', icon: Icons.logout_rounded, onPressed: _logoutAll),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageSection(
          title: 'Informations',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(
                label: 'Nom complet',
                error: _errors['full_name'],
                child: _text(_fullName, hint: 'Ex. Karim Benali', autofocus: u == null)),
            LabeledField(
              label: 'Identifiant',
              required: true,
              error: _errors['username'],
              helper: 'Le nom tapé pour se connecter, sans espace (ex. karim).',
              child: _text(_username, hint: 'karim'),
            ),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: LabeledField(
                      label: 'Téléphone',
                      error: _errors['phone'],
                      child: _text(_phone, hint: '05 55 12 34 56', type: TextInputType.phone))),
              const SizedBox(width: 16),
              Expanded(
                  child: LabeledField(
                      label: 'Email',
                      error: _errors['email'],
                      child: _text(_email, hint: 'nom@exemple.dz', type: TextInputType.emailAddress))),
            ]),
          ]),
        ),
        PageSection(
          title: 'Rôle et accès',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(
              label: 'Rôle',
              required: true,
              error: _errors['role_id'],
              helper: role == null
                  ? null
                  : '${role.description.isEmpty ? '' : '${role.description} '}Voit : ${(scopeLabels[role.scope] ?? role.scope).toLowerCase()}.',
              child: DropdownButtonFormField<String>(
                initialValue: _roleId,
                isExpanded: true,
                decoration: fieldDecoration(),
                items: [
                  for (final r in widget.roles) DropdownMenuItem(value: r.id, child: Text(r.name, style: T.body)),
                ],
                onChanged: (v) => setState(() {
                  _roleId = v;
                  _dirty = true;
                  _errors.remove('role_id');
                }),
              ),
            ),
            if (widget.warehouses.length > 1) ...[
              const Text('Dépôts autorisés', style: T.label),
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 0, children: [
                for (final w in widget.warehouses)
                  SizedBox(
                    width: 260,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: T.mintDeep,
                      value: _warehouses.contains(w.id),
                      title: Text(w.name, style: T.body),
                      onChanged: (v) => setState(() {
                        _dirty = true;
                        if (v == true) {
                          _warehouses.add(w.id);
                        } else {
                          _warehouses.remove(w.id);
                          if (_defaultWarehouse == w.id) _defaultWarehouse = null;
                        }
                      }),
                    ),
                  ),
              ]),
              Text(
                  role?.scope == 'warehouse'
                      ? 'Avec ce rôle, il ne voit que les documents et le stock de ces dépôts.'
                      : 'Aucun dépôt coché = tous les dépôts.',
                  style: T.small),
              const SizedBox(height: 14),
            ],
            if (widget.warehouses.isNotEmpty)
              LabeledField(
                label: 'Dépôt par défaut',
                helper: 'Proposé d’office à la caisse et dans les nouveaux documents.',
                child: DropdownButtonFormField<String?>(
                  key: ValueKey(_warehouses.length),
                  initialValue: _defaultWarehouse,
                  isExpanded: true,
                  decoration: fieldDecoration(),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Celui du magasin', style: T.body)),
                    for (final w in widget.warehouses)
                      if (_warehouses.isEmpty || _warehouses.contains(w.id))
                        DropdownMenuItem<String?>(value: w.id, child: Text(w.name, style: T.body)),
                  ],
                  onChanged: (v) => setState(() {
                    _defaultWarehouse = v;
                    _dirty = true;
                  }),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: T.mintDeep,
              value: _active,
              onChanged: _isMe
                  ? null
                  : (v) => setState(() {
                        _active = v;
                        _dirty = true;
                      }),
              title: const Text('Compte actif', style: T.body),
              subtitle: Text(
                  _isMe
                      ? 'Vous ne pouvez pas désactiver votre propre compte.'
                      : 'Un compte désactivé ne peut plus se connecter ; ses documents restent.',
                  style: T.bodyMuted),
            ),
          ]),
        ),
        PageSection(title: 'Mot de passe', child: _passwordBlock()),
        PageSection(
          title: 'Code caisse',
          child: u == null
              ? const Text('Enregistrez d’abord l’utilisateur pour lui donner un code caisse.', style: T.bodyMuted)
              : Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(u.hasPin ? 'Un code caisse est défini.' : 'Pas de code caisse.',
                          style: T.body.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      const Text(
                          '4 à 6 chiffres pour « Changer de caissier » et pour donner son accord '
                          '(code du gérant).',
                          style: T.bodyMuted),
                    ]),
                  ),
                  OutlinedButton.icon(
                    onPressed: _editPin,
                    icon: const Icon(Icons.pin_outlined, size: 18),
                    label: Text(u.hasPin ? 'Changer' : 'Définir'),
                  ),
                  if (u.hasPin) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _removePin,
                      style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                      child: const Text('Retirer'),
                    ),
                  ],
                ]),
        ),
        if (u != null)
          PageSection(
            title: 'Connexion',
            child: FactGrid(facts: [
              ('Dernière connexion', formatWhen(u.lastLoginAt)),
              ('Rôle', u.roleLabel),
            ]),
          ),
      ]),
    );
  }
}

/// Enter the new code twice.
class _PinSetDialog extends StatefulWidget {
  const _PinSetDialog();

  @override
  State<_PinSetDialog> createState() => _PinSetDialogState();
}

class _PinSetDialogState extends State<_PinSetDialog> {
  String _first = '';
  String _second = '';
  bool _confirming = false;
  String? _error;

  void _next() {
    if (!_confirming) {
      if (_first.length < 4) {
        setState(() => _error = 'Le code doit avoir 4 à 6 chiffres.');
        return;
      }
      setState(() {
        _confirming = true;
        _error = null;
      });
      return;
    }
    if (_second != _first) {
      setState(() {
        _error = 'Les deux codes ne sont pas pareils. Recommencez.';
        _first = '';
        _second = '';
        _confirming = false;
      });
      return;
    }
    Navigator.of(context).pop(_first);
  }

  @override
  Widget build(BuildContext context) {
    final value = _confirming ? _second : _first;
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(_confirming ? 'Retapez le code' : 'Nouveau code caisse', style: T.h2),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_confirming ? 'Pour être sûr, tapez le même code une deuxième fois.' : '4 à 6 chiffres.',
              style: T.bodyMuted),
          const SizedBox(height: 12),
          PinPad(
            key: ValueKey(_confirming),
            value: value,
            onChanged: (v) => setState(() {
              if (_confirming) {
                _second = v;
              } else {
                _first = v;
              }
              _error = null;
            }),
            onSubmit: _next,
          ),
          FieldError(_error),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: value.length >= 4 ? _next : null,
          child: Text(_confirming ? 'Enregistrer' : 'Suivant'),
        ),
      ],
    );
  }
}

/// « Voir son activité »: the journal filtered on that user.
class _ActivityDialog extends StatefulWidget {
  const _ActivityDialog({required this.api, required this.user});
  final ApiClient api;
  final User user;

  @override
  State<_ActivityDialog> createState() => _ActivityDialogState();
}

class _ActivityDialogState extends State<_ActivityDialog> {
  List<AuditEntry>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (items, _) = await widget.api.auditSearch(userId: widget.user.id, limit: 200);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Activité de ${widget.user.displayName}', style: T.h2),
      content: SizedBox(
        width: 640,
        height: 460,
        child: _error != null
            ? FieldError(_error)
            : items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? const Center(child: Text('Aucune activité enregistrée.', style: T.bodyMuted))
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: T.border),
                        itemBuilder: (_, i) {
                          final e = items[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              SizedBox(width: 170, child: Text(formatWhen(e.createdAt), style: T.small)),
                              Expanded(
                                child: Text(e.detail?.isNotEmpty == true ? e.detail! : e.action, style: T.body),
                              ),
                            ]),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fermer')),
      ],
    );
  }
}
