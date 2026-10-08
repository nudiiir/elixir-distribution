import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/list_export.dart';
import '../util/prefs.dart';
import '../widgets/doc_editor.dart';
import '../widgets/list_toolbar.dart';
import 'stock/inventory_page.dart';
import 'stock/ledger_tab.dart';
import 'stock/levels_tab.dart';
import 'stock/lots_tab.dart';
import 'stock/reorder_tab.dart';
import 'stock/stock_common.dart';
import 'stock/stock_docs_tab.dart';

/// Écran Stock : Niveaux · Mouvements · À commander · Dates de péremption ·
/// Ajustements · Transferts. Remembers the last tab and depot (UiPrefs).
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.api, required this.session});
  final ApiClient api;
  final Session session;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

enum _Tab { levels, moves, reorder, lots, adjustments, transfers }

class _StockScreenState extends State<StockScreen> {
  bool get _viewCost => widget.session.user.can('view_cost');
  bool get _canPurchase => widget.session.user.can('purchases');

  List<Warehouse> _warehouses = const [];
  Map<String, String> _company = const {};
  String? _warehouseId = UiPrefs.instance.get<String>(kStockPrefs, 'warehouse');
  late _Tab _tab = _Tab.values.firstWhere(
      (t) => t.name == UiPrefs.instance.get<String>(kStockPrefs, 'tab'),
      orElse: () => _Tab.levels);
  final Set<_Tab> _visited = {};

  final _levelsKey = GlobalKey<LevelsTabState>();
  final _ledgerKey = GlobalKey<LedgerTabState>();
  final _adjKey = GlobalKey<StockDocsTabState>();
  final _trKey = GlobalKey<StockDocsTabState>();

  @override
  void initState() {
    super.initState();
    Features.instance.addListener(_onFeatures);
    _init();
  }

  @override
  void dispose() {
    Features.instance.removeListener(_onFeatures);
    super.dispose();
  }

