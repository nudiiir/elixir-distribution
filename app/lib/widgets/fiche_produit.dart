import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:win32/win32.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../screens/products/product_detail_page.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../util/feedback.dart';
import '../util/file_dialog.dart';
import 'ui.dart';

/// Opens the product's detail page (« Produits / nom »), pushed in the
/// current navigator — inside the module, with the menu still visible.
/// [navigate] gives « ‹ Précédent » / « Suivant › » (Alt+↑ / Alt+↓) through
/// the list as displayed; [onShown] tells the list which product is shown.
/// [onEdit] / [onDuplicate] let the caller open the edit page itself (null =
/// the page opens it); [canEdit] hides Modifier / Dupliquer / Désactiver.
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
  FutureOr<void> Function(Product)? onDuplicate,
  bool canEdit = true,
}) {
  return Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => ProductDetailPage(
      api: api,
      productId: productId,
      canCost: canCost,
      canEdit: canEdit,
      onChanged: onChanged,
      onEdit: onEdit,
      onDuplicate: onDuplicate,
      onLabel: onLabel,
      navigate: navigate,
      onShown: onShown,
      focusMoves: focusMoves,
    ),
  ));
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
  return showAdjustStockFor(context, api, d);
}

/// « Ajuster le stock » for an already loaded fiche (quantity counted +
/// mandatory reason → a posted STOCK_ADJUSTMENT). True when posted.
Future<bool> showAdjustStockFor(
    BuildContext context, ApiClient api, FicheData fiche) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _AdjustDialog(api: api, fiche: fiche),
  );
  return done == true;
}

/// « Séparer en variantes » : each barcode of the product becomes its own
/// variant; the shopkeeper counts the split. True when done.
Future<bool> showSplitProduct(
    BuildContext context, ApiClient api, FicheData fiche) async {
  final codes = <BarcodeEntry>[
    if (fiche.product.barcode != null && fiche.product.barcode!.isNotEmpty)
      BarcodeEntry(code: fiche.product.barcode!, label: 'principal'),
    ...fiche.product.barcodesEx,
  ];
  if (codes.length < 2) {
    showToast(context,
        'Il faut au moins deux codes-barres pour séparer en variantes.',
        kind: ToastKind.warning);
    return false;
  }
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => _SplitDialog(api: api, fiche: fiche, codes: codes),
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
        width: 460,
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
                    'Différence : ${(parseQty(_counted.text)! - _current) > 0 ? '+' : ''}${fmtQty(parseQty(_counted.text)! - _current)}',
                    style: T.monoBody.copyWith(
                        color: parseQty(_counted.text)! - _current >= 0
                            ? T.mintDark
                            : T.dangerDark)),
              ),
            const SizedBox(height: 12),
            const MicroLabel('Motif *'),
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
            FieldError(_error),
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

// ---------------- Séparer en variantes ----------------

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
        setState(() => _error = 'Donnez un nom à chaque variante (Pomme, Rouge…).');
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
      title: Text('Séparer en variantes', style: T.h2),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Chaque code-barres devient sa propre variante. Comptez la '
                'répartition : la somme doit égaler le stock actuel (${fmtQty(total)}).',
                style: T.bodyMuted.copyWith(height: 1.4)),
            const SizedBox(height: 12),
            Row(children: [
              SizedBox(width: 160, child: Text('Code-barres', style: T.label)),
              Expanded(child: Text('Nom de la variante *', style: T.label)),
              const SizedBox(width: 10),
              SizedBox(width: 110, child: Text('Quantité', style: T.label)),
            ]),
            const SizedBox(height: 4),
            for (var i = 0; i < widget.codes.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  SizedBox(
                      width: 160,
                      child: Text(widget.codes[i].code,
                          style: T.monoBody, overflow: TextOverflow.ellipsis)),
                  Expanded(
                    child: TextField(
                      controller: _suffixes[i],
                      style: T.body,
                      decoration:
                          const InputDecoration(hintText: 'Pomme, Rouge, XL…'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _qtys[i],
                      style: T.monoBody,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: '0'),
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
            FieldError(_error),
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
