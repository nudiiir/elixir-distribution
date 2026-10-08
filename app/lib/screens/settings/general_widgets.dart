import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';

/// Form building blocks shared by the general settings sections: label
/// ABOVE the field, red « * » when required, help or error under it.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.required = false,
    this.help,
    this.error,
    this.hint,
    this.maxLines = 1,
    this.mono = false,
    this.enabled = true,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.suffix,
  });

  final String label;
  final TextEditingController controller;
  final bool required;
  final String? help;
  final String? error;
  final String? hint;
  final int maxLines;
  final bool mono;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

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
        TextField(
          controller: controller,
          enabled: enabled,
          minLines: maxLines > 1 ? 2 : 1,
          maxLines: maxLines,
          keyboardType: keyboardType ?? (maxLines > 1 ? TextInputType.multiline : null),
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: mono ? T.monoBody : T.body,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            filled: true,
            fillColor: enabled ? T.surface : T.bg,
            suffixIcon: suffix,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            border: border,
            enabledBorder: border,
            disabledBorder: border.copyWith(borderSide: const BorderSide(color: T.border)),
            focusedBorder: border.copyWith(
                borderSide: BorderSide(color: error == null ? T.mintDeep : T.danger, width: 1.6)),
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

/// « Libellé * » above a field.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.required = false});
  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: text, style: T.label.copyWith(color: T.ink, fontWeight: FontWeight.w600)),
        if (required)
          const TextSpan(
              text: ' *', style: TextStyle(color: T.danger, fontWeight: FontWeight.w700)),
      ]));
}

/// Two short fields side by side (Téléphone | Email).
class FieldPair extends StatelessWidget {
  const FieldPair(this.a, this.b, {super.key});
  final Widget a;
  final Widget b;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: a),
        const SizedBox(width: 16),
        Expanded(child: b),
      ]);
}

/// A switch with a title and a plain explanation under it.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.explanation,
  });
  final String title;
  final String? explanation;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(T.rInner),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              if (explanation != null) ...[
                const SizedBox(height: 3),
                Text(explanation!, style: T.bodyMuted),
              ],
            ]),
          ),
          const SizedBox(width: 16),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

/// Banner shown to non-admins: they can read but not change.
class AdminOnlyNotice extends StatelessWidget {
  const AdminOnlyNotice({super.key});

  @override
  Widget build(BuildContext context) => const InfoBanner(
        icon: Icons.lock_outline_rounded,
        text: 'Seul un administrateur peut modifier ces réglages.',
      );
}

/// A tinted message block (info / warning / danger).
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.title,
    this.kind = ToastKind.info,
    this.actions = const [],
  });
  final String text;
  final String? title;
  final IconData icon;
  final ToastKind kind;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      ToastKind.warning => (T.warnTint, T.warnDark),
      ToastKind.error => (T.dangerTint, T.dangerDark),
      ToastKind.success => (T.mintTint, T.mintDark),
      ToastKind.info => (T.cream, T.muted),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: fg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null) ...[
              Text(title!, style: T.body.copyWith(fontWeight: FontWeight.w700, color: T.ink)),
              const SizedBox(height: 4),
            ],
            Text(text, style: T.body.copyWith(color: T.ink)),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 0, runSpacing: 8, children: actions),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Dialog that asks the user to type a word before a dangerous action.
/// Returns true only when the word was typed and confirmed.
Future<bool> confirmTyped(
  BuildContext context, {
  required String title,
  required String message,
  required String word,
  required String confirmLabel,
  List<String> alsoAccepted = const [],
}) async {
  final ctrl = TextEditingController();
  bool ok(String v) {
    final t = v.trim().toUpperCase();
    return t == word.toUpperCase() || alsoAccepted.any((a) => a.toUpperCase() == t);
  }

  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
        title: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(color: T.dangerTint, shape: BoxShape.circle),
            child: const Icon(Icons.warning_amber_rounded, size: 18, color: T.dangerDark),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: T.h2)),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(message, style: T.bodyMuted),
            const SizedBox(height: 16),
            FieldLabel('Pour confirmer, tapez $word'),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: T.monoBody,
              onChanged: (_) => setDlg(() {}),
              onSubmitted: (v) {
                if (ok(v)) Navigator.of(ctx).pop(true);
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: word,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.danger, foregroundColor: Colors.white),
            onPressed: ok(ctrl.text) ? () => Navigator.of(ctx).pop(true) : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  return res == true;
}

/// « 08/10/2026 14:05 » from an ISO timestamp (local time).
String fmtDateTime(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}
