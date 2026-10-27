import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/prefs.dart';
import '../widgets/ui.dart';
import 'webstore/alerts_section.dart';
import 'webstore/appearance_section.dart';
import 'webstore/catalog_sync.dart';
import 'webstore/claim_pane.dart';
import 'webstore/delivery_section.dart';
import 'webstore/domain_section.dart';
import 'webstore/home_section.dart';
import 'webstore/media_section.dart';
import 'webstore/mode_section.dart';
import 'webstore/overview_section.dart';
import 'webstore/pages_section.dart';
import 'webstore/photos_section.dart';
import 'webstore/products_tab.dart';
import 'webstore/promos_section.dart';
import 'webstore/seo_section.dart';
import 'webstore/stats_section.dart';
import 'webstore/web_common.dart';
import 'webstore/web_orders_tab.dart';

export 'webstore/web_common.dart' show webField;

/// « Boutique en ligne » — the shop's `slug.shops.example.com` storefront.
/// The catalogue leaves from here as a SNAPSHOT (the site lives on with the PC off) and
/// web orders come back here by pull, like scanned invoices.
///
/// Left: the module's own menu (sections grouped like Paramètres) with the
/// two always-visible actions « Voir la boutique » and « Publier le
/// catalogue »; right: the chosen section.
class WebstoreScreen extends StatefulWidget {
  const WebstoreScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<WebstoreScreen> createState() => _WebstoreScreenState();
}

class _Entry {
  const _Entry(this.id, this.group, this.title, this.icon);
  final String id;
  final String group;
  final String title;
  final IconData icon;
}

const _entries = [
  _Entry('overview', 'Ma boutique', 'Vue d’ensemble', Icons.storefront_outlined),
  _Entry('orders', 'Ma boutique', 'Commandes', Icons.shopping_bag_outlined),
  _Entry('products', 'Ma boutique', 'Produits', Icons.inventory_2_outlined),
  _Entry('photos', 'Ma boutique', 'Photos produits', Icons.photo_library_outlined),
  _Entry('alerts', 'Ma boutique', 'Alertes stock', Icons.notifications_active_outlined),
  _Entry('stats', 'Ma boutique', 'Statistiques', Icons.bar_chart_rounded),
  _Entry('appearance', 'Le site', 'Apparence', Icons.palette_outlined),
  _Entry('home', 'Le site', 'Page d’accueil', Icons.view_agenda_outlined),
  _Entry('media', 'Le site', 'Images', Icons.image_outlined),
  _Entry('pages', 'Le site', 'Pages', Icons.article_outlined),
  _Entry('seo', 'Le site', 'Référencement', Icons.travel_explore_rounded),
  _Entry('domain', 'Le site', 'Domaine', Icons.language_rounded),
  _Entry('mode', 'La vente', 'Mode de vente', Icons.sell_outlined),
  _Entry('delivery', 'La vente', 'Livraison', Icons.local_shipping_outlined),
  _Entry('promos', 'La vente', 'Promotions', Icons.local_offer_outlined),
];

class _WebstoreScreenState extends State<WebstoreScreen> {
  bool _loading = true;
  String? _error;
  CloudConfig? _cloud;
  WebStore? _store;
  CloudClient? _clientCache;
  late String _section = _entries
      .firstWhere((e) => e.id == UiPrefs.instance.get<String>('webstore', 'section'),
          orElse: () => _entries.first)
      .id;

  CloudClient get _client =>
      _clientCache ??= CloudClient(config: _cloud!, token: widget.api.token!);

