import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/doc_list.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

enum StockDocsMode { adjustments, transfers }

/// « Ajustements » (ajustements + inventaires) and « Transferts » lists.
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

  /// « Faire un inventaire » / « Nouveau transfert » (empty state).
  final VoidCallback onPrimary;

  /// Opens a saved (draft) inventory session.
  final void Function(String docId)? onResumeInventory;
  final Map<String, String> company;

  @override
  State<StockDocsTab> createState() => StockDocsTabState();
}

class StockDocsTabState extends State<StockDocsTab> {
  static const _reasons = ['casse', 'vol', 'péremption', 'inventaire'];

  bool get _adj => widget.mode == StockDocsMode.adjustments;
  String get _p => _adj ? 'stock_adjustments' : 'stock_transfers';

  final _search = TextEditingController();
  late StockPeriod _period = StockPeriod.load(_p, fallback: 'month');
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
        types: _adj ? const ['STOCK_ADJUSTMENT', 'INVENTORY_COUNT'] : const ['STOCK_TRANSFER'],
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

  String _reasonOf(StockDoc d) =>
      d.docType == 'INVENTORY_COUNT' ? 'inventaire' : (d.reason ?? '').trim().toLowerCase();

  List<StockDoc> get _visible {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final d in _docs)
        if ((!_drafts || d.status == 'draft') &&
            (_reason == null || _reasonOf(d) == _reason) &&
            (q.isEmpty ||
                (d.number ?? '').toLowerCase().contains(q) ||
                (d.reason ?? '').toLowerCase().contains(q) ||
                (d.notes ?? '').toLowerCase().contains(q)))
          d
    ];
  }

  Future<void> _open(StockDoc d) async {
    if (d.docType == 'INVENTORY_COUNT' && d.status == 'draft' && widget.onResumeInventory != null) {
      widget.onResumeInventory!(d.id);
      return;
    }
    final changed = await openStockDocument(context, widget.api, d.id);
    if (changed) reload();
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final draftCount = _docs.where((d) => d.status == 'draft').length;
    final multi = widget.warehouses.length > 1;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        search: _search,
        searchHint: _adj ? 'N°, motif, note…' : 'N°, note…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          PeriodButton(
            period: _period,
            onChanged: (p) {
              setState(() => _period = p);
              p.save(_p);
              reload();
            },
          ),
          if (_adj)
            for (final r in _reasons)
              FilterPill(
                label: _cap(r),
                active: _reason == r,
                count: _docs.where((d) => _reasonOf(d) == r).length,
                onTap: () {
                  setState(() => _reason = _reason == r ? null : r);
                  UiPrefs.instance.set(_p, 'reason', _reason);
                },
              ),
          FilterPill(
            label: 'Brouillons',
            icon: Icons.edit_note_rounded,
            active: _drafts,
            count: draftCount,
            onTap: () {
              setState(() => _drafts = !_drafts);
              UiPrefs.instance.set(_p, 'drafts', _drafts);
            },
          ),
        ],
        active: [
          if (_reason != null)
            ActiveFilter('Motif : $_reason', () {
              setState(() => _reason = null);
              UiPrefs.instance.set(_p, 'reason', null);
            }),
          if (_drafts)
            ActiveFilter('Brouillons', () {
              setState(() => _drafts = false);
              UiPrefs.instance.set(_p, 'drafts', false);
            }),
        ],
        onClearAll: () {
          setState(() {
            _reason = null;
            _drafts = false;
            _search.clear();
          });
          UiPrefs.instance.set(_p, 'reason', null);
          UiPrefs.instance.set(_p, 'drafts', false);
        },
        trailing: [
          DepotDropdown(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
          ),
          IconButton(
            tooltip: 'Actualiser',
            onPressed: reload,
            icon: const Icon(Icons.refresh_rounded, size: 18, color: T.muted),
          ),
        ],
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
          exportTitle: '${_adj ? 'Ajustements de stock' : 'Transferts de stock'} — ${_period.label}',
          exportBaseName: _adj ? 'ajustements' : 'transferts',
          company: widget.company,
          onTap: _open,
          rowMenu: (d) => [
            RowAction(
                d.docType == 'INVENTORY_COUNT' && d.status == 'draft'
                    ? 'Reprendre l’inventaire'
                    : 'Ouvrir',
                Icons.open_in_new_rounded,
                _open),
          ],
          empty: EmptyState(
            icon: _adj ? Icons.tune_rounded : Icons.compare_arrows_rounded,
            text: _adj
                ? 'Aucun ajustement ni inventaire sur cette période.'
                : 'Aucun transfert sur cette période.',
            actions: [
              if (_period.key != 'all')
                ('Toute la période', () {
                  setState(() => _period = StockPeriod.preset('all'));
                  _period.save(_p);
                  reload();
                }),
              (_adj ? 'Faire un inventaire' : 'Nouveau transfert', widget.onPrimary),
            ],
          ),
          aggregates: (sel) => [
            ('Documents', '${sel.length}'),
            if (widget.viewCost)
              ('Valeur nette', fmtDA(sel.fold<int>(0, (s, d) => s + d.value))),
          ],
          columns: [
            ColumnSpec(
              id: 'date',
              label: 'Date',
              width: 100,
              hideable: false,
              sortKey: (d) => '${d.docDate}${d.createdAt}',
              exportValue: (d) => frDate(d.docDate),
              cell: (context, d) => Text(frDate(d.docDate), style: T.monoSmall),
            ),
            if (_adj)
              ColumnSpec(
                id: 'type',
                label: 'Type',
                width: 105,
                sortKey: (d) => d.docType,
                exportValue: (d) => docLabel(d.docType),
                cell: (context, d) => Text(docLabel(d.docType), style: T.small),
              ),
            ColumnSpec(
              id: 'number',
              label: 'N°',
              width: 150,
              hideable: false,
              sortKey: (d) => d.number ?? '',
              exportValue: (d) => d.number ?? '',
              cell: (context, d) => Text(d.number ?? 'brouillon',
                  style: T.monoSmall.copyWith(color: d.number == null ? T.faint : T.ink)),
            ),
            if (_adj && multi)
              ColumnSpec(
                id: 'depot',
                label: 'Dépôt',
                flex: 2,
                sortKey: (d) => d.warehouseName ?? '',
                exportValue: (d) => d.warehouseName ?? '',
                cell: (context, d) => Text(d.warehouseName ?? '—',
                    style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (!_adj) ...[
              ColumnSpec(
                id: 'from',
                label: 'De',
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
                  const Icon(Icons.arrow_forward_rounded, size: 13, color: T.faint),
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
                cell: (context, d) => Text(_cap(_reasonOf(d)).isEmpty ? '—' : _cap(_reasonOf(d)),
                    style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ColumnSpec(
              id: 'notes',
              label: 'Note',
              flex: 3,
              visibleByDefault: false,
              sortKey: (d) => d.notes ?? '',
              exportValue: (d) => d.notes ?? '',
              cell: (context, d) => Text(d.notes ?? '',
                  style: T.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'lines',
              label: 'Lignes',
              width: 70,
              numeric: true,
              sortKey: (d) => d.lineCount,
              exportValue: (d) => d.lineCount,
              cell: (context, d) => Text('${d.lineCount}', style: T.monoSmall),
            ),
            if (_adj) ...[
              ColumnSpec(
                id: 'in',
                label: 'Entrées',
                width: 85,
                numeric: true,
                sortKey: (d) => d.inMilli,
                exportValue: (d) => d.inMilli / 1000,
                cell: (context, d) => Text(d.inMilli > 0 ? '+${fmtQty(d.inMilli)}' : '',
                    style: T.monoBody.copyWith(color: T.mintDark)),
              ),
              ColumnSpec(
                id: 'out',
                label: 'Sorties',
                width: 85,
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
                width: 90,
                numeric: true,
                sortKey: (d) => d.outMilli,
                exportValue: (d) => d.outMilli / 1000,
                cell: (context, d) => Text(d.outMilli > 0 ? fmtQty(d.outMilli) : '—',
                    style: T.monoBody),
              ),
            if (widget.viewCost)
              ColumnSpec(
                id: 'value',
                label: 'Valeur',
                width: 120,
                numeric: true,
                sortKey: (d) => _adj ? d.value : -d.value,
                exportValue: (d) => (_adj ? d.value : -d.value) / 100,
                cell: (context, d) => Text(
                    d.status == 'posted' ? fmtDA(_adj ? d.value : -d.value) : '—',
                    style: T.monoBody.copyWith(
                        color: _adj && d.value < 0 ? T.dangerDark : T.ink)),
              ),
            ColumnSpec(
              id: 'status',
              label: 'Statut',
              width: 95,
              sortKey: (d) => d.status,
              exportValue: (d) => switch (d.status) {
                'posted' => 'validé',
                'cancelled' => 'annulé',
                _ => 'brouillon',
              },
              cell: (context, d) => StatusChip(status: d.status),
            ),
          ],
        ),
      ),
    ]);
  }
}
