import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../api/dist_api.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_editor.dart' show showPartnerPicker;
import '../orders/order_common.dart';
import '../orders/product_pick.dart';

/// « Choisir… » button showing the current choice (product / client).
class PickerField extends StatelessWidget {
  const PickerField({super.key, required this.label, required this.onPick, this.onClear, this.width = 420});
  final String? label;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 42,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: T.ink,
          backgroundColor: T.surface,
          side: const BorderSide(color: T.border3),
          padding: const EdgeInsets.only(left: 12, right: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rInner)),
        ),
        onPressed: onPick,
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 16, color: T.muted),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label ?? 'Choisir…',
                  overflow: TextOverflow.ellipsis, style: T.body.copyWith(color: label == null ? T.ghost : T.ink))),
          if (label != null && onClear != null)
            IconButton(
                tooltip: 'Retirer',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 16),
                onPressed: onClear),
        ]),
      ),
    );
  }
}

abstract class _FormState<W extends StatefulWidget> extends State<W> {
  bool saving = false;
  final Map<String, String> errors = {};

  String get pageTitle;
  Future<Object?> doSave();
  bool validate();

  Future<void> save() async {
    if (saving) return;
    errors.clear();
    if (!validate()) {
      setState(() {});
      return;
    }
    setState(() => saving = true);
    try {
      final r = await doSave();
      if (!mounted) return;
      showToast(context, 'Enregistré.');
      Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        saving = false;
        if (e.field != null) errors[e.field!] = e.message;
      });
      if (e.field == null) showActionError(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      showActionError(context, e);
    }
  }

  Widget frame(List<Widget> sections) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.keyS, control: true): save},
        child: AppPage(
          crumbs: [Crumb('Tarifs et offres', () => Navigator.of(context).pop()), Crumb(pageTitle)],
          title: pageTitle,
          maxWidth: 760,
          actions: [
            PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).pop()),
            PageAction(
                label: saving ? 'Enregistrement…' : 'Enregistrer',
                icon: Icons.check_rounded,
                primary: true,
                onPressed: saving ? null : save),
          ],
          body: Column(children: sections),
        ),
      );
}

// ---------------------------------------------------------------------------
// Special price
// ---------------------------------------------------------------------------

class SpecialPriceFormPage extends StatefulWidget {
  const SpecialPriceFormPage(
      {super.key, required this.api, this.existing, this.groups = const [], this.initialProduct, this.initialPartner});
  final ApiClient api;
  final CustomerPrice? existing;
  final List<CustomerGroup> groups;
  final (String, String)? initialProduct;
  final (String, String)? initialPartner;

  @override
  State<SpecialPriceFormPage> createState() => _SpecialPriceFormPageState();
}

class _SpecialPriceFormPageState extends _FormState<SpecialPriceFormPage> {
  late final e = widget.existing;
  late String _for = e?.groupId != null ? 'group' : 'partner';
  late (String, String)? _partner =
      e?.partnerId != null ? (e!.partnerId!, e!.partnerName ?? '') : widget.initialPartner;
  late String? _groupId = e?.groupId;
  late (String, String)? _product = e != null ? (e!.productId, e!.productName) : widget.initialProduct;
  late final _price = TextEditingController(text: e == null ? '' : editDA(e!.priceHT));
  late final _minQty = TextEditingController(text: e == null || e!.minQtyMilli == 0 ? '' : fmtQty(e!.minQtyMilli));
  late String? _start = e?.startDate;
  late String? _end = e?.endDate;
  late final _notes = TextEditingController(text: e?.notes ?? '');

  @override
  String get pageTitle => e == null ? 'Nouveau prix spécial' : 'Prix spécial — ${e!.productName}';

