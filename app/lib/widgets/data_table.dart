import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/list_export.dart';
import '../util/prefs.dart';
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
    this.id,
    this.visibleByDefault = true,
    this.hideable = true,
    this.exportValue,
  });

  final String label;
  final int flex; // used when width == null
  final double? width; // fixed width
  final bool numeric; // end-aligned
  final Widget Function(BuildContext, R) cell;
  final Comparable Function(R)? sortKey; // sortable when non-null

  /// Stable key for remembered column choices (defaults to the label).
  final String? id;

  /// Hidden until the user turns it on in « Colonnes ».
  final bool visibleByDefault;

  /// False for the columns that make the row readable (name, number…).
  final bool hideable;

  /// Value written by the generic « Exporter » menu: a [num] (real number in
  /// Excel) or a [String]. Columns without it are not exported.
  final Object? Function(R)? exportValue;

  String get key => id ?? label;
}

/// One entry of a row's ⋯ menu (also shown on right-click).
class RowAction<R> {
  const RowAction(this.label, this.icon, this.onSelected,
      {this.danger = false, this.enabled = true});
  final String label;
  final IconData icon;
  final void Function(R) onSelected;
  final bool danger;
  final bool enabled;
}

/// An action of the bulk bar that appears when rows are selected.
class BulkAction<R> {
  const BulkAction(this.label, this.icon, this.onSelected, {this.danger = false});
  final String label;
  final IconData icon;

  /// Receives the selected rows; return true to clear the selection after.
  final Future<bool> Function(List<R>) onSelected;
  final bool danger;
}

/// Gives the screen the rows exactly as displayed (filtered + sorted), e.g.
/// to step to the next product from a side panel.
class DataListController<R> {
  List<R> rows = const [];
  int? cursor;

  R? next(R current, String Function(R) id) {
    final i = rows.indexWhere((r) => id(r) == id(current));
    return i >= 0 && i + 1 < rows.length ? rows[i + 1] : null;
  }

  R? previous(R current, String Function(R) id) {
    final i = rows.indexWhere((r) => id(r) == id(current));
    return i > 0 ? rows[i - 1] : null;
  }
}

/// The list-screen table archetype shared by every list of the app:
/// sortable header (asc → desc → default), virtualized hoverable rows,
/// optional selection with a bulk bar, ⋯ row menu + right-click, keyboard
/// (↑ ↓ Entrée Espace Ctrl+A Échap), remembered visible columns and
/// density, loading skeleton, error card, aggregate footer that follows the
/// selection, and an « Exporter » menu (Excel, CSV, PDF, Imprimer).
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
    this.prefsKey,
    this.loading = false,
    this.error,
    this.onRetry,
    this.rowId,
    this.rowMenu,
    this.bulkActions = const [],
    this.exportTitle,
    this.exportBaseName,
    this.controller,
    this.highlight,
    this.company = const {},
  });

  final List<R> items;
  final List<ColumnSpec<R>> columns;
  final void Function(R)? onTap;

  /// Computes footer aggregates — from the selection when rows are selected,
  /// otherwise from all displayed rows.
  final List<(String, String)> Function(List<R>)? aggregates;
  final Widget? empty;

  /// Legacy custom export (CSV built by the screen). Used only when no
  /// column declares an [ColumnSpec.exportValue].
  final Future<void> Function(List<R>)? onExport;
  final int? initialSortColumn;
  final bool initialAscending;

  /// Enables remembered columns and density for this screen.
  final String? prefsKey;

  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  /// Needed for selection and keyboard navigation.
  final String Function(R)? rowId;
  final List<RowAction<R>> Function(R)? rowMenu;

  /// Non-empty + [rowId] = checkboxes and the bulk bar.
  final List<BulkAction<R>> bulkActions;

  final String? exportTitle;
  final String? exportBaseName;
  final DataListController<R>? controller;

  /// Marks the row currently open in a side panel.
  final bool Function(R)? highlight;
  final Map<String, String> company;

  @override
  State<DataListView<R>> createState() => _DataListViewState<R>();
}

class _DataListViewState<R> extends State<DataListView<R>> {
  int? _sortCol;
  bool _asc = true;
  bool _exporting = false;
  bool _compact = false;
  int _page = 0;
  int _pageSize = 50; // 0 = tout afficher
  Set<String> _hidden = {};
  final Set<String> _selected = {};
  int? _cursor;
  final _focus = FocusNode(debugLabel: 'DataListView');
  final _scroll = ScrollController();

