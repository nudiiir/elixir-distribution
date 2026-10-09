import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../settings/config_widgets.dart' show NumberField;
import 'web_common.dart';

/// « Mode de vente » : shop / catalogue (devis) / showcase, minimum order,
/// what the visitors see of the stock.
class ModeSection extends StatefulWidget {
  const ModeSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<ModeSection> createState() => _ModeSectionState();
}

class _ModeSectionState extends State<ModeSection> {
  Map<String, dynamic> get _p => widget.ctx.store.policy;

  late String _mode = switch (_p['mode']) {
    'shop' || 'catalog' || 'showcase' || 'pro' => _p['mode'] as String,
    _ => _p['show_prices'] == false ? 'showcase' : 'shop',
  };
  late String _qtyMode = ['labels', 'exact', 'hidden'].contains(_p['qty_mode'])
      ? _p['qty_mode'] as String
      : 'labels';
  late final _lowStock = TextEditingController(
      text: fmtQty((_p['low_stock_milli'] as num?)?.toInt() ?? 5000));
  late final _proNote =
      TextEditingController(text: '${widget.ctx.store.theme['pro_note'] ?? ''}');
  final _minOrder = TextEditingController();

  Map<String, dynamic>? _delivery;
  bool _deliveryLoaded = false;
  String? _deliveryError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDelivery();
  }

  @override
  void dispose() {
    _lowStock.dispose();
    _proNote.dispose();
    _minOrder.dispose();
    super.dispose();
  }

  Future<void> _loadDelivery() async {
    try {
      final (d, _) = await widget.ctx.client.webDelivery();
      _delivery = d;
      final m = (d?['min_order_centimes'] as num?)?.toInt() ?? 0;
      _minOrder.text = m > 0 ? editDA(m) : '';
      _deliveryLoaded = true;
      _deliveryError = null;
    } catch (e) {
      _deliveryError = errText(e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final low = parseQty(_lowStock.text);
    if (low == null || low < 0) {
      showToast(context, 'Seuil « stock faible » invalide.', kind: ToastKind.warning);
      return;
    }
    final min = _minOrder.text.trim().isEmpty ? 0 : parseDA(_minOrder.text);
    if (min == null || min < 0) {
      showToast(context, 'Commande minimum invalide.', kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await widget.ctx.client.webConfig({
        'policy': {'mode': _mode, 'qty_mode': _qtyMode, 'low_stock_milli': low},
        if (_mode == 'pro') 'theme': {'pro_note': _proNote.text.trim()},
      });
      widget.ctx.onStore(s);
      // The minimum order lives in the delivery settings (§10).
      if (_deliveryLoaded) {
        final cur = (_delivery?['min_order_centimes'] as num?)?.toInt() ?? 0;
        if (cur != min) {
          final d = Map<String, dynamic>.from(_delivery ?? {'enabled': false});
          if (min > 0) {
            d['min_order_centimes'] = min;
          } else {
            d.remove('min_order_centimes');
          }
          await widget.ctx.client.webPutDelivery(d);
          _delivery = d;
        }
      }
      if (mounted) showToast(context, 'Mode de vente enregistré.');
    } catch (e) {
      if (mounted) toastError(context, 'Enregistrement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _modeCard(String value, IconData icon, String title, String text) {
    final sel = _mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(T.rCard),
      onTap: () => setState(() => _mode = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: sel ? T.mintTint : T.surface,
          borderRadius: BorderRadius.circular(T.rCard),
          border: Border.all(color: sel ? T.mintDeep : T.border, width: sel ? 1.6 : 1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: sel ? T.mintDeep : T.faint, size: 22),
          const SizedBox(width: 12),
          Icon(icon, color: T.muted, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(text, style: T.bodyMuted),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebPane(
      title: 'Mode de vente',
      intro: 'Comment vos clients achètent sur le site.',
      actions: [
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      children: [
        WebBlock(title: 'Que peuvent faire les visiteurs ?', children: [
          _modeCard('shop', Icons.shopping_cart_outlined, 'Boutique',
              'Prix affichés, panier, commande payée à la livraison. Les codes promo s’appliquent.'),
          _modeCard('catalog', Icons.request_quote_outlined, 'Catalogue avec devis',
              'Prix affichés, mais le panier devient une « Demande de devis ». Vous rappelez '
                  'le client pour confirmer. Idéal pour la vente aux professionnels.'),
          _modeCard('showcase', Icons.storefront_outlined, 'Vitrine',
              'Pas de prix ni de panier. Chaque produit a un bouton WhatsApp ou Appeler '
                  'pour vous contacter.'),
          if (_mode == 'pro') ...[
            _modeCard('pro', Icons.badge_outlined, 'Espace professionnel (bientôt)',
                'Pour l’instant identique à « Catalogue avec devis », avec un bandeau.'),
            LabeledField(
                label: 'Texte du bandeau professionnel',
                controller: _proNote,
                maxLines: 2,
                help: '300 caractères maximum.'),
          ],
        ]),
        WebBlock(
          title: 'Commande minimum',
          help: 'Montant minimum des articles pour passer commande (ou demander un devis). '
              'Laissez vide pour aucun minimum.',
          children: [
            if (_deliveryError != null)
              InfoBanner(
                  kind: ToastKind.error,
                  text: 'Réglage indisponible : $_deliveryError',
                  actions: [
                    TextButton(onPressed: _loadDelivery, child: const Text('Réessayer'))
                  ])
            else
              NumberField(
                label: 'Commande minimum',
                controller: _minOrder,
                suffix: 'DA',
                decimals: true,
                enabled: _deliveryLoaded,
              ),
          ],
        ),
        WebBlock(title: 'Stock affiché', children: [
          ChoiceRow<String>(
            label: 'Quantités en stock',
            value: _qtyMode,
            options: const [
              ('labels', 'Étiquettes (En stock / Stock faible / Rupture)'),
              ('exact', 'Quantités exactes'),
              ('hidden', 'Ne rien afficher'),
            ],
            onChanged: (v) => setState(() => _qtyMode = v),
          ),
          if (_qtyMode == 'labels')
            NumberField(
              label: '« Stock faible » à partir de',
              controller: _lowStock,
              decimals: true,
              suffix: 'unités',
              help: 'En dessous de cette quantité, le site affiche « Stock faible ».',
            ),
        ]),
      ],
    );
  }
}
