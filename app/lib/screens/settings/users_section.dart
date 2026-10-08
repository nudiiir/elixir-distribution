import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/data_table.dart';
import '../../widgets/ui.dart';
import 'settings_shell.dart';
import 'users/permission_catalog.dart';
import 'users/user_page.dart';

/// Utilisateurs: the list of accounts, then the page of one user.
class UsersSection extends StatefulWidget {
  const UsersSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends State<UsersSection> {
  List<User>? _users;
  List<Role> _roles = const [];
  List<Warehouse> _warehouses = const [];
  String? _error;
  bool _loading = true;
  String _q = '';

  User? _open;
  bool _creating = false;

  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([_api.users(), _api.roles(), _api.warehouses()]);
      if (!mounted) return;
      setState(() {
        _users = results[0] as List<User>;
        _roles = results[1] as List<Role>;
        _warehouses = results[2] as List<Warehouse>;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : '$e';
          _loading = false;
        });
      }
    }
  }

  void _show(User? u, {bool creating = false}) => setState(() {
        _open = u;
        _creating = creating;
      });

  String _depots(User u) {
    if (u.warehouseIds.isEmpty) return 'Tous';
    final names = {for (final w in _warehouses) w.id: w.name};
    return u.warehouseIds.map((id) => names[id] ?? '?').join(', ');
  }

  Future<void> _logoutAll(User u) async {
    final ok = await confirmAction(context,
        title: 'Déconnecter ${u.displayName} partout ?',
        message: 'Toutes ses sessions se ferment, sur tous les postes et téléphones.',
        confirmLabel: 'Déconnecter partout',
        danger: true);
    if (!ok) return;
    try {
      await _api.logoutAll(u.id);
      if (mounted) showToast(context, '${u.displayName} est déconnecté partout', kind: ToastKind.success);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _setActive(User u, bool active) async {
    try {
      await _api.saveUser({
        'username': u.username,
        'full_name': u.fullName,
        'role_id': u.roleId,
        'active': active,
      }, id: u.id);
      await _load();
      if (mounted) {
        showToast(context, active ? '${u.displayName} est réactivé' : '${u.displayName} est désactivé',
            kind: ToastKind.success);
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ctx.isAdmin) {
      return const SettingsPage(
          title: 'Utilisateurs',
          children: [Text('Seul un administrateur peut gérer les utilisateurs.', style: T.bodyMuted)]);
    }
    if (_open != null || _creating) {
      return UserPage(
        key: ValueKey(_open?.id ?? 'new'),
        api: _api,
        me: widget.ctx.session.user,
        user: _open,
        roles: _roles,
        warehouses: _warehouses,
        onBack: () {
          _show(null);
          _load();
        },
        onSaved: (_) {},
      );
    }
    final q = _q.trim().toLowerCase();
    final items = [
      for (final u in _users ?? const <User>[])
        if (q.isEmpty || '${u.fullName} ${u.username} ${u.roleLabel}'.toLowerCase().contains(q)) u,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Utilisateurs', style: T.h1)),
          PageAction(
              label: 'Nouvel utilisateur',
              icon: Icons.person_add_alt_1_rounded,
              primary: true,
              onPressed: () => _show(null, creating: true)),
        ]),
        const SizedBox(height: 6),
        const Text(
            'Chaque personne a son compte, son rôle (ce qu’elle peut faire) et, si besoin, un code caisse.',
            style: T.bodyMuted),
        const SizedBox(height: 14),
        SizedBox(
          width: 360,
          height: 42,
          child: TextField(
            onChanged: (v) => setState(() => _q = v),
            style: T.body,
            decoration: fieldDecoration(hint: 'Chercher un nom, un identifiant, un rôle…')
                .copyWith(prefixIcon: const Icon(Icons.search, size: 18)),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DataListView<User>(
            items: items,
            loading: _loading && _users == null,
            error: _error,
            onRetry: _load,
            prefsKey: 'settings.users',
            rowId: (u) => u.id,
            onTap: (u) => _show(u),
            exportTitle: 'Utilisateurs',
            exportBaseName: 'utilisateurs',
            empty: EmptyState(
              icon: Icons.people_alt_outlined,
              text: q.isEmpty ? 'Aucun utilisateur.' : 'Personne ne correspond à « $_q ».',
              actions: [('Nouvel utilisateur', () => _show(null, creating: true))],
            ),
            rowMenu: (u) => [
              RowAction('Ouvrir', Icons.open_in_new_rounded, (u) => _show(u)),
              RowAction('Déconnecter partout', Icons.logout_rounded, _logoutAll),
              if (u.id != widget.ctx.session.user.id)
                u.active
                    ? RowAction('Désactiver', Icons.person_off_outlined, (u) => _setActive(u, false), danger: true)
                    : RowAction('Réactiver', Icons.person_outline_rounded, (u) => _setActive(u, true)),
            ],
            columns: [
              ColumnSpec(
                id: 'name',
                label: 'Nom',
                flex: 3,
                hideable: false,
                sortKey: (u) => u.displayName.toLowerCase(),
                exportValue: (u) => u.fullName,
                cell: (_, u) => Row(children: [
                  Flexible(
                    child: Text(u.fullName.isEmpty ? '—' : u.fullName,
                        overflow: TextOverflow.ellipsis, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (u.hasPin) ...[
                    const SizedBox(width: 6),
                    const Tooltip(message: 'A un code caisse', child: Icon(Icons.pin_outlined, size: 16, color: T.muted)),
                  ],
                ]),
              ),
              ColumnSpec(
                id: 'username',
                label: 'Identifiant',
                flex: 2,
                sortKey: (u) => u.username.toLowerCase(),
                exportValue: (u) => u.username,
                cell: (_, u) => Text(u.username, overflow: TextOverflow.ellipsis, style: T.monoBody),
              ),
              ColumnSpec(
                id: 'role',
                label: 'Rôle',
                flex: 2,
                sortKey: (u) => u.roleLabel,
                exportValue: (u) => u.roleLabel,
                cell: (_, u) => Text(u.roleLabel, overflow: TextOverflow.ellipsis, style: T.body),
              ),
              ColumnSpec(
                id: 'depots',
                label: 'Dépôts',
                flex: 2,
                exportValue: _depots,
                cell: (_, u) => Text(_depots(u), overflow: TextOverflow.ellipsis, style: T.bodyMuted),
              ),
              ColumnSpec(
                id: 'last',
                label: 'Dernière connexion',
                flex: 2,
                sortKey: (u) => u.lastLoginAt ?? '',
                exportValue: (u) => formatWhen(u.lastLoginAt),
                cell: (_, u) => Text(formatWhen(u.lastLoginAt), overflow: TextOverflow.ellipsis, style: T.bodyMuted),
              ),
              ColumnSpec(
                id: 'active',
                label: 'Actif',
                width: 110,
                sortKey: (u) => u.active ? 0 : 1,
                exportValue: (u) => u.active ? 'Oui' : 'Non',
                cell: (_, u) => Text(u.active ? 'Oui' : 'Désactivé',
                    style: T.body.copyWith(color: u.active ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