  bool get _selectable => widget.rowId != null && widget.bulkActions.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _sortCol = widget.initialSortColumn;
    _asc = widget.initialAscending;
    _hidden = {
      for (final c in widget.columns)
        if (!c.visibleByDefault) c.key,
    };
    final k = widget.prefsKey;
    if (k != null) {
      final saved = UiPrefs.instance.getList(k, 'hidden_columns');
      if (saved != null) {
        _hidden = saved.toSet()
          ..removeWhere((key) => widget.columns
              .any((c) => c.key == key && !c.hideable));
      }
      _compact = UiPrefs.instance.get<bool>(k, 'compact') ?? false;
      _pageSize = UiPrefs.instance.get<int>(k, 'page_size') ?? 50;
      final sortKey = UiPrefs.instance.get<String>(k, 'sort');
      if (sortKey != null) {
        final i = widget.columns.indexWhere((c) => c.key == sortKey);
        if (i >= 0) {
          _sortCol = i;
          _asc = UiPrefs.instance.get<bool>(k, 'asc') ?? true;
        }
      }
    }
  }

  @override
  void didUpdateWidget(covariant DataListView<R> old) {
    super.didUpdateWidget(old);
    // A new search / filter result starts again on page 1.
    if (old.items.length != widget.items.length) _page = 0;
    if (widget.rowId != null && _selected.isNotEmpty) {
      final ids = {for (final r in widget.items) widget.rowId!(r)};
      _selected.removeWhere((id) => !ids.contains(id));
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ColumnSpec<R>> get _visibleCols => [
        for (final c in widget.columns)
          if (!_hidden.contains(c.key)) c,
      ];

  List<R> get _sorted {
    final items = [...widget.items];
    final col = _sortCol;
    if (col != null && col < widget.columns.length) {
      final key = widget.columns[col].sortKey;
      if (key != null) {
        items.sort((a, b) => key(a).compareTo(key(b)));
        if (!_asc) return items.reversed.toList();
      }
    }
    return items;
  }

  void _toggleSort(ColumnSpec<R> c) {
    if (c.sortKey == null) return;
    final i = widget.columns.indexOf(c);
    setState(() {
      if (_sortCol != i) {
        _sortCol = i;
        _asc = true;
      } else if (_asc) {
        _asc = false;
      } else {
        // third click: back to the screen's default order
        _sortCol = widget.initialSortColumn;
        _asc = widget.initialAscending;
      }
    });
    final k = widget.prefsKey;
    if (k != null) {
      final sc = _sortCol;
      UiPrefs.instance.set(k, 'sort', sc == null ? null : widget.columns[sc].key);
      UiPrefs.instance.set(k, 'asc', _asc);
    }
  }

  void _setHidden(String key, bool hidden) {
    setState(() => hidden ? _hidden.add(key) : _hidden.remove(key));
    if (widget.prefsKey != null) {
      UiPrefs.instance.set(widget.prefsKey!, 'hidden_columns', _hidden.toList());
    }
  }

  void _setCompact(bool v) {
    setState(() => _compact = v);
    if (widget.prefsKey != null) {
      UiPrefs.instance.set(widget.prefsKey!, 'compact', v);
    }
  }

  List<R> _selectedRows(List<R> rows) => widget.rowId == null
      ? const []
      : [for (final r in rows) if (_selected.contains(widget.rowId!(r))) r];

  bool get _genericExport => widget.columns.any((c) => c.exportValue != null);

  Future<void> _export(ExportFormat f, List<R> rows) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final sel = _selectedRows(rows);
      final source = sel.isNotEmpty ? sel : rows;
      final cols = [
        for (final c in _visibleCols)
          if (c.exportValue != null) c,
      ];
      final table = ExportTable(
        title: widget.exportTitle ?? 'Export',
        baseName: widget.exportBaseName ?? 'export',
        headers: [for (final c in cols) c.label],
        rows: [
          for (final r in source) [for (final c in cols) c.exportValue!(r)],
        ],
        numeric: {
          for (var i = 0; i < cols.length; i++)
            if (cols[i].numeric) i,
        },
      );
      final path = await exportTable(table, f, company: widget.company);
      if (mounted && f != ExportFormat.print) {
        showToast(context, 'Exporté : $path', kind: ToastKind.info);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Export impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _legacyExport(List<R> rows) async {
    if (widget.onExport == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      await widget.onExport!(rows);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openRowMenu(R row, Offset globalPos) async {
    final actions = widget.rowMenu?.call(row) ?? const [];
    if (actions.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final chosen = await showMenu<RowAction<R>>(
      context: context,
      position: RelativeRect.fromRect(
          globalPos & const Size(1, 1), Offset.zero & overlay.size),
      color: T.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInner),
          side: const BorderSide(color: T.border)),
      items: [
        for (final a in actions)
          PopupMenuItem<RowAction<R>>(
            value: a,
            enabled: a.enabled,
            height: 36,
            child: Row(children: [
              Icon(a.icon, size: 16, color: a.danger ? T.dangerDark : T.muted),
              const SizedBox(width: 10),
              Text(a.label,
                  style: T.body.copyWith(
                      fontSize: 13, color: a.danger ? T.dangerDark : T.ink)),
            ]),
          ),
      ],
    );
    if (chosen != null) chosen.onSelected(row);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e, List<R> rows) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (rows.isEmpty) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final next = ((_cursor ?? -1) + (k == LogicalKeyboardKey.arrowDown ? 1 : -1))
          .clamp(0, rows.length - 1);
      setState(() => _cursor = next);
      _ensureVisible(next);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter && _cursor != null && widget.onTap != null) {
      widget.onTap!(rows[_cursor!.clamp(0, rows.length - 1)]);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space && _cursor != null && _selectable) {
      final id = widget.rowId!(rows[_cursor!]);
      setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyA && _selectable) {
      setState(() => _selected.addAll(rows.map(widget.rowId!)));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _selected.isNotEmpty) {
      setState(_selected.clear);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _ensureVisible(int i) {
    if (!_scroll.hasClients) return;
    final h = _compact ? 37.0 : 49.0;
    final top = i * h;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + h > _scroll.offset + view) {
      _scroll.jumpTo((top + h - view).clamp(0, _scroll.position.maxScrollExtent));
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

  Widget _columnsMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Colonnes et affichage',
      color: T.surface,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInner),
          side: const BorderSide(color: T.border)),
      icon: const Icon(Icons.view_column_outlined, size: 16, color: T.muted),
      itemBuilder: (_) => [
        const PopupMenuItem<String>(
            enabled: false, height: 28, child: MicroLabel('Colonnes')),
        for (final c in widget.columns)
          if (c.hideable && c.label.isNotEmpty)
            CheckedPopupMenuItem<String>(
              value: 'col:${c.key}',
              checked: !_hidden.contains(c.key),
              height: 34,
              child: Text(c.label, style: T.body.copyWith(fontSize: 13)),
            ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: 'compact',
          checked: _compact,
          height: 34,
          child: Text('Affichage compact', style: T.body.copyWith(fontSize: 13)),
        ),
      ],
      onSelected: (v) {
        if (v == 'compact') {
          _setCompact(!_compact);
        } else if (v.startsWith('col:')) {
          final key = v.substring(4);
          _setHidden(key, !_hidden.contains(key));
        }
      },
    );
  }

  Widget _exportMenu(List<R> rows) {
    if (_genericExport) {
      return PopupMenuButton<ExportFormat>(
        tooltip: 'Exporter',
        color: T.surface,
        enabled: !_exporting,
        position: PopupMenuPosition.over,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            side: const BorderSide(color: T.border)),
        itemBuilder: (_) => [
          for (final f in ExportFormat.values)
            PopupMenuItem(
              value: f,
              height: 34,
              child: Row(children: [
                Icon(
                    switch (f) {
                      ExportFormat.xlsx => Icons.grid_on_rounded,
                      ExportFormat.csv => Icons.description_outlined,
                      ExportFormat.pdf => Icons.picture_as_pdf_outlined,
                      ExportFormat.print => Icons.print_outlined,
                    },
                    size: 16,
                    color: T.muted),
                const SizedBox(width: 10),
                Text(f.label, style: T.body.copyWith(fontSize: 13)),
              ]),
            ),
        ],
        onSelected: (f) => _export(f, rows),
        child: _exportLabel(),
      );
    }
    return InkWell(
      onTap: _exporting ? null : () => _legacyExport(rows),
      borderRadius: BorderRadius.circular(T.rChip),
      child: _exportLabel(),
    );
  }

  Widget _exportLabel() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_exporting ? Icons.hourglass_top_rounded : Icons.download_rounded,
              size: 14, color: T.muted),
          const SizedBox(width: 5),
          Text(_exporting ? 'Export…' : 'Exporter',
              style: T.small.copyWith(fontSize: 13, color: T.ink)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _sorted;
    widget.controller?.rows = rows;
    final cols = _visibleCols;
    final selectedRows = _selectedRows(rows);
    final hasMenu = widget.rowMenu != null;
    // ~48 px rows (36 px in compact mode): easy to read and to click.
    final vPad = _compact ? 7.0 : 13.0;

    // ---- Paging: « 1–50 sur 312 » with previous / next ----
    final size = _pageSize <= 0 ? rows.length : _pageSize;
    final pages = rows.isEmpty || size == 0 ? 1 : (rows.length + size - 1) ~/ size;
    if (_page >= pages) _page = pages - 1;
    if (_page < 0) _page = 0;
    final start = rows.isEmpty ? 0 : _page * size;
    final end = rows.isEmpty ? 0 : (start + size).clamp(0, rows.length);
    final view = rows.isEmpty ? <R>[] : rows.sublist(start, end);

    Widget body;
    if (widget.loading && widget.items.isEmpty) {
      body = _Skeleton(columns: cols.length, compact: _compact);
    } else if (widget.error != null && widget.items.isEmpty) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, size: 32, color: T.danger),
          const SizedBox(height: 10),
          Text(widget.error!, style: T.bodyMuted, textAlign: TextAlign.center),
          if (widget.onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Réessayer'),
            ),
          ],
        ]),
      );
    } else if (rows.isEmpty) {
      body = widget.empty ??
          const EmptyState(icon: Icons.table_rows_outlined, text: 'Aucune donnée');
    } else {
      body = ListView.separated(
        controller: _scroll,
        itemCount: view.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, i) {
          final row = view[i];
          final id = widget.rowId?.call(row);
          final selected = id != null && _selected.contains(id);
          final highlighted = widget.highlight?.call(row) ?? false;
          return _HoverRow(
            onTap: widget.onTap == null
                ? null
                : () {
                    setState(() => _cursor = i);
                    _focus.requestFocus();
                    widget.onTap!(row);
                  },
            onSecondaryTap: hasMenu ? (pos) => _openRowMenu(row, pos) : null,
            background: selected
                ? T.mintTint
                : highlighted || _cursor == i && _focus.hasFocus
                    ? T.mintTint2.withValues(alpha: 0.10)
                    : null,
            leftBar: highlighted,
            builder: (hover) => Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: vPad),
              child: Row(children: [
                if (_selectable)
                  SizedBox(
                    width: 36,
                    child: Checkbox(
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => setState(() =>
                          v == true ? _selected.add(id!) : _selected.remove(id)),
                    ),
                  ),
                for (final c in cols) _cellBox(c, c.cell(context, row)),
                if (hasMenu)
                  SizedBox(
                    width: 112,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      // Always visible and labelled: nothing hides behind a
                      // hover or a right-click.
                      child: Builder(
                        builder: (btnCtx) => OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: T.ink,
                            side: BorderSide(color: hover ? T.mintDeep : T.border3),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            final box = btnCtx.findRenderObject() as RenderBox;
                            _openRowMenu(
                                row, box.localToGlobal(Offset(0, box.size.height)));
                          },
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('Actions',
                                style: TextStyle(
                                    fontFamily: T.sans,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                            SizedBox(width: 2),
                            Icon(Icons.arrow_drop_down_rounded, size: 18),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      );
    }

    final aggSource = selectedRows.isNotEmpty ? selectedRows : rows;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (n, e) => _onKey(n, e, view),
      child: Card14(
        padding: EdgeInsets.zero,
        child: Column(children: [
          // ---- Bulk bar or header ----
          if (selectedRows.isNotEmpty)
            Container(
              color: T.mintTint,
              padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 6),
              child: Row(children: [
                Checkbox(
                  value: selectedRows.length == rows.length ? true : null,
                  tristate: true,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => setState(() {
                    if (selectedRows.length == rows.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(rows.map(widget.rowId!));
                    }
                  }),
                ),
                const SizedBox(width: 4),
                Text(
                    '${selectedRows.length} sélectionné${selectedRows.length > 1 ? 's' : ''}',
                    style: T.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 16),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final a in widget.bulkActions)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                                foregroundColor: a.danger ? T.dangerDark : T.ink),
                            onPressed: () async {
                              final clear = await a.onSelected(selectedRows);
                              if (clear && mounted) setState(_selected.clear);
                            },
                            icon: Icon(a.icon, size: 16),
                            label: Text(a.label, style: const TextStyle(fontSize: 13.5)),
                          ),
                        ),
                    ]),
                  ),
                ),
                IconButton(
                  tooltip: 'Désélectionner (Échap)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 17),
                  onPressed: () => setState(_selected.clear),
                ),
              ]),
            )
          else
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8),
              child: Row(children: [
                if (_selectable)
                  SizedBox(
                    width: 36,
                    child: Checkbox(
                      value: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: rows.isEmpty
                          ? null
                          : (_) => setState(() => _selected.addAll(rows.map(widget.rowId!))),
                    ),
                  ),
                for (final c in cols)
                  _cellBox(
                    c,
                    InkWell(
                      onTap: c.sortKey == null ? null : () => _toggleSort(c),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: MicroLabel(c.label)),
                          if (_sortCol != null &&
                              _sortCol! < widget.columns.length &&
                              widget.columns[_sortCol!] == c)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 3),
                              child: Icon(
                                _asc
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                size: 14,
                                color: T.mintDeep,
                              ),
                            )
                          else if (c.sortKey != null)
                            const Padding(
                              padding: EdgeInsetsDirectional.only(start: 3),
                              child: Icon(Icons.unfold_more_rounded,
                                  size: 14, color: T.ghost),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (hasMenu) const SizedBox(width: 112),
              ]),
            ),
          const Divider(),
          if (widget.loading && widget.items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2, color: T.mint, backgroundColor: T.mintTint),
          // ---- Rows ----
          Expanded(child: body),
          // ---- Footer ----
          const Divider(),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
            child: Row(children: [
              Text(
                  rows.isEmpty
                      ? '0 ligne'
                      : selectedRows.isNotEmpty
                          ? '${selectedRows.length} sélectionné${selectedRows.length > 1 ? 's' : ''} · ${start + 1}–$end sur ${rows.length}'
                          : '${start + 1}–$end sur ${rows.length}',
                  style: T.body.copyWith(fontSize: 13.5, color: T.muted)),
              if (pages > 1) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Page précédente',
                  visualDensity: VisualDensity.compact,
                  onPressed: _page == 0 ? null : () => setState(() => _page--),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                ),
                Text('Page ${_page + 1} / $pages', style: T.small),
                IconButton(
                  tooltip: 'Page suivante',
                  visualDensity: VisualDensity.compact,
                  onPressed: _page >= pages - 1 ? null : () => setState(() => _page++),
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
              ],
              if (rows.length > 25) ...[
                const SizedBox(width: 6),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _pageSize,
                    isDense: true,
                    style: T.small.copyWith(color: T.ink),
                    items: const [
                      DropdownMenuItem(value: 25, child: Text('25 par page')),
                      DropdownMenuItem(value: 50, child: Text('50 par page')),
                      DropdownMenuItem(value: 100, child: Text('100 par page')),
                      DropdownMenuItem(value: 0, child: Text('Tout afficher')),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _pageSize = v ?? 50;
                        _page = 0;
                      });
                      if (widget.prefsKey != null) {
                        UiPrefs.instance.set(widget.prefsKey!, 'page_size', _pageSize);
                      }
                    },
                  ),
                ),
              ],
              if (widget.aggregates != null)
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final (label, value) in widget.aggregates!(aggSource)) ...[
                        const SizedBox(width: 18),
                        MicroLabel(label),
                        const SizedBox(width: 6),
                        Text(value,
                            style: T.monoBody.copyWith(
                                fontSize: 13.5, fontWeight: FontWeight.w700)),
                      ],
                    ]),
                  ),
                )
              else
                const Spacer(),
              if (widget.onExport != null || _genericExport) _exportMenu(rows),
              _columnsMenu(),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({
    required this.builder,
    this.onTap,
    this.onSecondaryTap,
    this.background,
    this.leftBar = false,
  });
  final Widget Function(bool hover) builder;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final Color? background;
  final bool leftBar;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondaryTap == null
            ? null
            : (d) => widget.onSecondaryTap!(d.globalPosition),
        child: Container(
          decoration: BoxDecoration(
            color: widget.background ?? (_hover ? T.bg : Colors.transparent),
            border: widget.leftBar
                ? const Border(left: BorderSide(color: T.mint, width: 3))
                : null,
          ),
          child: widget.builder(_hover),
        ),
      ),
    );
  }
}

/// Grey placeholder rows while the first load runs.
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.columns, required this.compact});
  final int columns;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 10,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (_, i) => Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 9 : 13),
        child: Row(children: [
          for (var c = 0; c < columns; c++)
            Expanded(
              flex: c == 0 ? 3 : 1,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 18),
                child: FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: c == 0 ? 0.55 + (i % 3) * 0.12 : 0.6,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: T.border2,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
