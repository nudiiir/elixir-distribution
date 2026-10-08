import 'dart:io';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import '../widgets/ui.dart';

/// A plain vertical field: label above (red « * » when required), the
/// input, then an optional helper line.
Widget webField(
  String label,
  TextEditingController c, {
  bool required = false,
  String? hint,
  String? help,
  String? suffix,
  int maxLines = 1,
  ValueChanged<String>? onChanged,
}) {
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text.rich(TextSpan(text: label, style: T.label, children: [
      if (required)
        const TextSpan(text: ' *', style: TextStyle(color: T.danger)),
    ])),
    const SizedBox(height: 6),
    TextField(
      controller: c,
      style: T.body,
      maxLines: maxLines,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: T.bodyMuted.copyWith(color: T.ghost),
        suffixText: suffix,
        filled: true,
        fillColor: T.bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.mintDeep, width: 1.4)),
      ),
    ),
    if (help != null) ...[
      const SizedBox(height: 4),
      Text(help, style: T.small),
    ],
  ]);
}


/// « Boutique en ligne » — la vitrine `slug.shops.example.com` du magasin.
/// Le catalogue part d'ici en SNAPSHOT (le site vit même PC éteint) et les
/// commandes web reviennent ici en pull, comme les factures scannées.
class WebstoreScreen extends StatefulWidget {
  const WebstoreScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<WebstoreScreen> createState() => _WebstoreScreenState();
}

void _openInBrowser(String url) {
  Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
}

class _WebstoreScreenState extends State<WebstoreScreen> {
  bool _loading = true;
  String? _error;
  CloudConfig? _cloud;
  WebStore? _store;
  int _tab = 0;

  CloudClient get _client =>
      CloudClient(config: _cloud!, token: widget.api.token!);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cloud = await widget.api.cloudStatus();
      _cloud = cloud;
      if (cloud.webReady) {
        _store = await CloudClient(config: cloud, token: widget.api.token!)
            .webStore();
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---------------- snapshot publish ----------------

  Future<void> _publish() async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        backgroundColor: T.surface,
        content: Row(children: [
          SizedBox(
              width: 22,
              height: 22,
              child:
                  CircularProgressIndicator(strokeWidth: 2.4, color: T.mintDeep)),
          SizedBox(width: 16),
          Text('Publication du catalogue…', style: T.body),
        ]),
      ),
    );
    try {
      final products = await widget.api.allProducts();
      final levels = await widget.api.stockLevels();
      final catList = await widget.api.categories();
      final cats = {for (final c in catList) c.id: c};
      final qty = <String, int>{};
      for (final l in levels) {
        qty[l.productId] = (qty[l.productId] ?? 0) + l.qtyMilli;
      }
      final snapshot = [
        for (final p in products)
          {
            'id': p.id,
            'name': p.name,
            'name_ar': p.nameAr,
            'barcode': p.barcode,
            'category':
                p.categoryId == null ? null : cats[p.categoryId]?.name,
            // Parent category feeds the two-level navigation of the site.
            'category_parent': p.categoryId == null
                ? null
                : cats[cats[p.categoryId]?.parentId]?.name,
            'unit': p.unit,
            'is_weighable': p.isWeighable,
            'price_centimes': p.priceRetail,
            'promo_price_centimes': p.promoActive ? p.promoPrice : null,
            'promo_end': p.promoActive ? p.promoEnd : null,
            'qty_milli': qty[p.id] ?? 0,
            'description': p.description,
            'warranty_months': p.warrantyMonths,
            'parent_product_id': p.parentProductId,
            'variant_label': p.variantLabel,
          }
      ];
      final n = await _client.webPublishCatalog(snapshot);
      _store = await _client.webStore();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      showToast(context, '$n produits publiés sur la boutique.',
          actionLabel: 'Voir la boutique',
          onAction: () => _openInBrowser(_store!.url));
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Publication impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.6, color: T.mintDeep));
    }
    if (_error != null) {
      return _Notice(
          icon: Icons.cloud_off_rounded,
          title: 'Service boutique injoignable',
          body: _error!,
          action: ('Réessayer', _load));
    }
    if (_cloud == null || !_cloud!.webReady) {
      return _Notice(
          icon: Icons.cloud_outlined,
          title: 'Connectez d\'abord le magasin au cloud',
          body:
              'La boutique en ligne utilise la connexion cloud du magasin. '
              'Ouvrez Paramètres → Services cloud et cliquez « Connecter le '
              'magasin », puis revenez ici.',
          action: ('Vérifier à nouveau', _load));
    }
    if (_store == null) {
      return _ClaimPane(client: _client, onClaimed: (s) {
        setState(() => _store = s);
      });
    }

    return Column(children: [
      Container(
        color: T.surface,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: [
          for (final (i, label) in const [
            (0, 'Boutique'),
            (1, 'Produits'),
            (2, 'Commandes'),
          ])
            InkWell(
              onTap: () => setState(() => _tab = i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          width: 2.4,
                          color: _tab == i ? T.mint : Colors.transparent)),
                ),
                child: Row(children: [
                  Text(label,
                      style: TextStyle(
                        fontFamily: T.sans,
                        fontSize: 14.5,
                        fontWeight:
                            _tab == i ? FontWeight.w800 : FontWeight.w600,
                        color: _tab == i ? T.ink : T.muted,
                      )),
                  if (i == 2 && _store!.pendingOrders > 0) ...[
                    const SizedBox(width: 7),
                    MintChip('${_store!.pendingOrders}',
                        color: T.danger, fg: Colors.white),
                  ],
                ]),
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _openInBrowser(_store!.url),
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: const Text('Voir la boutique'),
          ),
          const SizedBox(width: 8),
          PrimaryButton(
              label: 'Publier le catalogue',
              onPressed: _publish),
        ]),
      ),
      const Divider(),
      Expanded(
        child: switch (_tab) {
          0 => _ConfigPane(
              key: ValueKey('cfg-${_store!.slug}'),
              client: _client,
              store: _store!,
              onSaved: (s) => setState(() => _store = s)),
          1 => _ProductsPane(client: _client, onPublish: _publish),
          _ => _OrdersPane(api: widget.api, client: _client, onAcked: _load),
        },
      ),
    ]);
  }
}

