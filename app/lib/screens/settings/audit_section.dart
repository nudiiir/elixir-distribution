import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Plain words for the journal's action keys.
String auditActionLabel(String a) => switch (a) {
      'document.cancel' => 'Brouillon supprimé',
      'document.void' => 'Document annulé',
      'document.post' => 'Document validé',
      'product.price_change' => 'Prix modifié',
      'caisse.open' => 'Caisse ouverte',
      'caisse.close' => 'Caisse clôturée',
      'warehouse.create' => 'Dépôt créé',
      'warehouse.rename' => 'Dépôt renommé',
      'warehouse.default' => 'Dépôt par défaut changé',
      'warehouse.delete' => 'Dépôt supprimé',
      'backup.run' => 'Sauvegarde faite',
      'backup.restore_scheduled' => 'Restauration prévue',
      'backup.restore_cancelled' => 'Restauration annulée',
      'maintenance.export' => 'Export des données',
      'maintenance.reset' => 'Données réinitialisées',
      'settings.logo' => 'Logo modifié',
      _ when a.startsWith('user.') => 'Utilisateur : ${a.substring(5).replaceAll('_', ' ')}',
      _ when a.startsWith('role.') => 'Rôle : ${a.substring(5).replaceAll('_', ' ')}',
      _ => a.replaceAll('_', ' ').replaceAll('.', ' · '),
    };

const _periods = <(String, String)>[
  ('today', 'Aujourd’hui'),
  ('7d', '7 derniers jours'),
  ('30d', '30 derniers jours'),
  ('month', 'Ce mois-ci'),
];

/// Paramètres → Journal d'activité: who did what, when — filterable.
class AuditSection extends StatefulWidget {
  const AuditSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<AuditSection> createState() => _AuditSectionState();
}

class _AuditSectionState extends State<AuditSection> {
  static const _prefs = 'settings_audit';

  final _search = TextEditingController();
  Timer? _debounce;
  List<AuditEntry> _items = const [];
  List<String> _actions = const [];
  List<User> _users = const [];
  bool _loading = true;
  String? _error;

