import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/approval.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../../widgets/doc_list.dart' show DocChip;
import '../../widgets/ui.dart';
import 'order_common.dart';

/// One line being typed.
class _Line {
  _Line({required this.productId, required this.name, this.barcode, required this.qtyMilli});
  final String productId;
  final String name;
  final String? barcode;
  int qtyMilli;
  PriceQuote? quote;
  List<QuotaRow> quotas = const [];
  int? manualPrice; // HT, set by the user
  bool loading = false;
  String? error;
  late final qtyCtrl = TextEditingController(text: fmtQty(qtyMilli));
  late final priceCtrl = TextEditingController();

  /// Existing line kept as is (edit mode) — price not re-resolved.
  int? keptPrice;
  int? keptDiscount;
  int keptFree = 0;
  String keptSource = '';
  int keptVat = 0;

  int get unitPrice => manualPrice ?? keptPrice ?? quote?.unitPrice ?? 0;
  int get discountPct => manualPrice != null ? 0 : (keptDiscount ?? quote?.discountPct ?? 0);
  int get vatRate => quote?.vatRate ?? keptVat;
  int get freeMilli => keptPrice != null ? keptFree : (quote?.qtyFreeMilli ?? 0);
  String get source => manualPrice != null ? 'manual' : (keptPrice != null ? keptSource : quote?.priceSource ?? '');

  int get lineHT {
    final gross = roundDiv(unitPrice * qtyMilli, 1000);
    return roundDiv(gross * (10000 - discountPct), 10000);
  }

  int get lineTTC => lineHT + roundDiv(lineHT * vatRate, 10000);

  String? get quotaWarning {
    for (final q in quotas) {
      if (q.remainingMilli < qtyMilli) {
        final per = switch (q.period) { 'day' => 'jour', 'week' => 'semaine', _ => 'mois' };
        return 'Quota : il reste ${fmtQty(q.remainingMilli)} ce $per (maximum ${fmtQty(q.maxQtyMilli)}).';
      }
    }
    return null;
  }

  void dispose() {
    qtyCtrl.dispose();
    priceCtrl.dispose();
  }
}

/// « Nouvelle commande » (and « Modifier » of a new / validated order):
/// client with his account, fast product entry with the resolved price,
/// delivery details. A page, not a dialog: Échap = Retour.
class OrderFormPage extends StatefulWidget {
  const OrderFormPage({super.key, required this.api, required this.user, this.existing, this.initialPartner});
  final ApiClient api;
  final User user;
  final CustomerOrder? existing;
  final Partner? initialPartner;

  @override
  State<OrderFormPage> createState() => _OrderFormPageState();
}

class _OrderFormPageState extends State<OrderFormPage> {
  ApiClient get api => widget.api;
  CustomerOrder? get ex => widget.existing;

  String? _partnerId;
  String _partnerName = '';
  OrderClient? _client;
  PartnerCredit? _credit;

  final List<_Line> _lines = [];
  bool _linesDirty = false;

  final _entry = TextEditingController();
  final _entryFocus = FocusNode();
  final _entryQty = TextEditingController(text: '1');
  bool _searching = false;

  final _address = TextEditingController();
  final _commune = TextEditingController();
  final _contactName = TextEditingController();
  final _contactPhone = TextEditingController();
  final _notes = TextEditingController();
  final _internal = TextEditingController();
  final _shipping = TextEditingController();
  String? _wilaya;
  String? _requestedDate;
  int _priority = 0;
  String _source = 'phone';
  String _paymentMode = 'account';
  String? _repId;
  List<({String id, String name})> _staff = const [];

