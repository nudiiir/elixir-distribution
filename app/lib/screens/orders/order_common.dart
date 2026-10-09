import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/approval.dart';
import '../../util/feedback.dart';
import '../../widgets/doc_list.dart' show DocChip;

export '../settings/users/permission_catalog.dart' show LabeledField, fieldDecoration;

/// Statuses of a customer order, in board order.
const orderStatuses = <(String, String)>[
  ('new', 'Nouvelle'),
  ('validated', 'Validée'),
  ('preparing', 'En préparation'),
  ('ready', 'Prête'),
  ('shipping', 'En livraison'),
  ('delivered', 'Livrée'),
  ('invoiced', 'Facturée'),
  ('cancelled', 'Annulée'),
];

String orderStatusLabel(String s) =>
    orderStatuses.firstWhere((e) => e.$1 == s, orElse: () => (s, s)).$2;

(Color, Color) orderStatusColors(String s) => switch (s) {
      'new' => (const Color(0x1F3B82F6), const Color(0xFF1D4ED8)),
      'validated' => (T.mintTint, T.mintDark),
      'preparing' => (T.warnTint, T.warnDark),
      'ready' => (const Color(0x1F8B5CF6), const Color(0xFF6D28D9)),
      'shipping' => (const Color(0x1F0EA5E9), const Color(0xFF0369A1)),
      'delivered' => (T.mintTint2, T.mintDark),
      'invoiced' => (T.cream, T.muted),
      'cancelled' => (T.dangerTint, T.dangerDark),
      _ => (T.cream, T.muted),
    };

class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = orderStatusColors(status);
    return DocChip(label: orderStatusLabel(status), bg: bg, fg: fg);
  }
}

const orderSources = <(String, String)>[
  ('manual', 'Bureau'),
  ('phone', 'Téléphone'),
  ('whatsapp', 'WhatsApp'),
  ('rep', 'Commercial'),
  ('web', 'Boutique web'),
  ('portal', 'Portail client'),
];

String orderSourceLabel(String s) =>
    orderSources.firstWhere((e) => e.$1 == s, orElse: () => (s, s)).$2;

IconData orderSourceIcon(String s) => switch (s) {
      'phone' => Icons.phone_outlined,
      'whatsapp' => Icons.chat_outlined,
      'rep' => Icons.badge_outlined,
      'web' => Icons.language_rounded,
      'portal' => Icons.public_rounded,
      _ => Icons.desktop_windows_outlined,
    };

class SourceIcon extends StatelessWidget {
  const SourceIcon(this.source, {super.key, this.size = 16});
  final String source;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Origine : ${orderSourceLabel(source)}',
        child: Icon(orderSourceIcon(source), size: size, color: T.muted),
      );
}

const orderPriorities = <(int, String)>[(0, 'Normale'), (1, 'Haute'), (2, 'Urgente')];

String priorityLabel(int p) => orderPriorities.firstWhere((e) => e.$1 == p, orElse: () => (p, 'Normale')).$2;

/// Nothing for a normal priority; an orange / red badge otherwise.
class PriorityBadge extends StatelessWidget {
  const PriorityBadge(this.priority, {super.key});
  final int priority;

  @override
  Widget build(BuildContext context) {
    if (priority <= 0) return const SizedBox.shrink();
    return DocChip(
        label: priority >= 2 ? 'Urgente' : 'Haute',
        bg: priority >= 2 ? T.dangerTint : T.warnTint,
        fg: priority >= 2 ? T.dangerDark : T.warnDark);
  }
}

String priceSourceLabel(String s) => switch (s) {
      'special_partner' => 'Prix spécial',
      'special_group' => 'Tarif groupe',
      'wholesale' => 'Demi-gros',
      'retail' => 'Détail',
      'promo' => 'Prix promo',
      'manual' => 'Prix modifié',
      'web' => 'Prix boutique',
      'backorder' => 'Reliquat',
      _ => s,
    };

