import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../api/models.dart';
import '../screens/assistant_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/designer_screen.dart';
import '../screens/inbox_screen.dart';
import '../screens/partners_screen.dart';
import '../screens/pos_screen.dart';
import '../screens/products_screen.dart';
import '../screens/purchases_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/sales_screen.dart';
import '../screens/sav_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/stock_screen.dart';
import '../screens/webstore_screen.dart';
import '../theme/tokens.dart';
import '../util/config.dart';
import '../util/updater.dart';
import '../widgets/ui.dart';

class _Module {
  const _Module(this.key, this.icon, this.title, {this.enabled = true, String? perm})
      : perm = perm ?? key;
  final String key; // which screen to build
  final String perm; // permission that reveals it (defaults to key)
  final IconData icon;
  final String title;
  final bool enabled;
}

const _allModules = [
  _Module('dashboard', Icons.grid_view_rounded, 'Tableau de bord'),
  _Module('pos', Icons.point_of_sale_rounded, 'Caisse'),
  _Module('sales', Icons.receipt_long_outlined, 'Ventes'),
  _Module('purchases', Icons.local_shipping_outlined, 'Achats'),
  _Module('inbox', Icons.document_scanner_outlined, 'Factures scannées',
      perm: 'purchases'),
  _Module('stock', Icons.inventory_2_outlined, 'Stock'),
  _Module('products', Icons.category_outlined, 'Produits'),
  _Module('partners', Icons.people_alt_outlined, 'Partenaires'),
  _Module('sav', Icons.build_outlined, 'Réparations'),
  _Module('webstore', Icons.storefront_outlined, 'Boutique en ligne'),
  _Module('reports', Icons.query_stats_rounded, 'Rapports'),
  _Module('assistant', Icons.auto_awesome_outlined, 'Assistant'),
  _Module('delivery', Icons.rocket_launch_outlined, 'Livraison', enabled: false),
  _Module('designer', Icons.design_services_outlined, 'Modèles',
      perm: 'settings'),
  _Module('settings', Icons.settings_outlined, 'Paramètres'),
];

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.api,
    required this.config,
    required this.session,
    required this.onLogout,
  });
  final ApiClient api;
  final LocalConfig config;
  final Session session;
  final VoidCallback onLogout;

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

  late final List<_Module> _visible = [
    for (final m in _allModules)
      if (m.key == 'delivery' || user.can(m.perm)) m,
  ];

  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    _checkHealth();
    _loadCompany();
    _healthTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _checkHealth());
    _beat();
    _presenceTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _beat());
    _checkUpdate();
    // La vitrine web affiche les quantités du snapshot : on lui envoie un
    // battement de stock tant que l'app tourne, pour limiter les surventes.
    if (user.can('webstore')) {
      _webstoreTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => _pushWebstoreStock());
    }
  }

  Timer? _webstoreTimer;

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
      // Pas de boutique, hors ligne… le prochain battement réessaiera.
    }
  }

  /// Au démarrage : si une version plus récente est publiée, on propose de
  /// l'installer tout de suite (téléchargement + réinstallation silencieuse).
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
    _globalSearch.dispose();
    _productsQuery.dispose();
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

  void goTo(String key) {
    final i = _visible.indexWhere((m) => m.key == key);
    if (i >= 0 && _visible[i].enabled) {
      setState(() => _index = i);
      _beat();
    }
  }

  void _onGlobalSearch(String q) {
    if (q.trim().isEmpty) return;
    goTo('products');
    _productsQuery.value = q.trim();
    _globalSearch.clear();
  }

  Widget _screenFor(_Module m) => switch (m.key) {
        'dashboard' => DashboardScreen(
            api: widget.api, session: widget.session, onNavigate: goTo),
        'pos' => PosScreen(
            api: widget.api,
            config: widget.config,
            user: user,
            cashierName:
                user.fullName.isEmpty ? user.username : user.fullName),
        'sales' => SalesScreen(api: widget.api),
        'purchases' => PurchasesScreen(api: widget.api),
        'inbox' => InboxScreen(api: widget.api),
        'stock' => StockScreen(api: widget.api, session: widget.session),
        'products' => ProductsScreen(
            api: widget.api,
            session: widget.session,
            searchRequest: _productsQuery),
        'partners' => PartnersScreen(api: widget.api),
        'sav' => SavScreen(api: widget.api),
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
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            online: _online,
            companyName: _companyName,
            user: user,
            collapsed: _collapsed,
            showSearch: user.can('products'),
            searchCtrl: _globalSearch,
            onSearch: _onGlobalSearch,
            onBurger: () => setState(() => _collapsed = !_collapsed),
            onLogout: widget.onLogout,
          ),
          const Divider(),
          // Loud offline strip — every caisse depends on the server PC.
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
                  index: _index,
                  collapsed: _collapsed,
                  showHelp: user.can('assistant'),
                  onSelect: (i) => setState(() => _index = i),
                  onAssistant: () => goTo('assistant'),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      IndexedStack(
                        index: _index,
                        children: [for (final m in _visible) _screenFor(m)],
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
    required this.online,
    required this.companyName,
    required this.user,
    required this.collapsed,
    required this.showSearch,
    required this.searchCtrl,
    required this.onSearch,
    required this.onBurger,
    required this.onLogout,
  });

  final bool online;
  final String companyName;
  final User user;
  final bool collapsed;
  final bool showSearch;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;
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
                      fontSize: 13,
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
          if (showSearch)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: searchCtrl,
                  onSubmitted: onSearch,
                  style: T.body,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Rechercher un produit, code-barres…',
                    hintStyle: T.bodyMuted.copyWith(color: T.ghost),
                    prefixIcon:
                        const Icon(Icons.search, size: 17, color: T.faint),
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
          // The empty middle drags the window too.
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          Tooltip(
            message: online ? 'Serveur connecté' : 'Serveur hors ligne',
            child: Stack(children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.notifications_none_rounded,
                    size: 20, color: T.muted),
              ),
              PositionedDirectional(
                end: 7,
                top: 7,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: online ? T.mint : T.danger,
                    shape: BoxShape.circle,
                    border: Border.all(color: T.surface, width: 1.5),
                  ),
                ),
              ),
            ]),
          ),
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
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: T.ink)),
                  Text(user.roleLabel,
                      style: T.small.copyWith(fontSize: 11)),
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.modules,
    required this.index,
    required this.collapsed,
    required this.showHelp,
    required this.onSelect,
    required this.onAssistant,
  });
  final List<_Module> modules;
  final int index;
  final bool collapsed;
  final bool showHelp;
  final ValueChanged<int> onSelect;
  final VoidCallback onAssistant;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: collapsed ? 62 : 230,
      decoration: const BoxDecoration(
        color: T.surface,
        border: BorderDirectional(end: BorderSide(color: T.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: modules.length,
              itemBuilder: (context, i) {
                final item = modules[i];
                final selected = i == index;
                return InkWell(
                  onTap: item.enabled ? () => onSelect(i) : null,
                  child: Container(
                    height: 44,
                    color: selected ? T.mintTint : Colors.transparent,
                    child: Row(children: [
                      Container(
                        width: 3,
                        color: selected ? T.mint : Colors.transparent,
                      ),
                      SizedBox(width: collapsed ? 0 : 15),
                      Expanded(
                        child: collapsed
                            ? Tooltip(
                                message: item.title,
                                child: Icon(item.icon,
                                    size: 18,
                                    color: !item.enabled
                                        ? T.ghost
                                        : selected
                                            ? T.mintDeep
                                            : T.muted),
                              )
                            : Row(children: [
                                Icon(item.icon,
                                    size: 17,
                                    color: !item.enabled
                                        ? T.ghost
                                        : selected
                                            ? T.mintDeep
                                            : T.muted),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontFamily: T.sans,
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: !item.enabled
                                          ? T.ghost
                                          : selected
                                              ? T.mintDeep
                                              : T.muted,
                                    ),
                                  ),
                                ),
                                if (!item.enabled)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                        end: 10),
                                    child: MintChip('bientôt',
                                        color: T.cream, fg: T.faint),
                                  ),
                              ]),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
          if (!collapsed && showHelp)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: T.mintTint,
                borderRadius: BorderRadius.circular(T.rCard),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Besoin d'aide ?",
                      style: TextStyle(
                          fontFamily: T.sans,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: T.ink)),
                  const SizedBox(height: 4),
                  Text("Consultez notre guide ou contactez l'assistant.",
                      style: T.small.copyWith(fontSize: 11.5, height: 1.35)),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 34,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: T.surface,
                        foregroundColor: T.ink,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(T.rInner)),
                      ),
                      onPressed: onAssistant,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text("Ouvrir l'assistant",
                              style: TextStyle(
                                  fontFamily: T.sans,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded, size: 13),
                        ],
                      ),
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
