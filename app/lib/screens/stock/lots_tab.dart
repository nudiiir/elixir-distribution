import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// « Dates de péremption » : lots with their DLC, soonest first.
class LotsTab extends StatefulWidget {
  const LotsTab({
    super.key,
    required this.api,
    required this.warehouses,
    required this.warehouseId,
    required this.onWarehouse,
    this.onStockChanged,
    this.company = const {},
  });

  final ApiClient api;
  final List<Warehouse> warehouses;
  final String? warehouseId;
  final ValueChanged<String?> onWarehouse;
  final VoidCallback? onStockChanged;
  final Map<String, String> company;

  @override
  State<LotsTab> createState() => _LotsTabState();
}

class _LotsTabState extends State<LotsTab> {
  static const _p = 'stock_lots';

  final _search = TextEditingController();
  List<Lot> _lots = const [];
  bool _loading = true;
  String? _error;

  String? _window = UiPrefs.instance.get<String>(_p, 'window'); // expired | 15 | 60
  bool _hideEmpty = UiPrefs.instance.get<bool>(_p, 'hide_empty') ?? true;

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
      final items = await widget.api.lots();
      if (mounted) {
        setState(() {
          _lots = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Lots indisponibles : $e';
          _loading = false;
        });
      }
    }
  }

  void _save() {
    UiPrefs.instance.set(_p, 'window', _window);
    UiPrefs.instance.set(_p, 'hide_empty', _hideEmpty);
  }

  bool _inWindow(Lot l, String w) {
    final d = l.daysLeft;
    if (d == null) return false;
    return switch (w) {
      'expired' => d < 0,
      '15' => d >= 0 && d <= 15,
      '60' => d >= 0 && d <= 60,
      _ => true,
    };
  }

  List<Lot> get _visible {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final l in _lots)
        if ((!_hideEmpty || l.qtyMilli > 0) &&
            (_window == null || _inWindow(l, _window!)) &&
            (q.isEmpty ||
                l.productName.toLowerCase().contains(q) ||
                l.lotNumber.toLowerCase().contains(q)))
          l
    ];
  }

  String? get _targetWarehouse {
    if (widget.warehouseId != null) return widget.warehouseId;
    for (final w in widget.warehouses) {
      if (w.isDefault) return w.id;
    }
    return widget.warehouses.isEmpty ? null : widget.warehouses.first.id;
  }

  Future<void> _edit({Lot? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => LotDialog(api: widget.api, existing: existing),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(Lot l) async {
    final ok = await confirmAction(context,
        title: 'Supprimer le lot ${l.lotNumber.isEmpty ? '' : '« ${l.lotNumber} » '}?',
        message:
            '${l.productName} — le suivi de cette date de péremption est supprimé. Le stock ne change pas.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await widget.api.deleteLot(l.id);
      if (!mounted) return;
      showToast(context, 'Lot supprimé.');
      _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, 'Suppression impossible : ${e.message}', kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Suppression impossible : $e', kind: ToastKind.error);
    }
  }

  /// Retire the whole lot from the shelf: posted STOCK_ADJUSTMENT, motif
  /// « péremption », negative quantity on that lot.
  Future<void> _withdraw(Lot l) async {
    final wh = _targetWarehouse;
    if (wh == null) {
      showToast(context, 'Aucun dépôt configuré.', kind: ToastKind.error);
      return;
    }
    final whName = widget.warehouses.firstWhere((w) => w.id == wh).name;
    final ok = await confirmAction(context,
        title: 'Retirer du rayon ?',
        message:
            '${fmtQty(l.qtyMilli)} × ${l.productName}${l.lotNumber.isEmpty ? '' : ' (lot ${l.lotNumber})'} '
            'sortent du stock du dépôt « $whName » par un ajustement « péremption ».',
        confirmLabel: 'Retirer du stock',
        danger: true,
        icon: Icons.delete_sweep_outlined);
    if (!ok || !mounted) return;
    try {
      final draft = await widget.api.createDraft({
        'doc_type': 'STOCK_ADJUSTMENT',
        'doc_date': todayISO(),
        'warehouse_id': wh,
        'reason': 'péremption',
        'notes': 'Retrait du rayon — DLC ${l.expiryDate ?? '—'}',
        'lines': [
          {
            'product_id': l.productId,
            'lot_id': l.id,
            'description': l.productName,
            'qty_milli': -l.qtyMilli,
            'unit_price': 0,
            'discount_pct': 0,
            'vat_rate': 0,
          }
        ],
      });
      DocDetail posted;
      try {
        posted = await widget.api.postDocument(draft.id);
      } catch (_) {
        // ne pas laisser un brouillon orphelin derrière un refus
        try {
          await widget.api.cancelDocument(draft.id);
        } catch (_) {}
        rethrow;
      }
      if (!mounted) return;
      showToast(context, 'Ajustement ${posted.number ?? ''} validé — lot retiré du stock.',
          actionLabel: 'Ouvrir',
          onAction: () => openStockDocument(context, widget.api, posted.id));
      _load();
      widget.onStockChanged?.call();
    } on ApiException catch (e) {
      if (mounted) showToast(context, 'Retrait impossible : ${e.message}', kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Retrait impossible : $e', kind: ToastKind.error);
    }
  }

  (Color, String) _due(Lot l) {
    final days = l.daysLeft;
    if (days == null) return (T.faint, '—');
    if (days < 0) return (T.dangerDark, 'Périmé (${-days} j)');
    if (days <= 15) return (T.warnDark, 'J-$days');
    return (T.mintDark, 'J-$days');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final live = [for (final l in _lots) if (!_hideEmpty || l.qtyMilli > 0) l];
    int count(String w) => live.where((l) => _inWindow(l, w)).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListToolbar(
        search: _search,
        searchHint: 'Produit ou n° de lot…',
        onSearchChanged: (_) => setState(() {}),
        quickFilters: [
          for (final (k, label) in const [
            ('expired', 'Périmés'),
            ('15', '≤ 15 jours'),
            ('60', '≤ 60 jours'),
          ])
            FilterPill(
              label: label,
              active: _window == k,
              count: count(k),
              onTap: () {
                setState(() => _window = _window == k ? null : k);
                _save();
              },
            ),
          FilterPill(
            label: 'Lots épuisés',
            icon: Icons.visibility_outlined,
            active: !_hideEmpty,
            onTap: () {
              setState(() => _hideEmpty = !_hideEmpty);
              _save();
            },
          ),
        ],
        active: [
          if (_window != null)
            ActiveFilter(
                switch (_window) {
                  'expired' => 'Périmés',
                  '15' => '≤ 15 jours',
                  _ => '≤ 60 jours',
                }, () {
              setState(() => _window = null);
              _save();
            }),
        ],
        trailing: [
          DepotDropdown(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
          ),
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18, color: T.muted),
          ),
          const SizedBox(width: 6),
          SizedBox(
            height: 36,
            child: OutlinedButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Ajouter un lot'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
          'Les quantités des lots suivent les mouvements de stock. « Retirer du rayon » sort le lot '
          'du dépôt ${widget.warehouseId == null ? 'par défaut' : 'choisi'} par un ajustement « péremption ».',
          style: T.small.copyWith(fontSize: 11.5)),
      const SizedBox(height: 10),
      Expanded(
        child: DataListView<Lot>(
          prefsKey: _p,
          items: rows,
          loading: _loading,
          error: _error,
          onRetry: _load,
          rowId: (l) => l.id,
          initialSortColumn: 2,
          exportTitle: 'Dates de péremption',
          exportBaseName: 'peremptions',
          company: widget.company,
          onTap: (l) => _edit(existing: l),
          rowMenu: (l) => [
            RowAction('Retirer du rayon', Icons.delete_sweep_outlined, _withdraw,
                enabled: l.qtyMilli > 0),
            RowAction('Modifier', Icons.edit_outlined, (l) => _edit(existing: l)),
            RowAction('Supprimer le lot', Icons.delete_outline_rounded, _delete, danger: true),
          ],
          empty: EmptyState(
            icon: Icons.hourglass_bottom_rounded,
            text: _lots.isEmpty
                ? 'Aucun lot suivi.\nLes réceptions avec n° de lot ou DLC créent les lots automatiquement.'
                : 'Aucun lot ne correspond à ces filtres.',
            actions: [
              if (_window != null || _search.text.isNotEmpty)
                ('Effacer les filtres', () {
                  setState(() {
                    _window = null;
                    _search.clear();
                  });
                  _save();
                }),
              ('Ajouter un lot', () => _edit()),
            ],
          ),
          aggregates: (sel) => [
            ('Périmés', '${sel.where((l) => (l.daysLeft ?? 1) < 0).length}'),
            ('≤ 15 j', '${sel.where((l) => (l.daysLeft ?? 99) >= 0 && (l.daysLeft ?? 99) <= 15).length}'),
          ],
          columns: [
            ColumnSpec(
              id: 'product',
              label: 'Produit',
              flex: 5,
              hideable: false,
              sortKey: (l) => l.productName.toLowerCase(),
              exportValue: (l) => l.productName,
              cell: (context, l) => Text(l.productName,
                  style: T.body, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ColumnSpec(
              id: 'lot',
              label: 'N° de lot',
              flex: 2,
              sortKey: (l) => l.lotNumber,
              exportValue: (l) => l.lotNumber,
              cell: (context, l) =>
                  Text(l.lotNumber.isEmpty ? '—' : l.lotNumber, style: T.monoSmall),
            ),
            ColumnSpec(
              id: 'expiry',
              label: 'Péremption',
              width: 110,
              sortKey: (l) => l.expiryDate ?? '9999',
              exportValue: (l) => l.expiryDate == null ? '' : frDate(l.expiryDate!),
              cell: (context, l) => Text(
                  l.expiryDate == null ? '—' : frDate(l.expiryDate!),
                  style: T.monoBody.copyWith(fontSize: 12)),
            ),
            ColumnSpec(
              id: 'due',
              label: 'Échéance',
              width: 120,
              sortKey: (l) => l.daysLeft ?? 99999,
              exportValue: (l) => l.daysLeft ?? '',
              cell: (context, l) {
                final (color, label) = _due(l);
                return Text(label,
                    style: T.monoBody.copyWith(
                        fontSize: 12, color: color, fontWeight: FontWeight.w700));
              },
            ),
            ColumnSpec(
              id: 'qty',
              label: 'Qté',
              width: 90,
              numeric: true,
              sortKey: (l) => l.qtyMilli,
              exportValue: (l) => l.qtyMilli / 1000,
              cell: (context, l) => Text(fmtQty(l.qtyMilli), style: T.monoBody),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Create / edit a lot (DLC). Errors are shown under their field.
class LotDialog extends StatefulWidget {
  const LotDialog({super.key, required this.api, this.existing});
  final ApiClient api;
  final Lot? existing;

  @override
  State<LotDialog> createState() => _LotDialogState();
}

class _LotDialogState extends State<LotDialog> {
  Product? _product;
  late final _lotNumber = TextEditingController(text: widget.existing?.lotNumber ?? '');
  late final _qty = TextEditingController(
      text: widget.existing == null ? '' : fmtQty(widget.existing!.qtyMilli));
  late String? _expiry = widget.existing?.expiryDate;
  bool _busy = false;
  String? _productError;
  String? _expiryError;
  String? _qtyError;
  String? _error;

  @override
  void dispose() {
    _lotNumber.dispose();
    _qty.dispose();
    super.dispose();
  }

  Future<void> _pickProduct() async {
    final p = await pickProduct(context, widget.api, title: 'Produit du lot');
    if (p != null && mounted) {
      setState(() {
        _product = p;
        _productError = null;
      });
    }
  }

  Future<void> _pickExpiry() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_expiry ?? '') ??
          DateTime.now().add(const Duration(days: 90)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        _expiry = isoDay(d);
        _expiryError = null;
      });
    }
  }

  Future<void> _save() async {
    final productId = widget.existing?.productId ?? _product?.id;
    setState(() {
      _productError = productId == null ? 'Choisissez un produit.' : null;
      _expiryError = _expiry == null && _lotNumber.text.trim().isEmpty
          ? 'Renseignez la date de péremption.'
          : null;
      final q = _qty.text.trim();
      _qtyError = q.isNotEmpty && (parseQty(q) == null || parseQty(q)! < 0)
          ? 'Quantité invalide.'
          : null;
      _error = null;
    });
    if (_productError != null || _expiryError != null || _qtyError != null) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveLot({
        'product_id': productId,
        'lot_number': _lotNumber.text.trim(),
        'expiry_date': _expiry,
        'qty_milli': parseQty(_qty.text) ?? 0,
      }, id: widget.existing?.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _box(Widget child) => Container(
        height: 38,
        alignment: AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 430,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(widget.existing == null ? 'Nouveau lot' : 'Lot', style: T.h2)),
                IconButton(
                  tooltip: 'Fermer (Échap)',
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
              ]),
              const SizedBox(height: 8),
              const MicroLabel('Produit'),
              const SizedBox(height: 4),
              if (widget.existing != null)
                Text(widget.existing!.productName, style: T.body)
              else
                InkWell(
                  onTap: _pickProduct,
                  borderRadius: BorderRadius.circular(T.rInner),
                  child: _box(Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      Expanded(
                        child: Text(_product?.name ?? 'Choisir le produit…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _product == null ? T.bodyMuted : T.body),
                      ),
                      const Icon(Icons.search_rounded, size: 16, color: T.muted),
                    ]),
                  )),
                ),
              FieldError(_productError),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const MicroLabel('Péremption'),
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: _pickExpiry,
                      borderRadius: BorderRadius.circular(T.rInner),
                      child: _box(Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(_expiry == null ? '—' : frDate(_expiry!),
                            style: T.monoBody),
                      )),
                    ),
                    FieldError(_expiryError),
                  ]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const MicroLabel('Quantité'),
                    const SizedBox(height: 4),
                    _box(TextField(
                      controller: _qty,
                      style: T.monoBody,
                      onSubmitted: (_) => _save(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    )),
                    FieldError(_qtyError),
                  ]),
                ),
              ]),
              const SizedBox(height: 10),
              const MicroLabel('N° de lot (facultatif)'),
              const SizedBox(height: 4),
              _box(TextField(
                controller: _lotNumber,
                style: T.monoBody,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              )),
              FieldError(_error),
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Annuler', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Enregistrer',
                    onPressed: _busy ? null : _save,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
