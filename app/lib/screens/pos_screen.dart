import 'dart:async';

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

  int get unitPriceHT => product.unitPriceHT;
  int get lineHT => roundDiv(unitPriceHT * qtyMilli, 1000);
  int get lineVAT => roundDiv(lineHT * product.vatRate, 10000);
  int get lineTTC => lineHT + lineVAT;
}

class PosScreen extends StatefulWidget {
  const PosScreen(
      {super.key, required this.api, required this.config, this.cashierName = ''});
  final ApiClient api;
  final LocalConfig config;
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
    _refreshStock();
    _search('');
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
      if (mounted) setState(() => _company = s);
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
      await rawPrint(printer, bytes);
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
      final items = await widget.api.products(q: q, limit: 60);
      if (mounted) setState(() => _results = items);
    } catch (_) {
      if (mounted) setState(() => _results = const []);
    }
  }

  /// Barcode scanners type the code then send Enter.
  Future<void> _onSubmitted(String q) async {
    if (q.trim().isEmpty) return;
    try {
      final items = await widget.api.products(q: q.trim(), limit: 5);
      final exact = items.where((p) => p.barcode == q.trim()).toList();
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

  void _addToCart(Product p) {
    setState(() {
      final existing = _cart.where((l) => l.product.id == p.id);
      if (existing.isNotEmpty) {
        existing.first.qtyMilli += 1000;
      } else {
        _cart.add(CartLine(p));
      }
    });
  }

  void _changeQty(CartLine line, int deltaMilli) {
    setState(() {
      line.qtyMilli += deltaMilli;
      if (line.qtyMilli <= 0) _cart.remove(line);
    });
  }

  Future<void> _editQty(CartLine line) async {
    final ctrl = TextEditingController(text: fmtQty(line.qtyMilli));
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
                  onSubmitted: (v) =>
                      Navigator.of(context).pop(parseQty(v)),
                  decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              const SizedBox(height: 14),
              PrimaryButton(
                label: 'Valider',
                onPressed: () =>
                    Navigator.of(context).pop(parseQty(ctrl.text)),
              ),
            ]),
          ),
        ),
      ),
    );
    ctrl.dispose();
    if (result != null && result > 0) {
      setState(() => line.qtyMilli = result);
    }
    _searchFocus.requestFocus();
  }

  Future<void> _pickClient() async {
    final p = await showPartnerPicker(context, widget.api, kind: 'customer');
    if (p != null) setState(() => _client = p);
    _searchFocus.requestFocus();
  }

  int get _totalHT => _cart.fold(0, (s, l) => s + l.lineHT);
  int get _totalVAT => _cart.fold(0, (s, l) => s + l.lineVAT);
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
    await _checkout(received: received);
  }

  Future<void> _checkout({int? received}) async {
    setState(() => _checkingOut = true);
    try {
      final posted = await widget.api.checkoutTicket(
        warehouseId: _warehouseId!,
        paymentMethod: _paymentMethod,
        partnerId: _client?.id,
        caisseSessionId: _session?.id,
        lines: [
          for (final l in _cart)
            {
              'product_id': l.product.id,
              'description': l.product.name,
              'qty_milli': l.qtyMilli,
              'unit_price': l.unitPriceHT,
              'vat_rate': l.product.vatRate,
            }
        ],
      );
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
                const SizedBox(height: 16),
                Expanded(
                  child: _results.isEmpty
                      ? const EmptyState(
                          icon: Icons.qr_code_scanner,
                          text:
                              'Aucun produit.\nScannez un code-barres ou tapez un nom.')
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            mainAxisExtent: 120,
                          ),
                          itemCount: _results.length,
                          itemBuilder: (context, i) => _ProductTile(
                            product: _results[i],
                            stockMilli: _stockByProduct[_results[i].id] ?? 0,
                            onTap: () {
                              _addToCart(_results[i]);
                              _searchFocus.requestFocus();
                            },
                          ),
                        ),
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
                        const Expanded(child: MicroLabel('Total à payer')),
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
                      const SizedBox(width: 8),
                      _PayChoice(
                          label: 'CIB',
                          icon: Icons.credit_card,
                          selected: _paymentMethod == 'cib',
                          onTap: () =>
                              setState(() => _paymentMethod = 'cib')),
                      const SizedBox(width: 8),
                      _PayChoice(
                          label: 'Crédit',
                          icon: Icons.menu_book_outlined,
                          selected: _paymentMethod == 'credit',
                          onTap: () {
                            setState(() => _paymentMethod = 'credit');
                            if (_client == null) _pickClient();
                          }),
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
      {required this.product, required this.stockMilli, required this.onTap});
  final Product product;
  final int stockMilli;
  final VoidCallback onTap;

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
                const Spacer(),
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
              Text(fmtDA(p.priceRetail),
                  style: T.monoBody.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: T.mintDark)),
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
    required this.onDelta,
    required this.onEditQty,
    required this.onRemove,
  });
  final CartLine line;
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
                    '${fmtDA(line.product.priceRetail)} × ${fmtQty(line.qtyMilli)}',
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
                  onTap: () => widget.onDelta(line, -1000)),
              InkWell(
                onTap: widget.onEditQty,
                child: SizedBox(
                  width: 34,
                  child: Text(fmtQty(line.qtyMilli),
                      textAlign: TextAlign.center,
                      style: T.monoBody.copyWith(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
              _StepBtn(
                  icon: Icons.add, onTap: () => widget.onDelta(line, 1000)),
            ]),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: Text(fmtDA(line.lineTTC),
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
