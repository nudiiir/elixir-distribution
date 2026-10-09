import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../../widgets/doc_list.dart' show DocChip;
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import '../crm/send_message.dart';
import 'order_common.dart';

/// « Reliquats » : order lines waiting for stock, the ones that can be
/// served now, and the two ways to serve them (back into the same order, or
/// a new order per client).
class BackordersView extends StatefulWidget {
  const BackordersView({
    super.key,
    required this.api,
    required this.canManage,
    required this.onOpenOrder,
    this.onChanged,
  });
  final ApiClient api;
  final bool canManage;
  final Future<void> Function(String orderId) onOpenOrder;
  final VoidCallback? onChanged;

  @override
  State<BackordersView> createState() => _BackordersViewState();
}

class _BackordersViewState extends State<BackordersView> {
  List<BackorderRow> _rows = const [];
  int _fulfillable = 0;
  bool _loading = true;
  String? _error;
  bool _onlyFulfillable = false;
  (String, String)? _client;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (rows, n) = await widget.api.backorders(partnerId: _client?.$1, fulfillable: _onlyFulfillable);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _fulfillable = n;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de charger les reliquats : $e';
      });
    }
  }

  /// Messages: crm.view | orders.view.
  bool get _canMessage {
    final u = widget.api.user;
    return u != null && (u.isAdmin || u.can('crm.view') || u.can('orders'));
  }

  /// « Prévenir le client » : the product is back, tell the client
  /// (template backorder_available).
  Future<void> _tellClient(BackorderRow r) async {
    final sent = await showSendMessagePanel(context, widget.api,
        partnerId: r.partnerId,
        partnerName: r.partnerName,
        orderId: r.orderId,
        templateCode: 'backorder_available',
        extra: {'produit': r.productName});
    if (sent && mounted) showToast(context, 'Message pour ${r.partnerName} enregistré.');
  }

  List<BackorderRow> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return [
      for (final r in _rows)
        if (r.productName.toLowerCase().contains(q) ||
            r.partnerName.toLowerCase().contains(q) ||
            r.orderNumber.toLowerCase().contains(q))
          r
    ];
  }

  Future<void> _release(BackorderRow r) async {
    if (r.orderStatus != 'validated' && r.orderStatus != 'preparing') {
      showToast(context, 'La commande ${r.orderNumber} n’est plus en cours : créez plutôt une nouvelle commande.',
          kind: ToastKind.warning);
      return;
    }
    final ok = await confirmAction(context,
        title: 'Remettre dans la commande ${r.orderNumber} ?',
        message: '${r.productName} : jusqu’à ${fmtQty(r.qtyBackorderMilli)} selon le stock disponible.',
        confirmLabel: 'Remettre dans la commande');
    if (!ok || !mounted) return;
    final o = await runGuarded(context, widget.api, () => widget.api.releaseBackorder(r.orderId, lineIds: [r.lineId]));
    if (o != null && mounted) {
      showToast(context, 'Reliquat remis dans ${o.number}.');
      _load();
      widget.onChanged?.call();
    }
  }

  /// One new order per client with the chosen lines.
  Future<bool> _newOrders(List<BackorderRow> rows) async {
    final byClient = <String, List<BackorderRow>>{};
    for (final r in rows) {
      byClient.putIfAbsent(r.partnerId, () => []).add(r);
    }
    final ok = await confirmAction(context,
        title: byClient.length == 1
            ? 'Créer une commande pour ${rows.first.partnerName} ?'
            : 'Créer ${byClient.length} commandes (une par client) ?',
        message: '${rows.length} ligne${rows.length > 1 ? 's' : ''} en reliquat, aux mêmes prix. '
            'Les nouvelles commandes sont « Nouvelles » : il faudra les valider.',
        confirmLabel: 'Créer');
    if (!ok || !mounted) return false;
    final created = <String>[];
    for (final e in byClient.entries) {
      final o = await runGuarded(context, widget.api,
          () => widget.api.backorderNewOrder(e.key, lineIds: [for (final r in e.value) r.lineId]));
      if (o != null) created.add(o.number);
      if (!mounted) return false;
    }
    if (created.isNotEmpty && mounted) {
      showToast(context, 'Commande${created.length > 1 ? 's' : ''} créée${created.length > 1 ? 's' : ''} : ${created.join(', ')}.');
      _load();
      widget.onChanged?.call();
    }
    return created.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        search: _search,
        searchHint: 'Produit, client, n° de commande…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          FilterPill(
            label: 'Servables maintenant',
            icon: Icons.inventory_rounded,
            count: _fulfillable,
            active: _onlyFulfillable,
            onTap: () {
              setState(() => _onlyFulfillable = !_onlyFulfillable);
              _load();
            },
          ),
          FilterPill(
            label: _client == null ? 'Choisir un client' : 'Client : ${_client!.$2}',
            icon: Icons.person_search_outlined,
            active: _client != null,
            onTap: () async {
              if (_client != null) {
                setState(() => _client = null);
                _load();
                return;
              }
              final p = await showPartnerPicker(context, widget.api, kind: 'customer');
              if (p != null && mounted) {
                setState(() => _client = (p.id, p.name));
                _load();
              }
            },
          ),
        ],
        trailing: [
          OutlinedButton.icon(
              onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('Actualiser')),
        ],
      ),
      const SizedBox(height: 10),
      Text(
          'Un reliquat est une quantité commandée qui n’était pas en stock. Quand le produit arrive, '
          'cochez les lignes servables puis « Créer la commande », ou remettez-les dans la commande d’origine.',
          style: T.bodyMuted),
      const SizedBox(height: 10),
      Expanded(
        child: DataListView<BackorderRow>(
          items: _visible,
          prefsKey: 'orders_backorders',
          loading: _loading,
          error: _error,
          onRetry: _load,
          rowId: (r) => r.lineId,
          onTap: (r) => widget.onOpenOrder(r.orderId).then((_) => _load()),
          exportTitle: 'Reliquats',
          exportBaseName: 'reliquats',
          rowMenu: (r) => [
            RowAction('Ouvrir la commande', Icons.open_in_new_rounded, (r) => widget.onOpenOrder(r.orderId)),
            if (_canMessage)
              RowAction('Prévenir le client', Icons.chat_outlined, _tellClient, enabled: r.fulfillableMilli > 0),
            if (widget.canManage) ...[
              RowAction('Remettre dans la commande', Icons.undo_rounded, _release,
                  enabled: r.fulfillableMilli > 0),
              RowAction('Nouvelle commande pour ce client', Icons.add_shopping_cart_rounded,
                  (r) => _newOrders([for (final x in _rows) if (x.partnerId == r.partnerId) x])),
            ],
          ],
          bulkActions: [
            if (widget.canManage) BulkAction('Créer la commande', Icons.add_shopping_cart_rounded, _newOrders),
          ],
          empty: EmptyState(
            icon: Icons.check_circle_outline_rounded,
            text: _onlyFulfillable ? 'Aucun reliquat ne peut être servi pour l’instant.' : 'Aucun reliquat en attente.',
          ),
          aggregates: (rows) => [
            ('Lignes', '${rows.length}'),
            ('Valeur HT', fmtDA(rows.fold(0, (s, r) => s + roundDiv(r.unitPrice * r.qtyBackorderMilli, 1000)))),
          ],
          columns: [
            ColumnSpec(
              id: 'product',
              label: 'Produit',
              flex: 3,
              hideable: false,
              sortKey: (r) => r.productName.toLowerCase(),
              exportValue: (r) => r.productName,
              cell: (_, r) => Text(r.productName, style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'client',
              label: 'Client',
              flex: 3,
              sortKey: (r) => r.partnerName.toLowerCase(),
              exportValue: (r) => r.partnerName,
              cell: (_, r) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(r.partnerName, style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (r.partnerPhone.isNotEmpty) Text(r.partnerPhone, style: T.monoSmall),
              ]),
            ),
            ColumnSpec(
              id: 'order',
              label: 'Commande',
              width: 170,
              sortKey: (r) => r.orderDate,
              exportValue: (r) => r.orderNumber,
              cell: (_, r) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(r.orderNumber, style: T.monoSmall.copyWith(color: T.ink)),
                Text('${frDate(r.orderDate)} · ${orderStatusLabel(r.orderStatus)}', style: T.small),
              ]),
            ),
            ColumnSpec(
              id: 'qty',
              label: 'En attente',
              width: 100,
              numeric: true,
              sortKey: (r) => r.qtyBackorderMilli,
              exportValue: (r) => r.qtyBackorderMilli / 1000,
              cell: (_, r) => Text(fmtQty(r.qtyBackorderMilli), style: T.monoBody),
            ),
            ColumnSpec(
              id: 'available',
              label: 'Disponible',
              width: 100,
              numeric: true,
              sortKey: (r) => r.availableMilli,
              exportValue: (r) => r.availableMilli / 1000,
              cell: (_, r) => Text(fmtQty(r.availableMilli), style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'fulfillable',
              label: 'Servable',
              width: _canMessage ? 260 : 150,
              sortKey: (r) => r.fulfillableMilli,
              exportValue: (r) => r.fulfillableMilli / 1000,
              cell: (_, r) => r.fulfillableMilli <= 0
                  ? Text('Pas encore', style: T.small)
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      DocChip(
                          label: r.fulfillableMilli >= r.qtyBackorderMilli
                              ? 'Oui, tout'
                              : 'Oui, ${fmtQty(r.fulfillableMilli)}',
                          bg: T.mintTint,
                          fg: T.mintDark),
                      if (_canMessage) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                visualDensity: VisualDensity.compact),
                            onPressed: () => _tellClient(r),
                            icon: const Icon(Icons.chat_outlined, size: 15),
                            label: const Text('Prévenir', overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ],
                    ]),
            ),
          ],
        ),
      ),
    ]);
  }
}
