import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/config.dart';
import '../util/escpos.dart';
import '../util/raw_printer.dart';
import '../widgets/doc_editor.dart' show showPartnerPicker;
import '../widgets/ui.dart';

// Pastel avatar palette (from the Elixir handoff tiles).
const _pastels = [
  (Color(0xFFB9F0DC), Color(0xFF00795C)),
  (Color(0xFFFFE3C2), Color(0xFFC97A1A)),
  (Color(0xFFCFDCFA), Color(0xFF4A63B8)),
  (Color(0xFFF9D3DC), Color(0xFFB8556B)),
  (Color(0xFFE4E6F9), Color(0xFF6B5AC2)),
];

(Color, Color) pastelFor(String name) =>
    _pastels[name.codeUnits.fold(0, (s, c) => s + c) % _pastels.length];

class CartLine {
  CartLine(this.product) : qtyMilli = 1000;
  final Product product;
  int qtyMilli;
  int discountPct = 0; // percent * 100

  /// All money math depends on the customer's price tier, resolved at
  /// render/checkout time so picking the client later reprices the cart.
  int unitTTC(String level) => product.priceFor(level);
  int unitHT(String level) =>
      ((unitTTC(level) * 10000) + (10000 + product.vatRate) ~/ 2) ~/
      (10000 + product.vatRate);
  int lineHT(String level) {
    final gross = roundDiv(unitHT(level) * qtyMilli, 1000);
    return roundDiv(gross * (10000 - discountPct), 10000);
  }

  int lineVAT(String level) => roundDiv(lineHT(level) * product.vatRate, 10000);
  int lineTTC(String level) => lineHT(level) + lineVAT(level);
}

class PosScreen extends StatefulWidget {
  const PosScreen(
      {super.key,
      required this.api,
      required this.config,
      required this.user,
      this.cashierName = ''});
  final ApiClient api;
  final LocalConfig config;
  final User user;
  final String cashierName;

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;

  List<Product> _results = const [];
  Map<String, int> _stockByProduct = const {};
  final List<CartLine> _cart = [];
  String _paymentMethod = 'cash';
  Partner? _client;
  String? _warehouseId;
  bool _checkingOut = false;
  CaisseSession? _session;
  bool _sessionLoading = true;
  Map<String, String> _company = const {};
  List<Category> _cats = const [];
  String? _catFilter;
  Set<String> _favorites = {};

