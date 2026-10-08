import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/analysis_links.dart';
import '../util/commands.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/list_export.dart';
import '../util/prefs.dart';
import '../widgets/doc_editor.dart';
import '../widgets/fiche_produit.dart';
import '../widgets/list_toolbar.dart';
import 'stock/inventory_page.dart';
import 'stock/ledger_tab.dart';
import 'stock/levels_tab.dart';
import 'stock/lots_tab.dart';
import 'stock/reorder_tab.dart';
import 'stock/stock_common.dart';
import 'stock/stock_docs_tab.dart';

/// Écran Stock : Niveaux de stock · Mouvements · Inventaire · Transferts ·
/// À commander · Dates de péremption · Ajustements. Each tab has its own
/// labelled primary action in the page header. Remembers the last tab and
/// depot (UiPrefs). Menu commands (see [ScreenCommand]): `tab:levels`,
/// `tab:ledger`, `inventory`, `tab:transfers`, `tab:reorder`, `tab:lots`,
/// `tab:adjustments`.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.api, required this.session, this.command});
  final ApiClient api;
  final Session session;
  final ScreenCommand? command;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

enum _Tab { levels, moves, inventory, transfers, reorder, lots, adjustments }

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
  late final Future<void> _ready;

  final _levelsKey = GlobalKey<LevelsTabState>();
  final _ledgerKey = GlobalKey<LedgerTabState>();
  final _invKey = GlobalKey<StockDocsTabState>();
  final _adjKey = GlobalKey<StockDocsTabState>();
  final _trKey = GlobalKey<StockDocsTabState>();
  final _reorderKey = GlobalKey<ReorderTabState>();
  final _lotsKey = GlobalKey<LotsTabState>();

  @override
  void initState() {
    super.initState();
    Features.instance.addListener(_onFeatures);
    widget.command?.addListener(_onCommand);
    _ready = _init();
    _onCommand();
  }

  @override
  void didUpdateWidget(covariant StockScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.command != widget.command) {
      oldWidget.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
      _onCommand();
    }
  }

  @override
  void dispose() {
    Features.instance.removeListener(_onFeatures);
    widget.command?.removeListener(_onCommand);
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

  // ---- menu commands -------------------------------------------------------

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null) return;
    widget.command!.done();
    // after the first frame: the screen may be built by this very command
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run(cmd);
    });
  }

  Future<void> _run(String cmd) async {
    // back to the tabs if a page (inventory, detail…) is open on top
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      final popped = await nav.maybePop();
      if (!popped || !mounted) return;
    }
    switch (cmd) {
      case 'inventory':
        _select(_Tab.inventory);
        await _ready;
        if (mounted) await _inventory();
      case 'tab:lots':
        if (!Features.instance.lots) {
          showToast(context,
              'Le suivi des dates de péremption est désactivé — activez-le dans les paramètres.',
              kind: ToastKind.info);
          return;
        }
        _select(_Tab.lots);
      default:
        final t = switch (cmd) {
          'tab:levels' => _Tab.levels,
          'tab:ledger' => _Tab.moves,
          'tab:transfers' => _Tab.transfers,
          'tab:reorder' => _Tab.reorder,
          'tab:adjustments' => _Tab.adjustments,
          'tab:inventory' => _Tab.inventory,
          _ => null,
        };
        if (t != null) _select(t);
    }
  }

  // ---- tabs ----------------------------------------------------------------

  List<(_Tab, String)> get _tabs => [
        (_Tab.levels, 'Niveaux de stock'),
        (_Tab.moves, 'Mouvements'),
        (_Tab.inventory, 'Inventaire'),
        if (_warehouses.length > 1 || _tab == _Tab.transfers) (_Tab.transfers, 'Transferts'),
        (_Tab.reorder, 'À commander'),
        if (Features.instance.lots) (_Tab.lots, 'Dates de péremption'),
        (_Tab.adjustments, 'Ajustements'),
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
    _invKey.currentState?.reload();
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

  // ---- actions -------------------------------------------------------------

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
          'Comptage enregistré (${doc.lines.length} produit(s)) — reprenez-le depuis l’onglet « Inventaire ».',
          kind: ToastKind.info,
          actionLabel: 'Reprendre',
          onAction: () => _inventory(resumeId: doc.id));
      if (_tab != _Tab.inventory) _select(_Tab.inventory);
      _invKey.currentState?.reload();
      return;
    }
    showToast(context, 'Inventaire ${doc.number ?? ''} validé — ${doc.lines.length} produit(s) compté(s).',
        actionLabel: 'Ouvrir', onAction: () => openStockDocument(context, widget.api, doc.id));
    if (_tab != _Tab.inventory) _select(_Tab.inventory);
    _stockChanged();
  }

  Future<void> _newTransfer() async {
    if (_warehouses.length < 2) {
      showToast(context, 'Un transfert demande au moins deux dépôts (paramètres).',
          kind: ToastKind.warning);
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

  /// « Nouvel ajustement » : choose the product, then the quick adjust dialog.
  Future<void> _newAdjustment() async {
    final p = await pickProduct(context, widget.api, title: 'Corriger le stock de quel produit ?');
    if (p == null || !mounted) return;
    final done = await showAdjustStock(context, widget.api, p.id);
    if (done && mounted) {
      if (_tab != _Tab.adjustments) _select(_Tab.adjustments);
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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

  /// The labelled primary action of each tab (null = none).
  (String, IconData, VoidCallback)? get _primary => switch (_tab) {
        _Tab.levels || _Tab.inventory => (
            _tab == _Tab.inventory ? 'Nouvel inventaire' : 'Faire un inventaire',
            Icons.fact_check_outlined,
            () => _inventory()
          ),
        _Tab.moves => null,
        _Tab.transfers => ('Nouveau transfert', Icons.compare_arrows_rounded, _newTransfer),
        _Tab.reorder when _canPurchase => (
            'Créer les bons de commande',
            Icons.local_shipping_outlined,
            () => _reorderKey.currentState?.createOrdersForShown()
          ),
        _Tab.reorder => null,
        _Tab.lots => (
            'Ajouter une date de péremption',
            Icons.add_rounded,
            () => _lotsKey.currentState?.addLot()
          ),
        _Tab.adjustments => ('Nouvel ajustement', Icons.tune_rounded, _newAdjustment),
      };

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
      case _Tab.inventory:
        return StockDocsTab(
          key: _invKey,
          mode: StockDocsMode.inventories,
          api: widget.api,
          viewCost: _viewCost,
          warehouses: _warehouses,
          warehouseId: _warehouseId,
          onWarehouse: _setWarehouse,
          onPrimary: _inventory,
          onResumeInventory: (id) => _inventory(resumeId: id),
          company: _company,
        );
      case _Tab.reorder:
        return ReorderTab(
          key: _reorderKey,
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
          key: _lotsKey,
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
          onPrimary: _newAdjustment,
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
    final multi = _warehouses.length > 1;
    final primary = _primary;
    final primaryLabel = primary?.$1;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Stock',
          primaryLabel: primaryLabel,
          primaryIcon: primary?.$2 ?? Icons.add_rounded,
          onPrimary: primary?.$3,
          more: [
            if (primaryLabel != 'Faire un inventaire' && primaryLabel != 'Nouvel inventaire')
              MenuEntry('Faire un inventaire', Icons.fact_check_outlined, () => _inventory()),
            if (primaryLabel != 'Nouvel ajustement')
              MenuEntry('Nouvel ajustement', Icons.tune_rounded, _newAdjustment),
            if (primaryLabel != 'Nouveau transfert' && multi)
              MenuEntry('Nouveau transfert', Icons.compare_arrows_rounded, _newTransfer),
            MenuEntry('Exporter le stock…', Icons.download_rounded, _export),
            if (AnalysisLinks.available)
              MenuEntry('Analyser le stock', Icons.insights_rounded,
                  () => AnalysisLinks.launch(AnalysisLinks.stock())),
          ],
        ),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (t, label) in tabs)
              _ViewTab(label: label, selected: _tab == t, onTap: () => _select(t)),
          ]),
        ),
        const SizedBox(height: 16),
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
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border3),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : T.ink,
              )),
        ),
      ),
    );
  }
}
