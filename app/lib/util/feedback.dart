import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One confirmation dialog for every destructive or important action.
/// Returns true only when the user explicitly confirms.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirmer',
  bool danger = false,
  IconData? icon,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: danger ? T.dangerTint : T.mintTint,
            shape: BoxShape.circle,
          ),
          child: Icon(icon ?? (danger ? Icons.warning_amber_rounded : Icons.help_outline_rounded),
              size: 18, color: danger ? T.dangerDark : T.mintDark),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: T.h2)),
      ]),
      content: message == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(message, style: T.bodyMuted),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          autofocus: true,
          style: FilledButton.styleFrom(
            backgroundColor: danger ? T.danger : T.mint,
            foregroundColor: danger ? Colors.white : T.ink,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

enum ToastKind { success, info, warning, error }

/// Snackbar with the lifetimes used everywhere: success/info 4.5 s,
/// warning 10 s, errors stay until dismissed. Optional action (« Ouvrir »,
/// « Annuler »…).
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.success,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final duration = switch (kind) {
    ToastKind.success || ToastKind.info => const Duration(milliseconds: 4500),
    ToastKind.warning => const Duration(seconds: 10),
    ToastKind.error => const Duration(days: 1),
  };
  final icon = switch (kind) {
    ToastKind.success => Icons.check_circle_rounded,
    ToastKind.info => Icons.info_outline_rounded,
    ToastKind.warning => Icons.warning_amber_rounded,
    ToastKind.error => Icons.error_outline_rounded,
  };
  final color = switch (kind) {
    ToastKind.success => T.mint,
    ToastKind.info => Colors.white70,
    ToastKind.warning => T.warn,
    ToastKind.error => T.danger,
  };
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    width: 460,
    duration: duration,
    backgroundColor: T.ink,
    showCloseIcon: kind == ToastKind.error || kind == ToastKind.warning,
    closeIconColor: Colors.white70,
    content: Row(children: [
      Icon(icon, color: color, size: 18),
      const SizedBox(width: 10),
      Expanded(
          child: Text(message,
              style: T.body.copyWith(color: Colors.white, fontSize: 13))),
    ]),
    action: actionLabel == null
        ? null
        : SnackBarAction(
            label: actionLabel,
            textColor: T.mint,
            onPressed: onAction ?? () {},
          ),
  ));
}

/// Runs [action] after a grace period unless the user presses « Annuler ».
/// Use for reversible-looking steps (empty a ticket, remove a line…): it
/// replaces a confirmation dialog. [undo] restores the previous state at once.
void showUndoToast(
  BuildContext context,
  String message, {
  required VoidCallback undo,
}) {
  showToast(context, message,
      kind: ToastKind.info, actionLabel: 'Annuler', onAction: undo);
}

/// Error text shown under a form field (field-level validation).
class FieldError extends StatelessWidget {
  const FieldError(this.text, {super.key});
  final String? text;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, size: 13, color: T.dangerDark),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text!,
              style: T.small.copyWith(color: T.dangerDark, fontSize: 11.5)),
        ),
      ]),
    );
  }
}