  bool get _canDiscount => widget.user.can('discount');
  String get _priceLevel => _client?.priceLevel ?? 'retail';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final whs = await widget.api.warehouses();
      if (whs.isNotEmpty && mounted) {
        setState(() => _warehouseId =
            whs.firstWhere((w) => w.isDefault, orElse: () => whs.first).id);
      }
    } catch (_) {}
    _loadSession();
    _loadCompany();
    _loadCats();
    _refreshStock();
    _search('');
  }

  Future<void> _loadCats() async {
    try {
      final cats = await widget.api.categories();
      if (mounted) setState(() => _cats = cats);
    } catch (_) {}
  }

  Future<void> _loadSession() async {
    try {
      final s = await widget.api.caisseCurrent();
      if (mounted) {
        setState(() {
          _session = s;
          _sessionLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sessionLoading = false);
    }
  }

  Future<void> _loadCompany() async {
    try {
      final s = await widget.api.settings();
      if (mounted) {
        setState(() {
          _company = s;
          _favorites = _parseFavorites(s['pos_quick_keys']);
        });
      }
    } catch (_) {}
  }

  static Set<String> _parseFavorites(String? raw) {
    try {
      return {
        for (final id in jsonDecode(raw ?? '[]') as List) id.toString()
      };
    } catch (_) {
      return {};
    }
  }

  /// Quick keys: administrators pin products with a right-click; everyone
  /// gets them first on the grid.
  Future<void> _toggleFavorite(Product p) async {
    if (!widget.user.isAdmin) return;
    final next = {..._favorites};
    if (!next.remove(p.id)) next.add(p.id);
    setState(() => _favorites = next);
    try {
      await widget.api
          .saveSettings({'pos_quick_keys': jsonEncode(next.toList())});
    } catch (_) {}
  }

  Future<void> _openCaisse() async {
    final opened = await showDialog<CaisseSession>(
      context: context,
      builder: (_) => _OpenCaisseDialog(api: widget.api),
    );
    if (opened != null) {
      setState(() => _session = opened);
      _searchFocus.requestFocus();
    }
  }

  Future<void> _showXReport() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ReportDialog(api: widget.api, closing: false),
    );
    _searchFocus.requestFocus();
  }

  Future<void> _closeCaisse() async {
    final closed = await showDialog<bool>(
      context: context,
      builder: (_) => _ReportDialog(api: widget.api, closing: true),
    );
    if (closed == true) setState(() => _session = null);
  }

  /// Sends the 80mm ticket to the configured thermal printer, if any.
  Future<void> _printTicket(DocDetail doc, {int? received, int? change}) async {
    final printer = widget.config.ticketPrinter;
    if (printer == null || printer.isEmpty) return;
    try {
      final bytes = buildTicket(
        company: _company,
        doc: doc,
        cashierName: widget.cashierName,
        received: received,
        change: change,
      );
      // Cash payment pops the drawer through the printer's RJ11 port.
      final payload =
          doc.paymentMethod == 'cash' ? [...drawerKick, ...bytes] : bytes;
      await rawPrint(printer, payload);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.warnDark,
        behavior: SnackBarBehavior.floating,
        content: Text('Impression du ticket impossible : $e',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
      ));
    }
  }

  Future<void> _refreshStock() async {
    try {
      final levels = await widget.api.stockLevels();
      final map = <String, int>{};
      for (final l in levels) {
        map[l.productId] = (map[l.productId] ?? 0) + l.qtyMilli;
      }
      if (mounted) setState(() => _stockByProduct = map);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    try {
      final items = await widget.api.products(q: q, limit: 200);
      if (mounted) setState(() => _results = items);
    } catch (_) {
      if (mounted) setState(() => _results = const []);
    }
  }

  /// Barcode scanners type the code then send Enter.
  Future<void> _onSubmitted(String q) async {
    q = q.trim();
    if (q.isEmpty) return;

    // Scale barcodes (GS1 prefixes 21/22): 2 P PPPPP VVVVV C —
    // 21 embeds the weight in grams, 22 the price in centimes.
    final scale = RegExp(r'^(2[12])(\d{5})(\d{5})\d$').firstMatch(q);
    if (scale != null && await _addScaleItem(scale)) {
      _searchCtrl.clear();
      _search('');
      _searchFocus.requestFocus();
      return;
    }

    try {
      final items = await widget.api.products(q: q, limit: 5);
      final exact = items.where((p) => p.matchesBarcode(q)).toList();
      final pick = exact.isNotEmpty
          ? exact.first
          : (items.length == 1 ? items.first : null);
      if (pick != null) {
        _addToCart(pick);
        _searchCtrl.clear();
        _search('');
      } else {
        setState(() => _results = items);
      }
    } catch (_) {}
    _searchFocus.requestFocus();
  }

  Future<bool> _addScaleItem(RegExpMatch m) async {
    final plu = m.group(2)!;
    final value = int.parse(m.group(3)!);
    Product? p;
    try {
      final trimmed = plu.replaceFirst(RegExp(r'^0+'), '');
      for (final code in {plu, if (trimmed.isNotEmpty) trimmed}) {
        final items = await widget.api.products(q: code, limit: 5);
        final hit = items.where((x) => x.matchesBarcode(code));
        if (hit.isNotEmpty) {
          p = hit.first;
          break;
        }
      }
    } catch (_) {}
    if (p == null) return false;
    final product = p;
    int qtyMilli;
    if (m.group(1) == '21') {
      qtyMilli = value; // grams == milli-kg
    } else {
      final unit = product.priceFor(_priceLevel);
      if (unit <= 0) return false;
      qtyMilli = roundDiv(value * 1000, unit);
    }
    if (qtyMilli <= 0) return false;
    setState(() {
      final existing = _cart.where((l) => l.product.id == product.id);
      if (existing.isNotEmpty) {
        existing.first.qtyMilli += qtyMilli;
      } else {
        _cart.add(CartLine(product)..qtyMilli = qtyMilli);
      }
    });
    return true;
  }

  Future<void> _addToCart(Product p) async {
    // A product sold by weight can't default to "1": ask for the weight.
    if (p.isWeighable) {
      final milli = await _askWeight(p);
      if (milli == null || milli <= 0) {
        _searchFocus.requestFocus();
        return;
      }
      setState(() {
        final existing = _cart.where((l) => l.product.id == p.id);
        if (existing.isNotEmpty) {
          existing.first.qtyMilli += milli;
        } else {
          _cart.add(CartLine(p)..qtyMilli = milli);
        }
      });
      _searchFocus.requestFocus();
      return;
    }
    setState(() {
      final existing = _cart.where((l) => l.product.id == p.id);
      if (existing.isNotEmpty) {
        existing.first.qtyMilli += 1000;
      } else {
        _cart.add(CartLine(p));
      }
    });
  }

  /// Weight entry for "produit au poids" — returns milli-kg.
  Future<int?> _askWeight(Product p) async {
    final ctrl = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(p.name, style: T.h2, textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('Poids en kg · ${fmtDA(p.effectivePriceTTC)}/kg',
                  style: T.small),
              const SizedBox(height: 12),
              Container(
                height: 54,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: T.monoBig,
                  onSubmitted: (v) => Navigator.of(context).pop(parseQty(v)),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '0,500',
                    hintStyle: T.monoBig.copyWith(color: T.ghost),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 6, children: [
                for (final (label, milli) in [
                  ('250 g', 250),
                  ('500 g', 500),
                  ('1 kg', 1000),
                  ('2 kg', 2000),
                ])
                  ActionChip(
                    label: Text(label,
                        style: T.small.copyWith(
                            fontWeight: FontWeight.w700, color: T.mintDark)),
                    backgroundColor: T.mintTint,
                    side: BorderSide.none,
                    onPressed: () => Navigator.of(context).pop(milli),
                  ),
              ]),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'Ajouter',
                onPressed: () => Navigator.of(context).pop(parseQty(ctrl.text)),
              ),
            ]),
          ),
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  void _changeQty(CartLine line, int deltaMilli) {
    setState(() {
      line.qtyMilli += deltaMilli;
      if (line.qtyMilli <= 0) _cart.remove(line);
    });
  }

  Future<void> _editQty(CartLine line) async {
    final ctrl = TextEditingController(text: fmtQty(line.qtyMilli));
    final discCtrl = TextEditingController(
        text: line.discountPct == 0 ? '' : '${line.discountPct ~/ 100}');
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) {
        (int, int)? parse() {
          final q = parseQty(ctrl.text);
          if (q == null || q <= 0) return null;
          final d = int.tryParse(discCtrl.text.trim()) ?? 0;
          return (q, (d.clamp(0, 100)) * 100);
        }

        return Dialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rCard)),
          child: SizedBox(
            width: 300,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(line.product.name,
                    style: T.h2, textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text(
                    line.product.isWeighable ? 'Quantité (kg)' : 'Quantité',
                    style: T.small),
                const SizedBox(height: 12),
                Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: T.bg,
                    borderRadius: BorderRadius.circular(T.rInner),
                    border: Border.all(color: T.border),
                  ),
                  child: TextField(
                    controller: ctrl,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: T.monoBig,
                    onSubmitted: (_) => Navigator.of(context).pop(parse()),
                    decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
                if (_canDiscount) ...[
                  const SizedBox(height: 10),
                  Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: TextField(
                      controller: discCtrl,
                      textAlign: TextAlign.center,
                      style: T.monoBody,
                      onSubmitted: (_) => Navigator.of(context).pop(parse()),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Remise % (0–100)',
                        hintStyle: T.small.copyWith(color: T.ghost),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                PrimaryButton(
                  label: 'Valider',
                  onPressed: () => Navigator.of(context).pop(parse()),
                ),
              ]),
            ),
          ),
        );
      },
    );
    ctrl.dispose();
    discCtrl.dispose();
    if (result != null) {
      setState(() {
        line.qtyMilli = result.$1;
        line.discountPct = result.$2;
      });
    }
    _searchFocus.requestFocus();
  }

  /// Whole-ticket remise: same percentage on every line.
  Future<void> _ticketDiscount() async {
    if (!_canDiscount || _cart.isEmpty) return;
    final ctrl = TextEditingController();
    final pct = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        child: SizedBox(
          width: 280,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Remise sur le ticket', style: T.h2),
              const SizedBox(height: 4),
              Text('Appliquée à toutes les lignes', style: T.small),
              const SizedBox(height: 12),
              Container(
                height: 54,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: T.monoBig,
                  onSubmitted: (v) =>
                      Navigator.of(context).pop(int.tryParse(v.trim())),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '%',
                    hintStyle: T.monoBig.copyWith(color: T.ghost),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PrimaryButton(
                label: 'Appliquer',
                onPressed: () =>
                    Navigator.of(context).pop(int.tryParse(ctrl.text.trim())),
              ),
            ]),
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (pct != null) {
      setState(() {
        for (final l in _cart) {
          l.discountPct = pct.clamp(0, 100) * 100;
        }
      });
    }
    _searchFocus.requestFocus();
  }

  Future<void> _pickClient() async {
    final p = await showPartnerPicker(context, widget.api, kind: 'customer');
    if (p != null) setState(() => _client = p);
    _searchFocus.requestFocus();
  }

  /// Return flow: pick the original sale, choose the lines, refund in cash.
  Future<void> _startReturn() async {
    final refunded = await showDialog<DocDetail>(
      context: context,
      builder: (_) => _ReturnDialog(
        api: widget.api,
        warehouseId: _warehouseId,
        caisseSessionId: _session?.id,
      ),
    );
    if (refunded != null && mounted) {
      _refreshStock();
      // Pop the drawer to give the money back.
      final printer = widget.config.ticketPrinter;
      if (printer != null && printer.isNotEmpty) {
        try {
          await rawPrint(printer, drawerKick);
        } catch (_) {}
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.ink,
        behavior: SnackBarBehavior.floating,
        content: Text(
            'Retour ${refunded.number} validé — rendre ${fmtDA(refunded.totalTTC)} au client.',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
      ));
    }
    _searchFocus.requestFocus();
  }

  int get _totalHT => _cart.fold(0, (s, l) => s + l.lineHT(_priceLevel));
  int get _totalVAT => _cart.fold(0, (s, l) => s + l.lineVAT(_priceLevel));
  int get _timbre {
    if (_paymentMethod != 'cash' || _cart.isEmpty) return 0;
    var t = roundDiv(_totalHT + _totalVAT, 100);
    if (t < 500) t = 500;
    if (t > 250000) t = 250000;
    return t;
  }

  int get _totalTTC => _totalHT + _totalVAT + _timbre;
  int get _itemCount =>
      _cart.fold(0, (s, l) => s + (l.qtyMilli / 1000).ceil());

  Future<void> _startCheckout() async {
    if (_cart.isEmpty || _warehouseId == null || _checkingOut) return;
    if (_paymentMethod == 'credit' && _client == null) {
      await _pickClient();
      if (_client == null) return;
    }
    if (!mounted) return;

    // Serialized products (IMEI): capture which physical unit goes out.
    Map<String, List<String>> serialsByProduct = {};
    final serialized =
        _cart.where((l) => l.product.trackSerials).toList();
    if (serialized.isNotEmpty) {
      final res = await showDialog<Map<String, List<String>>>(
        context: context,
        builder: (_) => _SerialDialog(lines: serialized),
      );
      if (res == null) {
        _searchFocus.requestFocus();
        return;
      }
      serialsByProduct = res;
    }
    if (!mounted) return;

    // Gift card: validate + debit BEFORE posting; refund if the post fails.
    String? giftUseId;
    if (_paymentMethod == 'gift') {
      final use = await showDialog<String>(
        context: context,
        builder: (_) => _GiftRedeemDialog(api: widget.api, total: _totalTTC),
      );
      if (use == null) {
        _searchFocus.requestFocus();
        return;
      }
      giftUseId = use;
    }
    if (!mounted) return;

    int? received;
    if (_paymentMethod == 'cash') {
      received = await showDialog<int>(
        context: context,
        builder: (context) => _CashDialog(total: _totalTTC),
      );
      if (received == null) {
        _searchFocus.requestFocus();
        return; // cancelled
      }
    }
    await _checkout(
        received: received, giftUseId: giftUseId, serials: serialsByProduct);
  }

  Future<void> _checkout(
      {int? received,
      String? giftUseId,
      Map<String, List<String>> serials = const {}}) async {
    setState(() => _checkingOut = true);
    try {
      final posted = await widget.api.checkoutTicket(
        warehouseId: _warehouseId!,
        // A gift-card sale is not cash in the drawer: no method, no timbre.
        paymentMethod: _paymentMethod == 'gift' ? null : _paymentMethod,
        partnerId: _client?.id,
        caisseSessionId: _session?.id,
        lines: [
          for (final l in _cart)
            {
              'product_id': l.product.id,
              'description': l.product.name,
              'qty_milli': l.qtyMilli,
              'unit_price': l.unitHT(_priceLevel),
              'discount_pct': l.discountPct,
              'vat_rate': l.product.vatRate,
            }
        ],
      );
      // Mark the sold serials — the sale stands even if this trails behind.
      for (final e in serials.entries) {
        for (final serial in e.value) {
          try {
            await widget.api.sellUnit(serial,
                productId: e.key,
                saleDocId: posted.id,
                partnerId: _client?.id);
          } catch (_) {}
        }
      }
      if (!mounted) return;
      final change =
          received == null ? 0 : (received - posted.totalTTC).clamp(0, 1 << 48);
      setState(() {
        _cart.clear();
        _client = null;
        _paymentMethod = 'cash';
      });
      _refreshStock();
      _printTicket(posted, received: received, change: change);
      await _showSuccess(posted, change);
    } on ApiException catch (e) {
      // The card was debited but the sale never posted — give the money back.
      if (giftUseId != null) {
        try {
          await widget.api.refundGiftCardUse(giftUseId);
        } catch (_) {}
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: T.danger,
        behavior: SnackBarBehavior.floating,
        content: Text('Échec de la vente : ${e.message}',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
      ));
    } finally {
      if (mounted) setState(() => _checkingOut = false);
      _searchFocus.requestFocus();
    }
  }

  Future<void> _showSuccess(DocDetail doc, int change) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        Timer(const Duration(milliseconds: 1800), () {
          if (context.mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        });
        return Dialog(
          backgroundColor: T.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: SizedBox(
            width: 320,
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                      color: T.mintTint2, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded,
                      size: 32, color: T.mintDark),
                ),
                const SizedBox(height: 14),
                Text(doc.number ?? '', style: T.monoSmall),
                const SizedBox(height: 6),
                Text(fmtDA(doc.totalTTC),
                    style: const TextStyle(
                        fontFamily: T.sans,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: T.ink)),
                if (change > 0) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('À rendre  ', style: T.small),
                      Text(fmtDA(change),
                          style: T.monoBody.copyWith(
                              fontWeight: FontWeight.w600,
                              color: T.warnDark)),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionLoading) {
      return const Center(child: CircularProgressIndicator(color: T.mint));
    }
    if (_session == null) {
      // Caisse fermée — gate before selling.
      return Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: T.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                    color: T.mintTint, shape: BoxShape.circle),
                child: const Icon(Icons.point_of_sale_rounded,
                    size: 26, color: T.mintDark),
              ),
              const SizedBox(height: 14),
              const Text('Caisse fermée', style: T.h1),
              const SizedBox(height: 6),
              Text(
                  'Ouvrez une session avec le fond de caisse\npour commencer à encaisser.',
                  textAlign: TextAlign.center,
                  style: T.bodyMuted),
              const SizedBox(height: 18),
              SizedBox(
                width: 220,
                child: PrimaryButton(
                    label: 'Ouvrir la caisse', big: true, onPressed: _openCaisse),
              ),
            ],
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ================= Left: search + product grid =================
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('Caisse', style: T.h1),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: MicroLabel('${_results.length} produits'),
                  ),
                  const Spacer(),
                  // Session strip
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: T.mintTint,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(children: [
                      Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                              color: T.mint, shape: BoxShape.circle)),
                      const SizedBox(width: 7),
                      Text(
                          'Ouverte ${_session!.openedAt.length >= 16 ? _session!.openedAt.substring(11, 16) : ''} · ${_session!.userName}',
                          style: T.monoSmall
                              .copyWith(color: T.mintDark, fontSize: 10.5)),
                    ]),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: 'Retour / remboursement client',
                    child: IconButton(
                      onPressed: _startReturn,
                      icon: const Icon(Icons.assignment_return_outlined,
                          size: 17, color: T.muted),
                    ),
                  ),
                  Tooltip(
                    message: 'Vendre une carte cadeau',
                    child: IconButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _GiftSellDialog(api: widget.api),
                      ).then((_) => _searchFocus.requestFocus()),
                      icon: const Icon(Icons.card_giftcard,
                          size: 17, color: T.muted),
                    ),
                  ),
                  Tooltip(
                    message: 'Rapport X (état de caisse)',
                    child: IconButton(
                      onPressed: _showXReport,
                      icon: const Icon(Icons.receipt_long_outlined,
                          size: 17, color: T.muted),
                    ),
                  ),
                  Tooltip(
                    message: 'Clôturer la caisse (Z)',
                    child: IconButton(
                      onPressed: _closeCaisse,
                      icon: const Icon(Icons.lock_outline,
                          size: 17, color: T.muted),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: T.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: T.border),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x0A141414),
                          blurRadius: 8,
                          offset: Offset(0, 2)),
                    ],
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    autofocus: true,
                    onChanged: _onQueryChanged,
                    onSubmitted: _onSubmitted,
                    style: T.body.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText:
                          'Scanner un code-barres ou rechercher un produit…',
                      hintStyle:
                          T.bodyMuted.copyWith(color: T.ghost, fontSize: 14),
                      prefixIcon: const Icon(Icons.qr_code_scanner,
                          size: 19, color: T.mintDeep),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_cats.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 32,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _CatChip(
                          label: 'Tous',
                          selected: _catFilter == null,
                          onTap: () => setState(() => _catFilter = null),
                        ),
                        for (final c in _cats)
                          _CatChip(
                            label: c.name,
                            selected: _catFilter == c.id,
                            onTap: () => setState(() =>
                                _catFilter = _catFilter == c.id ? null : c.id),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: Builder(builder: (context) {
                    final shown = [
                      for (final p in _results)
                        if (_catFilter == null || p.categoryId == _catFilter) p
                    ];
                    // Pinned quick keys come first while browsing.
                    if (_searchCtrl.text.trim().isEmpty &&
                        _favorites.isNotEmpty) {
                      shown.sort((a, b) {
                        final fa = _favorites.contains(a.id) ? 0 : 1;
                        final fb = _favorites.contains(b.id) ? 0 : 1;
                        return fa != fb
                            ? fa - fb
                            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
                      });
                    }
                    if (shown.isEmpty) {
                      return const EmptyState(
                          icon: Icons.qr_code_scanner,
                          text:
                              'Aucun produit.\nScannez un code-barres ou tapez un nom.');
                    }
                    return GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        mainAxisExtent: 120,
                      ),
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _ProductTile(
                        product: shown[i],
                        stockMilli: _stockByProduct[shown[i].id] ?? 0,
                        favorite: _favorites.contains(shown[i].id),
                        onTap: () {
                          _addToCart(shown[i]);
                          _searchFocus.requestFocus();
                        },
                        onSecondaryTap: () => _toggleFavorite(shown[i]),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
        // ================= Right: ticket =================
        Container(
          width: 400,
          decoration: const BoxDecoration(
            color: T.surface,
            border: BorderDirectional(start: BorderSide(color: T.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
                child: Row(children: [
                  const Icon(Icons.receipt_outlined,
                      size: 16, color: T.mintDeep),
                  const SizedBox(width: 8),
                  const MicroLabel('Ticket en cours'),
                  const SizedBox(width: 8),
                  if (_cart.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: T.mintTint,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('$_itemCount',
                          style: T.monoSmall.copyWith(
                              color: T.mintDark,
                              fontWeight: FontWeight.w600)),
                    ),
                  const Spacer(),
                  if (_cart.isNotEmpty)
                    IconButton(
                      onPressed: () => setState(() {
                        _cart.clear();
                        _client = null;
                      }),
                      tooltip: 'Vider le ticket',
                      icon: const Icon(Icons.delete_outline,
                          size: 17, color: T.faint),
                    ),
                ]),
              ),
              // Client selector
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: InkWell(
                  onTap: _pickClient,
                  borderRadius: BorderRadius.circular(T.rInner),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _client == null ? T.bg : T.mintTint,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(
                          color: _client == null ? T.border : T.mintDeep),
                    ),
                    child: Row(children: [
                      Icon(Icons.person_outline,
                          size: 16,
                          color: _client == null ? T.faint : T.mintDark),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _client?.name ?? 'Client de passage',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: T.sans,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: _client == null ? T.faint : T.mintDark,
                          ),
                        ),
                      ),
                      if (_client?.priceLevel == 'wholesale') ...[
                        const MintChip('demi-gros',
                            color: T.warnTint, fg: T.warnDark),
                        const SizedBox(width: 6),
                      ],
                      if (_client != null)
                        InkWell(
                          onTap: () => setState(() {
                            _client = null;
                            if (_paymentMethod == 'credit') {
                              _paymentMethod = 'cash';
                            }
                          }),
                          child: const Icon(Icons.close,
                              size: 14, color: T.mintDark),
                        )
                      else
                        Text('Choisir',
                            style: T.small
                                .copyWith(fontSize: 11, color: T.mintDark)),
                    ]),
                  ),
                ),
              ),
              const Divider(),
              // Lines
              Expanded(
                child: _cart.isEmpty
                    ? const EmptyState(
                        icon: Icons.shopping_basket_outlined,
                        text:
                            'Ticket vide.\nScannez un produit pour commencer.')
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _cart.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) => _CartRow(
                          line: _cart[i],
                          priceLevel: _priceLevel,
                          onDelta: _changeQty,
                          onEditQty: () => _editQty(_cart[i]),
                          onRemove: () =>
                              setState(() => _cart.removeAt(i)),
                        ),
                      ),
              ),
              // Totals + payment
              Container(
                decoration: const BoxDecoration(
                  color: T.bg,
                  border:
                      BorderDirectional(top: BorderSide(color: T.border)),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TotalRow('Sous-total HT', _totalHT),
                    _TotalRow('TVA', _totalVAT),
                    if (_timbre > 0) _TotalRow('Timbre fiscal', _timbre),
                    const SizedBox(height: 6),
                    const Divider(),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const MicroLabel('Total à payer'),
                        if (_canDiscount && _cart.isNotEmpty)
                          Padding(
                            padding:
                                const EdgeInsetsDirectional.only(start: 6),
                            child: Tooltip(
                              message: 'Remise sur tout le ticket',
                              child: InkWell(
                                onTap: _ticketDiscount,
                                borderRadius: BorderRadius.circular(6),
                                child: const Padding(
                                  padding: EdgeInsets.all(3),
                                  child: Icon(Icons.percent_rounded,
                                      size: 14, color: T.mintDark),
                                ),
                              ),
                            ),
                          ),
                        const Spacer(),
                        Text(fmtDA(_totalTTC),
                            style: const TextStyle(
                                fontFamily: T.sans,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: T.ink)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(children: [
                      _PayChoice(
                          label: 'Espèces',
                          icon: Icons.payments_outlined,
                          selected: _paymentMethod == 'cash',
                          onTap: () =>
                              setState(() => _paymentMethod = 'cash')),
                      const SizedBox(width: 6),
                      _PayChoice(
                          label: 'CIB',
                          icon: Icons.credit_card,
                          selected: _paymentMethod == 'cib',
                          onTap: () =>
                              setState(() => _paymentMethod = 'cib')),
                      const SizedBox(width: 6),
                      _PayChoice(
                          label: 'Crédit',
                          icon: Icons.menu_book_outlined,
                          selected: _paymentMethod == 'credit',
                          onTap: () {
                            setState(() => _paymentMethod = 'credit');
                            if (_client == null) _pickClient();
                          }),
                      const SizedBox(width: 6),
                      _PayChoice(
                          label: 'Cadeau',
                          icon: Icons.card_giftcard,
                          selected: _paymentMethod == 'gift',
                          onTap: () =>
                              setState(() => _paymentMethod = 'gift')),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: T.mint,
                          disabledBackgroundColor: T.border2,
                          foregroundColor: T.ink,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _cart.isEmpty || _checkingOut
                            ? null
                            : _startCheckout,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_checkingOut ? 'Encaissement…' : 'Encaisser',
                                style: const TextStyle(
                                    fontFamily: T.sans,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800)),
                            if (!_checkingOut && _cart.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Container(
                                width: 4,
                                height: 4,
                                decoration: const BoxDecoration(
                                    color: T.ink, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 10),
                              Text(fmtDA(_totalTTC),
                                  style: const TextStyle(
                                      fontFamily: T.mono,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ],
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
    );
  }
}

// ================= Widgets =================

class _ProductTile extends StatefulWidget {
  const _ProductTile(
      {required this.product,
      required this.stockMilli,
      required this.onTap,
      this.favorite = false,
      this.onSecondaryTap});
  final Product product;
  final int stockMilli;
  final VoidCallback onTap;
  final bool favorite;
  final VoidCallback? onSecondaryTap;

  @override
  State<_ProductTile> createState() => _ProductTileState();
}

class _ProductTileState extends State<_ProductTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final (bg, fg) = pastelFor(p.name);
    final out = widget.stockMilli <= 0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTap: widget.onSecondaryTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _hover ? T.mintDeep : T.border,
                width: _hover ? 1.4 : 1),
            boxShadow: _hover
                ? const [
                    BoxShadow(
                        color: Color(0x1400CC99),
                        blurRadius: 10,
                        offset: Offset(0, 3)),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration:
                      BoxDecoration(color: bg, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text(
                    p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                    style: TextStyle(
                        fontFamily: T.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: fg),
                  ),
                ),
                if (widget.favorite) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.push_pin_rounded, size: 11, color: T.warn),
                ],
                const Spacer(),
                if (p.promoActive) ...[
                  const MintChip('promo', color: T.warnTint, fg: T.warnDark),
                  const SizedBox(width: 4),
                ],
                if (out)
                  const MintChip('rupture',
                      color: T.dangerTint, fg: T.dangerDark)
                else
                  Text(fmtQty(widget.stockMilli),
                      style: T.monoSmall.copyWith(fontSize: 10)),
              ]),
              const Spacer(),
              Text(p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: T.sans,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: T.ink)),
              const SizedBox(height: 4),
              Row(children: [
                Text(fmtDA(p.effectivePriceTTC),
                    style: T.monoBody.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: p.promoActive ? T.warnDark : T.mintDark)),
                if (p.promoActive) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(fmtDA(p.priceRetail),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.monoSmall.copyWith(
                            fontSize: 10,
                            decoration: TextDecoration.lineThrough)),
                  ),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartRow extends StatefulWidget {
  const _CartRow({
    required this.line,
    required this.priceLevel,
    required this.onDelta,
    required this.onEditQty,
    required this.onRemove,
  });
  final CartLine line;
  final String priceLevel;
  final void Function(CartLine, int) onDelta;
  final VoidCallback onEditQty;
  final VoidCallback onRemove;

  @override
  State<_CartRow> createState() => _CartRowState();
}

