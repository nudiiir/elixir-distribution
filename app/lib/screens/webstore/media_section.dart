import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'image_prep.dart';
import 'web_common.dart';

/// « Images » : the store's media library (banners, slides, brand logos,
/// social image). Images are resized here before upload — the server keeps
/// them as sent.
class MediaSection extends StatelessWidget {
  const MediaSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  Widget build(BuildContext context) => MediaLibrary(ctx: ctx);
}

/// Opens the library as a page to choose one image. Returns the asset.
Future<WebAsset?> pickWebAsset(BuildContext context, WebCtx ctx,
    {String title = 'Choisir une image'}) {
  return Navigator.of(context).push<WebAsset>(MaterialPageRoute(
    builder: (_) => AppPage(
      crumbs: [const Crumb('Boutique en ligne'), Crumb(title)],
      title: title,
      subtitle: Text('Cliquez sur une image pour la choisir, ou ajoutez-en une.',
          style: T.bodyMuted),
      scroll: false,
      body: MediaLibrary(ctx: ctx, picking: true),
    ),
  ));
}

class MediaLibrary extends StatefulWidget {
  const MediaLibrary({super.key, required this.ctx, this.picking = false});
  final WebCtx ctx;
  final bool picking;

  @override
  State<MediaLibrary> createState() => _MediaLibraryState();
}

class _MediaLibraryState extends State<MediaLibrary> {
  Future<WebAssetsInfo>? _future;
  String? _progress;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() =>
      setState(() => _future = widget.ctx.client.webAssets());

  Future<void> _upload() async {
    final paths = pickImageFiles();
    if (paths.isEmpty) return;
    var ok = 0;
    WebAsset? last;
    final errors = <String>[];
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      final file = path.split('\\').last;
      setState(() => _progress = 'Préparation de « $file » (${i + 1}/${paths.length})…');
      try {
        final bytes = await File(path).readAsBytes();
        final im = await prepareImage(bytes, ImagePreset.banner);
        if (im == null) {
          errors.add('$file : image illisible ou trop lourde');
          continue;
        }
        if (mounted) setState(() => _progress = 'Envoi de « $file » (${i + 1}/${paths.length})…');
        var name = file.contains('.') ? file.substring(0, file.lastIndexOf('.')) : file;
        if (name.length > 80) name = name.substring(0, 80);
        last = await widget.ctx.client.webUploadAsset(im.bytes, im.contentType, name);
        ok++;
      } catch (e) {
        errors.add('$file : ${errText(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _progress = null);
    _reload();
    if (errors.isNotEmpty) {
      showToast(context, 'Envoi incomplet — ${errors.join(' · ')}',
          kind: ToastKind.error);
    } else {
      showToast(context, ok == 1 ? 'Image ajoutée.' : '$ok images ajoutées.');
    }
    if (widget.picking && paths.length == 1 && last != null) {
      Navigator.of(context).pop(last);
    }
  }

  Future<void> _delete(WebAsset a) async {
    final ok = await confirmAction(context,
        title: 'Supprimer « ${a.name.isEmpty ? 'cette image' : a.name} » ?',
        message: 'L’image disparaît définitivement de la boutique.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await widget.ctx.client.webDeleteAsset(a.id);
    } on WebApiException catch (e) {
      if (e.status != 409 || !mounted) {
        if (mounted) toastError(context, 'Suppression impossible', e);
        return;
      }
      final force = await confirmAction(context,
          title: 'Image encore utilisée',
          message: '${e.message}\n\nElle est encore affichée sur le site '
              '(page d’accueil, référencement…). Si vous la supprimez, ces '
              'endroits n’auront plus d’image.',
          confirmLabel: 'Supprimer quand même',
          danger: true);
      if (!force || !mounted) return;
      try {
        await widget.ctx.client.webDeleteAsset(a.id, force: true);
      } catch (e2) {
        if (mounted) toastError(context, 'Suppression impossible', e2);
        return;
      }
    } catch (e) {
      if (mounted) toastError(context, 'Suppression impossible', e);
      return;
    }
    if (mounted) showToast(context, 'Image supprimée.');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final picking = widget.picking;
    final body = WebLoader<WebAssetsInfo>(
      future: _future,
      onRetry: _reload,
      builder: (info) {
        final pct = info.quotaBytes == 0 ? 0.0 : info.usedBytes / info.quotaBytes;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                    '${info.items.length} / ${info.maxCount} images · '
                    '${fmtBytes(info.usedBytes)} utilisés sur ${fmtBytes(info.quotaBytes)}',
                    style: T.bodyMuted),
                const SizedBox(height: 6),
                SizedBox(
                  width: 320,
                  child: LinearProgressIndicator(
                      value: pct.clamp(0, 1),
                      color: pct > 0.9 ? T.danger : T.mintDeep,
                      backgroundColor: T.border2),
                ),
              ]),
            ),
            if (_progress != null) ...[
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: T.mintDeep)),
              const SizedBox(width: 10),
              Flexible(child: Text(_progress!, style: T.small)),
            ] else
              PageAction(
                  label: 'Ajouter des images',
                  icon: Icons.upload_rounded,
                  primary: true,
                  onPressed: _upload),
          ]),
          const SizedBox(height: 6),
          Text(
              'PNG, JPEG ou WebP. Les grandes images sont réduites à 1600 px '
              'de large avant l’envoi. Les SVG ne sont pas acceptés.',
              style: T.small),
          const SizedBox(height: 16),
          Expanded(
            child: info.items.isEmpty
                ? const EmptyStateLite(
                    text: 'Aucune image. Ajoutez vos bannières, photos de '
                        'magasin, logos de marques…')
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 14,
                        childAspectRatio: 0.82),
                    itemCount: info.items.length,
                    itemBuilder: (context, i) {
                      final a = info.items[i];
                      return _AssetTile(
                        asset: a,
                        onTap: picking ? () => Navigator.of(context).pop(a) : null,
                        actionLabel: picking ? 'Choisir' : 'Supprimer',
                        onAction: picking
                            ? () => Navigator.of(context).pop(a)
                            : () => _delete(a),
                        danger: !picking,
                      );
                    },
                  ),
          ),
        ]);
      },
    );
    if (picking) return body;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const WebPaneHeader(
          title: 'Images',
          intro: 'La médiathèque de la boutique : bannières, diaporama, logos '
              'de marques, image de partage. Choisissez-les ensuite dans la page '
              'd’accueil ou le référencement.',
        ),
        const SizedBox(height: 18),
        Expanded(child: body),
      ]),
    );
  }
}