  @override
  void dispose() {
    _price.dispose();
    _minQty.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  bool validate() {
    if (_for == 'partner' && _partner == null) errors['partner_id'] = 'Choisissez le client.';
    if (_for == 'group' && _groupId == null) errors['group_id'] = 'Choisissez le groupe.';
    if (_product == null) errors['product_id'] = 'Choisissez le produit.';
    final p = parseDA(_price.text);
    if (p == null || p < 0) errors['price_ht'] = 'Prix invalide.';
    if (_minQty.text.trim().isNotEmpty && (parseQty(_minQty.text) ?? -1) < 0) errors['min_qty_milli'] = 'Quantité invalide.';
    return errors.isEmpty;
  }

  @override
  Future<Object?> doSave() => widget.api.saveCustomerPrice({
        if (_for == 'partner') 'partner_id': _partner!.$1,
        if (_for == 'group') 'group_id': _groupId,
        'product_id': _product!.$1,
        'price_ht': parseDA(_price.text),
        'min_qty_milli': _minQty.text.trim().isEmpty ? 0 : parseQty(_minQty.text),
        'start_date': _start,
        'end_date': _end,
        'notes': _notes.text.trim(),
      }, id: e?.id);

  @override
  Widget build(BuildContext context) {
    return frame([
      PageSection(
        title: 'Pour qui',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'partner', label: Text('Un client')),
              ButtonSegment(value: 'group', label: Text('Un groupe de clients')),
            ],
            selected: {_for},
            onSelectionChanged: (v) => setState(() => _for = v.first),
          ),
          const SizedBox(height: 14),
          if (_for == 'partner')
            LabeledField(
              label: 'Client',
              required: true,
              error: errors['partner_id'],
              child: PickerField(
                label: _partner?.$2,
                onPick: () async {
                  final p = await showPartnerPicker(context, widget.api, kind: 'customer');
                  if (p != null) setState(() => _partner = (p.id, p.name));
                },
              ),
            )
          else
            LabeledField(
              label: 'Groupe de clients',
              required: true,
              error: errors['group_id'],
              helper: widget.groups.isEmpty ? 'Créez des groupes dans Paramètres › Clients.' : null,
              child: FormDropdown<String?>(
                value: _groupId,
                width: 420,
                options: [(null, 'Choisir…'), for (final g in widget.groups) (g.id, g.name)],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ),
        ]),
      ),
      PageSection(
        title: 'Prix',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
            label: 'Produit',
            required: true,
            error: errors['product_id'],
            child: PickerField(
              label: _product?.$2,
              onPick: () async {
                final p = await pickProduct(context, widget.api);
                if (p != null) setState(() => _product = (p.id, p.name));
              },
            ),
          ),
          LabeledField(
            label: 'Prix unitaire HT',
            required: true,
            error: errors['price_ht'],
            helper: 'Hors taxes : la TVA du produit s’ajoute.',
            child: SizedBox(width: 220, child: FormText(controller: _price, numeric: true, suffixText: 'DA', autofocus: e == null)),
          ),
          LabeledField(
            label: 'À partir de (quantité)',
            error: errors['min_qty_milli'],
            helper: 'Vide = dès la première unité. Plusieurs paliers possibles : un prix par quantité minimum.',
            child: SizedBox(width: 220, child: FormText(controller: _minQty, numeric: true)),
          ),
          Row(children: [
            LabeledField(label: 'Valable du', child: DateField(value: _start, onChanged: (v) => setState(() => _start = v))),
            const SizedBox(width: 14),
            LabeledField(label: 'Au', child: DateField(value: _end, onChanged: (v) => setState(() => _end = v))),
          ]),
          LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 2)),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Offer / free units
// ---------------------------------------------------------------------------

class PromoFormPage extends StatefulWidget {
  const PromoFormPage(
      {super.key,
      required this.api,
      this.existing,
      this.groups = const [],
      this.categories = const [],
      this.initialProduct});
  final ApiClient api;
  final PromoRule? existing;
  final List<CustomerGroup> groups;
  final List<Category> categories;
  final (String, String)? initialProduct;

  @override
  State<PromoFormPage> createState() => _PromoFormPageState();
}

