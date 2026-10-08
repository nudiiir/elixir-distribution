import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../screens/product_page.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import '../util/prefs.dart';
import 'charts.dart';
import 'doc_list.dart' show showDocDetailDialog;
import 'product_thumb.dart';
import 'side_panel.dart';
import 'ui.dart';

/// Fiche produit — l'écran où le commerçant répond à la question qui décide
/// s'il fait confiance au logiciel : « pourquoi ça dit 45 quand je compte
/// 43 ». Tout est recalculé, rien n'est stocké, et chaque chiffre remonte aux
/// documents en deux clics.
///
/// S'ouvre en panneau latéral droit par-dessus la liste. [navigate] permet
/// Alt+↓ / Alt+↑ (produit suivant / précédent de la liste affichée) ;
/// [onShown] signale à la liste quel produit est ouvert (ligne surlignée).
Future<void> showFicheProduit(
  BuildContext context,
  ApiClient api,
  String productId, {
  required bool canCost,
  VoidCallback? onChanged,
  FutureOr<void> Function(Product)? onEdit,
  void Function(Product)? onLabel,
  String? Function(String currentId, int delta)? navigate,
  ValueChanged<String>? onShown,
  bool focusMoves = false,
}) {
  return showSidePanel<void>(
    context,
    width: 860,
    builder: (_) => _FichePanel(
      api: api,
      productId: productId,
      canCost: canCost,
      onChanged: onChanged,
      onEdit: onEdit,
      onLabel: onLabel,
      navigate: navigate,
      onShown: onShown,
      focusMoves: focusMoves,
    ),
  );
}

/// « Ajuster le stock » sans ouvrir la fiche (menu de ligne de la liste).
/// Returns true when an adjustment was posted.
Future<bool> showAdjustStock(
    BuildContext context, ApiClient api, String productId) async {
  final FicheData d;
  try {
    d = await api.ficheProduct(productId);
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Fiche indisponible : $e', kind: ToastKind.error);
    }
    return false;
  }
  if (!context.mounted) return false;
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _AdjustDialog(api: api, fiche: d),
  );
  return done == true;
}

/// Étiquettes de rayon pour un ou plusieurs produits, avec le modèle
/// « étiquette » du magasin — un PDF, une page par étiquette.
Future<void> printProductLabels(
    BuildContext context, ApiClient api, List<Product> products,
    {bool askCopies = true}) async {
  if (products.isEmpty) return;
  var copies = 1;
  if (askCopies) {
    final n = await _askCopies(context, products.length);
    if (n == null) return;
    copies = n;
  }
  try {
    final rec = await api.defaultTemplate('label');
    final tpl =
        rec == null ? defaultTplDoc('label', 'fr') : TplDoc.fromJson(rec.body);
    final company = await api.settings();
    final pages = [
      for (final p in products)
        for (var i = 0; i < copies; i++) labelData(p, company),
    ];
    final bytes =
        await renderTemplatePages(tpl, lang: rec?.lang ?? 'fr', pages: pages);
    await saveAndOpenPdf(
        bytes,
        products.length == 1
            ? 'etiquette-${products.first.name}'
            : 'etiquettes-${products.length}-produits');
    if (context.mounted) {
      showToast(context,
          '${pages.length} étiquette${pages.length > 1 ? 's' : ''} prête${pages.length > 1 ? 's' : ''}');
    }
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Étiquettes impossibles : $e', kind: ToastKind.error);
    }
  }
}

Future<int?> _askCopies(BuildContext context, int products) {
  final ctrl = TextEditingController(text: '1');
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      void ok() {
        final n = int.tryParse(ctrl.text.trim()) ?? 0;
        if (n > 0 && n <= 500) Navigator.of(ctx).pop(n);
      }

      return AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        title: Text('Imprimer des étiquettes', style: T.h2),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  products == 1
                      ? '1 produit'
                      : '$products produits sélectionnés',
                  style: T.bodyMuted),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: T.monoBody,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Étiquettes par produit'),
                onSubmitted: (_) => ok(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler')),
          PrimaryButton(label: 'Imprimer', onPressed: ok),
        ],
      );
    },
  ).whenComplete(ctrl.dispose);
}

// ---------------- Photos : préparation, fichier, presse-papiers ----------------

const _maxPhotoBytes = 2 * 1024 * 1024;

