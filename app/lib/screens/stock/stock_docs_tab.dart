import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_list.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'inventory_page.dart';
import 'stock_common.dart';

enum StockDocsMode { adjustments, inventories, transfers }

/// « Ajustements », « Inventaire » and « Transferts » lists.
class StockDocsTab extends StatefulWidget {
  const StockDocsTab({
    super.key,
    required this.mode,
    required this.api,
    required this.viewCost,
    required this.warehouses,
    required this.warehouseId,
    required this.onWarehouse,
    required this.onPrimary,
    this.onResumeInventory,
    this.company = const {},
  });

  final StockDocsMode mode;
  final ApiClient api;
  final bool viewCost;
  final List<Warehouse> warehouses;
  final String? warehouseId;
  final ValueChanged<String?> onWarehouse;

  /// « Nouvel ajustement » / « Nouvel inventaire » / « Nouveau transfert ».
  final VoidCallback onPrimary;

  /// Opens a saved (draft) inventory session.
  final void Function(String docId)? onResumeInventory;
  final Map<String, String> company;

  @override
  State<StockDocsTab> createState() => StockDocsTabState();
}

class StockDocsTabState extends State<StockDocsTab> {
  static const _reasons = ['casse', 'vol', 'péremption'];

  StockDocsMode get _mode => widget.mode;
  bool get _adj => _mode == StockDocsMode.adjustments;
  bool get _inv => _mode == StockDocsMode.inventories;
  String get _p => switch (_mode) {
        StockDocsMode.adjustments => 'stock_adjustments',
        StockDocsMode.inventories => 'stock_inventories',
        StockDocsMode.transfers => 'stock_transfers',
      };

  String get _primaryLabel => switch (_mode) {
        StockDocsMode.adjustments => 'Nouvel ajustement',
        StockDocsMode.inventories => 'Nouvel inventaire',
        StockDocsMode.transfers => 'Nouveau transfert',
      };

  final _search = TextEditingController();
  late StockPeriod _period = StockPeriod.load(_p, fallback: _inv ? 'year' : 'month');
  late String? _reason = UiPrefs.instance.get<String>(_p, 'reason');
  late bool _drafts = UiPrefs.instance.get<bool>(_p, 'drafts') ?? false;

