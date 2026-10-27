import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../api/models.dart';
import '../screens/assistant_screen.dart';
import '../screens/analytics_screen.dart';
import '../screens/designer_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/partners_screen.dart';
import '../screens/crm/crm_screen.dart';
import '../screens/deliveries/deliveries_screen.dart';
import '../screens/orders/orders_screen.dart';
import '../screens/pricing/pricing_screen.dart';
import '../api/web_orders_sync.dart' show webOrdersHeartbeat;
import '../screens/pos_screen.dart';
import '../screens/products_screen.dart';
import '../screens/purchases_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/sales_screen.dart';
import '../screens/settings/settings_shell.dart';
import '../screens/stock_screen.dart';
import '../screens/webstore_screen.dart';
import '../theme/tokens.dart';
import '../util/analysis_links.dart';
import '../util/commands.dart';
import '../util/config.dart';
import '../util/features.dart';
import '../util/prefs.dart';
import '../util/feedback.dart';
import '../util/shortcuts.dart';
import '../util/updater.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart' show showDocDetailDialog;
import '../widgets/fiche_produit.dart' show showFicheProduit;
import '../screens/partners/partner_pages.dart' show openPartnerDetail;
import 'alerts_bell.dart';
import 'global_search.dart';
import '../widgets/ui.dart';

class _Module {
  const _Module(this.key, this.icon, this.title, this.group,
      {String? perm, this.feature, this.subs = const []})
      : perm = perm ?? key;
  final String key; // which screen to build
  final String perm; // permission that reveals it (defaults to key)
  final IconData icon;
  final String title;
  final String group; // sidebar section
  final String? feature; // « Profil du magasin » switch that hides it

  /// Sub-items: (label, command sent to the screen, optional feature).
  final List<(String, String, String?)> subs;
}

const _productSubs = [
  ('Liste des produits', 'list', null),
  ('Nouveau produit', 'new', null),
  ('Catégories', 'categories', null),
  ('Étiquettes', 'labels', null),
  ('Importer des produits', 'import', null),
];
const _stockSubs = [
  ('Niveaux de stock', 'tab:levels', null),
  ('Mouvements', 'tab:ledger', null),
  ('Inventaire', 'inventory', null),
  ('Transferts', 'tab:transfers', null),
  ('À commander', 'tab:reorder', null),
  ('Dates de péremption', 'tab:lots', 'feature_lots'),
  ('Ajustements', 'tab:adjustments', null),
];
const _salesSubs = [
  ('Toutes les ventes', 'list', null),
  ('Nouvelle facture', 'new:SALE_INVOICE', null),
  ('Tickets de caisse', 'type:SALE_TICKET', null),
  ('Devis', 'type:QUOTE', null),
  ('Bons de livraison', 'type:DELIVERY_NOTE', null),
  ('Avoirs clients', 'type:SALE_CREDIT_NOTE', null),
];
const _purchaseSubs = [
  ('Tous les achats', 'list', null),
  ('Nouveau bon de réception', 'new:PURCHASE_RECEIPT', null),
  ('Bons de commande', 'type:PURCHASE_ORDER', null),
  ('Factures fournisseurs', 'type:PURCHASE_INVOICE', null),
  ('Avoirs fournisseurs', 'type:PURCHASE_CREDIT_NOTE', null),
];
const _partnerSubs = [
  ('Clients', 'kind:customer', null),
  ('Fournisseurs', 'kind:supplier', null),
  ('Nouveau client', 'new:customer', null),
  ('Nouveau fournisseur', 'new:supplier', null),
];
const _crmSubs = [
  ('Mes tâches', 'tab:tasks', null),
  ('Segments', 'tab:segments', null),
  ('Commerciaux', 'tab:reps', null),
  ('Par wilaya', 'tab:wilayas', null),
];
const _orderSubs = [
  ('Tableau', 'board', null),
  ('Liste', 'list', null),
  ('Nouvelle commande', 'new', null),
  ('Reliquats', 'backorders', null),
];
const _deliverySubs = [
  ('Tournées', 'runs', null),
  ('Planifier une tournée', 'new', null),
  ('Tournées types', 'routes', null),
  ('Véhicules', 'vehicles', null),
];
const _pricingSubs = [
  ('Prix spéciaux', 'special', null),
  ('Offres et UG', 'promos', null),
  ('Quotas', 'quotas', null),
];

