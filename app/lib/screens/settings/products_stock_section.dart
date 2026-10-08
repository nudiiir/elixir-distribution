import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'config_widgets.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres › Produits et stock : selling-price rounding and target margin,
/// expiry alert window, default minimum stock, units, brands, internal
/// barcode prefix, default label template.
class ProductsStockSection extends StatefulWidget {
  const ProductsStockSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<ProductsStockSection> createState() => _ProductsStockSectionState();
}

class _ProductsStockSectionState extends State<ProductsStockSection> {
  final f = Features.instance;
  late int _rounding = f.priceRounding;
  late final _margin = TextEditingController(text: '${f.targetMarginPct}');
  late final _expiry = TextEditingController(text: '${f.expiryAlertDays}');
  late final _minStock = TextEditingController(text: fmtQty(f.defaultMinStockMilli));
  late final _prefix = TextEditingController(text: f.barcodePrefix);
  late List<String> _units = [...f.units];
  late List<String> _brands = [...f.brands];
  final Map<String, String?> _err = {};

  List<Template>? _labels;
  String? _labelError;
  String? _defaultLabel;
  String? _initialLabel;
  bool _busy = false;

  bool get _edit => widget.ctx.isAdmin;

  @override
  void initState() {
    super.initState();
    _loadLabels();
  }

