import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/data_table.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../partners/partner_pages.dart' show openPartnerDetailById;
import 'bulk_actions.dart';
import 'crm_common.dart';
import 'send_message.dart';

/// Main criterion of a segment (SegmentRules.builtin).
const segmentCriteria = <String, String>{
  '': 'Aucun (seulement les filtres)',
  'inactive': 'Sans achat depuis…',
  'credit_usage': 'Crédit presque épuisé',
  'overdue': 'Factures en retard',
  'top_customers': 'Meilleurs clients',
  'declining': 'Achats en baisse',
  'new_customers': 'Nouveaux clients',
};

/// One plain sentence describing segment rules.
String describeRules(Map<String, dynamic> r,
    {List<CrmUser> users = const [], List<CrmRoute> routes = const [], List<CrmTag> tags = const []}) {
  int n(String k, int d) => (r[k] as num?)?.toInt() ?? d;
  final parts = <String>[];
  switch (r['builtin']) {
    case 'inactive':
      parts.add('sans achat depuis ${n('days', 30)} jours');
    case 'credit_usage':
      parts.add('crédit utilisé à ${n('min_pct', 80)} % ou plus');
    case 'overdue':
      parts.add('avec des factures échues impayées');
    case 'top_customers':
      parts.add('les ${n('limit', 20)} meilleurs clients sur ${n('period_days', 90)} jours');
    case 'declining':
      parts.add('achats en baisse d’au moins ${n('min_drop_pct', 20)} % (${n('period_days', 30)} j vs ${n('period_days', 30)} j avant)');
    case 'new_customers':
      parts.add('créés depuis ${n('days', 30)} jours');
  }
  if ((r['client_type'] ?? '') != '') parts.add('type ${clientTypeLabels[r['client_type']] ?? r['client_type']}');
  if ((r['crm_status'] ?? '') != '') parts.add('statut ${crmStatusLabels[r['crm_status']] ?? r['crm_status']}');
  if ((r['wilaya'] ?? '') != '') parts.add('wilaya ${r['wilaya']}');
  if ((r['rep_user_id'] ?? '') != '') {
    parts.add('commercial ${users.where((u) => u.id == r['rep_user_id']).firstOrNull?.name ?? '…'}');
  }
  if ((r['route_id'] ?? '') != '') {
    parts.add('tournée ${routes.where((x) => x.id == r['route_id']).firstOrNull?.name ?? '…'}');
  }
  if ((r['tag_id'] ?? '') != '') parts.add('étiquette ${tags.where((t) => t.id == r['tag_id']).firstOrNull?.name ?? '…'}');
  if (n('min_turnover', 0) > 0) parts.add('achats ≥ ${fmtDA(n('min_turnover', 0))}');
  if (n('min_balance', 0) > 0) parts.add('solde ≥ ${fmtDA(n('min_balance', 0))}');
  if (parts.isEmpty) return 'Tous les clients actifs.';
  final s = parts.join(', ');
  return 'Clients ${s[0].toLowerCase()}${s.substring(1)}.';
}

class SegmentsTab extends StatefulWidget {
  const SegmentsTab({super.key, required this.api});
  final ApiClient api;

  @override
  State<SegmentsTab> createState() => SegmentsTabState();
}

class SegmentsTabState extends State<SegmentsTab> {
  List<CrmSegment> _segments = const [];
  CrmSegment? _current;
  SegmentResult? _result;
  bool _loadingList = true;
  bool _evaluating = false;
  String? _error;
  List<CrmUser> _users = const [];
  List<CrmRoute> _routes = const [];
  List<CrmTag> _tags = const [];

  // Filters added on top of the segment (GET …/evaluate overrides).
  String? _clientType;
  String? _wilaya;
  String? _repId;
  String? _routeId;
  String? _tagId;
  String? _crmStatus;

  @override
  void initState() {
    super.initState();
    _loadList();
    CrmDirectory.users(widget.api).then((u) {
      if (mounted) setState(() => _users = u);
    }).catchError((_) {});
    CrmDirectory.routes(widget.api).then((r) {
      if (mounted) setState(() => _routes = r);
    });
    CrmDirectory.tags(widget.api).then((t) {
      if (mounted) setState(() => _tags = t);
    });
  }

