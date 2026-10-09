import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/commands.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_list.dart' show DocChip, popToModuleRoot;
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../orders/order_common.dart';
import 'delivery_forms.dart';
import 'run_page.dart';

const _prefs = 'deliveries';

String runStatusLabel(String s) => switch (s) {
      'planned' => 'Prévue',
      'out' => 'En route',
      'closed' => 'Clôturée',
      'cancelled' => 'Annulée',
      _ => s,
    };

class RunStatusChip extends StatelessWidget {
  const RunStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      'planned' => (const Color(0x1F3B82F6), const Color(0xFF1D4ED8)),
      'out' => (T.warnTint, T.warnDark),
      'closed' => (T.mintTint, T.mintDark),
      _ => (T.dangerTint, T.dangerDark),
    };
    return DocChip(label: runStatusLabel(status), bg: bg, fg: fg);
  }
}

/// « Livraisons » : tournées du jour (planning, feuille de route, résultats,
/// clôture de caisse), tournées types, véhicules.
/// Menu commands: `runs` · `new` · `routes` · `vehicles`.
class DeliveriesScreen extends StatefulWidget {
  const DeliveriesScreen({super.key, required this.api, required this.user, this.command});
  final ApiClient api;
  final User user;
  final ScreenCommand? command;

  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends State<DeliveriesScreen> {
  ApiClient get api => widget.api;
  bool get _manage => widget.user.isAdmin || widget.user.can('deliveries.manage');

  String _tab = 'runs';

  // runs
  List<DeliveryRun> _runs = const [];
  String? _from;
  String? _to;
  String? _runStatus; // null = open (planned + out)
  String? _routeFilter;

  List<DeliveryRoute> _routes = const [];
  List<Vehicle> _vehicles = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = UiPrefs.instance.get<String>(_prefs, 'tab');
    if (t == 'runs' || t == 'routes' || t == 'vehicles') _tab = t!;
    widget.command?.addListener(_onCommand);
    _loadAll();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(DeliveriesScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    switch (cmd) {
      case 'runs':
      case 'routes':
      case 'vehicles':
        _setTab(cmd);
      case 'new':
        _setTab('runs');
        if (_manage) _newRun();
    }
  }

  void _setTab(String t) {
    setState(() => _tab = t);
    UiPrefs.instance.set(_prefs, 'tab', t);
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        api.deliveryRuns(
          from: _from,
          to: _to,
          statuses: _runStatus == null ? const ['planned', 'out'] : [_runStatus!],
          routeId: _routeFilter,
        ),
        api.deliveryRoutes(),
        api.vehicles(),
      ]);
      if (!mounted) return;
      setState(() {
        _runs = results[0] as List<DeliveryRun>;
        _routes = results[1] as List<DeliveryRoute>;
        _vehicles = results[2] as List<Vehicle>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de charger les livraisons : $e';
      });
    }
  }

  Future<void> _newRun({DeliveryRoute? route}) async {
    final run = await Navigator.of(context).push<DeliveryRun>(MaterialPageRoute(
      builder: (_) => RunPlanPage(api: api, routes: _routes, vehicles: _vehicles, initialRoute: route),
    ));
    if (run == null || !mounted) return;
    _loadAll();
    await _openRun(run.id);
  }

  Future<void> _openRun(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RunPage(api: api, user: widget.user, runId: id),
    ));
    if (mounted) _loadAll();
  }

  Future<void> _editRoute([DeliveryRoute? r]) async {
    final saved = await Navigator.of(context).push<DeliveryRoute>(MaterialPageRoute(
      builder: (_) => RouteFormPage(api: api, existing: r, vehicles: _vehicles),
    ));
    if (saved != null && mounted) _loadAll();
  }

  Future<void> _deleteRoute(DeliveryRoute r) async {
    final ok = await confirmAction(context,
        title: 'Supprimer la tournée type « ${r.name} » ?',
        message: 'Impossible si des clients, commandes ou tournées l’utilisent : désactivez-la plutôt.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    final done = await runGuarded(context, api, () async {
      await api.deleteDeliveryRoute(r.id);
      return true;
    });
    if (done == true && mounted) {
      showToast(context, 'Tournée type supprimée.');
      _loadAll();
    }
  }

  Future<void> _editVehicle([Vehicle? v]) async {
    final saved = await Navigator.of(context).push<Vehicle>(MaterialPageRoute(
      builder: (_) => VehicleFormPage(api: api, existing: v),
    ));
    if (saved != null && mounted) _loadAll();
  }

  Future<void> _deleteVehicle(Vehicle v) async {
    final ok = await confirmAction(context, title: 'Supprimer le véhicule « ${v.name} » ?', confirmLabel: 'Supprimer', danger: true);
    if (!ok || !mounted) return;
    final done = await runGuarded(context, api, () async {
      await api.deleteVehicle(v.id);
      return true;
    });
    if (done == true && mounted) _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    final (primary, onPrimary) = switch (_tab) {
      'routes' => ('Nouvelle tournée type', () => _editRoute()),
      'vehicles' => ('Nouveau véhicule', () => _editVehicle()),
      _ => ('Planifier une tournée', () => _newRun()),
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Livraisons',
          primaryLabel: _manage ? primary : null,
          primaryIcon: Icons.add_rounded,
          onPrimary: onPrimary,
          more: [MenuEntry('Actualiser', Icons.refresh_rounded, _loadAll)],
        ),
        const SizedBox(height: 14),
        Row(children: [
          FilterPill(label: 'Tournées', icon: Icons.route_outlined, active: _tab == 'runs', onTap: () => _setTab('runs')),
          FilterPill(
              label: 'Tournées types',
              icon: Icons.map_outlined,
              active: _tab == 'routes',
              count: _routes.length,
              onTap: () => _setTab('routes')),
          FilterPill(
              label: 'Véhicules',
              icon: Icons.local_shipping_outlined,
              active: _tab == 'vehicles',
              count: _vehicles.length,
              onTap: () => _setTab('vehicles')),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: switch (_tab) {
            'routes' => _routesList(),
            'vehicles' => _vehiclesList(),
            _ => _runsList(),
          },
        ),
      ]),
    );
  }

  Widget _runsList() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        quickFilters: [
          FilterPill(
              label: 'En cours (prévues et en route)',
              active: _runStatus == null,
              onTap: () {
                _runStatus = null;
                _loadAll();
              }),
          for (final s in const ['planned', 'out', 'closed', 'cancelled'])
            FilterPill(
                label: runStatusLabel(s),
                active: _runStatus == s,
                onTap: () {
                  _runStatus = _runStatus == s ? null : s;
                  _loadAll();
                }),
        ],
        panel: Wrap(spacing: 14, runSpacing: 12, children: [
          FilterField<String>(
            label: 'Tournée type',
            value: _routeFilter,
            allLabel: 'Toutes',
            options: [for (final r in _routes) (r.id, r.name)],
            onChanged: (v) {
              _routeFilter = v;
              _loadAll();
            },
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const MicroLabel('Du'),
            const SizedBox(height: 5),
            DateField(
                value: _from,
                width: 170,
                hint: 'Début',
                onChanged: (v) {
                  _from = v;
                  _loadAll();
                }),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const MicroLabel('Au'),
            const SizedBox(height: 5),
            DateField(
                value: _to,
                width: 170,
                hint: 'Fin',
                onChanged: (v) {
                  _to = v;
                  _loadAll();
                }),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: DataListView<DeliveryRun>(
          items: _runs,
          prefsKey: 'deliveries_runs',
          loading: _loading,
          error: _error,
          onRetry: _loadAll,
          rowId: (r) => r.id,
          onTap: (r) => _openRun(r.id),
          exportTitle: 'Tournées',
          exportBaseName: 'tournees',
          rowMenu: (r) => [RowAction('Ouvrir', Icons.open_in_new_rounded, (r) => _openRun(r.id))],
          empty: EmptyState(
            icon: Icons.route_outlined,
            text: _runStatus == null ? 'Aucune tournée en cours.' : 'Aucune tournée.',
            actions: [if (_manage) ('Planifier une tournée', () => _newRun())],
          ),
          aggregates: (rows) => [
            ('Arrêts', '${rows.fold(0, (s, r) => s + r.stopsCount)}'),
            ('À encaisser', fmtDA(rows.fold(0, (s, r) => s + r.codExpectedTotal))),
          ],
          columns: [
            ColumnSpec(
              id: 'date',
              label: 'Date',
              width: 110,
              hideable: false,
              sortKey: (r) => r.runDate,
              exportValue: (r) => r.runDate,
              cell: (_, r) => Text(frDate(r.runDate), style: T.monoBody),
            ),
            ColumnSpec(
              id: 'route',
              label: 'Tournée',
              flex: 2,
              sortKey: (r) => r.routeName,
              exportValue: (r) => r.routeName,
              cell: (_, r) => Text(r.routeName.isEmpty ? 'Hors tournée type' : r.routeName, style: T.body),
            ),
            ColumnSpec(
              id: 'driver',
              label: 'Chauffeur',
              flex: 2,
              sortKey: (r) => r.driverName,
              exportValue: (r) => r.driverName,
              cell: (_, r) => Text(r.driverName.isEmpty ? '—' : r.driverName, style: T.body),
            ),
            ColumnSpec(
              id: 'vehicle',
              label: 'Véhicule',
              flex: 2,
              exportValue: (r) => r.vehicleName,
              cell: (_, r) => Text(r.vehicleName.isEmpty ? '—' : r.vehicleName, style: T.small),
            ),
            ColumnSpec(
              id: 'status',
              label: 'Statut',
              width: 120,
              sortKey: (r) => r.status,
              exportValue: (r) => runStatusLabel(r.status),
              cell: (_, r) => RunStatusChip(r.status),
            ),
            ColumnSpec(
              id: 'stops',
              label: 'Arrêts',
              width: 120,
              numeric: true,
              sortKey: (r) => r.stopsCount,
              exportValue: (r) => r.stopsCount,
              cell: (_, r) => Text(
                  r.status == 'out' ? '${r.stopsCount - r.pendingCount}/${r.stopsCount} faits' : '${r.stopsCount}',
                  style: T.monoBody),
            ),
            ColumnSpec(
              id: 'cod',
              label: 'À encaisser',
              width: 140,
              numeric: true,
              sortKey: (r) => r.codExpectedTotal,
              exportValue: (r) => r.codExpectedTotal / 100,
              cell: (_, r) => Text(fmtDA(r.codExpectedTotal), style: T.monoBody),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _routesList() {
    return DataListView<DeliveryRoute>(
      items: _routes,
      prefsKey: 'deliveries_routes',
      loading: _loading,
      error: _error,
      onRetry: _loadAll,
      rowId: (r) => r.id,
      onTap: _manage ? _editRoute : null,
      exportTitle: 'Tournées types',
      exportBaseName: 'tournees-types',
      rowMenu: (r) => [
        if (_manage) RowAction('Modifier', Icons.edit_outlined, _editRoute),
        if (_manage && r.readyOrdersCount > 0)
          RowAction('Planifier une tournée', Icons.route_outlined, (r) => _newRun(route: r)),
        if (_manage) RowAction('Supprimer', Icons.delete_outline_rounded, _deleteRoute, danger: true),
      ],
      empty: EmptyState(
        icon: Icons.map_outlined,
        text: 'Aucune tournée type. Une tournée type regroupe des wilayas / communes livrées les mêmes jours.',
        actions: [if (_manage) ('Nouvelle tournée type', () => _editRoute())],
      ),
      columns: [
        ColumnSpec(
          id: 'name',
          label: 'Nom',
          flex: 2,
          hideable: false,
          sortKey: (r) => r.name.toLowerCase(),
          exportValue: (r) => r.name,
          cell: (_, r) => Row(children: [
            Flexible(child: Text(r.name, style: T.body.copyWith(fontWeight: FontWeight.w600))),
            if (!r.active) ...[const SizedBox(width: 6), const DocChip(label: 'Inactive', bg: T.cream, fg: T.muted)],
          ]),
        ),
        ColumnSpec(
          id: 'zone',
          label: 'Zone',
          flex: 3,
          exportValue: (r) => [...r.wilayas, ...r.communes].join(', '),
          cell: (_, r) => Text([...r.wilayas, ...r.communes].join(', '),
              style: T.small, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        ColumnSpec(
          id: 'days',
          label: 'Jours',
          flex: 2,
          exportValue: (r) => r.weekdays.map((d) => weekdayNames[d] ?? '$d').join(', '),
          cell: (_, r) => Text(
              r.weekdays.isEmpty ? '—' : r.weekdays.map((d) => (weekdayNames[d] ?? '$d').substring(0, 3)).join(' · '),
              style: T.small),
        ),
        ColumnSpec(
          id: 'driver',
          label: 'Chauffeur habituel',
          flex: 2,
          exportValue: (r) => r.defaultDriverName,
          cell: (_, r) => Text(r.defaultDriverName.isEmpty ? '—' : r.defaultDriverName, style: T.small),
        ),
        ColumnSpec(
          id: 'clients',
          label: 'Clients',
          width: 80,
          numeric: true,
          sortKey: (r) => r.partnersCount,
          exportValue: (r) => r.partnersCount,
          cell: (_, r) => Text('${r.partnersCount}', style: T.monoBody),
        ),
        ColumnSpec(
          id: 'ready',
          label: 'Prêtes',
          width: 90,
          numeric: true,
          sortKey: (r) => r.readyOrdersCount,
          exportValue: (r) => r.readyOrdersCount,
          cell: (_, r) => r.readyOrdersCount > 0
              ? DocChip(label: '${r.readyOrdersCount}', bg: T.mintTint, fg: T.mintDark)
              : Text('0', style: T.monoSmall),
        ),
      ],
    );
  }

  Widget _vehiclesList() {
    return DataListView<Vehicle>(
      items: _vehicles,
      prefsKey: 'deliveries_vehicles',
      loading: _loading,
      error: _error,
      onRetry: _loadAll,
      rowId: (v) => v.id,
      onTap: _manage ? _editVehicle : null,
      rowMenu: (v) => [
        if (_manage) RowAction('Modifier', Icons.edit_outlined, _editVehicle),
        if (_manage) RowAction('Supprimer', Icons.delete_outline_rounded, _deleteVehicle, danger: true),
      ],
      empty: EmptyState(
        icon: Icons.local_shipping_outlined,
        text: 'Aucun véhicule.',
        actions: [if (_manage) ('Nouveau véhicule', () => _editVehicle())],
      ),
      columns: [
        ColumnSpec(
          id: 'name',
          label: 'Nom',
          flex: 3,
          hideable: false,
          sortKey: (v) => v.name.toLowerCase(),
          exportValue: (v) => v.name,
          cell: (_, v) => Row(children: [
            Flexible(child: Text(v.name, style: T.body.copyWith(fontWeight: FontWeight.w600))),
            if (!v.active) ...[const SizedBox(width: 6), const DocChip(label: 'Inactif', bg: T.cream, fg: T.muted)],
          ]),
        ),
        ColumnSpec(
          id: 'plate',
          label: 'Immatriculation',
          flex: 2,
          exportValue: (v) => v.plate,
          cell: (_, v) => Text(v.plate.isEmpty ? '—' : v.plate, style: T.monoBody),
        ),
        ColumnSpec(
          id: 'capacity',
          label: 'Charge utile',
          width: 130,
          numeric: true,
          sortKey: (v) => v.capacityKg,
          exportValue: (v) => v.capacityKg,
          cell: (_, v) => Text(v.capacityKg > 0 ? '${v.capacityKg} kg' : '—', style: T.monoBody),
        ),
        ColumnSpec(
          id: 'notes',
          label: 'Notes',
          flex: 3,
          exportValue: (v) => v.notes,
          cell: (_, v) => Text(v.notes, style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
