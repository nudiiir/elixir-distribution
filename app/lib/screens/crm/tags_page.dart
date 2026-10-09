import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'crm_common.dart';

/// Colours offered for tags.
const tagPalette = <String>[
  '#00CC99', '#2563EB', '#7C3AED', '#DB2777', '#E5484D',
  '#E0A020', '#EA580C', '#0891B2', '#65A30D', '#4D5452',
];

/// « Gérer les étiquettes » page. Returns true when something changed.
Future<bool> openTagsPage(BuildContext context, ApiClient api) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => TagsPage(api: api)));
  return r == true;
}

class TagsPage extends StatefulWidget {
  const TagsPage({super.key, required this.api});
  final ApiClient api;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  List<CrmTag> _tags = const [];
  bool _loading = true;
  bool _changed = false;
  String? _error;

  bool get _canEdit => crmEditFiche(widget.api);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.api.crmTags();
      if (mounted) setState(() => _tags = t);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([CrmTag? t]) async {
    final saved = await showTagDialog(context, widget.api, existing: t);
    if (saved != null) {
      _changed = true;
      CrmDirectory.forgetTags();
      _load();
    }
  }

  Future<void> _delete(CrmTag t) async {
    final ok = await confirmAction(context,
        title: 'Supprimer l’étiquette « ${t.name} » ?',
        message: t.partnersCount > 0
            ? 'Elle sera retirée de ${t.partnersCount} client(s). Les clients ne sont pas supprimés.'
            : 'Aucun client ne la porte.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteTag(t.id);
      _changed = true;
      CrmDirectory.forgetTags();
      _load();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      crumbs: [Crumb('Clients', () => Navigator.of(context).pop(_changed)), const Crumb('Étiquettes')],
      title: 'Étiquettes des clients',
      subtitle: Text('Pour regrouper les clients (VIP, nuit, garde…) et filtrer les listes.', style: T.bodyMuted),
      onBack: () => Navigator.of(context).pop(_changed),
      maxWidth: 760,
      actions: [
        if (_canEdit)
          PageAction(
              label: 'Nouvelle étiquette', icon: Icons.add_rounded, primary: true, onPressed: () => _edit()),
      ],
      body: PageSection(
        title: '${_tags.length} étiquette(s)',
        child: _loading
            ? const SkeletonBar(width: 240, height: 14)
            : _error != null
                ? FieldError(_error)
                : _tags.isEmpty
                    ? EmptyState(
                        icon: Icons.sell_outlined,
                        text: 'Aucune étiquette pour l’instant.',
                        actions: [if (_canEdit) ('Nouvelle étiquette', () => _edit())])
                    : Column(children: [
                        for (final t in _tags) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              TagChip(name: t.name, colour: t.colour),
                              const SizedBox(width: 12),
                              Expanded(child: Text('${t.partnersCount} client(s)', style: T.bodyMuted)),
                              if (_canEdit) ...[
                                TextButton(onPressed: () => _edit(t), child: const Text('Modifier')),
                                TextButton(
                                    onPressed: () => _delete(t),
                                    child: const Text('Supprimer', style: TextStyle(color: T.dangerDark))),
                              ],
                            ]),
                          ),
                          const Divider(),
                        ],
                      ]),
      ),
    );
  }
}

/// Small dialog: name + colour. Returns the saved tag.
Future<CrmTag?> showTagDialog(BuildContext context, ApiClient api, {CrmTag? existing}) {
  return showDialog<CrmTag>(context: context, builder: (_) => _TagDialog(api: api, existing: existing));
}

class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.api, this.existing});
  final ApiClient api;
  final CrmTag? existing;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _colour = widget.existing?.colour.toUpperCase() ?? tagPalette.first;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _err = 'Donnez un nom.');
      return;
    }
    setState(() => _busy = true);
    try {
      final t = await widget.api.crmSaveTag(_name.text.trim(), _colour, id: widget.existing?.id);
      if (mounted) Navigator.of(context).pop(t);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text(widget.existing == null ? 'Nouvelle étiquette' : 'Modifier l’étiquette', style: T.h2),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextBlock(label: 'Nom', required: true, controller: _name, autofocus: true, error: _err, hint: 'Ex. VIP'),
          Text('Couleur', style: T.label),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in tagPalette)
              InkWell(
                onTap: () => setState(() => _colour = c),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: hexColour(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: _colour == c ? T.ink : Colors.transparent, width: 3),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 14),
          Text('Aperçu', style: T.label),
          const SizedBox(height: 6),
          TagChip(name: _name.text.isEmpty ? 'Étiquette' : _name.text, colour: _colour),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _busy ? null : _save,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