class _CartRowState extends State<_CartRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final (bg, fg) = pastelFor(line.product.name);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? T.bg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              line.product.name.isEmpty
                  ? '?'
                  : line.product.name[0].toUpperCase(),
              style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: fg),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: T.sans,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: T.ink)),
                const SizedBox(height: 2),
                Text(
                    '${fmtDA(line.unitTTC(widget.priceLevel))}'
                    '${line.product.isWeighable ? '/kg' : ''}'
                    ' × ${fmtQty(line.qtyMilli)}'
                    '${line.product.isWeighable ? ' kg' : ''}'
                    '${line.discountPct > 0 ? '  · -${line.discountPct ~/ 100}%' : ''}'
                    '${line.product.promoActive ? '  · promo' : ''}',
                    style: T.monoSmall.copyWith(fontSize: 10.5)),
              ],
            ),
          ),
          // Stepper pill
          Container(
            height: 28,
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: T.border2),
            ),
            child: Row(children: [
              _StepBtn(
                  icon: Icons.remove,
                  onTap: () => widget.onDelta(
                      line, line.product.isWeighable ? -100 : -1000)),
              InkWell(
                onTap: widget.onEditQty,
                child: SizedBox(
                  width: 40,
                  child: Text(fmtQty(line.qtyMilli),
                      textAlign: TextAlign.center,
                      style: T.monoBody.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
              _StepBtn(
                  icon: Icons.add,
                  onTap: () => widget.onDelta(
                      line, line.product.isWeighable ? 100 : 1000)),
            ]),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: Text(fmtDA(line.lineTTC(widget.priceLevel)),
                textAlign: TextAlign.end,
                style: T.monoBody
                    .copyWith(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          SizedBox(
            width: 24,
            child: _hover
                ? InkWell(
                    onTap: widget.onRemove,
                    child:
                        const Icon(Icons.close, size: 14, color: T.faint),
                  )
                : null,
          ),
        ]),
      ),
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: T.sans,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : T.muted,
              )),
        ),
      ),
    );
  }
}