class _PromoFormPageState extends _FormState<PromoFormPage> {
  late final e = widget.existing;
  late final _name = TextEditingController(text: e?.name ?? '');
  late String _type = e?.type.isNotEmpty == true ? e!.type : 'free_goods';
  late String _scope = e?.scope ?? (widget.initialProduct != null ? 'product' : 'product');
  late (String, String)? _product =
      e?.productId != null ? (e!.productId!, e!.productName ?? '') : widget.initialProduct;
  late String? _categoryId = e?.categoryId;
  late final _brand = TextEditingController(text: e?.brand ?? '');
  late final _minQty = TextEditingController(text: e == null ? '' : fmtQty(e!.minQtyMilli));
  late final _free = TextEditingController(text: e == null || e!.freeQtyMilli == 0 ? '' : fmtQty(e!.freeQtyMilli));
  late final _pct = TextEditingController(
      text: e == null || e!.discountPct == 0 ? '' : pctText(e!.discountPct).replaceAll(' %', ''));
  late String _audience = e?.audience ?? 'all';
  late String? _groupId = e?.groupId;
  late (String, String)? _partner = e?.partnerId != null ? (e!.partnerId!, e!.partnerName ?? '') : null;
  late String _channel = e?.channel ?? 'all';
  late String? _start = e?.startDate;
  late String? _end = e?.endDate;
  late bool _active = e?.active ?? true;
  late final _notes = TextEditingController(text: e?.notes ?? '');

  @override
  String get pageTitle => e == null ? 'Nouvelle offre' : e!.name;

