import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/prefs.dart';
import '../../widgets/doc_editor.dart';
import '../../widgets/doc_list.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/product_thumb.dart';
import '../../widgets/ui.dart';

/// UiPrefs namespace of the Stock screen.
const kStockPrefs = 'stock';

/// Short unit label after a quantity (« 12 u. », « 3,5 kg »).
String unitLabel(String unit) => switch (unit) {
      'piece' || '' => 'u.',
      _ => unit,
    };

String qtyUnit(int milli, String unit) => '${fmtQty(milli)} ${unitLabel(unit)}';

String docLabel(String docType) => docTypeLabels[docType] ?? docType;

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// « 2026-03-10 » → « 10/03/2026 ».
String frDate(String iso) {
  if (iso.length < 10) return iso;
  return '${iso.substring(8, 10)}/${iso.substring(5, 7)}/${iso.substring(0, 4)}';
}

String frDateTime(DateTime? d) {
  if (d == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Opens any document from the stock screens (detail dialog; transfers are
/// edited with the transfer editor). Returns true when it changed.
Future<bool> openStockDocument(
    BuildContext context, ApiClient api, String docId) async {
  final changed = await showDocDetailDialog(context, api, docId,
      editorFor: (t) => switch (t) {
            'STOCK_TRANSFER' => stockTransferConfig,
            'PURCHASE_ORDER' => purchaseOrderConfig,
            _ => null,
          });
  return changed == true;
}

// ---------------------------------------------------------------------------
// Depot
// ---------------------------------------------------------------------------

/// The « Dépôt » filter of a stock list (null when the shop has one depot).
FilterField<String>? depotFilter({
  required List<Warehouse> warehouses,
  required String? value,
  required ValueChanged<String?> onChanged,
  String label = 'Dépôt',
}) {
  if (warehouses.length <= 1) return null;
  return FilterField<String>(
    label: label,
    value: warehouses.any((w) => w.id == value) ? value : null,
    allLabel: 'Tous les dépôts',
    options: [for (final w in warehouses) (w.id, w.name)],
    onChanged: onChanged,
  );
}

/// The « Période » filter of a stock list: presets + « Choisir les dates… ».
FilterField<String> periodFilter(
  BuildContext context, {
  required StockPeriod period,
  required ValueChanged<StockPeriod> onChanged,
}) {
  Future<void> custom() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: period.from != null && period.to != null
          ? DateTimeRange(start: period.from!, end: period.to!)
          : null,
      helpText: 'Période',
      saveText: 'Appliquer',
    );
    if (r != null) onChanged(StockPeriod('custom', r.start, r.end));
  }

  return FilterField<String>(
    label: 'Période',
    value: period.key == 'all' ? null : period.key,
    allLabel: 'Toute la période',
    options: [
      for (final (k, l) in StockPeriod.presets)
        if (k != 'all') (k, l),
      ('custom', period.key == 'custom' ? period.label : 'Choisir les dates…'),
    ],
    onChanged: (k) {
      if (k == 'custom') {
        custom();
      } else {
        onChanged(StockPeriod.preset(k ?? 'all'));
      }
    },
  );
}

/// A labelled filter slot that opens a picker (« Produit : Choisir… »),
/// same look as [FilterField], for [ListToolbar.panel].
class PickerFilter extends StatelessWidget {
  const PickerFilter({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onPick,
    this.onClear,
    this.width = 260,
  });
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MicroLabel(label),
        const SizedBox(height: 5),
        InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(T.rInner),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: value == null ? T.border : T.mintDeep),
            ),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 17, color: T.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(value ?? placeholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.body.copyWith(
                        fontSize: 14, color: value == null ? T.muted : T.ink)),
              ),
              if (value != null && onClear != null)
                IconButton(
                  tooltip: 'Retirer ce filtre',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 17, color: T.muted),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// « Actualiser » with its word (rule: no icon-only buttons).
class RefreshButton extends StatelessWidget {
  const RefreshButton({super.key, required this.onPressed, this.label = 'Actualiser'});
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: SizedBox(
        height: 40,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: T.muted,
            textStyle: const TextStyle(
                fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(label),
        ),
      ),
    );
  }
}

class DepotDropdown extends StatelessWidget {
  const DepotDropdown({
    super.key,
    required this.warehouses,
    required this.value,
    required this.onChanged,
    this.allowAll = true,
  });
  final List<Warehouse> warehouses;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;

