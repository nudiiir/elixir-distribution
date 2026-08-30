import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'ui.dart';

/// Column definition for [DataListView].
class ColumnSpec<R> {
  const ColumnSpec({
    required this.label,
    required this.cell,
    this.flex = 1,
    this.width,
    this.numeric = false,
    this.sortKey,
  });

  final String label;
  final int flex; // used when width == null
  final double? width; // fixed width
  final bool numeric; // end-aligned
  final Widget Function(BuildContext, R) cell;
  final Comparable Function(R)? sortKey; // sortable when non-null
}

/// The list-screen table archetype: sortable header, virtualized hoverable
/// rows, aggregate footer, CSV export hook.
class DataListView<R> extends StatefulWidget {
  const DataListView({
    super.key,
    required this.items,
    required this.columns,
    this.onTap,
    this.aggregates,
    this.empty,
    this.onExport,
    this.initialSortColumn,
    this.initialAscending = true,
  });

  final List<R> items;
  final List<ColumnSpec<R>> columns;
  final void Function(R)? onTap;

  /// Computes footer aggregates from the visible (sorted) rows.
  final List<(String, String)> Function(List<R>)? aggregates;
  final Widget? empty;

  /// Called with rows in the current sort order.
  final Future<void> Function(List<R>)? onExport;
  final int? initialSortColumn;
  final bool initialAscending;

  @override
  State<DataListView<R>> createState() => _DataListViewState<R>();
}

class _DataListViewState<R> extends State<DataListView<R>> {
  int? _sortCol;
  bool _asc = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _sortCol = widget.initialSortColumn;
    _asc = widget.initialAscending;
  }

  List<R> get _sorted {
    final items = [...widget.items];
    final col = _sortCol;
    if (col != null && col < widget.columns.length) {
      final key = widget.columns[col].sortKey;
      if (key != null) {
        items.sort((a, b) => key(a).compareTo(key(b)));
        if (!_asc) {
          return items.reversed.toList();
        }
      }
    }
    return items;
  }

  void _toggleSort(int i) {
    if (widget.columns[i].sortKey == null) return;
    setState(() {
      if (_sortCol == i) {
        _asc = !_asc;
      } else {
        _sortCol = i;
        _asc = true;
      }
    });
  }

  Future<void> _export() async {
    if (widget.onExport == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      await widget.onExport!(_sorted);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _cellBox(ColumnSpec<R> c, Widget child) {
    final aligned = Align(
      alignment: c.numeric
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: child,
    );
    return c.width != null
        ? SizedBox(width: c.width, child: aligned)
        : Expanded(flex: c.flex, child: aligned);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _sorted;
    return Card14(
      padding: EdgeInsets.zero,
      child: Column(children: [
        // ---- Header ----
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 8),
          child: Row(children: [
            for (var i = 0; i < widget.columns.length; i++)
              _cellBox(
                widget.columns[i],
                InkWell(
                  onTap: widget.columns[i].sortKey == null
                      ? null
                      : () => _toggleSort(i),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: MicroLabel(widget.columns[i].label)),
                      if (_sortCol == i)
                        Padding(
                          padding:
                              const EdgeInsetsDirectional.only(start: 3),
                          child: Icon(
                            _asc
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                            size: 11,
                            color: T.mintDeep,
                          ),
                        )
                      else if (widget.columns[i].sortKey != null)
                        const Padding(
                          padding: EdgeInsetsDirectional.only(start: 3),
                          child: Icon(Icons.unfold_more_rounded,
                              size: 11, color: T.ghost),
                        ),
                    ],
                  ),
                ),
              ),
          ]),
        ),
        const Divider(),
        // ---- Rows ----
        Expanded(
          child: rows.isEmpty
              ? (widget.empty ??
                  const EmptyState(
                      icon: Icons.table_rows_outlined, text: 'Aucune donnée'))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, i) => _HoverRow(
                    onTap: widget.onTap == null
                        ? null
                        : () => widget.onTap!(rows[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      child: Row(children: [
                        for (final c in widget.columns)
                          _cellBox(c, c.cell(context, rows[i])),
                      ]),
                    ),
                  ),
                ),
        ),
        // ---- Footer ----
        const Divider(),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
          child: Row(children: [
            MicroLabel('${rows.length} lignes'),
            if (widget.aggregates != null)
              for (final (label, value) in widget.aggregates!(rows)) ...[
                const SizedBox(width: 18),
                MicroLabel(label),
                const SizedBox(width: 6),
                Text(value,
                    style: T.monoBody.copyWith(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ],
            const Spacer(),
            if (widget.onExport != null)
              Tooltip(
                message: 'Exporter en CSV (Excel)',
                child: InkWell(
                  onTap: _exporting ? null : _export,
                  borderRadius: BorderRadius.circular(T.rChip),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          _exporting
                              ? Icons.hourglass_top_rounded
                              : Icons.download_rounded,
                          size: 14,
                          color: T.muted),
                      const SizedBox(width: 5),
                      Text(_exporting ? 'Export…' : 'Exporter',
                          style: T.small.copyWith(fontSize: 11)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? T.bg : Colors.transparent,
          child: widget.child,
        ),
      ),
    );
  }
}