/// Captures the serial/IMEI of each serialized unit in the cart.
class _SerialDialog extends StatefulWidget {
  const _SerialDialog({required this.lines});
  final List<CartLine> lines;

  @override
  State<_SerialDialog> createState() => _SerialDialogState();
}

class _SerialDialogState extends State<_SerialDialog> {
  late final Map<String, List<TextEditingController>> _ctrls = {
    for (final l in widget.lines)
      l.product.id: [
        for (var i = 0; i < (l.qtyMilli / 1000).ceil(); i++)
          TextEditingController()
      ]
  };

  @override
  void dispose() {
    for (final list in _ctrls.values) {
      for (final c in list) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _submit() {
    final out = <String, List<String>>{};
    for (final e in _ctrls.entries) {
      final serials = [
        for (final c in e.value)
          if (c.text.trim().isNotEmpty) c.text.trim()
      ];
      if (serials.isNotEmpty) out[e.key] = serials;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('N° de série / IMEI', style: T.h2),
              const SizedBox(height: 4),
              Text('Scannez ou saisissez le numéro de chaque appareil vendu.',
                  style: T.small),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final l in widget.lines) ...[
                        MicroLabel(l.product.name),
                        const SizedBox(height: 4),
                        for (final c in _ctrls[l.product.id]!)
                          Container(
                            height: 38,
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: T.bg,
                              borderRadius: BorderRadius.circular(T.rInner),
                              border: Border.all(color: T.border),
                            ),
                            child: TextField(
                              controller: c,
                              style: T.monoBody,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: 'IMEI / N° de série',
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Annuler', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: PrimaryButton(label: 'Continuer', onPressed: _submit),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cash-refund return: pick the sale, tick the lines, post the avoir.
class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog(
      {required this.api, required this.warehouseId, this.caisseSessionId});
  final ApiClient api;
  final String? warehouseId;
  final String? caisseSessionId;

  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  final _search = TextEditingController();
  List<DocSummary> _docs = const [];
  DocDetail? _doc;
  final Map<String, int> _selectedQty = {}; // line id -> qty milli
  bool _busy = false;
  String? _error;

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
    try {
      final tickets = await widget.api
          .documents(type: 'SALE_TICKET', status: 'posted', limit: 30);
      final invoices = await widget.api
          .documents(type: 'SALE_INVOICE', status: 'posted', limit: 10);
      final all = [...tickets, ...invoices]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _docs = all);
    } catch (_) {}
  }

  Future<void> _open(DocSummary d) async {
    try {
      final detail = await widget.api.getDocument(d.id);
      if (mounted) {
        setState(() {
          _doc = detail;
          _selectedQty.clear();
        });
      }
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  int get _refundEstimate {
    final d = _doc;
    if (d == null) return 0;
    var total = 0;
    for (final l in d.lines) {
      final sel = _selectedQty[l.id ?? ''] ?? 0;
      if (sel > 0 && l.qtyMilli > 0) {
        total += roundDiv(l.lineTTC * sel, l.qtyMilli);
      }
    }
    return total;
  }

  Future<void> _refund() async {
    final d = _doc;
    if (d == null || _busy) return;
    final lines = [
      for (final l in d.lines)
        if ((_selectedQty[l.id ?? ''] ?? 0) > 0)
          {
            'product_id': l.productId,
            'description': l.description,
            'qty_milli': _selectedQty[l.id ?? '']!,
            'unit_price': l.unitPrice,
            'discount_pct': l.discountPct,
            'vat_rate': l.vatRate,
            'position': 0,
          }
    ];
    if (lines.isEmpty) {
      setState(() => _error = 'Sélectionnez au moins un article.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await widget.api.createDraft({
        'doc_type': 'SALE_CREDIT_NOTE',
        'doc_date': todayISO(),
        'warehouse_id': d.warehouseId ?? widget.warehouseId,
        'partner_id': d.partnerId,
        'payment_method': 'cash',
        'caisse_session_id': widget.caisseSessionId,
        'ref_document_id': d.id,
        'notes': 'Retour sur ${d.number ?? d.id.substring(0, 8)}',
        'lines': lines,
      });
      final posted = await widget.api.postDocument(draft.id);
      if (mounted) Navigator.of(context).pop(posted);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 560,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(
                    child: Text('Retour client', style: T.h2)),
                if (d != null)
                  TextButton(
                    onPressed: () => setState(() => _doc = null),
                    child: Text('← Autre ticket',
                        style: T.small.copyWith(color: T.mintDark)),
                  ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
              ]),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_error!,
                      style: T.small.copyWith(color: T.dangerDark)),
                ),
              if (d == null) ...[
                SearchField(
                  controller: _search,
                  hint: 'N° du ticket (ex. TK-2026-000012)…',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(
                    children: [
                      for (final doc in _docs)
                        if (_search.text.trim().isEmpty ||
                            (doc.number ?? '')
                                .toLowerCase()
                                .contains(_search.text.trim().toLowerCase()))
                          InkWell(
                            onTap: () => _open(doc),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 9),
                              child: Row(children: [
                                Text(doc.number ?? '',
                                    style: T.monoBody.copyWith(fontSize: 12)),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Text(doc.docDate, style: T.small)),
                                Text(fmtDA(doc.totalTTC), style: T.monoBody),
                              ]),
                            ),
                          ),
                    ],
                  ),
                ),
              ] else ...[
                Text('${d.number} · ${d.docDate}', style: T.monoSmall),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      for (final l in d.lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(children: [
                            InkWell(
                              onTap: () => setState(() {
                                final k = l.id ?? '';
                                if ((_selectedQty[k] ?? 0) > 0) {
                                  _selectedQty.remove(k);
                                } else {
                                  _selectedQty[k] = l.qtyMilli;
                                }
                              }),
                              child: Icon(
                                  (_selectedQty[l.id ?? ''] ?? 0) > 0
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  size: 18,
                                  color: (_selectedQty[l.id ?? ''] ?? 0) > 0
                                      ? T.mintDeep
                                      : T.faint),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(l.description,
                                    style: T.body,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis)),
                            if ((_selectedQty[l.id ?? ''] ?? 0) > 0 &&
                                l.qtyMilli > 1000) ...[
                              _StepBtn(
                                  icon: Icons.remove,
                                  onTap: () => setState(() {
                                        final k = l.id ?? '';
                                        final v = (_selectedQty[k] ?? 0) - 1000;
                                        if (v > 0) _selectedQty[k] = v;
                                      })),
                              Text(
                                  fmtQty(_selectedQty[l.id ?? ''] ?? 0),
                                  style: T.monoBody.copyWith(fontSize: 12)),
                              _StepBtn(
                                  icon: Icons.add,
                                  onTap: () => setState(() {
                                        final k = l.id ?? '';
                                        final v = (_selectedQty[k] ?? 0) + 1000;
                                        if (v <= l.qtyMilli) {
                                          _selectedQty[k] = v;
                                        }
                                      })),
                            ] else
                              Text('×${fmtQty(l.qtyMilli)}',
                                  style: T.monoSmall),
                            const SizedBox(width: 12),
                            SizedBox(
                                width: 90,
                                child: Text(fmtDA(l.lineTTC),
                                    textAlign: TextAlign.end,
                                    style: T.monoBody.copyWith(fontSize: 12))),
                          ]),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text('À rembourser (espèces)',
                        style: T.bodyMuted),
                  ),
                  Text(fmtDA(_refundEstimate),
                      style: T.monoBig.copyWith(fontSize: 20)),
                ]),
                const SizedBox(height: 10),
                PrimaryButton(
                  label: _busy ? '…' : 'Valider le retour',
                  big: true,
                  onPressed:
                      _busy || _selectedQty.isEmpty ? null : _refund,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: 28,
        child: Icon(icon, size: 13, color: T.muted),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount);
  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Expanded(
            child: Text(label, style: T.bodyMuted.copyWith(fontSize: 12))),
        Text(fmtDA(amount),
            style: T.monoBody.copyWith(fontSize: 12, color: T.muted)),
      ]),
    );
  }
}

