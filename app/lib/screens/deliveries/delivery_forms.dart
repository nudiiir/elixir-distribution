import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../orders/order_common.dart';

// ---------------------------------------------------------------------------
// Route template
// ---------------------------------------------------------------------------

class RouteFormPage extends StatefulWidget {
  const RouteFormPage({super.key, required this.api, this.existing, this.vehicles = const []});
  final ApiClient api;
  final DeliveryRoute? existing;
  final List<Vehicle> vehicles;

  @override
  State<RouteFormPage> createState() => _RouteFormPageState();
}

class _RouteFormPageState extends State<RouteFormPage> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _communes = TextEditingController(text: widget.existing?.communes.join(', ') ?? '');
  late final _driverName = TextEditingController(text: widget.existing?.defaultDriverName ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late final Set<String> _wilayas = {...?widget.existing?.wilayas};
  late final Set<int> _days = {...?widget.existing?.weekdays};
  late String? _driverId = widget.existing?.defaultDriverUserId;
  late String? _vehicleId = widget.existing?.defaultVehicleId;
  late bool _active = widget.existing?.active ?? true;
  List<({String id, String name})> _staff = const [];
  String? _nameError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.api.staffList().then((s) {
      if (mounted) setState(() => _staff = s);
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _communes, _driverName, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Donnez un nom à la tournée.');
      return;
    }
    setState(() {
      _saving = true;
      _nameError = null;
    });
    final body = {
      'name': name,
      'wilayas': _wilayas.toList()..sort(),
      'communes': [
        for (final c in _communes.text.split(','))
          if (c.trim().isNotEmpty) c.trim()
      ],
      'weekdays': _days.toList()..sort(),
      'default_driver_user_id': _driverId,
      'default_driver_name': _driverName.text.trim(),
      'default_vehicle_id': _vehicleId,
      'active': _active,
      'notes': _notes.text.trim(),
    };
    try {
      final r = await widget.api.saveDeliveryRoute(body, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, 'Tournée type « ${r.name} » enregistrée.');
      Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (e.field == 'name') _nameError = e.message;
      });
      if (e.field != 'name') showActionError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.existing == null ? 'Nouvelle tournée type' : widget.existing!.name;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save},
      child: AppPage(
        crumbs: [Crumb('Livraisons', () => Navigator.of(context).pop()), Crumb(title)],
        title: title,
        maxWidth: 820,
        actions: [
          PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
          PageAction(
              label: _saving ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _saving ? null : _save),
        ],
        body: Column(children: [
          PageSection(
            title: 'Tournée',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LabeledField(
                label: 'Nom',
                required: true,
                error: _nameError,
                child: FormText(controller: _name, autofocus: widget.existing == null, hint: 'Ex. Alger Est — mardi'),
              ),
              LabeledField(
                label: 'Jours de livraison',
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in weekdayNames.entries)
                    FilterChip(
                      label: Text(e.value),
                      selected: _days.contains(e.key),
                      onSelected: (v) => setState(() => v ? _days.add(e.key) : _days.remove(e.key)),
                    ),
                ]),
              ),
              LabeledField(
                label: 'Wilayas desservies',
                helper: 'Cliquez pour ajouter ou retirer.',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_wilayas.isNotEmpty)
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final w in _wilayas.toList()..sort())
                        InputChip(label: Text(w), onDeleted: () => setState(() => _wilayas.remove(w))),
                    ]),
                  const SizedBox(height: 8),
                  FormDropdown<String?>(
                    value: null,
                    width: 320,
                    options: [
                      (null, 'Ajouter une wilaya…'),
                      for (final w in wilayaNames)
                        if (!_wilayas.contains(w)) (w, w)
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _wilayas.add(v));
                    },
                  ),
                ]),
              ),
              LabeledField(
                label: 'Communes',
                helper: 'Séparées par des virgules (facultatif).',
                child: FormText(controller: _communes, maxLines: 2),
              ),
            ]),
          ),
          PageSection(
            title: 'Par défaut',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_staff.isNotEmpty)
                LabeledField(
                  label: 'Chauffeur (utilisateur)',
                  child: FormDropdown<String?>(
                    value: _driverId,
                    options: [(null, 'Aucun'), for (final s in _staff) (s.id, s.name)],
                    onChanged: (v) => setState(() {
                      _driverId = v;
                      final s = _staff.where((x) => x.id == v);
                      if (s.isNotEmpty && _driverName.text.trim().isEmpty) _driverName.text = s.first.name;
                    }),
                  ),
                ),
              LabeledField(
                label: 'Nom du chauffeur',
                helper: 'Imprimé sur la feuille de route.',
                child: FormText(controller: _driverName),
              ),
              LabeledField(
                label: 'Véhicule',
                child: FormDropdown<String?>(
                  value: _vehicleId,
                  options: [(null, 'Aucun'), for (final v in widget.vehicles) (v.id, v.label)],
                  onChanged: (v) => setState(() => _vehicleId = v),
                ),
              ),
              LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 3)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Tournée active', style: T.body),
                subtitle: Text('Une tournée inactive n’est plus proposée.', style: T.small),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vehicle
