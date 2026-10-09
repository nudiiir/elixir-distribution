import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_list.dart' show DocChip;
import '../../widgets/ui.dart';
import '../orders/order_common.dart';
import '../orders/order_detail_page.dart';
import '../orders/orders_pdf.dart';
import 'deliveries_screen.dart' show RunStatusChip;

String stopStatusLabel(String s) => switch (s) {
      'pending' => 'À livrer',
      'delivered' => 'Livré',
      'partial' => 'Livré en partie',
      'failed' => 'Échec',
      _ => s,
    };

/// One delivery run: the stops in order (drag to reorder), the run sheet,
/// the result of each stop, and the cash reconciliation at closing.
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.api, required this.user, required this.runId});
  final ApiClient api;
  final User user;
  final String runId;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  ApiClient get api => widget.api;
  bool get _manage => widget.user.isAdmin || widget.user.can('deliveries.manage');

  DeliveryRun? _run;
  String? _error;
  bool _busy = false;
  final _counted = TextEditingController();
  final _closeNotes = TextEditingController();
  Map<String, dynamic>? _reconciliation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    _closeNotes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await api.deliveryRun(widget.runId);
      if (mounted) {
        setState(() {
          _run = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  Future<void> _do(Future<void> Function() f, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
      if (ok != null && mounted) showToast(context, ok);
      await _load();
    } catch (e) {
      if (mounted) showActionError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() async {
    try {
      await printRunSheetPdf(api, _run!);
    } catch (e) {
      if (mounted) showActionError(context, e);
    }
  }

  Future<void> _start() async {
    final r = _run!;
    final ok = await confirmAction(context,
        title: 'Départ de la tournée ?',
        message: '${r.stops.length} arrêt${r.stops.length > 1 ? 's' : ''}. Chaque commande passe « En livraison » '
            'et son bon de livraison est créé (le stock sort).',
        confirmLabel: 'Départ',
        icon: Icons.local_shipping_outlined);
    if (!ok || !mounted) return;
    await _do(() => api.startDeliveryRun(r.id), ok: 'Tournée partie.');
  }

  Future<void> _cancelRun() async {
    final ok = await confirmAction(context,
        title: 'Annuler cette tournée ?',
        message: 'Les arrêts sont retirés ; les commandes restent « Prêtes ».',
        confirmLabel: 'Annuler la tournée',
        danger: true);
    if (!ok || !mounted) return;
    await _do(() => api.cancelDeliveryRun(_run!.id), ok: 'Tournée annulée.');
  }

  Future<void> _addOrders() async {
    final r = _run!;
    final ids = await showDialog<List<String>>(
        context: context, builder: (_) => _AddOrdersDialog(api: api, routeId: r.routeId, exclude: {for (final s in r.stops) s.orderId}));
    if (ids == null || ids.isEmpty || !mounted) return;
    await _do(() => api.addRunStops(r.id, ids), ok: '${ids.length} commande${ids.length > 1 ? 's' : ''} ajoutée${ids.length > 1 ? 's' : ''}.');
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final r = _run!;
    final stops = [...r.stops];
    final s = stops.removeAt(oldIndex);
    stops.insert(newIndex, s);
    setState(() => _run = DeliveryRun.fromJson({
          ...r.raw,
          'stops': [
            for (var i = 0; i < stops.length; i++) {...stopJson(stops[i]), 'sequence': i + 1}
          ],
        }));
    await _do(() => api.reorderRunStops(r.id, [for (final x in stops) x.id]));
  }

  Map<String, dynamic> stopJson(RunStop s) {
    final raw = (_run!.raw['stops'] as List? ?? const []).whereType<Map>().firstWhere((m) => m['id'] == s.id, orElse: () => const {});
    return Map<String, dynamic>.from(raw);
  }

  Future<void> _removeStop(RunStop s) async {
    final ok = await confirmAction(context,
        title: 'Retirer ${s.orderNumber} de la tournée ?',
        message: 'La commande redevient « Prête ».',
        confirmLabel: 'Retirer',
        danger: true);
    if (!ok || !mounted) return;
    await _do(() => api.removeRunStop(_run!.id, s.id));
  }

  Future<void> _editCod(RunStop s) async {
    final t = await askText(context,
        title: 'Montant à encaisser — ${s.partnerName}',
        label: 'Montant attendu (DA)',
        initial: editDA(s.codExpected),
        confirmLabel: 'Enregistrer');
    if (t == null || !mounted) return;
    final v = parseDA(t);
    if (v == null || v < 0) {
      showToast(context, 'Montant invalide.', kind: ToastKind.warning);
      return;
    }
    await _do(() => api.patchRunStop(_run!.id, s.id, codExpected: v));
  }

  Future<void> _result(RunStop s, String status) async {
    final body = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _ResultDialog(stop: s, status: status));
    if (body == null || !mounted) return;
    await _do(() => api.recordRunStop(_run!.id, s.id, body), ok: '${s.partnerName} : ${stopStatusLabel(body['status'] as String)}.');
  }

  Future<void> _close() async {
    final r = _run!;
    final counted = _counted.text.trim().isEmpty ? null : parseDA(_counted.text);
    if (_counted.text.trim().isNotEmpty && counted == null) {
      showToast(context, 'Montant compté invalide.', kind: ToastKind.warning);
      return;
    }
    final collected = r.stops.fold(0, (s, x) => s + x.codCollected);
    final ok = await confirmAction(context,
        title: 'Clôturer la tournée ?',
        message: 'Encaissé : ${fmtDA(collected)}${counted == null ? '' : ' — compté : ${fmtDA(counted)}'}.\n'
            'Un encaissement est créé au compte de chaque client payé. Ce n’est plus modifiable ensuite.',
        confirmLabel: 'Clôturer',
        icon: Icons.lock_outline_rounded);
    if (!ok || !mounted) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final done = await api.closeDeliveryRun(r.id, countedCash: counted, notes: _closeNotes.text.trim());
      if (!mounted) return;
      setState(() => _reconciliation =
          done.raw['reconciliation'] is Map ? Map<String, dynamic>.from(done.raw['reconciliation'] as Map) : null);
      showToast(context, 'Tournée clôturée.');
      await _load();
    } catch (e) {
      if (mounted) showActionError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOrder(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderDetailPage(api: api, user: widget.user, orderId: id),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final r = _run;
    if (r == null) {
      return AppPage(
        crumbs: [Crumb('Livraisons', () => Navigator.of(context).pop()), const Crumb('Tournée')],
        title: 'Tournée',
        body: _error == null
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: T.mint)))
            : EmptyState(icon: Icons.cloud_off_rounded, text: _error!, actions: [('Réessayer', _load)]),
      );
    }
    final title = 'Tournée du ${frDate(r.runDate)}${r.routeName.isEmpty ? '' : ' — ${r.routeName}'}';
    VoidCallback? on(VoidCallback f) => _busy ? null : f;
    return AppPage(
      crumbs: [Crumb('Livraisons', () => Navigator.of(context).pop()), Crumb(title)],
      title: title,
      maxWidth: 1280,
      subtitle: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        RunStatusChip(r.status),
        Text([if (r.driverName.isNotEmpty) 'Chauffeur : ${r.driverName}', if (r.vehicleName.isNotEmpty) r.vehicleName].join(' · '),
            style: T.bodyMuted),
      ]),
      actions: [
        PageAction(label: 'Feuille de route', icon: Icons.print_outlined, onPressed: r.stops.isEmpty ? null : _print),
        if (_manage && r.status == 'planned') PageAction(label: 'Annuler', icon: Icons.block_rounded, danger: true, onPressed: on(_cancelRun)),
        if (_manage && r.open) PageAction(label: 'Ajouter des commandes', icon: Icons.playlist_add_rounded, onPressed: on(_addOrders)),
        if (_manage && r.status == 'planned')
          PageAction(label: 'Départ', icon: Icons.local_shipping_outlined, primary: true, onPressed: r.stops.isEmpty ? null : on(_start)),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.mintTint),
        if (r.status == 'out' && r.pendingCount > 0)
          InfoBanner(
              text: '${r.pendingCount} arrêt${r.pendingCount > 1 ? 's' : ''} à saisir : cliquez « Livré », « Partiel » ou « Échec » '
                  'au retour du chauffeur, puis clôturez la tournée.'),
        _stopsSection(r),
        if (r.status == 'out' || r.status == 'closed') _cashSection(r),
      ]),
    );
  }

  Widget _stopsSection(DeliveryRun r) {
    final canReorder = _manage && r.open && r.stops.every((s) => s.status == 'pending') && r.stops.length > 1;
    return PageSection(
      title: 'Arrêts (${r.stops.length})',
      trailing: canReorder ? Text('Glissez ⠿ pour changer l’ordre de passage', style: T.small) : null,
      child: r.stops.isEmpty
          ? Text('Aucune commande dans cette tournée. Utilisez « Ajouter des commandes ».', style: T.bodyMuted)
          : canReorder
              ? ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorderItem: _reorder,
                  children: [
                    for (var i = 0; i < r.stops.length; i++)
                      KeyedSubtree(key: ValueKey(r.stops[i].id), child: _stopRow(r, r.stops[i], i, true)),
                  ],
                )
              : Column(children: [for (var i = 0; i < r.stops.length; i++) _stopRow(r, r.stops[i], i, false)]),
    );
  }

  Widget _stopRow(DeliveryRun r, RunStop s, int index, bool draggable) {
    final (bg, fg) = switch (s.status) {
      'delivered' => (T.mintTint, T.mintDark),
      'partial' => (T.warnTint, T.warnDark),
      'failed' => (T.dangerTint, T.dangerDark),
      _ => (T.cream, T.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(color: T.surface, border: Border(bottom: BorderSide(color: T.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (draggable)
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(right: 6, top: 4),
              child: MouseRegion(cursor: SystemMouseCursors.grab, child: Icon(Icons.drag_indicator_rounded, color: T.faint)),
            ),
          ),
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: T.ink, shape: BoxShape.circle),
          child: Text('${s.sequence == 0 ? index + 1 : s.sequence}', style: T.label.copyWith(color: Colors.white)),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.partnerName, style: T.body.copyWith(fontWeight: FontWeight.w700)),
            Text(s.place.isEmpty ? 'Adresse non renseignée' : s.place, style: T.small),
            if (s.partnerPhone.isNotEmpty) Text(s.partnerPhone, style: T.monoSmall),
          ]),
        ),
        Expanded(
          flex: 2,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => _openOrder(s.orderId),
              child: Text(s.orderNumber, style: T.monoBody.copyWith(color: T.mintDark, decoration: TextDecoration.underline)),
            ),
            if (s.deliveryNoteNumber != null) Text('BL ${s.deliveryNoteNumber}', style: T.small),
            Text('Total ${fmtDA(s.totalTTC)}', style: T.small),
          ]),
        ),
        SizedBox(
          width: 170,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('À encaisser', style: T.label),
            InkWell(
              onTap: _manage && r.open && s.status == 'pending' ? () => _editCod(s) : null,
              child: Text(fmtDA(s.codExpected), style: T.monoBody.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (s.status != 'pending')
              Text('Encaissé ${fmtDA(s.codCollected)}',
                  style: T.small.copyWith(color: s.codCollected == s.codExpected ? T.mintDark : T.warnDark)),
          ]),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 300,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            DocChip(label: stopStatusLabel(s.status), bg: bg, fg: fg),
            if (s.failureReason.isNotEmpty) Text(s.failureReason, style: T.small.copyWith(color: T.dangerDark)),
            if (s.receiverName.isNotEmpty) Text('Reçu par ${s.receiverName}', style: T.small),
            if (_manage && r.status == 'out' && s.status == 'pending') ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink, visualDensity: VisualDensity.compact),
                  onPressed: _busy ? null : () => _result(s, 'delivered'),
                  child: const Text('Livré'),
                ),
                OutlinedButton(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _busy ? null : () => _result(s, 'partial'),
                    child: const Text('Partiel')),
                OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: T.dangerDark, visualDensity: VisualDensity.compact),
                    onPressed: _busy ? null : () => _result(s, 'failed'),
                    child: const Text('Échec')),
              ]),
            ],
            if (_manage && r.open && s.status == 'pending')
              TextButton(onPressed: _busy ? null : () => _removeStop(s), child: const Text('Retirer de la tournée')),
          ]),
        ),
      ]),
    );
  }

  Widget _cashSection(DeliveryRun r) {
    final expected = r.stops.where((s) => s.status == 'delivered' || s.status == 'partial').fold(0, (a, s) => a + s.codExpected);
    final collected = r.stops.fold(0, (a, s) => a + s.codCollected);
    final rec = _reconciliation;
    final closed = r.status == 'closed';
    final exp = closed ? r.cashExpected : expected;
    final col = closed ? r.cashCollected : collected;
    final diff = closed ? r.cashDifference : col - exp;
    final counted = closed ? r.countedCash : parseDA(_counted.text);
    Widget box(String label, String value, {Color? color}) => Container(
          width: 210,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: T.bg, borderRadius: BorderRadius.circular(T.rInner), border: Border.all(color: T.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label),
            const SizedBox(height: 4),
            Text(value, style: T.monoBig.copyWith(fontSize: 20, color: color)),
          ]),
        );
    return PageSection(
      title: closed ? 'Caisse de la tournée (clôturée)' : 'Clôture et caisse',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 12, children: [
          box('Attendu (livrés)', fmtDA(exp)),
          box('Encaissé (saisi)', fmtDA(col)),
          box('Écart', '${diff > 0 ? '+' : ''}${fmtDA(diff)}', color: diff == 0 ? T.mintDark : T.dangerDark),
          if (counted != null)
            box('Compté à la remise', fmtDA(counted), color: counted == col ? T.mintDark : T.warnDark),
        ]),
        const SizedBox(height: 10),
        Text(
            diff == 0
                ? 'Le chauffeur a encaissé exactement ce qui était attendu.'
                : diff < 0
                    ? 'Il manque ${fmtDA(-diff)} par rapport à ce qui était attendu.'
                    : 'Le chauffeur a encaissé ${fmtDA(diff)} de plus que prévu.',
            style: T.body.copyWith(fontWeight: FontWeight.w600, color: diff == 0 ? T.mintDark : T.warnDark)),
        if (!closed && _manage) ...[
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(
              width: 240,
              child: LabeledField(
                label: 'Argent compté à la remise (facultatif)',
                child: FormText(controller: _counted, numeric: true, suffixText: 'DA', onChanged: (_) => setState(() {})),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: LabeledField(label: 'Notes de clôture', child: FormText(controller: _closeNotes))),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: PrimaryButton(
                  label: r.pendingCount > 0 ? 'Clôturer (${r.pendingCount} à saisir)' : 'Clôturer la tournée',
                  onPressed: _busy || r.pendingCount > 0 ? null : _close),
            ),
          ]),
        ],
        if (rec != null && (rec['payments'] as List? ?? const []).isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Encaissements créés', style: T.h2.copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          for (final p in (rec['payments'] as List).whereType<Map>())
            Text('${p['number'] ?? ''} — ${fmtDA((p['amount'] as num?)?.toInt() ?? 0)} (${p['payment_method'] ?? ''})',
                style: T.monoSmall),
        ],
      ]),
    );
  }
}