// ---------------- shared bits ----------------

class _Notice extends StatelessWidget {
  const _Notice(
      {required this.icon,
      required this.title,
      required this.body,
      this.action});
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card14(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 36, color: T.faint),
            const SizedBox(height: 12),
            Text(title, style: T.h2, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body,
                style: T.bodyMuted.copyWith(height: 1.5),
                textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 14),
              PrimaryButton(label: action!.$1, onPressed: action!.$2),
            ],
          ]),
        ),
      ),
    );
  }
}

// ---------------- claim ----------------

class _ClaimPane extends StatefulWidget {
  const _ClaimPane({required this.client, required this.onClaimed});
  final CloudClient client;
  final ValueChanged<WebStore> onClaimed;

  @override
  State<_ClaimPane> createState() => _ClaimPaneState();
}

class _ClaimPaneState extends State<_ClaimPane> {
  final _slug = TextEditingController();
  final _name = TextEditingController();
  String? _hint;
  bool? _available;
  bool _busy = false;

  @override
  void dispose() {
    _slug.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final slug = _slug.text.trim().toLowerCase();
    if (slug.isEmpty) return;
    setState(() {
      _busy = true;
      _hint = null;
      _available = null;
    });
    try {
      final (ok, reason) = await widget.client.webCheckSlug(slug);
      _available = ok;
      _hint = ok ? 'Disponible !' : (reason ?? 'Déjà pris.');
    } catch (e) {
      _hint = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _claim() async {
    final slug = _slug.text.trim().toLowerCase();
    final name = _name.text.trim();
    if (slug.isEmpty || name.isEmpty) {
      setState(() => _hint = 'Choisissez une adresse ET un nom de boutique.');
      return;
    }
    setState(() => _busy = true);
    try {
      final store = await widget.client.webClaim(slug, name);
      widget.onClaimed(store);
    } catch (e) {
      if (mounted) {
        setState(() {
          _hint = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card14(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.storefront_rounded, size: 38, color: T.mintDeep),
            const SizedBox(height: 10),
            Text('Créez la boutique en ligne du magasin', style: T.h2),
            const SizedBox(height: 6),
            Text(
                'Votre stock devient un site web où vos clients commandent '
                '(paiement à la livraison). Le site reste en ligne même quand '
                'ce PC est éteint.',
                style: T.bodyMuted.copyWith(height: 1.5),
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            webField('Nom de la boutique', _name,
                required: true, help: 'Affiché en haut du site.'),
            const SizedBox(height: 12),
            webField(
              'Adresse du site',
              _slug,
              required: true,
              hint: 'mon-magasin',
              suffix: '.shops.example.com',
              help: 'Lettres minuscules, chiffres et tirets.',
              onChanged: (_) => setState(() {
                _available = null;
                _hint = null;
              }),
            ),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_hint!,
                    style: T.small.copyWith(
                        color: _available == true ? T.mintDeep : T.dangerDark,
                        fontWeight: FontWeight.w700)),
              ),
            ],
            const SizedBox(height: 16),
            Row(children: [
              OutlinedButton(
                  onPressed: _busy ? null : _check,
                  child: const Text('Vérifier la disponibilité')),
              const Spacer(),
              PrimaryButton(
                  label: _busy ? '…' : 'Créer ma boutique',
                  onPressed: _busy ? null : _claim),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ---------------- config / theme ----------------

class _ConfigPane extends StatefulWidget {
  const _ConfigPane(
      {super.key,
      required this.client,
      required this.store,
      required this.onSaved});
  final CloudClient client;
  final WebStore store;
  final ValueChanged<WebStore> onSaved;

  @override
  State<_ConfigPane> createState() => _ConfigPaneState();
}

const _palette = [
  '#00A87C', '#2563EB', '#D97706', '#DC2626', '#7C3AED', '#0F766E', '#0F1113',
];

class _ConfigPaneState extends State<_ConfigPane> {
  late final _name = TextEditingController(text: widget.store.name);
  late final _about =
      TextEditingController(text: '${widget.store.theme['about'] ?? ''}');
  late final _announce =
      TextEditingController(text: '${widget.store.theme['announcement'] ?? ''}');
  late final _phone =
      TextEditingController(text: '${widget.store.theme['phone'] ?? ''}');
  late final _whatsapp =
      TextEditingController(text: '${widget.store.theme['whatsapp'] ?? ''}');
  late final _instagram =
      TextEditingController(text: '${widget.store.theme['instagram'] ?? ''}');
  late final _facebook =
      TextEditingController(text: '${widget.store.theme['facebook'] ?? ''}');
  late final _address =
      TextEditingController(text: '${widget.store.theme['address'] ?? ''}');

  late String _template =
      widget.store.theme['template'] == 'vitrine' ? 'vitrine' : 'grid';
  late String _primary = _palette.contains(widget.store.theme['primary'])
      ? widget.store.theme['primary'] as String
      : (widget.store.theme['primary'] as String?) ?? '#00A87C';
  late String _bg = widget.store.theme['bg'] == 'cream' ? 'cream' : 'light';
  late bool _showPrices = widget.store.policy['show_prices'] != false;
  late String _qtyMode = ['labels', 'exact', 'hidden']
          .contains(widget.store.policy['qty_mode'])
      ? widget.store.policy['qty_mode'] as String
      : 'labels';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _name, _about, _announce, _phone, _whatsapp, _instagram, _facebook,
      _address,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final s = await widget.client.webPutConfig(
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        theme: {
          'template': _template,
          'primary': _primary,
          'bg': _bg,
          'about': _about.text.trim(),
          'announcement': _announce.text.trim(),
          'phone': _phone.text.trim(),
          'whatsapp': _whatsapp.text.trim(),
          'instagram': _instagram.text.trim(),
          'facebook': _facebook.text.trim(),
          'address': _address.text.trim(),
        },
        policy: {
          'show_prices': _showPrices,
          'qty_mode': _qtyMode,
        },
      );
      widget.onSaved(s);
      messenger.showSnackBar(const SnackBar(
          backgroundColor: T.mintDeep,
          content: Text('Boutique enregistrée',
              style: TextStyle(color: Colors.white))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Enregistrement impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _upload(String kind) async {
    final path = pickImageFile();
    if (path == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length > 2 * 1024 * 1024) {
        messenger.showSnackBar(const SnackBar(
            backgroundColor: T.danger,
            content: Text('Image trop lourde (2 Mo max)',
                style: TextStyle(color: Colors.white))));
        return;
      }
      await widget.client.webUploadImage(kind, bytes, imageContentType(path));
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.mintDeep,
          content: Text(kind == 'logo' ? 'Logo mis à jour' : 'Bannière mise à jour',
              style: const TextStyle(color: Colors.white))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Envoi impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
  }

  Widget _section(String title, List<Widget> children) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: T.h2),
        const SizedBox(height: 14),
        ...children,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // Address + stats strip
        Card14(
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                  color: T.mintTint, borderRadius: BorderRadius.circular(12)),
              child:
                  const Icon(Icons.language_rounded, color: T.mintDeep, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(s.url,
                    style: T.h2.copyWith(fontSize: 15, color: T.mintDeep)),
                const SizedBox(height: 3),
                Text(
                    s.publishedAt == null
                        ? 'Catalogue jamais publié — cliquez « Publier le catalogue ».'
                        : '${s.visibleCount}/${s.productCount} produits visibles · '
                            '${s.pendingOrders} commande(s) en attente',
                    style: T.small),
              ]),
            ),
            OutlinedButton.icon(
              onPressed: () => _upload('logo'),
              icon: const Icon(Icons.image_outlined, size: 15),
              label: Text(s.hasLogo ? 'Changer le logo' : 'Ajouter un logo'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _upload('cover'),
              icon: const Icon(Icons.panorama_outlined, size: 15),
              label: Text(s.hasCover ? 'Changer la bannière' : 'Bannière'),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        _section('Apparence', [
          webField('Nom de la boutique', _name, required: true),
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 12, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Modèle de page', style: T.label),
              const SizedBox(height: 6),
              DropdownMenu<String>(
                initialSelection: _template,
                width: 280,
                onSelected: (v) => setState(() => _template = v ?? 'grid'),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'grid', label: 'Grille (catalogue)'),
                  DropdownMenuEntry(value: 'vitrine', label: 'Vitrine (avec bannière)'),
                ],
              ),
            ]),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Fond', style: T.label),
              const SizedBox(height: 6),
              DropdownMenu<String>(
                initialSelection: _bg,
                width: 180,
                onSelected: (v) => setState(() => _bg = v ?? 'light'),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'light', label: 'Clair'),
                  DropdownMenuEntry(value: 'cream', label: 'Crème'),
                ],
              ),
            ]),
          ]),
          const SizedBox(height: 14),
          const Text('Couleur principale', style: T.label),
          const SizedBox(height: 6),
          Row(children: [
            for (final c in _palette)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: InkWell(
                  onTap: () => setState(() => _primary = c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Color(
                          0xFF000000 | int.parse(c.substring(1), radix: 16)),
                      shape: BoxShape.circle,
                      border: Border.all(
                          width: _primary == c ? 3 : 1,
                          color: _primary == c ? T.ink : T.border),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 14),
          webField('Présentation', _about,
              maxLines: 3, help: 'Affichée sur la bannière du site.'),
          const SizedBox(height: 12),
          webField('Bandeau d’annonce', _announce,
              hint: 'ex. Livraison 58 wilayas',
              help: 'Une phrase courte en haut de toutes les pages.'),
        ]),
        const SizedBox(height: 14),
        _section('Contact', [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: webField('Téléphone', _phone)),
            const SizedBox(width: 12),
            Expanded(
                child: webField('WhatsApp', _whatsapp,
                    hint: 'ex. 213550123456',
                    help: 'Avec l’indicatif 213, sans le 0.')),
          ]),
          const SizedBox(height: 12),
          webField('Instagram', _instagram),
          const SizedBox(height: 12),
          webField('Facebook', _facebook, help: 'Lien de la page ou son nom.'),
          const SizedBox(height: 12),
          webField('Adresse du magasin', _address),
        ]),
        const SizedBox(height: 14),
        _section('Ce que les visiteurs voient', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showPrices,
            activeTrackColor: T.mint,
            title: Text('Afficher les prix', style: T.body),
            subtitle: Text(
                'Désactivé : « Prix sur demande » partout, commande en ligne coupée.',
                style: T.small),
            onChanged: (v) => setState(() => _showPrices = v),
          ),
          const SizedBox(height: 6),
          const Text('Quantités en stock', style: T.label),
          const SizedBox(height: 6),
          Row(children: [
            DropdownMenu<String>(

              initialSelection: _qtyMode,
              onSelected: (v) => setState(() => _qtyMode = v ?? 'labels'),
              dropdownMenuEntries: const [
                DropdownMenuEntry(
                    value: 'labels',
                    label: 'Étiquettes (En stock / Faible / Rupture)'),
                DropdownMenuEntry(value: 'exact', label: 'Quantités exactes'),
                DropdownMenuEntry(value: 'hidden', label: 'Rien afficher'),
              ],
            ),
          ]),
        ]),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: PrimaryButton(
              label: _busy ? '…' : 'Enregistrer la boutique',
              onPressed: _busy ? null : _save),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ---------------- products flags ----------------