class _PayChoice extends StatelessWidget {
  const _PayChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.rInner),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 52,
          decoration: BoxDecoration(
            color: selected ? T.mintTint : T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(
                color: selected ? T.mintDeep : T.border,
                width: selected ? 1.4 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: selected ? T.mintDark : T.faint),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: selected ? T.mintDark : T.muted,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= Caisse session dialogs =================

class _OpenCaisseDialog extends StatefulWidget {
  const _OpenCaisseDialog({required this.api});
  final ApiClient api;

  @override
  State<_OpenCaisseDialog> createState() => _OpenCaisseDialogState();
}

class _OpenCaisseDialogState extends State<_OpenCaisseDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final cents = parseDA(_ctrl.text) ?? 0;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.api.caisseOpen(cents);
      if (mounted) Navigator.of(context).pop(session);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MicroLabel('Ouverture de caisse'),
              const SizedBox(height: 14),
              const MicroLabel('Fond de caisse (DA)'),
              const SizedBox(height: 6),
              Container(
                height: 56,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: T.monoBig.copyWith(fontSize: 22),
                  onSubmitted: (_) => _open(),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '0,00',
                    hintStyle:
                        T.monoBig.copyWith(fontSize: 22, color: T.ghost),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Annuler',
                        style: T.small.copyWith(color: T.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: PrimaryButton(
                    label: _busy ? '…' : 'Ouvrir la caisse',
                    big: true,
                    onPressed: _busy ? null : _open,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// X report (closing=false) or Z closure flow (closing=true).
class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.api, required this.closing});
  final ApiClient api;
  final bool closing;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  CaisseReport? _report;
  CaisseSession? _session;
  String? _error;
  final _counted = TextEditingController();
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (session, report) = await widget.api.caisseReport();
      if (mounted) {
        setState(() {
          _session = session;
          _report = report;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  int get _ecart {
    final counted = parseDA(_counted.text);
    if (counted == null || _report == null) return 0;
    return counted - _report!.expectedCash;
  }

  Future<void> _close() async {
    final counted = parseDA(_counted.text);
    if (counted == null) return;
    setState(() => _busy = true);
    try {
      final (session, report) = await widget.api.caisseClose(
          counted, _notes.text.trim().isEmpty ? null : _notes.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop(true);
      // Z summary
      showDialog<void>(
        context: context,
        builder: (_) => _ZSummaryDialog(session: session, report: report),
      );
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Widget _row(String label, int amount, {Color? color, bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
              child: Text(label, style: T.bodyMuted.copyWith(fontSize: 12.5))),
          Text(fmtDA(amount),
              style: T.monoBody.copyWith(
                  color: color ?? T.ink,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 400,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: r == null
              ? SizedBox(
                  height: 140,
                  child: Center(
                    child: _error != null
                        ? Text(_error!, style: T.bodyMuted)
                        : const CircularProgressIndicator(color: T.mint),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                          child: MicroLabel(widget.closing
                              ? 'Clôture de caisse (Z)'
                              : 'État de caisse (X)')),
                      if (_session != null)
                        Text(
                            'depuis ${_session!.openedAt.length >= 16 ? _session!.openedAt.substring(11, 16) : ''}',
                            style: T.monoSmall),
                    ]),
                    const SizedBox(height: 14),
                    _row('Fond de caisse', r.openingCash),
                    _row('Ventes espèces', r.cashSales),
                    if (r.cardSales > 0) _row('Ventes carte', r.cardSales),
                    if (r.creditSales > 0)
                      _row('Ventes à crédit', r.creditSales, color: T.warnDark),
                    if (r.cashIn > 0) _row('Encaissements espèces', r.cashIn),
                    if (r.cashOut > 0)
                      _row('Règlements espèces', -r.cashOut, color: T.dangerDark),
                    if (r.cashRefunds > 0)
                      _row('Retours remboursés', -r.cashRefunds,
                          color: T.dangerDark),
                    const Divider(height: 16),
                    _row('Espèces attendues en caisse', r.expectedCash,
                        bold: true),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Expanded(
                            child: MicroLabel(
                                '${r.ticketCount} tickets · ${fmtDA(r.totalSales)}')),
                      ]),
                    ),
                    if (widget.closing) ...[
                      const SizedBox(height: 14),
                      const MicroLabel('Espèces comptées (DA)'),
                      const SizedBox(height: 6),
                      Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: T.bg,
                          borderRadius: BorderRadius.circular(T.rInner),
                          border: Border.all(color: T.border),
                        ),
                        child: TextField(
                          controller: _counted,
                          autofocus: true,
                          textAlign: TextAlign.center,
                          style: T.monoBig.copyWith(fontSize: 20),
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: '0,00',
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      if (parseDA(_counted.text) != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: _ecart == 0
                                ? T.mintTint
                                : _ecart > 0
                                    ? T.warnTint
                                    : T.dangerTint,
                            borderRadius: BorderRadius.circular(T.rInner),
                          ),
                          child: Row(children: [
                            Expanded(
                                child: Text(
                                    _ecart == 0
                                        ? 'Caisse juste ✓'
                                        : _ecart > 0
                                            ? 'Excédent'
                                            : 'Manquant',
                                    style: T.bodyMuted
                                        .copyWith(fontSize: 12.5))),
                            Text(fmtDA(_ecart),
                                style: T.monoBody.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: _ecart == 0
                                        ? T.mintDark
                                        : _ecart > 0
                                            ? T.warnDark
                                            : T.dangerDark)),
                          ]),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: T.bg,
                          borderRadius: BorderRadius.circular(T.rInner),
                          border: Border.all(color: T.border),
                        ),
                        child: TextField(
                          controller: _notes,
                          style: T.body,
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Remarques (facultatif)…',
                            hintStyle: T.bodyMuted.copyWith(color: T.ghost),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: T.small.copyWith(color: T.dangerDark)),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Fermer',
                              style: T.small.copyWith(color: T.muted)),
                        ),
                      ),
                      if (widget.closing) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: PrimaryButton(
                            label: _busy ? '…' : 'Clôturer la caisse',
                            big: true,
                            color: T.ink,
                            fg: Colors.white,
                            onPressed:
                                _busy || parseDA(_counted.text) == null
                                    ? null
                                    : _close,
                          ),
                        ),
                      ],
                    ]),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ZSummaryDialog extends StatelessWidget {
  const _ZSummaryDialog({required this.session, required this.report});
  final CaisseSession session;
  final CaisseReport report;

  @override
  Widget build(BuildContext context) {
    final ecart = (session.countedCash ?? 0) - (session.expectedCash ?? 0);
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: const BoxDecoration(
                    color: T.mintTint2, shape: BoxShape.circle),
                child:
                    const Icon(Icons.lock_rounded, size: 26, color: T.mintDark),
              ),
              const SizedBox(height: 12),
              const Text('Caisse clôturée', style: T.h2),
              const SizedBox(height: 4),
              Text('${report.ticketCount} tickets · ${fmtDA(report.totalSales)}',
                  style: T.bodyMuted),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                ),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: Text('Attendu', style: T.small)),
                    Text(fmtDA(session.expectedCash ?? 0),
                        style: T.monoBody),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(child: Text('Compté', style: T.small)),
                    Text(fmtDA(session.countedCash ?? 0),
                        style: T.monoBody),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(child: Text('Écart', style: T.small)),
                    Text(fmtDA(ecart),
                        style: T.monoBody.copyWith(
                            fontWeight: FontWeight.w700,
                            color: ecart == 0
                                ? T.mintDark
                                : ecart > 0
                                    ? T.warnDark
                                    : T.dangerDark)),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'OK',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= Gift card dialogs =================

