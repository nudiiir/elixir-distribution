import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../theme/tokens.dart';
import '../util/config.dart';
import '../util/escpos.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../util/raw_printer.dart';
import '../util/shortcuts.dart';
import '../widgets/doc_editor.dart' show showPartnerPicker;
import '../widgets/doc_list.dart' show showDocDetailDialog;
import '../widgets/product_thumb.dart';
import '../widgets/side_panel.dart';
import '../widgets/ui.dart';
import 'pos/cart_line.dart';
import 'pos/cash_rounding.dart';
import 'pos/mixed_payment_dialog.dart';
import 'pos/parked_tickets.dart';
import 'pos/parked_tickets_dialog.dart';
import 'pos/pos_customer.dart';
import 'pos/pos_rights.dart';
import 'pos/recent_tickets_panel.dart';

export 'pos/cart_line.dart';

/// Pastel avatar colours of a product name (kept for older callers).
(Color, Color) pastelFor(String name) => productPastel(name);

class PosScreen extends StatefulWidget {
  const PosScreen({
    super.key,
    required this.api,
    required this.config,
    required this.user,
    this.cashierName = '',
    this.onSwitchUser,
  });
  final ApiClient api;
  final LocalConfig config;
  final User user;
  final String cashierName;

  /// « Changer de caissier » succeeded: the shell switches to [Session]
  /// (new token, new user) and rebuilds the till for that cashier.
  final void Function(Session session)? onSwitchUser;

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
  bool _favOnly = false; // « Favoris » pill
  Set<String> _favorites = {};
  int _parkedCount = 0;
  // « Rendu : X DA » of the last sale, shown until the next scan.
  int? _lastChange;
  // Paramètres › Caisse : client proposé à chaque nouveau ticket.
  Partner? _defaultClient;
  // Groupe (tarif + remise) et points fidélité du client choisi.
  PosCustomerInfo _clientInfo = const PosCustomerInfo();
  String? _clientInfoFor; // partner id _clientInfo belongs to
  // Points fidélité utilisés sur ce ticket (ligne « Points fidélité »).
  PosLoyaltyUse? _pointsUse;
  // Manager code already typed on this ticket (price change): sent with the
  // checkout so the manager is not asked twice.
  String? _pendingApproval;

  late final PosRights _rights = PosRights(widget.user);
  Features get _f => Features.instance;
  bool get _canDiscount => _rights.discount;
  String get _priceLevel =>
      _clientInfo.groupPriceLevel ?? _client?.priceLevel ?? 'retail';

  /// The customer changed (or may have): drop the points used for the
  /// previous one and load the new one's group and points.
  void _clientChanged() {
    final id = _client?.id;
    final use = _pointsUse;
    if (use != null && id != _clientInfoFor) {
      _pointsUse = null;
      cancelPosPoints(widget.api, use.redemptionId).catchError((_) {});
    }
    if (id == _clientInfoFor) return;
    _clientInfoFor = id;
    _clientInfo = const PosCustomerInfo();
    if (id == null) return;
    loadPosCustomerInfo(widget.api, id, loyalty: _f.loyaltyEnabled).then((
      info,
    ) {
      if (mounted && _client?.id == id) setState(() => _clientInfo = info);
    });
  }

  /// The group's remise follows every line (lines with their own remise
  /// keep it).
  void _syncGroupDiscount() {
    final g = _clientInfo.groupDiscountPct;
    for (final l in _cart) {
      l.groupDiscountPct = g;
    }
  }

  /// Gives back the points of an abandoned ticket.
  void _dropPoints() {
    final use = _pointsUse;
    if (use == null) return;
    _pointsUse = null;
    cancelPosPoints(widget.api, use.redemptionId).catchError((_) {});
  }

  /// Payment tiles offered by the shop (Paramètres › Caisse).
  List<(String, String, IconData)> get _offeredMethods {
    final on = _f.posPaymentMethods;
    final all = <(String, String, IconData)>[
      ('cash', 'Espèces', Icons.payments_outlined),
      ('cib', 'CIB', Icons.credit_card),
      ('edahabia', 'Edahabia', Icons.contactless_outlined),
      ('cheque', 'Chèque', Icons.request_page_outlined),
      ('credit', 'Crédit client', Icons.menu_book_outlined),
      ('gift', 'Carte cadeau', Icons.card_giftcard),
      if (_f.loyaltyEnabled)
        ('loyalty', 'Points fidélité', Icons.loyalty_outlined),
    ];
    final list = [
      for (final m in all)
        if (on.contains(m.$1)) m,
    ];
    return list.isEmpty ? all.take(1).toList() : list;
  }

  /// Method a new ticket starts with: cash when offered, else the first tile.
  String get _firstMethod {
    final ids = [for (final m in _offeredMethods) m.$1];
    return ids.contains('cash') ? 'cash' : ids.first;
  }

  /// A new ticket: default customer and first payment method.
  void _resetTicketState() {
    _client = _defaultClient;
    _paymentMethod = _firstMethod;
    _clientChanged();
  }

  /// The open till dates from a previous day and the shop requires a Z.
  bool get _needsDailyZ {
    final s = _session;
    if (s == null || !_f.posRequireDailyZ) return false;
    final opened = DateTime.tryParse(s.openedAt)?.toLocal();
    if (opened == null) return false;
    final now = DateTime.now();
    return DateTime(
      opened.year,
      opened.month,
      opened.day,
    ).isBefore(DateTime(now.year, now.month, now.day));
  }

  @override
  void initState() {
    super.initState();
    _paymentMethod = _firstMethod;
    _f.addListener(_onFeatures);
    _init();
    _refreshParked();
  }

  /// Paramètres › Caisse saved on this PC: follow the new tiles at once.
  void _onFeatures() {
    if (!mounted) return;
    setState(() {
      if (!_offeredMethods.any((m) => m.$1 == _paymentMethod)) {
        _paymentMethod = _firstMethod;
      }
    });
  }

  Future<void> _refreshParked() async {
    final n = (await ParkedTicketStore.instance.list()).length;
    if (mounted) setState(() => _parkedCount = n);
  }

  /// Any change to the cart hides the « Rendu » of the previous sale.
  void _touch() => _lastChange = null;

  List<CartLine> _snapshot() => [for (final l in _cart) l.copy()];

  void _restoreCart(List<CartLine> lines, Partner? client, String method) {
    if (!mounted) return;
    setState(() {
      _cart
        ..clear()
        ..addAll(lines);
      _client = client;
      _paymentMethod = method;
      _clientChanged();
      _touch();
    });
    _searchFocus.requestFocus();
  }

  // ---- Vider / retirer avec « Annuler » ----

  void _clearTicket() {
    if (_cart.isEmpty) return;
    final before = _snapshot();
    final client = _client;
    final method = _paymentMethod;
    final hadPoints = _pointsUse != null;
    setState(() {
      _cart.clear();
      _dropPoints();
      _resetTicketState();
    });
    showUndoToast(
      context,
      hadPoints
          ? 'Ticket vidé (${before.length} ligne(s)) — les points fidélité sont rendus au client.'
          : 'Ticket vidé (${before.length} ligne(s)).',
      undo: () => _restoreCart(before, client, method),
    );
    _searchFocus.requestFocus();
  }

  void _removeLine(CartLine line) {
    final before = _snapshot();
    final client = _client;
    final method = _paymentMethod;
    setState(() {
      _cart.remove(line);
      _touch();
    });
    showUndoToast(
      context,
      '« ${line.product.name} » retiré du ticket.',
      undo: () => _restoreCart(before, client, method),
    );
  }

  // ---- Tickets en attente ----

  Future<void> _hold() async {
    if (_cart.isEmpty) {
      showToast(
        context,
        'Ticket vide : rien à mettre en attente.',
        kind: ToastKind.info,
      );
      return;
    }
    final t = await ParkedTicketStore.instance.park(
      lines: [
        for (final l in _cart)
          ParkedLine(
            l.product,
            l.qtyMilli,
            l.discountPct,
            priceOverride: l.priceOverride,
          ),
      ],
      client: _client,
      paymentMethod: _paymentMethod,
      cashier: widget.cashierName,
    );
    if (!mounted) return;
    setState(() {
      _cart.clear();
      // Points are not kept on hold: they are used again at payment.
      _dropPoints();
      _resetTicketState();
      _touch();
    });
    await _refreshParked();
    if (!mounted) return;
    showToast(context, 'Ticket mis en attente (n° ${t.number}).');
    _searchFocus.requestFocus();
  }

  Future<void> _showParked() async {
    final pick = await showDialog<ParkedTicket>(
      context: context,
      builder: (_) => const ParkedTicketsDialog(),
    );
    if (pick != null && mounted) {
      // The cart in progress is not lost: it goes on hold in its place.
      if (_cart.isNotEmpty) await _hold();
      await ParkedTicketStore.instance.remove(pick.number);
      _restoreCart(
        [
          for (final l in pick.lines)
            CartLine(l.product)
              ..qtyMilli = l.qtyMilli
              ..discountPct = l.discountPct
              ..priceOverride = l.priceOverride,
        ],
        pick.partner,
        pick.paymentMethod,
      );
    }
    await _refreshParked();
    _searchFocus.requestFocus();
  }

  // ---- Derniers tickets ----