/// Makes [bytes] acceptable to the server: JPEG/PNG under 2 Mo. Other formats
/// (WebP, BMP…) and oversized photos are re-encoded as PNG, shrunk if needed.
/// Returns null when the image cannot be read.
Future<(Uint8List, String)?> normalizeProductPhoto(
    Uint8List bytes, String mime) async {
  final okType = mime == 'image/jpeg' || mime == 'image/png';
  if (okType && bytes.length <= _maxPhotoBytes) return (bytes, mime);
  try {
    for (final maxSide in [2000, 1400, 1000, 700]) {
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buf);
      final w = desc.width, h = desc.height;
      final scale = (w > h ? w : h) > maxSide ? maxSide / (w > h ? w : h) : 1.0;
      final codec = await desc.instantiateCodec(
          targetWidth: (w * scale).round(), targetHeight: (h * scale).round());
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      desc.dispose();
      buf.dispose();
      if (png == null) return null;
      final out = png.buffer.asUint8List();
      if (out.length <= _maxPhotoBytes) return (out, 'image/png');
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// « Ajouter une photo » : boîte Windows d'ouverture de fichier.
Future<(Uint8List, String)?> pickProductPhoto() async {
  final path = pickImageFile();
  if (path == null) return null;
  final bytes = await File(path).readAsBytes();
  return normalizeProductPhoto(bytes, imageContentType(path));
}

/// « Coller » : l'image du presse-papiers Windows (capture d'écran, image
/// copiée depuis un navigateur…), convertie en PNG. Null s'il n'y en a pas.
Future<(Uint8List, String)?> pasteProductPhoto() async {
  final dib = _clipboardDib();
  if (dib == null) return null;
  final bmp = _dibToBmp(dib);
  if (bmp == null) return null;
  try {
    final codec = await ui.instantiateImageCodec(bmp);
    final frame = await codec.getNextFrame();
    var image = frame.image;
    // Les captures 32 bits ont souvent un canal alpha à zéro : on les rend
    // opaques plutôt que d'obtenir une image invisible.
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw != null) {
      final px = raw.buffer.asUint8List();
      var anyAlpha = false;
      for (var i = 3; i < px.length; i += 4) {
        if (px[i] != 0) {
          anyAlpha = true;
          break;
        }
      }
      if (!anyAlpha) {
        for (var i = 3; i < px.length; i += 4) {
          px[i] = 255;
        }
        final buf = await ui.ImmutableBuffer.fromUint8List(px);
        final desc = ui.ImageDescriptor.raw(buf,
            width: image.width,
            height: image.height,
            pixelFormat: ui.PixelFormat.rgba8888);
        final c2 = await desc.instantiateCodec();
        image.dispose();
        image = (await c2.getNextFrame()).image;
      }
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) return null;
    return normalizeProductPhoto(png.buffer.asUint8List(), 'image/png');
  } catch (_) {
    return null;
  }
}

Uint8List? _clipboardDib() {
  if (OpenClipboard(NULL) == 0) return null;
  try {
    if (IsClipboardFormatAvailable(CF_DIB) == 0) return null;
    final handle = GetClipboardData(CF_DIB);
    if (handle == 0) return null;
    final h = Pointer<Void>.fromAddress(handle);
    final p = GlobalLock(h);
    if (p == nullptr) return null;
    try {
      final size = GlobalSize(h);
      if (size <= 40) return null;
      return Uint8List.fromList(p.cast<Uint8>().asTypedList(size));
    } finally {
      GlobalUnlock(h);
    }
  } finally {
    CloseClipboard();
  }
}

/// A CF_DIB block is a BMP file without its 14-byte file header.
Uint8List? _dibToBmp(Uint8List dib) {
  final bd = ByteData.sublistView(dib);
  final headerSize = bd.getUint32(0, Endian.little);
  if (headerSize < 12 || headerSize > dib.length) return null;
  var colors = 0, masks = 0;
  if (headerSize >= 40) {
    final bitCount = bd.getUint16(14, Endian.little);
    final compression = bd.getUint32(16, Endian.little);
    final clrUsed = bd.getUint32(32, Endian.little);
    colors = clrUsed != 0 ? clrUsed : (bitCount <= 8 ? 1 << bitCount : 0);
    if (headerSize == 40 && compression == 3) masks = 12; // BI_BITFIELDS
  }
  final offset = 14 + headerSize + masks + colors * 4;
  final out = Uint8List(14 + dib.length);
  final ob = ByteData.sublistView(out);
  out[0] = 0x42; // B
  out[1] = 0x4D; // M
  ob.setUint32(2, out.length, Endian.little);
  ob.setUint32(10, offset, Endian.little);
  out.setRange(14, out.length, dib);
  return out;
}

// ---------------- Panneau ----------------

class _FichePanel extends StatefulWidget {
  const _FichePanel({
    required this.api,
    required this.productId,
    required this.canCost,
    this.onChanged,
    this.onEdit,
    this.onLabel,
    this.navigate,
    this.onShown,
    this.focusMoves = false,
  });
  final ApiClient api;
  final String productId;
  final bool canCost;
  final VoidCallback? onChanged;
  final FutureOr<void> Function(Product)? onEdit;
  final void Function(Product)? onLabel;
  final String? Function(String currentId, int delta)? navigate;
  final ValueChanged<String>? onShown;
  final bool focusMoves;

  @override
  State<_FichePanel> createState() => _FichePanelState();
}

/// Filtre des mouvements : libellé → types de documents (null = tous).
const _moveFilters = <(String, Set<String>?)>[
  ('Tous', null),
  ('Ventes', {'SALE_TICKET', 'SALE_INVOICE', 'DELIVERY_NOTE'}),
  ('Achats', {'PURCHASE_RECEIPT', 'PURCHASE_INVOICE'}),
  ('Retours', {'SALE_CREDIT_NOTE', 'PURCHASE_CREDIT_NOTE'}),
  ('Ajustements', {'STOCK_ADJUSTMENT'}),
  ('Inventaires', {'INVENTORY_COUNT'}),
  ('Transferts', {'STOCK_TRANSFER'}),
];

/// Période des mouvements : libellé → jours (null = tout l'historique).
const _periods = <(String, int?)>[
  ('7 j', 7),
  ('30 j', 30),
  ('90 j', 90),
  ('1 an', 365),
  ('Tout', null),
];

const _typeLabels = {
  'SALE_TICKET': 'Ticket',
  'SALE_INVOICE': 'Facture',
  'SALE_CREDIT_NOTE': 'Avoir client',
  'DELIVERY_NOTE': 'BL',
  'PURCHASE_RECEIPT': 'Réception',
  'PURCHASE_INVOICE': 'Facture fourn.',
  'PURCHASE_CREDIT_NOTE': 'Retour fourn.',
  'STOCK_ADJUSTMENT': 'Ajustement',
  'STOCK_TRANSFER': 'Transfert',
  'INVENTORY_COUNT': 'Inventaire',
};

class _FichePanelState extends State<_FichePanel> {
  late String _id = widget.productId;
  FicheData? _data;
  String? _error;
  bool _busyPhoto = false;
  int _moveFilter = 0;
  late int _period = UiPrefs.instance.get<int>('fiche', 'period') ?? 4;
  final _scroll = ScrollController();
  final _movesKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'fiche');

  @override
  void initState() {
    super.initState();
    _load(scrollToMoves: widget.focusMoves);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load({bool scrollToMoves = false}) async {
    try {
      final d = await widget.api.ficheProduct(_id, full: true);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
      if (scrollToMoves) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _movesKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx,
                duration: const Duration(milliseconds: 200));
          }
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _step(int delta) {
    final nav = widget.navigate;
    if (nav == null) return;
    final next = nav(_id, delta);
    if (next == null) return;
    setState(() {
      _id = next;
      _data = null;
      _error = null;
    });
    widget.onShown?.call(next);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _changed() {
    _load();
    widget.onChanged?.call();
  }

  /// Marge sur PV_HT contre CMUP — jamais TTC contre HT (spec §2.4).
  String _marginText(int saleTTC, int vatRate, int? cmup) {
    if (cmup == null || cmup <= 0 || saleTTC <= 0) return '—';
    final pvHT = roundDiv(saleTTC * 10000, 10000 + vatRate);
    final m = roundDiv((pvHT - cmup) * 10000, cmup);
    return '${(m / 100).toStringAsFixed(2).replaceAll('.', ',')} %';
  }

  Future<void> _edit(Product p) async {
    if (widget.onEdit != null) {
      await widget.onEdit!(p);
    } else {
      final saved = await openProductPage(context,
          api: widget.api, existing: p, showCost: widget.canCost);
      if (saved == true) widget.onChanged?.call();
    }
    if (mounted) _load();
  }

  void _labels(Product p) {
    if (widget.onLabel != null) {
      widget.onLabel!(p);
    } else {
      printProductLabels(context, widget.api, [p]);
    }
  }

  Future<void> _adjust() async {
    final d = _data!;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _AdjustDialog(api: widget.api, fiche: d),
    );
    if (done == true) {
      _changed();
      if (mounted) showToast(context, 'Stock ajusté');
    }
  }

  Future<void> _split() async {
    final d = _data!;
    final codes = <BarcodeEntry>[
      if (d.product.barcode != null && d.product.barcode!.isNotEmpty)
        BarcodeEntry(code: d.product.barcode!, label: 'principal'),
      ...d.product.barcodesEx,
    ];
    if (codes.length < 2) {
      showToast(context,
          'Il faut au moins deux codes-barres pour séparer en déclinaisons.',
          kind: ToastKind.warning);
      return;
    }
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _SplitDialog(api: widget.api, fiche: d, codes: codes),
    );
    if (done == true) _changed();
  }

  // ---- Photos ----

  Future<void> _addPhoto({bool paste = false}) async {
    final p = _data?.product;
    if (p == null || _busyPhoto) return;
    final img = paste ? await pasteProductPhoto() : await pickProductPhoto();
    if (img == null) {
      if (paste && mounted) {
        showToast(context, 'Aucune image dans le presse-papiers.',
            kind: ToastKind.info);
      }
      return;
    }
    setState(() => _busyPhoto = true);
    try {
      await widget.api.uploadProductImage(p.id, img.$1, img.$2);
      _changed();
      if (mounted) showToast(context, 'Photo ajoutée');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Photo impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
  }

  Future<void> _photoAction(Product p, int index, bool remove) async {
    if (remove) {
      final ok = await confirmAction(context,
          title: 'Supprimer cette photo ?',
          message: 'La photo est retirée du produit (caisse, liste, boutique).',
          confirmLabel: 'Supprimer',
          danger: true);
      if (!ok) return;
    }
    setState(() => _busyPhoto = true);
    try {
      if (remove) {
        await widget.api.deleteProductImage(p.id, index);
      } else {
        await widget.api.setMainProductImage(p.id, index);
      }
      _changed();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
            _step(-1),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: d == null
            ? Column(children: [
                _skeletonHeader(),
                Expanded(
                  child: Center(
                    child: _error != null
                        ? Column(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.cloud_off_rounded,
                                size: 30, color: T.danger),
                            const SizedBox(height: 8),
                            Text(_error!, style: T.bodyMuted),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Réessayer'),
                            ),
                          ])
                        : const CircularProgressIndicator(
                            strokeWidth: 2.6, color: T.mintDeep),
                  ),
                ),
              ])
            : Column(children: [
                _header(d),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: [
                      _photos(d),
                      _alerts(d),
                      _indicators(d),
                      if (!d.product.isService) ...[
                        const SizedBox(height: 12),
                        _sales(d),
                        const SizedBox(height: 12),
                        _levels(d),
                      ],
                      if (d.variants.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _variants(d),
                      ],
                      if (d.lots.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _lots(d),
                      ],
                      const SizedBox(height: 12),
                      KeyedSubtree(key: _movesKey, child: _moves(d)),
                      if (widget.canCost && d.suppliers.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _suppliers(d),
                      ],
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _skeletonHeader() => Container(
        color: T.surface,
        padding: const EdgeInsets.fromLTRB(18, 18, 10, 18),
        child: Row(children: [
          const SkeletonBar(width: 220, height: 14),
          const Spacer(),
          IconButton(
            tooltip: 'Fermer (Échap)',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18, color: T.muted),
          ),
        ]),
      );

  Widget _header(FicheData d) {
    final p = d.product;
    final hasNav = widget.navigate != null;
    return Container(
      color: T.surface,
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      child: Row(children: [
        ProductThumb(api: widget.api, product: p, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                  child: Text(p.name,
                      style: T.h2.copyWith(fontSize: 17),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 10),
              if (!p.active)
                const MintChip('inactif', color: T.cream, fg: T.faint),
            ]),
            const SizedBox(height: 5),
            Wrap(spacing: 6, runSpacing: 4, children: [
              if (p.isService)
                const MintChip('service', color: T.mintTint, fg: T.mintDark),
              if (p.brand.isNotEmpty)
                MintChip(p.brand, color: T.cream, fg: T.faint),
              MintChip('TVA ${p.vatRate ~/ 100}%', color: T.cream, fg: T.faint),
              if (p.trackLots || p.trackExpiry)
                const MintChip('lot & DLC', color: T.mintTint, fg: T.mintDark),
              if (p.trackSerials)
                const MintChip('n° série', color: T.mintTint, fg: T.mintDark),
              if (p.isWeighable)
                const MintChip('au poids', color: T.mintTint, fg: T.mintDark),
              if (p.promoActive)
                MintChip('promo ${fmtDA(p.promoPrice!)}',
                    color: T.warnTint, fg: T.warnDark),
              if (p.barcode != null)
                MintChip(p.barcode!, color: T.cream, fg: T.faint),
              if (p.barcodesEx.isNotEmpty)
                MintChip('+${p.barcodesEx.length} codes',
                    color: T.cream, fg: T.faint),
            ]),
          ]),
        ),
        // ---- Actions ----
        if (hasNav) ...[
          IconButton(
            tooltip: 'Produit précédent (Alt+↑)',
            onPressed: () => _step(-1),
            icon: const Icon(Icons.keyboard_arrow_up_rounded,
                size: 20, color: T.muted),
          ),
          IconButton(
            tooltip: 'Produit suivant (Alt+↓)',
            onPressed: () => _step(1),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 20, color: T.muted),
          ),
          const SizedBox(width: 4),
        ],
        IconButton(
          tooltip: 'Modifier',
          onPressed: () => _edit(p),
          icon: const Icon(Icons.edit_outlined, size: 18, color: T.muted),
        ),
        if (!p.isService)
          IconButton(
            tooltip: 'Ajuster le stock (motif obligatoire)',
            onPressed: _adjust,
            icon: const Icon(Icons.tune_rounded, size: 18, color: T.muted),
          ),
        IconButton(
          tooltip: 'Imprimer des étiquettes',
          onPressed: () => _labels(p),
          icon: const Icon(Icons.qr_code_2_rounded, size: 18, color: T.muted),
        ),
        if (d.variants.isEmpty && !p.isService)
          IconButton(
            tooltip: 'Séparer en déclinaisons',
            onPressed: _split,
            icon: const Icon(Icons.call_split_rounded, size: 18, color: T.muted),
          ),
        IconButton(
          tooltip: 'Fermer (Échap)',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 18, color: T.muted),
        ),
      ]),
    );
  }

  Widget _photos(FicheData d) {
    final p = d.product;
    final count = p.imageCount;
    Widget tile(int i) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: _GalleryTile(
            url: widget.api
                .productImageUrl(p.id, p.imageRev, thumb: true, index: i),
            headers: widget.api.authHeaders,
            size: i == 0 ? 96 : 56,
            main: i == 0,
            onMain: i == 0 || _busyPhoto ? null : () => _photoAction(p, i, false),
            onRemove: _busyPhoto ? null : () => _photoAction(p, i, true),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card14(
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (count == 0)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: ProductThumb(api: widget.api, product: p, size: 72),
            )
          else
            for (var i = 0; i < count; i++) tile(i),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MicroLabel('PHOTOS'),
                const SizedBox(height: 4),
                Text(
                    count == 0
                        ? 'Aucune photo — elle s’affiche à la caisse, dans la liste et sur la boutique.'
                        : '$count photo${count > 1 ? 's' : ''} · la première est la photo principale',
                    style: T.small),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  OutlinedButton.icon(
                    onPressed: _busyPhoto ? null : () => _addPhoto(),
                    icon: Icon(
                        _busyPhoto
                            ? Icons.hourglass_top_rounded
                            : Icons.add_photo_alternate_outlined,
                        size: 16),
                    label: const Text('Ajouter une photo'),
                  ),
                  TextButton.icon(
                    onPressed: _busyPhoto ? null : () => _addPhoto(paste: true),
                    icon: const Icon(Icons.content_paste_rounded, size: 16),
                    label: const Text('Coller'),
                  ),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _alerts(FicheData d) {
    final alerts = <Widget>[];
    final today = DateTime.now();
    for (final l in d.lots) {
      if (l.qtyMilli <= 0 || l.expiryDate == null) continue;
      final exp = DateTime.tryParse(l.expiryDate!);
      if (exp == null) continue;
      final days = exp.difference(today).inDays;
      if (days < 0) {
        alerts.add(_alertRow(Icons.dangerous_outlined, T.dangerDark,
            'Lot ${l.lotNumber} PÉRIMÉ depuis ${-days} j (${fmtQty(l.qtyMilli)} u.)'));
      } else if (days <= 90) {
        alerts.add(_alertRow(Icons.hourglass_bottom_rounded, T.warnDark,
            'Lot ${l.lotNumber} expire dans $days j (${fmtQty(l.qtyMilli)} u.)'));
      }
    }
    if (!d.product.isService) {
      if (d.stockTotal <= 0) {
        alerts.add(_alertRow(
            Icons.remove_shopping_cart_outlined, T.dangerDark, 'En rupture'));
      } else if (d.product.minStockMilli > 0 &&
          d.stockTotal < d.product.minStockMilli) {
        alerts.add(_alertRow(Icons.trending_down_rounded, T.warnDark,
            'Sous le minimum (${fmtQty(d.product.minStockMilli)})'));
      }
    }
    // Pool à ventiler : du stock sur le parent alors que des déclinaisons
    // existent — le stock n'est vendable sur aucune teinte tant que le
    // commerçant n'a pas réparti.
    if (d.variants.isNotEmpty && d.stockTotal > 0) {
      alerts.add(_alertRow(Icons.call_split_rounded, T.warnDark,
          '${fmtQty(d.stockTotal)} u. à ventiler entre les déclinaisons'));
    }
    if (alerts.isEmpty) return const SizedBox.shrink();
    return Card14(
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('ALERTES'),
        const SizedBox(height: 8),
        ...alerts,
      ]),
    );
  }

  Widget _alertRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: T.body.copyWith(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _indicators(FicheData d) {
    // Quand stock_total est nul, chaque moyenne affiche un tiret, jamais un
    // zéro : une moyenne de rien n'est pas zéro dinar.
    final stock = d.stockTotal;
    final achat = d.achatPondere;
    int? ventePonderee;
    if (stock > 0) {
      var v = 0;
      if (d.variants.isEmpty) {
        v = d.product.priceRetail;
        ventePonderee = v;
      } else {
        var sum = 0;
        var qty = 0;
        for (final va in d.variants) {
          sum += (va.stockMilli * va.product.priceRetail) ~/ 1000;
          qty += va.stockMilli;
        }
        if (qty > 0) ventePonderee = (sum * 1000) ~/ qty;
      }
    }
    final margin = achat == null
        ? '—'
        : _marginText(ventePonderee ?? d.product.priceRetail,
            d.product.vatRate, achat);

    Widget card(String label, String value) => Expanded(
          child: Container(
            margin: const EdgeInsetsDirectional.only(end: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MicroLabel(label),
              const SizedBox(height: 5),
              Text(value, style: T.monoBody.copyWith(fontSize: 15)),
            ]),
          ),
        );

    if (d.product.isService) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          card('PRIX DE VENTE TTC', fmtDA(d.product.priceRetail)),
          card('TYPE', 'Service — sans stock'),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        card('STOCK TOTAL', fmtQty(stock)),
        card('VALEUR DU STOCK',
            widget.canCost ? (stock > 0 ? fmtDA(d.valeurStock) : '—') : '···'),
        card('CMUP',
            widget.canCost ? (achat == null ? '—' : fmtDA(achat)) : '···'),
        card('VENTE PONDÉRÉE',
            ventePonderee == null ? '—' : fmtDA(ventePonderee)),
        card('MARGE MOYENNE', widget.canCost ? margin : '···'),
      ]),
    );
  }

  Widget _sales(FicheData d) {
    final total = d.sales30d.fold(0, (s, e) => s + e.qtyMilli);
    final cov = d.coverageDays;
    final covText = cov == null
        ? 'pas de ventes sur 30 jours'
        : cov == 0
            ? 'rupture'
            : '$cov jour${cov > 1 ? 's' : ''}';
    final covColor = cov == null
        ? T.muted
        : cov <= 7
            ? T.dangerDark
            : cov <= 21
                ? T.warnDark
                : T.mintDark;
    return Card14(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const MicroLabel('VENTES 30 JOURS'),
              const Spacer(),
              Text('${fmtQty(total)} vendus', style: T.monoSmall),
            ]),
            const SizedBox(height: 10),
            if (d.sales30d.length >= 2 && total > 0)
              Tooltip(
                message:
                    '${d.sales30d.first.date} → ${d.sales30d.last.date} · moyenne ${fmtQty(d.avgDailySalesMilli)} / jour',
                child: Sparkline(
                    values: [
                      for (final s in d.sales30d) s.qtyMilli / 1000.0
                    ],
                    height: 42),
              )
            else
              SizedBox(
                height: 42,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text('Aucune vente sur la période.', style: T.small),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 18),
        SizedBox(
          width: 200,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const MicroLabel('COUVERTURE'),
            const SizedBox(height: 6),
            Text('Couverture : $covText',
                style: T.body.copyWith(
                    color: covColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                d.avgDailySalesMilli > 0
                    ? 'au rythme de ${fmtQty(d.avgDailySalesMilli)} / jour'
                    : 'stock ÷ ventes moyennes par jour',
                style: T.small.copyWith(fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  Widget _levels(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('STOCK PAR DÉPÔT'),
        const SizedBox(height: 8),
        if (d.levels.isEmpty)
          Text('Aucun mouvement.', style: T.bodyMuted)
        else
          for (final l in d.levels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text(l.warehouse, style: T.body)),
                SizedBox(
                  width: 90,
                  child: Text(fmtQty(l.qtyMilli),
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          color: l.qtyMilli <= 0 ? T.dangerDark : T.ink)),
                ),
                SizedBox(
                  width: 130,
                  child: Text(
                      widget.canCost
                          ? 'CMUP ${l.qtyMilli == 0 ? '—' : fmtDA(l.avgCost)}'
                          : '',
                      textAlign: TextAlign.end, style: T.monoSmall),
                ),
              ]),
            ),
      ]),
    );
  }

  Widget _variants(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('DÉCLINAISONS'),
        const SizedBox(height: 8),
        for (final v in d.variants)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(
                  child: Text(v.product.variantLabel ?? v.product.name,
                      style: T.body)),
              if (v.product.barcode != null)
                SizedBox(
                    width: 130,
                    child: Text(v.product.barcode!, style: T.monoSmall)),
              SizedBox(
                width: 90,
                child: Text(fmtDA(v.product.priceRetail),
                    textAlign: TextAlign.end, style: T.monoSmall),
              ),
              SizedBox(
                width: 80,
                child: Text(fmtQty(v.stockMilli),
                    textAlign: TextAlign.end,
                    style: T.monoBody.copyWith(
                        color: v.stockMilli <= 0 ? T.dangerDark : T.ink)),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _lots(FicheData d) {
    final today = DateTime.now();
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('LOTS — triés par péremption'),
        const SizedBox(height: 8),
        for (final l in d.lots.where((l) => l.qtyMilli != 0))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 140, child: Text(l.lotNumber, style: T.monoBody)),
              Expanded(
                child: Builder(builder: (context) {
                  if (l.expiryDate == null) {
                    return Text('sans DLC', style: T.small);
                  }
                  final exp = DateTime.tryParse(l.expiryDate!);
                  final days = exp?.difference(today).inDays;
                  final color = days == null
                      ? T.muted
                      : days < 0
                          ? T.dangerDark
                          : days <= 90
                              ? T.warnDark
                              : T.muted;
                  return Text(
                      'DLC ${l.expiryDate}${days != null ? '  (J${days >= 0 ? '-' : '+'}${days.abs()})' : ''}',
                      style: T.monoSmall.copyWith(color: color));
                }),
              ),
              Text(fmtQty(l.qtyMilli), style: T.monoBody),
            ]),
          ),
      ]),
    );
  }

  List<FicheMove> _filteredMoves(FicheData d) {
    final types = _moveFilters[_moveFilter].$2;
    final days = _periods[_period].$2;
    final since = days == null
        ? null
        : DateTime.now().subtract(Duration(days: days)).toIso8601String();
    return [
      for (final m in d.moves)
        if ((types == null || types.contains(m.docType)) &&
            (since == null || m.date.compareTo(since.substring(0, 10)) >= 0))
          m
    ];
  }

  Widget _chip(String label, bool active, VoidCallback onTap) => Padding(
        padding: const EdgeInsetsDirectional.only(end: 6, bottom: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: active ? T.ink : T.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: active ? T.ink : T.border),
            ),
            child: Text(label,
                style: T.small.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : T.ink)),
          ),
        ),
      );

  Widget _moves(FicheData d) {
    final moves = _filteredMoves(d);
    final multiDepot = {for (final m in d.moves) m.warehouseId}.length > 1;
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: MicroLabel('MOUVEMENTS')),
          Text(
              d.moves.length >= 200
                  ? '200 derniers mouvements'
                  : '${moves.length} mouvement${moves.length > 1 ? 's' : ''}',
              style: T.small.copyWith(fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        Wrap(children: [
          for (var i = 0; i < _moveFilters.length; i++)
            _chip(_moveFilters[i].$1, _moveFilter == i,
                () => setState(() => _moveFilter = i)),
          const SizedBox(width: 10),
          for (var i = 0; i < _periods.length; i++)
            _chip(_periods[i].$1, _period == i, () {
              setState(() => _period = i);
              UiPrefs.instance.set('fiche', 'period', i);
            }),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const SizedBox(width: 84, child: MicroLabel('Date')),
            const SizedBox(width: 110, child: MicroLabel('Type')),
            const SizedBox(width: 130, child: MicroLabel('Document')),
            const Expanded(child: MicroLabel('Dépôt')),
            const SizedBox(
                width: 80,
                child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: MicroLabel('Qté'))),
            SizedBox(
                width: 90,
                child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Tooltip(
                        message: multiDepot
                            ? 'Stock du dépôt juste après le mouvement'
                            : 'Stock juste après le mouvement',
                        child: const MicroLabel('Solde')))),
          ]),
        ),
        const Divider(height: 1),
        if (moves.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('Aucun mouvement pour ce filtre.', style: T.bodyMuted),
          )
        else
          for (final m in moves)
            InkWell(
              onTap: m.docId.isEmpty
                  ? null
                  : () async {
                      final changed = await showDocDetailDialog(
                          context, widget.api, m.docId);
                      if (changed == true) _changed();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  SizedBox(
                      width: 84,
                      child: Text(
                          m.date.length >= 10 ? m.date.substring(0, 10) : m.date,
                          style: T.monoSmall)),
                  SizedBox(
                      width: 110,
                      child: Tooltip(
                        message: m.reason ?? '',
                        child: Text(_typeLabels[m.docType] ?? m.docType,
                            style: T.small),
                      )),
                  SizedBox(
                      width: 130,
                      child: Text(m.docNumber ?? '—',
                          style: T.monoSmall.copyWith(color: T.mintDark))),
                  Expanded(
                      child: Text(m.warehouse,
                          style: T.small, overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    width: 80,
                    child: Text(
                      '${m.qtyMilli > 0 ? '+' : ''}${fmtQty(m.qtyMilli)}',
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          color: m.qtyMilli >= 0 ? T.mintDark : T.dangerDark),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                        m.balanceAfter == null ? '—' : fmtQty(m.balanceAfter!),
                        textAlign: TextAlign.end,
                        style: T.monoBody.copyWith(
                            color: (m.balanceAfter ?? 0) < 0
                                ? T.dangerDark
                                : T.ink)),
                  ),
                ]),
              ),
            ),
      ]),
    );
  }

  Widget _suppliers(FicheData d) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('FOURNISSEURS — dernier prix payé'),
        const SizedBox(height: 8),
        for (final s in d.suppliers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(s.partner, style: T.body)),
              SizedBox(
                  width: 84,
                  child: Text(
                      s.date.length >= 10 ? s.date.substring(0, 10) : s.date,
                      style: T.monoSmall)),
              SizedBox(
                width: 110,
                child: Text(fmtDA(s.unitCost),
                    textAlign: TextAlign.end, style: T.monoBody),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// One photo of the gallery with hover actions (main / remove).
class _GalleryTile extends StatefulWidget {
  const _GalleryTile({
    required this.url,
    required this.headers,
    required this.size,
    required this.main,
    this.onMain,
    this.onRemove,
  });
  final String url;
  final Map<String, String> headers;
  final double size;
  final bool main;
  final VoidCallback? onMain;
  final VoidCallback? onRemove;

  @override
  State<_GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<_GalleryTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(children: [
        Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(
                color: widget.main ? T.mintDeep : T.border,
                width: widget.main ? 1.5 : 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(T.rInner - 1),
            child: Image.network(widget.url,
                headers: widget.headers,
                width: s,
                height: s,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: T.ghost,
                    size: 20)),
          ),
        ),
        if (_hover)
          Positioned(
            right: 2,
            top: 2,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (widget.onMain != null)
                _miniBtn(Icons.star_outline_rounded, 'Photo principale',
                    widget.onMain!),
              if (widget.onRemove != null)
                _miniBtn(
                    Icons.delete_outline_rounded, 'Supprimer', widget.onRemove!),
            ]),
          ),
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(left: 2),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: T.border),
            ),
            child: Icon(icon, size: 13, color: T.ink),
          ),
        ),
      );
}

