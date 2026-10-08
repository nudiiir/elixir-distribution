import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../util/invoice_pdf.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'config_widgets.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres › Documents et numérotation : the number format of every
/// document type, quote validity and payment term, and how invoices print
/// (language, paper, columns, amount in words, footer) with a sample « Aperçu ».
class DocumentsSection extends StatefulWidget {
  const DocumentsSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<DocumentsSection> createState() => _DocumentsSectionState();
}

class _NumRow {
  _NumRow(this.src)
      : prefix = TextEditingController(text: src.prefix),
        next = TextEditingController(text: '${src.nextNumber}'),
        includeYear = src.includeYear,
        digits = src.digits,
        reset = src.resetYearly;

  NumberingRow src;
  final TextEditingController prefix;
  final TextEditingController next;
  bool includeYear;
  int digits;
  bool reset;
  bool open = false;
  String? prefixError;
  String? nextError;

  int? get nextValue => int.tryParse(next.text.trim());

  bool get dirty =>
      prefix.text.trim().toUpperCase() != src.prefix ||
      includeYear != src.includeYear ||
      digits != src.digits ||
      (includeYear && reset) != src.resetYearly ||
      nextValue != src.nextNumber;

  String get preview => NumberingRow.format(
      prefix.text.trim().toUpperCase(), includeYear, digits, nextValue ?? src.nextNumber,
      y: src.year);

  void reload(NumberingRow r) {
    src = r;
    prefix.text = r.prefix;
    next.text = '${r.nextNumber}';
    includeYear = r.includeYear;
    digits = r.digits;
    reset = r.resetYearly;
    prefixError = null;
    nextError = null;
  }

  void dispose() {
    prefix.dispose();
    next.dispose();
  }
}

class _DocumentsSectionState extends State<DocumentsSection> {
  final f = Features.instance;
  List<_NumRow>? _rows;
  String? _rowsError;

  Map<String, String> _settings = const {};
  late final _quoteDays = TextEditingController(text: '${f.quoteValidityDays}');
  late final _termDays = TextEditingController(text: '${f.paymentTermDays}');
  final _footer = TextEditingController();
  String _lang = 'fr';
  String _format = 'a4';
  Set<String> _columns = {'discount'};
  bool _words = true;
  final Map<String, String?> _err = {};
  bool _busy = false;
  bool _previewing = false;

