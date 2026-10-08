import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/ui.dart';

/// Moyens proposés dans le paiement mixte (la carte cadeau garde son propre
/// parcours : code, solde, débit).
const mixedMethods = <(String, String, IconData)>[
  ('cash', 'Espèces', Icons.payments_outlined),
  ('cib', 'CIB', Icons.credit_card),
  ('edahabia', 'Edahabia', Icons.contactless_outlined),
  ('cheque', 'Chèque', Icons.request_page_outlined),
  ('credit', 'Crédit', Icons.menu_book_outlined),
];

String methodLabel(String m) => switch (m) {
  'cash' => 'Espèces',
  'cib' => 'CIB',
  'edahabia' => 'Edahabia',
  'cheque' => 'Chèque',
  'transfer' => 'Virement',
  'credit' => 'Crédit',
  'gift' => 'Carte cadeau',
  _ => m,
};

/// What the dialog hands back: the rows to post (one merged cash row that
/// includes the timbre), what the customer handed over in cash, the change.
class MixedPaymentResult {
  const MixedPaymentResult(this.payments, this.cashReceived, this.change);
  final List<PosPayment> payments;
  final int cashReceived;
  final int change;
}

/// The money math of a mixed payment, shared by the dialog and its tests:
/// the non-cash rows pay part of the goods, the cash rows pay the rest plus
/// the timbre due on that cash part only.
class MixedMath {
  MixedMath(this.goods, this.cashGiven, this.nonCash);
  final int goods; // total TTC of the goods, timbre excluded
  final int cashGiven; // sum of the cash rows as typed (may exceed: change)
  final int nonCash; // sum of the other rows

  int get cashGoods => goods - nonCash;
  int get timbre => cashGiven > 0 && cashGoods > 0 ? timbreFor(cashGoods) : 0;
  int get cashDue => cashGoods > 0 ? cashGoods + timbre : 0;
  int get totalToPay => goods + timbre;
  int get collected => cashGiven + nonCash;
  bool get overNonCash => nonCash > goods;
  int get remaining {
    if (overNonCash) return 0;
    final r = cashDue - cashGiven;
    if (cashGiven == 0) return cashGoods > 0 ? cashGoods : 0;
    return r > 0 ? r : 0;
  }

  int get change {
    if (overNonCash) return 0;
    final c = cashGiven - cashDue;
    return c > 0 ? c : 0;
  }

  bool get covered =>
      !overNonCash && remaining == 0 && (cashGoods <= 0 || cashGiven > 0);
}

class MixedPaymentDialog extends StatefulWidget {
  const MixedPaymentDialog({
    super.key,
    required this.goodsTotal,
    required this.hasClient,
  });
  final int goodsTotal; // TTC, timbre excluded
  final bool hasClient;

  @override
  State<MixedPaymentDialog> createState() => _MixedPaymentDialogState();
}

class _Row {
  _Row(this.method) : ctrl = TextEditingController();
  String method;
  final TextEditingController ctrl;
  int get amount => parseDA(ctrl.text) ?? 0;
}

class _MixedPaymentDialogState extends State<MixedPaymentDialog> {
  late final List<_Row> _rows = [_Row('cib'), _Row('cash')];

  @override
  void dispose() {
    for (final r in _rows) {
      r.ctrl.dispose();
    }
    super.dispose();
  }

  MixedMath _math({_Row? except}) {
    var cash = 0, other = 0;
    for (final r in _rows) {
      if (identical(r, except)) continue;
      if (r.method == 'cash') {
        cash += r.amount;
      } else {
        other += r.amount;
      }
    }
    return MixedMath(widget.goodsTotal, cash, other);
  }

  String? get _error {
    final m = _math();
    if (!widget.hasClient &&
        _rows.any((r) => r.method == 'credit' && r.amount > 0)) {
      return 'Le crédit exige un client : choisissez-le d’abord (F6).';
    }
    if (m.overNonCash) {
      return 'Les paiements hors espèces dépassent le total (le rendu ne se fait qu’en espèces).';
    }
    return null;
  }

  bool get _canPay => _error == null && _math().covered;

