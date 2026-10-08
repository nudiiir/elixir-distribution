import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../widgets/data_table.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'stock_common.dart';

/// « Dates de péremption » : lots with their expiry date, soonest first.
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
  State<LotsTab> createState() => LotsTabState();
}

class LotsTabState extends State<LotsTab> {
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
      '60' => d >= 0 && d <= Features.instance.expiryAlertDays, // fenêtre des Paramètres
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

  /// « Ajouter une date de péremption » of the page header.
  void addLot() => _edit();

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
        'notes': 'Retrait du rayon — péremption le ${l.expiryDate == null ? '—' : frDate(l.expiryDate!)}',
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
    if (days == 0) return (T.warnDark, 'Aujourd’hui');
    if (days <= 15) return (T.warnDark, '$days jour(s)');
    return (T.mintDark, '$days jours');
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
          for (final (k, label) in [
            ('expired', 'Périmés'),
            ('15', '≤ 15 jours'),
            ('60', '≤ ${Features.instance.expiryAlertDays} jours'),
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
        ],
        panel: FilterPanel(fields: [
          ?depotFilter(
            warehouses: widget.warehouses,
            value: widget.warehouseId,
            onChanged: widget.onWarehouse,
            label: 'Dépôt pour « Retirer du rayon »',
          ),
          FilterField<bool>(
            label: 'Lots vides (quantité 0)',
            value: _hideEmpty ? null : true,
            allLabel: 'Masqués',
            options: const [(true, 'Affichés')],
            onChanged: (v) {
              setState(() => _hideEmpty = v == null);
              _save();
            },
          ),
        ]),
        active: [
          if (_window != null)
            ActiveFilter(
                switch (_window) {
                  'expired' => 'Périmés',
                  '15' => '≤ 15 jours',
                  _ => '≤ ${Features.instance.expiryAlertDays} jours',
                }, () {
              setState(() => _window = null);
              _save();
            }),
        ],
        trailing: [RefreshButton(onPressed: _load)],
      ),
      const SizedBox(height: 8),
      Text(
          'Les quantités des lots suivent les ventes et les achats. « Retirer du rayon » sort le lot '
          'du stock du dépôt ${widget.warehouseId == null ? 'par défaut' : 'choisi'} (ajustement « péremption »).',
          style: T.small),
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
                ? 'Aucune date de péremption suivie.\nLes bons de réception avec un n° de lot ou une date de péremption les créent automatiquement.'
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
              ('Ajouter une date de péremption', () => _edit()),
            ],
          ),
          aggregates: (sel) => [
            ('Périmés', '${sel.where((l) => (l.daysLeft ?? 1) < 0).length}'),
            ('Dans 15 jours ou moins', '${sel.where((l) => (l.daysLeft ?? 99) >= 0 && (l.daysLeft ?? 99) <= 15).length}'),
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
              label: 'Date de péremption',
              width: 170,
              sortKey: (l) => l.expiryDate ?? '9999',
              exportValue: (l) => l.expiryDate == null ? '' : frDate(l.expiryDate!),
              cell: (context, l) => Text(
                  l.expiryDate == null ? '—' : frDate(l.expiryDate!),
                  style: T.monoBody.copyWith(fontSize: 13.5)),
            ),
            ColumnSpec(
              id: 'due',
              label: 'Reste',
              width: 140,
              sortKey: (l) => l.daysLeft ?? 99999,
              exportValue: (l) => l.daysLeft ?? '',
              cell: (context, l) {
                final (color, label) = _due(l);
                return Text(label,
                    style: T.monoBody.copyWith(
                        fontSize: 13.5, color: color, fontWeight: FontWeight.w700));
              },
            ),
            ColumnSpec(
              id: 'qty',
              label: 'Quantité',
              width: 100,
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

  Widget _box(Widget child, {bool error = false}) => Container(
        height: 44,
        alignment: AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: error ? T.danger : T.border3),
        ),
        child: child,
      );

  /// Label above the field, red « * » when required.
  Widget _label(String text, {bool required = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text),
          if (required)
            const TextSpan(text: ' *', style: TextStyle(color: T.dangerDark)),
        ]), style: T.label.copyWith(color: T.ink)),
      );

  Widget _help(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text, style: T.small),
      );

  @override
  Widget build(BuildContext context) {
    final edit = widget.existing != null;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 460,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                    child: Text(edit ? 'Modifier la date de péremption' : 'Nouvelle date de péremption',
                        style: T.h2)),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Fermer'),
                  style: TextButton.styleFrom(foregroundColor: T.muted),
                ),
              ]),
              const SizedBox(height: 14),
              _label('Produit', required: !edit),
              if (edit)
                Text(widget.existing!.productName, style: T.body)
              else
                InkWell(
                  onTap: _pickProduct,
                  borderRadius: BorderRadius.circular(T.rInner),
                  child: _box(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        Expanded(
                          child: Text(_product?.name ?? 'Choisir le produit…',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _product == null ? T.bodyMuted : T.body),
                        ),
                        const Icon(Icons.search_rounded, size: 18, color: T.muted),
                      ]),
                    ),
                    error: _productError != null,
                  ),
                ),
              FieldError(_productError),
              const SizedBox(height: 14),
              _label('Date de péremption', required: true),
              InkWell(
                onTap: _pickExpiry,
                borderRadius: BorderRadius.circular(T.rInner),
                child: _box(
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      Expanded(
                        child: Text(_expiry == null ? 'Choisir la date…' : frDate(_expiry!),
                            style: _expiry == null ? T.bodyMuted : T.monoBody),
                      ),
                      const Icon(Icons.calendar_today_rounded, size: 17, color: T.muted),
                    ]),
                  ),
                  error: _expiryError != null,
                ),
              ),
              FieldError(_expiryError),
              const SizedBox(height: 14),
              _label('Quantité dans ce lot'),
              _box(
                TextField(
                  controller: _qty,
                  style: T.monoBody,
                  onSubmitted: (_) => _save(),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
                error: _qtyError != null,
              ),
              FieldError(_qtyError),
              if (_qtyError == null)
                _help('Elle suit ensuite toute seule les ventes et les achats.'),
              const SizedBox(height: 14),
              _label('N° de lot (facultatif)'),
              _box(TextField(
                controller: _lotNumber,
                style: T.monoBody,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              )),
              FieldError(_error),
              const SizedBox(height: 20),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Annuler', style: TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: PrimaryButton(
                    label: _busy ? 'Enregistrement…' : 'Enregistrer',
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