  Future<void> _loadLabels() async {
    try {
      final all = await widget.ctx.api.templates(kind: 'label');
      if (!mounted) return;
      String? def;
      for (final t in all) {
        if (t.isDefault) def = t.id;
      }
      setState(() {
        _labels = all;
        _defaultLabel = def ?? (all.isEmpty ? null : all.first.id);
        _initialLabel = def;
        _labelError = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _labelError = e.message);
    }
  }

  @override
  void dispose() {
    _margin.dispose();
    _expiry.dispose();
    _minStock.dispose();
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = int.tryParse(_margin.text.trim());
    final e = int.tryParse(_expiry.text.trim());
    final ms = _minStock.text.trim().isEmpty ? 0 : parseQty(_minStock.text);
    final p = _prefix.text.trim();
    setState(() {
      _err['margin'] = m == null || m < 0 || m > 500 ? 'Entre 0 et 500 %' : null;
      _err['expiry'] = e == null || e < 1 || e > 3650 ? 'Entre 1 et 3 650 jours' : null;
      _err['min'] = ms == null || ms < 0 ? 'Quantité invalide' : null;
      _err['prefix'] = !RegExp(r'^[0-9]{1,7}$').hasMatch(p)
          ? 'De 1 à 7 chiffres (ex. 200)'
          : null;
      _err['units'] = _units.isEmpty ? 'Gardez au moins une unité.' : null;
    });
    if (_err.values.any((v) => v != null)) return;
    setState(() => _busy = true);
    final ok = await saveShopSettings(context, widget.ctx, {
      'price_rounding': '$_rounding',
      'target_margin_pct': '$m',
      'expiry_alert_days': '$e',
      'default_min_stock_milli': '$ms',
      'barcode_prefix': p,
      'units': _units.join('|'),
      'brands': _brands.join('|'),
    }, done: 'Réglages des produits enregistrés.');
    if (ok && _defaultLabel != null && _defaultLabel != _initialLabel) {
      try {
        await widget.ctx.api.setDefaultTemplate(_defaultLabel!);
        _initialLabel = _defaultLabel;
      } on ApiException catch (e) {
        if (mounted) showToast(context, 'Format d’étiquette : ${e.message}', kind: ToastKind.error);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  String _example() {
    final p = _prefix.text.trim();
    if (!RegExp(r'^[0-9]{1,7}$').hasMatch(p)) return '';
    final digits = p + '12345678901'.substring(0, 12 - p.length);
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = int.parse(digits[i]);
      sum += i.isOdd ? d * 3 : d;
    }
    return '$digits${(10 - sum % 10) % 10}';
  }

  @override
  Widget build(BuildContext context) {
    final ex = _example();
    return SettingsPage(
      title: 'Produits et stock',
      intro: 'Comment les prix sont proposés, quand prévenir avant la péremption, et les listes utilisées sur la fiche produit.',
      actions: [
        if (_edit)
          PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _busy ? null : _save),
      ],
      children: [
        if (!_edit) const AdminOnlyNotice(),
        PageSection(
          title: 'Prix de vente',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            OptionChips<int>(
              label: 'Arrondi du prix de vente',
              value: _rounding,
              options: const [(0, 'Aucun'), (500, 'Aux 5 DA'), (1000, 'Aux 10 DA')],
              onChanged: _edit ? (v) => setState(() => _rounding = v) : null,
              help: 'Le prix calculé à partir de la marge (fiche produit, bon de réception) est arrondi '
                  'au-dessus : avec « Aux 10 DA », 243 DA devient 250 DA.',
            ),
            NumberField(
              label: 'Marge cible',
              controller: _margin,
              suffix: '%',
              enabled: _edit,
              error: _err['margin'],
              help: 'Sert au prix de vente proposé quand vous recevez de la marchandise.',
            ),
          ]),
        ),
        PageSection(
          title: 'Stock et péremption',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NumberField(
              label: 'Prévenir avant la péremption',
              controller: _expiry,
              suffix: 'jours',
              enabled: _edit,
              error: _err['expiry'],
              help: 'Les lots qui périment dans ce délai apparaissent dans les alertes, '
                  'le filtre « Péremption proche » et l’onglet Lots du stock.',
            ),
            NumberField(
              label: 'Stock minimum d’un nouveau produit',
              controller: _minStock,
              decimals: true,
              enabled: _edit,
              error: _err['min'],
              help: 'Proposé à la création d’un produit. 0 = pas d’alerte de stock bas.',
            ),
          ]),
        ),
        PageSection(
          title: 'Listes de la fiche produit',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WordListEditor(
              label: 'Unités de vente',
              items: _units,
              enabled: _edit,
              hint: 'ex. bouteille',
              error: _err['units'],
              help: 'Proposées dans la liste « Unité » de la fiche produit.',
              onChanged: (v) => setState(() => _units = v),
            ),
            WordListEditor(
              label: 'Marques',
              items: _brands,
              enabled: _edit,
              hint: 'ex. Ifri',
              help: 'Proposées pendant la saisie de la marque (une autre marque reste possible).',
              onChanged: (v) => setState(() => _brands = v),
            ),
          ]),
        ),
        PageSection(
          title: 'Codes-barres et étiquettes',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NumberField(
              label: 'Début des codes-barres créés par le logiciel',
              controller: _prefix,
              enabled: _edit,
              width: 160,
              error: _err['prefix'],
              onChanged: (_) => setState(() {}),
              help: 'Les codes commençant par 200 à 299 sont réservés à l’usage interne des magasins : '
                  'ils ne se confondent jamais avec ceux des fabricants.'
                  '${ex.isEmpty ? '' : '\nExemple de code créé : $ex'}',
            ),
            const SizedBox(height: 4),
            const FieldLabel('Format d’étiquette par défaut'),
            const SizedBox(height: 8),
            if (_labelError != null)
              Row(children: [
                Expanded(child: FieldError(_labelError)),
                TextButton(onPressed: _loadLabels, child: const Text('Réessayer')),
              ])
            else if (_labels == null)
              const SizedBox(height: 42, child: Align(alignment: Alignment.centerLeft, child: Text('Chargement…')))
            else if (_labels!.isEmpty)
              Text('Aucun modèle d’étiquette pour l’instant : créez-en un depuis Produits › Étiquettes.',
                  style: T.bodyMuted)
            else
              SizedBox(
                width: 360,
                child: DropdownButtonFormField<String>(
                  initialValue: _defaultLabel,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                  ),
                  items: [
                    for (final t in _labels!)
                      DropdownMenuItem(value: t.id, child: Text(t.name, style: T.body)),
                  ],
                  onChanged: _edit ? (v) => setState(() => _defaultLabel = v) : null,
                ),
              ),
            if (_labels != null && _labels!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text('Utilisé quand vous imprimez des étiquettes sans choisir de modèle.', style: T.small),
              ),
          ]),
        ),
      ],
    );
  }
}