// ---------------- Ajuster le stock ----------------

const kAdjustReasons = [
  'inventaire',
  'casse',
  'vol',
  'péremption',
  'erreur de saisie',
  'consommation interne',
  'échantillon',
];

/// Il n'existe aucun champ de stock modifiable : le stock change par un
/// document d'ajustement avec quantité comptée et motif. Deux clics de plus
/// qui gardent chaque chiffre du système explicable.
class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.api, required this.fiche});
  final ApiClient api;
  final FicheData fiche;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  String _reason = 'inventaire';
  String? _warehouseId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final levels = widget.fiche.levels;
    _warehouseId = levels.isNotEmpty ? levels.first.warehouseId : null;
  }

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _current {
    final l =
        widget.fiche.levels.where((l) => l.warehouseId == _warehouseId);
    return l.isEmpty ? 0 : l.first.qtyMilli;
  }

  Future<void> _apply() async {
    final counted = parseQty(_counted.text);
    if (counted == null) {
      setState(() => _error = 'Saisissez la quantité comptée.');
      return;
    }
    if (_warehouseId == null) {
      setState(() => _error = 'Aucun dépôt.');
      return;
    }
    final delta = counted - _current;
    if (delta == 0) {
      setState(() => _error = 'La quantité comptée égale le stock actuel.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = _note.text.trim();
      final draft = await widget.api.createDraft({
        'doc_type': 'STOCK_ADJUSTMENT',
        'doc_date': todayISO(),
        'warehouse_id': _warehouseId,
        'reason': _reason,
        'notes': note.isEmpty ? null : note,
        'lines': [
          {
            'product_id': widget.fiche.product.id,
            'description': widget.fiche.product.name,
            'qty_milli': delta,
            'unit_price': 0,
            'discount_pct': 0,
            'vat_rate': 0,
          }
        ],
      });
      await widget.api.postDocument(draft.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final warehouses = widget.fiche.levels;
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Ajuster le stock', style: T.h2),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fiche.product.name,
                style: T.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (warehouses.length > 1) ...[
              DropdownButton<String>(
                value: _warehouseId,
                isExpanded: true,
                items: [
                  for (final l in warehouses)
                    DropdownMenuItem(
                        value: l.warehouseId,
                        child:
                            Text('${l.warehouse} — ${fmtQty(l.qtyMilli)} u.')),
                ],
                onChanged: (v) => setState(() => _warehouseId = v),
              ),
              const SizedBox(height: 8),
            ],
            Text('Stock actuel : ${fmtQty(_current)}', style: T.small),
            const SizedBox(height: 10),
            TextField(
              controller: _counted,
              autofocus: true,
              style: T.monoBody,
              decoration:
                  const InputDecoration(labelText: 'Quantité comptée *'),
              onChanged: (_) => setState(() {}),
            ),
            if (parseQty(_counted.text) != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Écart : ${(parseQty(_counted.text)! - _current) > 0 ? '+' : ''}${fmtQty(parseQty(_counted.text)! - _current)}',
                    style: T.monoSmall.copyWith(
                        color: parseQty(_counted.text)! - _current >= 0
                            ? T.mintDark
                            : T.dangerDark)),
              ),
            const SizedBox(height: 12),
            const MicroLabel('MOTIF *'),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in kAdjustReasons)
                ChoiceChip(
                  label: Text(r),
                  selected: _reason == r,
                  selectedColor: T.mintTint,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              style: T.body,
              decoration: const InputDecoration(
                  labelText: 'Note (optionnelle — jamais un substitut au motif)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: T.small.copyWith(
                      color: T.dangerDark, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : "Valider l'ajustement",
            onPressed: _busy ? null : _apply),
      ],
    );
  }
}

