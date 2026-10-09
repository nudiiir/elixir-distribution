import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_list.dart' show DocChip, showDocDetailDialog;
import '../../widgets/ui.dart';
import '../crm/send_message.dart';
import 'order_actions.dart';
import 'order_common.dart';
import 'order_form_page.dart';
import 'orders_pdf.dart';
import 'picking_page.dart';
import 'product_pick.dart';

/// Message template proposed for an order status (seed of 0017_crm.sql).
String? orderMessageTemplate(String status) => switch (status) {
      'validated' => 'order_confirmed',
      'ready' => 'order_ready',
      'shipping' => 'order_shipped',
      'delivered' => 'order_delivered',
      _ => null,
    };

/// The page of one customer order: where it stands (timeline), what to do
/// next (named buttons per status), the lines, the documents.
class OrderDetailPage extends StatefulWidget {
  const OrderDetailPage({super.key, required this.api, required this.user, required this.orderId});
  final ApiClient api;
  final User user;
  final String orderId;

  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  ApiClient get api => widget.api;
  User get user => widget.user;
  bool get _manage => user.isAdmin || user.can('orders.manage');
  bool get _validate => user.isAdmin || user.can('orders.validate');

  /// Messages: crm.view | orders.view (same rule as the client page).
  bool get _canMessage => user.isAdmin || user.can('crm.view') || user.can('orders');

  CustomerOrder? _o;
  String? _error;
  bool _busy = false;
  bool _changed = false;
  bool _showHistory = false;

  /// Last status seen, to notice a change (whatever the path: buttons,
  /// preparation page, BL…).
  String? _lastStatus;

  /// Status just reached that the client could be told about
  /// (« Prévenir le client ? »). Null = no prompt.
  String? _notify;