  List<StockDoc> _docs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant StockDocsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.warehouseId != widget.warehouseId) reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final docs = await widget.api.stockDocuments(
        types: switch (_mode) {
          StockDocsMode.adjustments => const ['STOCK_ADJUSTMENT'],
          StockDocsMode.inventories => const ['INVENTORY_COUNT'],
          StockDocsMode.transfers => const ['STOCK_TRANSFER'],
        },
        from: _period.fromIso,
        to: _period.toIso,
        warehouseId: widget.warehouseId,
      );
      if (mounted) {
        setState(() {
          _docs = docs;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Documents indisponibles : $e';
          _loading = false;
        });
      }
    }
  }

  String _reasonOf(StockDoc d) => (d.reason ?? '').trim().toLowerCase();

  List<StockDoc> get _visible {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final d in _docs)
        if ((!_drafts || d.status == 'draft') &&
            (!_adj || _reason == null || _reasonOf(d) == _reason) &&
            (q.isEmpty ||
                (d.number ?? '').toLowerCase().contains(q) ||
                (d.reason ?? '').toLowerCase().contains(q) ||
                (d.notes ?? '').toLowerCase().contains(q)))
          d
    ];
  }

  Future<void> _open(StockDoc d) async {
    if (d.docType == 'INVENTORY_COUNT') {
      if (d.status == 'draft' && widget.onResumeInventory != null) {
        widget.onResumeInventory!(d.id);
        return;
      }
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => InventoryDetailPage(api: widget.api, doc: d, viewCost: widget.viewCost),
      ));
      if (changed == true) reload();
      return;
    }
    final changed = await openStockDocument(context, widget.api, d.id);
    if (changed) reload();
  }

  void _setPeriod(StockPeriod p) {
    setState(() => _period = p);
    p.save(_p);
    reload();
  }

  void _clearAll() {
    setState(() {
      _reason = null;
      _drafts = false;
      _search.clear();
    });
    UiPrefs.instance.set(_p, 'reason', null);
    UiPrefs.instance.set(_p, 'drafts', false);
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final draftCount = _docs.where((d) => d.status == 'draft').length;
    final multi = widget.warehouses.length > 1;
    final reasons = {
      ..._reasons,
      for (final d in _docs)
        if (_reasonOf(d).isNotEmpty) _reasonOf(d)
    }.toList();
    final depot = depotFilter(
      warehouses: widget.warehouses,
      value: widget.warehouseId,
      onChanged: widget.onWarehouse,
      label: _mode == StockDocsMode.transfers ? 'Dépôt (départ ou arrivée)' : 'Dépôt',
    );
    final anyFilter = _reason != null || _drafts || _search.text.trim().isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        search: _search,
        searchHint: _adj ? 'N°, motif, note…' : 'N°, note…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          FilterPill(
            label: _inv ? 'En cours (non validés)' : 'Brouillons',
            icon: Icons.edit_note_rounded,
            active: _drafts,
            count: draftCount,
            onTap: () {
              setState(() => _drafts = !_drafts);
              UiPrefs.instance.set(_p, 'drafts', _drafts);
            },
          ),
        ],
        panel: FilterPanel(fields: [
          ?depot,
          periodFilter(context, period: _period, onChanged: _setPeriod),
          if (_adj)
            FilterField<String>(
              label: 'Motif',
              value: reasons.contains(_reason) ? _reason : null,
              options: [for (final r in reasons) (r, _cap(r))],
              onChanged: (v) {
                setState(() => _reason = v);
                UiPrefs.instance.set(_p, 'reason', v);
              },
            ),
        ]),
        active: [
          if (_reason != null)
            ActiveFilter('Motif : $_reason', () {
              setState(() => _reason = null);
              UiPrefs.instance.set(_p, 'reason', null);
            }),
          if (_drafts)
            ActiveFilter(_inv ? 'En cours' : 'Brouillons', () {
              setState(() => _drafts = false);
              UiPrefs.instance.set(_p, 'drafts', false);
            }),
        ],
        onClearAll: _clearAll,
        trailing: [RefreshButton(onPressed: reload)],
      ),
      const SizedBox(height: 12),
      Expanded(
        child: DataListView<StockDoc>(
          prefsKey: _p,
          items: rows,
          loading: _loading,
          error: _error,
          onRetry: reload,
          rowId: (d) => d.id,
          initialSortColumn: 0,
          initialAscending: false,
          exportTitle: '${switch (_mode) {
            StockDocsMode.adjustments => 'Ajustements de stock',
            StockDocsMode.inventories => 'Inventaires',
            StockDocsMode.transfers => 'Transferts de stock',
          }} — ${_period.label}',
          exportBaseName: _p.replaceFirst('stock_', ''),
          company: widget.company,
          onTap: _open,
          rowMenu: (d) => [
            RowAction(
                d.docType == 'INVENTORY_COUNT' && d.status == 'draft'
                    ? 'Reprendre le comptage'
                    : 'Ouvrir',
                Icons.open_in_new_rounded,
                _open),
            if (d.docType == 'INVENTORY_COUNT' && d.status != 'draft')
              RowAction('Document complet (imprimer, annuler)', Icons.description_outlined,
                  (d) async {
                final changed = await openStockDocument(context, widget.api, d.id);
                if (changed) reload();
              }),
          ],
          empty: anyFilter
              ? EmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  text: 'Aucun document ne correspond à ces filtres.',
                  actions: [('Effacer les filtres', _clearAll), (_primaryLabel, widget.onPrimary)])
              : EmptyState(
                  icon: switch (_mode) {
                    StockDocsMode.adjustments => Icons.tune_rounded,
                    StockDocsMode.inventories => Icons.fact_check_outlined,
                    StockDocsMode.transfers => Icons.compare_arrows_rounded,
                  },
                  text: switch (_mode) {
                    StockDocsMode.adjustments =>
                      'Aucun ajustement sur cette période.\nUn ajustement corrige le stock d’un produit (casse, vol, péremption…).',
                    StockDocsMode.inventories =>
                      'Aucun inventaire sur cette période.\nUn inventaire compare ce que vous comptez au stock du logiciel.',
                    StockDocsMode.transfers => multi
                        ? 'Aucun transfert sur cette période.'
                        : 'Un transfert déplace du stock d’un dépôt à un autre : créez d’abord un deuxième dépôt dans les paramètres.',
                  },
                  actions: [
                    if (_period.key != 'all')
                      ('Voir toute la période', () => _setPeriod(StockPeriod.preset('all'))),
                    if (_mode != StockDocsMode.transfers || multi)
                      (_primaryLabel, widget.onPrimary),
                  ],
                ),
          aggregates: (sel) => [
            ('Documents', '${sel.length}'),
            if (widget.viewCost)
              (_inv ? 'Différence en DA' : 'Valeur nette',
                  fmtDA(sel.fold<int>(0, (s, d) => s + d.value))),
          ],
          columns: [
            ColumnSpec(
              id: 'date',
              label: 'Date',
              width: 110,
              hideable: false,
              sortKey: (d) => '${d.docDate}${d.createdAt}',
              exportValue: (d) => frDate(d.docDate),
              cell: (context, d) => Text(frDate(d.docDate), style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'number',
              label: 'N°',
              width: 160,
              hideable: false,
              sortKey: (d) => d.number ?? '',
              exportValue: (d) => d.number ?? '',
              cell: (context, d) => Text(
                  d.number ?? (_inv ? 'en cours' : 'brouillon'),
                  style: T.monoSmall.copyWith(color: d.number == null ? T.muted : T.ink)),
            ),
            if (_mode != StockDocsMode.transfers && multi)
              ColumnSpec(
                id: 'depot',
                label: 'Dépôt',
                flex: 2,
                sortKey: (d) => d.warehouseName ?? '',
                exportValue: (d) => d.warehouseName ?? '',
                cell: (context, d) => Text(d.warehouseName ?? '—',
                    style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (_mode == StockDocsMode.transfers) ...[
              ColumnSpec(
                id: 'from',
                label: 'Depuis',
                flex: 2,
                sortKey: (d) => d.warehouseName ?? '',
                exportValue: (d) => d.warehouseName ?? '',
                cell: (context, d) => Text(d.warehouseName ?? '—',
                    style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              ColumnSpec(
                id: 'to',
                label: 'Vers',
                flex: 2,
                sortKey: (d) => d.destWarehouseName ?? '',
                exportValue: (d) => d.destWarehouseName ?? '',
                cell: (context, d) => Row(children: [
                  const Icon(Icons.arrow_forward_rounded, size: 15, color: T.faint),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(d.destWarehouseName ?? '—',
                        style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ]),
              ),
            ],
            if (_adj)
              ColumnSpec(
                id: 'reason',
                label: 'Motif',
                flex: 2,
                sortKey: (d) => _reasonOf(d),
                exportValue: (d) => _reasonOf(d),
                cell: (context, d) => Text(_reasonOf(d).isEmpty ? '—' : _cap(_reasonOf(d)),
                    style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ColumnSpec(
              id: 'notes',
              label: _inv ? 'Ce qui a été compté' : 'Note',
              flex: 3,
              visibleByDefault: _inv,
              sortKey: (d) => d.notes ?? '',
              exportValue: (d) => d.notes ?? '',
              cell: (context, d) => Text(
                  _inv ? (d.notes ?? '').replaceFirst('Inventaire — ', '') : (d.notes ?? ''),
                  style: T.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'lines',
              label: _inv ? 'Produits comptés' : 'Lignes',
              width: _inv ? 140 : 80,
              numeric: true,
              sortKey: (d) => d.lineCount,
              exportValue: (d) => d.lineCount,
              cell: (context, d) => Text('${d.lineCount}', style: T.monoSmall),
            ),
            if (_mode != StockDocsMode.transfers) ...[
              ColumnSpec(
                id: 'in',
                label: _inv ? 'En plus' : 'Entrées',
                width: 95,
                numeric: true,
                sortKey: (d) => d.inMilli,
                exportValue: (d) => d.inMilli / 1000,
                cell: (context, d) => Text(d.inMilli > 0 ? '+${fmtQty(d.inMilli)}' : '',
                    style: T.monoBody.copyWith(color: T.mintDark)),
              ),
              ColumnSpec(
                id: 'out',
                label: _inv ? 'En moins' : 'Sorties',
                width: 95,
                numeric: true,
                sortKey: (d) => d.outMilli,
                exportValue: (d) => d.outMilli / 1000,
                cell: (context, d) => Text(d.outMilli > 0 ? '−${fmtQty(d.outMilli)}' : '',
                    style: T.monoBody.copyWith(color: T.dangerDark)),
              ),
            ] else
              ColumnSpec(
                id: 'qty',
                label: 'Quantité',
                width: 100,
                numeric: true,
                sortKey: (d) => d.outMilli,
                exportValue: (d) => d.outMilli / 1000,
                cell: (context, d) => Text(d.outMilli > 0 ? fmtQty(d.outMilli) : '—',
                    style: T.monoBody),
              ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'value',
                label: _inv ? 'Différence en DA' : 'Valeur',
                width: 150,
                numeric: true,
                sortKey: (d) => _mode == StockDocsMode.transfers ? -d.value : d.value,
                exportValue: (d) => (_mode == StockDocsMode.transfers ? -d.value : d.value) / 100,
                cell: (context, d) => Text(
                    d.status == 'posted'
                        ? fmtDA(_mode == StockDocsMode.transfers ? -d.value : d.value)
                        : '—',
                    style: T.monoBody.copyWith(
                        color: _mode != StockDocsMode.transfers && d.value < 0
                            ? T.dangerDark
                            : T.ink)),
              ),
            ColumnSpec(
              id: 'status',
              label: 'Statut',
              width: 110,
              sortKey: (d) => d.status,
              exportValue: (d) => switch (d.status) {
                'posted' => 'validé',
                'cancelled' => 'annulé',
                _ => _inv ? 'en cours' : 'brouillon',
              },
              cell: (context, d) => StatusChip(status: d.status),
            ),
          ],
        ),
      ),
    ]);
  }
}
