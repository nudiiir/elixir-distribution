import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/ui.dart';
import 'cart_line.dart';
import 'parked_tickets.dart';

/// « Tickets en attente » (F5): pops with the ticket to resume, or null.
/// « Supprimer » asks for confirmation (the cart is lost for good).
class ParkedTicketsDialog extends StatefulWidget {
  const ParkedTicketsDialog({super.key});

  @override
  State<ParkedTicketsDialog> createState() => _ParkedTicketsDialogState();
}

class _ParkedTicketsDialogState extends State<ParkedTicketsDialog> {
  List<ParkedTicket>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ParkedTicketStore.instance.list();
    if (mounted) setState(() => _items = items);
  }

  static int totalOf(ParkedTicket t) {
    final level = t.partner?.priceLevel ?? 'retail';
    var total = 0;
    for (final l in t.lines) {
      final c = CartLine(l.product)
        ..qtyMilli = l.qtyMilli
        ..discountPct = l.discountPct;
      total += c.lineTTC(level);
    }
    return total;
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _delete(ParkedTicket t) async {
    final ok = await confirmAction(
      context,
      title: 'Supprimer le ticket en attente n° ${t.number} ?',
      message:
          '${t.itemCount} article(s), ${fmtDA(totalOf(t))}. Le panier sera perdu.',
      confirmLabel: 'Supprimer',
      danger: true,
    );
    if (!ok) return;
    await ParkedTicketStore.instance.remove(t.number);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Dialog(
      backgroundColor: T.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: SizedBox(
        width: 600,
        height: 460,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.pause_circle_outline,
                    size: 18,
                    color: T.mintDeep,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Tickets en attente', style: T.h2),
                  ),
                  IconButton(
                    tooltip: 'Fermer (Échap)',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18, color: T.muted),
                  ),
                ],
              ),
              Text('Gardés sur ce poste uniquement.', style: T.small),
              const SizedBox(height: 10),
              Expanded(
                child: items == null
                    ? const Center(
                        child: CircularProgressIndicator(color: T.mint),
                      )
                    : items.isEmpty
                    ? const EmptyState(
                        icon: Icons.pause_circle_outline,
                        text:
                            'Aucun ticket en attente.\n« Mettre en attente » (F4) libère la caisse pour le client suivant.',
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) {
                          final t = items[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    color: T.mintTint,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '${t.number}',
                                    style: T.monoBody.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: T.mintDark,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    [
                                      _hhmm(t.parkedAt),
                                      t.partner?.name ?? 'Client de passage',
                                      '${t.itemCount} article(s)',
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: T.body,
                                  ),
                                ),
                                Text(
                                  fmtDA(totalOf(t)),
                                  style: T.monoBody.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(t),
                                  child: Text(
                                    'Reprendre',
                                    style: T.body.copyWith(
                                      color: T.mintDark,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => _delete(t),
                                  child: Text(
                                    'Supprimer',
                                    style: T.small.copyWith(
                                      color: T.dangerDark,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