/// Sell a card: pick the amount, the server mints the code, the cashier
/// collects the money and hands the code to the customer.
class _GiftSellDialog extends StatefulWidget {
  const _GiftSellDialog({required this.api});
  final ApiClient api;

  @override
  State<_GiftSellDialog> createState() => _GiftSellDialogState();
}

class _GiftSellDialogState extends State<_GiftSellDialog> {
  final _amount = TextEditingController();
  GiftCard? _created;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _sell() async {
    final cents = parseDA(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final card = await widget.api.createGiftCard(cents);
      if (mounted) setState(() => _created = card);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _created;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: card != null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: const BoxDecoration(
                        color: T.mintTint2, shape: BoxShape.circle),
                    child: const Icon(Icons.card_giftcard,
                        size: 26, color: T.mintDark),
                  ),
                  const SizedBox(height: 12),
                  Text(fmtDA(card.initialAmount),
                      style: const TextStyle(
                          fontFamily: T.sans,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: T.ink)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border),
                    ),
                    child: Text(card.code,
                        style: const TextStyle(
                            fontFamily: T.mono,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                            color: T.ink)),
                  ),
                  const SizedBox(height: 10),
                  Text(
                      'Encaissez ${fmtDA(card.initialAmount)} et remettez ce '
                      'code au client. Notez-le : il ne sera plus affiché.',
                      textAlign: TextAlign.center,
                      style: T.small),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 140,
                    child: PrimaryButton(
                        label: 'Terminer',
                        onPressed: () => Navigator.of(context).pop()),
                  ),
                ])
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const MicroLabel('Vendre une carte cadeau'),
                    const SizedBox(height: 14),
                    const MicroLabel('Montant (DA)'),
                    const SizedBox(height: 6),
                    Container(
                      height: 54,
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: TextField(
                        controller: _amount,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        style: T.monoBig.copyWith(fontSize: 22),
                        onSubmitted: (_) => _sell(),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: '0,00',
                          hintStyle: T.monoBig
                              .copyWith(fontSize: 22, color: T.ghost),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: T.small.copyWith(color: T.dangerDark)),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Annuler',
                              style: T.small.copyWith(color: T.muted)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: PrimaryButton(
                          label: _busy ? '…' : 'Créer la carte',
                          big: true,
                          onPressed: _busy ? null : _sell,
                        ),
                      ),
                    ]),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Redeem at checkout: enter the code, see the balance, debit the total.
