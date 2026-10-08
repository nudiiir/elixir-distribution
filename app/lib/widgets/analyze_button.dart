import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../util/analysis_links.dart';

/// « Analyser ▾ » page action: opens the Explorateur on one of the ready
/// analyses of the object shown (this product, this customer…). Hidden when
/// the user has no access to the Explorateur.
class AnalyzeButton extends StatelessWidget {
  const AnalyzeButton({super.key, required this.seeds, this.label = 'Analyser'});
  final List<AnalysisSeed> seeds;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!AnalysisLinks.available || seeds.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: PopupMenuButton<AnalysisSeed>(
        tooltip: 'Ouvrir une analyse dans l’Explorateur',
        color: T.surface,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            side: const BorderSide(color: T.border)),
        onSelected: AnalysisLinks.launch,
        itemBuilder: (_) => [
          for (final s in seeds)
            PopupMenuItem(
              value: s,
              height: 40,
              child: Row(children: [
                const Icon(Icons.insights_rounded, size: 17, color: T.mintDark),
                const SizedBox(width: 10),
                Text(s.title, style: T.body.copyWith(fontSize: 14)),
              ]),
            ),
        ],
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.insights_rounded, size: 18, color: T.mintDark),
            const SizedBox(width: 7),
            Text(label,
                style: const TextStyle(
                    fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w700, color: T.ink)),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down_rounded, size: 20, color: T.muted),
          ]),
        ),
      ),
    );
  }
}