  /// « Reste » on a row: the amount that makes the ticket exactly covered.
  void _fillRest(_Row row) {
    final others = _math(except: row);
    int fill;
    if (row.method == 'cash') {
      final g = widget.goodsTotal - others.nonCash;
      fill = g > 0 ? g + timbreFor(g) - others.cashGiven : 0;
    } else {
      // Smallest x such that the cash already typed covers what is left
      // (goods − x) plus its timbre. g + timbre(g) grows with g: bisection.
      final maxX = widget.goodsTotal - others.nonCash;
      if (maxX <= 0) {
        fill = 0;
      } else if (others.cashGiven == 0) {
        fill = maxX;
      } else {
        var lo = 0, hi = maxX;
        while (lo < hi) {
          final mid = (lo + hi) ~/ 2;
          final g = maxX - mid;
          final due = g > 0 ? g + timbreFor(g) : 0;
          if (due <= others.cashGiven) {
            hi = mid;
          } else {
            lo = mid + 1;
          }
        }
        fill = lo;
      }
    }
    if (fill < 0) fill = 0;
    setState(() => row.ctrl.text = fill == 0 ? '' : editDA(fill));
  }

  void _submit() {
    if (!_canPay) return;
    final m = _math();
    final byMethod = <String, int>{};
    for (final r in _rows) {
      if (r.method == 'cash' || r.amount <= 0) continue;
      byMethod[r.method] = (byMethod[r.method] ?? 0) + r.amount;
    }
    final pays = [
      for (final e in byMethod.entries) PosPayment(e.key, e.value),
      if (m.cashDue > 0) PosPayment('cash', m.cashDue),
    ];
    Navigator.of(context).pop(MixedPaymentResult(pays, m.cashGiven, m.change));
  }

  Widget _figure(String label, int amount, {Color? color, bool big = false}) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MicroLabel(label),
            const SizedBox(height: 2),
            Text(
              fmtDA(amount),
              style: TextStyle(
                fontFamily: T.mono,
                fontSize: big ? 18 : 14,
                fontWeight: FontWeight.w700,
                color: color ?? T.ink,
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final m = _math();
    final err = _error;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
      },
      child: Dialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.call_split_rounded,
                      size: 18,
                      color: T.mintDeep,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Paiement mixte', style: T.h2)),
                    IconButton(
                      tooltip: 'Fermer (Échap)',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18, color: T.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final r in _rows) _rowWidget(r),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _rows.length >= 6
                        ? null
                        : () => setState(() => _rows.add(_Row('cash'))),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Ajouter un moyen'),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: T.bg,
                    borderRadius: BorderRadius.circular(T.rInner),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _figure('Total à payer', m.totalToPay, big: true),
                          _figure('Encaissé', m.collected),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _figure(
                            'Reste',
                            m.remaining,
                            color: m.remaining > 0 ? T.dangerDark : T.faint,
                          ),
                          _figure(
                            'Rendu',
                            m.change,
                            color: m.change > 0 ? T.mintDark : T.faint,
                          ),
                        ],
                      ),
                      if (m.timbre > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Timbre fiscal ${fmtDA(m.timbre)} sur la part en espèces (${fmtDA(m.cashGoods)}).',
                          style: T.small,
                        ),
                      ],
                    ],
                  ),
                ),
                if (err != null) ...[
                  const SizedBox(height: 8),
                  Text(err, style: T.small.copyWith(color: T.dangerDark)),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          'Annuler',
                          style: T.small.copyWith(color: T.muted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Tooltip(
                        message: 'Encaisser (Entrée)',
                        child: PrimaryButton(
                          label: 'Encaisser',
                          big: true,
                          onPressed: _canPay ? _submit : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowWidget(_Row r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: r.method,
                style: T.body,
                items: [
                  for (final (id, label, icon) in mixedMethods)
                    DropdownMenuItem(
                      value: id,
                      enabled: id != 'credit' || widget.hasClient,
                      child: Row(
                        children: [
                          Icon(
                            icon,
                            size: 15,
                            color: id == 'credit' && !widget.hasClient
                                ? T.ghost
                                : T.muted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            id == 'credit' && !widget.hasClient
                                ? '$label (client requis)'
                                : label,
                            style: T.body.copyWith(
                              color: id == 'credit' && !widget.hasClient
                                  ? T.ghost
                                  : T.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => r.method = v ?? r.method),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                color: T.bg,
                borderRadius: BorderRadius.circular(T.rInner),
                border: Border.all(color: T.border),
              ),
              child: TextField(
                controller: r.ctrl,
                autofocus: identical(r, _rows.first),
                textAlign: TextAlign.end,
                style: T.monoBody.copyWith(fontSize: 15),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _canPay ? _submit() : _fillRest(r),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '0,00',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () => _fillRest(r),
            child: Text('Reste', style: T.small.copyWith(color: T.mintDark)),
          ),
          IconButton(
            tooltip: 'Retirer ce moyen',
            onPressed: _rows.length <= 1
                ? null
                : () => setState(() {
                    _rows.remove(r);
                    r.ctrl.dispose();
                  }),
            icon: const Icon(Icons.close, size: 15, color: T.faint),
          ),
        ],
      ),
    );
  }
}
