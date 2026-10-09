import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../partners/partner_pages.dart' show openPartnerDetail;
import 'crm_common.dart';

/// « Par wilaya » : clients grouped by wilaya or by delivery route, with
/// counts — a list instead of a map (no map dependency).
class WilayaTab extends StatefulWidget {
  const WilayaTab({super.key, required this.api});
  final ApiClient api;

  @override
  State<WilayaTab> createState() => WilayaTabState();
}

class _Group {
  _Group(this.key, this.label);
  final String key;
  final String label;
  final List<Partner> clients = [];
  int get active => clients.where((p) => p.crmStatus == 'active').length;
  int get prospects => clients.where((p) => p.crmStatus == 'prospect').length;
  int get dormant => clients.where((p) => p.crmStatus == 'dormant').length;
  int get blocked => clients.where((p) => p.crmStatus == 'blocked').length;
  int get balance => clients.fold(0, (s, p) => s + p.balance);
}

class WilayaTabState extends State<WilayaTab> {
  bool _byRoute = false;
  String? _status;
  String? _clientType;
  List<Partner> _all = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _open = {};

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
      final out = <Partner>[];
      for (var offset = 0; offset < 5000; offset += 500) {
        final page = await widget.api.crmPartners(kind: 'customer', limit: 500, offset: offset);
        out.addAll(page);
        if (page.length < 500) break;
      }
      if (mounted) setState(() => _all = out);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  List<_Group> get _groups {
    final map = <String, _Group>{};
    for (final p in _all) {
      if (_status != null && p.crmStatus != _status) continue;
      if (_clientType != null && p.clientType != _clientType) continue;
      final key = _byRoute ? (p.routeId ?? '') : p.wilaya.toLowerCase();
      final label = _byRoute
          ? (p.routeName.isEmpty ? 'Sans tournée' : p.routeName)
          : (p.wilaya.isEmpty ? 'Wilaya non renseignée' : wilayaLabel(p.wilaya));
      map.putIfAbsent(key, () => _Group(key, label)).clients.add(p);
    }
    final list = map.values.toList()
      ..sort((a, b) {
        if (a.key.isEmpty != b.key.isEmpty) return a.key.isEmpty ? 1 : -1;
        return b.clients.length.compareTo(a.clients.length);
      });
    for (final g in list) {
      g.clients.sort((a, b) => (a.commune + a.name).toLowerCase().compareTo((b.commune + b.name).toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final total = groups.fold(0, (s, g) => s + g.clients.length);
    final maxCount = groups.isEmpty ? 1 : groups.map((g) => g.clients.length).reduce((a, b) => a > b ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        quickFilters: [
          FilterPill(
              label: 'Par wilaya',
              icon: Icons.place_outlined,
              active: !_byRoute,
              onTap: () => setState(() {
                    _byRoute = false;
                    _open.clear();
                  })),
          FilterPill(
              label: 'Par tournée',
              icon: Icons.route_outlined,
              active: _byRoute,
              onTap: () => setState(() {
                    _byRoute = true;
                    _open.clear();
                  })),
        ],
        trailing: [
          Text('$total client(s) · ${groups.length} groupe(s)', style: T.bodyMuted),
          const SizedBox(width: 10),
          OutlinedButton.icon(
              onPressed: _loading ? null : reload,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Actualiser')),
        ],
        panel: FilterPanel(fields: [
          FilterField<String>(
            label: 'Statut',
            value: _status,
            options: [for (final e in crmStatusLabels.entries) (e.key, e.value)],
            onChanged: (v) => setState(() => _status = v),
          ),
          FilterField<String>(
            label: 'Type de client',
            value: _clientType,
            options: [for (final e in clientTypeLabels.entries) (e.key, e.value)],
            onChanged: (v) => setState(() => _clientType = v),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: _loading && _all.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? EmptyState(icon: Icons.error_outline_rounded, text: _error!, actions: [('Réessayer', reload)])
                : groups.isEmpty
                    ? const EmptyState(icon: Icons.place_outlined, text: 'Aucun client.')
                    : ListView(children: [
                        for (final g in groups) _groupCard(g, maxCount),
                      ]),
      ),
    ]);
  }

  Widget _groupCard(_Group g, int maxCount) {
    final open = _open.contains(g.key);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: T.surface, borderRadius: BorderRadius.circular(T.rInner), border: Border.all(color: T.border)),
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => open ? _open.remove(g.key) : _open.add(g.key)),
          borderRadius: BorderRadius.circular(T.rInner),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(children: [
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: T.muted),
              const SizedBox(width: 8),
              SizedBox(width: 230, child: Text(g.label, style: T.body.copyWith(fontWeight: FontWeight.w700))),
              SizedBox(
                width: 70,
                child: Text('${g.clients.length}', textAlign: TextAlign.end, style: T.monoBody.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FractionallySizedBox(
                    widthFactor: (g.clients.length / maxCount).clamp(0.02, 1.0),
                    child: Container(
                        height: 10,
                        decoration: BoxDecoration(color: T.mint.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(99))),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                  [
                    '${g.active} actif(s)',
                    if (g.prospects > 0) '${g.prospects} prospect(s)',
                    if (g.dormant > 0) '${g.dormant} inactif(s)',
                    if (g.blocked > 0) '${g.blocked} bloqué(s)',
                  ].join(' · '),
                  style: T.small),
              const SizedBox(width: 12),
              SizedBox(
                  width: 140,
                  child: Text(fmtDA(g.balance),
                      textAlign: TextAlign.end, style: T.monoSmall.copyWith(color: g.balance > 0 ? T.warnDark : T.muted))),
            ]),
          ),
        ),
        if (open) ...[
          const Divider(),
          for (final p in g.clients)
            InkWell(
              onTap: () async {
                await openPartnerDetail(context, widget.api, p);
                if (mounted) reload();
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(46, 7, 14, 7),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(p.name, style: T.body, overflow: TextOverflow.ellipsis)),
                  Expanded(flex: 2, child: Text(p.commune.isEmpty ? '—' : p.commune, style: T.small)),
                  Expanded(
                      flex: 2,
                      child: Text(_byRoute ? (p.wilaya.isEmpty ? '—' : p.wilaya) : (p.routeName.isEmpty ? '—' : p.routeName),
                          style: T.small)),
                  SizedBox(width: 110, child: Text(p.phone ?? '—', style: T.monoSmall)),
                  SizedBox(
                      width: 90,
                      child: Align(alignment: AlignmentDirectional.centerStart, child: CrmStatusChip(p.crmStatus))),
                  SizedBox(
                      width: 130,
                      child: Text(fmtDA(p.balance),
                          textAlign: TextAlign.end, style: T.monoSmall.copyWith(color: p.balance > 0 ? T.warnDark : T.muted))),
                ]),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }
}
