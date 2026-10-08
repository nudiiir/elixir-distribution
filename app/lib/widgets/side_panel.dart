import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Opens [builder] as a panel sliding in from the right over the current
/// screen (the list stays visible on the left). Esc or a click outside
/// closes it. Returns what the panel pops with.
Future<V?> showSidePanel<V>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 760,
}) {
  return showGeneralDialog<V>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fermer',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: T.bg,
        elevation: 12,
        shadowColor: Colors.black26,
        child: SizedBox(
          width: width.clamp(360, MediaQuery.of(ctx).size.width - 120),
          height: double.infinity,
          child: builder(ctx),
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .chain(CurveTween(curve: Curves.easeOutCubic))
          .animate(anim),
      child: child,
    ),
  );
}
