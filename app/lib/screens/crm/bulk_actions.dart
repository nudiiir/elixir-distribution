import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import 'crm_common.dart';
import 'send_message.dart';

/// A client targeted by a bulk action (segment result row, list row…).
class BulkClient {
  const BulkClient({required this.id, required this.name, this.tagIds = const [], this.repUserId});
  final String id;
  final String name;
  final List<String> tagIds;
  final String? repUserId;
}

/// Runs [one] for every client with a blocking progress dialog; returns the
/// number of successes and shows a summary toast.
Future<int> _runAll(BuildContext context, List<BulkClient> clients, String verb,
    Future<void> Function(BulkClient) one) async {
  final progress = ValueNotifier<int>(0);
  final errors = <String>[];
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: T.surface,
      content: ValueListenableBuilder<int>(
        valueListenable: progress,
        builder: (_, n, _) => Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Text('$verb… $n / ${clients.length}', style: T.body),
        ]),
      ),
    ),
  );
  var ok = 0;
  for (final c in clients) {
    try {
      await one(c);
      ok++;
    } catch (e) {
      errors.add('${c.name} : ${errText(e)}');
    }
    progress.value++;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();
  if (context.mounted) {
    if (errors.isEmpty) {
      showToast(context, '$verb : $ok client(s) traité(s).');
    } else {
      showToast(context, '$verb : $ok réussi(s), ${errors.length} en échec. ${errors.first}',
          kind: ToastKind.warning);
    }
  }
  return ok;
}

Future<V?> _pickDialog<V>(BuildContext context, String title, List<(V, String)> options, {String? note}) {
  return showDialog<V>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: T.surface,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: T.h2),
        if (note != null) ...[const SizedBox(height: 4), Text(note, style: T.small)],
      ]),
      children: [
        SizedBox(
          width: 420,
          height: options.length > 8 ? 400 : null,
          child: ListView(shrinkWrap: true, children: [
            for (final (v, l) in options)
              SimpleDialogOption(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                onPressed: () => Navigator.of(ctx).pop(v),
                child: Text(l, style: T.body),
              ),
          ]),
        ),
      ],
    ),
  );
}

/// « Attribuer un commercial » to every client. Returns true if done.
Future<bool> bulkAssignRep(BuildContext context, ApiClient api, List<BulkClient> clients) async {
  final users = await CrmDirectory.users(api);
  if (!context.mounted) return false;
  final pick = await _pickDialog<String>(
    context,
    'Attribuer un commercial',
    [('', 'Aucun commercial'), for (final u in users) (u.id, u.name)],
    note: '${clients.length} client(s) sélectionné(s)',
  );
  if (pick == null || !context.mounted) return false;
  await _runAll(context, clients, 'Attribution du commercial',
      (c) => api.crmPatchPartner(c.id, {'rep_user_id': pick}));
  return true;
}

/// « Ajouter une étiquette » to every client.
Future<bool> bulkAddTag(BuildContext context, ApiClient api, List<BulkClient> clients) async {
  final tags = await CrmDirectory.tags(api, refresh: true);
  if (!context.mounted) return false;
  if (tags.isEmpty) {
    showToast(context, 'Aucune étiquette : créez-en une d’abord (fiche client › Étiquettes).', kind: ToastKind.warning);
    return false;
  }
  final pick = await _pickDialog<String>(context, 'Ajouter une étiquette', [for (final t in tags) (t.id, t.name)],
      note: '${clients.length} client(s) sélectionné(s)');
  if (pick == null || !context.mounted) return false;
  await _runAll(context, clients, 'Ajout de l’étiquette', (c) async {
    if (c.tagIds.contains(pick)) return;
    await api.crmSetPartnerTags(c.id, [...c.tagIds, pick]);
  });
  CrmDirectory.forgetTags();
  return true;
}

/// « Créer une tâche » for every client (same title, type, date).
Future<bool> bulkCreateTasks(BuildContext context, ApiClient api, List<BulkClient> clients) async {
  final spec = await showDialog<Map<String, dynamic>>(
      context: context, builder: (_) => _BulkTaskDialog(api: api, count: clients.length));
  if (spec == null || !context.mounted) return false;
  final toRep = spec['to_rep'] == true;
  await _runAll(context, clients, 'Création des tâches', (c) async {
    final assignee = toRep ? (c.repUserId ?? spec['assignee_id']) : spec['assignee_id'];
    await api.crmSaveTask({
      'title': spec['title'],
      'type': spec['type'],
      'priority': spec['priority'],
      'partner_id': c.id,
      'due_at': ?spec['due_at'],
      'assignee_id': ?assignee,
    });
  });
  return true;
}

/// « Message WhatsApp » for every client (one by one).
Future<void> bulkWhatsApp(BuildContext context, ApiClient api, List<BulkClient> clients, {String? templateCode}) =>
    showBulkWhatsAppPanel(context, api, clients: [for (final c in clients) (c.id, c.name)], templateCode: templateCode);

class _BulkTaskDialog extends StatefulWidget {
  const _BulkTaskDialog({required this.api, required this.count});
  final ApiClient api;
  final int count;

  @override
  State<_BulkTaskDialog> createState() => _BulkTaskDialogState();
}

class _BulkTaskDialogState extends State<_BulkTaskDialog> {
  final _title = TextEditingController(text: 'Appeler le client');
  String _type = 'call';
  int _priority = 0;
  String? _due = isoDate(DateTime.now());
  String? _assignee;
  bool _toRep = true;
  List<CrmUser> _users = const [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _assignee = widget.api.user?.id;
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Créer une tâche pour ${widget.count} client(s)', style: T.h2),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextBlock(label: 'À faire', required: true, controller: _title, error: _err, autofocus: true),
            Text('Type', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<String>(
              options: [for (final e in taskTypeLabels.entries) (e.key, e.value)],
              value: _type,
              onSelect: (v) => setState(() => _type = v),
            ),
            const SizedBox(height: 12),
            Text('Priorité', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<int>(
              options: [for (final e in taskPriorityLabels.entries) (e.key, e.value)],
              value: _priority,
              onSelect: (v) => setState(() => _priority = v),
            ),
            const SizedBox(height: 12),
            DateBlock(label: 'Échéance', value: _due, onChanged: (v) => setState(() => _due = v)),
            CheckboxListTile(
              value: _toRep,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: T.mintDeep,
              title: Text('Confier au commercial de chaque client', style: T.body),
              subtitle: Text('Sinon, ou s’il n’en a pas : la personne choisie ci-dessous.', style: T.small),
              onChanged: (v) => setState(() => _toRep = v ?? false),
            ),
            DropdownBlock<String>(
              label: 'Confiée à',
              value: _assignee,
              noneLabel: 'Personne',
              options: [for (final u in _users) (u.id, u.name)],
              onChanged: (v) => setState(() => _assignee = v),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: () {
            if (_title.text.trim().isEmpty) {
              setState(() => _err = 'Écrivez ce qu’il faut faire.');
              return;
            }
            Navigator.of(context).pop({
              'title': _title.text.trim(),
              'type': _type,
              'priority': _priority,
              'due_at': _due,
              'assignee_id': _assignee,
              'to_rep': _toRep,
            });
          },
          child: Text('Créer ${widget.count} tâche(s)'),
        ),
      ],
    );
  }
}
