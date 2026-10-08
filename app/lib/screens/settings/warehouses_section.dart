import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/data_table.dart';
import '../../widgets/ui.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres → Dépôts: list, create, rename, default, delete.
class WarehousesSection extends StatefulWidget {
  const WarehousesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<WarehousesSection> createState() => _WarehousesSectionState();
}

class _WarehousesSectionState extends State<WarehousesSection> {
  List<Warehouse> _items = const [];
  bool _loading = true;
  String? _error;

  ApiClient get _api => widget.ctx.api;
  bool get _canEdit => widget.ctx.isAdmin || widget.ctx.session.user.can('settings');

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
      final items = await _api.warehouses();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de charger les dépôts : $e';
        });
      }
    }
  }

  Future<void> _edit([Warehouse? w]) async {
    final saved = await showDialog<Warehouse>(
      context: context,
      builder: (_) => _WarehouseDialog(api: _api, existing: w),
    );
    if (saved == null || !mounted) return;
    await _load();
    if (!mounted) return;
    showToast(context, w == null ? 'Dépôt « ${saved.name} » créé.' : 'Dépôt « ${saved.name} » enregistré.');
  }

  Future<void> _makeDefault(Warehouse w) async {
    try {
      await _api.setDefaultWarehouse(w.id);
      await _load();
      if (mounted) showToast(context, '« ${w.name} » est maintenant le dépôt par défaut.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _delete(Warehouse w) async {
    final ok = await confirmAction(context,
        title: 'Supprimer le dépôt « ${w.name} » ?',
        message: 'Possible seulement si le dépôt est vide et n’a jamais servi dans un document. '
            'Sinon, Elixir vous dira pourquoi il doit rester.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await _api.deleteWarehouse(w.id);
      await _load();
      if (mounted) showToast(context, 'Dépôt « ${w.name} » supprimé.');
    } on ApiException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.surface,
          title: Text('« ${w.name} » ne peut pas être supprimé', style: T.h2),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(e.message, style: T.body),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Compris')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = (170 + 50.0 * _items.length).clamp(260.0, 620.0);
    return SettingsPage(
      title: 'Dépôts',
      intro: 'Les endroits où vous rangez la marchandise : le magasin, une réserve, un entrepôt… '
          'Le stock est suivi dépôt par dépôt.',
      actions: [
        if (_canEdit)
          PageAction(label: 'Nouveau dépôt', icon: Icons.add_rounded, primary: true, onPressed: () => _edit()),
      ],
      children: [
        if (!_canEdit) const AdminOnlyNotice(),
        SizedBox(
          height: height,
          child: DataListView<Warehouse>(
            items: _items,
            loading: _loading,
            error: _error,
            onRetry: _load,
            rowId: (w) => w.id,
            onTap: _canEdit ? _edit : null,
            columns: [
              ColumnSpec(
                label: 'Nom',
                flex: 3,
                hideable: false,
                sortKey: (w) => w.name.toLowerCase(),
                exportValue: (w) => w.name,
                cell: (_, w) => Row(children: [
                  Flexible(child: Text(w.name, style: T.body.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                  if (w.isDefault) ...[
                    const SizedBox(width: 8),
                    const MintChip('Par défaut', color: T.mintTint, fg: T.mintDark),
                  ],
                ]),
              ),
              ColumnSpec(
                label: 'Adresse',
                flex: 3,
                exportValue: (w) => w.address,
                cell: (_, w) => Text(w.address.isEmpty ? '—' : w.address,
                    style: T.bodyMuted, overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec(
                label: 'Téléphone',
                flex: 2,
                exportValue: (w) => w.phone,
                cell: (_, w) => Text(w.phone.isEmpty ? '—' : w.phone, style: T.bodyMuted),
              ),
            ],
            rowMenu: _canEdit
                ? (w) => [
                      RowAction('Modifier', Icons.edit_outlined, _edit),
                      RowAction('Définir par défaut', Icons.star_outline_rounded, _makeDefault,
                          enabled: !w.isDefault),
                      RowAction('Supprimer', Icons.delete_outline_rounded, _delete,
                          danger: true, enabled: !w.isDefault),
                    ]
                : null,
            exportTitle: 'Dépôts',
            exportBaseName: 'depots',
            empty: EmptyState(
              icon: Icons.warehouse_outlined,
              text: 'Aucun dépôt.',
              actions: [if (_canEdit) ('Créer un dépôt', () => _edit())],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const InfoBanner(
          text: 'Le dépôt par défaut est proposé partout : caisse, ventes, achats, inventaires. '
              'Un dépôt qui contient du stock ou qui apparaît dans un document ne peut pas être '
              'supprimé — renommez-le si besoin.',
        ),
      ],
    );
  }
}

class _WarehouseDialog extends StatefulWidget {
  const _WarehouseDialog({required this.api, this.existing});
  final ApiClient api;
  final Warehouse? existing;

  @override
  State<_WarehouseDialog> createState() => _WarehouseDialogState();
}

class _WarehouseDialogState extends State<_WarehouseDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _address = TextEditingController(text: widget.existing?.address ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  String? _nameError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Donnez un nom au dépôt.');
      return;
    }
    setState(() {
      _busy = true;
      _nameError = null;
    });
    try {
      final w = widget.existing == null
          ? await widget.api.createWarehouse(name, address: _address.text.trim(), phone: _phone.text.trim())
          : await widget.api.updateWarehouse(widget.existing!.id,
              name: name, address: _address.text.trim(), phone: _phone.text.trim());
      if (mounted) Navigator.of(context).pop(w);
    } on ApiException catch (e) {
      if (mounted) setState(() => _nameError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 480,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.existing == null ? 'Nouveau dépôt' : 'Modifier le dépôt', style: T.h2),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Nom',
              controller: _name,
              required: true,
              error: _nameError,
              hint: 'ex. Réserve',
              onSubmitted: (_) => _save(),
            ),
            LabeledField(label: 'Adresse', controller: _address),
            LabeledField(label: 'Téléphone', controller: _phone, onSubmitted: (_) => _save()),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
              PageAction(
                label: _busy ? 'Enregistrement…' : 'Enregistrer',
                primary: true,
                onPressed: _busy ? null : _save,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
