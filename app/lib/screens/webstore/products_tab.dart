import 'package:flutter/material.dart';

import '../../api/cloud.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'web_common.dart';

/// « Produits » : what each published product shows on the site (visible,
/// price hidden, featured on the home page).
class WebProductsTab extends StatefulWidget {
  const WebProductsTab({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<WebProductsTab> createState() => _WebProductsTabState();
}

class _WebProductsTabState extends State<WebProductsTab> {
  List<WebStoreProduct>? _items;
  String? _error;
  final _search = TextEditingController();
  String _q = '';
  bool _noPhoto = false;
  final _dirty = <String, Map<String, dynamic>>{};
  bool _busy = false;

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
    setState(() => _error = null);
    try {
      final items = await widget.ctx.client.webStoreProducts();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
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
      for (final p in _rows()) {
        p.visible = visible;
        (_dirty[p.productId] ??= {'product_id': p.productId})['visible'] =
            visible;
      }
    });
  }

  Future<void> _save() async {
    if (_dirty.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.ctx.client.webPutFlags(_dirty.values.toList());
      _dirty.clear();
      if (mounted) showToast(context, 'Choix enregistrés — le site est à jour.');
      widget.ctx.reload();
    } catch (e) {
      if (mounted) toastError(context, 'Enregistrement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  List<WebStoreProduct> _rows() {
    final items = _items ?? const [];
    final q = _q.toLowerCase();
    return [
      for (final p in items)
        if ((q.isEmpty ||
                p.name.toLowerCase().contains(q) ||
                (p.category ?? '').toLowerCase().contains(q) ||
                (p.brand ?? '').toLowerCase().contains(q)) &&
            (!_noPhoto || p.imageCount == 0))
          p
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return WebNotice(
          icon: Icons.error_outline_rounded,
          title: 'Chargement impossible',
          body: _error!,
          action: ('Réessayer', _load));
    }
    if (_items == null) return webSpinner;
    if (_items!.isEmpty) {
      return WebNotice(
          icon: Icons.inventory_2_outlined,
          title: 'Aucun produit publié',
          body: 'Publiez le catalogue : vos produits apparaîtront ici et '
              'vous pourrez choisir quoi montrer sur le site.',
          action: ('Publier le catalogue', widget.ctx.publish));
    }
    final rows = _rows();
    final noPhoto = _items!.where((p) => p.imageCount == 0).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        WebPaneHeader(
          title: 'Produits sur le site',
          intro: 'Choisissez ce que les visiteurs voient. Les prix, le stock '
              'et les fiches viennent du catalogue publié.',
          actions: [
            if (_dirty.isNotEmpty)
              PrimaryButton(
                  label: _busy ? '…' : 'Enregistrer (${_dirty.length})',
                  onPressed: _busy ? null : _save),
          ],
        ),
        const SizedBox(height: 14),
        Row(children: [
          SizedBox(
            width: 320,
            child: SearchField(
              controller: _search,
              hint: 'Nom, catégorie ou marque…',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          const SizedBox(width: 10),
          FilterPill(
              label: 'Sans photo ($noPhoto)',
              active: _noPhoto,
              onTap: () => setState(() => _noPhoto = !_noPhoto)),
          const Spacer(),
          OutlinedButton(
              onPressed: () => _bulk(true), child: const Text('Tout afficher')),
          const SizedBox(width: 8),
          OutlinedButton(
              onPressed: () => _bulk(false), child: const Text('Tout masquer')),
        ]),
        const SizedBox(height: 12),
        const Row(children: [
          Expanded(flex: 4, child: Text('Produit', style: T.label)),
          Expanded(flex: 2, child: Text('Prix de vente', style: T.label)),
          Expanded(flex: 1, child: Text('Stock', style: T.label)),
          SizedBox(width: 70, child: Text('Photos', style: T.label)),
          SizedBox(width: 80, child: Text('Visible', style: T.label)),
          SizedBox(width: 96, child: Text('Prix caché', style: T.label)),
          SizedBox(width: 96, child: Text('En vedette', style: T.label)),
        ]),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 18),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final p = rows[i];
              final sub = [
                if ((p.brand ?? '').isNotEmpty) p.brand!,
                if ((p.category ?? '').isNotEmpty) p.category!,
                if ((p.packSize ?? '').isNotEmpty) p.packSize!,
              ].join(' · ');
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: T.border))),
                child: Row(children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: T.body.copyWith(
                                  color: p.visible ? T.ink : T.faint,
                                  fontWeight: FontWeight.w600)),
                          if (sub.isNotEmpty)
                            Text(sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.small),
                        ]),
                  ),
                  Expanded(
                      flex: 2,
                      child: Text(
                          p.promoPriceCentimes != null
                              ? '${fmtDA(p.promoPriceCentimes!)} (promo)'
                              : fmtDA(p.priceCentimes),
                          style: T.body)),
                  Expanded(
                      flex: 1, child: Text(fmtQty(p.qtyMilli), style: T.body)),
                  SizedBox(
                      width: 70,
                      child: Text(p.imageCount == 0 ? '—' : '${p.imageCount}',
                          style: T.body)),
                  SizedBox(
                    width: 80,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Checkbox(
                          value: p.visible,
                          activeColor: T.mintDeep,
                          onChanged: (v) => _flag(p, 'visible', v ?? true)),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Checkbox(
                          value: p.hidePrice,
                          activeColor: T.mintDeep,
                          onChanged: (v) => _flag(p, 'hide_price', v ?? false)),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Align(
                      alignment: Alignment.centerLeft,
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
                            color: p.featured
                                ? const Color(0xFFE8A213)
                                : T.faint),
                      ),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}