  void _onFeatures() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    try {
      final ws = await widget.api.warehouses();
      if (mounted) {
        setState(() {
          _warehouses = ws;
          if (_warehouseId != null && !ws.any((w) => w.id == _warehouseId)) {
            _warehouseId = null;
          }
        });
      }
    } catch (_) {
      // les onglets affichent leur propre erreur de chargement
    }
    try {
      final s = await widget.api.settings();
      if (mounted) setState(() => _company = s);
    } catch (_) {}
  }

  List<(_Tab, String)> get _tabs => [
        (_Tab.levels, 'Niveaux'),
        (_Tab.moves, 'Mouvements'),
        (_Tab.reorder, 'À commander'),
        if (Features.instance.lots) (_Tab.lots, 'Dates de péremption'),
        (_Tab.adjustments, 'Ajustements'),
        if (_warehouses.length > 1 || _tab == _Tab.transfers)
          (_Tab.transfers, 'Transferts'),
      ];

  void _select(_Tab t) {
    setState(() => _tab = t);
    UiPrefs.instance.set(kStockPrefs, 'tab', t.name);
  }

  void _setWarehouse(String? id) {
    setState(() => _warehouseId = id);
    UiPrefs.instance.set(kStockPrefs, 'warehouse', id);
  }

  void _stockChanged() {
    _levelsKey.currentState?.load();
    _adjKey.currentState?.reload();
    _trKey.currentState?.reload();
  }

  void _showMoves(String productId, String productName) {
    final ledger = _ledgerKey.currentState;
    if (ledger != null) {
      ledger.showProduct(productId, productName);
    } else {
      // first visit: the tab reads its remembered product filter at start
      UiPrefs.instance.set('stock_ledger', 'product_id', productId);
      UiPrefs.instance.set('stock_ledger', 'product_name', productName);
    }
    _select(_Tab.moves);
  }

  Future<void> _inventory({String? resumeId}) async {
    if (_warehouses.isEmpty) {
      showToast(context, 'Aucun dépôt : créez un dépôt dans les paramètres.', kind: ToastKind.warning);
      return;
    }
    final out = await openInventoryPage(
      context,
      api: widget.api,
      warehouses: _warehouses,
      viewCost: _viewCost,
      warehouseId: _warehouseId,
      resumeId: resumeId,
    );
    if (!mounted || out == null || out.doc == null) return;
    final doc = out.doc!;
    if (out.saved) {
      showToast(context,
          'Inventaire enregistré (${doc.lines.length} ligne(s)) — reprenez-le depuis « Inventaire ».',
          kind: ToastKind.info);
      _adjKey.currentState?.reload();
      return;
    }
    showToast(context, 'Inventaire ${doc.number ?? ''} validé — ${doc.lines.length} produit(s) compté(s).',
        actionLabel: 'Ouvrir', onAction: () => openStockDocument(context, widget.api, doc.id));
    _stockChanged();
  }

  Future<void> _newTransfer() async {
    if (_warehouses.length < 2) {
      showToast(context, 'Un transfert demande au moins deux dépôts.', kind: ToastKind.warning);
      return;
    }
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DocEditorScreen(api: widget.api, config: stockTransferConfig),
    ));
    if (changed == true && mounted) {
      if (_tab != _Tab.transfers) _select(_Tab.transfers);
      _stockChanged();
    }
  }

  Future<void> _export() async {
    final f = await showDialog<ExportFormat>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: T.surface,
        title: const Text('Exporter le stock', style: T.h2),
        children: [
          for (final f in ExportFormat.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Text(f.label, style: T.body),
            ),
        ],
      ),
    );
    if (f == null || !mounted) return;
    if (_tab != _Tab.levels) _select(_Tab.levels);
    // la liste doit être construite (et chargée) avant d'être exportée
    await WidgetsBinding.instance.endOfFrame;
    final st = _levelsKey.currentState;
    if (st == null) return;
    try {
      final path = await st.exportVisible(f);
      if (mounted && f != ExportFormat.print) {
        showToast(context, 'Exporté : $path', kind: ToastKind.info);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Export impossible : $e', kind: ToastKind.error);
    }
  }

  Widget _buildTab(_Tab t) {
    switch (t) {
      case _Tab.levels:
        return LevelsTab(
          key: _levelsKey,
          api: widget.api,
          viewCost: _viewCost,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          onShowMoves: _showMoves,
          onInventory: _inventory,
          company: _company,
        );
      case _Tab.moves:
        return LedgerTab(
          key: _ledgerKey,
          api: widget.api,
          viewCost: _viewCost,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          company: _company,
        );
      case _Tab.reorder:
        return ReorderTab(
          api: widget.api,
          viewCost: _viewCost,
          canPurchase: _canPurchase,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          company: _company,
        );
      case _Tab.lots:
        return LotsTab(
          api: widget.api,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          onStockChanged: _stockChanged,
          company: _company,
        );
      case _Tab.adjustments:
        return StockDocsTab(
          key: _adjKey,
          mode: StockDocsMode.adjustments,
          api: widget.api,
          viewCost: _viewCost,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          onPrimary: _inventory,
          onResumeInventory: (id) => _inventory(resumeId: id),
          company: _company,
        );
      case _Tab.transfers:
        return StockDocsTab(
          key: _trKey,
          mode: StockDocsMode.transfers,
          api: widget.api,
          viewCost: _viewCost,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          onPrimary: _newTransfer,
          company: _company,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (!tabs.any((t) => t.$1 == _tab)) _tab = _Tab.levels;
    _visited.add(_tab);
    final transfers = _tab == _Tab.transfers;
    final multi = _warehouses.length > 1;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Stock',
          primaryLabel: transfers ? 'Nouveau transfert' : 'Inventaire',
          primaryIcon: transfers ? Icons.compare_arrows_rounded : Icons.fact_check_outlined,
          onPrimary: transfers ? _newTransfer : () => _inventory(),
          more: [
            if (transfers)
              MenuEntry('Inventaire', Icons.fact_check_outlined, () => _inventory())
            else
              MenuEntry('Nouveau transfert', Icons.compare_arrows_rounded, _newTransfer,
                  enabled: multi),
            MenuEntry('Exporter…', Icons.download_rounded, _export),
          ],
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (t, label) in tabs)
              _ViewTab(label: label, selected: _tab == t, onTap: () => _select(t)),
          ]),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: IndexedStack(
            index: tabs.indexWhere((t) => t.$1 == _tab),
            children: [
              for (final (t, _) in tabs)
                KeyedSubtree(
                  key: ValueKey(t),
                  child: _visited.contains(t) ? _buildTab(t) : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _ViewTab extends StatelessWidget {
  const _ViewTab({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : T.muted,
              )),
        ),
      ),
    );
  }
}
