import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'config_widgets.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres › Taxes : the VAT rates offered everywhere (product page, document
/// editor, filters), the default rate of a new product, and the stamp duty.
class TaxesSection extends StatefulWidget {
  const TaxesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<TaxesSection> createState() => _TaxesSectionState();
}

class _VatRow {
  _VatRow(int? rate, String label)
      : rate = TextEditingController(text: rate == null ? '' : editPct(rate)),
        label = TextEditingController(text: label);
  final TextEditingController rate;
  final TextEditingController label;
  String? error;

  void dispose() {
    rate.dispose();
    label.dispose();
  }
}

class _TaxesSectionState extends State<TaxesSection> {
  final _rows = <_VatRow>[];
  late int _default;
  late bool _timbre;
  String? _listError;
  bool _busy = false;

  bool get _edit => widget.ctx.isAdmin;

  @override
  void initState() {
    super.initState();
    final f = Features.instance;
    for (final r in f.vatRates) {
      _rows.add(_VatRow(r, f.vatLabels[r] ?? _defaultName(r)));
    }
    _default = f.defaultVat;
    _timbre = f.timbreEnabled;
  }

  static String _defaultName(int r) => switch (r) {
        1900 => 'Taux normal',
        900 => 'Taux réduit',
        0 => 'Exonéré',
        _ => '',
      };

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final rates = <int>[];
    var bad = false;
    for (final r in _rows) {
      final v = parsePct(r.rate.text);
      r.error = null;
      if (v == null || v > 10000) {
        r.error = 'Taux entre 0 et 100 %';
        bad = true;
      } else if (rates.contains(v)) {
        r.error = 'Ce taux est déjà dans la liste';
        bad = true;
      } else {
        rates.add(v);
      }
    }
    _listError = _rows.isEmpty ? 'Gardez au moins un taux.' : null;
    setState(() {});
    if (bad || _listError != null) return;
    var def = _default;
    if (!rates.contains(def)) def = rates.first;
    final labels = [
      for (var i = 0; i < _rows.length; i++)
        if (_rows[i].label.text.trim().isNotEmpty)
          '${rates[i]}=${_rows[i].label.text.trim().replaceAll('|', ' ').replaceAll('=', ' ')}',
    ].join('|');
    setState(() => _busy = true);
    await saveShopSettings(context, widget.ctx, {
      'vat_rates': rates.join(','),
      'vat_labels': labels,
      'default_vat': '$def',
      'timbre_enabled': _timbre ? '1' : '0',
    }, done: 'Taxes enregistrées.');
    if (mounted) {
      setState(() {
        _busy = false;
        _default = def;
      });
    }
  }

  Future<void> _remove(int i) async {
    final r = _rows[i];
    final v = parsePct(r.rate.text);
    if (v != null) {
      final ok = await confirmAction(context,
          title: 'Retirer le taux ${editPct(v)} % ?',
          message: 'Il ne sera plus proposé pour les nouveaux produits et documents. '
              'Les produits et documents qui l’utilisent déjà gardent leur taux.',
          confirmLabel: 'Retirer');
      if (!ok) return;
    }
    setState(() {
      _rows.removeAt(i).dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final validRates = [for (final r in _rows) ?parsePct(r.rate.text)];
    return SettingsPage(
      title: 'Taxes',
      intro: 'Les taux de TVA proposés dans tout le logiciel et le droit de timbre sur les ventes en espèces.',
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
          title: 'Taux de TVA',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'Ces taux sont proposés sur la fiche produit, dans les factures et les filtres. '
                '0 % est permis (produits exonérés).',
                style: T.bodyMuted),
            const SizedBox(height: 14),
            for (var i = 0; i < _rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  NumberField(
                      label: 'Taux',
                      controller: _rows[i].rate,
                      suffix: '%',
                      decimals: true,
                      width: 120,
                      required: true,
                      enabled: _edit,
                      error: _rows[i].error,
                      onChanged: (_) => setState(() {})),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LabeledField(
                        label: 'Nom (facultatif)',
                        controller: _rows[i].label,
                        enabled: _edit,
                        hint: 'ex. Taux normal'),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: TextButton.icon(
                      onPressed: !_edit || _rows.length <= 1 ? null : () => _remove(i),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Retirer'),
                    ),
                  ),
                ]),
              ),
            FieldError(_listError),
            if (_edit)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _rows.add(_VatRow(null, ''))),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Ajouter un taux'),
                ),
              ),
            const SizedBox(height: 18),
            OptionChips<int>(
              label: 'TVA d’un nouveau produit',
              value: validRates.contains(_default) ? _default : (validRates.isEmpty ? 0 : validRates.first),
              options: [for (final r in validRates) (r, '${editPct(r)} %')],
              onChanged: _edit ? (v) => setState(() => _default = v) : null,
              help: 'Proposée par défaut quand vous créez un produit.',
            ),
          ]),
        ),
        PageSection(
          title: 'Droit de timbre',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchRow(
              title: 'Appliquer le droit de timbre',
              explanation: 'Ajouté automatiquement aux tickets et factures payés en espèces. '
                  'Les paiements par carte (CIB, Edahabia), chèque, virement ou à crédit en sont exemptés.',
              value: _timbre,
              onChanged: _edit ? (v) => setState(() => _timbre = v) : null,
            ),
            const SizedBox(height: 10),
            const InfoBanner(
              icon: Icons.gavel_rounded,
              title: 'Barème légal appliqué (non modifiable)',
              text: '• Jusqu’à 300 DA : pas de timbre.\n'
                  '• De 300 à 30 000 DA : 1 DA par tranche de 100 DA commencée.\n'
                  '• De 30 000 à 100 000 DA : 1,5 DA par tranche de 100 DA.\n'
                  '• Au-delà de 100 000 DA : 2 DA par tranche de 100 DA.\n'
                  'Le montant est arrondi au dinar supérieur, avec un minimum de 5 DA et un maximum de 10 000 DA.\n'
                  'Exemples : 1 000 DA → 10 DA ; 25 000 DA → 250 DA ; 50 000 DA → 750 DA.',
            ),
            if (!_timbre)
              const InfoBanner(
                kind: ToastKind.warning,
                icon: Icons.warning_amber_rounded,
                text: 'Le timbre est désactivé : aucun ticket ni facture n’en portera. '
                    'Ne le désactivez que si votre activité en est légalement dispensée.',
              ),
          ]),
        ),
      ],
    );
  }
}
