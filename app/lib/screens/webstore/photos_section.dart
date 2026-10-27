import 'package:flutter/material.dart';

import '../../api/cloud.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'catalog_sync.dart';
import 'web_common.dart';

/// « Photos produits » : sends the product photos of the shop (product
/// record) to the online store. Only new or changed photos travel.
class PhotosSection extends StatefulWidget {
  const PhotosSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<PhotosSection> createState() => _PhotosSectionState();
}

class _PhotosSectionState extends State<PhotosSection> {
  Future<(List<Product>, List<WebStoreProduct>)>? _future;
  bool _running = false;
  bool _cancel = false;
  (String, int, int) _step = ('', 0, 0);
  PhotoSyncResult? _result = lastPhotoSync;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() {
        _future = () async {
          final local = await widget.ctx.products(refresh: true);
          final online = await widget.ctx.client.webStoreProducts();
          return (local, online);
        }();
      });

  Future<void> _sync() async {
    setState(() {
      _running = true;
      _cancel = false;
      _step = ('Démarrage…', 0, 0);
    });
    try {
      final r = await syncProductPhotos(widget.ctx.api, widget.ctx.client,
          onProgress: (s, d, t) {
            if (mounted) setState(() => _step = (s, d, t));
          },
          cancelled: () => _cancel);
      lastPhotoSync = r;
      _result = r;
      if (mounted) {
        showToast(context, _cancel ? 'Envoi arrêté. ${r.summary}' : r.summary,
            kind: r.errors.isEmpty ? ToastKind.success : ToastKind.warning);
      }
    } catch (e) {
      if (mounted) toastError(context, 'Envoi impossible', e);
    }
    if (mounted) {
      setState(() => _running = false);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebLoader<(List<Product>, List<WebStoreProduct>)>(
      future: _future,
      onRetry: _reload,
      builder: (data) {
        final (local, online) = data;
        final published = {for (final p in online) p.productId};
        final withPhotos = local.where((p) => p.imageCount > 0 && published.contains(p.id)).length;
        final onSite = online.where((p) => p.imageCount > 0).length;
        final missing = online.where((p) => p.imageCount == 0).length;
        final r = _result;
        return WebPane(
          title: 'Photos produits',
          intro: 'Les photos de vos fiches produit sont envoyées à la boutique (8 par produit '
              'au plus), réduites à environ 1000 px. Seules les photos nouvelles ou modifiées '
              'sont envoyées. « Publier le catalogue » le fait aussi automatiquement.',
          actions: [
            PageAction(
                label: _running ? 'Envoi en cours…' : 'Envoyer les photos',
                icon: Icons.cloud_upload_outlined,
                primary: true,
                onPressed: _running || online.isEmpty ? null : _sync),
          ],
          children: [
            if (online.isEmpty)
              InfoBanner(
                kind: ToastKind.warning,
                text: 'Publiez d’abord le catalogue : les photos ne peuvent être envoyées '
                    'que pour des produits déjà sur le site.',
                actions: [
                  OutlinedButton(
                      onPressed: widget.ctx.publish, child: const Text('Publier le catalogue')),
                ],
              ),
            Wrap(spacing: 14, runSpacing: 14, children: [
              _stat('Produits avec photo (magasin)', '$withPhotos'),
              _stat('Produits avec photo (site)', '$onSite'),
              _stat('Produits du site sans photo', '$missing'),
            ]),
            const SizedBox(height: 16),
            if (_running)
              WebBlock(title: 'Envoi en cours', children: [
                Text(_step.$3 > 0 ? '${_step.$1} : ${_step.$2} / ${_step.$3}' : _step.$1,
                    style: T.body),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                    value: _step.$3 > 0 ? _step.$2 / _step.$3 : null,
                    color: T.mintDeep,
                    backgroundColor: T.border2),
                const SizedBox(height: 10),
                OutlinedButton(
                    onPressed: _cancel ? null : () => setState(() => _cancel = true),
                    child: Text(_cancel ? 'Arrêt…' : 'Arrêter')),
              ]),
            if (r != null && !_running)
              WebBlock(
                title: 'Dernier envoi',
                children: [
                  Text(r.summary, style: T.body),
                  if (r.errors.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('${r.errors.length} problème(s) :',
                        style: T.label.copyWith(color: T.dangerDark)),
                    const SizedBox(height: 4),
                    for (final e in r.errors.take(30))
                      Text('• $e', style: T.small),
                    if (r.errors.length > 30)
                      Text('… et ${r.errors.length - 30} autre(s).', style: T.small),
                  ],
                ],
              ),
            WebBlock(
              title: 'Conseils',
              children: [
                Text(
                    '• Ajoutez les photos dans Produits → fiche du produit → Photos. La première '
                    'photo est celle des vignettes du site.\n'
                    '• Fond blanc, produit centré, image carrée : le rendu est plus propre.\n'
                    '• Les fonds transparents deviennent blancs sur le site.',
                    style: T.bodyMuted.copyWith(height: 1.6)),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _stat(String label, String value) => SizedBox(
        width: 230,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rCard),
            border: Border.all(color: T.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label),
            const SizedBox(height: 6),
            Text(value, style: T.monoBig.copyWith(fontSize: 24)),
          ]),
        ),
      );
}