  bool _saving = false;
  final Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    final o = ex;
    if (o != null) {
      _partnerId = o.partnerId;
      _partnerName = o.partnerName;
      _address.text = o.deliveryAddress;
      _commune.text = o.commune;
      _contactName.text = o.contactName;
      _contactPhone.text = o.contactPhone;
      _notes.text = o.notes;
      _internal.text = o.internalNotes;
      _shipping.text = o.shippingFee > 0 ? editDA(o.shippingFee) : '';
      _wilaya = o.wilaya.isEmpty ? null : o.wilaya;
      _requestedDate = o.requestedDate;
      _priority = o.priority;
      _source = o.source;
      _paymentMode = o.paymentMode;
      _repId = o.repUserId;
      for (final l in o.activeLines) {
        final x = _Line(productId: l.productId, name: l.productName, barcode: l.barcode, qtyMilli: l.qtyOrderedMilli)
          ..keptPrice = l.unitPrice
          ..keptDiscount = l.discountPct
          ..keptFree = l.qtyFreeMilli
          ..keptSource = l.priceSource
          ..keptVat = l.vatRate;
        if (l.priceSource == 'manual') x.manualPrice = l.unitPrice;
        _lines.add(x);
      }
      _loadClient(o.partnerId, prefill: false);
    } else if (widget.initialPartner != null) {
      _setPartner(widget.initialPartner!.id, widget.initialPartner!.name);
    }
    api.staffList().then((s) {
      if (mounted) setState(() => _staff = s);
    });
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in [_entry, _entryQty, _address, _commune, _contactName, _contactPhone, _notes, _internal, _shipping]) {
      c.dispose();
    }
    _entryFocus.dispose();
    _qtyDebounce?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- client

  Future<void> _pickClient() async {
    if (ex != null && ex!.status != 'new') {
      showToast(context, 'Le client ne peut plus changer : la commande est validée.', kind: ToastKind.warning);
      return;
    }
    final p = await showPartnerPicker(context, api, kind: 'customer');
    if (p == null || !mounted) return;
    _setPartner(p.id, p.name);
  }

  void _setPartner(String id, String name) {
    setState(() {
      _partnerId = id;
      _partnerName = name;
      _client = null;
      _credit = null;
      _errors.remove('partner_id');
    });
    _loadClient(id, prefill: true);
    for (final l in _lines) {
      if (l.manualPrice == null) {
        l.keptPrice = null;
        _resolve(l);
      }
    }
    _entryFocus.requestFocus();
  }

  Future<void> _loadClient(String id, {required bool prefill}) async {
    try {
      final c = await api.orderClient(id);
      if (!mounted || _partnerId != id) return;
      setState(() {
        _client = c;
        if (prefill) {
          _address.text = c.address;
          _commune.text = c.commune;
          _wilaya = c.wilaya.isEmpty ? null : c.wilaya;
          _contactPhone.text = c.phone;
          _contactName.text = '';
          _repId = c.repUserId;
        }
      });
    } catch (_) {}
    try {
      final cr = await api.partnerCredit(id);
      if (mounted && _partnerId == id) setState(() => _credit = cr);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- lines

  Future<void> _resolve(_Line l) async {
    setState(() {
      l.loading = true;
      l.error = null;
    });
    try {
      final (q, quotas) = await api.resolvePrice(l.productId,
          partnerId: _partnerId, qtyMilli: l.qtyMilli, channel: _source == 'web' ? 'web' : 'desk');
      if (!mounted) return;
      setState(() {
        l.quote = q;
        l.quotas = quotas;
        l.loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        l.loading = false;
        l.error = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _addFromEntry() async {
    final text = _entry.text.trim();
    if (text.isEmpty || _searching) return;
    final qty = parseQty(_entryQty.text) ?? 1000;
    if (qty <= 0) {
      showToast(context, 'Quantité invalide.', kind: ToastKind.warning);
      return;
    }
    setState(() => _searching = true);
    List<Product> found = const [];
    try {
      found = await api.products(q: text, limit: 30);
    } catch (e) {
      if (mounted) showActionError(context, e);
    }
    if (!mounted) return;
    setState(() => _searching = false);
    Product? p;
    final exact = found.where((x) => x.barcode == text || x.barcodes.contains(text)).toList();
    if (exact.length == 1) {
      p = exact.first;
    } else if (found.length == 1) {
      p = found.first;
    } else if (found.isEmpty) {
      SystemSound.play(SystemSoundType.alert);
      showToast(context, 'Aucun produit pour « $text ».', kind: ToastKind.warning);
      return;
    } else {
      p = await showDialog<Product>(context: context, builder: (_) => _ProductChoice(items: found, query: text));
    }
    if (p == null || !mounted) return;
    _addProduct(p, qty);
    _entry.clear();
    _entryQty.text = '1';
    _entryFocus.requestFocus();
  }

  void _addProduct(Product p, int qty) {
    final existing = _lines.where((l) => l.productId == p.id).toList();
    if (existing.isNotEmpty) {
      final l = existing.first;
      l.qtyMilli += qty;
      l.qtyCtrl.text = fmtQty(l.qtyMilli);
      l.keptPrice = l.manualPrice == null ? null : l.keptPrice;
      _linesDirty = true;
      _resolve(l);
      showToast(context, '${p.name} : quantité portée à ${fmtQty(l.qtyMilli)}.', kind: ToastKind.info);
      return;
    }
    final l = _Line(productId: p.id, name: p.name, barcode: p.barcode, qtyMilli: qty);
    setState(() {
      _lines.add(l);
      _linesDirty = true;
      _errors.remove('lines');
    });
    _resolve(l);
  }

  Timer? _qtyDebounce;

  void _setQty(_Line l, String text) {
    final q = parseQty(text);
    if (q == null || q <= 0) return;
    l.qtyMilli = q;
    _linesDirty = true;
    if (l.manualPrice == null) l.keptPrice = null;
    setState(() {});
    _qtyDebounce?.cancel();
    _qtyDebounce = Timer(const Duration(milliseconds: 350), () => _resolve(l));
  }

  void _setPrice(_Line l, String text) {
    final t = text.trim();
    setState(() {
      l.manualPrice = t.isEmpty ? null : parseDA(t);
      _linesDirty = true;
    });
  }

  void _remove(_Line l) {
    setState(() {
      _lines.remove(l);
      _linesDirty = true;
    });
    l.dispose();
  }

  // ---------------------------------------------------------------- save

  int get _goodsTTC => _lines.fold(0, (s, l) => s + l.lineTTC);
  int get _shippingFee => parseDA(_shipping.text) ?? 0;

  Map<String, dynamic> _lineBody(_Line l) => {
        'product_id': l.productId,
        'qty_milli': l.qtyMilli,
        if (l.manualPrice != null) 'unit_price': l.manualPrice,
        if (l.manualPrice == null && l.keptPrice != null && (l.keptSource == 'web' || l.keptSource == 'backorder')) ...{
          'unit_price': l.keptPrice,
          'discount_pct': l.keptDiscount ?? 0,
        },
      };

  Future<void> _save() async {
    if (_saving) return;
    _errors.clear();
    if (_partnerId == null) _errors['partner_id'] = 'Choisissez le client.';
    if (_lines.isEmpty) _errors['lines'] = 'Ajoutez au moins un produit.';
    if (_shipping.text.trim().isNotEmpty && parseDA(_shipping.text) == null) {
      _errors['shipping_fee'] = 'Montant invalide.';
    }
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    final body = <String, dynamic>{
      'partner_id': _partnerId,
      if (ex == null || ex!.source != 'web') 'source': _source,
      'priority': _priority,
      'payment_mode': _paymentMode,
      'requested_date': _requestedDate,
      'delivery_address': _address.text.trim(),
      'wilaya': _wilaya ?? '',
      'commune': _commune.text.trim(),
      'contact_name': _contactName.text.trim(),
      'contact_phone': _contactPhone.text.trim(),
      'notes': _notes.text.trim(),
      'internal_notes': _internal.text.trim(),
      'shipping_fee': _shippingFee,
      'rep_user_id': _repId ?? '',
    };
    if (ex != null) {
      body['order_date'] = ex!.orderDate;
      body['warehouse_id'] = ex!.warehouseId;
      body['extra_discount'] = ex!.extraDiscount;
      body['promo_code'] = ex!.promoCode;
      if (ex!.source == 'web') body.remove('source');
      if (_linesDirty) body['lines'] = [for (final l in _lines) _lineBody(l)];
    } else {
      body['lines'] = [for (final l in _lines) _lineBody(l)];
    }
    if (body['requested_date'] == null) body.remove('requested_date');
    setState(() => _saving = true);
    try {
      final o = await withApproval(
          context, api, () => ex == null ? api.createOrder(body) : api.updateOrder(ex!.id, body));
      if (!mounted) return;
      showToast(context, ex == null ? 'Commande ${o.number} enregistrée.' : 'Commande ${o.number} modifiée.');
      Navigator.of(context).pop(o);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (e.field != null) _errors[e.field!] = e.message;
      });
      showActionError(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showActionError(context, e);
    }
  }

  Future<void> _back() async {
    if (_lines.isNotEmpty && ex == null || (ex != null && _linesDirty)) {
      final leave = await confirmAction(context,
          title: 'Quitter sans enregistrer ?', message: 'La commande en cours de saisie sera perdue.', confirmLabel: 'Quitter');
      if (!leave || !mounted) return;
    }
    Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final title = ex == null ? 'Nouvelle commande' : 'Modifier ${ex!.number}';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: AppPage(
        crumbs: [Crumb('Commandes clients', _back), Crumb(title)],
        title: title,
        subtitle: Text('Ctrl+S pour enregistrer · Échap pour revenir', style: T.small),
        onBack: _back,
        maxWidth: 1320,
        actions: [
          PageAction(label: 'Annuler', onPressed: _back),
          PageAction(
            label: _saving ? 'Enregistrement…' : 'Enregistrer la commande',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _saving ? null : _save,
          ),
        ],
        bottomBar: _totalsBar(),
        body: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 1000;
          final left = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _clientSection(),
            _linesSection(),
          ]);
          final right = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _deliverySection(),
            _moreSection(),
          ]);
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 7, child: left),
                  const SizedBox(width: 16),
                  SizedBox(width: 380, child: right),
                ])
              : Column(children: [left, right]);
        }),
      ),
    );
  }

  Widget _clientSection() {
    final c = _client;
    final cr = _credit;
    return PageSection(
      title: 'Client',
      trailing: _partnerId == null
          ? null
          : TextButton.icon(
              onPressed: _pickClient,
              icon: const Icon(Icons.swap_horiz_rounded, size: 16),
              label: const Text('Changer de client')),
      child: _partnerId == null
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PrimaryButton(label: 'Choisir le client', onPressed: _pickClient),
              FieldError(_errors['partner_id']),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_partnerName, style: T.h2),
              if (c != null) ...[
                const SizedBox(height: 4),
                Text([c.phone, c.wilaya, c.priceLevelLabel].where((s) => s.isNotEmpty).join(' · '), style: T.bodyMuted),
              ],
              const SizedBox(height: 12),
              if (c?.crmStatus == 'blocked')
                const InfoBanner(
                    text: 'Client bloqué : la validation demandera de passer outre.', kind: ToastKind.error),
              if (cr == null)
                const SkeletonBar(width: 260, height: 12)
              else ...[
                Wrap(spacing: 28, runSpacing: 10, children: [
                  _fact('Solde', fmtDA(cr.balance), color: cr.balance > 0 ? T.warnDark : T.ink),
                  _fact('Plafond', cr.creditLimit > 0 ? fmtDA(cr.creditLimit) : 'Aucun'),
                  _fact('Commandes en cours', '${cr.openOrdersCount} · ${fmtDA(cr.openOrdersTotal)}'),
                  _fact(
                      'Crédit restant',
                      cr.availableCredit == null ? 'Sans plafond' : fmtDA(cr.availableCredit!),
                      color: (cr.availableCredit ?? 1) - _goodsTTC < 0 ? T.dangerDark : T.mintDark),
                ]),
                if (cr.overdueCount > 0) ...[
                  const SizedBox(height: 10),
                  InfoBanner(
                      text: '${cr.overdueCount} facture${cr.overdueCount > 1 ? 's' : ''} échue${cr.overdueCount > 1 ? 's' : ''} '
                          'non payée${cr.overdueCount > 1 ? 's' : ''} : ${fmtDA(cr.overdueAmount)}',
                      kind: ToastKind.warning),
                ],
                if (cr.availableCredit != null && cr.availableCredit! - _goodsTTC < 0)
                  InfoBanner(
                      text: 'Cette commande dépasse le crédit restant de ${fmtDA(_goodsTTC - cr.availableCredit!)}.',
                      kind: ToastKind.warning),
              ],
            ]),
    );
  }

  Widget _fact(String k, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: T.label),
        const SizedBox(height: 2),
        Text(v, style: T.monoBody.copyWith(fontWeight: FontWeight.w700, color: color)),
      ]);

  Widget _linesSection() {
    Widget head(String s, double? w, {bool end = false}) {
      final t = Text(s, style: T.label, textAlign: end ? TextAlign.end : TextAlign.start);
      return w == null ? Expanded(child: t) : SizedBox(width: w, child: t);
    }

    return PageSection(
      title: 'Produits',
      trailing: Text('${_lines.length} ligne${_lines.length > 1 ? 's' : ''}', style: T.small),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: _entry,
              focusNode: _entryFocus,
              autofocus: true,
              style: T.body,
              onSubmitted: (_) => _addFromEntry(),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Scanner un code-barres ou taper un nom, puis Entrée',
                prefixIcon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: FormText(controller: _entryQty, numeric: true, hint: 'Qté', onSubmitted: (_) => _addFromEntry()),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: T.ink, foregroundColor: Colors.white),
              onPressed: _searching ? null : _addFromEntry,
              icon: _searching
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.add_rounded, size: 18),
              label: const Text('Ajouter'),
            ),
          ),
        ]),
        FieldError(_errors['lines']),
        const SizedBox(height: 14),
        if (_lines.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
                _partnerId == null
                    ? 'Choisissez d’abord le client : les prix dépendent de lui (prix spéciaux, tarif de son groupe).'
                    : 'Aucun produit. Scannez ou cherchez un produit ci-dessus.',
                style: T.bodyMuted),
          )
        else ...[
          Row(children: [
            head('Produit', null),
            head('Quantité', 92),
            head('Prix HT', 150),
            head('Offert', 80, end: true),
            head('Total TTC', 120, end: true),
            const SizedBox(width: 44),
          ]),
          const Divider(height: 14),
          for (final l in _lines) _lineRow(l),
        ],
      ]),
    );
  }

  Widget _lineRow(_Line l) {
    final warn = l.quotaWarning;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name, style: T.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (l.loading)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6))
              else if (l.source.isNotEmpty)
                DocChip(
                    label: priceSourceLabel(l.source),
                    bg: l.source.startsWith('special') ? T.mintTint : T.cream,
                    fg: l.source.startsWith('special') ? T.mintDark : T.muted),
              if (l.discountPct > 0) DocChip(label: 'Remise ${pctText(l.discountPct)}', bg: T.mintTint, fg: T.mintDark),
              if (l.quote?.promoRuleName != null && l.freeMilli > 0)
                Text('Offre : ${l.quote!.promoRuleName}', style: T.small),
              if (l.barcode != null) Text(l.barcode!, style: T.monoSmall),
            ]),
            if (l.error != null) FieldError(l.error),
            if (warn != null)
              Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(warn, style: T.small.copyWith(color: T.warnDark, fontWeight: FontWeight.w700))),
          ]),
        ),
        SizedBox(
          width: 92,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FormText(controller: l.qtyCtrl, numeric: true, onChanged: (t) => _setQty(l, t)),
          ),
        ),
        SizedBox(
          width: 150,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: l.priceCtrl,
              style: T.body,
              onChanged: (t) => _setPrice(l, t),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,. ]'))],
              decoration: InputDecoration(
                isDense: true,
                hintText: fmtDA(l.unitPrice),
                hintStyle: T.monoSmall.copyWith(color: T.ink),
                helperText: l.manualPrice != null ? 'Prix modifié' : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 80,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(l.freeMilli > 0 ? '+${fmtQty(l.freeMilli)} UG' : '—',
                textAlign: TextAlign.end,
                style: T.monoSmall.copyWith(
                    color: l.freeMilli > 0 ? T.mintDark : T.ghost, fontWeight: FontWeight.w700)),
          ),
        ),
        SizedBox(
          width: 120,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(fmtDA(l.lineTTC), textAlign: TextAlign.end, style: T.monoBody),
          ),
        ),
        SizedBox(
          width: 44,
          child: IconButton(
            tooltip: 'Retirer la ligne',
            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: T.dangerDark),
            onPressed: () => _remove(l),
          ),
        ),
      ]),
    );
  }

  Widget _deliverySection() {
    final wilayas = {...wilayaNames, ?_wilaya}.toList()..sort();
    return PageSection(
      title: 'Livraison',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LabeledField(label: 'Adresse de livraison', child: FormText(controller: _address, maxLines: 2)),
        LabeledField(
          label: 'Wilaya',
          child: FormDropdown<String?>(
            value: _wilaya,
            options: [(null, '—'), for (final w in wilayas) (w, w)],
            onChanged: (v) => setState(() => _wilaya = v),
          ),
        ),
        LabeledField(label: 'Commune', child: FormText(controller: _commune)),
        LabeledField(label: 'Personne à contacter', child: FormText(controller: _contactName, hint: 'Facultatif')),
        LabeledField(label: 'Téléphone de contact', child: FormText(controller: _contactPhone)),
        LabeledField(
          label: 'Livraison souhaitée le',
          child: DateField(value: _requestedDate, width: 340, onChanged: (v) => setState(() => _requestedDate = v)),
        ),
        LabeledField(
          label: 'Frais de livraison (TTC)',
          error: _errors['shipping_fee'],
          child: FormText(controller: _shipping, numeric: true, suffixText: 'DA', hint: '0', onChanged: (_) => setState(() {})),
        ),
      ]),
    );
  }

  Widget _moreSection() {
    final reps = <(String?, String)>[
      (null, 'Aucun'),
      for (final s in _staff) (s.id, s.name),
      if (_repId != null && !_staff.any((s) => s.id == _repId))
        (_repId, _client?.repName.isNotEmpty == true ? _client!.repName : (ex?.repName ?? 'Commercial du client')),
    ];
    return PageSection(
      title: 'Commande',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (ex?.source != 'web')
          LabeledField(
            label: 'Reçue par',
            child: FormDropdown<String>(
              value: _source,
              options: [for (final s in orderSources) if (s.$1 != 'web' && s.$1 != 'portal') s],
              onChanged: (v) => setState(() => _source = v ?? 'manual'),
            ),
          ),
        LabeledField(
          label: 'Priorité',
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (final (v, l) in orderPriorities) ButtonSegment(value: v, label: Text(l))],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
        ),
        LabeledField(
          label: 'Paiement',
          child: FormDropdown<String>(
            value: _paymentMode,
            options: const [('account', 'Sur le compte du client'), ('cod', 'À la livraison (espèces)')],
            onChanged: (v) => setState(() => _paymentMode = v ?? 'account'),
          ),
        ),
        LabeledField(
          label: 'Commercial',
          child: FormDropdown<String?>(value: _repId, options: reps, onChanged: (v) => setState(() => _repId = v)),
        ),
        LabeledField(
            label: 'Note pour le client',
            helper: 'Imprimée sur le bon de commande.',
            child: FormText(controller: _notes, maxLines: 3)),
        LabeledField(
            label: 'Note interne',
            helper: 'Jamais imprimée ni envoyée au client.',
            child: FormText(controller: _internal, maxLines: 3)),
      ]),
    );
  }

  Widget _totalsBar() {
    final free = _lines.fold(0, (s, l) => s + l.freeMilli);
    final ht = _lines.fold(0, (s, l) => s + l.lineHT);
    final total = _goodsTTC + _shippingFee - (ex?.extraDiscount ?? 0);
    return Container(
      decoration: const BoxDecoration(color: T.surface, border: Border(top: BorderSide(color: T.border))),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
      child: Row(children: [
        Text('${_lines.length} produit${_lines.length > 1 ? 's' : ''}', style: T.bodyMuted),
        if (free > 0) ...[
          const SizedBox(width: 18),
          Text('+ ${fmtQty(free)} unité${free > 1000 ? 's' : ''} offerte${free > 1000 ? 's' : ''}',
              style: T.body.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
        ],
        const Spacer(),
        Text('Total HT ', style: T.label),
        Text(fmtDA(ht), style: T.monoBody),
        if (_shippingFee > 0) ...[
          const SizedBox(width: 18),
          Text('Livraison ', style: T.label),
          Text(fmtDA(_shippingFee), style: T.monoBody),
        ],
        const SizedBox(width: 22),
        Text('Total TTC ', style: T.label.copyWith(fontSize: 15)),
        Text(fmtDA(total), style: T.monoBig.copyWith(fontSize: 22)),
      ]),
    );
  }
}

/// Several products match: choose one (↑ ↓ Entrée).
class _ProductChoice extends StatelessWidget {
  const _ProductChoice({required this.items, required this.query});
  final List<Product> items;
  final String query;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      title: Text('Quel produit ? (« $query »)', style: T.h2),
      content: SizedBox(
        width: 560,
        height: 420,
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, i) {
            final p = items[i];
            return ListTile(
              autofocus: i == 0,
              onTap: () => Navigator.pop(context, p),
              title: Text(p.name, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text([p.barcode ?? '', p.brand].where((s) => s.isNotEmpty).join(' · '), style: T.monoSmall),
              trailing: Text(fmtDA(p.priceWholesale ?? p.priceRetail), style: T.monoBody),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'))],
    );
  }
}