  /// « Choisir les quantités à valider » (partial validation).
  bool _chooseQty = false;
  final Map<String, TextEditingController> _valQty = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _valQty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await api.order(widget.orderId);
      if (mounted) {
        setState(() {
          _setOrder(o);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  void _back() => Navigator.of(context).pop(_changed);

  /// Sets the order and notices a status change worth a message.
  void _setOrder(CustomerOrder o) {
    if (_lastStatus != null && o.status != _lastStatus) {
      _notify = _canMessage && orderMessageTemplate(o.status) != null ? o.status : null;
    }
    _lastStatus = o.status;
    _o = o;
  }

  /// « Envoyer un message » : the send panel, with the template of the
  /// current status preselected.
  Future<void> _message() async {
    final o = _o!;
    final sent = await showSendMessagePanel(context, api,
        orderId: o.id,
        partnerId: o.partnerId.isEmpty ? null : o.partnerId,
        partnerName: o.partnerName,
        templateCode: orderMessageTemplate(o.status));
    if (sent && mounted) {
      setState(() => _notify = null);
      _load();
    }
  }

  /// Runs an action that returns the updated order.
  Future<void> _act(Future<CustomerOrder?> Function() run) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final o = await run();
      if (o != null && mounted) {
        _changed = true;
        // Action answers carry the detail; reload anyway for computed fields.
        setState(() => _setOrder(o));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- actions

  Future<void> _validateOrder() async {
    final o = _o!;
    List<Map<String, dynamic>>? lines;
    if (_chooseQty) {
      lines = [];
      for (final l in o.activeLines) {
        final c = _valQty[l.id];
        final q = c == null ? null : parseQty(c.text);
        if (q == null || q < 0 || q > l.qtyOrderedMilli) {
          showToast(context, '${l.productName} : quantité à valider entre 0 et ${fmtQty(l.qtyOrderedMilli)}.',
              kind: ToastKind.warning);
          return;
        }
        lines.add({'line_id': l.id, 'qty_validated_milli': q});
      }
    }
    await _act(() => validateOrderFlow(context, api, user, o.id, lines: lines));
    if (mounted) setState(() => _chooseQty = false);
  }

  Future<void> _edit() async {
    final o = _o!;
    if (o.status == 'validated') {
      final ok = await confirmAction(context,
          title: 'Modifier une commande validée ?',
          message: 'Si vous changez les produits, la commande repasse « Nouvelle » et devra être revalidée.',
          confirmLabel: 'Modifier');
      if (!ok || !mounted) return;
    }
    final saved = await Navigator.of(context).push<CustomerOrder>(MaterialPageRoute(
      builder: (_) => OrderFormPage(api: api, user: user, existing: o),
    ));
    if (saved != null && mounted) {
      _changed = true;
      _load();
    }
  }

  Future<void> _openPicking() async {
    final o = _o!;
    if (o.status == 'validated') {
      final started = await runGuarded(context, api, () => api.startPreparation(o.id));
      if (started == null || !mounted) return;
      _changed = true;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PickingPage(api: api, user: user, orderId: o.id)));
    _changed = true;
    if (mounted) _load();
  }

  Future<void> _deliveryNote() async {
    final o = _o!;
    if (o.deliveryNoteId != null) {
      await _openDoc(o.deliveryNoteId!);
      return;
    }
    final ok = await confirmAction(context,
        title: 'Créer le bon de livraison ?',
        message: 'Le stock sort (par lot prélevé). Les unités offertes apparaissent à 100 % de remise.',
        confirmLabel: 'Créer le BL',
        icon: Icons.receipt_outlined);
    if (!ok || !mounted) return;
    await _act(() async {
      final r = await runGuarded(context, api, () => api.orderDeliveryNote(o.id));
      if (r != null && mounted) {
        final id = '${r.raw['document_id'] ?? r.deliveryNoteId ?? ''}';
        showToast(context, 'Bon de livraison ${r.raw['document_number'] ?? r.deliveryNoteNumber ?? ''} créé.',
            actionLabel: id.isEmpty ? null : 'Ouvrir', onAction: id.isEmpty ? null : () => _openDoc(id));
      }
      return r;
    });
  }

  Future<void> _openDoc(String id) async {
    await showDocDetailDialog(context, api, id);
    if (mounted) _load();
  }

  Future<void> _releaseBackorder() async {
    final o = _o!;
    await _act(() async {
      final r = await runGuarded(context, api, () => api.releaseBackorder(o.id));
      if (r != null && mounted) showToast(context, 'Reliquats remis dans la commande selon le stock disponible.');
      return r;
    });
  }

  Future<void> _print(String what) async {
    final o = _o!;
    try {
      if (what == 'order') {
        await printOrderPdf(api, o);
      } else {
        await printPickingPdf(api, await api.pickingList(o.id));
      }
    } catch (e) {
      if (mounted) showActionError(context, e);
    }
  }

  // ---- lines

  Future<void> _editQty(OrderLine l) async {
    final o = _o!;
    final t = await askText(context,
        title: 'Quantité — ${l.productName}',
        message: o.status == 'validated'
            ? 'La nouvelle quantité est revalidée contre le stock disponible ; le reste part en reliquat.'
            : 'Les unités offertes (UG) sont recalculées.',
        label: 'Nouvelle quantité',
        initial: fmtQty(l.qtyOrderedMilli),
        confirmLabel: 'Enregistrer');
    if (t == null || !mounted) return;
    final q = parseQty(t);
    if (q == null || q <= 0) {
      showToast(context, 'Quantité invalide.', kind: ToastKind.warning);
      return;
    }
    await _act(() => runGuarded(context, api, () => api.patchOrderLine(o.id, l.id, {'qty_milli': q})));
  }

  Future<void> _substitute(OrderLine l) async {
    final o = _o!;
    final p = await pickProduct(context, api, title: 'Remplacer « ${l.productName} » par…');
    if (p == null || !mounted) return;
    final ok = await confirmAction(context,
        title: 'Remplacer par ${p.name} ?',
        message: 'Même quantité (${fmtQty(l.qtyOrderedMilli)}), au prix du nouveau produit pour ce client. '
            'L’ancienne ligne reste visible, à zéro.',
        confirmLabel: 'Remplacer',
        icon: Icons.swap_horiz_rounded);
    if (!ok || !mounted) return;
    await _act(() => runGuarded(context, api, () => api.substituteOrderLine(o.id, l.id, productId: p.id)));
  }

  Future<void> _deleteLine(OrderLine l) async {
    final o = _o!;
    final ok = await confirmAction(context,
        title: 'Retirer ${l.productName} ?', confirmLabel: 'Retirer', danger: true);
    if (!ok || !mounted) return;
    await _act(() => runGuarded(context, api, () => api.deleteOrderLine(o.id, l.id)));
  }

  // ---------------------------------------------------------------- build

  List<Widget> _actions(CustomerOrder o) {
    final busy = _busy;
    VoidCallback? on(VoidCallback f) => busy ? null : f;
    final printMenu = PopupMenuButton<String>(
      tooltip: 'Imprimer',
      onSelected: _print,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'order', child: Text('Bon de commande')),
        if (const {'validated', 'preparing', 'ready'}.contains(o.status))
          const PopupMenuItem(value: 'picking', child: Text('Liste de préparation')),
      ],
      child: const IgnorePointer(child: PageAction(label: 'Imprimer', icon: Icons.print_outlined, onPressed: _noop)),
    );
    return [
      printMenu,
      if (_canMessage && o.status != 'cancelled')
        PageAction(label: 'Envoyer un message', icon: Icons.chat_outlined, onPressed: on(_message)),
      if (_manage && (o.status == 'new' || o.status == 'validated'))
        PageAction(label: 'Modifier', icon: Icons.edit_outlined, onPressed: on(_edit)),
      if (_manage && o.status == 'validated')
        PageAction(label: 'Rouvrir', icon: Icons.undo_rounded, onPressed: on(() => _act(() => moveOrder(context, api, user, o, 'new')))),
      if (_manage && const {'new', 'validated', 'preparing', 'ready', 'shipping'}.contains(o.status))
        PageAction(
            label: 'Annuler', icon: Icons.block_rounded, danger: true, onPressed: on(() => _act(() => cancelFlow(context, api, o)))),
      ...switch (o.status) {
        'new' => [
            if (_validate)
              PageAction(
                  label: _chooseQty ? 'Valider ces quantités' : 'Valider',
                  icon: Icons.check_circle_outline_rounded,
                  primary: true,
                  onPressed: on(_validateOrder)),
          ],
        'validated' => [
            if (_manage) ...[
              PageAction(
                  label: 'Marquer prête',
                  icon: Icons.inventory_2_outlined,
                  onPressed: on(() => _act(() => moveOrder(context, api, user, o, 'ready')))),
              PageAction(label: 'Démarrer la préparation', icon: Icons.qr_code_scanner_rounded, primary: true, onPressed: on(_openPicking)),
            ],
          ],
        'preparing' => [
            if (_manage) ...[
              PageAction(
                  label: 'Marquer prête',
                  icon: Icons.inventory_2_outlined,
                  onPressed: on(() => _act(() => readyFlow(context, api, o.id)))),
              PageAction(label: 'Préparation', icon: Icons.qr_code_scanner_rounded, primary: true, onPressed: on(_openPicking)),
            ],
          ],
        'ready' => [
            if (_manage) ...[
              PageAction(
                  label: o.deliveryNoteId == null ? 'Créer le BL' : 'Ouvrir le BL',
                  icon: Icons.receipt_outlined,
                  onPressed: on(_deliveryNote)),
              PageAction(
                  label: 'Expédier', icon: Icons.local_shipping_outlined, onPressed: on(() => _act(() => shipFlow(context, api, o)))),
              PageAction(
                  label: 'Livrer',
                  icon: Icons.where_to_vote_outlined,
                  primary: true,
                  onPressed: on(() => _act(() => deliverFlow(context, api, o)))),
            ],
          ],
        'shipping' => [
            if (_manage)
              PageAction(
                  label: 'Livrer',
                  icon: Icons.where_to_vote_outlined,
                  primary: true,
                  onPressed: on(() => _act(() => deliverFlow(context, api, o)))),
          ],
        'delivered' => [
            if (_manage)
              PageAction(
                  label: 'Facturer',
                  icon: Icons.receipt_long_outlined,
                  primary: true,
                  onPressed: on(() => _act(() => invoiceFlow(context, api, o)))),
          ],
        'invoiced' => [
            if (o.invoiceId != null)
              PageAction(
                  label: 'Ouvrir la facture',
                  icon: Icons.receipt_long_outlined,
                  primary: true,
                  onPressed: on(() => _openDoc(o.invoiceId!))),
          ],
        _ => const <Widget>[],
      },
    ];
  }

  static void _noop() {}

  @override
  Widget build(BuildContext context) {
    final o = _o;
    if (o == null) {
      return AppPage(
        crumbs: [Crumb('Commandes clients', _back), const Crumb('Commande')],
        title: 'Commande',
        onBack: _back,
        body: _error == null
            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: T.mint)))
            : EmptyState(icon: Icons.cloud_off_rounded, text: _error!, actions: [('Réessayer', _load)]),
      );
    }
    return AppPage(
      crumbs: [Crumb('Commandes clients', _back), Crumb(o.number)],
      title: 'Commande ${o.number}',
      onBack: _back,
      maxWidth: 1280,
      subtitle: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OrderStatusChip(o.status),
        PriorityBadge(o.priority),
        if (o.isPartial) const DocChip(label: 'Partielle', bg: T.warnTint, fg: T.warnDark),
        if (o.hasBackorder) const DocChip(label: 'Reliquat en attente', bg: T.cream, fg: T.muted),
        if (o.creditOverride) const DocChip(label: 'Validée malgré le compte', bg: T.warnTint, fg: T.warnDark),
        SourceIcon(o.source),
        Text('${orderSourceLabel(o.source)} · ${o.partnerName} · ${frDate(o.orderDate)}', style: T.bodyMuted),
      ]),
      actions: _actions(o),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.mintTint),
        _timeline(o),
        if (_notify != null && _notify == o.status)
          InfoBanner(
            text: 'Commande ${orderStatusLabel(o.status).toLowerCase()}. Prévenir le client ?',
            kind: ToastKind.success,
            action: Wrap(spacing: 4, children: [
              TextButton.icon(
                  onPressed: _busy ? null : _message,
                  icon: const Icon(Icons.chat_outlined, size: 16),
                  label: const Text('Envoyer un message')),
              TextButton(onPressed: () => setState(() => _notify = null), child: const Text('Plus tard')),
            ]),
          ),
        if (o.status == 'cancelled')
          InfoBanner(text: 'Commande annulée${o.cancelReason.isEmpty ? '' : ' : ${o.cancelReason}'}', kind: ToastKind.error),
        if (o.status == 'new' && o.activeLines.any((l) => !l.isService && l.availableMilli < l.qtyOrderedMilli))
          InfoBanner(
            text: 'Stock insuffisant pour certaines lignes : à la validation, le manque part en reliquat.',
            kind: ToastKind.warning,
            action: _validate
                ? TextButton(
                    onPressed: () => setState(() => _chooseQty = !_chooseQty),
                    child: Text(_chooseQty ? 'Valider tout le disponible' : 'Choisir les quantités'))
                : null,
          ),
        if (o.hasBackorder && _manage && (o.status == 'validated' || o.status == 'preparing'))
          InfoBanner(
            text: 'Des quantités attendent du stock (reliquat).',
            action: TextButton(onPressed: _busy ? null : _releaseBackorder, child: const Text('Remettre ce qui est disponible')),
          ),
        _linesSection(o),
        LayoutBuilder(builder: (context, c) {
          final a = _clientSection(o);
          final b = _documentsSection(o);
          return c.maxWidth > 900
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: a),
                  const SizedBox(width: 16),
                  Expanded(child: b),
                ])
              : Column(children: [a, b]);
        }),
        _historySection(o),
      ]),
    );
  }

  Widget _timeline(CustomerOrder o) {
    const steps = ['new', 'validated', 'preparing', 'ready', 'shipping', 'delivered', 'invoiced'];
    var current = steps.indexOf(o.status);
    if (o.status == 'cancelled') {
      // Last status reached before the cancellation.
      final before = o.events.lastWhere((e) => e.toStatus == 'cancelled', orElse: () => o.events.isEmpty ? OrderEvent.fromJson(const {}) : o.events.last);
      current = steps.indexOf(before.fromStatus ?? 'new');
    }
    String? when(String s) {
      for (final e in o.events.reversed) {
        if (e.toStatus == s) return frDateTime(e.createdAt);
      }
      return s == 'new' ? frDateTime(o.createdAt) : null;
    }

    return PageSection(
      title: 'Où en est la commande',
      child: Row(children: [
        for (var i = 0; i < steps.length; i++) ...[
          Expanded(
            child: Column(children: [
              Row(children: [
                Expanded(child: Container(height: 3, color: i == 0 ? Colors.transparent : (i <= current ? T.mint : T.border))),
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < current ? T.mint : (i == current ? (o.status == 'cancelled' ? T.danger : T.ink) : T.surface),
                    border: Border.all(color: i <= current ? Colors.transparent : T.border3, width: 2),
                  ),
                  child: i < current
                      ? const Icon(Icons.check_rounded, size: 15, color: T.ink)
                      : Text('${i + 1}',
                          style: T.label.copyWith(color: i == current ? Colors.white : T.faint, fontSize: 12)),
                ),
                Expanded(
                    child: Container(
                        height: 3, color: i == steps.length - 1 ? Colors.transparent : (i < current ? T.mint : T.border))),
              ]),
              const SizedBox(height: 6),
              Text(orderStatusLabel(steps[i]),
                  textAlign: TextAlign.center,
                  style: T.small.copyWith(
                      color: i == current ? T.ink : T.faint, fontWeight: i == current ? FontWeight.w800 : FontWeight.w500)),
              if (i <= current && when(steps[i]) != null)
                Text(when(steps[i])!, textAlign: TextAlign.center, style: T.small.copyWith(fontSize: 12)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _linesSection(CustomerOrder o) {
    final editable = _manage && (o.status == 'new' || o.status == 'validated');
    final canSub = _manage && const {'new', 'validated', 'preparing'}.contains(o.status);
    final showAvail = o.status == 'new' || o.status == 'validated';
    final showPrep = const {'preparing', 'ready', 'shipping', 'delivered', 'invoiced'}.contains(o.status);
    Widget head(String s, double? w, {bool end = false}) {
      final t = Text(s, style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    Widget num(String s, double w, {Color? color, bool bold = false}) => SizedBox(
        width: w,
        child: Text(s,
            textAlign: TextAlign.end,
            style: T.monoSmall.copyWith(color: color ?? T.ink, fontWeight: bold ? FontWeight.w700 : FontWeight.w400)));

    return PageSection(
      title: 'Produits',
      trailing: Text('${o.activeLines.length} ligne${o.activeLines.length > 1 ? 's' : ''}', style: T.small),
      child: Column(children: [
        Row(children: [
          head('Produit', null),
          head('Commandé', 80, end: true),
          if (o.status != 'new') head('Validé', 70, end: true),
          head('Reliquat', 70, end: true),
          head('Offert', 64, end: true),
          if (showPrep) head('Préparé', 70, end: true),
          if (showAvail) head('Disponible', 84, end: true),
          if (_chooseQty) head('À valider', 96, end: true),
          head('Prix HT', 110, end: true),
          head('Total TTC', 116, end: true),
          if (editable || canSub) const SizedBox(width: 112),
        ]),
        const Divider(height: 14),
        for (final l in o.lines)
          Opacity(
            opacity: l.inactive ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.productName,
                        style: T.body.copyWith(
                            fontWeight: FontWeight.w600, decoration: l.inactive ? TextDecoration.lineThrough : null)),
                    Wrap(spacing: 6, children: [
                      Text(priceSourceLabel(l.priceSource), style: T.small),
                      if (l.discountPct > 0) Text('remise ${pctText(l.discountPct)}', style: T.small),
                      if (l.substitutedFromLineId != null)
                        Text('remplace un autre produit', style: T.small.copyWith(color: T.warnDark)),
                      if (l.inactive) Text('ligne remplacée ou déplacée', style: T.small),
                    ]),
                  ]),
                ),
                num(fmtQty(l.qtyOrderedMilli), 80),
                if (o.status != 'new') num(fmtQty(l.qtyValidatedMilli), 70),
                num(l.qtyBackorderMilli > 0 ? fmtQty(l.qtyBackorderMilli) : '—', 70,
                    color: l.qtyBackorderMilli > 0 ? T.warnDark : T.ghost, bold: l.qtyBackorderMilli > 0),
                num(l.qtyFreeMilli > 0 ? '+${fmtQty(l.qtyFreeMilli)}' : '—', 64,
                    color: l.qtyFreeMilli > 0 ? T.mintDark : T.ghost, bold: l.qtyFreeMilli > 0),
                if (showPrep)
                  num('${fmtQty(l.qtyPreparedMilli)}/${fmtQty(l.qtyToPrepareMilli)}', 70,
                      color: l.qtyPreparedMilli >= l.qtyToPrepareMilli ? T.mintDark : T.warnDark),
                if (showAvail)
                  num(l.isService ? '—' : fmtQty(l.availableMilli), 84,
                      color: !l.isService && l.availableMilli < l.qtyOrderedMilli ? T.dangerDark : T.muted,
                      bold: !l.isService && l.availableMilli < l.qtyOrderedMilli),
                if (_chooseQty)
                  SizedBox(
                    width: 96,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: l.inactive
                          ? const SizedBox()
                          : FormText(
                              numeric: true,
                              controller: _valQty.putIfAbsent(
                                  l.id,
                                  () => TextEditingController(
                                      text: fmtQty(l.isService
                                          ? l.qtyOrderedMilli
                                          : l.availableMilli.clamp(0, l.qtyOrderedMilli)))),
                            ),
                    ),
                  ),
                num(fmtDA(l.unitPrice), 110),
                num(fmtDA(l.lineTTC), 116, bold: true),
                if (editable || canSub)
                  SizedBox(
                    width: 112,
                    child: l.inactive
                        ? const SizedBox()
                        : Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            if (editable)
                              IconButton(
                                  tooltip: 'Changer la quantité',
                                  icon: const Icon(Icons.edit_outlined, size: 17),
                                  onPressed: _busy ? null : () => _editQty(l)),
                            if (canSub && l.qtyPreparedMilli == 0)
                              IconButton(
                                  tooltip: 'Remplacer par un autre produit',
                                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                                  onPressed: _busy ? null : () => _substitute(l)),
                            if (editable)
                              IconButton(
                                  tooltip: 'Retirer la ligne',
                                  icon: const Icon(Icons.delete_outline_rounded, size: 17, color: T.dangerDark),
                                  onPressed: _busy ? null : () => _deleteLine(l)),
                          ]),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 320,
            child: Column(children: [
              for (final (k, v) in [
                ('Total HT', fmtDA(o.totalHT)),
                ('TVA', fmtDA(o.totalVAT)),
                if (o.totalDiscount > 0) ('Remises', fmtDA(o.totalDiscount)),
                if (o.shippingFee > 0) ('Frais de livraison', fmtDA(o.shippingFee)),
                if (o.extraDiscount > 0) ('Remise ${o.promoCode.isEmpty ? '' : '(code ${o.promoCode})'}', '-${fmtDA(o.extraDiscount)}'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [Expanded(child: Text(k, style: T.bodyMuted)), Text(v, style: T.monoBody)]),
                ),
              const Divider(height: 14),
              Row(children: [
                const Expanded(child: Text('Total TTC', style: T.h2)),
                Text(fmtDA(o.totalTTC), style: T.monoBig.copyWith(fontSize: 22)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _clientSection(CustomerOrder o) => PageSection(
        title: 'Client et livraison',
        child: FactGrid(columns: 2, facts: [
          ('Client', o.partnerName),
          ('Téléphone', o.contactPhone.isNotEmpty ? o.contactPhone : o.partnerPhone),
          ('Adresse', o.deliveryAddress),
          ('Wilaya / commune', [o.wilaya, o.commune].where((s) => s.isNotEmpty).join(' — ')),
          ('Contact', o.contactName),
          ('Livraison souhaitée', frDate(o.requestedDate)),
          ('Tournée', o.routeName),
          ('Commercial', o.repName),
          ('Paiement', o.paymentMode == 'cod' ? 'À la livraison' : 'Sur le compte du client'),
          ('Dépôt', o.warehouseName),
          if (o.externalNumber != null) ('N° boutique web', o.externalNumber!),
          ('Saisie par', o.createdByName),
          if (o.notes.isNotEmpty) ('Note pour le client', o.notes),
          if (o.internalNotes.isNotEmpty) ('Note interne', o.internalNotes),
        ]),
      );

  Widget _documentsSection(CustomerOrder o) {
    Widget docRow(String label, String? number, String? id, IconData icon) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Icon(icon, size: 18, color: number == null ? T.ghost : T.mintDark),
            const SizedBox(width: 10),
            SizedBox(width: 150, child: Text(label, style: T.label)),
            Expanded(child: Text(number ?? 'Pas encore', style: number == null ? T.small : T.monoBody)),
            if (id != null) TextButton(onPressed: () => _openDoc(id), child: const Text('Ouvrir')),
          ]),
        );
    return PageSection(
      title: 'Documents',
      child: Column(children: [
        docRow('Bon de livraison', o.deliveryNoteNumber, o.deliveryNoteId, Icons.receipt_outlined),
        docRow('Facture', o.invoiceNumber, o.invoiceId, Icons.receipt_long_outlined),
        docRow('Encaissement', o.paymentNumber, o.paymentId, Icons.payments_outlined),
      ]),
    );
  }

  Widget _historySection(CustomerOrder o) {
    final events = o.events.reversed.toList();
    return PageSection(
      title: 'Historique',
      trailing: TextButton(
          onPressed: () => setState(() => _showHistory = !_showHistory),
          child: Text(_showHistory ? 'Masquer' : 'Afficher les ${events.length} étapes')),
      child: !_showHistory
          ? Text(
              events.isEmpty
                  ? 'Aucun événement.'
                  : 'Dernière action : ${_eventLabel(events.first)} — ${frDateTime(events.first.createdAt)}',
              style: T.bodyMuted)
          : Column(children: [
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 140, child: Text(frDateTime(e.createdAt), style: T.monoSmall)),
                    SizedBox(width: 200, child: Text(_eventLabel(e), style: T.body.copyWith(fontWeight: FontWeight.w600))),
                    Expanded(child: Text(e.note, style: T.bodyMuted)),
                    SizedBox(width: 140, child: Text(e.userName, style: T.small, textAlign: TextAlign.end)),
                  ]),
                ),
            ]),
    );
  }

  static String _eventLabel(OrderEvent e) => switch (e.action) {
        'create' => 'Créée',
        'import' => 'Importée de la boutique',
        'update' => 'Modifiée',
        'add_line' => 'Produit ajouté',
        'edit_line' => 'Ligne modifiée',
        'delete_line' => 'Ligne retirée',
        'substitute' => 'Produit remplacé',
        'validate' => 'Validée',
        'reopen' => 'Rouverte',
        'start_preparation' => 'Préparation démarrée',
        'resume_preparation' => 'Préparation reprise',
        'pick' => 'Prélèvement',
        'unpick' => 'Prélèvement annulé',
        'ready' => 'Prête',
        'delivery_note' => 'Bon de livraison créé',
        'ship' => 'Expédiée',
        'deliver' => 'Livrée',
        'delivery_failed' => 'Échec de livraison',
        'run_add' => 'Ajoutée à une tournée',
        'run_remove' => 'Retirée d’une tournée',
        'cod_collected' => 'Paiement encaissé',
        'invoice' => 'Facturée',
        'cancel' => 'Annulée',
        'release_backorder' => 'Reliquat remis',
        'backorder_moved' => 'Reliquat déplacé',
        _ => e.toStatus == null ? e.action : orderStatusLabel(e.toStatus!),
      };
}