const paymentMethodsCod = <(String, String)>[
  ('cash', 'Espèces'),
  ('cib', 'Carte CIB'),
  ('edahabia', 'Edahabia'),
  ('cheque', 'Chèque'),
  ('transfer', 'Virement'),
];

/// « il y a 3 h », « il y a 2 j » from an ISO timestamp.
String ageText(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final diff = DateTime.now().toUtc().difference(d.toUtc());
  if (diff.inMinutes < 1) return 'à l’instant';
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
  return 'il y a ${diff.inDays} j';
}

/// "2026-10-09" → "09/10/2026" (also accepts full timestamps).
String frDate(String? iso) {
  if (iso == null || iso.length < 10) return iso ?? '';
  return '${iso.substring(8, 10)}/${iso.substring(5, 7)}/${iso.substring(0, 4)}';
}

/// ISO timestamp → "09/10/2026 14:05" in local time.
String frDateTime(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso ?? '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// « 7,5 % » from a ×100 percentage.
String pctText(int x100) {
  final v = x100 / 100;
  return '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll('.', ',')} %';
}

/// Shows the error of an action as a red toast (nothing for a closed
/// manager-code dialog, which already says so).
void showActionError(BuildContext context, Object e) {
  if (!context.mounted) return;
  final msg = e is ApiException ? e.message : '$e';
  showToast(context, msg, kind: ToastKind.error);
}

/// Runs an API action with the « Code du gérant » flow; returns null (after a
/// red toast) when it failed.
Future<V?> runGuarded<V>(BuildContext context, ApiClient api, Future<V> Function() run) async {
  try {
    return await withApproval(context, api, run);
  } catch (e) {
    if (context.mounted) showActionError(context, e);
    return null;
  }
}

/// Small text question (motif d'annulation…). Null when closed.
Future<String?> askText(BuildContext context,
    {required String title,
    String? message,
    String label = '',
    String confirmLabel = 'Confirmer',
    bool required = true,
    bool danger = false,
    String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(builder: (ctx, setS) {
        void submit() {
          final v = ctrl.text.trim();
          if (required && v.isEmpty) {
            setS(() => error = 'Ce champ est obligatoire.');
            return;
          }
          Navigator.of(ctx).pop(v);
        }

        return AlertDialog(
          backgroundColor: T.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
          title: Text(title, style: T.h2),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (message != null) ...[Text(message, style: T.bodyMuted), const SizedBox(height: 12)],
              if (label.isNotEmpty) ...[Text(label, style: T.label), const SizedBox(height: 6)],
              TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                style: T.body,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  isDense: true,
                  errorText: error,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: danger ? T.danger : T.mint, foregroundColor: danger ? Colors.white : T.ink),
              onPressed: submit,
              child: Text(confirmLabel),
            ),
          ],
        );
      });
    },
  );
}

/// A date field: shows « 09/10/2026 », opens the calendar, « × » clears it.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.value, required this.onChanged, this.hint = 'Choisir une date', this.width = 210});
  final String? value; // YYYY-MM-DD
  final ValueChanged<String?> onChanged;
  final String hint;
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
        onPressed: () async {
          final now = DateTime.now();
          final init = DateTime.tryParse(value ?? '') ?? now;
          final d = await showDatePicker(
            context: context,
            initialDate: init,
            firstDate: DateTime(now.year - 5),
            lastDate: DateTime(now.year + 5),
          );
          if (d != null) onChanged(isoDate(d));
        },
        child: Row(children: [
          const Icon(Icons.event_outlined, size: 16, color: T.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value == null || value!.isEmpty ? hint : frDate(value),
                style: T.body.copyWith(fontSize: 14, color: value == null ? T.ghost : T.ink)),
          ),
          if (value != null && value!.isNotEmpty)
            IconButton(
              tooltip: 'Effacer la date',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 16),
              onPressed: () => onChanged(null),
            ),
        ]),
      ),
    );
  }
}