  String? _userId = UiPrefs.instance.get<String>(_prefs, 'user');
  String? _action = UiPrefs.instance.get<String>(_prefs, 'action');
  String? _period = UiPrefs.instance.get<String>(_prefs, 'period') ?? '30d';

  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _api.users().then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  (String?, String?) _range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = switch (_period) {
      'today' => today,
      '7d' => today.subtract(const Duration(days: 6)),
      '30d' => today.subtract(const Duration(days: 29)),
      'month' => DateTime(now.year, now.month, 1),
      _ => null,
    };
    return (from?.toUtc().toIso8601String(), null);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (from, to) = _range();
    try {
      final (items, actions) = await _api.auditSearch(
        limit: 1000,
        userId: _userId,
        action: _action,
        from: from,
        to: to,
        q: _search.text,
      );
      if (mounted) {
        setState(() {
          _items = items;
          _actions = actions;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de lire le journal : $e';
        });
      }
    }
  }

  void _set(VoidCallback f) {
    setState(f);
    UiPrefs.instance.set(_prefs, 'user', _userId);
    UiPrefs.instance.set(_prefs, 'action', _action);
    UiPrefs.instance.set(_prefs, 'period', _period ?? 'all');
    _load();
  }

  String _userName(AuditEntry e) =>
      e.fullName.isNotEmpty ? e.fullName : (e.username.isNotEmpty ? e.username : 'Système');

  /// The detail is stored as « username — text »: drop the repeated name.
  String _detail(AuditEntry e) {
    final d = e.detail ?? '';
    final p = '${e.username} — ';
    return e.username.isNotEmpty && d.startsWith(p) ? d.substring(p.length) : d;
  }

  @override
  Widget build(BuildContext context) {
    final userName = {for (final u in _users) u.id: u.fullName.isEmpty ? u.username : u.fullName};
    final period = _period == 'all' ? null : _period;
    final actionOptions = <(String, String)>[
      for (final a in _actions) (a, auditActionLabel(a)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Journal d’activité', style: T.h1),
        const SizedBox(height: 6),
        Text('Qui a annulé un document, changé un prix, ouvert ou clôturé la caisse, fait une '
            'sauvegarde… Chaque action importante est notée avec la date et la personne.',
            style: T.bodyMuted),
        const SizedBox(height: 16),
        ListToolbar(
          search: _search,
          searchHint: 'Chercher dans le journal (n° de document, produit…)',
          onSearchChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), _load);
          },
          onSearchSubmitted: (_) => _load(),
          panel: FilterPanel(fields: [
            FilterField<String>(
              label: 'Utilisateur',
              value: _userId,
              allLabel: 'Tous',
              options: [for (final u in _users) (u.id, u.fullName.isEmpty ? u.username : u.fullName)],
              onChanged: (v) => _set(() => _userId = v),
            ),
            FilterField<String>(
              label: 'Action',
              value: _actions.contains(_action) ? _action : null,
              allLabel: 'Toutes',
              options: actionOptions,
              onChanged: (v) => _set(() => _action = v),
            ),
            FilterField<String>(
              label: 'Période',
              value: period,
              allLabel: 'Tout',
              options: _periods,
              onChanged: (v) => _set(() => _period = v ?? 'all'),
            ),
          ]),
          active: [
            if (_userId != null)
              ActiveFilter('Utilisateur : ${userName[_userId] ?? '…'}', () => _set(() => _userId = null)),
            if (_action != null)
              ActiveFilter('Action : ${auditActionLabel(_action!)}', () => _set(() => _action = null)),
            if (period != null)
              ActiveFilter(_periods.firstWhere((p) => p.$1 == period, orElse: () => (period, period)).$2,
                  () => _set(() => _period = 'all')),
          ],
          onClearAll: () {
            _search.clear();
            _set(() {
              _userId = null;
              _action = null;
              _period = 'all';
            });
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DataListView<AuditEntry>(
            items: _items,
            loading: _loading,
            error: _error,
            onRetry: _load,
            rowId: (e) => e.id,
            prefsKey: 'settings_audit_list',
            exportTitle: 'Journal d’activité',
            exportBaseName: 'journal-activite',
            columns: [
              ColumnSpec(
                label: 'Date et heure',
                width: 170,
                hideable: false,
                sortKey: (e) => e.createdAt,
                exportValue: (e) => fmtDateTime(e.createdAt),
                cell: (_, e) => Text(fmtDateTime(e.createdAt), style: T.monoBody),
              ),
              ColumnSpec(
                label: 'Utilisateur',
                flex: 2,
                sortKey: (e) => _userName(e).toLowerCase(),
                exportValue: _userName,
                cell: (_, e) => Text(_userName(e), style: T.body, overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec(
                label: 'Action',
                flex: 2,
                sortKey: (e) => auditActionLabel(e.action),
                exportValue: (e) => auditActionLabel(e.action),
                cell: (_, e) => Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: MintChip(auditActionLabel(e.action), color: T.cream, fg: T.ink),
                ),
              ),
              ColumnSpec(
                label: 'Détail',
                flex: 5,
                hideable: false,
                exportValue: _detail,
                cell: (_, e) => Text(_detail(e), style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
            onTap: (e) => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: T.surface,
                title: Text(auditActionLabel(e.action), style: T.h2),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${fmtDateTime(e.createdAt)} — ${_userName(e)}', style: T.bodyMuted),
                    const SizedBox(height: 10),
                    SelectableText(_detail(e), style: T.body),
                  ]),
                ),
                actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Fermer'))],
              ),
            ),
            empty: EmptyState(
              icon: Icons.history_rounded,
              text: _userId != null || _action != null || period != null || _search.text.isNotEmpty
                  ? 'Aucun événement avec ces filtres.'
                  : 'Aucun événement enregistré pour le moment.',
              actions: [
                if (_userId != null || _action != null || period != null || _search.text.isNotEmpty)
                  ('Effacer les filtres', () {
                    _search.clear();
                    _set(() {
                      _userId = null;
                      _action = null;
                      _period = 'all';
                    });
                  }),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
