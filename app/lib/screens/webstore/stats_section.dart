import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/app_page.dart';
import '../../widgets/charts.dart';
import '../../widgets/list_toolbar.dart';
import '../../widgets/ui.dart';
import 'web_common.dart';

/// « Statistiques » : anonymous daily visits of the site and the most viewed
/// products (no cookies, bots excluded).
class StatsSection extends StatefulWidget {
  const StatsSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<StatsSection> createState() => _StatsSectionState();
}

class _StatsSectionState extends State<StatsSection> {
  int _days = 30;
  String _metric = 'views';
  Future<WebStats>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() =>
      setState(() => _future = widget.ctx.client.webStats(days: _days));

  int _value(WebStatsDay d) => switch (_metric) {
        'products' => d.productViews,
        'cart' => d.addToCart,
        'orders' => d.orders + d.quotes,
        _ => d.views,
      };

  Widget _kpi(String label, int value, String help) => SizedBox(
        width: 190,
        child: Card14(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label),
            const SizedBox(height: 6),
            Text('$value', style: T.monoBig.copyWith(fontSize: 24)),
            const SizedBox(height: 2),
            Text(help, style: T.small),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return WebLoader<WebStats>(
      future: _future,
      onRetry: _reload,
      builder: (s) {
        final t = s.totals;
        // Bars keep a fixed gap: past ~45 days, one bar = 3 days.
        final g = s.daily.length > 45 ? 3 : 1;
        final bars = <(String, double)>[];
        for (var i = 0; i < s.daily.length; i += g) {
          final chunk = s.daily.sublist(i, (i + g).clamp(0, s.daily.length));
          final n = bars.length;
          final day = chunk.first.day;
          bars.add((
            n % 5 == 0 && day.length >= 10 ? day.substring(8, 10) : '',
            chunk.fold<int>(0, (a, d) => a + _value(d)).toDouble(),
          ));
        }
        final conv = t.views == 0 ? 0.0 : (t.orders + t.quotes) * 100 / t.views;
        return WebPane(
          title: 'Statistiques',
          intro: 'Visites anonymes de votre boutique (sans cookies, robots exclus).',
          actions: [
            for (final d in const [7, 30, 90])
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: FilterPill(
                    label: '$d jours',
                    active: _days == d,
                    onTap: () {
                      _days = d;
                      _reload();
                    }),
              ),
            PageAction(label: 'Actualiser', icon: Icons.refresh_rounded, onPressed: _reload),
          ],
          children: [
            Wrap(spacing: 14, runSpacing: 14, children: [
              _kpi('Pages vues', t.views, 'accueil, listes et produits'),
              _kpi('Fiches produit vues', t.productViews, 'pages produit ouvertes'),
              _kpi('Ajouts au panier', t.addToCart, 'clics « Ajouter »'),
              _kpi('Commandes', t.orders, 'passées sur le site'),
              _kpi('Demandes de devis', t.quotes, 'mode catalogue'),
              _kpi('Taux de commande',
                  conv.round(), '% des pages vues → commande ou devis'),
            ]),
            const SizedBox(height: 16),
            WebBlock(
              title: 'Jour par jour',
              trailing: Wrap(children: [
                for (final (v, l) in const [
                  ('views', 'Pages vues'),
                  ('products', 'Fiches produit'),
                  ('cart', 'Paniers'),
                  ('orders', 'Commandes + devis'),
                ])
                  FilterPill(
                      label: l,
                      active: _metric == v,
                      onTap: () => setState(() => _metric = v)),
              ]),
              children: [
                if (s.daily.isEmpty)
                  Text('Pas encore de visites.', style: T.bodyMuted)
                else
                  Bars(data: bars, height: 180),
                const SizedBox(height: 6),
                Text(g > 1
                        ? 'Une barre = 3 jours ; le chiffre est le jour du mois. Dernière barre = aujourd’hui.'
                        : 'Le chiffre sous une barre est le jour du mois ; la dernière barre = aujourd’hui.',
                    style: T.small),
              ],
            ),
            WebBlock(
              title: 'Produits les plus consultés',
              children: [
                if (s.topProducts.isEmpty)
                  Text('Aucune consultation pour l’instant.', style: T.bodyMuted)
                else ...[
                  const Row(children: [
                    SizedBox(width: 34, child: Text('#', style: T.label)),
                    Expanded(child: Text('Produit', style: T.label)),
                    SizedBox(width: 110, child: Text('Vues', style: T.label)),
                    SizedBox(width: 140, child: Text('Ajouts au panier', style: T.label)),
                  ]),
                  const Divider(),
                  for (var i = 0; i < s.topProducts.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        SizedBox(width: 34, child: Text('${i + 1}', style: T.monoSmall)),
                        Expanded(
                          child: Text(s.topProducts[i].name,
                              style: T.body, overflow: TextOverflow.ellipsis),
                        ),
                        SizedBox(
                            width: 110,
                            child: Text('${s.topProducts[i].views}', style: T.monoBody)),
                        SizedBox(
                            width: 140,
                            child: Text('${s.topProducts[i].addToCart}', style: T.monoBody)),
                      ]),
                    ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}
