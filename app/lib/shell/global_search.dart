import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../widgets/product_thumb.dart';
import '../widgets/ui.dart';

/// One hit of the global search.
class SearchHit {
  SearchHit.product(Product this.product)
      : kind = 'product',
        partner = null,
        doc = null;
  SearchHit.partner(Partner this.partner)
      : kind = 'partner',
        product = null,
        doc = null;
  SearchHit.document(DocSummary this.doc)
      : kind = 'document',
        product = null,
        partner = null;

  final String kind;
  final Product? product;
  final Partner? partner;
  final DocSummary? doc;
}

/// Top-bar search with live results grouped by kind (products, customers and
/// suppliers, documents). ↑ ↓ to move, Enter opens, Esc closes;
/// Ctrl+K focuses it from anywhere (wired by the shell).
class GlobalSearch extends StatefulWidget {
  const GlobalSearch({
    super.key,
    required this.api,
    required this.focusNode,
    required this.onOpen,
    required this.onSubmitProducts,
    this.searchProducts = true,
    this.searchPartners = true,
    this.searchDocuments = true,
    this.documentSearch,
  });

  final ApiClient api;
  final FocusNode focusNode;
  final void Function(SearchHit) onOpen;

  /// Enter with no highlighted hit: open Produits filtered on the query.
  final void Function(String query) onSubmitProducts;
  final bool searchProducts;
  final bool searchPartners;
  final bool searchDocuments;

  /// Documents matching a query (number, partner…). Null = not available.
  final Future<List<DocSummary>> Function(String q)? documentSearch;

  @override
  State<GlobalSearch> createState() => _GlobalSearchState();
}