  @override
  void initState() {
    super.initState();
    WebCtx.resetCaches();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _store == null;
      _error = null;
    });
    try {
      final cloud = await widget.api.cloudStatus();
      _cloud = cloud;
      _clientCache = null;
      if (cloud.webReady) _store = await _client.webStore();
    } catch (e) {
      _error = errText(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reloadStore() async {
    try {
      final s = await _client.webStore();
      if (mounted && s != null) setState(() => _store = s);
    } catch (_) {}
  }

  void _open(String id) {
    setState(() => _section = id);
    UiPrefs.instance.set('webstore', 'section', id);
  }

  // ---------------- snapshot publish (+ photos) ----------------

  Future<void> _publish() async {
    final step = ValueNotifier<(String, int, int)>(('Envoi du catalogue…', 0, 0));
    var cancel = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        title: const Text('Publication du catalogue', style: T.h2),
        content: SizedBox(
          width: 420,
          child: ValueListenableBuilder<(String, int, int)>(
            valueListenable: step,
            builder: (context, s, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.$3 > 0 ? '${s.$1} : ${s.$2} / ${s.$3}' : s.$1,
                      style: T.body),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                      value: s.$3 > 0 ? s.$2 / s.$3 : null,
                      color: T.mintDeep,
                      backgroundColor: T.border2),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => cancel = true,
              child: const Text('Arrêter les photos')),
        ],
      ),
    );
    void close() {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    int n;
    try {
      n = await publishCatalogSnapshot(widget.api, _client);
    } catch (e) {
      close();
      if (mounted) toastError(context, 'Publication impossible', e);
      return;
    }
    PhotoSyncResult? photos;
    String? photoError;
    try {
      photos = await syncProductPhotos(widget.api, _client,
          onProgress: (s, d, t) => step.value = (s, d, t),
          cancelled: () => cancel);
      lastPhotoSync = photos;
    } catch (e) {
      photoError = errText(e);
    }
    close();
    await _reloadStore();
    if (!mounted) return;
    final photoText = photoError != null
        ? ' Photos non envoyées : $photoError'
        : (photos == null ? '' : ' Photos : ${photos.summary}');
    final hasErr = photoError != null || (photos?.errors.isNotEmpty ?? false);
    showToast(context, '$n produits publiés sur la boutique.$photoText',
        kind: hasErr ? ToastKind.warning : ToastKind.success,
        actionLabel: hasErr ? 'Voir les photos' : 'Voir la boutique',
        onAction: hasErr
            ? () => _open('photos')
            : () => openWebUrl(_store?.publicUrl ?? ''));
  }

  Widget _sectionFor(WebCtx ctx) => switch (_section) {
        'orders' => WebOrdersTab(
            api: widget.api, client: _client, onAcked: _reloadStore),
        'products' => WebProductsTab(ctx: ctx),
        'photos' => PhotosSection(ctx: ctx),
        'alerts' => AlertsSection(ctx: ctx),
        'stats' => StatsSection(ctx: ctx),
        'appearance' => AppearanceSection(ctx: ctx),
        'home' => HomeSection(ctx: ctx),
        'media' => MediaSection(ctx: ctx),
        'pages' => PagesSection(ctx: ctx),
        'seo' => SeoSection(ctx: ctx),
        'domain' => DomainSection(ctx: ctx),
        'mode' => ModeSection(ctx: ctx),
        'delivery' => DeliverySection(ctx: ctx),
        'promos' => PromosSection(ctx: ctx),
        _ => OverviewSection(ctx: ctx),
      };

  @override
  Widget build(BuildContext context) {
    if (_loading) return webSpinner;
    if (_error != null) {
      return WebNotice(
          icon: Icons.cloud_off_rounded,
          title: 'Service boutique injoignable',
          body: _error!,
          action: ('Réessayer', _load));
    }
    if (_cloud == null || !_cloud!.webReady) {
      return WebNotice(
          icon: Icons.cloud_outlined,
          title: 'Connectez d\'abord le magasin au cloud',
          body: 'La boutique en ligne utilise la connexion cloud du magasin. '
              'Ouvrez Paramètres → Cloud et téléphone et cliquez « Connecter le '
              'magasin », puis revenez ici.',
          action: ('Vérifier à nouveau', _load));
    }
    if (_store == null) {
      return ClaimPane(
          client: _client, onClaimed: (s) => setState(() => _store = s));
    }
    final store = _store!;
    final ctx = WebCtx(
      api: widget.api,
      client: _client,
      store: store,
      onStore: (s) => setState(() => _store = s),
      reload: _reloadStore,
      publish: _publish,
      open: _open,
    );
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _menu(store),
      Expanded(
        child: KeyedSubtree(key: ValueKey(_section), child: _sectionFor(ctx)),
      ),
    ]);
  }

  Widget _menu(WebStore store) {
    final paused = store.status != 'active';
    int? badge(String id) => switch (id) {
          'orders' => store.pendingOrders,
          'alerts' => store.openAlerts,
          _ => null,
        };
    final groups = <String, List<_Entry>>{};
    for (final e in _entries) {
      groups.putIfAbsent(e.group, () => []).add(e);
    }
    return Container(
      width: 270,
      decoration: const BoxDecoration(
        color: T.surface,
        border: BorderDirectional(end: BorderSide(color: T.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 4),
          child: Text(store.name.isEmpty ? 'Boutique en ligne' : store.name,
              style: T.h2.copyWith(fontSize: 18),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
          child: Row(children: [
            StatusPill(
                switch (store.status) {
                  'paused' => 'En pause',
                  'suspended' => 'Suspendue',
                  _ => 'Ouverte',
                },
                kind: paused ? ToastKind.warning : ToastKind.success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  Uri.tryParse(store.publicUrl)?.host ?? store.publicUrl,
                  style: T.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PrimaryButton(label: 'Publier le catalogue', onPressed: _publish),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                  foregroundColor: T.ink,
                  side: const BorderSide(color: T.border3)),
              onPressed: () => openWebUrl(store.publicUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Voir la boutique'),
            ),
          ]),
        ),
        const Divider(),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Text(g.key, style: T.label),
              ),
              for (final e in g.value)
                InkWell(
                  onTap: () => _open(e.id),
                  child: Container(
                    color: e.id == _section ? T.mintTint : Colors.transparent,
                    padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
                    child: Row(children: [
                      Icon(e.icon,
                          size: 19,
                          color: e.id == _section ? T.mintDeep : T.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(e.title,
                            style: T.body.copyWith(
                                fontSize: 14,
                                fontWeight: e.id == _section
                                    ? FontWeight.w700
                                    : FontWeight.w600)),
                      ),
                      if ((badge(e.id) ?? 0) > 0)
                        MintChip('${badge(e.id)}',
                            color: T.danger, fg: Colors.white),
                    ]),
                  ),
                ),
            ],
          ]),
        ),
      ]),
    );
  }
}
