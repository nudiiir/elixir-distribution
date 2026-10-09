import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import '../crm/crm_common.dart' show errText;
import '../orders/order_common.dart';
import '../orders/orders_screen.dart' show openOrderDetail;
import 'partner_crm_tabs.dart' show FilterPillLite;

/// « Commandes » tab of the client page: the customer orders of this client,
/// newest first. A click opens the order.
class PartnerOrdersTab extends StatefulWidget {
  const PartnerOrdersTab({super.key, required this.api, required this.partnerId, this.onNewOrder});
  final ApiClient api;
  final String partnerId;

  /// Shown as « Nouvelle commande » when not null.
  final VoidCallback? onNewOrder;

  @override
  State<PartnerOrdersTab> createState() => _PartnerOrdersTabState();
}

class _PartnerOrdersTabState extends State<PartnerOrdersTab> {
  static const _pageSize = 30;
  static const _openStatuses = ['new', 'validated', 'preparing', 'ready', 'shipping'];

  bool _openOnly = false;
  int _offset = 0;
  OrderPage? _page;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api.orders(
          partnerId: widget.partnerId,
          statuses: _openOnly ? _openStatuses : const [],
          limit: _pageSize,
          offset: _offset);
      if (mounted) setState(() => _page = p);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(String id) async {
    final user = widget.api.user;
    if (user == null) return;
    final changed = await openOrderDetail(context, widget.api, user, id);
    if (changed && mounted) _load();
  }

  void _filter(bool openOnly) {
    setState(() {
      _openOnly = openOnly;
      _offset = 0;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    final total = p?.total ?? 0;
    Widget head(String s, double? w, {bool end = false}) {
      final t = Text(s, style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return PageSection(
      title: 'Commandes',
      trailing: widget.onNewOrder == null
          ? null
          : TextButton.icon(
              onPressed: widget.onNewOrder,
              icon: const Icon(Icons.add_shopping_cart_rounded, size: 16),
              label: const Text('Nouvelle commande')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(runSpacing: 6, children: [
          FilterPillLite(label: 'Toutes', active: !_openOnly, onTap: () => _filter(false)),
          FilterPillLite(label: 'En cours', active: _openOnly, onTap: () => _filter(true)),
        ]),
        const SizedBox(height: 14),
        if (_loading && p == null)
          const SkeletonBar(width: 260, height: 14)
        else if (_error != null)
          FieldError(_error)
        else if (p == null || p.items.isEmpty)
          EmptyState(
            icon: Icons.shopping_basket_outlined,
            text: _openOnly ? 'Aucune commande en cours pour ce client.' : 'Aucune commande pour ce client.',
            actions: [if (widget.onNewOrder != null) ('Nouvelle commande', widget.onNewOrder!)],
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              head('Date', 120),
              head('Numéro', 170),
              head('Origine', null),
              head('Total TTC', 150, end: true),
              const SizedBox(width: 16),
              head('Statut', 170),
            ]),
          ),
          const Divider(),
          for (final o in p.items) ...[
            InkWell(
              onTap: () => _open(o.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  SizedBox(width: 120, child: Text(frDate(o.orderDate), style: T.monoSmall)),
                  SizedBox(
                      width: 170,
                      child: Text(o.number, overflow: TextOverflow.ellipsis, style: T.monoSmall.copyWith(color: T.ink))),
                  Expanded(
                      child: Row(children: [
                    Icon(orderSourceIcon(o.source), size: 15, color: T.muted),
                    const SizedBox(width: 6),
                    Flexible(child: Text(orderSourceLabel(o.source), style: T.body, overflow: TextOverflow.ellipsis)),
                  ])),
                  SizedBox(
                      width: 150,
                      child: Text(fmtDA(o.totalTTC), textAlign: TextAlign.end, style: T.monoBody)),
                  const SizedBox(width: 16),
                  SizedBox(width: 170, child: Align(alignment: Alignment.centerLeft, child: OrderStatusChip(o.status))),
                ]),
              ),
            ),
            const Divider(height: 1),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Text('${_offset + 1}–${_offset + p.items.length} sur $total', style: T.small),
            const Spacer(),
            OutlinedButton(
              onPressed: _offset == 0 || _loading
                  ? null
                  : () {
                      setState(() => _offset = (_offset - _pageSize).clamp(0, 1 << 30));
                      _load();
                    },
              child: const Text('Précédent'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _offset + p.items.length >= total || _loading
                  ? null
                  : () {
                      setState(() => _offset += _pageSize);
                      _load();
                    },
              child: const Text('Suivant'),
            ),
          ]),
        ],
      ]),
    );
  }
}
