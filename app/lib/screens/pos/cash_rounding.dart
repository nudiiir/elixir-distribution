import '../../theme/tokens.dart';
import '../../util/features.dart';

/// Arrondi des espèces (Paramètres › Caisse) — exact mirror of the server's
/// `cashRoundingDelta` (server/internal/api/ux_pos.go).
///
/// The server records the rounding as a ticket line « Arrondi » (VAT 0): the
/// ticket total is then exactly the cash that went into the drawer, so the
/// X/Z reports and the sales figures stay exact.

/// Whether the timbre is due on cash sales in this shop.
bool get posTimbreOn => Features.instance.timbreEnabled;

/// Timbre on a cash amount, honouring the shop's timbre setting.
int posTimbre(int cashGoods) =>
    posTimbreOn && cashGoods > 0 ? timbreFor(cashGoods) : 0;

/// Cash to take for goods paid in cash (timbre included when due).
int cashDueOf(int cashGoods, {bool? timbre}) {
  final on = timbre ?? posTimbreOn;
  return on && cashGoods > 0 ? cashGoods + timbreFor(cashGoods) : cashGoods;
}

/// The « Arrondi » amount (centimes, may be negative) to add to the goods
/// paid in cash so that goods + arrondi + timbre is a multiple of [step],
/// nearest to the unrounded amount. 0 when no rounding applies.
int cashRoundingDelta(int cashGoods, int step, {bool? timbre}) {
  final on = timbre ?? posTimbreOn;
  if (step <= 0 || cashGoods <= 0) return 0;
  final base = cashDueOf(cashGoods, timbre: on);
  if (base % step == 0) return 0;
  final near = ((base + step ~/ 2) ~/ step) * step;
  // The timbre moves by whole DA, so the nearest multiple may be out of
  // reach: then the next nearest one (below or above, closest first).
  final below = near - step, above = near + step;
  final others = (below - base).abs() < (above - base).abs()
      ? [below, above]
      : [above, below];
  for (final target in [near, ...others]) {
    if (target <= 0) continue;
    int? best;
    for (var d = -2 * step; d <= 2 * step; d++) {
      if (cashGoods + d <= 0 ||
          cashDueOf(cashGoods + d, timbre: on) != target) {
        continue;
      }
      if (best == null || d.abs() < best.abs()) best = d;
    }
    if (best != null) return best;
  }
  return 0;
}

/// The shop's cash rounding step (centimes; 0 = none).
int get posCashStep => Features.instance.posCashRounding;

/// Plain label of a rounding step, for the settings and the till.
String cashRoundingLabel(int step) => switch (step) {
  50 => '0,50 DA',
  100 => '1 DA',
  500 => '5 DA',
  0 => 'Aucun',
  _ => fmtDA(step),
};