  @override
  Widget build(BuildContext context) {
    if (warehouses.length <= 1 && allowAll) return const SizedBox.shrink();
    final v = warehouses.any((w) => w.id == value) ? value : null;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: v == null ? T.border : T.mintDeep),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: v,
          isExpanded: true,
          style: T.body.copyWith(fontSize: 14),
          icon: const Icon(Icons.expand_more, size: 18, color: T.faint),
          items: [
            if (allowAll)
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Tous les dépôts')),
            for (final w in warehouses)
              DropdownMenuItem<String?>(value: w.id, child: Text(w.name)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Indicators
// ---------------------------------------------------------------------------

class Kpi {
  const Kpi(this.label, this.value, {this.hint, this.tone, this.onTap});
  final String label;
  final String value;
  final String? hint;
  final Color? tone; // value colour (alert), neutral by default
  final VoidCallback? onTap;
}

class KpiStrip extends StatelessWidget {
  const KpiStrip({super.key, required this.items, this.loading = false});
  final List<Kpi> items;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(width: 10),
        Expanded(child: _KpiCard(kpi: items[i], loading: loading)),
      ],
    ]);
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.kpi, required this.loading});
  final Kpi kpi;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(kpi.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.label.copyWith(fontSize: 13)),
        const SizedBox(height: 6),
        loading
            ? const SkeletonBar(width: 110, height: 20)
            : FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(kpi.value,
                    maxLines: 1,
                    style: T.monoBody.copyWith(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: kpi.tone ?? T.ink)),
              ),
        if (kpi.hint != null) ...[
          const SizedBox(height: 3),
          Text(kpi.hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.small),
        ],
      ]),
    );
    if (kpi.onTap == null) return card;
    return InkWell(
        onTap: kpi.onTap,
        borderRadius: BorderRadius.circular(T.rInner),
        child: card);
  }
}

// ---------------------------------------------------------------------------
// Period
// ---------------------------------------------------------------------------

/// A period of the stock lists — preset key or custom dates.
class StockPeriod {
  const StockPeriod(this.key, this.from, this.to);
  final String key; // today | 7d | month | last_month | year | custom | all
  final DateTime? from;
  final DateTime? to;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static const presets = [
    ('today', "Aujourd'hui"),
    ('7d', '7 jours'),
    ('month', 'Ce mois'),
    ('last_month', 'Mois dernier'),
    ('year', 'Cette année'),
    ('all', 'Tout'),
  ];

  factory StockPeriod.preset(String key) {
    final today = _day(DateTime.now());
    final monthStart = DateTime(today.year, today.month, 1);
    return switch (key) {
      'today' => StockPeriod(key, today, today),
      '7d' => StockPeriod(key, today.subtract(const Duration(days: 6)), today),
      'last_month' => StockPeriod(key, DateTime(today.year, today.month - 1, 1),
          monthStart.subtract(const Duration(days: 1))),
      'year' => StockPeriod(key, DateTime(today.year, 1, 1), today),
      'all' => const StockPeriod('all', null, null),
      _ => StockPeriod('month', monthStart, today),
    };
  }

  String? get fromIso => from == null ? null : isoDay(from!);
  String? get toIso => to == null ? null : isoDay(to!);

  String get label {
    if (key != 'custom') {
      return presets.firstWhere((p) => p.$1 == key, orElse: () => ('', 'Ce mois')).$2;
    }
    return '${frDate(fromIso ?? '')} → ${frDate(toIso ?? '')}';
  }

  /// Restores the remembered period of a list (default: this month).
  static StockPeriod load(String screen, {String fallback = 'month'}) {
    final key = UiPrefs.instance.get<String>(screen, 'period') ?? fallback;
    if (key == 'custom') {
      final f = DateTime.tryParse(UiPrefs.instance.get<String>(screen, 'period_from') ?? '');
      final t = DateTime.tryParse(UiPrefs.instance.get<String>(screen, 'period_to') ?? '');
      if (f != null && t != null) return StockPeriod('custom', f, t);
      return StockPeriod.preset(fallback);
    }
    return StockPeriod.preset(key);
  }

  void save(String screen) {
    UiPrefs.instance.set(screen, 'period', key);
    UiPrefs.instance.set(screen, 'period_from', key == 'custom' ? fromIso : null);
    UiPrefs.instance.set(screen, 'period_to', key == 'custom' ? toIso : null);
  }
}

/// Period button: presets + « Personnalisé… » (date range picker).
class PeriodButton extends StatelessWidget {
  const PeriodButton({super.key, required this.period, required this.onChanged});
  final StockPeriod period;
  final ValueChanged<StockPeriod> onChanged;