class EmptyStateLite extends StatelessWidget {
  const EmptyStateLite({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.image_outlined, size: 34, color: T.ghost),
          const SizedBox(height: 10),
          Text(text, style: T.bodyMuted, textAlign: TextAlign.center),
        ]),
      );
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.actionLabel,
    required this.onAction,
    this.onTap,
    this.danger = false,
  });
  final WebAsset asset;
  final VoidCallback? onTap;
  final String actionLabel;
  final VoidCallback onAction;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rCard),
      child: Container(
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rCard),
          border: Border.all(color: T.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              color: T.bg,
              child: Image.network(asset.url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined, color: T.ghost)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            child: Text(asset.name.isEmpty ? 'Sans nom' : asset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(fmtBytes(asset.size), style: T.small),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: danger ? T.dangerDark : T.mintDark),
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A form field holding one image of the library: preview, « Choisir »,
/// « Retirer ».
class AssetField extends StatelessWidget {
  const AssetField({
    super.key,
    required this.ctx,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    this.required = false,
  });
  final WebCtx ctx;
  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? help;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final has = value != null && value!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label, required: required),
        const SizedBox(height: 6),
        Row(children: [
          Container(
            width: 120,
            height: 72,
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border3),
            ),
            clipBehavior: Clip.antiAlias,
            child: has
                ? Image.network(ctx.assetUrl(value!),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                        child: Text('Image supprimée', style: T.small)))
                : const Icon(Icons.image_outlined, color: T.ghost),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final a = await pickWebAsset(context, ctx);
              if (a != null) onChanged(a.id);
            },
            icon: const Icon(Icons.photo_library_outlined, size: 17),
            label: Text(has ? 'Changer l’image' : 'Choisir une image'),
          ),
          if (has) ...[
            const SizedBox(width: 8),
            TextButton(
                onPressed: () => onChanged(null), child: const Text('Retirer')),
          ],
        ]),
        if (help != null) ...[
          const SizedBox(height: 5),
          Text(help!, style: T.small),
        ],
      ]),
    );
  }
}
