import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../util/prefs.dart';
import '../../util/analysis_links.dart';
import '../../widgets/analyze_button.dart';
import '../../widgets/app_page.dart';
import '../../widgets/charts.dart';
import '../../widgets/doc_list.dart' show showDocDetailDialog;
import '../../widgets/fiche_produit.dart'
    show
        pasteProductPhoto,
        pickProductPhoto,
        printProductLabels,
        showAdjustStockFor,
        showSplitProduct;
import '../../widgets/product_thumb.dart';
import '../../widgets/ui.dart';
import '../product_page.dart';
import '../pricing/product_pricing_page.dart' show openProductPricing;

/// Product record (« Fiche produit ») — the page where the shopkeeper answers the question that
/// decides whether he trusts the software: « why does it say 45 when I count
/// 43 ». Everything is recomputed, nothing stored, and every figure leads
/// back to its documents in two clicks.
///
/// Pushed inside the module's navigator (« Produits / nom »). [navigate]
/// gives « ‹ Précédent » / « Suivant › » (and Alt+↑ / Alt+↓) through the
/// list as displayed; [onShown] tells the list which product is shown.
class ProductDetailPage extends StatefulWidget {
  const ProductDetailPage({
    super.key,
    required this.api,
    required this.productId,
    required this.canCost,
    this.canEdit = true,
    this.onChanged,
    this.onEdit,
    this.onDuplicate,
    this.onLabel,
    this.navigate,
    this.onShown,
    this.focusMoves = false,
  });
  final ApiClient api;
  final String productId;
  final bool canCost;
  final bool canEdit;
  final VoidCallback? onChanged;
  final FutureOr<void> Function(Product)? onEdit;
  final FutureOr<void> Function(Product)? onDuplicate;
  final void Function(Product)? onLabel;
  final String? Function(String currentId, int delta)? navigate;
  final ValueChanged<String>? onShown;
  final bool focusMoves;

  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

/// Movement filter: label → document types (null = all).
const _moveFilters = <(String, Set<String>?)>[
  ('Tous', null),
  ('Ventes', {'SALE_TICKET', 'SALE_INVOICE', 'DELIVERY_NOTE'}),
  ('Achats', {'PURCHASE_RECEIPT', 'PURCHASE_INVOICE'}),
  ('Retours', {'SALE_CREDIT_NOTE', 'PURCHASE_CREDIT_NOTE'}),
  ('Ajustements', {'STOCK_ADJUSTMENT'}),
  ('Inventaires', {'INVENTORY_COUNT'}),
  ('Transferts', {'STOCK_TRANSFER'}),
];

/// Movement period: label → days (null = whole history).
const _periods = <(String, int?)>[
  ('7 jours', 7),
  ('30 jours', 30),
  ('90 jours', 90),
  ('1 an', 365),
  ('Tout', null),
];

const _typeLabels = {
  'SALE_TICKET': 'Ticket',
  'SALE_INVOICE': 'Facture',
  'SALE_CREDIT_NOTE': 'Avoir client',
  'DELIVERY_NOTE': 'Bon de livraison',
  'PURCHASE_RECEIPT': 'Bon de réception',
  'PURCHASE_INVOICE': 'Facture fournisseur',
  'PURCHASE_CREDIT_NOTE': 'Retour fournisseur',
  'STOCK_ADJUSTMENT': 'Ajustement',
  'STOCK_TRANSFER': 'Transfert',
  'INVENTORY_COUNT': 'Inventaire',
};

class _ProductDetailPageState extends State<ProductDetailPage> {
  late String _id = widget.productId;
  FicheData? _data;
  String? _error;
  bool _busyPhoto = false;
  bool _busy = false;
  int _moveFilter = 0;
  late int _period = UiPrefs.instance.get<int>('fiche', 'period') ?? 4;
  List<Category> _cats = const [];
  final _movesKey = GlobalKey();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (_period < 0 || _period >= _periods.length) _period = 4;
    _load(scrollToMoves: widget.focusMoves);
    widget.api.categories().then((c) {
      if (mounted) setState(() => _cats = c);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _scroll.dispose();
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
    } catch (_) {
      if (mounted) setState(() => _error = 'Serveur injoignable.');
    }
  }

