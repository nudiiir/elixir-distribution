import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/prefs.dart';
import '../../widgets/doc_editor.dart';
import '../../widgets/doc_list.dart';
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
// Dépôt
// ---------------------------------------------------------------------------

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
      height: 36,
      margin: const EdgeInsetsDirectional.only(start: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: v == null ? T.border : T.mintDeep),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: v,
          style: T.body.copyWith(fontSize: 13),
          icon: const Icon(Icons.expand_more, size: 16, color: T.faint),
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
// Indicateurs
// ---------------------------------------------------------------------------

class Kpi {
  const Kpi(this.label, this.value, {this.hint, this.tone, this.onTap});
  final String label;
  final String value;
  final String? hint;
  final Color? tone; // couleur de la valeur (alerte), neutre par défaut
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MicroLabel(kpi.label),
        const SizedBox(height: 6),
        loading
            ? const SkeletonBar(width: 90, height: 14)
            : Text(kpi.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.monoBody.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: kpi.tone ?? T.ink)),
        if (kpi.hint != null) ...[
          const SizedBox(height: 2),
          Text(kpi.hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.small.copyWith(fontSize: 11)),
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
// Période
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
            height: 34,
            child: Text(l, style: T.body.copyWith(fontSize: 13)),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<String>(
          value: 'custom',
          checked: period.key == 'custom',
          height: 34,
          child: Text('Personnalisé…', style: T.body.copyWith(fontSize: 13)),
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
        height: 32,
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
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: T.ink)),
          const Icon(Icons.expand_more_rounded, size: 16, color: T.muted),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sélecteur de produit
// ---------------------------------------------------------------------------

/// Search picker for one product (Entrée = premier résultat, ↑↓, Échap).
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
                                    horizontal: 8, vertical: 7),
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

/// Coloured state dot used by quantities (rupture = rouge, sous le min. = orange).
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
