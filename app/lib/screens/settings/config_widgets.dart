import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Building blocks of the business-configuration sections (Documents, Produits
/// et stock, Taxes, Clients et fidélité). Labels above fields, plain help
/// under them, errors under the field.

/// Saves shop-wide settings, reloads [Features] so the whole app follows,
/// and shows the outcome. Returns true on success.
Future<bool> saveShopSettings(BuildContext context, SettingsContext ctx, Map<String, String> values,
    {String done = 'Réglages enregistrés.'}) async {
  try {
    await ctx.api.saveSettings(values);
    await Features.instance.load(ctx.api);
    if (context.mounted) showToast(context, done);
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showToast(context, e.message, kind: ToastKind.error);
    return false;
  }
}

/// A short numeric field (days, %, DA…) with its label above.
class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.controller,
    this.suffix,
    this.help,
    this.error,
    this.required = false,
    this.enabled = true,
    this.decimals = false,
    this.width = 240,
    this.onChanged,
  });
  final String label;
  final TextEditingController controller;
  final String? suffix;
  final String? help;
  final String? error;
  final bool required;
  final bool enabled;
  final bool decimals;
  final double width;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(T.rInner),
      borderSide: BorderSide(color: error == null ? T.border3 : T.danger),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label, required: required),
        const SizedBox(height: 6),
        SizedBox(
          width: width,
          child: TextField(
            controller: controller,
            enabled: enabled,
            onChanged: onChanged,
            keyboardType: TextInputType.numberWithOptions(decimal: decimals),
            inputFormatters: [
              FilteringTextInputFormatter.allow(decimals ? RegExp(r'[0-9 ,.]') : RegExp(r'[0-9]')),
            ],
            style: T.monoBody,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: enabled ? T.surface : T.bg,
              suffixText: suffix,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              border: border,
              enabledBorder: border,
              disabledBorder: border.copyWith(borderSide: const BorderSide(color: T.border)),
              focusedBorder: border.copyWith(
                  borderSide: BorderSide(color: error == null ? T.mintDeep : T.danger, width: 1.6)),
            ),
          ),
        ),
        FieldError(error),
        if (error == null && help != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(help!, style: T.small),
          ),
      ]),
    );
  }
}

/// « Libellé » above a row of choice chips (Aucun / 5 DA / 10 DA…).
class OptionChips<V> extends StatelessWidget {
  const OptionChips({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.help,
  });
  final String label;
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V>? onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FieldLabel(label),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (v, l) in options)
              ChoiceChip(
                label: Text(l, style: T.body.copyWith(fontSize: 14)),
                selected: v == value,
                selectedColor: T.mintTint2,
                onSelected: onChanged == null ? null : (_) => onChanged!(v),
              ),
          ]),
          if (help != null) ...[
            const SizedBox(height: 6),
            Text(help!, style: T.small),
          ],
        ]),
      );
}

/// An editable list of words (units, brands): chips with « Retirer », a field
/// and an « Ajouter » button.
class WordListEditor extends StatefulWidget {
  const WordListEditor({
    super.key,
    required this.label,
    required this.items,
    required this.onChanged,
    this.hint = '',
    this.help,
    this.error,
    this.enabled = true,
  });
  final String label;
  final List<String> items;
  final ValueChanged<List<String>> onChanged;
  final String hint;
  final String? help;
  final String? error;
  final bool enabled;

  @override
  State<WordListEditor> createState() => _WordListEditorState();
}

class _WordListEditorState extends State<WordListEditor> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    final v = _c.text.trim().replaceAll('|', ' ');
    if (v.isEmpty) return;
    if (widget.items.any((e) => e.toLowerCase() == v.toLowerCase())) {
      setState(() => _err = '« $v » est déjà dans la liste.');
      return;
    }
    setState(() => _err = null);
    widget.onChanged([...widget.items, v]);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(widget.label),
        const SizedBox(height: 8),
        if (widget.items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('La liste est vide.', style: T.bodyMuted),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final it in widget.items)
              InputChip(
                label: Text(it, style: T.body.copyWith(fontSize: 14)),
                onDeleted: widget.enabled ? () => widget.onChanged([...widget.items]..remove(it)) : null,
                deleteButtonTooltipMessage: 'Retirer « $it »',
              ),
          ]),
        if (widget.enabled) ...[
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(
              width: 260,
              height: 42,
              child: TextField(
                controller: _c,
                style: T.body,
                onSubmitted: (_) => _add(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.hint,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 42,
              child: OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Ajouter'),
              ),
            ),
          ]),
        ],
        FieldError(_err ?? widget.error),
        if (_err == null && widget.error == null && widget.help != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(widget.help!, style: T.small),
          ),
      ]),
    );
  }
}

/// « 19 » / « 9,5 » → 1900 / 950; null when invalid.
int? parsePct(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

/// 1900 → « 19 », 950 → « 9,5 ».
String editPct(int x100) {
  if (x100 % 100 == 0) return '${x100 ~/ 100}';
  var s = (x100 / 100).toStringAsFixed(2);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.replaceAll('.', ',');
}