  bool _canStep(int delta) =>
      widget.navigate != null && widget.navigate!(_id, delta) != null;

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
    _load();
  }

  void _changed() {
    _load();
    widget.onChanged?.call();
  }

  String _catName(String? id) {
    for (final c in _cats) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  // ---------------------------------------------------------------- actions

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

  Future<void> _duplicate(Product p) async {
    if (widget.onDuplicate != null) {
      await widget.onDuplicate!(p);
    } else {
      final saved = await openProductPage(context,
          api: widget.api, template: p, showCost: widget.canCost);
      if (saved == true) widget.onChanged?.call();
    }
  }

  void _labels(Product p) {
    if (widget.onLabel != null) {
      widget.onLabel!(p);
    } else {
      printProductLabels(context, widget.api, [p]);
    }
  }

  Future<void> _adjust() async {
    final d = _data;
    if (d == null) return;
    if (await showAdjustStockFor(context, widget.api, d)) {
      _changed();
      if (mounted) showToast(context, 'Stock ajusté');
    }
  }

  Future<void> _split() async {
    final d = _data;
    if (d == null) return;
    if (await showSplitProduct(context, widget.api, d)) _changed();
  }

  Future<void> _setActive(Product p, bool active) async {
    if (!active) {
      final ok = await confirmAction(context,
          title: 'Désactiver « ${p.name} » ?',
          message:
              'Le produit disparaît de la caisse et des listes ; son historique et son stock restent. Vous pourrez le réactiver.',
          confirmLabel: 'Désactiver',
          danger: true);
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.bulkProducts([p.id], active ? 'activate' : 'deactivate');
      if (!mounted) return;
      showToast(context, active ? 'Produit réactivé' : 'Produit désactivé');
      _changed();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- Photos ----

  Future<void> _addPhoto({bool paste = false}) async {
    final p = _data?.product;
    if (p == null || _busyPhoto) return;
    final img = paste ? await pasteProductPhoto() : await pickProductPhoto();
    if (!mounted) return;
    if (img == null) {
      if (paste) {
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
      if (mounted) {
        showToast(context, 'Photo impossible : $e', kind: ToastKind.error);
      }
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

  // ---------------------------------------------------------------- build

  List<Crumb> _crumbs(String name) => [
        Crumb('Produits',
            () => Navigator.of(context).popUntil((r) => r.isFirst)),
        Crumb(name),
      ];

  List<Widget> _navActions() => [
        if (widget.navigate != null) ...[
          PageAction(
              label: '‹ Précédent',
              onPressed: _canStep(-1) ? () => _step(-1) : null),
          PageAction(
              label: 'Suivant ›',
              onPressed: _canStep(1) ? () => _step(1) : null),
          const SizedBox(width: 12),
        ],
      ];

  /// The header actions wrap onto a second line rather than overflow on a
  /// narrow window.
  Widget _actionsWrap(List<Widget> children) => Flexible(
        flex: 3,
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: children,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final page = d == null
        ? AppPage(
            crumbs: _crumbs('Fiche produit'),
            title: _error != null ? 'Fiche indisponible' : 'Chargement…',
            actions: [_actionsWrap(_navActions())],
            body: _error != null
                ? Card14(
                    child: Row(children: [
                      const Icon(Icons.cloud_off_rounded,
                          size: 22, color: T.danger),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_error!, style: T.body)),
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Réessayer'),
                      ),
                    ]),
                  )
                : const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBar(width: 320, height: 16),
                      SizedBox(height: 14),
                      SkeletonBar(width: 520, height: 14),
                      SizedBox(height: 14),
                      SkeletonBar(width: 420, height: 14),
                    ],
                  ),
          )
        : _page(d);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
            _step(-1),
      },
      child: page,
    );
  }

  Widget _page(FicheData d) {
    final p = d.product;
    final cat = _catName(p.categoryId);
    return AppPage(
      crumbs: _crumbs(p.name),
      title: p.name,
      subtitle: Wrap(spacing: 6, runSpacing: 6, children: [
        if (!p.active)
          const MintChip('Inactif', color: T.dangerTint, fg: T.dangerDark),
        if (p.barcode != null && p.barcode!.isNotEmpty)
          MintChip(p.barcode!, color: T.cream, fg: T.muted),
        if (p.barcodesEx.isNotEmpty)
          MintChip(
              '+${p.barcodesEx.length} code${p.barcodesEx.length > 1 ? 's' : ''}-barres',
              color: T.cream,
              fg: T.muted),
        if (cat.isNotEmpty) MintChip(cat, color: T.mintTint, fg: T.mintDark),
        if (p.brand.isNotEmpty) MintChip(p.brand, color: T.cream, fg: T.muted),
        if (p.variantLabel != null)
          MintChip('Variante : ${p.variantLabel}',
              color: T.cream, fg: T.muted),
      ]),
      actions: [
        _actionsWrap([
          ..._navActions(),
          if (widget.canEdit)
            p.active
                ? PageAction(
                    label: 'Désactiver',
                    icon: Icons.block_rounded,
                    danger: true,
                    onPressed: _busy ? null : () => _setActive(p, false))
                : PageAction(
                    label: 'Réactiver',
                    icon: Icons.restore_rounded,
                    onPressed: _busy ? null : () => _setActive(p, true)),
          if (widget.canEdit)
            PageAction(
                label: 'Dupliquer',
                icon: Icons.copy_all_rounded,
                onPressed: () => _duplicate(p)),
          AnalyzeButton(seeds: [
            AnalysisLinks.product(p.id, p.name, canCost: widget.canCost),
            AnalysisLinks.productCustomers(p.id, p.name),
            if (!p.isService) AnalysisLinks.productMovements(p.id, p.name),
          ]),
          PageAction(
              label: 'Étiquettes',
              icon: Icons.qr_code_2_rounded,
              onPressed: () => _labels(p)),
          if (widget.api.user?.can('pricing') ?? false)
            PageAction(
                label: 'Tarifs et offres',
                icon: Icons.sell_outlined,
                onPressed: () => openProductPricing(context, widget.api, p)),
          if (!p.isService && (widget.api.user?.can('stock_adjust') ?? true))
            PageAction(
                label: 'Ajuster le stock',
                icon: Icons.tune_rounded,
                onPressed: _adjust),
          if (widget.canEdit)
            PageAction(
                label: 'Modifier',
                icon: Icons.edit_outlined,
                primary: true,
                onPressed: () => _edit(p)),
        ]),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _infos(d),
          _alerts(d),
          if (!p.isService) _levels(d),
          if (Features.instance.lots &&
              (d.lots.isNotEmpty || p.trackLots || p.trackExpiry))
            _lots(d),
          _variants(d),
          if (!p.isService) _sales(d),
          KeyedSubtree(key: _movesKey, child: _moves(d)),
          if (widget.canCost && d.suppliers.isNotEmpty) _suppliers(d),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- sections

  /// Margin on selling price excl. tax vs average cost — never incl. tax vs excl. tax (spec §2.4).
  String _marginText(int saleTTC, int vatRate, int? cost) {
    if (cost == null || cost <= 0 || saleTTC <= 0) return '—';
    final pvHT = roundDiv(saleTTC * 10000, 10000 + vatRate);
    final m = roundDiv((pvHT - cost) * 10000, cost);
    return '${(m / 100).toStringAsFixed(1).replaceAll('.', ',')} %';
  }

  Widget _infos(FicheData d) {
    final p = d.product;
    // When total stock is zero, every average shows a dash, never
    // a zero: an average of nothing is not zero dinars.
    final stock = d.stockTotal;
    final cost = d.achatPondere;
    int? avgSale;
    if (d.variants.isEmpty) {
      avgSale = p.priceRetail;
    } else if (stock > 0) {
      var sum = 0, qty = 0;
      for (final va in d.variants) {
        sum += (va.stockMilli * va.product.priceRetail) ~/ 1000;
        qty += va.stockMilli;
      }
      if (qty > 0) avgSale = (sum * 1000) ~/ qty;
    }
    final unit = p.isWeighable || p.unit == 'kg' ? ' kg' : '';
    final vat = '${(p.vatRate / 100).toStringAsFixed(p.vatRate % 100 == 0 ? 0 : 1)} %';
    final facts = <(String, String)>[
      (
        d.variants.isEmpty ? 'Prix de vente TTC' : 'Prix de vente moyen TTC',
        avgSale == null ? '—' : fmtDA(avgSale)
      ),
      if (widget.canCost && !p.isService)
        ('Coût moyen HT', cost == null ? '—' : fmtDA(cost)),
      if (widget.canCost && !p.isService)
        ('Marge', _marginText(avgSale ?? p.priceRetail, p.vatRate, cost)),
      ('TVA', vat),
      if (!p.isService) ('Stock total', '${fmtQty(stock)}$unit'),
      if (widget.canCost && !p.isService)
        ('Valeur du stock (au coût)', stock > 0 ? fmtDA(d.valeurStock) : '—'),
      if (Features.instance.wholesale &&
          p.priceWholesale != null &&
          p.priceWholesale! > 0)
        ('Prix demi-gros TTC', fmtDA(p.priceWholesale!)),
      if (p.promoActive)
        (
          'Promotion en cours',
          '${fmtDA(p.promoPrice!)}${p.promoEnd != null ? ' jusqu’au ${p.promoEnd}' : ''}'
        ),
      if (!p.isService && p.minStockMilli > 0)
        ('Stock minimum (alerte)', fmtQty(p.minStockMilli)),
      if (p.warrantyMonths > 0) ('Garantie', '${p.warrantyMonths} mois'),
    ];
    final tracking = [
      if (p.isService) 'Service — sans stock',
      if (p.trackLots || p.trackExpiry) 'Lot et date de péremption',
      if (p.trackSerials) 'N° de série',
      if (p.isWeighable) 'Vendu au poids',
      if (p.packagings.isNotEmpty)
        'Emballages : ${p.packagings.map((k) => '${k.name} × ${fmtQty(k.factorMilli)}').join(', ')}',
    ];
    return PageSection(
      title: 'Informations',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _mainPhoto(p),
          const SizedBox(width: 24),
          Expanded(child: FactGrid(facts: facts, columns: 3)),
        ]),
        if (tracking.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 6, children: [
            Text('Suivi :', style: T.label),
            for (final t in tracking)
              MintChip(t, color: T.mintTint, fg: T.mintDark),
          ]),
        ],
        if (p.imageCount > 1) ...[
          const SizedBox(height: 16),
          Text('Autres photos', style: T.label),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 1; i < p.imageCount; i++) _photoTile(p, i),
          ]),
        ],
      ]),
    );
  }

  Widget _mainPhoto(Product p) {
    return SizedBox(
      width: 168,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (p.imageCount == 0)
          ProductThumb(api: widget.api, product: p, size: 140)
        else
          _image(p, 0, 140),
        const SizedBox(height: 8),
        if (p.imageCount == 0)
          Text('Aucune photo — elle s’affiche à la caisse, dans la liste et sur la boutique.',
              style: T.small),
        if (p.imageCount > 0)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: T.dangerDark),
            onPressed: _busyPhoto ? null : () => _photoAction(p, 0, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Supprimer la photo'),
          ),
        TextButton.icon(
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
          label: const Text('Coller une image'),
        ),
      ]),
    );
  }

  Widget _image(Product p, int i, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(
              color: i == 0 ? T.mintDeep : T.border, width: i == 0 ? 1.5 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(T.rInner - 1),
          child: Image.network(
              widget.api.productImageUrl(p.id, p.imageRev,
                  thumb: size < 200, index: i),
              headers: widget.api.authHeaders,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: T.ghost,
                  size: 22)),
        ),
      );

  /// A secondary photo with its two labelled actions (no hover-only buttons).
  Widget _photoTile(Product p, int i) => SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _image(p, i, 96),
          TextButton.icon(
            onPressed: _busyPhoto ? null : () => _photoAction(p, i, false),
            icon: const Icon(Icons.star_outline_rounded, size: 16),
            label: const Text('Mettre en premier'),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: T.dangerDark),
            onPressed: _busyPhoto ? null : () => _photoAction(p, i, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Supprimer'),
          ),
        ]),
      );

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
            'Lot ${l.lotNumber} périmé depuis ${-days} jour${-days > 1 ? 's' : ''} (${fmtQty(l.qtyMilli)} en stock)'));
      } else if (days <= 90) {
        alerts.add(_alertRow(Icons.hourglass_bottom_rounded, T.warnDark,
            'Lot ${l.lotNumber} : péremption dans $days jour${days > 1 ? 's' : ''} (${fmtQty(l.qtyMilli)} en stock)'));
      }
    }
    if (!d.product.isService) {
      if (d.stockTotal <= 0) {
        alerts.add(_alertRow(
            Icons.remove_shopping_cart_outlined, T.dangerDark, 'En rupture de stock'));
      } else if (d.product.minStockMilli > 0 &&
          d.stockTotal < d.product.minStockMilli) {
        alerts.add(_alertRow(Icons.trending_down_rounded, T.warnDark,
            'Sous le minimum (${fmtQty(d.product.minStockMilli)})'));
      }
    }
    // Stock on the main product while variants exist:
    // it is sellable on no variant until it is split.
    if (d.variants.isNotEmpty && d.stockTotal > 0) {
      alerts.add(_alertRow(Icons.call_split_rounded, T.warnDark,
          '${fmtQty(d.stockTotal)} à répartir entre les variantes'));
    }
    if (alerts.isEmpty) return const SizedBox.shrink();
    return PageSection(
      title: 'Alertes',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: alerts),
    );
  }

  Widget _alertRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: T.body.copyWith(color: color, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  /// Header row of the small tables of this page.
  Widget _head(List<(String, double?, bool)> cols) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          for (final (label, width, end) in cols)
            width == null
                ? Expanded(child: Text(label, style: T.label))
                : SizedBox(
                    width: width,
                    child: Text(label,
                        style: T.label,
                        textAlign: end ? TextAlign.end : TextAlign.start)),
        ]),
      );

  Widget _levels(FicheData d) {
    return PageSection(
      title: 'Stock par dépôt',
      child: d.levels.isEmpty
          ? Text('Aucun mouvement de stock pour l’instant.', style: T.bodyMuted)
          : Column(children: [
              _head([
                ('Dépôt', null, false),
                ('Quantité', 130, true),
                if (widget.canCost) ('Coût moyen HT', 170, true),
              ]),
              const Divider(height: 1),
              for (final l in d.levels)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    Expanded(child: Text(l.warehouse, style: T.body)),
                    SizedBox(
                      width: 130,
                      child: Text(fmtQty(l.qtyMilli),
                          textAlign: TextAlign.end,
                          style: T.monoBody.copyWith(
                              color: l.qtyMilli <= 0 ? T.dangerDark : T.ink)),
                    ),
                    if (widget.canCost)
                      SizedBox(
                        width: 170,
                        child: Text(
                            l.qtyMilli == 0 ? '—' : fmtDA(l.avgCost),
                            textAlign: TextAlign.end,
                            style: T.monoBody.copyWith(color: T.muted)),
                      ),
                  ]),
                ),
            ]),
    );
  }

  Widget _lots(FicheData d) {
    final today = DateTime.now();
    final lots = d.lots.where((l) => l.qtyMilli != 0).toList();
    return PageSection(
      title: 'Lots par date de péremption',
      child: lots.isEmpty
          ? Text(
              'Aucun lot en stock. Les lots se créent au bon de réception.',
              style: T.bodyMuted)
          : Column(children: [
              _head([
                ('N° de lot', 200, false),
                ('Péremption', null, false),
                ('Quantité', 130, true),
              ]),
              const Divider(height: 1),
              for (final l in lots)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    SizedBox(
                        width: 200,
                        child: Text(l.lotNumber,
                            style: T.monoBody,
                            overflow: TextOverflow.ellipsis)),
                    Expanded(
                      child: Builder(builder: (context) {
                        if (l.expiryDate == null) {
                          return Text('sans date de péremption', style: T.small);
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
                        final rel = days == null
                            ? ''
                            : days < 0
                                ? '  (périmé depuis ${-days} j)'
                                : '  (dans $days j)';
                        return Text('${l.expiryDate}$rel',
                            style: T.monoBody.copyWith(color: color));
                      }),
                    ),
                    SizedBox(
                        width: 130,
                        child: Text(fmtQty(l.qtyMilli),
                            textAlign: TextAlign.end, style: T.monoBody)),
                  ]),
                ),
            ]),
    );
  }

  Widget _variants(FicheData d) {
    final p = d.product;
    if (d.variants.isEmpty) {
      // Only a « main » product without variants can be split.
      if (!Features.instance.variants || p.isService || p.parentProductId != null) {
        return const SizedBox.shrink();
      }
      final codes = (p.barcode != null && p.barcode!.isNotEmpty ? 1 : 0) +
          p.barcodesEx.length;
      return PageSection(
        title: 'Variantes (taille, couleur…)',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              codes >= 2
                  ? 'Ce produit a $codes codes-barres. Vous pouvez en faire des variantes : chaque code-barres devient une variante avec son propre stock.'
                  : 'Ce produit n’a pas de variantes. Pour en créer (taille, couleur…), cliquez sur « Modifier ».',
              style: T.bodyMuted),
          if (codes >= 2 && widget.canEdit) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _split,
              icon: const Icon(Icons.call_split_rounded, size: 18),
              label: const Text('Séparer en variantes'),
            ),
          ],
        ]),
      );
    }
    return PageSection(
      title: 'Variantes (${d.variants.length})',
      child: Column(children: [
        _head([
          ('Variante', null, false),
          ('Code-barres', 170, false),
          ('Prix de vente TTC', 160, true),
          ('Stock', 110, true),
        ]),
        const Divider(height: 1),
        for (final v in d.variants)
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProductDetailPage(
                      api: widget.api,
                      productId: v.product.id,
                      canCost: widget.canCost,
                      canEdit: widget.canEdit,
                      onChanged: widget.onChanged,
                      onEdit: widget.onEdit,
                      onDuplicate: widget.onDuplicate,
                      onLabel: widget.onLabel,
                    ))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                Expanded(
                    child: Text(v.product.variantLabel ?? v.product.name,
                        style: T.body.copyWith(color: T.mintDark),
                        overflow: TextOverflow.ellipsis)),
                SizedBox(
                    width: 170,
                    child: Text(v.product.barcode ?? '—',
                        style: T.monoBody, overflow: TextOverflow.ellipsis)),
                SizedBox(
                  width: 160,
                  child: Text(fmtDA(v.product.priceRetail),
                      textAlign: TextAlign.end, style: T.monoBody),
                ),
                SizedBox(
                  width: 110,
                  child: Text(fmtQty(v.stockMilli),
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          color: v.stockMilli <= 0 ? T.dangerDark : T.ink)),
                ),
              ]),
            ),
          ),
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
    return PageSection(
      title: 'Ventes des 30 derniers jours',
      trailing: Text('${fmtQty(total)} vendus', style: T.monoBody),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: d.sales30d.length >= 2 && total > 0
              ? Tooltip(
                  message:
                      '${d.sales30d.first.date} → ${d.sales30d.last.date} · moyenne ${fmtQty(d.avgDailySalesMilli)} par jour',
                  child: Sparkline(
                      values: [
                        for (final s in d.sales30d) s.qtyMilli / 1000.0
                      ],
                      height: 56),
                )
              : SizedBox(
                  height: 56,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('Aucune vente sur la période.',
                        style: T.bodyMuted),
                  ),
                ),
        ),
        const SizedBox(width: 24),
        SizedBox(
          width: 260,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Couverture du stock', style: T.label),
            const SizedBox(height: 4),
            Text(covText,
                style: T.body.copyWith(
                    color: covColor, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                d.avgDailySalesMilli > 0
                    ? 'au rythme de ${fmtQty(d.avgDailySalesMilli)} vendus par jour'
                    : 'stock ÷ ventes moyennes par jour',
                style: T.small),
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
            height: 34,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: active ? T.ink : T.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: active ? T.ink : T.border),
            ),
            child: Text(label,
                style: T.small.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : T.ink)),
          ),
        ),
      );

  Widget _moves(FicheData d) {
    final moves = _filteredMoves(d);
    final multiDepot = {for (final m in d.moves) m.warehouseId}.length > 1;
    return PageSection(
      title: 'Mouvements de stock',
      trailing: Text(
          d.moves.length >= 200
              ? '200 derniers mouvements'
              : '${moves.length} mouvement${moves.length > 1 ? 's' : ''}',
          style: T.small),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 80,
              child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Type', style: T.label))),
          Expanded(
            child: Wrap(children: [
              for (var i = 0; i < _moveFilters.length; i++)
                _chip(_moveFilters[i].$1, _moveFilter == i,
                    () => setState(() => _moveFilter = i)),
            ]),
          ),
        ]),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 80,
              child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Période', style: T.label))),
          Expanded(
            child: Wrap(children: [
              for (var i = 0; i < _periods.length; i++)
                _chip(_periods[i].$1, _period == i, () {
                  setState(() => _period = i);
                  UiPrefs.instance.set('fiche', 'period', i);
                }),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        _head([
          ('Date', 110, false),
          ('Type', 170, false),
          ('Document', 150, false),
          ('Dépôt', null, false),
          ('Quantité', 100, true),
          (multiDepot ? 'Stock du dépôt après' : 'Stock après', 150, true),
        ]),
        const Divider(height: 1),
        if (moves.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
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
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  SizedBox(
                      width: 110,
                      child: Text(
                          m.date.length >= 10 ? m.date.substring(0, 10) : m.date,
                          style: T.monoBody)),
                  SizedBox(
                      width: 170,
                      child: Text(
                          [
                            _typeLabels[m.docType] ?? m.docType,
                            if (m.reason != null && m.reason!.isNotEmpty)
                              m.reason!,
                          ].join(' · '),
                          style: T.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis)),
                  SizedBox(
                      width: 150,
                      child: Text(m.docNumber ?? '—',
                          style: T.monoBody.copyWith(color: T.mintDark),
                          overflow: TextOverflow.ellipsis)),
                  Expanded(
                      child: Text(m.warehouse,
                          style: T.body, overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    width: 100,
                    child: Text(
                      '${m.qtyMilli > 0 ? '+' : ''}${fmtQty(m.qtyMilli)}',
                      textAlign: TextAlign.end,
                      style: T.monoBody.copyWith(
                          color: m.qtyMilli >= 0 ? T.mintDark : T.dangerDark),
                    ),
                  ),
                  SizedBox(
                    width: 150,
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
    return PageSection(
      title: 'Fournisseurs',
      child: Column(children: [
        _head([
          ('Fournisseur', null, false),
          ('Dernier achat', 140, false),
          ('Dernier prix payé HT', 190, true),
        ]),
        const Divider(height: 1),
        for (final s in d.suppliers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(children: [
              Expanded(
                  child: Text(s.partner,
                      style: T.body, overflow: TextOverflow.ellipsis)),
              SizedBox(
                  width: 140,
                  child: Text(
                      s.date.length >= 10 ? s.date.substring(0, 10) : s.date,
                      style: T.monoBody)),
              SizedBox(
                width: 190,
                child: Text(fmtDA(s.unitCost),
                    textAlign: TextAlign.end, style: T.monoBody),
              ),
            ]),
          ),
      ]),
    );
  }
}
