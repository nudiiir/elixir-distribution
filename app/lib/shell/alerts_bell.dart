import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/tokens.dart';
import '../widgets/ui.dart';

/// Top-bar bell: the alert count (ruptures, DLC, retards de paiement…) and,
/// as a small dot, whether the server answers. Opens the alerts list; each
/// line jumps to the module concerned.
class AlertsBell extends StatelessWidget {
  const AlertsBell({
    super.key,
    required this.items,
    required this.online,
    required this.onOpenTarget,
    required this.onRefresh,
  });

  final List<AlertItem> items;
  final bool online;
  final void Function(String target) onOpenTarget;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final critical = items.where((a) => a.critical).length;
    final count = items.length;
    return PopupMenuButton<String>(
      tooltip: online
          ? (count == 0 ? 'Aucune alerte' : '$count alerte${count > 1 ? 's' : ''}')
          : 'Serveur hors ligne',
      color: T.surface,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 380, maxWidth: 420),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rInner),
          side: const BorderSide(color: T.border)),
      onOpened: onRefresh,
      onSelected: onOpenTarget,
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 34,
          child: Row(children: [
            const MicroLabel('Alertes'),
            const Spacer(),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: online ? T.mint : T.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(online ? 'Serveur connecté' : 'Serveur hors ligne',
                style: T.small.copyWith(fontSize: 11)),
          ]),
        ),
        if (items.isEmpty)
          PopupMenuItem<String>(
            enabled: false,
            child: Row(children: [
              const Icon(Icons.check_circle_outline_rounded, size: 18, color: T.mintDeep),
              const SizedBox(width: 10),
              Text('Rien à signaler aujourd’hui.', style: T.body.copyWith(fontSize: 13)),
            ]),
          ),
        for (final a in items)
          PopupMenuItem<String>(
            value: a.target,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                    a.critical ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
                    size: 18,
                    color: a.critical ? T.danger : T.warn),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.title,
                        style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                    if (a.examples.isNotEmpty)
                      Text(
                        a.examples.join(' · ') + (a.count > a.examples.length ? ' …' : ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: T.small.copyWith(fontSize: 11.5),
                      ),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, size: 16, color: T.faint),
              ]),
            ),
          ),
      ],
      child: Stack(clipBehavior: Clip.none, children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.notifications_none_rounded, size: 20, color: T.muted),
        ),
        // server status dot
        PositionedDirectional(
          start: 7,
          bottom: 7,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: online ? T.mint : T.danger,
              shape: BoxShape.circle,
              border: Border.all(color: T.surface, width: 1.4),
            ),
          ),
        ),
        if (count > 0)
          PositionedDirectional(
            end: 2,
            top: 2,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: critical > 0 ? T.danger : T.warn,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: T.surface, width: 1.4),
              ),
              child: Text('$count',
                  style: const TextStyle(
                      fontFamily: T.mono,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ),
          ),
      ]),
    );
  }
}