  @override
  void dispose() {
    for (final c in [_name, _brand, _minQty, _free, _pct, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _pctX100 {
    final t = _pct.text.trim().replaceAll(',', '.').replaceAll('%', '');
    final v = double.tryParse(t);
    return v == null ? null : (v * 100).round();
  }

  @override
  bool validate() {
    if (_name.text.trim().isEmpty) errors['name'] = 'Donnez un nom à l’offre.';
    if (_scope == 'product' && _product == null) errors['product_id'] = 'Choisissez le produit.';
    if (_scope == 'category' && _categoryId == null) errors['category_id'] = 'Choisissez la catégorie.';
    if (_scope == 'brand' && _brand.text.trim().isEmpty) errors['brand'] = 'Indiquez la marque.';
    final n = parseQty(_minQty.text);
    if (n == null || n <= 0) errors['min_qty_milli'] = 'Quantité minimum obligatoire.';
    if (_type == 'free_goods') {
      final m = parseQty(_free.text);
      if (m == null || m <= 0) errors['free_qty_milli'] = 'Nombre d’unités offertes obligatoire.';
    } else {
      final p = _pctX100;
      if (p == null || p < 1 || p > 10000) errors['discount_pct'] = 'Remise entre 0,01 et 100 %.';
    }
    if (_audience == 'group' && _groupId == null) errors['group_id'] = 'Choisissez le groupe.';
    if (_audience == 'partner' && _partner == null) errors['partner_id'] = 'Choisissez le client.';
    return errors.isEmpty;
  }

  @override
  Future<Object?> doSave() => widget.api.savePromoRule({
        'name': _name.text.trim(),
        'scope': _scope,
        if (_scope == 'product') 'product_id': _product!.$1,
        if (_scope == 'category') 'category_id': _categoryId,
        if (_scope == 'brand') 'brand': _brand.text.trim(),
        'type': _type,
        'min_qty_milli': parseQty(_minQty.text),
        if (_type == 'free_goods') 'free_qty_milli': parseQty(_free.text),
        if (_type == 'qty_discount') 'discount_pct': _pctX100,
        'start_date': _start,
        'end_date': _end,
        'audience': _audience,
        if (_audience == 'group') 'group_id': _groupId,
        if (_audience == 'partner') 'partner_id': _partner!.$1,
        'channel': _channel,
        'active': _active,
        'notes': _notes.text.trim(),
      }, id: e?.id);

  String get _summary {
    final n = parseQty(_minQty.text);
    if (n == null || n <= 0) return '';
    if (_type == 'free_goods') {
      final m = parseQty(_free.text);
      return m == null || m <= 0 ? '' : 'Pour ${fmtQty(n)} achetés, ${fmtQty(m)} offert${m > 1000 ? 's' : ''} (et ainsi de suite).';
    }
    final p = _pctX100;
    return p == null ? '' : 'Remise de ${pctText(p)} dès ${fmtQty(n)} unités.';
  }

  @override
  Widget build(BuildContext context) {
    return frame([
      PageSection(
        title: 'Offre',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
              label: 'Nom',
              required: true,
              error: errors['name'],
              child: FormText(controller: _name, autofocus: e == null, hint: 'Ex. Doliprane 10 + 1')),
          LabeledField(
            label: 'Type',
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'free_goods', label: Text('Unités gratuites (UG)')),
                ButtonSegment(value: 'qty_discount', label: Text('Remise par quantité')),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 220,
              child: LabeledField(
                label: _type == 'free_goods' ? 'Pour (quantité achetée)' : 'Dès (quantité)',
                required: true,
                error: errors['min_qty_milli'],
                child: FormText(controller: _minQty, numeric: true, onChanged: (_) => setState(() {})),
              ),
            ),
            const SizedBox(width: 14),
            if (_type == 'free_goods')
              SizedBox(
                width: 220,
                child: LabeledField(
                  label: 'Offert (unités)',
                  required: true,
                  error: errors['free_qty_milli'],
                  child: FormText(controller: _free, numeric: true, onChanged: (_) => setState(() {})),
                ),
              )
            else
              SizedBox(
                width: 220,
                child: LabeledField(
                  label: 'Remise',
                  required: true,
                  error: errors['discount_pct'],
                  child: FormText(controller: _pct, numeric: true, suffixText: '%', onChanged: (_) => setState(() {})),
                ),
              ),
          ]),
          if (_summary.isNotEmpty) InfoBanner(text: _summary, kind: ToastKind.success),
        ]),
      ),
      PageSection(
        title: 'Sur quels produits',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
            label: 'Portée',
            child: FormDropdown<String>(
              value: _scope,
              width: 420,
              options: const [
                ('product', 'Un produit'),
                ('category', 'Une catégorie'),
                ('brand', 'Une marque'),
                ('all', 'Tous les produits'),
              ],
              onChanged: (v) => setState(() => _scope = v ?? 'product'),
            ),
          ),
          if (_scope == 'product')
            LabeledField(
              label: 'Produit',
              required: true,
              error: errors['product_id'],
              child: PickerField(
                label: _product?.$2,
                onPick: () async {
                  final p = await pickProduct(context, widget.api);
                  if (p != null) setState(() => _product = (p.id, p.name));
                },
              ),
            ),
          if (_scope == 'category')
            LabeledField(
              label: 'Catégorie',
              required: true,
              error: errors['category_id'],
              child: FormDropdown<String?>(
                value: _categoryId,
                width: 420,
                options: [(null, 'Choisir…'), for (final c in widget.categories) (c.id, c.name)],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
          if (_scope == 'brand')
            LabeledField(
                label: 'Marque',
                required: true,
                error: errors['brand'],
                child: SizedBox(width: 420, child: FormText(controller: _brand))),
        ]),
      ),
      PageSection(
        title: 'Pour qui, où, quand',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
            label: 'Clients concernés',
            child: FormDropdown<String>(
              value: _audience,
              width: 420,
              options: const [('all', 'Tous les clients'), ('group', 'Un groupe de clients'), ('partner', 'Un seul client')],
              onChanged: (v) => setState(() => _audience = v ?? 'all'),
            ),
          ),
          if (_audience == 'group')
            LabeledField(
              label: 'Groupe',
              required: true,
              error: errors['group_id'],
              child: FormDropdown<String?>(
                value: _groupId,
                width: 420,
                options: [(null, 'Choisir…'), for (final g in widget.groups) (g.id, g.name)],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ),
          if (_audience == 'partner')
            LabeledField(
              label: 'Client',
              required: true,
              error: errors['partner_id'],
              child: PickerField(
                label: _partner?.$2,
                onPick: () async {
                  final p = await showPartnerPicker(context, widget.api, kind: 'customer');
                  if (p != null) setState(() => _partner = (p.id, p.name));
                },
              ),
            ),
          LabeledField(
            label: 'Canal',
            helper: 'Les offres « Tous » ou « Boutique web » pour tous les clients sont publiées sur le site.',
            child: FormDropdown<String>(
              value: _channel,
              width: 420,
              options: const [('all', 'Partout'), ('desk', 'Bureau seulement'), ('web', 'Boutique web seulement')],
              onChanged: (v) => setState(() => _channel = v ?? 'all'),
            ),
          ),
          Row(children: [
            LabeledField(label: 'Du', child: DateField(value: _start, onChanged: (v) => setState(() => _start = v))),
            const SizedBox(width: 14),
            LabeledField(label: 'Au', child: DateField(value: _end, onChanged: (v) => setState(() => _end = v))),
          ]),
          LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 2)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Offre active', style: T.body),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Quota
