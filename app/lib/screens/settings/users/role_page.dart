import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/client.dart';
import '../../../api/models.dart';
import '../../../theme/tokens.dart';
import '../../../util/feedback.dart';
import '../../../widgets/app_page.dart';
import 'permission_catalog.dart';

/// Page of one role: name, description, scope, the permission grid, the
/// special rights with their limits. [role] null = new role.
class RolePage extends StatefulWidget {
  const RolePage({
    super.key,
    required this.api,
    required this.role,
    required this.onBack,
    required this.onSaved,
    required this.onCopied,
    required this.onDeleted,
  });
  final ApiClient api;
  final Role? role;
  final VoidCallback onBack;
  final ValueChanged<Role> onSaved;
  final ValueChanged<Role> onCopied;
  final VoidCallback onDeleted;

  @override
  State<RolePage> createState() => _RolePageState();
}

class _RolePageState extends State<RolePage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _maxDiscount;
  late final TextEditingController _maxCredit;
  late final TextEditingController _approvalAbove;
  late Map<String, bool> _perms;
  late String _scope;
  String? _nameError;
  String? _limitError;
  bool _busy = false;
  bool _dirty = false;

  bool get _readOnly => widget.role?.isSystem == true;

  static String _da(int centimes) => centimes <= 0 ? '' : (centimes / 100).toStringAsFixed(0);
  static String _pct(int x100) {
    if (x100 <= 0) return '';
    final v = x100 / 100;
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll('.', ',');
  }

  @override
  void initState() {
    super.initState();
    final r = widget.role;
    _name = TextEditingController(text: r?.name ?? '');
    _desc = TextEditingController(text: r?.description ?? '');
    _maxDiscount = TextEditingController(text: _pct(r?.limits['max_discount_pct'] ?? 0));
    _maxCredit = TextEditingController(text: _da(r?.limits['max_credit'] ?? 0));
    _approvalAbove = TextEditingController(text: _da(r?.limits['approval_above'] ?? 0));
    _perms = {...?r?.perms};
    if (r == null) {
      _perms['pos.view'] = true;
      _perms['sales.view'] = true;
      _perms['sales.create'] = true;
    }
    _scope = r?.scope ?? 'all';
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _maxDiscount, _maxCredit, _approvalAbove]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _on(String k) => _perms[k] == true;

  void _set(String key, bool v) {
    setState(() {
      _dirty = true;
      _perms[key] = v;
      final i = key.indexOf('.');
      if (i > 0) {
        final m = key.substring(0, i);
        final a = key.substring(i + 1);
        final mod = permModules.firstWhere((e) => e.key == m);
        if (a == 'view' && !v) {
          for (final x in mod.actions) {
            _perms['$m.$x'] = false;
          }
        } else if (a != 'view' && v) {
          _perms['$m.view'] = true;
        }
      }
    });
  }

  bool? _rowState(PermModule m) {
    final n = m.actions.where((a) => _on('${m.key}.$a')).length;
    return n == 0 ? false : (n == m.actions.length ? true : null);
  }

  void _setRow(PermModule m, bool v) {
    setState(() {
      _dirty = true;
      for (final a in m.actions) {
        _perms['${m.key}.$a'] = v;
      }
    });
  }

  bool? _colState(String action) {
    final mods = permModules.where((m) => m.actions.contains(action)).toList();
    final n = mods.where((m) => _on('${m.key}.$action')).length;
    return n == 0 ? false : (n == mods.length ? true : null);
  }

  void _setCol(String action, bool v) {
    for (final m in permModules.where((m) => m.actions.contains(action))) {
      _set('${m.key}.$action', v);
    }
  }

  int? _parsePct(String s) {
    final t = s.trim().replaceAll(',', '.').replaceAll('%', '');
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    if (v == null || v < 0 || v > 100) return null;
    return (v * 100).round();
  }

  int? _parseDa(String s) {
    final t = s.trim().replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.');
    if (t.isEmpty) return 0;
    final v = double.tryParse(t);
    if (v == null || v < 0) return null;
    return (v * 100).round();
  }

  Future<void> _save() async {
    if (_readOnly || _busy) return;
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Donnez un nom au rôle.' : null;
      _limitError = null;
    });
    final pct = _parsePct(_maxDiscount.text);
    final credit = _parseDa(_maxCredit.text);
    final above = _parseDa(_approvalAbove.text);
    if (pct == null || credit == null || above == null) {
      setState(() => _limitError = 'Les limites doivent être des nombres positifs (remise entre 0 et 100 %).');
      return;
    }
    if (_nameError != null) return;
    setState(() => _busy = true);
    try {
      final saved = await widget.api.saveRole({
        'name': name,
        'description': _desc.text.trim(),
        'scope': _scope,
        'perms': {for (final e in _perms.entries) if (e.value) e.key: true},
        'limits': {'max_discount_pct': pct, 'max_credit': credit, 'approval_above': above},
      }, id: widget.role?.id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _dirty = false;
      });
      showToast(context, 'Rôle « ${saved.name} » enregistré', kind: ToastKind.success);
      widget.onSaved(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.field == 'name') {
          _nameError = e.message;
        } else if (e.field != null && e.field!.startsWith('max_') || e.field == 'approval_above') {
          _limitError = e.message;
        }
      });
      if (e.field == null) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _copy() async {
    final r = widget.role;
    if (r == null) return;
    try {
      final c = await widget.api.copyRole(r.id);
      if (!mounted) return;
      showToast(context, 'Copie créée : « ${c.name} »', kind: ToastKind.success);
      widget.onCopied(c);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _delete() async {
    final r = widget.role;
    if (r == null) return;
    final ok = await confirmAction(context,
        title: 'Supprimer le rôle « ${r.name} » ?',
        message: r.userCount > 0
            ? 'Ce rôle est donné à ${r.userCount} utilisateur${r.userCount > 1 ? 's' : ''}. '
                'Donnez-leur d’abord un autre rôle.'
            : 'Le rôle disparaît. Cette action ne peut pas être annulée.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await widget.api.deleteRole(r.id);
      if (!mounted) return;
      showToast(context, 'Rôle supprimé', kind: ToastKind.success);
      widget.onDeleted();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _back() async {
    if (_dirty && !_readOnly) {
      final leave = await confirmAction(context,
          title: 'Quitter sans enregistrer ?',
          message: 'Les changements de ce rôle seront perdus.',
          confirmLabel: 'Quitter');
      if (!leave) return;
    }
    widget.onBack();
  }

  Widget _check(bool? v, ValueChanged<bool> onChanged, {String? tooltip}) {
    final box = Checkbox(
      value: v,
      tristate: v == null,
      activeColor: T.mintDeep,
      onChanged: _readOnly ? null : (x) => onChanged(x ?? false),
    );
    return tooltip == null ? box : Tooltip(message: tooltip, child: box);
  }

  Widget _grid() {
    const first = 210.0;
    const cell = 82.0;
    Widget head(String t) => SizedBox(
        width: cell, child: Text(t, textAlign: TextAlign.center, style: T.label.copyWith(fontWeight: FontWeight.w700)));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: first, child: Text('Module', style: T.label)),
          for (final (_, label) in permActions) head(label),
          head('Tout'),
        ]),
        Row(children: [
          SizedBox(width: first, child: Text('Tout cocher', style: T.small)),
          for (final (a, label) in permActions)
            SizedBox(
                width: cell,
                child: Center(
                    child: _check(_colState(a), (v) => _setCol(a, v), tooltip: 'Tout cocher : $label'))),
          const SizedBox(width: cell),
        ]),
        const Divider(height: 8, color: T.border),
        for (final m in permModules)
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
            child: Row(children: [
              SizedBox(width: first, child: Text(m.label, style: T.body.copyWith(fontWeight: FontWeight.w600))),
              for (final (a, label) in permActions)
                SizedBox(
                  width: cell,
                  child: Center(
                    child: m.actions.contains(a)
                        ? _check(_on('${m.key}.$a'), (v) => _set('${m.key}.$a', v), tooltip: '$label — ${m.label}')
                        : const Text('—', style: TextStyle(color: T.ghost)),
                  ),
                ),
              SizedBox(
                  width: cell,
                  child: Center(
                      child: _check(_rowState(m), (v) => _setRow(m, v), tooltip: 'Tout cocher : ${m.label}'))),
            ]),
          ),
      ]),
    );
  }

  Widget _limitField(TextEditingController c, String unit) => SizedBox(
        width: 170,
        height: 42,
        child: TextField(
          controller: c,
          enabled: !_readOnly,
          onChanged: (_) => _dirty = true,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,. ]'))],
          style: T.body,
          decoration: fieldDecoration(hint: 'Pas de limite', suffixText: unit),
        ),
      );

  Widget _special(SpecialRight r) {
    final on = _on(r.key);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _check(on, (v) => setState(() {
              _dirty = true;
              _perms[r.key] = v;
            })),
        const SizedBox(width: 6),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(r.sentence, style: T.bodyMuted),
            ]),
          ),
        ),
        if (r.limitKey != null && on)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.limitLabel!, style: T.label),
              const SizedBox(height: 4),
              _limitField(r.limitKey == 'max_discount_pct' ? _maxDiscount : _maxCredit, r.limitUnit!),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.role;
    final title = r == null ? 'Nouveau rôle' : r.name;
    return AppPage(
      crumbs: [Crumb('Rôles et permissions', _back), Crumb(title)],
      title: title,
      subtitle: r == null
          ? null
          : Text(
              r.userCount == 0
                  ? 'Aucun utilisateur n’a ce rôle'
                  : '${r.userCount} utilisateur${r.userCount > 1 ? 's' : ''} avec ce rôle',
              style: T.bodyMuted),
      onBack: _back,
      maxWidth: 1000,
      actions: [
        if (r != null) PageAction(label: 'Copier', icon: Icons.copy_rounded, onPressed: _copy),
        if (r != null && !r.isSystem)
          PageAction(label: 'Supprimer', icon: Icons.delete_outline_rounded, danger: true, onPressed: _delete),
        if (!_readOnly)
          PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_readOnly)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: T.mintTint,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.mintTint2),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded, color: T.mintDark),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                    'L’Administrateur a tous les droits : il gère les utilisateurs, les rôles et tous '
                    'les réglages. Ce rôle ne peut être ni modifié ni supprimé. Pour un rôle proche, '
                    'utilisez « Copier ».',
                    style: T.body),
              ),
            ]),
          ),
        PageSection(
          title: 'Informations',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(
              label: 'Nom du rôle',
              required: true,
              error: _nameError,
              child: SizedBox(
                height: 42,
                child: TextField(
                  controller: _name,
                  enabled: !_readOnly,
                  autofocus: r == null,
                  onChanged: (_) => _dirty = true,
                  onSubmitted: (_) => _save(),
                  style: T.body,
                  decoration: fieldDecoration(hint: 'Ex. Vendeur, Magasinier…'),
                ),
              ),
            ),
            LabeledField(
              label: 'Description',
              helper: 'Une phrase pour se souvenir à qui ce rôle est destiné.',
              child: TextField(
                controller: _desc,
                enabled: !_readOnly,
                onChanged: (_) => _dirty = true,
                minLines: 1,
                maxLines: 3,
                style: T.body,
                decoration: fieldDecoration(),
              ),
            ),
          ]),
        ),
        PageSection(
          title: 'Ce que ce rôle voit',
          child: RadioGroup<String>(
            groupValue: _scope,
            onChanged: (v) {
              if (_readOnly || v == null) return;
              setState(() {
                _dirty = true;
                _scope = v;
              });
            },
            child: Column(children: [
              for (final e in const [
                ('all', 'Tout', 'Voit tous les documents du magasin.'),
                ('own', 'Seulement ses propres documents', 'Voit les ventes et documents qu’il a créés ou validés.'),
                ('warehouse', 'Seulement son dépôt', 'Voit les documents et le stock de ses dépôts autorisés.'),
              ])
                RadioListTile<String>(
                  value: e.$1,
                  enabled: !_readOnly,
                  contentPadding: EdgeInsets.zero,
                  activeColor: T.mintDeep,
                  title: Text(e.$2, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  subtitle: Text(e.$3, style: T.bodyMuted),
                ),
            ]),
          ),
        ),
        PageSection(
          title: 'Permissions par module',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'Cochez ce que ce rôle peut faire. « Voir » ouvre le module ; sans « Voir », '
                'le module n’apparaît pas dans le menu.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            _grid(),
          ]),
        ),
        PageSection(
          title: 'Droits particuliers',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in specialRights) _special(s),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Code du gérant au-delà de',
              helper: 'Une vente plus élevée que ce montant demande le code du gérant. Vide = jamais.',
              error: _limitError,
              child: _limitField(_approvalAbove, 'DA'),
            ),
          ]),
        ),
      ]),
    );
  }
}