/// Plain dropdown for a form (vertical forms: label above, this below).
class FormDropdown<V> extends StatelessWidget {
  const FormDropdown({super.key, required this.value, required this.options, required this.onChanged, this.width});
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V?>? onChanged;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border3),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<V>(
          isExpanded: true,
          value: options.any((o) => o.$1 == value) ? value : null,
          style: T.body.copyWith(fontSize: 14),
          items: [
            for (final (v, l) in options) DropdownMenuItem<V>(value: v, child: Text(l, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Text input with the shared decoration.
class FormText extends StatelessWidget {
  const FormText(
      {super.key,
      required this.controller,
      this.hint,
      this.suffixText,
      this.numeric = false,
      this.maxLines = 1,
      this.autofocus = false,
      this.onSubmitted,
      this.onChanged,
      this.focusNode,
      this.enabled = true});
  final TextEditingController controller;
  final String? hint;
  final String? suffixText;
  final bool numeric;
  final int maxLines;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: autofocus,
      minLines: 1,
      maxLines: maxLines,
      style: T.body,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9,. -]'))] : null,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        suffixText: suffixText,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
      ),
    );
  }
}

/// Coloured information banner (warnings of the credit check, hints…).
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.kind = ToastKind.info, this.lines = const [], this.action});
  final String text;
  final ToastKind kind;
  final List<String> lines;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (kind) {
      ToastKind.error => (T.dangerTint, T.dangerDark, Icons.error_outline_rounded),
      ToastKind.warning => (T.warnTint, T.warnDark, Icons.warning_amber_rounded),
      ToastKind.success => (T.mintTint, T.mintDark, Icons.check_circle_outline_rounded),
      ToastKind.info => (T.mintTint, T.mintDark, Icons.info_outline_rounded),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(T.rInner)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: T.body.copyWith(color: fg, fontWeight: FontWeight.w700)),
            for (final l in lines)
              Padding(padding: const EdgeInsets.only(top: 3), child: Text('• $l', style: T.body.copyWith(fontSize: 13.5))),
          ]),
        ),
        if (action != null) ...[const SizedBox(width: 10), action!],
      ]),
    );
  }
}

/// The 58 wilayas, as the storefront writes them (« 16 Alger »).
const wilayaNames = <String>[
  '01 Adrar', '02 Chlef', '03 Laghouat', '04 Oum El Bouaghi', '05 Batna', '06 Béjaïa', '07 Biskra',
  '08 Béchar', '09 Blida', '10 Bouira', '11 Tamanrasset', '12 Tébessa', '13 Tlemcen', '14 Tiaret',
  '15 Tizi Ouzou', '16 Alger', '17 Djelfa', '18 Jijel', '19 Sétif', '20 Saïda', '21 Skikda',
  '22 Sidi Bel Abbès', '23 Annaba', '24 Guelma', '25 Constantine', '26 Médéa', '27 Mostaganem',
  '28 M’Sila', '29 Mascara', '30 Ouargla', '31 Oran', '32 El Bayadh', '33 Illizi',
  '34 Bordj Bou Arréridj', '35 Boumerdès', '36 El Tarf', '37 Tindouf', '38 Tissemsilt', '39 El Oued',
  '40 Khenchela', '41 Souk Ahras', '42 Tipaza', '43 Mila', '44 Aïn Defla', '45 Naâma',
  '46 Aïn Témouchent', '47 Ghardaïa', '48 Relizane', '49 Timimoun', '50 Bordj Badji Mokhtar',
  '51 Ouled Djellal', '52 Béni Abbès', '53 In Salah', '54 In Guezzam', '55 Touggourt', '56 Djanet',
  '57 El M’Ghair', '58 El Meniaa',
];

const weekdayNames = <int, String>{
  1: 'Lundi',
  2: 'Mardi',
  3: 'Mercredi',
  4: 'Jeudi',
  5: 'Vendredi',
  6: 'Samedi',
  7: 'Dimanche',
};