class _ProductsPane extends StatefulWidget {
  const _ProductsPane({required this.client, this.onPublish});
  final CloudClient client;
  final VoidCallback? onPublish;

  @override
  State<_ProductsPane> createState() => _ProductsPaneState();
}

class _ProductsPaneState extends State<_ProductsPane> {
  List<WebStoreProduct>? _items;
  String? _error;
  final _search = TextEditingController();
  String _q = '';
  final _dirty = <String, Map<String, dynamic>>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.client.webStoreProducts();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _flag(WebStoreProduct p, String field, bool value) {
    setState(() {
      switch (field) {
        case 'visible':
          p.visible = value;
        case 'hide_price':
          p.hidePrice = value;
        case 'featured':
          p.featured = value;
      }
      (_dirty[p.productId] ??= {'product_id': p.productId})[field] = value;
    });
  }

  void _bulk(bool visible) {
    setState(() {
      for (final p in _visible()) {
        p.visible = visible;
        (_dirty[p.productId] ??= {'product_id': p.productId})['visible'] =
            visible;
      }
    });
  }

  Future<void> _save() async {
    if (_dirty.isEmpty) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.client.webPutFlags(_dirty.values.toList());
      _dirty.clear();
      messenger.showSnackBar(const SnackBar(
          backgroundColor: T.mintDeep,
          content: Text('Choix enregistrés — le site est à jour',
              style: TextStyle(color: Colors.white))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Enregistrement impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
    if (mounted) setState(() => _busy = false);
  }

  List<WebStoreProduct> _visible() {
    final items = _items ?? const [];
    if (_q.isEmpty) return items;
    final q = _q.toLowerCase();
    return [
      for (final p in items)
        if (p.name.toLowerCase().contains(q) ||
            (p.category ?? '').toLowerCase().contains(q))
          p
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _Notice(
          icon: Icons.error_outline_rounded,
          title: 'Chargement impossible',
          body: _error!,
          action: ('Réessayer', _load));
    }
    if (_items == null) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.6, color: T.mintDeep));
    }
    if (_items!.isEmpty) {
      return _Notice(
          icon: Icons.inventory_2_outlined,
          title: 'Aucun produit publié',
          body: 'Publiez le catalogue : vos produits apparaîtront ici et '
              'vous pourrez choisir quoi montrer sur le site.',
          action: widget.onPublish == null
              ? null
              : ('Publier le catalogue', widget.onPublish!));
    }
    final rows = _visible();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
        child: Row(children: [
          SizedBox(
            width: 320,
            child: SearchField(
              controller: _search,
              hint: 'Filtrer les produits…',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
              onPressed: () => _bulk(true), child: const Text('Tout afficher')),
          const SizedBox(width: 8),
          OutlinedButton(
              onPressed: () => _bulk(false), child: const Text('Tout masquer')),
          const Spacer(),
          if (_dirty.isNotEmpty)
            PrimaryButton(
                label: _busy ? '…' : 'Enregistrer (${_dirty.length})',
                onPressed: _busy ? null : _save),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(children: [
          const Expanded(flex: 4, child: Text('Produit', style: T.label)),
          const Expanded(flex: 2, child: Text('Prix de vente', style: T.label)),
          const Expanded(flex: 2, child: Text('Stock', style: T.label)),
          const SizedBox(width: 84, child: Text('Visible', style: T.label)),
          const SizedBox(width: 100, child: Text('Prix caché', style: T.label)),
          const SizedBox(width: 96, child: Text('En vedette', style: T.label)),
        ]),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final p = rows[i];
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: T.border))),
              child: Row(children: [
                Expanded(
                  flex: 4,
                  child:
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.body.copyWith(
                            color: p.visible ? T.ink : T.faint,
                            fontWeight: FontWeight.w600)),
                    if (p.category != null)
                      Text(p.category!, style: T.small),
                  ]),
                ),
                Expanded(
                    flex: 2,
                    child: Text(
                        p.promoPriceCentimes != null
                            ? '${fmtDA(p.promoPriceCentimes!)} (promo)'
                            : fmtDA(p.priceCentimes),
                        style: T.body)),
                Expanded(flex: 2, child: Text(fmtQty(p.qtyMilli), style: T.body)),
                SizedBox(
                  width: 84,
                  child: Checkbox(
                      value: p.visible,
                      activeColor: T.mintDeep,
                      onChanged: (v) => _flag(p, 'visible', v ?? true)),
                ),
                SizedBox(
                  width: 100,
                  child: Checkbox(
                      value: p.hidePrice,
                      activeColor: T.mintDeep,
                      onChanged: (v) => _flag(p, 'hide_price', v ?? false)),
                ),
                SizedBox(
                  width: 96,
                  child: IconButton(
                    tooltip: p.featured
                        ? 'Retirer de la vedette'
                        : 'Mettre en vedette sur la page d’accueil',
                    onPressed: () => _flag(p, 'featured', !p.featured),
                    icon: Icon(
                        p.featured
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 20,
                        color: p.featured ? const Color(0xFFE8A213) : T.faint),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}

// ---------------- orders ----------------

class _OrdersPane extends StatefulWidget {
  const _OrdersPane(
      {required this.api, required this.client, required this.onAcked});
  final ApiClient api;
  final CloudClient client;
  final VoidCallback onAcked;

  @override
  State<_OrdersPane> createState() => _OrdersPaneState();
}

class _OrdersPaneState extends State<_OrdersPane> {
  List<WebOrder>? _orders;
  String? _error;
  bool _history = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _orders = null;
      _error = null;
    });
    try {
      final items =
          await widget.client.webOrders(status: _history ? 'all' : 'new');
      if (mounted) setState(() => _orders = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Accepte : brouillon de ticket dans Ventes (à encaisser à la livraison),
  /// puis la commande est marquée traitée côté site.
  Future<void> _accept(WebOrder o) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final warehouses = await widget.api.warehouses();
      final wh = warehouses.firstWhere((w) => w.isDefault,
          orElse: () => warehouses.first);
      final contact = [
        o.customerName,
        o.phone,
        [o.wilaya, o.commune, o.address].whereType<String>()
            .where((s) => s.isNotEmpty).join(', '),
        if ((o.note ?? '').isNotEmpty) 'Note : ${o.note}',
      ].where((s) => s.isNotEmpty).join(' — ');
      await widget.api.createDraft({
        'doc_type': 'SALE_TICKET',
        'doc_date': todayISO(),
        'warehouse_id': wh.id,
        'payment_method': 'cash',
        'notes': 'Commande web ${o.number} — $contact',
        'lines': [
          for (final l in o.lines)
            {
              'product_id': l.productId,
              'description': l.name,
              'qty_milli': l.qtyMilli,
              'unit_price': l.priceCentimes,
              'discount_pct': 0,
              'vat_rate': 0,
            }
        ],
      });
      await widget.client.webAckOrder(o.id, accept: true);
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.mintDeep,
          content: Text(
              'Commande ${o.number} acceptée — brouillon créé dans Ventes',
              style: const TextStyle(color: Colors.white))));
      widget.onAcked();
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Acceptation impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
  }

  Future<void> _reject(WebOrder o) async {
    final ok = await confirmAction(
      context,
      title: 'Refuser la commande ${o.number} ?',
      message: 'Le client ne sera pas livré. Ce choix ne peut pas être annulé.',
      confirmLabel: 'Refuser la commande',
      danger: true,
    );
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.client.webAckOrder(o.id, accept: false);
      widget.onAcked();
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: T.danger,
          content: Text('Refus impossible : $e',
              style: const TextStyle(color: Colors.white))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _Notice(
          icon: Icons.error_outline_rounded,
          title: 'Chargement impossible',
          body: _error!,
          action: ('Réessayer', _load));
    }
    if (_orders == null) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.6, color: T.mintDeep));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
        child: Row(children: [
          ChoiceChip(
            label: const Text('À traiter'),
            selected: !_history,
            selectedColor: T.mintTint,
            onSelected: (_) {
              _history = false;
              _load();
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('Historique'),
            selected: _history,
            selectedColor: T.mintTint,
            onSelected: (_) {
              _history = true;
              _load();
            },
          ),
          const Spacer(),
          TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Actualiser')),
        ]),
      ),
      Expanded(
        child: _orders!.isEmpty
            ? _Notice(
                icon: Icons.shopping_bag_outlined,
                title: _history ? 'Aucune commande' : 'Aucune commande à traiter',
                body:
                    'Les commandes passées sur votre boutique en ligne '
                    'apparaîtront ici.',
                action: ('Actualiser', _load))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                itemCount: _orders!.length,
                itemBuilder: (context, i) {
                  final o = _orders![i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card14(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text(o.number, style: T.h2.copyWith(fontSize: 15)),
                              const SizedBox(width: 10),
                              MintChip(
                                switch (o.status) {
                                  'accepted' => 'acceptée',
                                  'rejected' => 'refusée',
                                  _ => 'nouvelle',
                                },
                                color: switch (o.status) {
                                  'accepted' => T.mintTint,
                                  'rejected' => const Color(0xFFFBE3E3),
                                  _ => const Color(0xFFFFF1DB),
                                },
                                fg: switch (o.status) {
                                  'accepted' => T.mintDeep,
                                  'rejected' => T.dangerDark,
                                  _ => const Color(0xFFA96311),
                                },
                              ),
                              const Spacer(),
                              Text(fmtDA(o.totalCentimes),
                                  style: T.h2.copyWith(fontSize: 15)),
                            ]),
                            const SizedBox(height: 8),
                            Text(
                                '${o.customerName} · ${o.phone} · '
                                '${[o.wilaya, o.commune, o.address].whereType<String>().where((s) => s.isNotEmpty).join(', ')}',
                                style: T.bodyMuted),
                            if ((o.note ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text('Note : ${o.note}', style: T.small),
                              ),
                            const SizedBox(height: 8),
                            for (final l in o.lines)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(l.name, style: T.body)),
                                  Text(
                                      '${fmtQty(l.qtyMilli)} × ${fmtDA(l.priceCentimes)}',
                                      style: T.bodyMuted),
                                ]),
                              ),
                            if (o.status == 'new') ...[
                              const SizedBox(height: 10),
                              Row(children: [
                                const Spacer(),
                                OutlinedButton(
                                    onPressed: () => _reject(o),
                                    style: OutlinedButton.styleFrom(
                                        foregroundColor: T.dangerDark),
                                    child: const Text('Refuser')),
                                const SizedBox(width: 10),
                                PrimaryButton(
                                    label: 'Accepter (brouillon dans Ventes)',
                                    onPressed: () => _accept(o)),
                              ]),
                            ],
                          ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