class _ResultDialog extends StatefulWidget {
  const _ResultDialog({required this.stop, required this.status});
  final RunStop stop;
  final String status;

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  late String _status = widget.status;
  late final _cod = TextEditingController(text: widget.status == 'failed' ? '' : editDA(widget.stop.codExpected));
  final _receiver = TextEditingController();
  final _reason = TextEditingController();
  final _note = TextEditingController();
  String _method = 'cash';
  String? _error;

  static const _reasons = ['Client absent', 'Magasin fermé', 'Refus du client', 'Adresse introuvable', 'Pas d’argent', 'Manque de temps'];

  @override
  void dispose() {
    for (final c in [_cod, _receiver, _reason, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final failed = _status == 'failed';
    final cod = failed || _cod.text.trim().isEmpty ? 0 : parseDA(_cod.text);
    if (cod == null || cod < 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    if (failed && _reason.text.trim().isEmpty) {
      setState(() => _error = 'Indiquez la raison de l’échec.');
      return;
    }
    Navigator.pop(context, {
      'status': _status,
      'cod_collected': cod,
      'payment_method': _method,
      'receiver_name': _receiver.text.trim(),
      'failure_reason': failed ? _reason.text.trim() : '',
      'note': _note.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stop;
    final failed = _status == 'failed';
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('${s.partnerName} — ${s.orderNumber}', style: T.h2),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'delivered', label: Text('Livré')),
                ButtonSegment(value: 'partial', label: Text('Partiel')),
                ButtonSegment(value: 'failed', label: Text('Échec')),
              ],
              selected: {_status},
              onSelectionChanged: (v) => setState(() => _status = v.first),
            ),
            const SizedBox(height: 14),
            if (failed) ...[
              LabeledField(
                label: 'Raison de l’échec',
                required: true,
                helper: 'La commande redevient « Prête » et pourra repartir.',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final r in _reasons)
                      ActionChip(label: Text(r), onPressed: () => setState(() => _reason.text = r)),
                  ]),
                  const SizedBox(height: 8),
                  FormText(controller: _reason, autofocus: true),
                ]),
              ),
            ] else ...[
              if (_status == 'partial')
                const InfoBanner(
                    text: 'Livraison partielle : la commande passe « Livrée » ; faites un avoir pour la marchandise revenue.',
                    kind: ToastKind.warning),
              LabeledField(
                label: 'Argent encaissé',
                helper: 'Attendu : ${fmtDA(s.codExpected)}. Comptabilisé à la clôture de la tournée.',
                child: FormText(controller: _cod, numeric: true, suffixText: 'DA', autofocus: true, onSubmitted: (_) => _submit()),
              ),
              LabeledField(
                label: 'Moyen de paiement',
                child: FormDropdown<String>(value: _method, options: paymentMethodsCod, onChanged: (v) => setState(() => _method = v ?? 'cash')),
              ),
              LabeledField(label: 'Reçu par', child: FormText(controller: _receiver, hint: 'Nom de la personne')),
            ],
            LabeledField(label: 'Note (facultative)', child: FormText(controller: _note)),
            FieldError(_error),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: failed ? T.danger : T.mint, foregroundColor: failed ? Colors.white : T.ink),
          onPressed: _submit,
          child: Text(failed ? 'Enregistrer l’échec' : 'Enregistrer'),
        ),
      ],
    );
  }
}