  Future<void> _custom(BuildContext context) async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: period.from != null && period.to != null
          ? DateTimeRange(start: period.from!, end: period.to!)
          : null,
      helpText: 'Période',
      saveText: 'Appliquer',
    );
    if (r != null) onChanged(StockPeriod('custom', r.start, r.end));
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Période',
      color: T.surface,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInner),
          side: const BorderSide(color: T.border)),
      itemBuilder: (_) => [
        for (final (k, l) in StockPeriod.presets)
          CheckedPopupMenuItem<String>(
            value: k,
            checked: period.key == k,
            height: 40,
            child: Text(l, style: T.body.copyWith(fontSize: 14)),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: 'custom',
          checked: period.key == 'custom',
          height: 40,
          child: Text('Personnalisé…', style: T.body.copyWith(fontSize: 14)),
        ),
      ],
      onSelected: (k) {
        if (k == 'custom') {
          _custom(context);
        } else {
          onChanged(StockPeriod.preset(k));
        }
      },
      child: Container(
        height: 36,
        margin: const EdgeInsetsDirectional.only(end: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: T.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.calendar_today_rounded, size: 13, color: T.muted),
          const SizedBox(width: 6),
          Text(period.label,
              style: T.small.copyWith(
                  fontSize: 13.5, fontWeight: FontWeight.w600, color: T.ink)),
          const Icon(Icons.expand_more_rounded, size: 16, color: T.muted),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Product picker
// ---------------------------------------------------------------------------

/// Search picker for one product (Enter = first result, ↑↓, Esc).
Future<Product?> pickProduct(BuildContext context, ApiClient api,
    {String title = 'Choisir un produit'}) {
  return showDialog<Product>(
    context: context,
    builder: (_) => _ProductPicker(api: api, title: title),
  );
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker({required this.api, required this.title});
  final ApiClient api;
  final String title;

  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Product> _items = const [];
  bool _loading = false;
  String? _error;
  int _cursor = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.products(q: _q.text.trim(), limit: 30);
      if (mounted) {
        setState(() {
          _items = items;
          _cursor = 0;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 480,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(widget.title, style: T.h2)),
              IconButton(
                tooltip: 'Fermer (Échap)',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 18, color: T.muted),
              ),
            ]),
            const SizedBox(height: 8),
            Focus(
              onKeyEvent: (n, e) {
                if (e is! KeyDownEvent) return KeyEventResult.ignored;
                final k = e.logicalKey;
                if (k == LogicalKeyboardKey.arrowDown && _items.isNotEmpty) {
                  setState(() => _cursor = (_cursor + 1).clamp(0, _items.length - 1));
                  return KeyEventResult.handled;
                }
                if (k == LogicalKeyboardKey.arrowUp && _items.isNotEmpty) {
                  setState(() => _cursor = (_cursor - 1).clamp(0, _items.length - 1));
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: SearchField(
                controller: _q,
                autofocus: true,
                hint: 'Nom, code-barres…',
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 220), _search);
                },
                onSubmitted: (_) {
                  if (_items.isNotEmpty) {
                    Navigator.of(context).pop(_items[_cursor.clamp(0, _items.length - 1)]);
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _error != null
                  ? EmptyState(icon: Icons.cloud_off_rounded, text: _error!, actions: [
                      ('Réessayer', _search),
                    ])
                  : _items.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off_rounded,
                          text: _loading ? 'Recherche…' : 'Aucun produit trouvé.')
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final p = _items[i];
                            return InkWell(
                              onTap: () => Navigator.of(context).pop(p),
                              child: Container(
                                color: i == _cursor ? T.mintTint : null,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 9),
                                child: Row(children: [
                                  ProductThumb(api: widget.api, product: p, size: 28),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(p.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: T.body)),
                                  if (p.barcode != null)
                                    Text(p.barcode!, style: T.monoSmall),
                                ]),
                              ),
                            );
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Coloured state dot used by quantities (out of stock = red, below min. = orange).
class StockDot extends StatelessWidget {
  const StockDot({super.key, required this.rupture, required this.underMin});
  final bool rupture;
  final bool underMin;

  @override
  Widget build(BuildContext context) {
    if (!rupture && !underMin) return const SizedBox(width: 13);
    return Container(
      margin: const EdgeInsetsDirectional.only(end: 6),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
          color: rupture ? T.danger : T.warn, shape: BoxShape.circle),
    );
  }
}