/// Sidebar order, in six groups. Modules not ready yet are not listed at
/// all rather than shown greyed out.
const _allModules = [
  _Module('dashboard', Icons.grid_view_rounded, 'Tableau de bord', 'Accueil'),
  _Module('explorer', Icons.insights_rounded, 'Explorateur', 'Accueil',
      perm: 'reports'),
  _Module('assistant', Icons.auto_awesome_outlined, 'Assistant', 'Accueil'),
  _Module('pos', Icons.point_of_sale_rounded, 'Caisse', 'Vente'),
  _Module('sales', Icons.receipt_long_outlined, 'Ventes', 'Vente', subs: _salesSubs),
  _Module('orders', Icons.shopping_basket_outlined, 'Commandes clients', 'Vente',
      subs: _orderSubs),
  _Module('deliveries', Icons.route_outlined, 'Livraisons', 'Vente', subs: _deliverySubs),
  _Module('pricing', Icons.sell_outlined, 'Tarifs et offres', 'Vente', subs: _pricingSubs),
  _Module('webstore', Icons.storefront_outlined, 'Boutique en ligne', 'Vente',
      feature: 'feature_webstore'),
  _Module('purchases', Icons.local_shipping_outlined, 'Achats', 'Achat',
      subs: _purchaseSubs),
  _Module('inbox', Icons.document_scanner_outlined, 'Factures scannées',
      'Achat', perm: 'purchases'),
  _Module('products', Icons.category_outlined, 'Produits', 'Stock',
      subs: _productSubs),
  _Module('stock', Icons.inventory_2_outlined, 'Stock', 'Stock', subs: _stockSubs),
  _Module('partners', Icons.people_alt_outlined, 'Clients et fournisseurs', 'Tiers',
      subs: _partnerSubs),
  _Module('crm', Icons.handshake_outlined, 'Relation clients', 'Tiers', subs: _crmSubs),
  _Module('reports', Icons.query_stats_rounded, 'Rapports', 'Pilotage'),
  _Module('designer', Icons.design_services_outlined, 'Modèles', 'Pilotage',
      perm: 'settings'),
  _Module('settings', Icons.settings_outlined, 'Paramètres', 'Pilotage'),
];