class _GlobalSearchState extends State<GlobalSearch> {
  final _ctrl = TextEditingController();
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _debounce;
  List<SearchHit> _hits = const [];
  Map<String, String> _partnerNames = const {};
  int _cursor = 0;
  bool _loading = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (widget.focusNode.hasFocus) {
      if (_ctrl.text.trim().isNotEmpty) _portal.show();
      _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
    } else {
      // let a click on a result land before closing
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && !widget.focusNode.hasFocus) _portal.hide();
      });
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _hits = const []);
      _portal.hide();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () => _run(q.trim()));
  }

  Future<void> _run(String q) async {
    final seq = ++_seq;
    setState(() => _loading = true);
    _portal.show();
    final hits = <SearchHit>[];
    final names = <String, String>{};
    try {
      final results = await Future.wait<Object>([
        widget.searchProducts
            ? widget.api.products(q: q, limit: 6)
            : Future.value(const <Product>[]),
        widget.searchPartners
            ? widget.api.partners(q: q, limit: 5)
            : Future.value(const <Partner>[]),
        widget.searchDocuments && widget.documentSearch != null
            ? widget.documentSearch!(q).catchError((_) => const <DocSummary>[])
            : Future.value(const <DocSummary>[]),
      ]);
      for (final p in results[0] as List<Product>) {
        hits.add(SearchHit.product(p));
      }
      for (final p in results[1] as List<Partner>) {
        hits.add(SearchHit.partner(p));
        names[p.id] = p.name;
      }
      for (final d in (results[2] as List<DocSummary>).take(5)) {
        hits.add(SearchHit.document(d));
      }
    } catch (_) {}
    if (!mounted || seq != _seq) return;
    setState(() {
      _hits = hits;
      _partnerNames = names;
      _cursor = 0;
      _loading = false;
    });
  }

  void _open(SearchHit h) {
    _portal.hide();
    widget.focusNode.unfocus();
    _ctrl.clear();
    setState(() => _hits = const []);
    widget.onOpen(h);
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _portal.hide();
      widget.focusNode.unfocus();
      return KeyEventResult.handled;
    }
    if (_hits.isEmpty) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _cursor = (_cursor + 1) % _hits.length);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _cursor = (_cursor - 1 + _hits.length) % _hits.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit(String q) {
    if (_hits.isNotEmpty && _portal.isShowing) {
      _open(_hits[_cursor.clamp(0, _hits.length - 1)]);
    } else if (q.trim().isNotEmpty) {
      widget.onSubmitProducts(q.trim());
      _ctrl.clear();
      widget.focusNode.unfocus();
    }
  }

  String _docLabel(String t) => switch (t) {
        'SALE_TICKET' => 'Ticket',
        'SALE_INVOICE' => 'Facture',
        'QUOTE' => 'Devis',
        'DELIVERY_NOTE' => 'Bon de livraison',
        'SALE_CREDIT_NOTE' => 'Avoir client',
        'PURCHASE_ORDER' => 'Bon de commande',
        'PURCHASE_RECEIPT' => 'Réception',
        'PURCHASE_INVOICE' => 'Facture fournisseur',
        'PURCHASE_CREDIT_NOTE' => 'Avoir fournisseur',
        'STOCK_ADJUSTMENT' => 'Ajustement',
        'STOCK_TRANSFER' => 'Transfert',
        'INVENTORY_COUNT' => 'Inventaire',
        'PAYMENT_IN' => 'Encaissement',
        'PAYMENT_OUT' => 'Paiement fournisseur',
        _ => t,
      };

  Widget _results() {
    final groups = <String, List<int>>{};
    for (var i = 0; i < _hits.length; i++) {
      groups.putIfAbsent(_hits[i].kind, () => []).add(i);
    }
    const titles = {
      'product': 'Produits',
      'partner': 'Clients et fournisseurs',
      'document': 'Documents',
    };
    return Material(
      color: T.surface,
      elevation: 8,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(T.rInner),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 440),
        child: _loading && _hits.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: T.mintDeep)),
                  SizedBox(width: 10),
                  Text('Recherche…', style: T.bodyMuted),
                ]),
              )
            : _hits.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Aucun résultat. Entrée : chercher dans les produits.',
                        style: T.bodyMuted),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    children: [
                      for (final g in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                          child: MicroLabel(titles[g.key] ?? g.key),
                        ),
                        for (final i in g.value) _hitRow(i),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Text('↑ ↓ pour choisir · Entrée pour ouvrir · Échap pour fermer',
                            style: T.small.copyWith(fontSize: 12.5)),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _hitRow(int i) {
    final h = _hits[i];
    final selected = i == _cursor;
    Widget leading;
    String title;
    String sub;
    switch (h.kind) {
      case 'product':
        final p = h.product!;
        leading = ProductThumb(api: widget.api, product: p, size: 28);
        title = p.name;
        sub = [
          if ((p.barcode ?? '').isNotEmpty) p.barcode!,
          fmtDA(p.effectivePriceTTC),
        ].join(' · ');
      case 'partner':
        final p = h.partner!;
        leading = const _HitIcon(Icons.person_outline_rounded);
        title = p.name;
        sub = [
          p.kind == 'supplier' ? 'Fournisseur' : p.kind == 'both' ? 'Client et fournisseur' : 'Client',
          if ((p.phone ?? '').isNotEmpty) p.phone!,
        ].join(' · ');
      default:
        final d = h.doc!;
        leading = const _HitIcon(Icons.receipt_long_outlined);
        title = '${_docLabel(d.docType)} ${d.number ?? '(brouillon)'}';
        sub = [
          d.docDate,
          if (d.partnerId != null && _partnerNames[d.partnerId] != null)
            _partnerNames[d.partnerId]!,
          fmtDA(d.totalTTC),
        ].join(' · ');
    }
    return InkWell(
      onTap: () => _open(h),
      child: Container(
        color: selected ? T.mintTint : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
            ]),
          ),
          if (selected) const Icon(Icons.keyboard_return_rounded, size: 14, color: T.faint),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 6),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 460, child: _results()),
          ),
        ),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: Focus(
            onKeyEvent: _onKey,
            skipTraversal: true,
            child: TextField(
              controller: _ctrl,
              focusNode: widget.focusNode,
              onChanged: _onChanged,
              onSubmitted: _submit,
              style: T.body,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Rechercher un produit, un client, un document…',
                hintStyle: T.bodyMuted.copyWith(color: T.ghost),
                prefixIcon: const Icon(Icons.search, size: 17, color: T.faint),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    widthFactor: 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: T.surface,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: T.border),
                      ),
                      child: Text('Ctrl+K', style: T.label.copyWith(fontSize: 11.5)),
                    ),
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HitIcon extends StatelessWidget {
  const _HitIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: T.bg, borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 16, color: T.muted),
      );
}