// ---------------- Séparer en déclinaisons ----------------

/// Le logiciel ne connaît pas la répartition par parfum : le commerçant
/// compte, et la séparation est refusée tant que la somme ne tombe pas juste.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog(
      {required this.api, required this.fiche, required this.codes});
  final ApiClient api;
  final FicheData fiche;
  final List<BarcodeEntry> codes;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  late final List<TextEditingController> _suffixes;
  late final List<TextEditingController> _qtys;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suffixes = [
      for (final c in widget.codes)
        TextEditingController(text: c.label == 'principal' ? '' : c.label)
    ];
    _qtys = [for (final _ in widget.codes) TextEditingController()];
  }

  @override
  void dispose() {
    for (final c in [..._suffixes, ..._qtys]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _sum =>
      _qtys.fold(0, (s, c) => s + (parseQty(c.text) ?? 0));

  Future<void> _apply() async {
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < widget.codes.length; i++) {
      final suffix = _suffixes[i].text.trim();
      if (suffix.isEmpty) {
        setState(() => _error = 'Chaque déclinaison exige un suffixe.');
        return;
      }
      items.add({
        'barcode': widget.codes[i].code,
        'suffix': suffix,
        'qty_milli': parseQty(_qtys[i].text) ?? 0,
      });
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wh = widget.fiche.levels.isNotEmpty
          ? widget.fiche.levels.first.warehouseId
          : '';
      await widget.api.splitProduct(widget.fiche.product.id, wh, items);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.fiche.stockTotal;
    final ok = _sum == total;
    return AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Séparer en déclinaisons', style: T.h2),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Chaque code-barres devient sa propre déclinaison. Comptez la '
                'répartition : la somme doit égaler le stock actuel (${fmtQty(total)}).',
                style: T.small.copyWith(height: 1.4)),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.codes.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  SizedBox(
                      width: 130,
                      child:
                          Text(widget.codes[i].code, style: T.monoSmall)),
                  Expanded(
                    child: TextField(
                      controller: _suffixes[i],
                      style: T.body,
                      decoration:
                          const InputDecoration(hintText: 'Suffixe (Pomme…)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: _qtys[i],
                      style: T.monoBody,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: 'Qté'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ]),
              ),
            Row(children: [
              Text('Somme : ${fmtQty(_sum)} / ${fmtQty(total)}',
                  style: T.monoBody.copyWith(
                      color: ok ? T.mintDark : T.dangerDark,
                      fontWeight: FontWeight.w700)),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: T.small.copyWith(
                      color: T.dangerDark, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler')),
        PrimaryButton(
            label: _busy ? '…' : 'Séparer',
            onPressed: _busy || !ok ? null : _apply),
      ],
    );
  }
}