/// Pops with the use id on success (so a failed post can be refunded).
class _GiftRedeemDialog extends StatefulWidget {
  const _GiftRedeemDialog({required this.api, required this.total});
  final ApiClient api;
  final int total;

  @override
  State<_GiftRedeemDialog> createState() => _GiftRedeemDialogState();
}

class _GiftRedeemDialogState extends State<_GiftRedeemDialog> {
  final _code = TextEditingController();
  GiftCard? _card;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_code.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final card = await widget.api.giftCard(_code.text.trim());
      if (!mounted) return;
      setState(() => _card = card);
      if (!card.usable) {
        _error = 'Carte ${card.status == 'depleted' ? 'épuisée' : card.status}.';
      } else if (card.balance < widget.total) {
        _error =
            'Solde insuffisant : ${fmtDA(card.balance)} pour un ticket de ${fmtDA(widget.total)}.';
      }
      setState(() {});
    } on ApiException catch (e) {
      setState(() {
        _card = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _redeem() async {
    final card = _card;
    if (card == null || !card.usable || card.balance < widget.total) return;
    setState(() => _busy = true);
    try {
      final (useId, _) =
          await widget.api.redeemGiftCard(card.code, widget.total);
      if (mounted) Navigator.of(context).pop(useId);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    final ok = card != null && card.usable && card.balance >= widget.total;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.card_giftcard, size: 18, color: T.mintDeep),
                const SizedBox(width: 8),
                const Expanded(child: MicroLabel('Payer par carte cadeau')),
                Text(fmtDA(widget.total),
                    style: T.monoBody.copyWith(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 14),
              const MicroLabel('Code de la carte'),
              const SizedBox(height: 6),
              Container(
                height: 50,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: _code,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  style: T.monoBody.copyWith(fontSize: 16, letterSpacing: 2),
                  onSubmitted: (_) => _check(),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'XXXX-XXXX-XXXX',
                    hintStyle: T.monoSmall.copyWith(color: T.ghost),
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
              if (card != null && ok) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: T.mintTint,
                    borderRadius: BorderRadius.circular(T.rInner),
                  ),
                  child: Row(children: [
                    Expanded(
                        child: Text('Solde disponible',
                            style: T.bodyMuted.copyWith(fontSize: 12.5))),
                    Text(fmtDA(card.balance),
                        style: T.monoBody.copyWith(
                            color: T.mintDark, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Annuler',
                        style: T.small.copyWith(color: T.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: PrimaryButton(
                    label: _busy
                        ? '…'
                        : ok
                            ? 'Débiter ${fmtDA(widget.total)}'
                            : 'Vérifier la carte',
                    big: true,
                    onPressed: _busy ? null : (ok ? _redeem : _check),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= Cash dialog =================

class _CashDialog extends StatefulWidget {
  const _CashDialog({required this.total});
  final int total;

  @override
  State<_CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends State<_CashDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int? get _received => parseDA(_ctrl.text);
  int get _change =>
      _received == null ? 0 : (_received! - widget.total).clamp(0, 1 << 48);
  bool get _enough => _received != null && _received! >= widget.total;

  /// Round amounts a customer is likely to hand over.
  List<int> get _suggestions {
    final t = widget.total;
    final s = <int>{t};
    for (final step in [50000, 100000, 200000]) {
      final rounded = ((t + step - 1) ~/ step) * step;
      if (rounded > t) s.add(rounded);
    }
    return s.take(4).toList();
  }

  void _confirm() {
    if (_enough) Navigator.of(context).pop(_received);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.payments_outlined,
                    size: 18, color: T.mintDeep),
                const SizedBox(width: 8),
                const Expanded(child: MicroLabel('Paiement en espèces')),
                Text(fmtDA(widget.total),
                    style:
                        T.monoBody.copyWith(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 16),
              const MicroLabel('Montant reçu'),
              const SizedBox(height: 6),
              Container(
                height: 58,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(
                      color: _enough ? T.mintDeep : T.border,
                      width: _enough ? 1.4 : 1),
                ),
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: T.monoBig.copyWith(fontSize: 24),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _confirm(),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: editDA(widget.total),
                    hintStyle:
                        T.monoBig.copyWith(fontSize: 24, color: T.ghost),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final s in _suggestions)
                  InkWell(
                    onTap: () {
                      _ctrl.text = editDA(s);
                      setState(() {});
                    },
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: T.border),
                      ),
                      child: Text(fmtDA(s),
                          style: T.monoSmall
                              .copyWith(color: T.ink, fontSize: 11)),
                    ),
                  ),
              ]),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: _change > 0 ? T.mintTint : T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                ),
                child: Row(children: [
                  Expanded(
                      child: Text('À rendre',
                          style: T.bodyMuted.copyWith(fontSize: 12.5))),
                  Text(fmtDA(_change),
                      style: TextStyle(
                          fontFamily: T.mono,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: _change > 0 ? T.mintDark : T.faint)),
                ]),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Annuler',
                        style: T.small.copyWith(color: T.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: PrimaryButton(
                    label: 'Encaisser',
                    big: true,
                    onPressed: _enough ? _confirm : null,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