// ---------------------------------------------------------------------------

class VehicleFormPage extends StatefulWidget {
  const VehicleFormPage({super.key, required this.api, this.existing});
  final ApiClient api;
  final Vehicle? existing;

  @override
  State<VehicleFormPage> createState() => _VehicleFormPageState();
}

class _VehicleFormPageState extends State<VehicleFormPage> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _plate = TextEditingController(text: widget.existing?.plate ?? '');
  late final _capacity =
      TextEditingController(text: (widget.existing?.capacityKg ?? 0) > 0 ? '${widget.existing!.capacityKg}' : '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late bool _active = widget.existing?.active ?? true;
  String? _nameError;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _plate, _capacity, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'Donnez un nom au véhicule.');
      return;
    }
    setState(() => _saving = true);
    try {
      final v = await widget.api.saveVehicle({
        'name': _name.text.trim(),
        'plate': _plate.text.trim(),
        'capacity_kg': int.tryParse(_capacity.text.trim()) ?? 0,
        'active': _active,
        'notes': _notes.text.trim(),
      }, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, 'Véhicule « ${v.name} » enregistré.');
      Navigator.of(context).pop(v);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.existing == null ? 'Nouveau véhicule' : widget.existing!.name;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save},
      child: AppPage(
        crumbs: [Crumb('Livraisons', () => Navigator.of(context).pop()), Crumb(title)],
        title: title,
        maxWidth: 700,
        actions: [
          PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
          PageAction(
              label: _saving ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _saving ? null : _save),
        ],
        body: PageSection(
          title: 'Véhicule',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(
                label: 'Nom',
                required: true,
                error: _nameError,
                child: FormText(controller: _name, autofocus: true, hint: 'Ex. Camionnette blanche')),
            LabeledField(label: 'Immatriculation', child: FormText(controller: _plate)),
            LabeledField(label: 'Charge utile', child: FormText(controller: _capacity, numeric: true, suffixText: 'kg')),
            LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 3)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Véhicule en service', style: T.body),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Plan a delivery round
// ---------------------------------------------------------------------------

class RunPlanPage extends StatefulWidget {
  const RunPlanPage({super.key, required this.api, required this.routes, required this.vehicles, this.initialRoute});
  final ApiClient api;
  final List<DeliveryRoute> routes;
  final List<Vehicle> vehicles;
  final DeliveryRoute? initialRoute;

  @override
  State<RunPlanPage> createState() => _RunPlanPageState();
}

class _RunPlanPageState extends State<RunPlanPage> {
  String _date = isoDate(DateTime.now());
  String? _routeId;
  String? _driverId;
  String? _vehicleId;
  final _driverName = TextEditingController();
  final _notes = TextEditingController();
  List<({String id, String name})> _staff = const [];

  List<CustomerOrder> _ready = const [];
  final Set<String> _selected = {};
  bool _allRoutes = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.initialRoute;
    if (r != null) _setRoute(r.id, reload: false);
    widget.api.staffList().then((s) {
      if (mounted) setState(() => _staff = s);
    });
    _loadReady();
  }

  @override
  void dispose() {
    _driverName.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _setRoute(String? id, {bool reload = true}) {
    setState(() {
      _routeId = id;
      final r = widget.routes.where((x) => x.id == id);
      if (r.isNotEmpty) {
        _driverId = r.first.defaultDriverUserId ?? _driverId;
        if (r.first.defaultDriverName.isNotEmpty) _driverName.text = r.first.defaultDriverName;
        _vehicleId = r.first.defaultVehicleId ?? _vehicleId;
      }
    });
    if (reload) _loadReady();
  }

  Future<void> _loadReady() async {
    setState(() => _loading = true);
    try {
      final p = await widget.api.orders(
          statuses: const ['ready'], routeId: _allRoutes ? null : _routeId, limit: 500, sortPriority: true);
      if (!mounted) return;
      setState(() {
        _ready = p.items;
        _loading = false;
        _selected
          ..clear()
          ..addAll([
            for (final o in p.items)
              if (_routeId != null && o.routeId == _routeId) o.id
          ]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showActionError(context, e);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final run = await widget.api.createDeliveryRun({
        'run_date': _date,
        'route_id': ?_routeId,
        'driver_user_id': ?_driverId,
        'driver_name': _driverName.text.trim(),
        'vehicle_id': ?_vehicleId,
        'notes': _notes.text.trim(),
        'order_ids': [for (final o in _ready) if (_selected.contains(o.id)) o.id],
      });
      if (!mounted) return;
      showToast(context, 'Tournée du ${frDate(run.runDate)} créée (${run.stopsCount} arrêt${run.stopsCount > 1 ? 's' : ''}).');
      Navigator.of(context).pop(run);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _ready.where((o) => _selected.contains(o.id)).fold(0, (s, o) => s + o.totalTTC);
    return AppPage(
      crumbs: [Crumb('Livraisons', () => Navigator.of(context).pop()), const Crumb('Planifier une tournée')],
      title: 'Planifier une tournée',
      maxWidth: 1200,
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
        PageAction(
            label: _saving ? 'Création…' : 'Créer la tournée (${_selected.length})',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _saving ? null : _save),
      ],
      body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 360,
          child: PageSection(
            title: 'Tournée',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LabeledField(label: 'Date', child: DateField(value: _date, width: 320, onChanged: (v) => setState(() => _date = v ?? _date))),
              LabeledField(
                label: 'Tournée type',
                helper: 'Propose ses commandes prêtes, son chauffeur et son véhicule.',
                child: FormDropdown<String?>(
                  value: _routeId,
                  options: [(null, 'Aucune'), for (final r in widget.routes.where((r) => r.active)) (r.id, r.name)],
                  onChanged: (v) => _setRoute(v),
                ),
              ),
              if (_staff.isNotEmpty)
                LabeledField(
                  label: 'Chauffeur (utilisateur)',
                  child: FormDropdown<String?>(
                    value: _driverId,
                    options: [(null, 'Aucun'), for (final s in _staff) (s.id, s.name)],
                    onChanged: (v) => setState(() {
                      _driverId = v;
                      final s = _staff.where((x) => x.id == v);
                      if (s.isNotEmpty) _driverName.text = s.first.name;
                    }),
                  ),
                ),
              LabeledField(label: 'Nom du chauffeur', child: FormText(controller: _driverName)),
              LabeledField(
                label: 'Véhicule',
                child: FormDropdown<String?>(
                  value: _vehicleId,
                  options: [(null, 'Aucun'), for (final v in widget.vehicles.where((v) => v.active)) (v.id, v.label)],
                  onChanged: (v) => setState(() => _vehicleId = v),
                ),
              ),
              LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 3)),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: PageSection(
            title: 'Commandes prêtes à livrer',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Toutes les tournées', style: T.small),
              Switch(
                value: _allRoutes,
                onChanged: (v) {
                  setState(() => _allRoutes = v);
                  _loadReady();
                },
              ),
            ]),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('${_selected.length} choisie${_selected.length > 1 ? 's' : ''} · ${fmtDA(total)}',
                    style: T.body.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(
                    onPressed: () => setState(() => _selected.addAll(_ready.map((o) => o.id))),
                    child: const Text('Tout cocher')),
                TextButton(onPressed: () => setState(_selected.clear), child: const Text('Tout décocher')),
              ]),
              const Divider(),
              if (_loading)
                const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: T.mint)))
              else if (_ready.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                      _routeId != null && !_allRoutes
                          ? 'Aucune commande prête pour cette tournée. Activez « Toutes les tournées » pour en voir d’autres.'
                          : 'Aucune commande prête. Les commandes « Prêtes » apparaissent ici.',
                      style: T.bodyMuted),
                )
              else
                for (final o in _ready)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _selected.contains(o.id),
                    onChanged: (v) => setState(() => v == true ? _selected.add(o.id) : _selected.remove(o.id)),
                    title: Row(children: [
                      SizedBox(width: 140, child: Text(o.number, style: T.monoSmall.copyWith(color: T.ink))),
                      Expanded(child: Text(o.partnerName, style: T.body.copyWith(fontWeight: FontWeight.w600))),
                      PriorityBadge(o.priority),
                      const SizedBox(width: 8),
                      Text(fmtDA(o.totalTTC), style: T.monoBody),
                    ]),
                    subtitle: Text(
                        [o.deliveryAddress, o.commune, o.wilaya, if (o.routeName.isNotEmpty) 'tournée ${o.routeName}', if (o.paymentMode == 'cod') 'à encaisser']
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        style: T.small),
                  ),
            ]),
          ),
        ),
      ]),
    );
  }
}