class _AddOrdersDialog extends StatefulWidget {
  const _AddOrdersDialog({required this.api, required this.routeId, required this.exclude});
  final ApiClient api;
  final String? routeId;
  final Set<String> exclude;

  @override
  State<_AddOrdersDialog> createState() => _AddOrdersDialogState();
}

class _AddOrdersDialogState extends State<_AddOrdersDialog> {
  List<CustomerOrder> _items = const [];
  final Set<String> _sel = {};
  bool _all = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _all = widget.routeId == null;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await widget.api.orders(statuses: const ['ready'], routeId: _all ? null : widget.routeId, limit: 500);
      if (mounted) {
        setState(() {
          _items = [for (final o in p.items) if (!widget.exclude.contains(o.id)) o];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Row(children: [
        const Expanded(child: Text('Ajouter des commandes prêtes', style: T.h2)),
        if (widget.routeId != null) ...[
          Text('Toutes les tournées', style: T.small),
          Switch(
              value: _all,
              onChanged: (v) {
                setState(() => _all = v);
                _load();
              }),
        ],
      ]),
      content: SizedBox(
        width: 640,
        height: 440,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: T.mint))
            : _items.isEmpty
                ? Center(child: Text('Aucune autre commande prête.', style: T.bodyMuted))
                : ListView(children: [
                    for (final o in _items)
                      CheckboxListTile(
                        dense: true,
                        value: _sel.contains(o.id),
                        onChanged: (v) => setState(() => v == true ? _sel.add(o.id) : _sel.remove(o.id)),
                        title: Text('${o.number} — ${o.partnerName}', style: T.body),
                        subtitle: Text([o.wilaya, o.commune, o.routeName, fmtDA(o.totalTTC)].where((s) => s.isNotEmpty).join(' · '),
                            style: T.small),
                      ),
                  ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel.toList()),
          child: Text('Ajouter (${_sel.length})'),
        ),
      ],
    );
  }
}