  Future<void> _loadList({String? select}) async {
    try {
      final s = await widget.api.crmSegments();
      if (!mounted) return;
      setState(() {
        _segments = s;
        _loadingList = false;
      });
      final pick = s.where((x) => x.id == (select ?? _current?.id)).firstOrNull ?? (s.isEmpty ? null : s.first);
      if (pick != null) _select(pick);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingList = false;
          _error = errText(e);
        });
      }
    }
  }

  void _select(CrmSegment s) {
    setState(() => _current = s);
    _evaluate();
  }

  Future<void> _evaluate() async {
    final s = _current;
    if (s == null) return;
    setState(() {
      _evaluating = true;
      _error = null;
    });
    try {
      final r = await widget.api.crmEvaluateSegment(s.id, overrides: {
        'client_type': ?_clientType,
        'wilaya': ?_wilaya,
        'rep_user_id': ?_repId,
        'route_id': ?_routeId,
        'tag_id': ?_tagId,
        'crm_status': ?_crmStatus,
      });
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _evaluating = false);
  }

  Future<void> newSegment() async {
    final saved = await Navigator.of(context).push<CrmSegment>(MaterialPageRoute(
        builder: (_) => SegmentFormPage(api: widget.api, users: _users, routes: _routes, tags: _tags)));
    if (saved != null) _loadList(select: saved.id);
  }

  Future<void> _edit(CrmSegment s) async {
    final saved = await Navigator.of(context).push<CrmSegment>(MaterialPageRoute(
        builder: (_) => SegmentFormPage(api: widget.api, existing: s, users: _users, routes: _routes, tags: _tags)));
    if (saved != null) _loadList(select: saved.id);
  }

  /// Built-in segment copied as a saved one the user can change.
  Future<void> _copy(CrmSegment s) async {
    final saved = await Navigator.of(context).push<CrmSegment>(MaterialPageRoute(
        builder: (_) => SegmentFormPage(
            api: widget.api,
            initialName: '${s.name} (copie)',
            initialRules: s.rules,
            users: _users,
            routes: _routes,
            tags: _tags)));
    if (saved != null) _loadList(select: saved.id);
  }

  void _setFilter(void Function() f) {
    setState(f);
    _evaluate();
  }

  List<BulkClient> _bulk(List<CustomerMetric> rows) => [
        for (final m in rows) BulkClient(id: m.partnerId, name: m.name, tagIds: m.tagIds, repUserId: m.repUserId),
      ];

  @override
  Widget build(BuildContext context) {
    final canEdit = crmEdit(widget.api);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 270,
        child: Card14(
          padding: EdgeInsets.zero,
          child: _loadingList
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
                  _groupLabel('Prêts à l’emploi'),
                  for (final s in _segments.where((s) => s.builtin)) _segmentRow(s),
                  _groupLabel('Mes segments'),
                  for (final s in _segments.where((s) => !s.builtin)) _segmentRow(s),
                  if (!_segments.any((s) => !s.builtin))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text('Aucun segment enregistré.', style: T.small),
                    ),
                  if (canEdit)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: OutlinedButton.icon(
                        onPressed: newSegment,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Nouveau segment'),
                      ),
                    ),
                ]),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(child: _results(canEdit)),
    ]);
  }

  Widget _groupLabel(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(s, style: T.label),
      );

  Widget _segmentRow(CrmSegment s) {
    final sel = s.id == _current?.id;
    return InkWell(
      onTap: () => _select(s),
      child: Container(
        color: sel ? T.mintTint : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
        child: Row(children: [
          Container(width: 3, height: 18, color: sel ? T.mint : Colors.transparent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(s.name,
                style: T.body.copyWith(fontSize: 14, fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
          ),
        ]),
      ),
    );
  }

  Widget _results(bool canEdit) {
    final s = _current;
    if (s == null) {
      return EmptyState(
          icon: Icons.groups_2_outlined,
          text: 'Choisissez un segment à gauche.',
          actions: [if (canEdit) ('Nouveau segment', newSegment)]);
    }
    final r = _result;
    final rules = s.rules;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: T.h2),
            const SizedBox(height: 4),
            Text(describeRules(rules, users: _users, routes: _routes, tags: _tags), style: T.bodyMuted),
            if (r != null) ...[
              const SizedBox(height: 4),
              Text(
                  '${r.count} client(s) · achats ${fmtDA(r.totalTurnover)} du ${crmDate(r.periodFrom)} au ${crmDate(r.periodTo)} · '
                  'solde total ${fmtDA(r.totalBalance)}',
                  style: T.small),
            ],
          ]),
        ),
        if (canEdit && !s.builtin)
          OutlinedButton.icon(
              onPressed: () => _edit(s), icon: const Icon(Icons.tune_rounded, size: 18), label: const Text('Modifier les règles')),
        if (canEdit && s.builtin)
          OutlinedButton.icon(
              onPressed: () => _copy(s),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copier et personnaliser')),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _evaluating ? null : _evaluate,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Actualiser'),
        ),
      ]),
      const SizedBox(height: 12),
      FilterPanel(fields: [
        FilterField<String>(
          label: 'Type de client',
          value: _clientType,
          width: 170,
          options: [for (final e in clientTypeLabels.entries) (e.key, e.value)],
          onChanged: (v) => _setFilter(() => _clientType = v),
        ),
        FilterField<String>(
          label: 'Statut',
          value: _crmStatus,
          width: 150,
          options: [for (final e in crmStatusLabels.entries) (e.key, e.value)],
          onChanged: (v) => _setFilter(() => _crmStatus = v),
        ),
        FilterField<String>(
          label: 'Wilaya',
          value: _wilaya,
          allLabel: 'Toutes',
          width: 170,
          options: [for (final (c, n) in wilayas) (n, '$c · $n')],
          onChanged: (v) => _setFilter(() => _wilaya = v),
        ),
        if (_users.isNotEmpty)
          FilterField<String>(
            label: 'Commercial',
            value: _repId,
            width: 170,
            options: [for (final u in _users) (u.id, u.name)],
            onChanged: (v) => _setFilter(() => _repId = v),
          ),
        if (_routes.isNotEmpty)
          FilterField<String>(
            label: 'Tournée',
            value: _routeId,
            allLabel: 'Toutes',
            width: 170,
            options: [for (final x in _routes) (x.id, x.name)],
            onChanged: (v) => _setFilter(() => _routeId = v),
          ),
        if (_tags.isNotEmpty)
          FilterField<String>(
            label: 'Étiquette',
            value: _tagId,
            allLabel: 'Toutes',
            width: 170,
            options: [for (final t in _tags) (t.id, t.name)],
            onChanged: (v) => _setFilter(() => _tagId = v),
          ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: DataListView<CustomerMetric>(
          items: r?.items ?? const [],
          loading: _evaluating && r == null,
          error: _error,
          onRetry: _evaluate,
          prefsKey: 'crm_segment_results',
          rowId: (m) => m.partnerId,
          onTap: (m) => openPartnerDetailById(context, widget.api, m.partnerId),
          exportTitle: 'Segment — ${s.name}',
          exportBaseName: 'segment-${s.name.replaceAll(RegExp(r'[^\w-]+'), '_')}',
          rowMenu: (m) => [
            RowAction('Ouvrir la fiche', Icons.open_in_new_rounded,
                (m) => openPartnerDetailById(context, widget.api, m.partnerId)),
            RowAction('Envoyer un message', Icons.chat_outlined,
                (m) => showSendMessagePanel(context, widget.api, partnerId: m.partnerId, partnerName: m.name)),
            if (canEdit)
              RowAction('Créer une tâche', Icons.add_task_rounded,
                  (m) => openTaskForm(context, widget.api, partnerId: m.partnerId, partnerName: m.name)),
          ],
          bulkActions: [
            if (crmCan(widget.api, 'partners.edit'))
              BulkAction('Attribuer un commercial', Icons.badge_outlined, (rows) async {
                final done = await bulkAssignRep(context, widget.api, _bulk(rows));
                if (done) _evaluate();
                return done;
              }),
            if (crmEditFiche(widget.api))
              BulkAction('Ajouter une étiquette', Icons.sell_outlined, (rows) async {
                final done = await bulkAddTag(context, widget.api, _bulk(rows));
                if (done) _evaluate();
                return done;
              }),
            if (canEdit)
              BulkAction('Créer une tâche', Icons.add_task_rounded,
                  (rows) => bulkCreateTasks(context, widget.api, _bulk(rows))),
            BulkAction('Message WhatsApp', Icons.chat_outlined, (rows) async {
              await bulkWhatsApp(context, widget.api, _bulk(rows));
              return false;
            }),
          ],
          aggregates: (rows) => [
            ('Clients', '${rows.length}'),
            ('Achats', fmtDA(rows.fold(0, (a, m) => a + m.turnover))),
            ('Solde', fmtDA(rows.fold(0, (a, m) => a + m.balance))),
            ('Impayés', fmtDA(rows.fold(0, (a, m) => a + m.overdueAmount))),
          ],
          empty: const EmptyState(icon: Icons.groups_2_outlined, text: 'Aucun client dans ce segment.'),
          columns: [
            ColumnSpec(
              id: 'name',
              label: 'Client',
              flex: 3,
              hideable: false,
              sortKey: (m) => m.name.toLowerCase(),
              exportValue: (m) => m.name,
              cell: (_, m) => Text(m.name, style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'phone',
              label: 'Téléphone',
              width: 130,
              exportValue: (m) => m.phone,
              cell: (_, m) => Text(m.phone.isEmpty ? '—' : m.phone, style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'type',
              label: 'Type',
              width: 110,
              visibleByDefault: false,
              sortKey: (m) => m.clientType,
              exportValue: (m) => clientTypeLabels[m.clientType] ?? m.clientType,
              cell: (_, m) => Text(clientTypeLabels[m.clientType] ?? m.clientType, style: T.small),
            ),
            ColumnSpec(
              id: 'wilaya',
              label: 'Wilaya',
              width: 120,
              sortKey: (m) => m.wilaya,
              exportValue: (m) => m.wilaya,
              cell: (_, m) => Text(m.wilaya.isEmpty ? '—' : m.wilaya, style: T.small, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'rep',
              label: 'Commercial',
              width: 130,
              visibleByDefault: false,
              sortKey: (m) => m.repName,
              exportValue: (m) => m.repName,
              cell: (_, m) => Text(m.repName.isEmpty ? '—' : m.repName, style: T.small, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'turnover',
              label: 'Achats période',
              width: 140,
              numeric: true,
              sortKey: (m) => m.turnover,
              exportValue: (m) => m.turnover / 100,
              cell: (_, m) => Tooltip(
                message: 'Période précédente : ${fmtDA(m.turnoverPrevious)} · ${m.ordersCount} commande(s)',
                child: Text(fmtDA(m.turnover), style: T.monoBody),
              ),
            ),
            ColumnSpec(
              id: 'previous',
              label: 'Période précédente',
              width: 140,
              numeric: true,
              visibleByDefault: false,
              sortKey: (m) => m.turnoverPrevious,
              exportValue: (m) => m.turnoverPrevious / 100,
              cell: (_, m) => Text(fmtDA(m.turnoverPrevious), style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'last',
              label: 'Dernier achat',
              width: 125,
              sortKey: (m) => m.daysSinceLastOrder < 0 ? 1 << 30 : m.daysSinceLastOrder,
              exportValue: (m) => m.lastOrderDate,
              cell: (_, m) => Tooltip(
                message: daysAgo(m.daysSinceLastOrder),
                child: Text(m.lastOrderDate.isEmpty ? 'Jamais' : crmDate(m.lastOrderDate),
                    style: T.monoSmall.copyWith(color: m.daysSinceLastOrder > 60 ? T.warnDark : T.muted)),
              ),
            ),
            ColumnSpec(
              id: 'balance',
              label: 'Solde',
              width: 130,
              numeric: true,
              sortKey: (m) => m.balance,
              exportValue: (m) => m.balance / 100,
              cell: (_, m) => Text(fmtDA(m.balance),
                  style: T.monoBody.copyWith(color: m.balance > 0 ? T.warnDark : T.ink)),
            ),
            ColumnSpec(
              id: 'credit',
              label: 'Crédit utilisé',
              width: 110,
              numeric: true,
              sortKey: (m) => m.creditUsagePct,
              exportValue: (m) => m.creditLimit > 0 ? m.creditUsagePct : '',
              cell: (_, m) => Text(m.creditLimit > 0 ? '${m.creditUsagePct} %' : '—',
                  style: T.monoSmall.copyWith(
                      color: m.creditUsagePct >= 100
                          ? T.dangerDark
                          : m.creditUsagePct >= 80
                              ? T.warnDark
                              : T.muted)),
            ),
            ColumnSpec(
              id: 'overdue',
              label: 'Impayés échus',
              width: 130,
              numeric: true,
              sortKey: (m) => m.overdueAmount,
              exportValue: (m) => m.overdueAmount / 100,
              cell: (_, m) => Text(m.overdueAmount > 0 ? fmtDA(m.overdueAmount) : '—',
                  style: T.monoSmall.copyWith(color: m.overdueAmount > 0 ? T.dangerDark : T.muted)),
            ),
          ],
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Rule builder page
// ---------------------------------------------------------------------------

class SegmentFormPage extends StatefulWidget {
  const SegmentFormPage({
    super.key,
    required this.api,
    this.existing,
    this.initialName,
    this.initialRules,
    this.users = const [],
    this.routes = const [],
    this.tags = const [],
  });
  final ApiClient api;
  final CrmSegment? existing;
  final String? initialName;
  final Map<String, dynamic>? initialRules;
  final List<CrmUser> users;
  final List<CrmRoute> routes;
  final List<CrmTag> tags;

  @override
  State<SegmentFormPage> createState() => _SegmentFormPageState();
}

class _SegmentFormPageState extends State<SegmentFormPage> {
  late final Map<String, dynamic> _r = {...(widget.existing?.rules ?? widget.initialRules ?? const {})};
  late final _name = TextEditingController(text: widget.existing?.name ?? widget.initialName ?? '');
  late final _days = TextEditingController(text: _numText('days'));
  late final _minPct = TextEditingController(text: _numText('min_pct'));
  late final _minDrop = TextEditingController(text: _numText('min_drop_pct'));
  late final _limit = TextEditingController(text: _numText('limit'));
  late final _period = TextEditingController(text: _numText('period_days'));
  late final _minTurnover = TextEditingController(
      text: ((_r['min_turnover'] as num?)?.toInt() ?? 0) > 0 ? editDA((_r['min_turnover'] as num).toInt()) : '');
  late final _minBalance = TextEditingController(
      text: ((_r['min_balance'] as num?)?.toInt() ?? 0) > 0 ? editDA((_r['min_balance'] as num).toInt()) : '');
  List<CustomerGroup> _groups = const [];
  bool _busy = false;
  String? _err;
  String? _preview;

  String _numText(String k) => (_r[k] as num?) == null ? '' : '${(_r[k] as num).toInt()}';

  String get _builtin => (_r['builtin'] as String?) ?? '';

  @override
  void initState() {
    super.initState();
    widget.api.customerGroups().then((g) {
      if (mounted) setState(() => _groups = g);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _days, _minPct, _minDrop, _limit, _period, _minTurnover, _minBalance]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Rules as the server expects them (empty values left out).
  Map<String, dynamic>? _rules() {
    final out = <String, dynamic>{};
    String? bad;
    void num(String key, TextEditingController c) {
      final t = c.text.trim();
      if (t.isEmpty) return;
      final v = int.tryParse(t);
      if (v == null || v < 0) {
        bad = 'Nombre invalide : « $t ».';
        return;
      }
      out[key] = v;
    }

    if (_builtin.isNotEmpty) out['builtin'] = _builtin;
    if (_builtin == 'inactive' || _builtin == 'new_customers') num('days', _days);
    if (_builtin == 'credit_usage') num('min_pct', _minPct);
    if (_builtin == 'declining') num('min_drop_pct', _minDrop);
    if (_builtin == 'top_customers') num('limit', _limit);
    num('period_days', _period);
    for (final k in ['client_type', 'crm_status', 'tag_id', 'wilaya', 'rep_user_id', 'route_id', 'group_id']) {
      final v = _r[k];
      if (v is String && v.isNotEmpty) out[k] = v;
    }
    for (final (k, c) in [('min_turnover', _minTurnover), ('min_balance', _minBalance)]) {
      if (c.text.trim().isEmpty) continue;
      final v = parseDA(c.text);
      if (v == null || v < 0) {
        bad = 'Montant invalide : « ${c.text} ».';
      } else if (v > 0) {
        out[k] = v;
      }
    }
    if (bad != null) {
      setState(() => _err = bad);
      return null;
    }
    return out;
  }

  Future<void> _previewCount() async {
    final r = _rules();
    if (r == null) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final res = await widget.api.crmEvaluateRules(r);
      setState(() => _preview = '${res.count} client(s) correspondent · achats ${fmtDA(res.totalTurnover)}.');
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _err = 'Donnez un nom au segment.');
      return;
    }
    final r = _rules();
    if (r == null) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final s = await widget.api.crmSaveSegment(_name.text.trim(), r, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, 'Segment « ${s.name} » enregistré.');
      Navigator.of(context).pop(s);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final s = widget.existing!;
    final ok = await confirmAction(context,
        title: 'Supprimer le segment « ${s.name} » ?',
        message: 'Les clients ne sont pas touchés, seule la liste enregistrée disparaît.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteSegment(s.id);
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  Widget _strFilter(String label, String key, List<(String, String)> options, {String none = 'Tous'}) =>
      DropdownBlock<String>(
        label: label,
        value: (_r[key] as String?)?.isEmpty == true ? null : _r[key] as String?,
        noneLabel: none,
        options: options,
        onChanged: (v) => setState(() => _r[key] = v ?? ''),
      );

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final b = _builtin;
    return AppPage(
      crumbs: [Crumb('Segments', () => Navigator.of(context).pop()), Crumb(isNew ? 'Nouveau segment' : 'Modifier')],
      title: isNew ? 'Nouveau segment' : 'Modifier ${widget.existing!.name}',
      maxWidth: 820,
      actions: [
        if (!isNew) PageAction(label: 'Supprimer', danger: true, onPressed: _busy ? null : _delete),
        PageAction(label: 'Aperçu', icon: Icons.visibility_outlined, onPressed: _busy ? null : _previewCount),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageSection(
          title: 'Nom',
          child: TextBlock(label: 'Nom du segment', required: true, controller: _name, hint: 'Ex. Supérettes d’Alger à relancer'),
        ),
        PageSection(
          title: 'Critère principal',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ChoiceRow<String>(
              options: [for (final e in segmentCriteria.entries) (e.key, e.value)],
              value: b,
              onSelect: (v) => setState(() => _r['builtin'] = v),
            ),
            const SizedBox(height: 14),
            if (b == 'inactive' || b == 'new_customers')
              SizedBox(
                  width: 300,
                  child: TextBlock(
                      label: b == 'inactive' ? 'Sans achat depuis (jours)' : 'Créés depuis (jours)',
                      controller: _days,
                      hint: '30',
                      keyboard: TextInputType.number)),
            if (b == 'credit_usage')
              SizedBox(
                  width: 300,
                  child: TextBlock(
                      label: 'Crédit utilisé à partir de (%)', controller: _minPct, hint: '80', keyboard: TextInputType.number)),
            if (b == 'declining')
              SizedBox(
                  width: 300,
                  child: TextBlock(
                      label: 'Baisse d’au moins (%)', controller: _minDrop, hint: '20', keyboard: TextInputType.number)),
            if (b == 'top_customers')
              SizedBox(
                  width: 300,
                  child: TextBlock(label: 'Combien de clients', controller: _limit, hint: '20', keyboard: TextInputType.number)),
            SizedBox(
              width: 300,
              child: TextBlock(
                label: 'Période des achats (jours)',
                controller: _period,
                hint: b == 'declining' ? '30' : '90',
                keyboard: TextInputType.number,
                helper: 'Pour la colonne « Achats période ».',
              ),
            ),
          ]),
        ),
        PageSection(
          title: 'Filtres',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                  child: _strFilter('Type de client', 'client_type',
                      [for (final e in clientTypeLabels.entries) (e.key, e.value)])),
              const SizedBox(width: 14),
              Expanded(
                  child: _strFilter('Statut', 'crm_status', [for (final e in crmStatusLabels.entries) (e.key, e.value)])),
            ]),
            Row(children: [
              Expanded(
                  child: _strFilter('Wilaya', 'wilaya', [for (final (c, n) in wilayas) (n, '$c · $n')], none: 'Toutes')),
              const SizedBox(width: 14),
              Expanded(
                  child: _strFilter('Étiquette', 'tag_id', [for (final t in widget.tags) (t.id, t.name)], none: 'Toutes')),
            ]),
            Row(children: [
              Expanded(child: _strFilter('Commercial', 'rep_user_id', [for (final u in widget.users) (u.id, u.name)])),
              const SizedBox(width: 14),
              Expanded(
                  child: _strFilter('Tournée', 'route_id', [for (final x in widget.routes) (x.id, x.name)], none: 'Toutes')),
            ]),
            if (_groups.isNotEmpty)
              _strFilter('Groupe de clients', 'group_id', [for (final g in _groups) (g.id, g.name)]),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: TextBlock(
                      label: 'Achats minimum sur la période (DA)',
                      controller: _minTurnover,
                      keyboard: const TextInputType.numberWithOptions(decimal: true))),
              const SizedBox(width: 14),
              Expanded(
                  child: TextBlock(
                      label: 'Solde minimum (DA)',
                      controller: _minBalance,
                      keyboard: const TextInputType.numberWithOptions(decimal: true))),
            ]),
          ]),
        ),
        if (_preview != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: T.mintTint, borderRadius: BorderRadius.circular(T.rInner)),
            child: Text(_preview!, style: T.body.copyWith(fontWeight: FontWeight.w700, color: T.mintDark)),
          ),
        if (_err != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: FieldError(_err)),
      ]),
    );
  }
}
