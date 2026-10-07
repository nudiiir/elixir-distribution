import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/cloud.dart';
import '../api/models.dart';
import '../theme/tokens.dart';

class _Msg {
  _Msg.user(this.text)
      : isUser = true,
        rows = const [];
  _Msg.bot(this.text, {this.rows = const []}) : isUser = false;
  _Msg._(this.isUser, this.text, this.rows);

  final bool isUser;
  final String text;
  final List<(String, String)> rows;

  Map<String, dynamic> toJson() => {
        'u': isUser,
        't': text,
        'r': [for (final (l, v) in rows) [l, v]],
      };

  static _Msg fromJson(Map<String, dynamic> j) => _Msg._(
        j['u'] == true,
        (j['t'] as String?) ?? '',
        [
          for (final e in (j['r'] as List? ?? const []))
            ((e as List)[0].toString(), e[1].toString())
        ],
      );
}

/// L'assistant Elixir — styled after the phone app's Elixir AI screen:
/// white→#EFFAF5 gradient, blurred aurora at the bottom, centered wordmark,
/// pill composer with the mint up-arrow disc inside.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  bool _thinking = false;

  /// When the shop is connected to the cloud we use stock-llm, which reasons
  /// over the same data through the relay. Otherwise the built-in rule-based
  /// assistant answers locally — the shop keeps working without internet.
  CloudConfig? _cloud;
  String _runningTool = '';

  @override
  void initState() {
    super.initState();
    _loadCloud();
    _loadHistory();
  }

  // ---- History: the conversation survives an app restart. ----

  static File _historyFile() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\ElixirGestion\\assistant_history.json');
  }

  Future<void> _loadHistory() async {
    try {
      final f = _historyFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(list.map((e) => _Msg.fromJson(e as Map<String, dynamic>)));
      });
      _scrollDown();
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      final f = _historyFile();
      await f.parent.create(recursive: true);
      // Keep the file bounded: the last 200 messages are plenty of context.
      final tail = _messages.length > 200
          ? _messages.sublist(_messages.length - 200)
          : _messages;
      await f.writeAsString(jsonEncode([for (final m in tail) m.toJson()]));
    } catch (_) {}
  }

  void _newConversation() {
    setState(() => _messages.clear());
    _saveHistory();
    _focus.requestFocus();
  }

  Future<void> _loadCloud() async {
    try {
      final c = await widget.api.cloudStatus();
      if (mounted) setState(() => _cloud = c);
    } catch (_) {}
  }

  bool get _useCloud => _cloud?.llmReady == true && widget.api.token != null;

  static const _suggestions = [
    'Produits en rupture',
    "Ventes d'aujourd'hui",
    'Valeur du stock',
    'Crédits clients',
    'Stock de Coca-Cola',
    'Comment créer une facture ?',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final q = text.trim();
    if (q.isEmpty || _thinking) return;
    _ctrl.clear();
    setState(() {
      _messages.add(_Msg.user(q));
      _thinking = true;
      _runningTool = '';
    });
    _scrollDown();

    if (_useCloud) {
      await _sendCloud(q);
      return;
    }

    try {
      final answer = await _Brain(widget.api).answer(q);
      if (mounted) setState(() => _messages.add(answer));
    } catch (e) {
      if (mounted) {
        setState(() => _messages.add(_Msg.bot(
            'Je n’arrive pas à joindre le serveur. Vérifiez la connexion et réessayez.')));
      }
    } finally {
      if (mounted) setState(() => _thinking = false);
      _saveHistory();
      _scrollDown();
      _focus.requestFocus();
    }
  }

  /// Streams an answer from stock-llm, falling back to the local assistant if
  /// the cloud is unreachable — a shop mid-sale should never hit a dead end.
  Future<void> _sendCloud(String q) async {
    final client = CloudClient(config: _cloud!, token: widget.api.token!);
    final history = [
      for (final m in _messages.where((m) => m.text.isNotEmpty))
        (role: m.isUser ? 'user' : 'model', content: m.text)
    ];
    var streaming = false;
    try {
      await for (final (kind, value) in client.chat(history)) {
        if (!mounted) return;
        if (kind == 'tool') {
          setState(() => _runningTool = value);
          continue;
        }
        setState(() {
          if (!streaming) {
            _messages.add(_Msg.bot(value));
            streaming = true;
            _thinking = false;
            _runningTool = '';
          } else {
            final last = _messages.removeLast();
            _messages.add(_Msg.bot(last.text + value));
          }
        });
        _scrollDown();
      }
    } catch (e) {
      if (!mounted) return;
      if (!streaming) {
        // Cloud unavailable — answer locally rather than failing.
        try {
          final answer = await _Brain(widget.api).answer(q);
          if (mounted) setState(() => _messages.add(answer));
        } catch (_) {
          if (mounted) {
            setState(() => _messages.add(_Msg.bot(
                'Assistant indisponible : $e\nVérifiez la connexion internet du magasin.')));
          }
        }
      }
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _thinking = false;
          _runningTool = '';
        });
      }
      _saveHistory();
      _scrollDown();
      _focus.requestFocus();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent + 80,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final empty = _messages.isEmpty;
    return Stack(children: [
      // Screen gradient white → #EFFAF5 (stops 0/.54/.78/1).
      Positioned.fill(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.54, 0.78, 1],
              colors: [
                Colors.white,
                Colors.white,
                Color(0xFFF4FCF8),
                Color(0xFFEFFAF5),
              ],
            ),
          ),
        ),
      ),
      // Blurred aurora in the bottom half — mint / blue / pink.
      Positioned(
        left: 0,
        right: 0,
        bottom: -60,
        height: 300,
        child: IgnorePointer(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: Row(children: [
              Expanded(
                  child: Container(
                      margin: const EdgeInsets.all(30),
                      decoration: BoxDecoration(
                          color: const Color(0x3D00CC99),
                          borderRadius: BorderRadius.circular(200)))),
              Expanded(
                  child: Container(
                      margin: const EdgeInsets.all(50),
                      decoration: BoxDecoration(
                          color: const Color(0x2E4A63B8),
                          borderRadius: BorderRadius.circular(200)))),
              Expanded(
                  child: Container(
                      margin: const EdgeInsets.all(30),
                      decoration: BoxDecoration(
                          color: const Color(0x3DF9D3DC),
                          borderRadius: BorderRadius.circular(200)))),
            ]),
          ),
        ),
      ),
      // Content
      Column(children: [
        Expanded(
          child: empty
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: T.ink,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          alignment: Alignment.center,
                          child: const Text('E',
                              style: TextStyle(
                                  fontFamily: T.sans,
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                        ),
                        const SizedBox(height: 20),
                        const Text('Elixir AI',
                            style: TextStyle(
                                fontFamily: T.sans,
                                fontSize: 29,
                                height: 1.22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.6,
                                color: T.ink)),
                        const SizedBox(height: 8),
                        Text(
                            'Posez une question sur votre stock, vos ventes\nou le fonctionnement du logiciel.',
                            textAlign: TextAlign.center,
                            style: T.bodyMuted.copyWith(fontSize: 13.5)),
                        const SizedBox(height: 24),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final s in _suggestions)
                              InkWell(
                                onTap: () => _send(s),
                                borderRadius: BorderRadius.circular(999),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius:
                                        BorderRadius.circular(999),
                                    border: Border.all(color: T.border),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Color(0x0A141414),
                                          blurRadius: 6,
                                          offset: Offset(0, 2)),
                                    ],
                                  ),
                                  child: Text(s,
                                      style: const TextStyle(
                                          fontFamily: T.sans,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                          color: T.muted)),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
                  itemCount: _messages.length + (_thinking ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _messages.length) {
                      return _TypingBubble(tool: _runningTool);
                    }
                    return _Bubble(msg: _messages[i]);
                  },
                ),
        ),
        // Composer
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Container(
                height: 54,
                padding: const EdgeInsetsDirectional.only(start: 20, end: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: T.border),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x2200CC99),
                        blurRadius: 22,
                        offset: Offset(0, 6)),
                  ],
                ),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      autofocus: true,
                      onSubmitted: _send,
                      style: T.body.copyWith(fontSize: 14),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Écrivez votre question…',
                        hintStyle: T.bodyMuted
                            .copyWith(color: T.ghost, fontSize: 14),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => _send(_ctrl.text),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                          color: T.mint, shape: BoxShape.circle),
                      child: const Icon(Icons.arrow_upward_rounded,
                          size: 20, color: T.ink),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        if (!empty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
                "L'assistant peut se tromper — vérifiez les informations importantes.",
                style: T.small.copyWith(fontSize: 10.5, color: T.ghost)),
          )
        else
          const SizedBox(height: 10),
      ]),
      // New-conversation chip, floating over the transcript.
      if (!empty)
        PositionedDirectional(
          top: 10,
          end: 16,
          child: InkWell(
            onTap: _thinking ? null : _newConversation,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: T.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.add_comment_outlined,
                    size: 14, color: T.mintDark),
                const SizedBox(width: 6),
                Text('Nouvelle conversation',
                    style: T.small.copyWith(
                        fontSize: 11,
                        color: T.mintDark,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Align(
          alignment: msg.isUser
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
            constraints: const BoxConstraints(maxWidth: 460),
            decoration: BoxDecoration(
              color: msg.isUser ? T.ink : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(msg.isUser ? 16 : 5),
                bottomRight: Radius.circular(msg.isUser ? 5 : 16),
              ),
              border: msg.isUser ? null : Border.all(color: T.border),
              boxShadow: msg.isUser
                  ? null
                  : const [
                      BoxShadow(
                          color: Color(0x08141414),
                          blurRadius: 6,
                          offset: Offset(0, 2)),
                    ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(msg.text,
                    style: TextStyle(
                      fontFamily: T.sans,
                      fontSize: 13.5,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
                      color: msg.isUser ? Colors.white : T.ink,
                    )),
                if (msg.rows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: T.bg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (label, value) in msg.rows)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 2.5),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 260),
                                  child: Text(label,
                                      style: T.small.copyWith(
                                          fontSize: 12, color: T.muted),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                const SizedBox(width: 14),
                                const Spacer(),
                                Text(value,
                                    style: T.monoBody.copyWith(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ],
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
      ),
    );
  }
}

const _toolLabels = {
  'search_products': 'Recherche des produits…',
  'get_stock_summary': 'Analyse du stock…',
  'get_low_stock': 'Vérification des ruptures…',
  'get_stock_movements': 'Lecture des mouvements…',
  'get_sales_summary': 'Calcul des ventes…',
  'list_documents': 'Lecture des documents…',
  'get_document_detail': 'Ouverture du document…',
  'get_customer_credits': 'Lecture des crédits clients…',
  'search_partners': 'Recherche du partenaire…',
  'get_caisse_state': 'État de la caisse…',
};

class _TypingBubble extends StatefulWidget {
  const _TypingBubble({this.tool = ''});
  final String tool;

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: T.border),
            ),
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: T.mint.withValues(
                            alpha: 0.3 +
                                0.7 *
                                    (1 -
                                            ((_anim.value + i / 3) % 1 - 0.5)
                                                    .abs() *
                                                2)
                                        .clamp(0, 1)),
                        shape: BoxShape.circle,
                      ),
                    ),
                  if (widget.tool.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(_toolLabels[widget.tool] ?? 'Consultation…',
                        style: T.small.copyWith(fontSize: 11.5)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ===================== The brain =====================

class _Brain {
  _Brain(this.api);
  final ApiClient api;

  static String _norm(String s) {
    const from = 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ';
    const to = 'aaaeeeeiioouuucAAAEEEEIIOOUUUC';
    var out = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      out = out.replaceAll(from[i], to[i].toLowerCase());
    }
    return out;
  }

  static const _stop = {
    'le', 'la', 'les', 'de', 'du', 'des', 'un', 'une', 'en', 'a', 'au',
    'aux', 'et', 'ou', 'est', 'il', 'y', 'combien', 'reste', 'stock',
    'quantite', 'prix', 'me', 'moi', 'donne', 'affiche', 'montre', 'quel',
    'quelle', 'que', 'qui', 'pour', 'dans', 'ce', 'cette', 'mon', 'ma',
    'mes', 'je', 'j', 'ai', 'on', 'nous', 'vous', 'svp', 'stp', '?',
    'credit', 'solde', 'doit', 'client'
  };

  static String _rest(String norm) {
    final words = norm
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_stop.contains(w))
        .toList();
    return words.join(' ');
  }

  Future<_Msg> answer(String question) async {
    final q = _norm(question);

    if (RegExp(r'\b(salam|bonjour|salut|bonsoir|hello|cc)\b').hasMatch(q)) {
      return _Msg.bot(
          'Bonjour ! 👋 Je peux vous renseigner sur votre stock, vos ventes, '
          'les crédits clients, et répondre aux questions sur le logiciel.\n'
          'Essayez : « Stock de Coca-Cola », « Ventes d’aujourd’hui », '
          '« Produits en rupture ».');
    }

    if (q.contains('rupture') || q.contains('faible') || q.contains('alerte')) {
      return _lowStock();
    }
    if (q.contains('valeur') && q.contains('stock')) {
      return _stockValue();
    }
    if (q.contains('vente') ||
        q.contains('chiffre') ||
        q.contains('recette') ||
        q.contains("aujourd")) {
      return _sales(month: q.contains('mois'));
    }
    if (q.contains('credit') || q.contains('solde') || q.contains('doit')) {
      final rest = _rest(q);
      return rest.isEmpty ? _topDebtors() : _partnerBalance(rest);
    }
    if (q.contains('comment') || q.contains('aide') || q.contains('help')) {
      return _howTo(q);
    }
    if (RegExp(r'^\d{6,}$').hasMatch(q.trim())) {
      return _productInfo(q.trim());
    }
    if (q.contains('stock') ||
        q.contains('quantite') ||
        q.contains('combien') ||
        q.contains('reste') ||
        q.contains('prix')) {
      final rest = _rest(q);
      if (rest.isNotEmpty) return _productInfo(rest);
    }

    // Last resort: try a product search on the meaningful words.
    final rest = _rest(q);
    if (rest.isNotEmpty) {
      final products = await api.products(q: rest, limit: 3);
      if (products.isNotEmpty) return _productInfo(rest);
    }
    return _Msg.bot(
        'Je n’ai pas compris. 🤔 Je sais répondre à :\n'
        '• « Stock de <produit> » ou un code-barres\n'
        '• « Ventes d’aujourd’hui » / « ventes du mois »\n'
        '• « Produits en rupture », « Valeur du stock »\n'
        '• « Crédit de <client> », « Crédits clients »\n'
        '• « Comment créer une facture / un produit ? »');
  }

  Future<_Msg> _productInfo(String query) async {
    final products = await api.products(q: query, limit: 3);
    if (products.isEmpty) {
      return _Msg.bot('Aucun produit trouvé pour « $query ».');
    }
    final levels = await api.stockLevels();
    final qtyBy = <String, int>{};
    for (final l in levels) {
      qtyBy[l.productId] = (qtyBy[l.productId] ?? 0) + l.qtyMilli;
    }
    final p = products.first;
    final qty = qtyBy[p.id] ?? 0;
    final rows = <(String, String)>[
      ('En stock', fmtQty(qty)),
      ('Prix de vente TTC', fmtDA(p.priceRetail)),
      ("Prix d'achat HT", fmtDA(p.purchasePrice)),
      if (p.barcode != null) ('Code-barres', p.barcode!),
    ];
    var text = qty <= 0
        ? '⚠️ « ${p.name} » est en rupture de stock.'
        : 'Voici la situation de « ${p.name} » :';
    if (products.length > 1) {
      text +=
          '\n(${products.length - 1} autre(s) produit(s) correspondent aussi.)';
    }
    return _Msg.bot(text, rows: rows);
  }

  Future<_Msg> _lowStock() async {
    final results = await Future.wait([
      api.stockLevels(),
      api.products(limit: 500),
    ]);
    final levels = results[0] as List<StockLevel>;
    final minBy = {
      for (final p in results[1] as List<Product>) p.id: p.minStockMilli,
    };
    final low = levels
        .where((l) =>
            l.qtyMilli <= 0 ||
            ((minBy[l.productId] ?? 0) > 0 &&
                l.qtyMilli <= (minBy[l.productId] ?? 0)))
        .toList()
      ..sort((a, b) => a.qtyMilli.compareTo(b.qtyMilli));
    if (low.isEmpty) {
      return _Msg.bot('✅ Aucun produit en rupture ou sous le stock minimum.');
    }
    return _Msg.bot(
      '${low.length} produit(s) en alerte :',
      rows: [
        for (final l in low.take(8)) (l.productName, fmtQty(l.qtyMilli)),
        if (low.length > 8) ('…', '+${low.length - 8}'),
      ],
    );
  }

  Future<_Msg> _stockValue() async {
    final levels = await api.stockLevels();
    final total = levels.fold(0, (s, l) => s + l.valuation);
    return _Msg.bot('Votre stock actuel :', rows: [
      ('Valeur totale (CUMP)', fmtDA(total)),
      ('Références', '${levels.length}'),
      ('En rupture', '${levels.where((l) => l.qtyMilli <= 0).length}'),
    ]);
  }

  Future<_Msg> _sales({required bool month}) async {
    final now = DateTime.now();
    final from = month
        ? '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-01'
        : todayISO();
    final results = await Future.wait([
      api.documents(type: 'SALE_TICKET', status: 'posted', from: from, limit: 500),
      api.documents(type: 'SALE_INVOICE', status: 'posted', from: from, limit: 500),
    ]);
    final docs = [...results[0], ...results[1]];
    final total = docs.fold(0, (s, d) => s + d.totalTTC);
    final cash = docs
        .where((d) => d.paymentMethod == 'cash')
        .fold(0, (s, d) => s + d.totalTTC);
    final credit = docs
        .where((d) => d.paymentMethod == 'credit')
        .fold(0, (s, d) => s + d.totalTTC);
    final label = month ? 'ce mois-ci' : "aujourd'hui";
    if (docs.isEmpty) return _Msg.bot('Aucune vente $label pour le moment.');
    return _Msg.bot('Vos ventes $label :', rows: [
      ('Total TTC', fmtDA(total)),
      ('Tickets / factures', '${docs.length}'),
      if (cash > 0) ('Dont espèces', fmtDA(cash)),
      if (credit > 0) ('Dont crédit', fmtDA(credit)),
    ]);
  }

  Future<_Msg> _topDebtors() async {
    final partners = await api.partners(limit: 500);
    final debtors = partners.where((p) => p.balance > 0).toList()
      ..sort((a, b) => b.balance.compareTo(a.balance));
    if (debtors.isEmpty) {
      return _Msg.bot('✅ Aucun crédit client en cours.');
    }
    final total = debtors.fold(0, (s, p) => s + p.balance);
    return _Msg.bot(
      '${debtors.length} client(s) vous doivent ${fmtDA(total)} :',
      rows: [
        for (final p in debtors.take(6)) (p.name, fmtDA(p.balance)),
        if (debtors.length > 6) ('…', '+${debtors.length - 6}'),
      ],
    );
  }

  Future<_Msg> _partnerBalance(String name) async {
    final partners = await api.partners(q: name, limit: 5);
    if (partners.isEmpty) {
      return _Msg.bot('Aucun partenaire trouvé pour « $name ».');
    }
    final p = partners.first;
    final text = p.balance == 0
        ? '« ${p.name} » a un solde à jour.'
        : p.balance > 0
            ? '« ${p.name} » vous doit :'
            : 'Vous devez à « ${p.name} » :';
    return _Msg.bot(text, rows: [
      ('Solde', fmtDA(p.balance.abs())),
      if (p.phone != null) ('Téléphone', p.phone!),
    ]);
  }

  Future<_Msg> _howTo(String q) async {
    if (q.contains('facture')) {
      return _Msg.bot(
          'Pour créer une facture : ouvrez le module Ventes → « Nouvelle '
          'facture ». Ajoutez les produits (scanner ou recherche), choisissez '
          'le client et le mode de règlement, puis « Valider » — le numéro '
          'légal est attribué automatiquement. En espèces, le timbre fiscal '
          'est calculé tout seul.');
    }
    if (q.contains('produit')) {
      return _Msg.bot(
          'Pour ajouter un produit : module Produits → « Nouveau produit ». '
          'Renseignez la désignation, le code-barres, la TVA et les prix. '
          'Le stock entre ensuite via une réception fournisseur (module '
          'Achats).');
    }
    if (q.contains('timbre')) {
      return _Msg.bot(
          'Le timbre fiscal s’applique aux paiements en espèces : rien jusqu’à '
          '300 DA, puis 1 DA par tranche de 100 DA (1,5 DA au-delà de 30 000 DA, '
          '2 DA au-delà de 100 000 DA), minimum 5 DA, plafonné à 10 000 DA. Les '
          'paiements électroniques en sont exonérés — il est calculé '
          'automatiquement à la caisse.');
    }
    if (q.contains('credit')) {
      return _Msg.bot(
          'Pour vendre à crédit : à la Caisse, choisissez le client (« Client '
          'de passage » → sélectionnez-le), puis le mode « Crédit ». Le '
          'montant s’ajoute à son solde, visible dans Partenaires, où vous '
          'pouvez aussi encaisser un remboursement.');
    }
    return _Msg.bot(
        'Je peux vous guider sur : créer une facture, ajouter un produit, '
        'vendre à crédit, le timbre fiscal… Posez la question directement, '
        'par exemple « Comment créer une facture ? »');
  }
}