  bool get _edit => widget.ctx.isAdmin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final r in _rows ?? const <_NumRow>[]) {
      r.dispose();
    }
    _quoteDays.dispose();
    _termDays.dispose();
    _footer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _rowsError = null);
    try {
      final s = await widget.ctx.api.settings();
      final o = InvoiceOptions.fromSettings(s);
      final nums = await widget.ctx.api.numbering();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _lang = o.language;
        _format = o.format;
        _columns = {...o.columns};
        _words = o.amountInWords;
        _footer.text = s['company_footer'] ?? '';
        for (final r in _rows ?? const <_NumRow>[]) {
          r.dispose();
        }
        _rows = [for (final n in nums) _NumRow(n)];
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _rowsError = e.message);
    }
  }

  Map<String, String> _formValues() => {
        'quote_validity_days': _quoteDays.text.trim(),
        'payment_term_days': _termDays.text.trim(),
        'invoice_language': _lang,
        'invoice_format': _format,
        'invoice_columns': [for (final c in invoiceColumnLabels.keys) if (_columns.contains(c)) c].join('|'),
        'invoice_amount_words': _words ? '1' : '0',
        'company_footer': _footer.text.trim(),
      };

  bool _validateRow(_NumRow r) {
    final p = r.prefix.text.trim();
    final n = r.nextValue;
    r.prefixError = p.length > 8 || !RegExp(r'^[A-Za-z0-9]*$').hasMatch(p)
        ? 'Lettres et chiffres seulement, 8 au plus (sans espace ni accent)'
        : null;
    if (n == null || n < 1) {
      r.nextError = 'Un nombre à partir de 1';
    } else if (n < r.src.minNext) {
      r.nextError = 'Au moins ${r.src.minNext} : le n° '
          '${NumberingRow.format(r.src.prefix, r.src.includeYear, r.src.digits, r.src.lastIssued, y: r.src.year)} '
          'a déjà été attribué.';
    } else {
      r.nextError = null;
    }
    return r.prefixError == null && r.nextError == null;
  }

  Future<void> _save() async {
    final q = int.tryParse(_quoteDays.text.trim());
    final t = int.tryParse(_termDays.text.trim());
    var ok = true;
    setState(() {
      _err['quote'] = q == null || q < 0 || q > 365 ? 'Entre 0 et 365 jours' : null;
      _err['term'] = t == null || t < 0 || t > 365 ? 'Entre 0 et 365 jours' : null;
      for (final r in _rows ?? const <_NumRow>[]) {
        if (r.dirty && !_validateRow(r)) {
          r.open = true;
          ok = false;
        }
      }
    });
    if (!ok || _err.values.any((v) => v != null)) {
      showToast(context, 'Corrigez les champs signalés en rouge.', kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    var allOk = await saveShopSettings(context, widget.ctx, _formValues(), done: 'Réglages des documents enregistrés.');
    for (final r in _rows ?? const <_NumRow>[]) {
      if (!r.dirty) continue;
      try {
        final saved = await widget.ctx.api.saveNumbering(r.src.docType,
            prefix: r.prefix.text.trim().toUpperCase(),
            includeYear: r.includeYear,
            digits: r.digits,
            resetYearly: r.includeYear && r.reset,
            nextNumber: r.nextValue == r.src.nextNumber ? null : r.nextValue,
            year: r.src.year);
        if (mounted) setState(() => r.reload(saved));
      } on ApiException catch (e) {
        allOk = false;
        if (mounted) {
          setState(() {
            r.open = true;
            r.nextError = e.message;
          });
        }
      }
    }
    if (mounted) {
      setState(() => _busy = false);
      if (!allOk) {
        showToast(context, 'Certains formats de numéro n’ont pas été enregistrés.', kind: ToastKind.warning);
      }
    }
  }

  Future<void> _preview() async {
    setState(() => _previewing = true);
    try {
      final merged = {..._settings, ..._formValues()};
      final inv = _rows?.firstWhere((r) => r.src.docType == 'SALE_INVOICE', orElse: () => _rows!.first);
      if (inv != null && inv.src.docType == 'SALE_INVOICE') {
        merged['number_SALE_INVOICE_prefix'] = inv.prefix.text.trim().toUpperCase();
        merged['number_SALE_INVOICE_year'] = inv.includeYear ? '1' : '0';
        merged['number_SALE_INVOICE_digits'] = '${inv.digits}';
      }
      await openSampleInvoicePdf(settings: merged, api: widget.ctx.api);
    } catch (e) {
      if (mounted) showToast(context, 'Aperçu impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  // ---- UI -------------------------------------------------------------------

  Widget _numRow(_NumRow r) {
    final changed = r.dirty;
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => r.open = !r.open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: Text(r.src.label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                flex: 3,
                child: Text(r.preview, style: T.monoBody.copyWith(color: changed ? T.mintDark : T.ink)),
              ),
              if (changed)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Text('Modifié', style: T.small.copyWith(color: T.mintDark, fontWeight: FontWeight.w700)),
                ),
              TextButton.icon(
                onPressed: () => setState(() => r.open = !r.open),
                icon: Icon(r.open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                label: Text(r.open ? 'Fermer' : (_edit ? 'Modifier' : 'Détails')),
              ),
            ]),
          ),
        ),
        if (r.open)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 14),
            child: Wrap(spacing: 24, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.start, children: [
              SizedBox(
                width: 200,
                child: LabeledField(
                  label: 'Préfixe',
                  controller: r.prefix,
                  enabled: _edit,
                  mono: true,
                  error: r.prefixError,
                  help: 'Vide = pas de préfixe',
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(8),
                  ],
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const FieldLabel('Nombre de chiffres'),
                const SizedBox(height: 6),
                SizedBox(
                  width: 130,
                  child: DropdownButtonFormField<int>(
                    initialValue: r.digits,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                    ),
                    items: [
                      for (var d = 4; d <= 8; d++) DropdownMenuItem(value: d, child: Text('$d', style: T.monoBody)),
                    ],
                    onChanged: _edit ? (v) => setState(() => r.digits = v ?? r.digits) : null,
                  ),
                ),
              ]),
              SizedBox(
                width: 210,
                child: NumberField(
                  label: 'Prochain numéro',
                  controller: r.next,
                  enabled: _edit,
                  width: 150,
                  error: r.nextError,
                  help: r.src.lastIssued == 0 ? 'Aucun document encore numéroté' : 'Au moins ${r.src.minNext}',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 420,
                child: Column(children: [
                  SwitchRow(
                    title: 'Inclure l’année',
                    explanation: 'ex. ${NumberingRow.format('FV', true, r.digits, 124, y: r.src.year)}',
                    value: r.includeYear,
                    onChanged: _edit ? (v) => setState(() => r.includeYear = v) : null,
                  ),
                  SwitchRow(
                    title: 'Repartir à 1 chaque année',
                    explanation: r.includeYear
                        ? 'Le 1er janvier, la numérotation recommence à 1.'
                        : 'Possible seulement quand l’année figure dans le numéro.',
                    value: r.includeYear && r.reset,
                    onChanged: _edit && r.includeYear ? (v) => setState(() => r.reset = v) : null,
                  ),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _numbering() {
    if (_rowsError != null) {
      return Row(children: [
        Expanded(child: FieldError(_rowsError)),
        TextButton(onPressed: _load, child: const Text('Réessayer')),
      ]);
    }
    final rows = _rows;
    if (rows == null) {
      return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SkeletonBar(width: 420, height: 14),
        SizedBox(height: 12),
        SkeletonBar(width: 360, height: 14),
        SizedBox(height: 12),
        SkeletonBar(width: 400, height: 14),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const InfoBanner(
        icon: Icons.format_list_numbered_rounded,
        title: 'Une numérotation continue, sans trou ni doublon',
        text: 'Un numéro est donné au moment où le document est validé, toujours le suivant. '
            'Il n’est jamais réutilisé : un document annulé garde son numéro (il reste visible, marqué « Annulé »). '
            'Vous pouvez avancer le prochain numéro — par exemple pour continuer celle de votre ancien logiciel — '
            'mais jamais le ramener sur un numéro déjà donné. Chaque changement est noté dans le journal d’activité.',
      ),
      Row(children: [
        Expanded(flex: 3, child: Text('Document', style: T.label)),
        Expanded(flex: 3, child: Text('Prochain numéro', style: T.label)),
        const SizedBox(width: 120),
      ]),
      const SizedBox(height: 4),
      for (final r in rows) _numRow(r),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Documents et numérotation',
      intro: 'Numéros des factures, tickets et bons ; validité des devis ; présentation des factures imprimées.',
      actions: [
        PageAction(
            label: _previewing ? 'Préparation…' : 'Aperçu',
            icon: Icons.visibility_outlined,
            onPressed: _previewing ? null : _preview),
        if (_edit)
          PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _busy || _rows == null ? null : _save),
      ],
      children: [
        if (!_edit) const AdminOnlyNotice(),
        PageSection(title: 'Numérotation des documents', child: _numbering()),
        PageSection(
          title: 'Devis et échéances',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NumberField(
              label: 'Validité des devis',
              controller: _quoteDays,
              suffix: 'jours',
              enabled: _edit,
              error: _err['quote'],
              help: 'La date « Valable jusqu’au » est imprimée sur chaque devis. 0 = pas de date.',
            ),
            NumberField(
              label: 'Échéance par défaut des factures à crédit',
              controller: _termDays,
              suffix: 'jours',
              enabled: _edit,
              error: _err['term'],
              help: 'Proposée sur les factures à crédit et les factures fournisseur. 0 = paiement immédiat.',
            ),
          ]),
        ),
        PageSection(
          title: 'Impression des factures',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            OptionChips<String>(
              label: 'Langue',
              value: _lang,
              options: const [('fr', 'Français'), ('ar', 'Arabe'), ('both', 'Les deux')],
              onChanged: _edit ? (v) => setState(() => _lang = v) : null,
              help: '« Les deux » imprime chaque titre en français et en arabe.',
            ),
            OptionChips<String>(
              label: 'Format du papier',
              value: _format,
              options: const [('a4', 'A4'), ('a5', 'A5 (demi-page)')],
              onChanged: _edit ? (v) => setState(() => _format = v) : null,
            ),
            const FieldLabel('Colonnes affichées'),
            const SizedBox(height: 4),
            Text('Désignation, quantité, prix, TVA et total sont toujours imprimés.', style: T.small),
            const SizedBox(height: 6),
            Wrap(spacing: 4, children: [
              for (final e in invoiceColumnLabels.entries)
                SizedBox(
                  width: 200,
                  child: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(e.key == 'expiry' ? 'Date de péremption' : e.value, style: T.body),
                    value: _columns.contains(e.key),
                    onChanged: _edit
                        ? (v) => setState(() => v == true ? _columns.add(e.key) : _columns.remove(e.key))
                        : null,
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            SwitchRow(
              title: 'Montant en lettres',
              explanation: '« Arrêtée la présente facture à la somme de : mille deux cents dinars… »',
              value: _words,
              onChanged: _edit ? (v) => setState(() => _words = v) : null,
            ),
            const SizedBox(height: 8),
            LabeledField(
              label: 'Texte de pied de page',
              controller: _footer,
              enabled: _edit,
              maxLines: 3,
              hint: 'ex. Merci de votre confiance — RIB 00799999000000000000',
              help: 'Imprimé en bas des factures et des tickets. Le même texte que dans Entreprise.',
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _previewing ? null : _preview,
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Voir une facture d’exemple'),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}
