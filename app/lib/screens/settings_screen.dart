import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/config.dart';
import '../util/raw_printer.dart';
import '../widgets/cloud_card.dart';
import '../widgets/ui.dart';

/// Company identity keys stored in the server's settings table. They feed the
/// legal invoice header (décret 05-468).
const _companyFields = [
  ('company_name', 'Raison sociale'),
  ('company_address', 'Adresse'),
  ('company_phone', 'Téléphone'),
  ('company_nif', 'NIF'),
  ('company_nis', 'NIS'),
  ('company_rc', 'Registre de commerce (RC)'),
  ('company_ai', "Article d'imposition (AI)"),
];


class SettingsScreen extends StatefulWidget {
  const SettingsScreen(
      {super.key,
      required this.api,
      required this.session,
      required this.config});
  final ApiClient api;
  final Session session;
  final LocalConfig config;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, TextEditingController> _ctrls = {
    for (final (key, _) in _companyFields) key: TextEditingController(),
  };
  final _newWarehouse = TextEditingController();
  List<Warehouse> _warehouses = const [];
  List<User> _users = const [];
  List<String> _printers = const [];
  List<BackupInfo> _backups = const [];
  String _backupDir = '';
  bool _busy = false;
  bool _backingUp = false;
  String? _msg;

  bool get _isAdmin => widget.session.user.isAdmin;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPrinters();
    if (_isAdmin) {
      _loadUsers();
      _loadBackups();
    }
  }

  void _loadPrinters() {
    try {
      final printers = listPrinters();
      if (mounted) setState(() => _printers = printers);
    } catch (_) {}
  }

  Future<void> _loadBackups() async {
    try {
      final (dir, items) = await widget.api.backups();
      if (mounted) {
        setState(() {
          _backupDir = dir;
          _backups = items;
        });
      }
    } catch (_) {}
  }

  Future<void> _backupNow() async {
    setState(() => _backingUp = true);
    try {
      await widget.api.runBackup();
      await _loadBackups();
    } on ApiException catch (e) {
      if (mounted) setState(() => _msg = e.message);
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _loadUsers() async {
    try {
      final users = await widget.api.users();
      if (mounted) setState(() => _users = users);
    } catch (_) {}
  }

  Future<void> _openUserForm({User? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _UserFormDialog(
          api: widget.api, existing: existing, me: widget.session.user),
    );
    if (saved == true) _loadUsers();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _newWarehouse.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.settings(),
        widget.api.warehouses(),
      ]);
      final settings = results[0] as Map<String, String>;
      if (mounted) {
        setState(() {
          for (final (key, _) in _companyFields) {
            _ctrls[key]!.text = settings[key] ?? '';
          }
          _warehouses = results[1] as List<Warehouse>;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await widget.api.saveSettings({
        for (final (key, _) in _companyFields) key: _ctrls[key]!.text.trim(),
      });
      setState(() => _msg = 'Paramètres enregistrés.');
    } on ApiException catch (e) {
      setState(() => _msg = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addWarehouse() async {
    final name = _newWarehouse.text.trim();
    if (name.isEmpty) return;
    try {
      await widget.api.createWarehouse(name);
      _newWarehouse.clear();
      _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Paramètres', style: T.h1),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(children: [
              Card14(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MicroLabel('Entreprise — en-tête de facture'),
                    const SizedBox(height: 4),
                    Text(
                        'Ces informations figurent sur vos factures (décret 05-468).',
                        style: T.bodyMuted),
                    const SizedBox(height: 14),
                    for (var i = 0; i < _companyFields.length; i += 2)
                      Row(children: [
                        Expanded(
                            child: _SettingField(
                                label: _companyFields[i].$2,
                                controller:
                                    _ctrls[_companyFields[i].$1]!)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: i + 1 < _companyFields.length
                              ? _SettingField(
                                  label: _companyFields[i + 1].$2,
                                  controller:
                                      _ctrls[_companyFields[i + 1].$1]!)
                              : const SizedBox(),
                        ),
                      ]),
                    Row(children: [
                      if (_msg != null)
                        Text(_msg!,
                            style: T.small.copyWith(color: T.mintDark)),
                      const Spacer(),
                      SizedBox(
                        width: 150,
                        child: PrimaryButton(
                          label: _busy ? '…' : 'Enregistrer',
                          onPressed: _busy ? null : _save,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Card14(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MicroLabel('Dépôts'),
                    const SizedBox(height: 10),
                    for (final w in _warehouses)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(children: [
                          const Icon(Icons.warehouse_outlined,
                              size: 15, color: T.faint),
                          const SizedBox(width: 10),
                          Text(w.name, style: T.body),
                          const SizedBox(width: 8),
                          if (w.isDefault)
                            const MintChip('défaut',
                                color: T.mintTint, fg: T.mintDark),
                        ]),
                      ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: SearchField(
                          controller: _newWarehouse,
                          hint: 'Nom du nouveau dépôt…',
                          onSubmitted: (_) => _addWarehouse(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 120,
                        child: PrimaryButton(
                            label: 'Ajouter', onPressed: _addWarehouse),
                      ),
                    ]),
                  ],
                ),
              ),
              if (_isAdmin) ...[
                const SizedBox(height: 14),
                Card14(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Expanded(
                            child: MicroLabel('Utilisateurs & droits')),
                        SizedBox(
                          width: 170,
                          child: PrimaryButton(
                            label: 'Nouvel utilisateur',
                            onPressed: () => _openUserForm(),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      for (final u in _users)
                        InkWell(
                          onTap: () => _openUserForm(existing: u),
                          borderRadius: BorderRadius.circular(T.rInner),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              Icon(
                                  u.role == 'admin'
                                      ? Icons.shield_outlined
                                      : Icons.person_outline,
                                  size: 16,
                                  color: u.active ? T.muted : T.ghost),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                    u.fullName.isEmpty
                                        ? u.username
                                        : '${u.fullName}  ·  ${u.username}',
                                    style: T.body.copyWith(
                                        color:
                                            u.active ? T.ink : T.ghost)),
                              ),
                              if (!u.active)
                                const Padding(
                                  padding: EdgeInsetsDirectional.only(
                                      end: 8),
                                  child: MintChip('désactivé',
                                      color: T.dangerTint,
                                      fg: T.dangerDark),
                                ),
                              MintChip(u.roleLabel,
                                  color: T.cream, fg: T.muted),
                              const SizedBox(width: 8),
                              if (!u.can('view_cost'))
                                const Tooltip(
                                  message: "Ne voit pas les prix d'achat",
                                  child: Icon(Icons.visibility_off_outlined,
                                      size: 14, color: T.faint),
                                ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_isAdmin) ...[
                const SizedBox(height: 14),
                CloudCard(api: widget.api),
              ],
              const SizedBox(height: 14),
              // ---- Ticket printer (per-machine) ----
              Card14(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MicroLabel('Imprimante tickets (ce poste)'),
                    const SizedBox(height: 4),
                    Text(
                        'Imprimante thermique 80mm utilisée par la caisse. '
                        'Le ticket part automatiquement après chaque vente.',
                        style: T.bodyMuted),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: Container(
                          height: 42,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: T.bg,
                            borderRadius: BorderRadius.circular(T.rInner),
                            border: Border.all(color: T.border),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String?>(
                              value: _printers
                                      .contains(widget.config.ticketPrinter)
                                  ? widget.config.ticketPrinter
                                  : null,
                              isExpanded: true,
                              style: T.body,
                              icon: const Icon(Icons.expand_more,
                                  size: 16, color: T.faint),
                              hint: Text('Aucune — pas d’impression',
                                  style: T.bodyMuted
                                      .copyWith(color: T.ghost)),
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null,
                                    child:
                                        Text('Aucune — pas d’impression')),
                                for (final p in _printers)
                                  DropdownMenuItem<String?>(
                                    value: p,
                                    enabled: !isVirtualPrinter(p),
                                    child: Text(
                                      isVirtualPrinter(p)
                                          ? '$p — virtuelle, incompatible'
                                          : p,
                                      style: isVirtualPrinter(p)
                                          ? T.bodyMuted
                                              .copyWith(color: T.ghost)
                                          : null,
                                    ),
                                  ),
                              ],
                              onChanged: (v) async {
                                widget.config.ticketPrinter = v;
                                await widget.config.save();
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        onPressed: _loadPrinters,
                        tooltip: 'Rafraîchir la liste',
                        icon: const Icon(Icons.refresh,
                            size: 17, color: T.muted),
                      ),
                    ]),
                  ],
                ),
              ),
              if (_isAdmin) ...[
                const SizedBox(height: 14),
                // ---- Backups ----
                Card14(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Expanded(child: MicroLabel('Sauvegardes')),
                        SizedBox(
                          width: 200,
                          child: PrimaryButton(
                            label: _backingUp
                                ? 'Sauvegarde…'
                                : 'Sauvegarder maintenant',
                            onPressed: _backingUp ? null : _backupNow,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                          'Une copie de la base est faite automatiquement chaque jour '
                          '(14 conservées). Pour restaurer : arrêter le serveur, '
                          'remplacer data\\elixir.db par la copie choisie, redémarrer.',
                          style: T.bodyMuted),
                      const SizedBox(height: 6),
                      Text(_backupDir, style: T.monoSmall),
                      const SizedBox(height: 8),
                      for (final b in _backups.take(7))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            const Icon(Icons.save_outlined,
                                size: 13, color: T.faint),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(b.name, style: T.monoSmall)),
                            Text(
                                '${(b.sizeBytes / 1024 / 1024).toStringAsFixed(1)} Mo',
                                style: T.monoSmall),
                          ]),
                        ),
                      if (_backups.isEmpty)
                        Text('Aucune sauvegarde pour le moment.',
                            style: T.small),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Card14(
                child: Row(children: [
                  const Icon(Icons.dns_outlined, size: 16, color: T.faint),
                  const SizedBox(width: 10),
                  const MicroLabel('Serveur'),
                  const SizedBox(width: 14),
                  Text(widget.api.baseUrl, style: T.monoSmall),
                  const Spacer(),
                  const MicroLabel('Version'),
                  const SizedBox(width: 8),
                  Text('0.1.0', style: T.monoSmall),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

const _permLabels = [
  ('dashboard', 'Tableau de bord'),
  ('pos', 'Caisse'),
  ('sales', 'Ventes'),
  ('purchases', 'Achats'),
  ('stock', 'Stock'),
  ('products', 'Produits'),
  ('partners', 'Partenaires'),
  ('assistant', 'Assistant'),
  ('settings', 'Paramètres'),
];

Map<String, bool> _roleDefaults(String role) => switch (role) {
      'admin' || 'manager' => {
          for (final (k, _) in _permLabels) k: true,
          'view_cost': true,
        },
      _ => {
          for (final (k, _) in _permLabels) k: false,
          'pos': true,
          'assistant': true,
          'view_cost': false,
        },
    };

class _UserFormDialog extends StatefulWidget {
  const _UserFormDialog({required this.api, this.existing, required this.me});
  final ApiClient api;
  final User? existing;
  final User me;

  @override
  State<_UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<_UserFormDialog> {
  late final _username =
      TextEditingController(text: widget.existing?.username ?? '');
  late final _fullName =
      TextEditingController(text: widget.existing?.fullName ?? '');
  final _password = TextEditingController();
  late String _role = widget.existing?.role ?? 'cashier';
  late Map<String, bool> _perms = widget.existing != null
      ? {...widget.existing!.perms}
      : _roleDefaults(_role);
  late bool _active = widget.existing?.active ?? true;
  bool _busy = false;
  String? _error;

  bool get _isSelf => widget.existing?.id == widget.me.id;

  @override
  void dispose() {
    _username.dispose();
    _fullName.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveUser({
        'username': _username.text.trim(),
        'full_name': _fullName.text.trim(),
        'role': _role,
        'active': _active,
        'perms': _perms,
        if (_password.text.isNotEmpty) 'password': _password.text,
        if (widget.existing == null) 'password': _password.text,
      }, id: widget.existing?.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdminRole = _role == 'admin';
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    widget.existing == null
                        ? 'Nouvel utilisateur'
                        : widget.existing!.username,
                    style: T.h2),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                      child: _SettingField(
                          label: "Nom d'utilisateur",
                          controller: _username)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _SettingField(
                          label: 'Nom complet', controller: _fullName)),
                ]),
                _SettingField(
                    label: widget.existing == null
                        ? 'Mot de passe'
                        : 'Nouveau mot de passe (laisser vide pour garder)',
                    controller: _password),
                const MicroLabel('Rôle'),
                const SizedBox(height: 6),
                Row(children: [
                  for (final (label, value) in [
                    ('Caissier', 'cashier'),
                    ('Gérant', 'manager'),
                    ('Administrateur', 'admin')
                  ])
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ChoiceChip(
                        label: Text(label,
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _role == value
                                    ? T.mintDark
                                    : T.muted)),
                        selected: _role == value,
                        selectedColor: T.mintTint,
                        backgroundColor: T.bg,
                        side: BorderSide(
                            color:
                                _role == value ? T.mintDeep : T.border),
                        showCheckmark: false,
                        onSelected: _isSelf
                            ? null
                            : (_) => setState(() {
                                  _role = value;
                                  _perms = _roleDefaults(value);
                                }),
                      ),
                    ),
                ]),
                const SizedBox(height: 14),
                const MicroLabel('Modules accessibles'),
                const SizedBox(height: 6),
                if (isAdminRole)
                  Text("Un administrateur a accès à tout.",
                      style: T.bodyMuted)
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final (key, label) in _permLabels)
                      FilterChip(
                        label: Text(label,
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: (_perms[key] ?? false)
                                    ? T.mintDark
                                    : T.muted)),
                        selected: _perms[key] ?? false,
                        selectedColor: T.mintTint,
                        backgroundColor: T.bg,
                        checkmarkColor: T.mintDark,
                        side: BorderSide(
                            color: (_perms[key] ?? false)
                                ? T.mintDeep
                                : T.border),
                        onSelected: (v) =>
                            setState(() => _perms[key] = v),
                      ),
                  ]),
                if (!isAdminRole) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () => setState(() =>
                        _perms['view_cost'] = !(_perms['view_cost'] ?? false)),
                    child: Row(children: [
                      Icon(
                          (_perms['view_cost'] ?? false)
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 18,
                          color: (_perms['view_cost'] ?? false)
                              ? T.mintDeep
                              : T.faint),
                      const SizedBox(width: 8),
                      Text("Peut voir les prix d'achat, CUMP et marges",
                          style: T.bodyMuted),
                    ]),
                  ),
                ],
                if (widget.existing != null && !_isSelf) ...[
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () => setState(() => _active = !_active),
                    child: Row(children: [
                      Icon(
                          _active
                              ? Icons.toggle_on
                              : Icons.toggle_off_outlined,
                          size: 26,
                          color: _active ? T.mintDeep : T.ghost),
                      const SizedBox(width: 8),
                      Text(_active ? 'Compte actif' : 'Compte désactivé',
                          style: T.bodyMuted),
                    ]),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: T.small.copyWith(color: T.dangerDark)),
                ],
                const SizedBox(height: 18),
                Row(children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('Fermer',
                        style: T.small.copyWith(color: T.muted)),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 140,
                    child: PrimaryButton(
                      label: _busy ? '…' : 'Enregistrer',
                      onPressed: _busy ? null : _save,
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingField extends StatelessWidget {
  const _SettingField({required this.label, required this.controller});
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MicroLabel(label),
          const SizedBox(height: 4),
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: TextField(
              controller: controller,
              style: T.body,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
