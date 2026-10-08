import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/ui.dart';
import 'mixed_payment_dialog.dart' show methodLabel;

/// « Derniers tickets » (F7): the last 20 tickets of the open session with
/// Réimprimer / Ouvrir / Retour.
class RecentTicketsPanel extends StatefulWidget {
  const RecentTicketsPanel({
    super.key,
    required this.api,
    required this.onReprint,
    required this.onOpen,
    required this.onReturn,
  });
  final ApiClient api;
  final Future<void> Function(PosRecentTicket) onReprint;
  final void Function(PosRecentTicket) onOpen;
  final void Function(PosRecentTicket) onReturn;

  @override
  State<RecentTicketsPanel> createState() => _RecentTicketsPanelState();
}

class _RecentTicketsPanelState extends State<RecentTicketsPanel> {
  List<PosRecentTicket>? _items;
  String? _error;
  String? _printing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await widget.api.posRecentTickets(limit: 20);
      if (mounted) setState(() => _items = items);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  static String _time(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  static String _method(PosRecentTicket t) {
    if (t.payments.isNotEmpty) {
      return t.payments.map((p) => methodLabel(p.method)).join(' + ');
    }
    return t.paymentMethod == null
        ? 'Carte cadeau'
        : methodLabel(t.paymentMethod!);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Material(
      color: T.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.history_rounded, size: 18, color: T.mintDeep),
                const SizedBox(width: 8),
                const Expanded(child: Text('Derniers tickets', style: T.h2)),
                _act('Actualiser', Icons.refresh_rounded, _load),
                IconButton(
                  tooltip: 'Fermer (Échap)',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
              ],
            ),
            Text('Session de caisse en cours · 20 derniers', style: T.small),
            const SizedBox(height: 10),
            Expanded(
              child: _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off_outlined,
                      text: 'Impossible de charger les tickets.\n$_error',
                      actions: [('Réessayer', _load)],
                    )
                  : items == null
                  ? const Center(
                      child: CircularProgressIndicator(color: T.mint),
                    )
                  : items.isEmpty
                  ? EmptyState(
                      icon: Icons.receipt_long_outlined,
                      text:
                          'Aucun ticket dans cette session.\nLes ventes encaissées apparaîtront ici.',
                      actions: [
                        (
                          'Retour à la caisse',
                          () => Navigator.of(context).pop(),
                        ),
                      ],
                    )
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, i) => _row(items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _act(String label, IconData icon, VoidCallback? onPressed) =>
      TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: T.ink,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(
            fontFamily: T.sans,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        icon: Icon(icon, size: 17),
        label: Text(label),
      );

  Widget _row(PosRecentTicket t) {
    final cancelled = t.status == 'cancelled';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(_time(t.postedAt), style: T.monoSmall),
          ),
          Expanded(
            child: Text(
              [
                t.number ?? '',
                if (t.partnerName != null) t.partnerName!,
                _method(t),
                if (cancelled) 'annulé',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: T.body.copyWith(
                fontSize: 14,
                color: cancelled ? T.faint : T.ink,
                decoration: cancelled ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            fmtDA(t.totalTTC),
            style: T.monoBody.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          _act(
            'Réimprimer',
            Icons.print_outlined,
            _printing == t.id
                ? null
                : () async {
                    setState(() => _printing = t.id);
                    try {
                      await widget.onReprint(t);
                    } finally {
                      if (mounted) setState(() => _printing = null);
                    }
                  },
          ),
          _act('Ouvrir', Icons.open_in_new_rounded, () => widget.onOpen(t)),
          _act(
            'Retour',
            Icons.assignment_return_outlined,
            cancelled ? null : () => widget.onReturn(t),
          ),
        ],
      ),
    );
  }
}
