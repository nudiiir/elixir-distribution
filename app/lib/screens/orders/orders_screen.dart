import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/commands.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../../widgets/doc_list.dart' show DocChip, popToModuleRoot;
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'backorders_view.dart';
import 'order_actions.dart';
import 'order_common.dart';
import 'order_detail_page.dart';
import 'order_form_page.dart';
import 'orders_pdf.dart';

const _prefs = 'orders';

/// Opens an order page inside the current module navigator. Returns true
/// when something changed.
Future<bool> openOrderDetail(BuildContext context, ApiClient api, User user, String orderId) async {
  final r = await Navigator.of(context).push<bool>(MaterialPageRoute(
    builder: (_) => OrderDetailPage(api: api, user: user, orderId: orderId),
  ));
  return r == true;
}

/// « Commandes clients » : board by status, list with filters, backorders.
/// Menu commands: `board` · `list` · `new` · `backorders`.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, required this.api, required this.user, this.command});
  final ApiClient api;
  final User user;
  final ScreenCommand? command;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  ApiClient get api => widget.api;
  User get user => widget.user;
  bool get _canManage => user.isAdmin || user.can('orders.manage');

  String _view = 'board'; // board | list | backorders
  final _search = TextEditingController();
  Timer? _debounce;

  // Filters
  String? _status; // list only
  String? _source;
  String? _repId;
  String? _wilaya;
  String? _routeId;
  int? _priority;
  String? _from;
  String? _to;
  bool _backorderOnly = false;
  bool _showCancelled = false;
  (String, String)? _client; // id, name

  // Reference data
  List<DeliveryRoute> _routes = const [];
  final Map<String, String> _reps = {};

  // Data
  OrderPage? _page;
  bool _loading = true;
  String? _error;
  int _offset = 0;
  static const _limit = 100;
  int _seq = 0;
  int _fulfillable = 0;

  @override
  void initState() {
    super.initState();
    final v = UiPrefs.instance.get<String>(_prefs, 'view');
    if (v == 'list' || v == 'board' || v == 'backorders') _view = v!;
    _showCancelled = UiPrefs.instance.get<bool>(_prefs, 'show_cancelled') ?? false;
    widget.command?.addListener(_onCommand);
    _loadRefs();
    if (widget.command?.value == null) _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    switch (cmd) {
      case 'board':
      case 'list':
      case 'backorders':
        _setView(cmd);
      case 'new':
        _load();
        if (_canManage) _newOrder();
      default:
        _load();
    }
  }

  Future<void> _loadRefs() async {
    try {
      final r = await api.deliveryRoutes();
      if (mounted) setState(() => _routes = r);
    } catch (_) {}
    final staff = await api.staffList();
    if (mounted && staff.isNotEmpty) {
      setState(() {
        for (final s in staff) {
          _reps[s.id] = s.name;
        }
      });
    }
    try {
      final (_, n) = await api.backorders(fulfillable: true);
      if (mounted) setState(() => _fulfillable = n);
    } catch (_) {}
  }

  void _setView(String v) {
    setState(() {
      _view = v;
      _offset = 0;
    });
    UiPrefs.instance.set(_prefs, 'view', v);
    if (v != 'backorders') _load();
  }

  Future<void> _load() async {
    if (_view == 'backorders') return;
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final board = _view == 'board';
      final statuses = board
          ? [
              for (final (k, _) in orderStatuses)
                if (k != 'cancelled' || _showCancelled) k
            ]
          : (_status == null ? const <String>[] : [_status!]);
      final p = await api.orders(
        statuses: statuses,
        partnerId: _client?.$1,
        repUserId: _repId,
        wilaya: _wilaya,
        routeId: _routeId,
        source: _source,
        priority: _priority?.toString(),
        from: _from,
        to: _to,
        backorderOnly: _backorderOnly,
        q: _search.text,
        sortPriority: board,
        limit: board ? 500 : _limit,
        offset: board ? 0 : _offset,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _page = p;
        _loading = false;
        for (final o in p.items) {
          if (o.repUserId != null && o.repName.isNotEmpty) _reps.putIfAbsent(o.repUserId!, () => o.repName);
        }
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de charger les commandes : $e';
      });
    }
  }

  void _apply(VoidCallback f) {
    setState(() {
      f();
      _offset = 0;
    });
    _load();
  }

  Future<void> _newOrder() async {
    final created = await Navigator.of(context).push<CustomerOrder>(MaterialPageRoute(
      builder: (_) => OrderFormPage(api: api, user: user),
    ));
    if (!mounted) return;
    _load();
    if (created != null) {
      await openOrderDetail(context, api, user, created.id);
      if (mounted) _load();
    }
  }

  Future<void> _open(CustomerOrder o) async {
    await openOrderDetail(context, api, user, o.id);
    if (mounted) {
      _load();
      _loadRefs();
    }
  }

  Future<void> _move(CustomerOrder o, String to) async {
    if (!_canManage && !(to == 'validated' && user.can('orders.validate'))) {
      showToast(context, 'Votre rôle ne permet pas de changer cette commande.', kind: ToastKind.warning);
      return;
    }
    final r = await moveOrder(context, api, user, o, to);
    if (r != null && mounted) _load();
  }

  Future<void> _pickClient() async {
    final p = await showPartnerPicker(context, api, kind: 'customer');
    if (p != null) _apply(() => _client = (p.id, p.name));
  }

  Future<bool> _batchPicking(List<CustomerOrder> rows) async {
    final ids = [
      for (final o in rows)
        if (o.status == 'validated' || o.status == 'preparing') o.id
    ];
    if (ids.isEmpty) {
      showToast(context, 'Choisissez des commandes validées ou en préparation.', kind: ToastKind.warning);
      return false;
    }
    try {
      final pl = await api.batchPickingList(ids);
      await printPickingPdf(api, pl, title: 'PRÉPARATION GROUPÉE (${ids.length} commandes)');
    } catch (e) {
      if (mounted) showActionError(context, e);
    }
    return false;
  }

  // ---------------------------------------------------------------- build

  List<ActiveFilter> get _active => [
        if (_client != null) ActiveFilter('Client : ${_client!.$2}', () => _apply(() => _client = null)),
        if (_from != null || _to != null)
          ActiveFilter('Période : ${_from == null ? '…' : frDate(_from)} → ${_to == null ? '…' : frDate(_to)}',
              () => _apply(() {
                    _from = null;
                    _to = null;
                  })),
      ];

  void _clearAll() => _apply(() {
        _status = null;
        _source = null;
        _repId = null;
        _wilaya = null;
        _routeId = null;
        _priority = null;
        _from = null;
        _to = null;
        _client = null;
        _backorderOnly = false;
        _search.clear();
      });

  Widget _toolbar() {
    final wilayas = {...wilayaNames, ...?_page?.items.map((o) => o.wilaya).where((w) => w.isNotEmpty)}.toList()
      ..sort();
    return ListToolbar(
      search: _search,
      searchHint: 'N° de commande, n° web, client, téléphone…',
      onSearchChanged: (_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () => _apply(() {}));
      },
      quickFilters: [
        FilterPill(
            label: 'Urgentes',
            icon: Icons.priority_high_rounded,
            active: _priority == 2,
            onTap: () => _apply(() => _priority = _priority == 2 ? null : 2)),
        FilterPill(
            label: 'Avec reliquat',
            icon: Icons.call_split_rounded,
            active: _backorderOnly,
            onTap: () => _apply(() => _backorderOnly = !_backorderOnly)),
        FilterPill(
            label: _client == null ? 'Choisir un client' : 'Client : ${_client!.$2}',
            icon: Icons.person_search_outlined,
            active: _client != null,
            onTap: _client == null ? _pickClient : () => _apply(() => _client = null)),
        if (_view == 'board')
          FilterPill(
              label: 'Afficher les annulées',
              icon: Icons.block_rounded,
              active: _showCancelled,
              onTap: () {
                _showCancelled = !_showCancelled;
                UiPrefs.instance.set(_prefs, 'show_cancelled', _showCancelled);
                _apply(() {});
              }),
      ],
      panel: Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
        if (_view == 'list')
          FilterField<String>(
              label: 'Statut',
              value: _status,
              width: 180,
              options: orderStatuses,
              onChanged: (v) => _apply(() => _status = v)),
        FilterField<String>(
            label: 'Origine', value: _source, width: 170, options: orderSources, onChanged: (v) => _apply(() => _source = v)),
        FilterField<String>(
            label: 'Commercial',
            value: _repId,
            width: 190,
            options: [for (final e in _reps.entries) (e.key, e.value)],
            onChanged: (v) => _apply(() => _repId = v)),
        FilterField<String>(
            label: 'Wilaya',
            value: _wilaya,
            allLabel: 'Toutes',
            width: 190,
            options: [for (final w in wilayas) (w, w)],
            onChanged: (v) => _apply(() => _wilaya = v)),
        FilterField<String>(
            label: 'Tournée',
            value: _routeId,
            allLabel: 'Toutes',
            width: 190,
            options: [for (final r in _routes) (r.id, r.name)],
            onChanged: (v) => _apply(() => _routeId = v)),
        FilterField<int>(
            label: 'Priorité',
            value: _priority,
            allLabel: 'Toutes',
            width: 150,
            options: orderPriorities,
            onChanged: (v) => _apply(() => _priority = v)),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const MicroLabel('Du'),
          const SizedBox(height: 5),
          DateField(value: _from, width: 170, hint: 'Début', onChanged: (v) => _apply(() => _from = v)),
        ]),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const MicroLabel('Au'),
          const SizedBox(height: 5),
          DateField(value: _to, width: 170, hint: 'Fin', onChanged: (v) => _apply(() => _to = v)),
        ]),
      ]),
      active: _active,
      onClearAll: _clearAll,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Commandes clients',
          subtitle: p == null || _view == 'backorders' ? null : '${p.total} commande${p.total > 1 ? 's' : ''}',
          primaryLabel: _canManage ? 'Nouvelle commande' : null,
          primaryIcon: Icons.add_shopping_cart_rounded,
          onPrimary: _newOrder,
          more: [
            MenuEntry('Actualiser', Icons.refresh_rounded, () {
              _load();
              _loadRefs();
            }),
          ],
        ),
        const SizedBox(height: 14),
        Row(children: [
          FilterPill(
              label: 'Tableau', icon: Icons.view_kanban_outlined, active: _view == 'board', onTap: () => _setView('board')),
          FilterPill(label: 'Liste', icon: Icons.list_alt_rounded, active: _view == 'list', onTap: () => _setView('list')),
          FilterPill(
              label: 'Reliquats',
              icon: Icons.call_split_rounded,
              count: _fulfillable,
              active: _view == 'backorders',
              onTap: () => _setView('backorders')),
          if (_fulfillable > 0 && _view != 'backorders')
            Text('  $_fulfillable reliquat${_fulfillable > 1 ? 's' : ''} peuvent être servis maintenant',
                style: T.small.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),
        if (_view == 'backorders')
          Expanded(
            child: BackordersView(
              api: api,
              canManage: _canManage,
              onOpenOrder: (id) async {
                await openOrderDetail(context, api, user, id);
                _loadRefs();
              },
              onChanged: _loadRefs,
            ),
          )
        else ...[
          _toolbar(),
          const SizedBox(height: 12),
          Expanded(child: _view == 'board' ? _board() : _list()),
        ],
      ]),
    );
  }

  // ---------------------------------------------------------------- board

  Widget _board() {
    final p = _page;
    if (p == null) {
      return _error != null
          ? EmptyState(icon: Icons.cloud_off_rounded, text: _error!, actions: [('Réessayer', _load)])
          : const Center(child: CircularProgressIndicator(color: T.mint));
    }
    final cols = [
      for (final (k, l) in orderStatuses)
        if (k != 'cancelled' || _showCancelled) (k, l)
    ];
    return Column(children: [
      if (_loading) const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.mintTint),
      Expanded(
        child: Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (k, l) in cols)
                _BoardColumn(
                  status: k,
                  label: l,
                  count: p.counts[k] ?? 0,
                  orders: [for (final o in p.items) if (o.status == k) o],
                  onOpen: _open,
                  onDrop: _move,
                  onSeeAll: () {
                    setState(() => _status = k);
                    _setView('list');
                  },
                ),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('Glissez une carte vers une autre colonne pour faire avancer la commande (une confirmation est demandée).',
            style: T.small),
      ),
    ]);
  }

  // ---------------------------------------------------------------- list

  Widget _list() {
    final p = _page;
    final total = p?.total ?? 0;
    return Column(children: [
      if (total > _limit)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Text('Commandes ${_offset + 1}–${(_offset + _limit).clamp(0, total)} sur $total',
                style: T.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _offset == 0
                  ? null
                  : () {
                      setState(() => _offset = (_offset - _limit).clamp(0, total));
                      _load();
                    },
              icon: const Icon(Icons.chevron_left_rounded, size: 18),
              label: const Text('Précédentes'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: _offset + _limit >= total
                  ? null
                  : () {
                      setState(() => _offset += _limit);
                      _load();
                    },
              icon: const Icon(Icons.chevron_right_rounded, size: 18),
              label: const Text('Suivantes'),
            ),
          ]),
        ),
      Expanded(
        child: DataListView<CustomerOrder>(
          items: p?.items ?? const [],
          prefsKey: 'orders_list',
          loading: _loading,
          error: _error,
          onRetry: _load,
          rowId: (o) => o.id,
          onTap: _open,
          exportTitle: 'Commandes clients',
          exportBaseName: 'commandes-clients',
          rowMenu: (o) => [
            RowAction('Ouvrir', Icons.open_in_new_rounded, _open),
            if (_canManage || user.can('orders.validate'))
              for (final to in boardMoves[o.status] ?? const <String>{})
                RowAction(_moveLabel(to), _moveIcon(to), (o) => _move(o, to), danger: to == 'cancelled'),
            RowAction('Imprimer le bon de commande', Icons.print_outlined, (o) async {
              try {
                await printOrderPdf(api, await api.order(o.id));
              } catch (e) {
                if (mounted) showActionError(context, e);
              }
            }),
          ],
          bulkActions: [
            BulkAction('Préparation groupée (PDF)', Icons.playlist_add_check_rounded, _batchPicking),
          ],
          aggregates: (rows) => [
            ('Commandes', '${rows.length}'),
            ('Total TTC', fmtDA(rows.fold(0, (s, o) => s + o.totalTTC))),
          ],
          empty: EmptyState(
            icon: Icons.shopping_basket_outlined,
            text: 'Aucune commande ne correspond.',
            actions: [
              ('Effacer les filtres', _clearAll),
              if (_canManage) ('Nouvelle commande', _newOrder),
            ],
          ),
          columns: [
            ColumnSpec(
              id: 'number',
              label: 'N°',
              width: 150,
              hideable: false,
              sortKey: (o) => o.number,
              exportValue: (o) => o.number,
              cell: (_, o) => Row(children: [
                SourceIcon(o.source, size: 15),
                const SizedBox(width: 6),
                Flexible(child: Text(o.number, style: T.monoBody, overflow: TextOverflow.ellipsis)),
              ]),
            ),
            ColumnSpec(
              id: 'date',
              label: 'Date',
              width: 100,
              sortKey: (o) => o.orderDate,
              exportValue: (o) => o.orderDate,
              cell: (_, o) => Text(frDate(o.orderDate), style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'client',
              label: 'Client',
              flex: 3,
              hideable: false,
              sortKey: (o) => o.partnerName.toLowerCase(),
              exportValue: (o) => o.partnerName,
              cell: (_, o) => Text(o.partnerName, style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'status',
              label: 'Statut',
              width: 150,
              sortKey: (o) => orderStatuses.indexWhere((s) => s.$1 == o.status),
              exportValue: (o) => orderStatusLabel(o.status),
              cell: (_, o) => OrderStatusChip(o.status),
            ),
            ColumnSpec(
              id: 'flags',
              label: 'Repères',
              width: 170,
              cell: (_, o) => Wrap(spacing: 4, children: [
                PriorityBadge(o.priority),
                if (o.isPartial) const DocChip(label: 'Partielle', bg: T.warnTint, fg: T.warnDark),
                if (o.hasBackorder) const DocChip(label: 'Reliquat', bg: T.cream, fg: T.muted),
              ]),
            ),
            ColumnSpec(
              id: 'rep',
              label: 'Commercial',
              flex: 2,
              visibleByDefault: false,
              sortKey: (o) => o.repName,
              exportValue: (o) => o.repName,
              cell: (_, o) => Text(o.repName.isEmpty ? '—' : o.repName, style: T.small),
            ),
            ColumnSpec(
              id: 'wilaya',
              label: 'Wilaya',
              flex: 2,
              sortKey: (o) => o.wilaya,
              exportValue: (o) => o.wilaya,
              cell: (_, o) => Text(o.wilaya.isEmpty ? '—' : o.wilaya, style: T.small, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'route',
              label: 'Tournée',
              flex: 2,
              visibleByDefault: false,
              sortKey: (o) => o.routeName,
              exportValue: (o) => o.routeName,
              cell: (_, o) => Text(o.routeName.isEmpty ? '—' : o.routeName, style: T.small),
            ),
            ColumnSpec(
              id: 'total',
              label: 'Total TTC',
              width: 140,
              numeric: true,
              sortKey: (o) => o.totalTTC,
              exportValue: (o) => o.totalTTC / 100,
              cell: (_, o) => Text(fmtDA(o.totalTTC), style: T.monoBody),
            ),
          ],
        ),
      ),
    ]);
  }
}