  Future<void> _showRecent() async {
    await showSidePanel<void>(
      context,
      width: 620,
      builder: (ctx) => RecentTicketsPanel(
        api: widget.api,
        onReprint: (t) async {
          if ((widget.config.ticketPrinter ?? '').isEmpty) {
            showToast(
              ctx,
              'Aucune imprimante ticket configurée sur ce poste.',
              kind: ToastKind.warning,
            );
            return;
          }
          try {
            final doc = await widget.api.getDocument(t.id);
            await _printTicket(doc, payments: t.payments, kick: false);
          } on ApiException catch (e) {
            if (ctx.mounted) {
              showToast(
                ctx,
                'Réimpression impossible : ${e.message}',
                kind: ToastKind.error,
              );
            }
          }
        },
        onOpen: (t) => showDocDetailDialog(ctx, widget.api, t.id),
        onReturn: (t) {
          Navigator.of(ctx).pop();
          _startReturn(initialDocId: t.id);
        },
      ),
    );
    _searchFocus.requestFocus();
  }

  // ---- Clavier ----

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchCtrl.text.length,
    );
  }

  /// « + » / « − » / Suppr act on the last line — only while the search field
  /// is empty, so typing « coca-cola » still works.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_cart.isEmpty || _searchCtrl.text.isNotEmpty || _checkingOut) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final last = _cart.last;
    final step = last.product.isWeighable && Features.instance.weighed
        ? 100
        : 1000;
    if (k == LogicalKeyboardKey.add ||
        k == LogicalKeyboardKey.numpadAdd ||
        e.character == '+') {
      _changeQty(last, step);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract ||
        e.character == '-') {
      if (last.qtyMilli - step <= 0) {
        _removeLine(last);
      } else {
        _changeQty(last, -step);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete) {
      _removeLine(last);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _init() async {
    // The caisse settings may have changed on another PC since start.
    await _f.load(widget.api);
    try {
      final whs = await widget.api.warehouses();
      if (whs.isNotEmpty && mounted) {
        // A cashier limited to his depots sells from his own depot; else the
        // dépôt de la caisse (Paramètres › Caisse), else the default depot.
        final own = widget.user.scope == 'warehouse'
            ? widget.user.defaultWarehouseId
            : null;
        final wanted = own != null && whs.any((w) => w.id == own)
            ? own
            : _f.posDefaultWarehouseId;
        setState(
          () => _warehouseId = whs
              .firstWhere(
                (w) => w.id == wanted,
                orElse: () =>
                    whs.firstWhere((w) => w.isDefault, orElse: () => whs.first),
              )
              .id,
        );
      }
    } catch (_) {}
    final defId = _f.posDefaultCustomerId;
    if (defId != null) {
      try {
        final p = await widget.api.getPartner(defId);
        if (mounted && p.active) {
          setState(() {
            _defaultClient = p;
            if (_cart.isEmpty && _client == null) {
              _client = p;
              _clientChanged();
            }
          });
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _paymentMethod = _firstMethod);
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
      return {for (final id in jsonDecode(raw ?? '[]') as List) id.toString()};
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
      await widget.api.saveSettings({
        'pos_quick_keys': jsonEncode(next.toList()),
      });
    } catch (_) {}
  }

  Future<void> _openCaisse() async {
    final opened = await showDialog<CaisseSession>(
      context: context,
      builder: (_) =>
          _OpenCaisseDialog(api: widget.api, initialFloat: _f.posDefaultFloat),
    );
    if (opened != null) {
      setState(() => _session = opened);
      _searchFocus.requestFocus();
    }
  }

  Future<void> _showXReport() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ReportDialog(
        api: widget.api,
        closing: false,
        showTotals: _rights.viewToday,
      ),
    );
    _searchFocus.requestFocus();
  }

  Future<void> _closeCaisse() async {
    final closed = await showDialog<bool>(
      context: context,
      builder: (_) => _ReportDialog(
        api: widget.api,
        closing: true,
        showTotals: _rights.viewToday,
      ),
    );
    if (closed == true) setState(() => _session = null);
  }

  /// Sends the 80mm ticket to the configured thermal printer, if any.
  Future<void> _printTicket(
    DocDetail doc, {
    int? received,
    int? change,
    List<PosPayment> payments = const [],
    bool kick = true,
  }) async {
    final printer = widget.config.ticketPrinter;
    if (printer == null || printer.isEmpty) return;
    try {
      final bytes = buildTicket(
        company: _company,
        doc: doc,
        cashierName: widget.cashierName,
        received: received,
        change: change,
        payments: payments,
      );
      // Cash payment pops the drawer through the printer's RJ11 port.
      final hasCash =
          doc.paymentMethod == 'cash' ||
          payments.any((p) => p.method == 'cash');
      final payload = kick && hasCash && _f.posOpenDrawer
          ? [...drawerKick, ...bytes]
          : bytes;
      await rawPrint(printer, payload);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: T.warnDark,
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Impression du ticket impossible : $e',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white),
          ),
        ),
      );
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
    _f.removeListener(_onFeatures);
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

  /// « Bip au scan » (Paramètres › Caisse): a short sound when a scanned
  /// code lands on the ticket.
  void _beep() {
    if (_f.posBeep) SystemSound.play(SystemSoundType.alert);
  }

  /// Barcode scanners type the code then send Enter.
  Future<void> _onSubmitted(String q) async {
    q = q.trim();
    if (q.isEmpty) return;

    // Scale barcodes (GS1 prefixes 21/22): 2 P PPPPP VVVVV C —
    // 21 embeds the weight in grams, 22 the price in centimes.
    final scale = Features.instance.weighed
        ? RegExp(r'^(2[12])(\d{5})(\d{5})\d$').firstMatch(q)
        : null;
    if (scale != null && await _addScaleItem(scale)) {
      _beep();
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
        _beep();
        _addToCart(pick);
        _searchCtrl.clear();
        _search('');
      } else if (items.isEmpty && RegExp(r'^\d{6,14}$').hasMatch(q)) {
        // Démarrage progressif : un code inconnu scanné au comptoir ouvre une
        // création éclair — après trois semaines, les produits qui se vendent
        // vraiment existent, sans jamais avoir bloqué une vente.
        final created = await _quickCreateAtTill(q);
        if (created != null) {
          _addToCart(created);
          _searchCtrl.clear();
          _search('');
        }
      } else {
        setState(() => _results = items);
      }
    } catch (_) {}
    _searchFocus.requestFocus();
  }

  /// Création éclair au comptoir : deux champs, la vente continue.
  Future<Product?> _quickCreateAtTill(String barcode) async {
    final name = TextEditingController();
    final price = TextEditingController();
    final p = await showDialog<Product>(
      context: context,
      builder: (context) {
        String? error;
        bool busy = false;
        return StatefulBuilder(
          builder: (context, setDlg) {
            Future<void> create() async {
              if (name.text.trim().isEmpty || (parseDA(price.text) ?? 0) <= 0) {
                setDlg(() => error = 'Nom et prix de vente obligatoires.');
                return;
              }
              setDlg(() => busy = true);
              try {
                final created = await widget.api.saveProduct({
                  'name': name.text.trim(),
                  'barcode': barcode,
                  'vat_rate': Features.instance.defaultVat,
                  'purchase_price': 0,
                  'price_retail': parseDA(price.text) ?? 0,
                  'min_stock_milli': 0,
                  'is_weighable': false,
                  'unit': 'piece',
                  'track_lots': false,
                  'track_serials': false,
                  'warranty_months': 0,
                  'description': '',
                  'brand': '',
                  'track_expiry': false,
                });
                if (context.mounted) Navigator.of(context).pop(created);
              } on ApiException catch (e) {
                setDlg(() {
                  error = e.message;
                  busy = false;
                });
              }
            }

            return AlertDialog(
              backgroundColor: T.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(T.rCard),
              ),
              title: Text('Produit inconnu', style: T.h2),
              content: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Code $barcode — créez-le et encaissez.',
                      style: T.small,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: name,
                      autofocus: true,
                      style: T.body,
                      decoration: const InputDecoration(
                        labelText: 'Désignation *',
                      ),
                      onSubmitted: (_) => create(),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: price,
                      style: T.monoBody,
                      decoration: const InputDecoration(
                        labelText: 'Prix de vente TTC *',
                      ),
                      onSubmitted: (_) => create(),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: T.small.copyWith(color: T.dangerDark),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: T.mint,
                    foregroundColor: T.ink,
                  ),
                  onPressed: busy ? null : create,
                  child: Text(busy ? '…' : 'Créer et encaisser'),
                ),
              ],
            );
          },
        );
      },
    );
    Future.delayed(const Duration(seconds: 1), () {
      name.dispose();
      price.dispose();
    });
    return p;
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
      _touch();
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
    if (p.isWeighable && Features.instance.weighed) {
      final milli = await _askWeight(p);
      if (milli == null || milli <= 0) {
        _searchFocus.requestFocus();
        return;
      }
      setState(() {
        _touch();
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
      _touch();
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
          borderRadius: BorderRadius.circular(T.rCard),
        ),
        child: SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(p.name, style: T.h2, textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text(
                  'Poids en kg · ${fmtDA(p.effectivePriceTTC)}/kg',
                  style: T.small,
                ),
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
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final (label, milli) in [
                      ('250 g', 250),
                      ('500 g', 500),
                      ('1 kg', 1000),
                      ('2 kg', 2000),
                    ])
                      ActionChip(
                        label: Text(
                          label,
                          style: T.small.copyWith(
                            fontWeight: FontWeight.w700,
                            color: T.mintDark,
                          ),
                        ),
                        backgroundColor: T.mintTint,
                        side: BorderSide.none,
                        onPressed: () => Navigator.of(context).pop(milli),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Ajouter',
                  onPressed: () =>
                      Navigator.of(context).pop(parseQty(ctrl.text)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  void _changeQty(CartLine line, int deltaMilli) {
    if (line.qtyMilli + deltaMilli <= 0) {
      _removeLine(line);
      return;
    }
    setState(() {
      _touch();
      line.qtyMilli += deltaMilli;
    });
  }

  /// Line editor: quantity, remise (right `discount`) and unit price (right
  /// `price_edit`, else the manager's code).
  Future<void> _editQty(CartLine line) async {
    final ctrl = TextEditingController(text: fmtQty(line.qtyMilli));
    final discCtrl = TextEditingController(
      text: line.discountPct == 0 ? '' : '${line.discountPct ~/ 100}',
    );
    final basePrice = line.product.priceFor(_priceLevel);
    final priceCtrl = TextEditingController(
      text: editDA(line.unitTTC(_priceLevel)),
    );
    final maxPct = _rights.maxDiscountPct;
    final result = await showDialog<(int, int, int?)>(
      context: context,
      builder: (context) {
        (int, int, int?)? parse() {
          final q = parseQty(ctrl.text);
          if (q == null || q <= 0) return null;
          final d = int.tryParse(discCtrl.text.trim()) ?? 0;
          final p = parseDA(priceCtrl.text);
          final price = p == null || p <= 0 || p == basePrice ? null : p;
          return (q, (d.clamp(0, 100)) * 100, price);
        }

        Widget field(
          TextEditingController c, {
          bool big = false,
          bool autofocus = false,
          String? hint,
        }) => Container(
          height: big ? 54 : 44,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: TextField(
            controller: c,
            autofocus: autofocus,
            textAlign: TextAlign.center,
            style: big ? T.monoBig : T.monoBody,
            onSubmitted: (_) => Navigator.of(context).pop(parse()),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: hint,
              hintStyle: T.small.copyWith(color: T.ghost),
              contentPadding: EdgeInsets.symmetric(vertical: big ? 12 : 10),
            ),
          ),
        );

        return Dialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard),
          ),
          child: SizedBox(
            width: 320,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    line.product.name,
                    style: T.h2,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    line.product.isWeighable && Features.instance.weighed
                        ? 'Quantité (kg)'
                        : 'Quantité',
                    style: T.label,
                  ),
                  const SizedBox(height: 6),
                  field(ctrl, big: true, autofocus: true),
                  if (_canDiscount) ...[
                    const SizedBox(height: 10),
                    const Text('Remise (%)', style: T.label),
                    const SizedBox(height: 6),
                    field(discCtrl, hint: '0–100'),
                    if (maxPct != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Au-delà de ${maxPct ~/ 100} %, le code du gérant sera demandé à l’encaissement.',
                        style: T.small,
                      ),
                    ],
                  ],
                  const SizedBox(height: 10),
                  const Text('Prix unitaire TTC (DA)', style: T.label),
                  const SizedBox(height: 6),
                  field(priceCtrl),
                  const SizedBox(height: 4),
                  Text(
                    _rights.priceEdit
                        ? 'Prix normal : ${fmtDA(basePrice)}.'
                        : 'Prix normal : ${fmtDA(basePrice)}. Changer le prix demande le code du gérant.',
                    style: T.small,
                  ),
                  const SizedBox(height: 14),
                  PrimaryButton(
                    label: 'Valider',
                    onPressed: () => Navigator.of(context).pop(parse()),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    ctrl.dispose();
    discCtrl.dispose();
    priceCtrl.dispose();
    if (result != null && mounted) {
      var price = result.$3;
      if (price != line.priceOverride && price != null) {
        final grant = await posRequireRight(
          context,
          widget.api,
          _rights,
          'price_edit',
        );
        if (grant == null) {
          price = line.priceOverride;
        } else if (grant.token != null) {
          _pendingApproval = grant.token;
        }
      }
      if (!mounted) return;
      setState(() {
        line.qtyMilli = result.$1;
        if (_canDiscount) line.discountPct = result.$2;
        line.priceOverride = price;
        _touch();
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
          borderRadius: BorderRadius.circular(T.rCard),
        ),
        child: SizedBox(
          width: 280,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
              ],
            ),
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
    if (p != null) {
      setState(() {
        _client = p;
        _clientChanged();
      });
    }
    _searchFocus.requestFocus();
  }

  /// Return flow: pick the original sale, choose the lines, refund in cash.
  Future<void> _startReturn({String? initialDocId}) async {
    // Right `refund` (retour / avoir), else the manager's code.
    final grant = await posRequireRight(context, widget.api, _rights, 'refund');
    if (grant == null || !mounted) return;
    final refunded = await showDialog<DocDetail>(
      context: context,
      builder: (_) => _ReturnDialog(
        api: widget.api,
        preApproved: grant.token,
        warehouseId: _warehouseId,
        caisseSessionId: _session?.id,
        initialDocId: initialDocId,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: T.ink,
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Retour ${refunded.number} validé — rendre ${fmtDA(refunded.totalTTC)} au client.',
            style: const TextStyle(fontFamily: T.sans, color: Colors.white),
          ),
        ),
      );
    }
    _searchFocus.requestFocus();
  }

  int get _totalHT => _cart.fold(0, (s, l) => s + l.lineHT(_priceLevel));
  int get _totalVAT => _cart.fold(0, (s, l) => s + l.lineVAT(_priceLevel));

  /// Value of the loyalty points used on this ticket.
  int get _pointsValue => _pointsUse?.value ?? 0;

  /// What the goods cost once the points are taken off (timbre excluded).
  int get _goods => _totalHT + _totalVAT - _pointsValue;

  /// « Arrondi » of a cash ticket (Paramètres › Caisse) — the server adds the
  /// same amount as an « Arrondi » line, so the total is the cash taken.
  int get _rounding {
    if (_paymentMethod != 'cash' || _cart.isEmpty) return 0;
    return cashRoundingDelta(_goods, posCashStep);
  }

  int get _timbre {
    if (_paymentMethod != 'cash' || _cart.isEmpty) return 0;
    return posTimbre(_goods + _rounding);
  }

  int get _totalTTC => _goods + _rounding + _timbre;
  int get _itemCount => _cart.fold(0, (s, l) => s + (l.qtyMilli / 1000).ceil());

  /// « Demander le client au-delà de X DA » (Paramètres › Caisse): true to go
  /// on (client chosen or explicitly skipped), false to stay on the ticket.
  Future<bool> _askCustomerIfNeeded() async {
    final above = _f.posAskCustomerAbove;
    if (above <= 0 || _totalTTC < above) return true;
    if (_client != null && _client?.id != _defaultClient?.id) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
        ),
        title: const Text('À quel client est cette vente ?', style: T.h2),
        content: SizedBox(
          width: 380,
          child: Text(
            'Ce ticket fait ${fmtDA(_totalTTC)}. Au-delà de ${fmtDA(above)}, '
            'le magasin demande le nom du client (garantie, retour, fidélité).',
            style: T.body,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('skip'),
            child: const Text('Continuer sans client'),
          ),
          PrimaryButton(
            label: 'Choisir le client (F6)',
            onPressed: () => Navigator.of(ctx).pop('pick'),
          ),
        ],
      ),
    );
    if (choice == 'skip') return true;
    if (choice != 'pick') return false;
    await _pickClient();
    return _client != null && _client?.id != _defaultClient?.id;
  }

  Future<void> _startCheckout({bool mixed = false}) async {
    if (_cart.isEmpty || _warehouseId == null || _checkingOut) return;
    if (_needsDailyZ) {
      showToast(
        context,
        'Clôturez la caisse d’hier (rapport Z) avant de vendre.',
        kind: ToastKind.warning,
      );
      return;
    }
    _syncGroupDiscount();
    if (_goods < 0) {
      showToast(
        context,
        'Les points fidélité dépassent le total du ticket : rendez-les au client ou ajoutez des articles.',
        kind: ToastKind.warning,
      );
      return;
    }
    if (!mixed && _paymentMethod == 'credit' && _client == null) {
      await _pickClient();
      if (_client == null) return;
    }
    if (!mounted) return;
    if (!await _askCustomerIfNeeded()) {
      _searchFocus.requestFocus();
      return;
    }
    if (!mounted) return;

    // Serialized products (IMEI): capture which physical unit goes out.
    Map<String, List<String>> serialsByProduct = {};
    final serialized = Features.instance.serials
        ? _cart.where((l) => l.product.trackSerials).toList()
        : <CartLine>[];
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

    if (mixed) {
      final res = await showDialog<MixedPaymentResult>(
        context: context,
        builder: (_) =>
            MixedPaymentDialog(goodsTotal: _goods, hasClient: _client != null),
      );
      if (res == null) {
        _searchFocus.requestFocus();
        return;
      }
      await _checkout(
        payments: res.payments,
        received: res.cashReceived > 0 ? res.cashReceived : null,
        change: res.change,
        serials: serialsByProduct,
      );
      return;
    }

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
        builder: (context) =>
            _CashDialog(total: _totalTTC, rounding: _rounding),
      );
      if (received == null) {
        _searchFocus.requestFocus();
        return; // cancelled
      }
    }
    await _checkout(
      received: received,
      giftUseId: giftUseId,
      serials: serialsByProduct,
    );
  }

  Future<void> _checkout({
    int? received,
    int? change,
    String? giftUseId,
    List<PosPayment>? payments,
    Map<String, List<String>> serials = const {},
  }) async {
    setState(() => _checkingOut = true);
    try {
      _syncGroupDiscount();
      final goods = _goods;
      final points = _pointsUse;
      final lines = [
        for (final l in _cart)
          {
            'product_id': l.product.id,
            'description': l.product.name,
            'qty_milli': l.qtyMilli,
            'unit_price': l.unitHT(_priceLevel),
            'discount_pct': l.effectiveDiscountPct,
            'vat_rate': l.product.vatRate,
          },
        // Points fidélité: their value comes off the ticket as a line.
        if (points != null)
          {
            'product_id': null,
            'description': 'Points fidélité (${points.points} pts)',
            'qty_milli': 1000,
            'unit_price': -points.value,
            'discount_pct': 0,
            'vat_rate': 0,
          },
      ];
      // Remise above the cashier's limit, sale on credit beyond his rights
      // or the customer's ceiling: the server asks for the manager's code.
      final pre = _pendingApproval;
      _pendingApproval = null;
      final (posted, paid) = await posWithApproval(
        context,
        widget.api,
        preApproved: pre,
        () => widget.api.posCheckout(
          warehouseId: _warehouseId!,
          // A gift-card sale is not cash in the drawer: no method, no timbre —
          // it is recorded as one « gift » payment row.
          paymentMethod: payments != null || _paymentMethod == 'gift'
              ? null
              : _paymentMethod,
          payments:
              payments ??
              (_paymentMethod == 'gift'
                  ? [PosPayment('gift', goods)]
                  : const []),
          partnerId: _client?.id,
          caisseSessionId: _session?.id,
          lines: lines,
        ),
      );
      // Mark the sold serials — the sale stands even if this trails behind.
      for (final e in serials.entries) {
        for (final serial in e.value) {
          try {
            await widget.api.sellUnit(
              serial,
              productId: e.key,
              saleDocId: posted.id,
              partnerId: _client?.id,
            );
          } catch (_) {}
        }
      }
      if (!mounted) return;
      final rendu =
          change ??
          (received == null
              ? 0
              : (received - posted.totalTTC).clamp(0, 1 << 48).toInt());
      setState(() {
        _cart.clear();
        _pointsUse = null; // consumed by the sale
        _resetTicketState();
        _lastChange = received == null ? null : rendu;
      });
      _refreshStock();
      _afterSaleHardware(
        posted,
        received: received,
        change: rendu,
        payments: paid,
      );
      await _showSuccess(posted, rendu);
    } on ApiException catch (e) {
      // The card was debited but the sale never posted — give the money back.
      if (giftUseId != null) {
        try {
          await widget.api.refundGiftCardUse(giftUseId);
        } catch (_) {}
      }
      if (!mounted) return;
      // « Clôturez la caisse d'hier » from the server: show the Z card.
      if (e.status == 409 && e.message.contains('rapport Z')) _loadSession();
      showToast(
        context,
        'Échec de la vente : ${e.message}',
        kind: ToastKind.error,
      );
    } finally {
      if (mounted) setState(() => _checkingOut = false);
      _searchFocus.requestFocus();
    }
  }

  /// After a sale: ticket (« Imprimer le ticket automatiquement ») and drawer
  /// (« Ouvrir le tiroir après une vente en espèces »), Paramètres › Caisse.
  void _afterSaleHardware(
    DocDetail posted, {
    int? received,
    required int change,
    required List<PosPayment> payments,
  }) {
    final printer = widget.config.ticketPrinter;
    if (printer == null || printer.isEmpty) return;
    if (_f.posAutoPrint) {
      _printTicket(
        posted,
        received: received,
        change: change,
        payments: payments,
      );
      return;
    }
    final hasCash =
        posted.paymentMethod == 'cash' ||
        payments.any((p) => p.method == 'cash');
    if (hasCash && _f.posOpenDrawer) {
      rawPrint(printer, drawerKick).catchError((_) {});
    }
    showToast(
      context,
      'Vente ${posted.number ?? ''} enregistrée.',
      actionLabel: 'Imprimer le ticket',
      onAction: () => _printTicket(
        posted,
        received: received,
        change: change,
        payments: payments,
        kick: false,
      ),
    );
  }

  /// « Ouvrir le tiroir » without a sale — right `open_drawer`, else the
  /// manager's code.
  Future<void> _openDrawer() async {
    final printer = widget.config.ticketPrinter;
    if (printer == null || printer.isEmpty) {
      showToast(
        context,
        'Aucune imprimante ticket configurée sur ce poste : le tiroir s’ouvre par elle.',
        kind: ToastKind.warning,
      );
      return;
    }
    final grant = await posRequireRight(
      context,
      widget.api,
      _rights,
      'open_drawer',
    );
    if (grant == null) return;
    try {
      await rawPrint(printer, drawerKick);
    } catch (e) {
      if (mounted) {
        showToast(context, 'Tiroir : $e', kind: ToastKind.error);
      }
    }
    _searchFocus.requestFocus();
  }

  /// « Changer de caissier » : PIN of another user; the shell switches.
  Future<void> _switchCashier() async {
    if (_cart.isNotEmpty) {
      final go = await confirmAction(
        context,
        title: 'Changer de caissier ?',
        message:
            'Le ticket en cours sera mis en attente : le prochain caissier pourra le reprendre (F5).',
        confirmLabel: 'Mettre en attente et changer',
      );
      if (!go || !mounted) return;
      await _hold();
      if (!mounted) return;
    }
    final session = await posSwitchUser(context, widget.api);
    if (session != null) widget.onSwitchUser?.call(session);
  }

  /// « Utiliser les points » : the customer's loyalty points pay part (or
  /// all) of the ticket. Tapping it again gives the points back.
  Future<void> _usePoints() async {
    if (_cart.isEmpty) {
      showToast(
        context,
        'Ajoutez d’abord les articles du ticket.',
        kind: ToastKind.info,
      );
      return;
    }
    if (_client == null || _client?.id == _defaultClient?.id) {
      await _pickClient();
      if (_client == null || !mounted) return;
    }
    final used = _pointsUse;
    if (used != null) {
      final back = await confirmAction(
        context,
        title: 'Rendre les points ?',
        message:
            '${used.points} points (${fmtDA(used.value)}) sont utilisés sur ce ticket. Les rendre au client ?',
        confirmLabel: 'Rendre les points',
      );
      if (back && mounted) setState(_dropPoints);
      return;
    }
    // Fresh balance (the customer may have bought elsewhere meanwhile).
    final info = await loadPosCustomerInfo(widget.api, _client!.id);
    if (!mounted) return;
    setState(() => _clientInfo = info);
    if (!info.loyaltyEnabled || info.pointValue <= 0) {
      showToast(
        context,
        'Le programme de fidélité n’est pas activé (Paramètres › Clients et fidélité).',
        kind: ToastKind.info,
      );
      return;
    }
    if (!info.canRedeem) {
      showToast(
        context,
        '${_client!.name} a ${info.points} points : il en faut ${info.minRedeem} pour les utiliser.',
        kind: ToastKind.info,
      );
      return;
    }
    _syncGroupDiscount();
    final maxByTicket = (_totalHT + _totalVAT) ~/ info.pointValue;
    final maxPts = info.points < maxByTicket ? info.points : maxByTicket;
    if (maxPts <= 0) return;
    final ctrl = TextEditingController(text: '$maxPts');
    final pts = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final n = int.tryParse(ctrl.text.trim()) ?? 0;
          final err = n <= 0
              ? 'Indiquez un nombre de points.'
              : n > maxPts
              ? 'Au plus $maxPts points sur ce ticket.'
              : n < info.minRedeem
              ? 'Au moins ${info.minRedeem} points.'
              : null;
          return AlertDialog(
            backgroundColor: T.surface,
            title: const Text('Utiliser les points', style: T.h2),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_client!.name} a ${info.points} points '
                    '(${fmtDA(info.pointsValue)}). 1 point = ${fmtDA(info.pointValue)}.',
                    style: T.body,
                  ),
                  const SizedBox(height: 12),
                  const Text('Points à utiliser', style: T.label),
                  const SizedBox(height: 6),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: T.monoBody,
                    onChanged: (_) => setDlg(() {}),
                    onSubmitted: (_) {
                      if (err == null) Navigator.of(ctx).pop(n);
                    },
                  ),
                  const SizedBox(height: 6),
                  if (err != null)
                    FieldError(err)
                  else
                    Text(
                      'Déduit du ticket : ${fmtDA(n * info.pointValue)}',
                      style: T.small,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Annuler'),
              ),
              PrimaryButton(
                label: 'Utiliser',
                onPressed: err == null ? () => Navigator.of(ctx).pop(n) : null,
              ),
            ],
          );
        },
      ),
    );
    Future.delayed(const Duration(seconds: 1), ctrl.dispose);
    if (pts == null || !mounted) return;
    try {
      final use = await redeemPosPoints(widget.api, _client!.id, pts);
      if (!mounted) return;
      setState(() {
        _pointsUse = use;
        _clientInfo = PosCustomerInfo(
          groupName: info.groupName,
          groupPriceLevel: info.groupPriceLevel,
          groupDiscountPct: info.groupDiscountPct,
          loyaltyEnabled: info.loyaltyEnabled,
          points: info.points - use.points,
          pointValue: info.pointValue,
          minRedeem: info.minRedeem,
          canRedeem: false,
        );
      });
      showToast(
        context,
        '${use.points} points utilisés : ${fmtDA(use.value)} déduits du ticket. Choisissez comment payer le reste.',
      );
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
    _searchFocus.requestFocus();
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: SizedBox(
            width: 320,
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(
                      color: T.mintTint2,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 32,
                      color: T.mintDark,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(doc.number ?? '', style: T.monoSmall),
                  const SizedBox(height: 6),
                  Text(
                    fmtDA(doc.totalTTC),
                    style: const TextStyle(
                      fontFamily: T.sans,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: T.ink,
                    ),
                  ),
                  if (change > 0) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('À rendre  ', style: T.small),
                          Text(
                            fmtDA(change),
                            style: T.monoBody.copyWith(
                              fontWeight: FontWeight.w600,
                              color: T.warnDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
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
                  color: T.mintTint,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.point_of_sale_rounded,
                  size: 26,
                  color: T.mintDark,
                ),
              ),
              const SizedBox(height: 14),
              const Text('Caisse fermée', style: T.h1),
              const SizedBox(height: 6),
              Text(
                'Ouvrez une session avec le fond de caisse\npour commencer à encaisser.',
                textAlign: TextAlign.center,
                style: T.bodyMuted,
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 220,
                child: PrimaryButton(
                  label: 'Ouvrir la caisse',
                  big: true,
                  onPressed: _openCaisse,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_needsDailyZ) return _dailyZGate();
    _syncGroupDiscount();
    return CallbackShortcuts(
      bindings: bindingsFor({
        AppShortcuts.posSearch: _focusSearch,
        AppShortcuts.posHold: _hold,
        AppShortcuts.posParked: _showParked,
        AppShortcuts.posCustomer: _pickClient,
        AppShortcuts.posRecent: _showRecent,
        AppShortcuts.posMixed: () {
          if (_cart.isNotEmpty && !_checkingOut) _startCheckout(mixed: true);
        },
        AppShortcuts.posPay: () {
          if (_cart.isNotEmpty && !_checkingOut) _startCheckout();
        },
      }),
      child: Focus(onKeyEvent: _onKey, child: _buildBody(context)),
    );
  }

  /// « Clôturez la caisse d'hier (rapport Z) » — the till was opened on a
  /// previous day and the shop requires a daily Z (Paramètres › Caisse).
  Widget _dailyZGate() {
    final opened = DateTime.tryParse(_session!.openedAt)?.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final when = opened == null
        ? ''
        : ' le ${two(opened.day)}/${two(opened.month)} à ${two(opened.hour)}:${two(opened.minute)}';
    final canClose = _rights.closeTill;
    return Center(
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: T.warn),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: T.warnTint,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_clock_outlined,
                size: 26,
                color: T.warnDark,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Clôturez la caisse d’hier (rapport Z)',
              style: T.h1,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'La caisse est ouverte depuis$when. Le magasin demande un rapport Z '
              'chaque jour : comptez le tiroir et clôturez la caisse avant la '
              'première vente d’aujourd’hui.',
              textAlign: TextAlign.center,
              style: T.bodyMuted,
            ),
            if (!canClose) ...[
              const SizedBox(height: 10),
              Text(
                'Votre rôle ne permet pas de clôturer la caisse. Appelez un gérant '
                'ou l’administrateur : il clôture avec son compte, ou tape son code '
                'avec le bouton ci-dessous.',
                textAlign: TextAlign.center,
                style: T.body.copyWith(color: T.warnDark),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: 300,
              child: PrimaryButton(
                label: canClose
                    ? 'Clôturer la caisse (rapport Z)'
                    : 'Clôturer avec le code du gérant',
                big: true,
                onPressed: _closeCaisse,
              ),
            ),
            if (widget.onSwitchUser != null && posSwitchUserAvailable) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _switchCashier,
                icon: const Icon(Icons.switch_account_outlined, size: 18),
                label: const Text('Changer de caissier'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A labelled header button: icon + word (+ its keyboard key as a small
  /// extra hint). Nothing in the POS header is an icon alone.
  Widget _headerButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    String? keyHint,
    String? tooltip,
    bool highlight = false,
  }) {
    final btn = OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: highlight ? T.warnDark : T.ink,
        backgroundColor: highlight ? T.warnTint : T.surface,
        side: BorderSide(color: highlight ? T.warn : T.border3),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInner),
        ),
        textStyle: const TextStyle(
          fontFamily: T.sans,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Text(label),
          if (keyHint != null) ...[
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: T.bg,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: T.border3),
              ),
              child: Text(
                keyHint,
                style: T.monoSmall.copyWith(fontSize: 12, color: T.muted),
              ),
            ),
          ],
        ],
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  Widget _buildBody(BuildContext context) {
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
                Row(
                  children: [
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
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: T.mintTint,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: T.mint,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            'Ouverte ${_session!.openedAt.length >= 16 ? _session!.openedAt.substring(11, 16) : ''} · ${_session!.userName}',
                            style: T.monoSmall.copyWith(
                              color: T.mintDark,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Every caisse action, visible and labelled. Shortcuts stay
                // as extras (shown as small key hints).
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _headerButton(
                      label: 'Mettre en attente',
                      icon: Icons.pause_circle_outline,
                      keyHint: 'F4',
                      tooltip:
                          'Garder ce ticket de côté pour servir un autre client',
                      onPressed: _hold,
                    ),
                    _headerButton(
                      label: 'En attente ($_parkedCount)',
                      icon: Icons.pending_actions_outlined,
                      keyHint: 'F5',
                      highlight: _parkedCount > 0,
                      tooltip: 'Reprendre un ticket mis en attente',
                      onPressed: _showParked,
                    ),
                    _headerButton(
                      label: 'Derniers tickets',
                      icon: Icons.history_rounded,
                      keyHint: 'F7',
                      tooltip: 'Revoir, réimprimer ou rembourser un ticket',
                      onPressed: _showRecent,
                    ),
                    _headerButton(
                      label: 'Retour',
                      icon: Icons.assignment_return_outlined,
                      tooltip: _rights.refund
                          ? 'Retour / remboursement client'
                          : 'Retour / remboursement client — code du gérant nécessaire',
                      onPressed: () => _startReturn(),
                    ),
                    _headerButton(
                      label: 'Carte cadeau',
                      icon: Icons.card_giftcard,
                      tooltip: 'Vendre une carte cadeau',
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _GiftSellDialog(api: widget.api),
                      ).then((_) => _searchFocus.requestFocus()),
                    ),
                    _headerButton(
                      label: 'Ouvrir le tiroir',
                      icon: Icons.inbox_outlined,
                      tooltip: _rights.openDrawer
                          ? 'Ouvrir le tiroir-caisse sans vente (monnaie)'
                          : 'Ouvrir le tiroir-caisse sans vente — code du gérant nécessaire',
                      onPressed: _openDrawer,
                    ),
                    _headerButton(
                      label: 'Rapport X',
                      icon: Icons.receipt_long_outlined,
                      tooltip: _rights.closeTill
                          ? 'État de caisse en cours, sans clôturer'
                          : 'État de caisse en cours — code du gérant nécessaire',
                      onPressed: _showXReport,
                    ),
                    _headerButton(
                      label: 'Clôturer la caisse',
                      icon: Icons.lock_outline,
                      tooltip: _rights.closeTill
                          ? 'Compter la caisse et imprimer le rapport Z'
                          : 'Compter la caisse et imprimer le rapport Z — code du gérant nécessaire',
                      onPressed: _closeCaisse,
                    ),
                    if (widget.onSwitchUser != null && posSwitchUserAvailable)
                      _headerButton(
                        label: 'Changer de caissier',
                        icon: Icons.switch_account_outlined,
                        tooltip:
                            'Un autre caissier prend la caisse avec son code',
                        onPressed: _switchCashier,
                      ),
                  ],
                ),
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
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    autofocus: true,
                    onChanged: _onQueryChanged,
                    onSubmitted: _onSubmitted,
                    style: T.body.copyWith(fontSize: 15.5),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText:
                          'Scanner un code-barres ou rechercher un produit… (F3)',
                      hintStyle: T.bodyMuted.copyWith(
                        color: T.ghost,
                        fontSize: 15,
                      ),
                      prefixIcon: const Icon(
                        Icons.qr_code_scanner,
                        size: 19,
                        color: T.mintDeep,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_cats.isNotEmpty || _favorites.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 38,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _CatChip(
                          label: 'Tous',
                          selected: _catFilter == null && !_favOnly,
                          onTap: () => setState(() {
                            _catFilter = null;
                            _favOnly = false;
                          }),
                        ),
                        if (_favorites.isNotEmpty)
                          _CatChip(
                            label: 'Favoris',
                            icon: Icons.push_pin_rounded,
                            selected: _favOnly,
                            onTap: () => setState(() {
                              _favOnly = !_favOnly;
                              if (_favOnly) _catFilter = null;
                            }),
                          ),
                        for (final c in _cats)
                          _CatChip(
                            label: c.name,
                            selected: _catFilter == c.id,
                            onTap: () => setState(() {
                              _catFilter = _catFilter == c.id ? null : c.id;
                              _favOnly = false;
                            }),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final shown = [
                        for (final p in _results)
                          if ((_catFilter == null ||
                                  p.categoryId == _catFilter) &&
                              (!_favOnly || _favorites.contains(p.id)))
                            p,
                      ];
                      // Pinned quick keys come first while browsing.
                      if (_searchCtrl.text.trim().isEmpty &&
                          _favorites.isNotEmpty) {
                        shown.sort((a, b) {
                          final fa = _favorites.contains(a.id) ? 0 : 1;
                          final fb = _favorites.contains(b.id) ? 0 : 1;
                          return fa != fb
                              ? fa - fb
                              : a.name.toLowerCase().compareTo(
                                  b.name.toLowerCase(),
                                );
                        });
                      }
                      if (shown.isEmpty) {
                        final filtered =
                            _catFilter != null ||
                            _favOnly ||
                            _searchCtrl.text.trim().isNotEmpty;
                        return EmptyState(
                          icon: Icons.qr_code_scanner,
                          text: filtered
                              ? 'Aucun produit ne correspond.\nScannez un code-barres ou tapez un autre nom.'
                              : 'Aucun produit à vendre.\nAjoutez vos produits dans « Produits », puis revenez ici.',
                          actions: [
                            if (filtered)
                              (
                                'Voir tous les produits',
                                () {
                                  _searchCtrl.clear();
                                  setState(() {
                                    _catFilter = null;
                                    _favOnly = false;
                                  });
                                  _search('');
                                  _searchFocus.requestFocus();
                                },
                              ),
                          ],
                        );
                      }
                      return GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              mainAxisExtent: 156,
                            ),
                        itemCount: shown.length,
                        itemBuilder: (context, i) => _ProductTile(
                          api: widget.api,
                          product: shown[i],
                          stockMilli: _stockByProduct[shown[i].id] ?? 0,
                          favorite: _favorites.contains(shown[i].id),
                          onTap: () {
                            _addToCart(shown[i]);
                            _searchFocus.requestFocus();
                          },
                          onSecondaryTap: () => _toggleFavorite(shown[i]),
                          canPin: widget.user.isAdmin,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        // ================= Right: ticket =================
        Container(
          width: 430,
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
                child: Row(
                  children: [
                    const Icon(
                      Icons.receipt_outlined,
                      size: 18,
                      color: T.mintDeep,
                    ),
                    const SizedBox(width: 8),
                    const Text('Ticket en cours', style: T.h2),
                    const SizedBox(width: 8),
                    if (_cart.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: T.mintTint,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$_itemCount article${_itemCount > 1 ? 's' : ''}',
                          style: T.monoSmall.copyWith(
                            color: T.mintDark,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const Spacer(),
                    if (_cart.isNotEmpty)
                      TextButton.icon(
                        onPressed: _clearTicket,
                        style: TextButton.styleFrom(
                          foregroundColor: T.dangerDark,
                          textStyle: const TextStyle(
                            fontFamily: T.sans,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Vider'),
                      ),
                  ],
                ),
              ),
              // Client selector
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: InkWell(
                  onTap: _pickClient,
                  mouseCursor: SystemMouseCursors.click,
                  borderRadius: BorderRadius.circular(T.rInner),
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _client == null ? T.bg : T.mintTint,
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(
                        color: _client == null ? T.border : T.mintDeep,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 18,
                          color: _client == null ? T.faint : T.mintDark,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _client?.name ?? 'Client de passage',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: T.sans,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: _client == null ? T.faint : T.mintDark,
                            ),
                          ),
                        ),
                        if (_client != null && _priceLevel == 'wholesale') ...[
                          const MintChip(
                            'demi-gros',
                            color: T.warnTint,
                            fg: T.warnDark,
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (_client != null)
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _client = null;
                              _clientChanged();
                              if (_paymentMethod == 'credit' ||
                                  _paymentMethod == 'loyalty') {
                                _paymentMethod = _firstMethod;
                              }
                            }),
                            style: TextButton.styleFrom(
                              foregroundColor: T.mintDark,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              textStyle: const TextStyle(
                                fontFamily: T.sans,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            icon: const Icon(Icons.close, size: 16),
                            label: const Text('Retirer'),
                          )
                        else
                          Text(
                            'Choisir un client (F6)',
                            style: T.small.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: T.mintDark,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Groupe du client (tarif + remise) et points fidélité.
              if (_client != null &&
                  (_clientInfo.groupName != null ||
                      (_f.loyaltyEnabled && _clientInfo.loyaltyEnabled)))
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_clientInfo.groupName != null)
                        MintChip(
                          _clientInfo.groupDiscountPct > 0
                              ? 'Groupe ${_clientInfo.groupName} · remise ${_clientInfo.groupDiscountPct ~/ 100} %'
                              : 'Groupe ${_clientInfo.groupName}',
                          color: T.mintTint,
                          fg: T.mintDark,
                        ),
                      if (_f.loyaltyEnabled && _clientInfo.loyaltyEnabled)
                        MintChip(
                          '${_clientInfo.points} points · ${fmtDA(_clientInfo.pointsValue)}',
                          color: T.bg,
                          fg: T.ink,
                        ),
                      if (_pointsUse != null)
                        MintChip(
                          '${_pointsUse!.points} points utilisés',
                          color: T.warnTint,
                          fg: T.warnDark,
                        ),
                    ],
                  ),
                ),
              const Divider(),
              // Lines
              Expanded(
                child: _cart.isEmpty
                    ? (_lastChange != null
                          ? _RenduPanel(change: _lastChange!)
                          : EmptyState(
                              icon: Icons.shopping_basket_outlined,
                              text:
                                  'Ticket vide.\nScannez un produit pour commencer.',
                              actions: [
                                if (_parkedCount > 0)
                                  (
                                    'Tickets en attente ($_parkedCount)',
                                    _showParked,
                                  ),
                              ],
                            ))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _cart.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) => _CartRow(
                          api: widget.api,
                          line: _cart[i],
                          priceLevel: _priceLevel,
                          onDelta: _changeQty,
                          onEditQty: () => _editQty(_cart[i]),
                          onRemove: () => _removeLine(_cart[i]),
                        ),
                      ),
              ),
              // Totals + payment
              Container(
                decoration: const BoxDecoration(
                  color: T.bg,
                  border: BorderDirectional(top: BorderSide(color: T.border)),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TotalRow('Sous-total HT', _totalHT),
                    _TotalRow('TVA', _totalVAT),
                    if (_pointsValue > 0)
                      _TotalRow(
                        'Points fidélité (${_pointsUse!.points} pts)',
                        -_pointsValue,
                      ),
                    if (_rounding != 0) _TotalRow('Arrondi', _rounding),
                    if (_timbre > 0) _TotalRow('Timbre fiscal', _timbre),
                    const SizedBox(height: 6),
                    const Divider(),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text(
                          'Total à payer',
                          style: TextStyle(
                            fontFamily: T.sans,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: T.ink,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FittedBox(
                            alignment: AlignmentDirectional.centerEnd,
                            fit: BoxFit.scaleDown,
                            child: Text(
                              fmtDA(_totalTTC),
                              style: const TextStyle(
                                fontFamily: T.sans,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: T.ink,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_canDiscount && _cart.isNotEmpty)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: _ticketDiscount,
                          style: TextButton.styleFrom(
                            foregroundColor: T.mintDark,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            textStyle: const TextStyle(
                              fontFamily: T.sans,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          icon: const Icon(Icons.percent_rounded, size: 17),
                          label: const Text('Remise sur tout le ticket'),
                        ),
                      ),
                    const SizedBox(height: 10),
                    const Text('Paiement', style: T.label),
                    const SizedBox(height: 6),
                    // Rows of 3 (only the tiles the shop offers, Paramètres ›
                    // Caisse): each tile has room for its icon AND word.
                    for (final (i, row) in _payRows().indexed) ...[
                      if (i > 0) const SizedBox(height: 6),
                      Row(
                        children: [
                          for (final (j, (id, label, icon)) in row.indexed) ...[
                            if (j > 0) const SizedBox(width: 6),
                            _PayChoice(
                              label: id == 'loyalty' && _pointsUse != null
                                  ? 'Rendre les points'
                                  : label,
                              icon: icon,
                              selected: id == 'loyalty'
                                  ? _pointsUse != null
                                  : _paymentMethod == id,
                              onTap: () {
                                // Points pay part of the ticket; the rest
                                // is paid with the selected method.
                                if (id == 'loyalty') {
                                  _usePoints();
                                  return;
                                }
                                setState(() => _paymentMethod = id);
                                if (id == 'credit' && _client == null) {
                                  _pickClient();
                                }
                              },
                            ),
                          ],
                          // Keep tiles the same width on a short last row.
                          for (var k = row.length; k < 3; k++) ...[
                            const SizedBox(width: 6),
                            const Expanded(child: SizedBox()),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (offeredMixedMethods.length >= 2) ...[
                          SizedBox(
                            height: 58,
                            child: Tooltip(
                              message:
                                  'Payer avec plusieurs moyens (ex. espèces + CIB) — F8',
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  foregroundColor: T.ink,
                                  side: const BorderSide(color: T.border3),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  textStyle: const TextStyle(
                                    fontFamily: T.sans,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                onPressed: _cart.isEmpty || _checkingOut
                                    ? null
                                    : () => _startCheckout(mixed: true),
                                icon: const Icon(
                                  Icons.call_split_rounded,
                                  size: 20,
                                ),
                                label: const Text('Mixte (F8)'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(child: _payButton()),
                      ],
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

  /// The offered payment tiles, 3 per row.
  List<List<(String, String, IconData)>> _payRows() {
    final all = _offeredMethods;
    return [
      for (var i = 0; i < all.length; i += 3)
        all.sublist(i, i + 3 > all.length ? all.length : i + 3),
    ];
  }

  Widget _payButton() {
    return Tooltip(
      message: 'Encaisser (F9)',
      child: SizedBox(
        height: 58,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: T.mint,
            disabledBackgroundColor: T.border2,
            foregroundColor: T.ink,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _cart.isEmpty || _checkingOut ? null : _startCheckout,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _checkingOut ? 'Encaissement…' : 'Encaisser (F9)',
                style: const TextStyle(
                  fontFamily: T.sans,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (!_checkingOut && _cart.isNotEmpty) ...[
                const SizedBox(width: 10),
                Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: T.ink,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    fmtDA(_totalTTC),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: T.mono,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// « Rendu : X DA », large, after a cash sale — stays until the next scan.
class _RenduPanel extends StatelessWidget {
  const _RenduPanel({required this.change});
  final int change;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 28,
            color: T.mintDeep,
          ),
          const SizedBox(height: 8),
          const Text('Monnaie à rendre', style: T.h2),
          const SizedBox(height: 4),
          Text(
            fmtDA(change),
            style: TextStyle(
              fontFamily: T.sans,
              fontSize: 40,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: change > 0 ? T.mintDark : T.faint,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Scannez le produit suivant pour un nouveau ticket.',
            style: T.small,
          ),
        ],
      ),
    );
  }
}

// ================= Widgets =================

class _ProductTile extends StatefulWidget {
  const _ProductTile({
    required this.api,
    required this.product,
    required this.stockMilli,
    required this.onTap,
    this.favorite = false,
    this.onSecondaryTap,
    this.canPin = false,
  });
  final ApiClient api;
  final Product product;
  final int stockMilli;
  final VoidCallback onTap;
  final bool favorite;
  final VoidCallback?
  onSecondaryTap; // pin / unpin (also the visible pin button)
  final bool canPin;

  @override
  State<_ProductTile> createState() => _ProductTileState();
}

class _ProductTileState extends State<_ProductTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    // A service is never « en rupture »: it does not live in stock.
    final out = widget.stockMilli <= 0 && !p.isService;
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
              width: _hover ? 1.4 : 1,
            ),
            boxShadow: _hover
                ? const [
                    BoxShadow(
                      color: Color(0x1400CC99),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProductThumb(api: widget.api, product: p, size: 38),
                  if (widget.canPin)
                    // Visible pin button: no right-click needed.
                    IconButton(
                      tooltip: widget.favorite
                          ? 'Retirer des favoris'
                          : 'Ajouter aux favoris (affiché en premier)',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: widget.onSecondaryTap,
                      icon: Icon(
                        widget.favorite
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        color: widget.favorite ? T.warn : T.ghost,
                      ),
                    )
                  else if (widget.favorite) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.push_pin_rounded, size: 16, color: T.warn),
                  ],
                  const Spacer(),
                  if (p.promoActive) ...[
                    const MintChip('promo', color: T.warnTint, fg: T.warnDark),
                    const SizedBox(width: 4),
                  ],
                  if (out)
                    const MintChip(
                      'rupture',
                      color: T.dangerTint,
                      fg: T.dangerDark,
                    )
                  else if (!p.isService)
                    Flexible(
                      child: Text(
                        'Stock ${fmtQty(widget.stockMilli)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.monoSmall.copyWith(fontSize: 13),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                p.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: T.sans,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: T.ink,
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      fmtDA(p.effectivePriceTTC),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.monoBody.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.promoActive ? T.warnDark : T.mintDark,
                      ),
                    ),
                  ),
                  if (p.promoActive) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        fmtDA(p.priceRetail),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.monoSmall.copyWith(
                          fontSize: 13,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartRow extends StatefulWidget {
  const _CartRow({
    required this.api,
    required this.line,
    required this.priceLevel,
    required this.onDelta,
    required this.onEditQty,
    required this.onRemove,
  });
  final ApiClient api;
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
    final weighed = line.product.isWeighable && Features.instance.weighed;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? T.bg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            ProductThumb(api: widget.api, product: line.product, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: T.sans,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: T.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtDA(line.unitTTC(widget.priceLevel))}'
                    '${weighed ? '/kg' : ''}'
                    ' × ${fmtQty(line.qtyMilli)}'
                    '${weighed ? ' kg' : ''}'
                    '${line.discountPct > 0 ? '  · -${line.discountPct ~/ 100}%' : ''}'
                    '${line.product.promoActive ? '  · promo' : ''}',
                    style: T.monoSmall.copyWith(fontSize: 14),
                  ),
                ],
              ),
            ),
            // Stepper pill
            Container(
              height: 34,
              decoration: BoxDecoration(
                color: T.bg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: T.border2),
              ),
              child: Row(
                children: [
                  _StepBtn(
                    icon: Icons.remove,
                    onTap: () => widget.onDelta(line, weighed ? -100 : -1000),
                  ),
                  Tooltip(
                    message: 'Changer la quantité',
                    child: InkWell(
                      onTap: widget.onEditQty,
                      child: SizedBox(
                        width: 44,
                        child: Text(
                          fmtQty(line.qtyMilli),
                          textAlign: TextAlign.center,
                          style: T.monoBody.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _StepBtn(
                    icon: Icons.add,
                    onTap: () => widget.onDelta(line, weighed ? 100 : 1000),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: FittedBox(
                alignment: AlignmentDirectional.centerEnd,
                fit: BoxFit.scaleDown,
                child: Text(
                  fmtDA(line.lineTTC(widget.priceLevel)),
                  textAlign: TextAlign.end,
                  style: T.monoBody.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            // Always visible (not only on hover): remove this line.
            SizedBox(
              width: 32,
              child: IconButton(
                onPressed: widget.onRemove,
                tooltip: 'Retirer du ticket (Suppr)',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: _hover ? T.dangerDark : T.faint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? T.ink : T.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? T.ink : T.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: selected ? Colors.white : T.warn),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : T.muted,
                ),
              ),
            ],
          ),
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
          TextEditingController(),
      ],
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
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ];
      if (serials.isNotEmpty) out[e.key] = serials;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.rCard),
      ),
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
              Text(
                'Scannez ou saisissez le numéro de chaque appareil vendu.',
                style: T.small,
              ),
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
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Annuler',
                      style: T.small.copyWith(color: T.muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 130,
                    child: PrimaryButton(
                      label: 'Continuer',
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cash-refund return: pick the sale, tick the lines, post the avoir.
class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog({
    required this.api,
    required this.warehouseId,
    this.caisseSessionId,
    this.initialDocId,
    this.preApproved,
  });
  final ApiClient api;
  final String? preApproved; // manager code typed before opening the return
  final String? warehouseId;
  final String? caisseSessionId;
  final String? initialDocId; // « Retour » from « Derniers tickets »

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
    if (widget.initialDocId != null) _openId(widget.initialDocId!);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openId(String id) async {
    try {
      final detail = await widget.api.getDocument(id);
      if (mounted) {
        setState(() {
          _doc = detail;
          _selectedQty.clear();
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _load() async {
    try {
      final tickets = await widget.api.documents(
        type: 'SALE_TICKET',
        status: 'posted',
        limit: 30,
      );
      final invoices = await widget.api.documents(
        type: 'SALE_INVOICE',
        status: 'posted',
        limit: 10,
      );
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
          },
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
      final draft = await posWithApproval(
        context,
        widget.api,
        preApproved: widget.preApproved,
        () => widget.api.createDraft({
          'doc_type': 'SALE_CREDIT_NOTE',
          'doc_date': todayISO(),
          'warehouse_id': d.warehouseId ?? widget.warehouseId,
          'partner_id': d.partnerId,
          'payment_method': 'cash',
          'caisse_session_id': widget.caisseSessionId,
          'ref_document_id': d.id,
          'notes': 'Retour sur ${d.number ?? d.id.substring(0, 8)}',
          'lines': lines,
        }),
      );
      if (!mounted) return;
      final posted = await posWithApproval(
        context,
        widget.api,
        () => widget.api.postDocument(draft.id),
      );
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: SizedBox(
        width: 560,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Retour client', style: T.h2)),
                  if (d != null)
                    TextButton(
                      onPressed: () => setState(() => _doc = null),
                      child: Text(
                        '← Autre ticket',
                        style: T.small.copyWith(color: T.mintDark),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Fermer (Échap)',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _error!,
                    style: T.small.copyWith(color: T.dangerDark),
                  ),
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
                            (doc.number ?? '').toLowerCase().contains(
                              _search.text.trim().toLowerCase(),
                            ))
                          InkWell(
                            onTap: () => _open(doc),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              child: Row(
                                children: [
                                  Text(
                                    doc.number ?? '',
                                    style: T.monoBody.copyWith(fontSize: 13),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(doc.docDate, style: T.small),
                                  ),
                                  Text(fmtDA(doc.totalTTC), style: T.monoBody),
                                ],
                              ),
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
                          child: Row(
                            children: [
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
                                      : T.faint,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  l.description,
                                  style: T.body,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if ((_selectedQty[l.id ?? ''] ?? 0) > 0 &&
                                  l.qtyMilli > 1000) ...[
                                _StepBtn(
                                  icon: Icons.remove,
                                  onTap: () => setState(() {
                                    final k = l.id ?? '';
                                    final v = (_selectedQty[k] ?? 0) - 1000;
                                    if (v > 0) _selectedQty[k] = v;
                                  }),
                                ),
                                Text(
                                  fmtQty(_selectedQty[l.id ?? ''] ?? 0),
                                  style: T.monoBody.copyWith(fontSize: 13),
                                ),
                                _StepBtn(
                                  icon: Icons.add,
                                  onTap: () => setState(() {
                                    final k = l.id ?? '';
                                    final v = (_selectedQty[k] ?? 0) + 1000;
                                    if (v <= l.qtyMilli) {
                                      _selectedQty[k] = v;
                                    }
                                  }),
                                ),
                              ] else
                                Text(
                                  '×${fmtQty(l.qtyMilli)}',
                                  style: T.monoSmall,
                                ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 90,
                                child: Text(
                                  fmtDA(l.lineTTC),
                                  textAlign: TextAlign.end,
                                  style: T.monoBody.copyWith(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text('À rembourser (espèces)', style: T.bodyMuted),
                    ),
                    Text(
                      fmtDA(_refundEstimate),
                      style: T.monoBig.copyWith(fontSize: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                PrimaryButton(
                  label: _busy ? '…' : 'Valider le retour',
                  big: true,
                  onPressed: _busy || _selectedQty.isEmpty ? null : _refund,
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
        width: 32,
        height: 32,
        child: Icon(icon, size: 17, color: T.ink),
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
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: T.bodyMuted.copyWith(fontSize: 15)),
          ),
          Text(
            fmtDA(amount),
            style: T.monoBody.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: T.ink2,
            ),
          ),
        ],
      ),
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
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? T.mintTint : T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(
              color: selected ? T.mintDeep : T.border3,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: selected ? T.mintDark : T.muted),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: T.sans,
                    fontSize: 14,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: selected ? T.mintDark : T.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= Caisse session dialogs =================

class _OpenCaisseDialog extends StatefulWidget {
  const _OpenCaisseDialog({required this.api, this.initialFloat = 0});
  final ApiClient api;
  final int initialFloat; // fond de caisse proposé (Paramètres › Caisse)

  @override
  State<_OpenCaisseDialog> createState() => _OpenCaisseDialogState();
}

class _OpenCaisseDialogState extends State<_OpenCaisseDialog> {
  late final _ctrl =
      TextEditingController(
          text: widget.initialFloat > 0 ? editDA(widget.initialFloat) : '',
        )
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialFloat > 0
              ? editDA(widget.initialFloat).length
              : 0,
        );
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Ouvrir la caisse', style: T.h2),
              const SizedBox(height: 14),
              const Text('Fond de caisse (DA)', style: T.label),
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
                    hintStyle: T.monoBig.copyWith(fontSize: 22, color: T.ghost),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.initialFloat > 0
                    ? 'L’argent déjà dans le tiroir avant la première vente. '
                          'Montant proposé par le magasin : corrigez-le si besoin.'
                    : 'L’argent déjà dans le tiroir avant la première vente.',
                style: T.small,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                FieldError(_error!),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        'Annuler',
                        style: T.body.copyWith(color: T.muted),
                      ),
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// X report (closing=false) or Z closure flow (closing=true).
class _ReportDialog extends StatefulWidget {
  const _ReportDialog({
    required this.api,
    required this.closing,
    this.showTotals = true,
  });
  final ApiClient api;
  final bool closing;
  // Right `view_today`: the day's turnover (tickets · total) is shown.
  final bool showTotals;

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
      // Right `close_till` checked by the server: else the manager's code.
      final (session, report) = await posWithApproval(
        context,
        widget.api,
        () => widget.api.caisseReport(),
      );
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
      final (session, report) = await posWithApproval(
        context,
        widget.api,
        () => widget.api.caisseClose(
          counted,
          _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      // Z summary
      showDialog<void>(
        context: context,
        builder: (_) => _ZSummaryDialog(
          session: session,
          report: report,
          showTotals: widget.showTotals,
        ),
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
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: T.bodyMuted.copyWith(fontSize: 13.5)),
            ),
            Text(
              fmtDA(amount),
              style: T.monoBody.copyWith(
                color: color ?? T.ink,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
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
                    Row(
                      children: [
                        Expanded(
                          child: MicroLabel(
                            widget.closing
                                ? 'Clôture de caisse (Z)'
                                : 'État de caisse (X)',
                          ),
                        ),
                        if (_session != null)
                          Text(
                            'depuis ${_session!.openedAt.length >= 16 ? _session!.openedAt.substring(11, 16) : ''}',
                            style: T.monoSmall,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _row('Fond de caisse', r.openingCash),
                    _row('Ventes espèces', r.cashSales),
                    if (r.cardSales > 0) _row('Ventes carte', r.cardSales),
                    if (r.creditSales > 0)
                      _row('Ventes à crédit', r.creditSales, color: T.warnDark),
                    if (r.otherSales > 0)
                      _row('Chèques, cartes cadeaux…', r.otherSales),
                    if (r.cashIn > 0) _row('Encaissements espèces', r.cashIn),
                    if (r.cashOut > 0)
                      _row(
                        'Paiements sortis en espèces',
                        -r.cashOut,
                        color: T.dangerDark,
                      ),
                    if (r.cashRefunds > 0)
                      _row(
                        'Retours remboursés',
                        -r.cashRefunds,
                        color: T.dangerDark,
                      ),
                    const Divider(height: 16),
                    _row(
                      'Espèces attendues en caisse',
                      r.expectedCash,
                      bold: true,
                    ),
                    if (widget.showTotals)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: MicroLabel(
                                '${r.ticketCount} tickets · ${fmtDA(r.totalSales)}',
                              ),
                            ),
                          ],
                        ),
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
                            contentPadding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      if (parseDA(_counted.text) != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: _ecart == 0
                                ? T.mintTint
                                : _ecart > 0
                                ? T.warnTint
                                : T.dangerTint,
                            borderRadius: BorderRadius.circular(T.rInner),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _ecart == 0
                                      ? 'Caisse juste ✓'
                                      : _ecart > 0
                                      ? 'Excédent'
                                      : 'Manquant',
                                  style: T.bodyMuted.copyWith(fontSize: 13.5),
                                ),
                              ),
                              Text(
                                fmtDA(_ecart),
                                style: T.monoBody.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: _ecart == 0
                                      ? T.mintDark
                                      : _ecart > 0
                                      ? T.warnDark
                                      : T.dangerDark,
                                ),
                              ),
                            ],
                          ),
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
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: T.small.copyWith(color: T.dangerDark),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(
                              'Fermer',
                              style: T.small.copyWith(color: T.muted),
                            ),
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
                              onPressed: _busy || parseDA(_counted.text) == null
                                  ? null
                                  : _close,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ZSummaryDialog extends StatelessWidget {
  const _ZSummaryDialog({
    required this.session,
    required this.report,
    this.showTotals = true,
  });
  final CaisseSession session;
  final CaisseReport report;
  final bool showTotals;

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
                  color: T.mintTint2,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  size: 26,
                  color: T.mintDark,
                ),
              ),
              const SizedBox(height: 12),
              const Text('Caisse clôturée', style: T.h2),
              const SizedBox(height: 4),
              Text(
                showTotals
                    ? '${report.ticketCount} tickets · ${fmtDA(report.totalSales)}'
                    : '${report.ticketCount} tickets',
                style: T.bodyMuted,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Attendu', style: T.small)),
                        Text(
                          fmtDA(session.expectedCash ?? 0),
                          style: T.monoBody,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(child: Text('Compté', style: T.small)),
                        Text(
                          fmtDA(session.countedCash ?? 0),
                          style: T.monoBody,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(child: Text('Écart', style: T.small)),
                        Text(
                          fmtDA(ecart),
                          style: T.monoBody.copyWith(
                            fontWeight: FontWeight.w700,
                            color: ecart == 0
                                ? T.mintDark
                                : ecart > 0
                                ? T.warnDark
                                : T.dangerDark,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: const BoxDecoration(
                        color: T.mintTint2,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.card_giftcard,
                        size: 26,
                        color: T.mintDark,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      fmtDA(card.initialAmount),
                      style: const TextStyle(
                        fontFamily: T.sans,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: T.ink,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: T.bg,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border),
                      ),
                      child: Text(
                        card.code,
                        style: const TextStyle(
                          fontFamily: T.mono,
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: T.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Encaissez ${fmtDA(card.initialAmount)} et remettez ce '
                      'code au client. Notez-le : il ne sera plus affiché.',
                      textAlign: TextAlign.center,
                      style: T.small,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: 140,
                      child: PrimaryButton(
                        label: 'Terminer',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Vendre une carte cadeau', style: T.h2),
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
                          hintStyle: T.monoBig.copyWith(
                            fontSize: 22,
                            color: T.ghost,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: T.small.copyWith(color: T.dangerDark),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(
                              'Annuler',
                              style: T.small.copyWith(color: T.muted),
                            ),
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
                      ],
                    ),
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
        _error =
            'Carte ${card.status == 'depleted' ? 'épuisée' : card.status}.';
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
      final (useId, _) = await widget.api.redeemGiftCard(
        card.code,
        widget.total,
      );
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
              Row(
                children: [
                  const Icon(Icons.card_giftcard, size: 18, color: T.mintDeep),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Payer par carte cadeau', style: T.h2),
                  ),
                  Text(
                    fmtDA(widget.total),
                    style: T.monoBody.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('Code de la carte', style: T.label),
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
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: T.mintTint,
                    borderRadius: BorderRadius.circular(T.rInner),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Solde disponible',
                          style: T.bodyMuted.copyWith(fontSize: 13.5),
                        ),
                      ),
                      Text(
                        fmtDA(card.balance),
                        style: T.monoBody.copyWith(
                          color: T.mintDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: T.small.copyWith(color: T.dangerDark)),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        'Annuler',
                        style: T.small.copyWith(color: T.muted),
                      ),
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
                ],
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
  const _CashDialog({required this.total, this.rounding = 0});
  final int total;
  final int rounding; // « Arrondi » already inside total (Paramètres › Caisse)

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.payments_outlined,
                    size: 18,
                    color: T.mintDeep,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Paiement en espèces', style: T.h2),
                  ),
                  Text(
                    fmtDA(widget.total),
                    style: T.monoBody.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              if (widget.rounding != 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Arrondi des espèces : ${widget.rounding > 0 ? '+' : ''}${fmtDA(widget.rounding)} (inclus)',
                  style: T.small,
                ),
              ],
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
                    width: _enough ? 1.4 : 1,
                  ),
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
                    hintStyle: T.monoBig.copyWith(fontSize: 24, color: T.ghost),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _suggestions)
                    InkWell(
                      onTap: () {
                        _ctrl.text = editDA(s);
                        setState(() {});
                      },
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: T.bg,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: T.border),
                        ),
                        child: Text(
                          fmtDA(s),
                          style: T.monoSmall.copyWith(
                            color: T.ink,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _change > 0 ? T.mintTint : T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'À rendre',
                        style: T.bodyMuted.copyWith(fontSize: 13.5),
                      ),
                    ),
                    Text(
                      fmtDA(_change),
                      style: TextStyle(
                        fontFamily: T.mono,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: _change > 0 ? T.mintDark : T.faint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        'Annuler',
                        style: T.small.copyWith(color: T.muted),
                      ),
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