const _groupOrder = ['Accueil', 'Vente', 'Achat', 'Stock', 'Tiers', 'Pilotage'];

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.config,
    required this.session,
    required this.onLogout,
    this.openModule,
    this.onSwitchSession,
  });
  final ApiClient api;
  final LocalConfig config;
  final Session session;
  final VoidCallback onLogout;

  /// Module to open first (after « Changer de caissier » → the till).
  final String? openModule;

  /// « Changer de caissier » at the till: the new cashier's session.
  final void Function(Session)? onSwitchSession;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _online = false;
  bool _collapsed = false;
  String _companyName = 'Mon commerce';
  Timer? _healthTimer;
  final _globalSearch = TextEditingController();
  final _productsQuery = ValueNotifier<String>('');

  User get user => widget.session.user;

  /// Modules this user may open (stable: the IndexedStack is built on it).
  late final List<_Module> _visible = [
    for (final m in _allModules)
      if (user.can(m.perm)) m,
  ];

  /// …and of those, the ones the shop profile does not hide.
  bool _shown(_Module m) =>
      m.feature == null || Features.instance.flag(m.feature!);

  final _searchFocus = FocusNode(debugLabel: 'global-search');
  final _newMenuKey = GlobalKey<PopupMenuButtonState<int>>();
  List<AlertItem> _alerts = const [];
  Timer? _alertsTimer;

  Future<void> _loadAlerts() async {
    try {
      final a = await widget.api.alerts();
      if (mounted) setState(() => _alerts = a);
    } catch (_) {}
  }

  void _onFeatures() {
    if (!mounted) return;
    setState(() {
      if (_index < _visible.length && !_shown(_visible[_index])) _index = 0;
    });
  }

  Timer? _presenceTimer;

  /// Dashboard -> explorer handoff: the tile being edited.
  final _explorerRequest = ValueNotifier<ExplorerRequest?>(null);

  @override
  void initState() {
    super.initState();
    UiPrefs.instance.user = user.id;
    // « Mes préférences » → home page chosen by the user.
    final start = UiPrefs.instance.get<String>('prefs', 'start_module');
    final si = start == null ? -1 : _visible.indexWhere((m) => m.key == start);
    if (si >= 0) _index = si;
    final om = widget.openModule == null ? -1 : _visible.indexWhere((m) => m.key == widget.openModule);
    if (om >= 0) _index = om;
    // « Analyser » buttons of the modules open the Explorateur on a seed.
    if (_visible.any((m) => m.key == 'explorer')) {
      AnalysisLinks.open = (spec, {title, origin}) {
        _explorerRequest.value = ExplorerRequest(seed: spec, title: title, origin: origin);
        goTo('explorer');
      };
    }
    Features.instance.addListener(_onFeatures);
    Features.instance.load(widget.api);
    _loadAlerts();
    _alertsTimer =
        Timer.periodic(const Duration(minutes: 2), (_) => _loadAlerts());
    _checkHealth();
    _loadCompany();
    _healthTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _checkHealth());
    _beat();
    _presenceTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _beat());
    _checkUpdate();
    // The web storefront shows the snapshot quantities: we send it a
    // stock heartbeat while the app is running, to limit overselling.
    if (user.can('webstore')) {
      _webstoreTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => _pushWebstoreStock());
    }
    // Web orders: automatic import (if enabled) then push back the statuses
    // of imported orders to the store (customer tracking page).
    if (user.can('orders')) {
      _webOrdersTimer = Timer.periodic(const Duration(minutes: 5), (_) => _webOrdersBeat());
      Timer(const Duration(seconds: 20), _webOrdersBeat);
    }
  }

  Timer? _webstoreTimer;
  Timer? _webOrdersTimer;
  bool _webOrdersRunning = false;

  Future<void> _webOrdersBeat() async {
    if (_webOrdersRunning || !mounted) return;
    _webOrdersRunning = true;
    try {
      await webOrdersHeartbeat(widget.api, canManage: user.isAdmin || user.can('orders.manage'));
    } finally {
      _webOrdersRunning = false;
    }
  }

  Future<void> _pushWebstoreStock() async {
    try {
      final cloud = await widget.api.cloudStatus();
      if (!cloud.webReady || widget.api.token == null) return;
      final levels = await widget.api.stockLevels();
      final qty = <String, int>{};
      for (final l in levels) {
        qty[l.productId] = (qty[l.productId] ?? 0) + l.qtyMilli;
      }
      final client = CloudClient(config: cloud, token: widget.api.token!);
      await client.webPushStock([
        for (final e in qty.entries)
          {'product_id': e.key, 'qty_milli': e.value}
      ]);
    } catch (_) {
      // No store, offline… the next heartbeat will retry.
    }
  }

  /// At startup: if a newer version is published, offer to
  /// install it right away (download + silent reinstall).
  Future<void> _checkUpdate() async {
    final info = await checkForUpdate();
    if (info == null || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        title: Row(children: [
          const Icon(Icons.system_update_alt_rounded,
              size: 20, color: T.mintDeep),
          const SizedBox(width: 10),
          Text('Mise à jour disponible', style: T.h2),
        ]),
        content: Text(
            'La version ${info.version} est disponible (vous avez la '
            '$kAppVersion).\n\nAprès le téléchargement, Windows demandera '
            'une autorisation : cliquez « Oui ». L\'application se fermera, '
            's\'installera et redémarrera toute seule. Terminez les ventes '
            'en cours avant.',
            style: T.body.copyWith(height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Plus tard', style: T.body.copyWith(color: T.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: T.mint, foregroundColor: T.ink),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mettre à jour maintenant'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final status = ValueNotifier<String>('Préparation…');
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        content: Row(children: [
          const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: T.mintDeep)),
          const SizedBox(width: 16),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (context, s, _) => Text(s, style: T.body),
            ),
          ),
        ]),
      ),
    );
    try {
      await downloadAndInstall(info, onStatus: (s) => status.value = s);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Mise à jour impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _presenceTimer?.cancel();
    _webstoreTimer?.cancel();
    _webOrdersTimer?.cancel();
    _alertsTimer?.cancel();
    AnalysisLinks.open = null;
    Features.instance.removeListener(_onFeatures);
    _searchFocus.dispose();
    _globalSearch.dispose();
    _productsQuery.dispose();
    _explorerRequest.dispose();
    super.dispose();
  }

  /// Tells the server this post is alive and which module it shows — feeds
  /// the dashboard's "Postes connectés" card.
  Future<void> _beat() async {
    try {
      await widget.api.presenceBeat(
        device: Platform.localHostname,
        screen: _visible.isEmpty ? '' : _visible[_index].key,
      );
    } catch (_) {}
  }

  Future<void> _checkHealth() async {
    final ok = await widget.api.health();
    if (mounted && ok != _online) setState(() => _online = ok);
  }

  Future<void> _loadCompany() async {
    try {
      final s = await widget.api.settings();
      final name = s['company_name'];
      if (mounted && name != null && name.trim().isNotEmpty) {
        setState(() => _companyName = name.trim());
      }
    } catch (_) {}
  }

  /// Each module has its own navigator: detail / edit pages open INSIDE the
  /// content area, so the menu and the top bar stay visible.
  late final Map<String, GlobalKey<NavigatorState>> _navKeys = {
    for (final m in _visible) m.key: GlobalKey<NavigatorState>(debugLabel: 'nav-${m.key}'),
  };

  /// One command channel per module (sidebar sub-items, « + Nouveau »…).
  late final Map<String, ScreenCommand> _commands = {
    for (final m in _visible) m.key: ScreenCommand(),
  };

  /// Last sub-item used per module, to highlight it in the menu.
  final Map<String, String> _activeSub = {};

  /// Opens a module (back on its list page) and optionally sends it a
  /// command such as `new` or `tab:ledger`.
  void goTo(String key, {String? command}) {
    final i = _visible.indexWhere((m) => m.key == key);
    if (i < 0 || !_shown(_visible[i])) return;
    setState(() {
      _index = i;
      if (command != null) {
        _activeSub[key] = command;
      } else {
        _activeSub.remove(key);
      }
    });
    _navKeys[key]?.currentState?.popUntil((r) => r.isFirst);
    if (command != null) _commands[key]?.send(command);
    _beat();
  }

  /// Pushes a page inside a module's own navigator (after switching to it).
  Future<V?> _pushIn<V>(String key, Route<V> route) async {
    goTo(key);
    await Future<void>.delayed(Duration.zero);
    return _navKeys[key]?.currentState?.push(route);
  }

  /// Sidebar counts from the alerts (`tasks_overdue` → crm, `orders_new` → orders).
  Map<String, int> get _sidebarBadges => {
        for (final a in _alerts)
          if ((a.kind == 'tasks_overdue' || a.kind == 'orders_new') && a.target.isNotEmpty) a.target: a.count,
      };

  /// Sidebar tasks that need more than the module's « voir » right.
  static const _subPerms = {
    'orders/new': 'orders.manage',
    'deliveries/new': 'deliveries.manage',
  };

  bool _subAllowed(String module, String command) {
    final p = _subPerms['$module/$command'];
    return p == null || user.isAdmin || user.can(p);
  }

  bool _canOpen(String key) =>
      _visible.any((m) => m.key == key && _shown(m));

  void _onGlobalSearch(String q) {
    if (q.trim().isEmpty) return;
    goTo('products');
    _productsQuery.value = q.trim();
    _globalSearch.clear();
  }

  /// « Bien démarrer » checklist buttons → the module, on the right task.
  void _openFromChecklist(String key) => switch (key) {
        'products' => goTo('products', command: 'new'),
        'partners' => goTo('partners', command: 'new:supplier'),
        'purchases' => goTo('purchases', command: 'new:PURCHASE_RECEIPT'),
        _ => goTo(key),
      };

  /// Context of a module's navigator, so pages open inside that module.
  BuildContext? _moduleContext(String key) => _navKeys[key]?.currentContext;

  Future<void> _openHit(SearchHit h) async {
    switch (h.kind) {
      case 'product':
        goTo('products');
        await Future<void>.delayed(Duration.zero);
        final c = _moduleContext('products');
        if (c != null && c.mounted) {
          showFicheProduit(c, widget.api, h.product!.id, canCost: user.can('view_cost'));
        }
      case 'partner':
        goTo('partners',
            command: h.partner!.kind == 'supplier' ? 'kind:supplier' : 'kind:customer');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final c = _moduleContext('partners');
        if (c != null && c.mounted) openPartnerDetail(c, widget.api, h.partner!);
      default:
        final d = h.doc!;
        final module = d.docType.startsWith('PURCHASE')
            ? 'purchases'
            : (d.docType.startsWith('STOCK') || d.docType == 'INVENTORY_COUNT')
                ? 'stock'
                : 'sales';
        goTo(_canOpen(module) ? module : 'sales');
        await Future<void>.delayed(Duration.zero);
        final c = _moduleContext(_canOpen(module) ? module : 'sales');
        if (c != null && c.mounted) showDocDetailDialog(c, widget.api, d.id);
    }
  }

  Future<void> _openEditor(DocEditorConfig config) async {
    final module = config.docType.startsWith('PURCHASE')
        ? 'purchases'
        : config.docType.startsWith('STOCK')
            ? 'stock'
            : 'sales';
    await _pushIn(
        _canOpen(module) ? module : _visible[_index].key,
        MaterialPageRoute(
            builder: (_) => DocEditorScreen(api: widget.api, config: config)));
  }

  /// « + Nouveau » : the documents people create most, from any screen.
  List<(String, IconData, String, VoidCallback)> get _newEntries => [
        if (_canOpen('pos'))
          ('Vente au comptoir', Icons.point_of_sale_rounded, 'F2', () => goTo('pos')),
        if (_canOpen('sales')) ...[
          ('Facture de vente', Icons.receipt_long_outlined, '',
              () => goTo('sales', command: 'new:SALE_INVOICE')),
          ('Devis', Icons.request_quote_outlined, '', () => _openEditor(quoteConfig)),
          ('Bon de livraison', Icons.local_shipping_outlined, '',
              () => _openEditor(deliveryNoteConfig)),
        ],
        if (_canOpen('purchases')) ...[
          ('Bon de réception', Icons.move_to_inbox_outlined, '',
              () => goTo('purchases', command: 'new:PURCHASE_RECEIPT')),
          ('Bon de commande', Icons.shopping_cart_checkout_outlined, '',
              () => _openEditor(purchaseOrderConfig)),
        ],
        if (_canOpen('stock')) ...[
          ('Transfert de stock', Icons.swap_horiz_rounded, '',
              () => _openEditor(stockTransferConfig)),
          ('Inventaire', Icons.fact_check_outlined, '',
              () => goTo('stock', command: 'inventory')),
        ],
        if (_canOpen('products'))
          ('Produit', Icons.category_outlined, '',
              () => goTo('products', command: 'new')),
        if (_canOpen('orders') && (user.isAdmin || user.can('orders.manage')))
          ('Commande client', Icons.shopping_basket_outlined, '', () => goTo('orders', command: 'new')),
        if (_canOpen('deliveries') && (user.isAdmin || user.can('deliveries.manage')))
          ('Tournée de livraison', Icons.route_outlined, '', () => goTo('deliveries', command: 'new')),
        if (_canOpen('partners')) ...[
          ('Client', Icons.person_add_alt_outlined, '',
              () => goTo('partners', command: 'new:customer')),
          ('Fournisseur', Icons.store_mall_directory_outlined, '',
              () => goTo('partners', command: 'new:supplier')),
        ],
        if (_canOpen('crm') && (user.isAdmin || user.can('crm.edit')))
          ('Tâche (relation client)', Icons.add_task_rounded, '', () => goTo('crm', command: 'new:task')),
      ];

  Future<void> _logout() async {
    CaisseSession? open;
    try {
      open = await widget.api.caisseCurrent();
    } catch (_) {}
    if (!mounted) return;
    if (open != null) {
      final ok = await confirmAction(context,
          title: 'La caisse est encore ouverte',
          message: 'Ouverte depuis ${open.openedAt.length >= 16 ? open.openedAt.substring(11, 16) : open.openedAt}'
              ' par ${open.userName}. Vous pouvez vous déconnecter : la caisse '
              'reste ouverte pour le prochain caissier. Pensez au rapport Z en fin de journée.',
          confirmLabel: 'Se déconnecter');
      if (!ok) return;
    }
    widget.onLogout();
  }

  Map<ShortcutActivator, VoidCallback> get _bindings => bindingsFor({
        AppShortcuts.search: () => _searchFocus.requestFocus(),
        AppShortcuts.newDoc: () => _newMenuKey.currentState?.showButtonMenu(),
        AppShortcuts.pos: () => goTo('pos'),
        AppShortcuts.help: () => showShortcutsSheet(context),
      });

  Widget _screenFor(_Module m) => switch (m.key) {
        'dashboard' => AnalyticsDashboardScreen(
            api: widget.api,
            session: widget.session,
            onOpenModule: _openFromChecklist,
            onExplore: (req) {
              _explorerRequest.value = req;
              goTo('explorer');
            },
            onEdit: (r) {
              _explorerRequest.value = ExplorerRequest(report: r);
              goTo('explorer');
            },
            onNew: () {
              _explorerRequest.value = null;
              goTo('explorer');
            }),
        'explorer' => AnalyticsExplorerScreen(
            api: widget.api,
            session: widget.session,
            request: _explorerRequest,
            onDone: () => goTo('dashboard')),
        'pos' => PosScreen(
            api: widget.api,
            config: widget.config,
            user: user,
            cashierName:
                user.fullName.isEmpty ? user.username : user.fullName,
            onSwitchUser: widget.onSwitchSession),
        'sales' => SalesScreen(api: widget.api, command: _commands['sales']),
        'purchases' =>
            PurchasesScreen(api: widget.api, command: _commands['purchases']),
        'inbox' => InboxScreen(api: widget.api),
        'stock' => StockScreen(
            api: widget.api, session: widget.session, command: _commands['stock']),
        'products' => ProductsScreen(
            api: widget.api,
            session: widget.session,
            searchRequest: _productsQuery,
            command: _commands['products']),
        'partners' => PartnersScreen(api: widget.api, command: _commands['partners']),
        'orders' => OrdersScreen(api: widget.api, user: user, command: _commands['orders']),
        'deliveries' => DeliveriesScreen(api: widget.api, user: user, command: _commands['deliveries']),
        'pricing' => PricingScreen(api: widget.api, user: user, command: _commands['pricing']),
        'crm' => CrmScreen(
            api: widget.api, command: _commands['crm'], onTasksChanged: (_) => _loadAlerts()),
        'webstore' => WebstoreScreen(api: widget.api),
        'reports' => ReportsScreen(api: widget.api, session: widget.session),
        'assistant' => AssistantScreen(api: widget.api),
        'designer' => DesignerScreen(api: widget.api),
        'settings' => SettingsScreen(
            api: widget.api,
            session: widget.session,
            config: widget.config),
        _ => const SizedBox(),
      };

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _bindings,
      child: Focus(
        autofocus: true,
        child: _buildScaffold(context),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final entries = _newEntries;
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            companyName: _companyName,
            user: user,
            collapsed: _collapsed,
            search: (user.can('products') || user.can('partners') ||
                    user.can('sales') || user.can('purchases'))
                ? GlobalSearch(
                    api: widget.api,
                    focusNode: _searchFocus,
                    onOpen: _openHit,
                    onSubmitProducts: _onGlobalSearch,
                    searchProducts: user.can('products'),
                    searchPartners: user.can('partners'),
                    searchDocuments: user.can('sales') || user.can('purchases'),
                    documentSearch: (q) => widget.api.documents(q: q, limit: 5),
                  )
                : null,
            newMenu: entries.isEmpty
                ? null
                : PopupMenuButton<int>(
                    key: _newMenuKey,
                    tooltip: 'Nouveau (Ctrl+N)',
                    color: T.surface,
                    position: PopupMenuPosition.under,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(T.rInner),
                        side: const BorderSide(color: T.border)),
                    onSelected: (i) => entries[i].$4(),
                    itemBuilder: (_) => [
                      for (var i = 0; i < entries.length; i++)
                        PopupMenuItem<int>(
                          value: i,
                          height: 38,
                          child: Row(children: [
                            Icon(entries[i].$2, size: 17, color: T.muted),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(entries[i].$1,
                                    style: T.body.copyWith(fontSize: 13))),
                            if (entries[i].$3.isNotEmpty)
                              Text(entries[i].$3,
                                  style: T.label.copyWith(fontSize: 12)),
                          ]),
                        ),
                    ],
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: T.ink,
                        borderRadius: BorderRadius.circular(T.rInner),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add_rounded, size: 18, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Nouveau',
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ]),
                    ),
                  ),
            bell: AlertsBell(
              items: _alerts,
              online: _online,
              onRefresh: _loadAlerts,
              onOpenTarget: goTo,
            ),
            onHelp: () => showShortcutsSheet(context),
            onBurger: () => setState(() => _collapsed = !_collapsed),
            onLogout: _logout,
          ),
          const Divider(),
          // Loud offline strip — every till depends on the server PC.
          if (!_online)
            Container(
              width: double.infinity,
              color: T.danger,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
              child: const Row(children: [
                Icon(Icons.wifi_off_rounded, size: 15, color: Colors.white),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'SERVEUR INJOIGNABLE — les ventes sont impossibles. '
                      'Vérifiez que le PC serveur est allumé et connecté au réseau.',
                      style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ]),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  modules: _visible,
                  shown: _shown,
                  index: _index,
                  collapsed: _collapsed,
                  showHelp: user.can('assistant'),
                  activeSub: _activeSub,
                  onSelect: (i) => goTo(_visible[i].key,
                      command: _visible[i].subs.isEmpty ? null : _visible[i].subs.first.$2),
                  onSub: (i, command) => goTo(_visible[i].key, command: command),
                  subAllowed: _subAllowed,
                  onAssistant: () => goTo('assistant'),
                  badges: _sidebarBadges,
                ),
                Expanded(
                  child: Stack(
                    children: [
                      IndexedStack(
                        index: _index,
                        children: [
                          for (final m in _visible)
                            Navigator(
                              key: _navKeys[m.key],
                              onGenerateRoute: (_) => MaterialPageRoute(
                                  builder: (_) => _screenFor(m)),
                            ),
                        ],
                      ),
                      PositionedDirectional(
                        end: 0,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Container(
                            width: 40,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: AlignmentDirectional.centerEnd,
                                end: AlignmentDirectional.centerStart,
                                colors: [
                                  T.mint.withValues(alpha: 0.10),
                                  T.mint.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.companyName,
    required this.user,
    required this.collapsed,
    required this.search,
    required this.newMenu,
    required this.bell,
    required this.onHelp,
    required this.onBurger,
    required this.onLogout,
  });

  final String companyName;
  final User user;
  final bool collapsed;
  final Widget? search;
  final Widget? newMenu;
  final Widget bell;
  final VoidCallback onHelp;
  final VoidCallback onBurger;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      color: T.surface,
      padding: const EdgeInsetsDirectional.only(start: 18, end: 8),
      child: Row(
        children: [
          // The wordmark doubles as the window drag handle now that the
          // native title bar is gone.
          DragToMoveArea(
            child: Row(children: [
              Image.asset('assets/images/elixir-mark.png',
                  height: 30, filterQuality: FilterQuality.medium),
              const SizedBox(width: 8),
              const Text('ELIXIR',
                  style: TextStyle(
                      fontFamily: T.sans,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.4,
                      color: T.ink)),
              const SizedBox(width: 30),
            ]),
          ),
          IconButton(
            onPressed: onBurger,
            tooltip: collapsed ? 'Développer le menu' : 'Réduire le menu',
            icon: const Icon(Icons.menu, size: 19, color: T.muted),
          ),
          const SizedBox(width: 10),
          if (search != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: search,
            ),
          if (newMenu != null) ...[
            const SizedBox(width: 10),
            newMenu!,
          ],
          // The empty middle drags the window too.
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          IconButton(
            tooltip: 'Raccourcis clavier (F1)',
            onPressed: onHelp,
            icon: const Icon(Icons.keyboard_outlined, size: 19, color: T.muted),
          ),
          bell,
          const SizedBox(width: 12),
          PopupMenuButton<String>(
            tooltip: 'Compte',
            color: T.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(T.rInner)),
            onSelected: (v) {
              if (v == 'logout') onLogout();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(companyName, style: T.h2.copyWith(fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text(
                        '${user.fullName.isEmpty ? user.username : user.fullName} · ${user.roleLabel}',
                        style: T.small),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  const Icon(Icons.logout_rounded,
                      size: 15, color: T.dangerDark),
                  const SizedBox(width: 8),
                  Text('Se déconnecter',
                      style: T.body.copyWith(color: T.dangerDark)),
                ]),
              ),
            ],
            child: Row(children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                      user.fullName.isEmpty ? user.username : user.fullName,
                      style: const TextStyle(
                          fontFamily: T.sans,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: T.ink)),
                  Text(user.roleLabel,
                      style: T.small.copyWith(fontSize: 12.5)),
                ],
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, size: 18, color: T.faint),
            ]),
          ),
          const SizedBox(width: 10),
          // Window controls — we own the chrome now.
          _WinBtn(
            icon: Icons.remove,
            tooltip: 'Réduire',
            onTap: () => windowManager.minimize(),
          ),
          _WinBtn(
            icon: Icons.crop_square,
            tooltip: 'Agrandir',
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinBtn(
            icon: Icons.close,
            tooltip: 'Fermer',
            danger: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _WinBtn extends StatefulWidget {
  const _WinBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 40,
            height: 62,
            color: _hover
                ? (widget.danger ? T.danger : T.bg)
                : Colors.transparent,
            child: Icon(widget.icon,
                size: 16,
                color: _hover && widget.danger ? Colors.white : T.muted),
          ),
        ),
      ),
    );
  }
}

