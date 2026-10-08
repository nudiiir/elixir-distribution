import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'settings_shell.dart';
import 'users/permission_catalog.dart';
import 'users/role_page.dart';

/// Rôles et permissions: the list of roles (with how many users have each),
/// then the page of one role.
class RolesSection extends StatefulWidget {
  const RolesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<RolesSection> createState() => _RolesSectionState();
}

class _RolesSectionState extends State<RolesSection> {
  List<Role>? _roles;
  String? _error;

  /// The open role page: null = the list; [_creating] = new role.
  Role? _open;
  bool _creating = false;

  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await _api.roles();
      if (mounted) setState(() => _roles = r);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  void _show(Role? r, {bool creating = false}) => setState(() {
        _open = r;
        _creating = creating;
      });

  Future<void> _copy(Role r) async {
    try {
      final c = await _api.copyRole(r.id);
      await _load();
      if (!mounted) return;
      showToast(context, 'Copie créée : « ${c.name} »', kind: ToastKind.success);
      _show(c);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _delete(Role r) async {
    if (r.userCount > 0) {
      showToast(context,
          'Ce rôle est donné à ${r.userCount} utilisateur${r.userCount > 1 ? 's' : ''} : donnez-leur d’abord un autre rôle.',
          kind: ToastKind.warning);
      return;
    }
    final ok = await confirmAction(context,
        title: 'Supprimer le rôle « ${r.name} » ?',
        message: 'Le rôle disparaît. Cette action ne peut pas être annulée.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await _api.deleteRole(r.id);
      await _load();
      if (mounted) showToast(context, 'Rôle supprimé', kind: ToastKind.success);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ctx.isAdmin) {
      return const SettingsPage(
          title: 'Rôles et permissions',
          children: [Text('Seul un administrateur peut gérer les rôles.', style: T.bodyMuted)]);
    }
    if (_open != null || _creating) {
      return RolePage(
        key: ValueKey(_open?.id ?? 'new'),
        api: _api,
        role: _open,
        onBack: () {
          _show(null);
          _load();
        },
        onSaved: (r) {
          _load();
          _show(r);
        },
        onCopied: (r) {
          _load();
          _show(r);
        },
        onDeleted: () {
          _show(null);
          _load();
        },
      );
    }
    final roles = _roles;
    return SettingsPage(
      title: 'Rôles et permissions',
      intro: 'Un rôle dit ce qu’une personne peut voir et faire. Donnez ensuite un rôle à chaque '
          'utilisateur (Paramètres › Utilisateurs).',
      actions: [
        PageAction(
            label: 'Nouveau rôle', icon: Icons.add_rounded, primary: true, onPressed: () => _show(null, creating: true)),
      ],
      children: [
        if (_error != null)
          EmptyState(icon: Icons.error_outline_rounded, text: _error!, actions: [('Réessayer', _load)])
        else if (roles == null)
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SkeletonBar(width: 520, height: 16),
            SizedBox(height: 14),
            SkeletonBar(width: 480, height: 16),
            SizedBox(height: 14),
            SkeletonBar(width: 440, height: 16),
          ])
        else
          Container(
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rCard),
              border: Border.all(color: T.border),
            ),
            child: Column(children: [
              for (final r in roles) _row(r),
            ]),
          ),
      ],
    );
  }

  Widget _row(Role r) {
    final users = r.userCount == 0 ? 'Aucun utilisateur' : '${r.userCount} utilisateur${r.userCount > 1 ? 's' : ''}';
    return InkWell(
      onTap: () => _show(r),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
        child: Row(children: [
          Icon(r.isSystem ? Icons.verified_user_outlined : Icons.badge_outlined, color: T.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(r.name, style: T.body.copyWith(fontWeight: FontWeight.w700))),
                if (r.isSystem) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(T.rChip)),
                    child: Text('Système', style: T.small.copyWith(fontSize: 12, color: T.mintDark)),
                  ),
                ],
              ]),
              if (r.description.isNotEmpty)
                Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.bodyMuted),
            ]),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 150, child: Text(users, style: T.bodyMuted)),
          SizedBox(width: 190, child: Text(scopeLabels[r.scope] ?? r.scope, style: T.bodyMuted)),
          PopupMenuButton<String>(
            tooltip: 'Actions',
            onSelected: (v) {
              switch (v) {
                case 'open':
                  _show(r);
                case 'copy':
                  _copy(r);
                case 'delete':
                  _delete(r);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'open', child: Text('Ouvrir')),
              const PopupMenuItem(value: 'copy', child: Text('Copier')),
              if (!r.isSystem) const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Actions', style: T.body.copyWith(fontWeight: FontWeight.w600)),
                const Icon(Icons.arrow_drop_down_rounded),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
