import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/tokens.dart';
import '../util/features.dart';
import '../util/feedback.dart';
import '../widgets/ui.dart';

/// « Profil du magasin » : switch off what this shop does not use. Hidden
/// everywhere at once (menu, columns, form fields, filters).
class StoreProfileCard extends StatefulWidget {
  const StoreProfileCard({super.key, required this.api});
  final ApiClient api;

  @override
  State<StoreProfileCard> createState() => _StoreProfileCardState();
}

class _StoreProfileCardState extends State<StoreProfileCard> {
  final Set<String> _saving = {};

  Future<void> _set(String key, bool on) async {
    setState(() => _saving.add(key));
    try {
      await widget.api.saveSettings({key: on ? '1' : '0'});
      await Features.instance.load(widget.api);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Features.instance,
      builder: (context, _) => Card14(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const MicroLabel('Profil du magasin'),
          const SizedBox(height: 4),
          Text(
              'Désactivez ce que votre commerce n’utilise pas : les menus, colonnes '
              'et champs correspondants disparaissent pour tout le monde.',
              style: T.bodyMuted),
          const SizedBox(height: 8),
          Wrap(spacing: 18, runSpacing: 0, children: [
            for (final e in Features.keys.entries)
              SizedBox(
                width: 330,
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.value, style: T.body.copyWith(fontSize: 13)),
                  value: Features.instance.flag(e.key),
                  onChanged: _saving.contains(e.key) ? null : (v) => _set(e.key, v),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Shop-wide defaults the forms use: TVA of a new product, target margin for
/// the suggested selling price, default payment term of credit invoices.
class DefaultsCard extends StatefulWidget {
  const DefaultsCard({super.key, required this.api});
  final ApiClient api;

  @override
  State<DefaultsCard> createState() => _DefaultsCardState();
}

class _DefaultsCardState extends State<DefaultsCard> {
  late int _vat = Features.instance.defaultVat;
  late final _margin =
      TextEditingController(text: '${Features.instance.targetMarginPct}');
  late final _term =
      TextEditingController(text: '${Features.instance.paymentTermDays}');
  String? _marginErr;
  String? _termErr;
  bool _busy = false;

  @override
  void dispose() {
    _margin.dispose();
    _term.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = int.tryParse(_margin.text.trim());
    final t = int.tryParse(_term.text.trim());
    setState(() {
      _marginErr = m == null || m < 0 || m > 500 ? 'Entre 0 et 500 %' : null;
      _termErr = t == null || t < 0 || t > 365 ? 'Entre 0 et 365 jours' : null;
    });
    if (_marginErr != null || _termErr != null) return;
    setState(() => _busy = true);
    try {
      await widget.api.saveSettings({
        'default_vat': '$_vat',
        'target_margin_pct': '$m',
        'payment_term_days': '$t',
      });
      await Features.instance.load(widget.api);
      if (mounted) showToast(context, 'Valeurs par défaut enregistrées.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String label, TextEditingController c, String suffix, String? err,
          String help) =>
      SizedBox(
        width: 220,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MicroLabel(label),
          const SizedBox(height: 5),
          SizedBox(
            height: 38,
            child: TextField(
              controller: c,
              keyboardType: TextInputType.number,
              style: T.monoBody,
              decoration: InputDecoration(
                isDense: true,
                suffixText: suffix,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(T.rInner),
                    borderSide: BorderSide(color: err == null ? T.border : T.danger)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(T.rInner),
                    borderSide: BorderSide(color: err == null ? T.border : T.danger)),
              ),
            ),
          ),
          FieldError(err),
          if (err == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(help, style: T.small.copyWith(fontSize: 11)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Card14(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const MicroLabel('Produits et documents — valeurs par défaut'),
        const SizedBox(height: 12),
        Wrap(spacing: 24, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const MicroLabel('TVA d’un nouveau produit'),
            const SizedBox(height: 5),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final v in const [1900, 900, 0])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    label: Text('${v ~/ 100} %'),
                    selected: _vat == v,
                    onSelected: (_) => setState(() => _vat = v),
                    selectedColor: T.mintTint2,
                  ),
                ),
            ]),
          ]),
          _field('Marge cible', _margin, '%', _marginErr,
              'Sert au prix de vente suggéré à la réception.'),
          _field('Échéance par défaut', _term, 'jours', _termErr,
              'Factures à crédit et factures fournisseur.'),
        ]),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SizedBox(
            width: 150,
            child: PrimaryButton(label: _busy ? '…' : 'Enregistrer', onPressed: _busy ? null : _save),
          ),
        ),
      ]),
    );
  }
}