/// Sidebar in six folding groups (Accueil, Vente, Achat, Stock, Tiers,
/// Pilotage). The group holding the current screen is always open; the
/// folded state is remembered per user. Collapsed = icons only.
class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.modules,
    required this.shown,
    required this.index,
    required this.collapsed,
    required this.showHelp,
    required this.activeSub,
    required this.onSelect,
    required this.onSub,
    required this.onAssistant,
    this.badges = const {},
    this.subAllowed,
  });

  /// False hides a task of a module (right missing).
  final bool Function(String module, String command)? subAllowed;

  /// Red count next to a module (overdue tasks, orders to validate…).
  final Map<String, int> badges;
  final List<_Module> modules;
  final bool Function(_Module) shown;
  final int index;
  final bool collapsed;
  final bool showHelp;
  final Map<String, String> activeSub;
  final ValueChanged<int> onSelect;
  final void Function(int index, String command) onSub;
  final VoidCallback onAssistant;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  late final Set<String> _folded =
      (UiPrefs.instance.getList('shell', 'folded_groups') ?? const []).toSet();

  void _toggle(String g) {
    setState(() => _folded.contains(g) ? _folded.remove(g) : _folded.add(g));
    UiPrefs.instance.set('shell', 'folded_groups', _folded.toList());
  }

  /// The module row, followed (when it is the open module) by its tasks.
  Widget _item(int i) {
    final item = widget.modules[i];
    final selected = i == widget.index;
    final subs = [
      for (final s in item.subs)
        if ((s.$3 == null || Features.instance.flag(s.$3!)) &&
            (widget.subAllowed?.call(item.key, s.$2) ?? true))
          s,
    ];
    if (!selected || widget.collapsed || subs.isEmpty) return _moduleRow(i);
    final active = widget.activeSub[item.key] ?? subs.first.$2;
    return Column(children: [
      _moduleRow(i),
      for (final s in subs)
        InkWell(
          onTap: () => widget.onSub(i, s.$2),
          child: Container(
            height: 36,
            padding: const EdgeInsetsDirectional.only(start: 46, end: 10),
            alignment: AlignmentDirectional.centerStart,
            child: Row(children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: active == s.$2 ? T.mint : T.border3,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s.$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: T.sans,
                      fontSize: 13.5,
                      fontWeight: active == s.$2 ? FontWeight.w700 : FontWeight.w500,
                      color: active == s.$2 ? T.ink : T.muted,
                    )),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 4),
    ]);
  }

  Widget _moduleRow(int i) {
    final item = widget.modules[i];
    final selected = i == widget.index;
    final color = selected ? T.mintDeep : T.muted;
    return InkWell(
      onTap: () => widget.onSelect(i),
      child: Container(
        height: 42,
        color: selected ? T.mintTint : Colors.transparent,
        child: Row(children: [
          Container(width: 3, color: selected ? T.mint : Colors.transparent),
          SizedBox(width: widget.collapsed ? 0 : 15),
          Expanded(
            child: widget.collapsed
                ? Tooltip(
                    message: item.title,
                    child: Icon(item.icon, size: 18, color: color),
                  )
                : Row(children: [
                    Icon(item.icon, size: 17, color: color),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 14,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ),
                    if ((widget.badges[item.key] ?? 0) > 0)
                      Container(
                        margin: const EdgeInsetsDirectional.only(end: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(color: T.danger, borderRadius: BorderRadius.circular(999)),
                        child: Text('${widget.badges[item.key]}',
                            style: const TextStyle(
                                fontFamily: T.sans, fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.index < widget.modules.length
        ? widget.modules[widget.index].group
        : '';
    final children = <Widget>[];
    for (final g in _groupOrder) {
      final idx = [
        for (var i = 0; i < widget.modules.length; i++)
          if (widget.modules[i].group == g && widget.shown(widget.modules[i])) i,
      ];
      if (idx.isEmpty) continue;
      final open = !_folded.contains(g) || g == current;
      if (widget.collapsed) {
        if (children.isNotEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Divider(),
          ));
        }
        children.addAll(idx.map(_item));
        continue;
      }
      children.add(InkWell(
        onTap: g == current ? null : () => _toggle(g),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 12, 4),
          child: Row(children: [
            Expanded(child: MicroLabel(g)),
            if (g != current)
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 15, color: T.ghost),
          ]),
        ),
      ));
      if (open) children.addAll(idx.map(_item));
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: widget.collapsed ? 62 : 230,
      decoration: const BoxDecoration(
        color: T.surface,
        border: BorderDirectional(end: BorderSide(color: T.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 4),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: children),
          ),
          if (!widget.collapsed && widget.showHelp)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: T.mintTint,
                borderRadius: BorderRadius.circular(T.rCard),
              ),
              child: Row(children: [
                const Icon(Icons.auto_awesome_outlined, size: 18, color: T.mintDark),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text("Besoin d'aide ?",
                      style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: T.ink)),
                ),
                TextButton(
                  onPressed: widget.onAssistant,
                  child: const Text('Assistant', style: TextStyle(fontSize: 13)),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