// ---------------------------------------------------------------------------

class QuotaFormPage extends StatefulWidget {
  const QuotaFormPage({super.key, required this.api, this.existing, this.initialProduct});
  final ApiClient api;
  final Quota? existing;
  final (String, String)? initialProduct;

  @override
  State<QuotaFormPage> createState() => _QuotaFormPageState();
}

class _QuotaFormPageState extends _FormState<QuotaFormPage> {
  late final e = widget.existing;
  late (String, String)? _product = e != null ? (e!.productId, e!.productName) : widget.initialProduct;
  late (String, String)? _partner = e?.partnerId != null ? (e!.partnerId!, e!.partnerName ?? '') : null;
  late final _max = TextEditingController(text: e == null ? '' : fmtQty(e!.maxQtyMilli));
  late String _period = e?.period.isNotEmpty == true ? e!.period : 'month';
  late bool _active = e?.active ?? true;
  late final _notes = TextEditingController(text: e?.notes ?? '');

  @override
  String get pageTitle => e == null ? 'Nouveau quota' : 'Quota — ${e!.productName}';

  @override
  void dispose() {
    _max.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  bool validate() {
    if (_product == null) errors['product_id'] = 'Choisissez le produit.';
    final m = parseQty(_max.text);
    if (m == null || m <= 0) errors['max_qty_milli'] = 'Quantité maximum obligatoire.';
    return errors.isEmpty;
  }

  @override
  Future<Object?> doSave() => widget.api.saveQuota({
        'product_id': _product!.$1,
        'partner_id': ?_partner?.$1,
        'max_qty_milli': parseQty(_max.text),
        'period': _period,
        'active': _active,
        'notes': _notes.text.trim(),
      }, id: e?.id);

  @override
  Widget build(BuildContext context) {
    return frame([
      PageSection(
        title: 'Quota',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const InfoBanner(
              text: 'Un quota limite la quantité qu’un client peut recevoir d’un produit rare. '
                  'Il est vérifié à la validation de la commande et ne peut pas être dépassé.'),
          LabeledField(
            label: 'Produit',
            required: true,
            error: errors['product_id'],
            child: PickerField(
              label: _product?.$2,
              onPick: () async {
                final p = await pickProduct(context, widget.api);
                if (p != null) setState(() => _product = (p.id, p.name));
              },
            ),
          ),
          LabeledField(
            label: 'Client',
            helper: 'Vide = chaque client a ce quota. Un quota propre à un client remplace le quota général.',
            child: PickerField(
              label: _partner?.$2,
              onPick: () async {
                final p = await showPartnerPicker(context, widget.api, kind: 'customer');
                if (p != null) setState(() => _partner = (p.id, p.name));
              },
              onClear: () => setState(() => _partner = null),
            ),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 220,
              child: LabeledField(
                label: 'Quantité maximum',
                required: true,
                error: errors['max_qty_milli'],
                child: FormText(controller: _max, numeric: true, autofocus: e == null),
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 220,
              child: LabeledField(
                label: 'Par',
                child: FormDropdown<String>(
                  value: _period,
                  options: const [('day', 'Jour'), ('week', 'Semaine'), ('month', 'Mois')],
                  onChanged: (v) => setState(() => _period = v ?? 'month'),
                ),
              ),
            ),
          ]),
          LabeledField(label: 'Notes', child: FormText(controller: _notes, maxLines: 2)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Quota actif', style: T.body),
          ),
        ]),
      ),
    ]);
  }
}