String _moveLabel(String to) => switch (to) {
      'validated' => 'Valider',
      'new' => 'Rouvrir',
      'preparing' => 'Démarrer la préparation',
      'ready' => 'Marquer prête',
      'shipping' => 'Expédier',
      'delivered' => 'Livrer',
      'invoiced' => 'Facturer',
      'cancelled' => 'Annuler la commande',
      _ => to,
    };

IconData _moveIcon(String to) => switch (to) {
      'validated' => Icons.check_circle_outline_rounded,
      'new' => Icons.undo_rounded,
      'preparing' => Icons.inventory_outlined,
      'ready' => Icons.inventory_2_outlined,
      'shipping' => Icons.local_shipping_outlined,
      'delivered' => Icons.where_to_vote_outlined,
      'invoiced' => Icons.receipt_long_outlined,
      'cancelled' => Icons.block_rounded,
      _ => Icons.arrow_forward_rounded,
    };

class _BoardColumn extends StatelessWidget {
  const _BoardColumn({
    required this.status,
    required this.label,
    required this.count,
    required this.orders,
    required this.onOpen,
    required this.onDrop,
    required this.onSeeAll,
  });
  final String status;
  final String label;
  final int count;
  final List<CustomerOrder> orders;
  final void Function(CustomerOrder) onOpen;
  final void Function(CustomerOrder, String) onDrop;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = orderStatusColors(status);
    return DragTarget<CustomerOrder>(
      onWillAcceptWithDetails: (d) => canMove(d.data.status, status),
      onAcceptWithDetails: (d) => onDrop(d.data, status),
      builder: (context, candidates, rejected) {
        final allowed = candidates.isNotEmpty;
        final hovering = allowed ||
            rejected.any((r) => r is CustomerOrder && r.status != status);
        return Container(
          width: 286,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: hovering ? (allowed ? T.mintTint : T.dangerTint) : T.cream.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(T.rCard),
            border: Border.all(color: hovering ? (allowed ? T.mint : T.danger) : T.border),
          ),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: T.h2.copyWith(fontSize: 15))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
                  child: Text('$count', style: T.label.copyWith(color: fg)),
                ),
              ]),
            ),
            if (hovering)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(allowed ? 'Déposer pour : $label' : 'Changement impossible ici',
                    style: T.small.copyWith(color: allowed ? T.mintDark : T.dangerDark, fontWeight: FontWeight.w700)),
              ),
            Expanded(
              child: orders.isEmpty
                  ? Center(child: Text('Aucune commande', style: T.small))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: orders.length + (count > orders.length ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == orders.length) {
                          return TextButton(onPressed: onSeeAll, child: Text('Voir les ${count - orders.length} autres'));
                        }
                        final o = orders[i];
                        final card = _OrderCard(order: o, onTap: () => onOpen(o));
                        return Draggable<CustomerOrder>(
                          data: o,
                          feedback: Material(
                            color: Colors.transparent,
                            child: SizedBox(width: 270, child: Opacity(opacity: 0.92, child: card)),
                          ),
                          childWhenDragging: Opacity(opacity: 0.35, child: card),
                          child: card,
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.onTap});
  final CustomerOrder order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = order;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(T.rInner),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border(
                left: BorderSide(
                    color: o.priority >= 2 ? T.danger : (o.priority == 1 ? T.warn : T.border), width: 3),
                top: const BorderSide(color: T.border),
                right: const BorderSide(color: T.border),
                bottom: const BorderSide(color: T.border),
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SourceIcon(o.source, size: 15),
                const SizedBox(width: 6),
                Expanded(child: Text(o.number, style: T.monoSmall.copyWith(color: T.ink))),
                Text(ageText(o.createdAt), style: T.small.copyWith(fontSize: 12)),
              ]),
              const SizedBox(height: 4),
              Text(o.partnerName,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: T.body.copyWith(fontWeight: FontWeight.w700)),
              if (o.wilaya.isNotEmpty || o.routeName.isNotEmpty)
                Text([o.wilaya, o.routeName].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Wrap(spacing: 4, runSpacing: 4, children: [
                    PriorityBadge(o.priority),
                    if (o.isPartial) const DocChip(label: 'Partielle', bg: T.warnTint, fg: T.warnDark),
                    if (o.hasBackorder) const DocChip(label: 'Reliquat', bg: T.cream, fg: T.muted),
                    if (o.paymentMode == 'cod') const DocChip(label: 'À encaisser', bg: T.mintTint, fg: T.mintDark),
                  ]),
                ),
                Text(fmtDA(o.totalTTC), style: T.monoBody.copyWith(fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
