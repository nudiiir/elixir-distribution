import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/data_table.dart';
import '../../widgets/ui.dart';
import '../partners/partner_pages.dart' show openPartnerDetail;
import 'bulk_actions.dart';
import 'crm_common.dart';

/// « Commerciaux » : performance of the month vs targets, targets, portfolio.
class RepsTab extends StatefulWidget {
  const RepsTab({super.key, required this.api});
  final ApiClient api;

  @override
  State<RepsTab> createState() => RepsTabState();
}

class RepsTabState extends State<RepsTab> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<RepPerf> _items = const [];
  bool _loading = true;
  String? _error;

  String get _key => monthKey(_month);

  /// Targets can be set by crm.edit users that are not restricted to their own clients.
  bool get _canTarget => crmEdit(widget.api) && (widget.api.user?.scope ?? 'all') != 'own';

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.crmRepPerformance(_key);
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _shift(int d) {
    setState(() => _month = DateTime(_month.year, _month.month + d));
    reload();
  }

  Future<void> setTargets([RepPerf? rep]) async {
    var r = rep;
    if (r == null) {
      final users = await CrmDirectory.users(widget.api);
      if (!mounted) return;
      final id = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: T.surface,
          title: const Text('Objectifs de quel commercial ?', style: T.h2),
          children: [
            SizedBox(
              width: 400,
              height: users.length > 8 ? 400 : null,
              child: ListView(shrinkWrap: true, children: [
                for (final u in users)
                  SimpleDialogOption(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    onPressed: () => Navigator.of(ctx).pop(u.id),
                    child: Text(u.name, style: T.body),
                  ),
              ]),
            ),
          ],
        ),
      );
      if (id == null || !mounted) return;
      r = _items.where((x) => x.userId == id).firstOrNull;
      final name = users.firstWhere((u) => u.id == id).name;
      final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => RepTargetPage(api: widget.api, userId: id, userName: name, month: _key, current: r?.targets)));
      if (saved == true) reload();
      return;
    }
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) =>
            RepTargetPage(api: widget.api, userId: r!.userId, userName: r.name, month: _key, current: r.targets)));
    if (saved == true) reload();
  }

  Future<void> _portfolio(RepPerf r) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RepPortfolioPage(api: widget.api, userId: r.userId, userName: r.name)));
    if (mounted) reload();
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = _key == monthKey(DateTime.now());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(
            tooltip: 'Mois précédent', onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left_rounded)),
        SizedBox(
          width: 170,
          child: Text(monthLabel(_key)[0].toUpperCase() + monthLabel(_key).substring(1),
              textAlign: TextAlign.center, style: T.h2),
        ),
        IconButton(
            tooltip: 'Mois suivant',
            onPressed: isCurrent ? null : () => _shift(1),
            icon: const Icon(Icons.chevron_right_rounded)),
        if (!isCurrent)
          TextButton(
              onPressed: () {
                setState(() => _month = DateTime(DateTime.now().year, DateTime.now().month));
                reload();
              },
              child: const Text('Ce mois-ci')),
        const Spacer(),
        if (_canTarget)
          OutlinedButton.icon(
            onPressed: () => setTargets(),
            icon: const Icon(Icons.flag_outlined, size: 18),
            label: const Text('Fixer des objectifs'),
          ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: _loading && _items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(icon: Icons.error_outline_rounded, text: _error!, actions: [('Réessayer', reload)])
                : _items.isEmpty
                    ? EmptyState(
                        icon: Icons.badge_outlined,
                        text: 'Aucun commercial ce mois-ci. Attribuez un commercial à vos clients '
                            '(fiche client › Modifier) ou fixez-lui des objectifs.',
                        actions: [if (_canTarget) ('Fixer des objectifs', () => setTargets())])
                    : ListView(children: [for (final r in _items) _card(r)]),
      ),
    ]);
  }

  Widget _card(RepPerf r) {
    final t = r.targets;
    Widget metric(String label, String value, String? target, int? pct) => SizedBox(
          width: 200,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label),
            const SizedBox(height: 3),
            Text(value, style: T.monoBody.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
            if (target != null) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: ((pct ?? 0) / 100).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: T.border2,
                  color: (pct ?? 0) >= 100 ? T.mint : ((pct ?? 0) >= 60 ? T.warn : T.danger),
                ),
              ),
              const SizedBox(height: 2),
              Text('${pct ?? 0} % de $target', style: T.small),
            ] else
              Text('Pas d’objectif', style: T.small.copyWith(color: T.ghost)),
          ]),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
          color: T.surface, borderRadius: BorderRadius.circular(T.rCard), border: Border.all(color: T.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.badge_outlined, size: 20, color: T.mintDark),
          const SizedBox(width: 10),
          Expanded(child: Text(r.name, style: T.h2)),
          Text('${r.customers} client(s) · ${r.calls} appel(s)', style: T.bodyMuted),
          const SizedBox(width: 12),
          TextButton.icon(
              onPressed: () => _portfolio(r),
              icon: const Icon(Icons.people_alt_outlined, size: 17),
              label: const Text('Ses clients')),
          if (_canTarget)
            TextButton.icon(
                onPressed: () => setTargets(r),
                icon: const Icon(Icons.flag_outlined, size: 17),
                label: Text(t == null ? 'Fixer les objectifs' : 'Modifier les objectifs')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 18, runSpacing: 14, children: [
          metric('Ventes', fmtDA(r.sales), t == null || t.salesTarget == 0 ? null : fmtDA(t.salesTarget),
              r.achievement['sales']),
          metric('Commandes', '${r.ordersCount}', t == null || t.ordersTarget == 0 ? null : '${t.ordersTarget}',
              r.achievement['orders']),
          metric('Nouveaux clients', '${r.newCustomers}',
              t == null || t.newCustomersTarget == 0 ? null : '${t.newCustomersTarget}', r.achievement['new_customers']),
          metric('Visites', '${r.visits}', t == null || t.visitsTarget == 0 ? null : '${t.visitsTarget}',
              r.achievement['visits']),
          metric('Encaissements', fmtDA(r.collections),
              t == null || t.collectionsTarget == 0 ? null : fmtDA(t.collectionsTarget), r.achievement['collections']),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Targets page
// ---------------------------------------------------------------------------

class RepTargetPage extends StatefulWidget {
  const RepTargetPage(
      {super.key, required this.api, required this.userId, required this.userName, required this.month, this.current});
  final ApiClient api;
  final String userId;
  final String userName;
  final String month;
  final RepTarget? current;

  @override
  State<RepTargetPage> createState() => _RepTargetPageState();
}

class _RepTargetPageState extends State<RepTargetPage> {
  late final _sales = TextEditingController(text: _da(widget.current?.salesTarget));
  late final _orders = TextEditingController(text: _n(widget.current?.ordersTarget));
  late final _visits = TextEditingController(text: _n(widget.current?.visitsTarget));
  late final _newc = TextEditingController(text: _n(widget.current?.newCustomersTarget));
  late final _coll = TextEditingController(text: _da(widget.current?.collectionsTarget));
  bool _busy = false;
  String? _err;

  static String _da(int? v) => v == null || v == 0 ? '' : editDA(v);
  static String _n(int? v) => v == null || v == 0 ? '' : '$v';

  @override
  void dispose() {
    for (final c in [_sales, _orders, _visits, _newc, _coll]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    int? money(TextEditingController c) => c.text.trim().isEmpty ? 0 : parseDA(c.text);
    int? count(TextEditingController c) => c.text.trim().isEmpty ? 0 : int.tryParse(c.text.trim());
    final s = money(_sales), co = money(_coll), o = count(_orders), v = count(_visits), n = count(_newc);
    if ([s, co, o, v, n].any((x) => x == null || x < 0)) {
      setState(() => _err = 'Vérifiez les montants et les nombres.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.api.crmSaveRepTarget({
        'user_id': widget.userId,
        'month': widget.month,
        'sales_target': s,
        'orders_target': o,
        'visits_target': v,
        'new_customers_target': n,
        'collections_target': co,
      });
      if (!mounted) return;
      showToast(context, 'Objectifs de ${widget.userName} enregistrés.');
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _err = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      crumbs: [Crumb('Commerciaux', () => Navigator.of(context).pop()), Crumb(widget.userName)],
      title: 'Objectifs de ${widget.userName}',
      subtitle: Text('Pour ${monthLabel(widget.month)}. Vide = pas d’objectif.', style: T.bodyMuted),
      maxWidth: 720,
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      body: PageSection(
        title: 'Objectifs du mois',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextBlock(
              label: 'Ventes (DA, TTC)',
              controller: _sales,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              helper: 'Total de ses commandes du mois.'),
          TextBlock(label: 'Nombre de commandes', controller: _orders, keyboard: TextInputType.number),
          TextBlock(label: 'Nouveaux clients', controller: _newc, keyboard: TextInputType.number),
          TextBlock(label: 'Visites', controller: _visits, keyboard: TextInputType.number),
          TextBlock(
              label: 'Encaissements (DA)',
              controller: _coll,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              helper: 'Paiements reçus de ses clients dans le mois.'),
          FieldError(_err),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Portfolio page (clients of a rep) + reassignment
// ---------------------------------------------------------------------------

class RepPortfolioPage extends StatefulWidget {
  const RepPortfolioPage({super.key, required this.api, required this.userId, required this.userName});
  final ApiClient api;
  final String userId;
  final String userName;

  @override
  State<RepPortfolioPage> createState() => _RepPortfolioPageState();
}

class _RepPortfolioPageState extends State<RepPortfolioPage> {
  List<Partner> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await widget.api.crmPartners(kind: 'customer', repUserId: widget.userId);
      if (mounted) setState(() => _items = p);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  List<BulkClient> _bulk(List<Partner> rows) =>
      [for (final p in rows) BulkClient(id: p.id, name: p.name, tagIds: p.tagIds, repUserId: p.repUserId)];

  @override
  Widget build(BuildContext context) {
    final canReassign = crmCan(widget.api, 'partners.edit') && crmEdit(widget.api);
    return AppPage(
      crumbs: [Crumb('Commerciaux', () => Navigator.of(context).pop()), Crumb(widget.userName)],
      title: 'Clients de ${widget.userName}',
      subtitle: Text(
          canReassign
              ? '${_items.length} client(s). Cochez des clients puis « Réattribuer » pour les confier à un autre commercial.'
              : '${_items.length} client(s).',
          style: T.bodyMuted),
      scroll: false,
      actions: [
        if (canReassign && _items.isNotEmpty)
          PageAction(
              label: 'Tout réattribuer',
              icon: Icons.swap_horiz_rounded,
              onPressed: () async {
                if (await bulkAssignRep(context, widget.api, _bulk(_items))) _load();
              }),
      ],
      body: DataListView<Partner>(
        items: _items,
        loading: _loading,
        error: _error,
        onRetry: _load,
        prefsKey: 'crm_portfolio',
        rowId: (p) => p.id,
        onTap: (p) async {
          await openPartnerDetail(context, widget.api, p);
          if (mounted) _load();
        },
        exportTitle: 'Clients de ${widget.userName}',
        exportBaseName: 'portefeuille',
        bulkActions: [
          if (canReassign)
            BulkAction('Réattribuer', Icons.swap_horiz_rounded, (rows) async {
              final done = await bulkAssignRep(context, widget.api, _bulk(rows));
              if (done) _load();
              return done;
            }),
        ],
        empty: const EmptyState(icon: Icons.people_alt_outlined, text: 'Aucun client attribué.'),
        columns: [
          ColumnSpec(
              id: 'name',
              label: 'Client',
              flex: 3,
              hideable: false,
              sortKey: (p) => p.name.toLowerCase(),
              exportValue: (p) => p.name,
              cell: (_, p) => Text(p.name, style: T.body, overflow: TextOverflow.ellipsis)),
          ColumnSpec(
              id: 'phone',
              label: 'Téléphone',
              width: 140,
              exportValue: (p) => p.phone ?? '',
              cell: (_, p) => Text(p.phone ?? '—', style: T.monoSmall)),
          ColumnSpec(
              id: 'type',
              label: 'Type',
              width: 120,
              sortKey: (p) => p.clientType,
              exportValue: (p) => clientTypeLabels[p.clientType] ?? p.clientType,
              cell: (_, p) => Text(clientTypeLabels[p.clientType] ?? p.clientType, style: T.small)),
          ColumnSpec(
              id: 'status',
              label: 'Statut',
              width: 110,
              sortKey: (p) => p.crmStatus,
              exportValue: (p) => crmStatusLabels[p.crmStatus] ?? p.crmStatus,
              cell: (_, p) => Align(alignment: AlignmentDirectional.centerStart, child: CrmStatusChip(p.crmStatus))),
          ColumnSpec(
              id: 'wilaya',
              label: 'Wilaya',
              width: 140,
              sortKey: (p) => p.wilaya,
              exportValue: (p) => p.wilaya,
              cell: (_, p) => Text(p.wilaya.isEmpty ? '—' : p.wilaya, style: T.small)),
          ColumnSpec(
              id: 'balance',
              label: 'Solde',
              width: 140,
              numeric: true,
              sortKey: (p) => p.balance,
              exportValue: (p) => p.balance / 100,
              cell: (_, p) => Text(fmtDA(p.balance), style: T.monoBody)),
        ],
      ),
    );
  }
}
