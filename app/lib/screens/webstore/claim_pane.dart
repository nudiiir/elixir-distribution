import 'package:flutter/material.dart';

import '../../api/cloud.dart';
import '../../theme/tokens.dart';
import '../../widgets/ui.dart';
import 'web_common.dart';

/// First visit: choose the store address and name.
class ClaimPane extends StatefulWidget {
  const ClaimPane({super.key, required this.client, required this.onClaimed});
  final CloudClient client;
  final ValueChanged<WebStore> onClaimed;

  @override
  State<ClaimPane> createState() => _ClaimPaneState();
}

class _ClaimPaneState extends State<ClaimPane> {
  final _slug = TextEditingController();
  final _name = TextEditingController();
  String? _hint;
  bool? _available;
  bool _busy = false;

  @override
  void dispose() {
    _slug.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final slug = _slug.text.trim().toLowerCase();
    if (slug.isEmpty) return;
    setState(() {
      _busy = true;
      _hint = null;
      _available = null;
    });
    try {
      final (ok, reason) = await widget.client.webCheckSlug(slug);
      _available = ok;
      _hint = ok ? 'Disponible !' : (reason ?? 'Déjà pris.');
    } catch (e) {
      _hint = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _claim() async {
    final slug = _slug.text.trim().toLowerCase();
    final name = _name.text.trim();
    if (slug.isEmpty || name.isEmpty) {
      setState(() => _hint = 'Choisissez une adresse ET un nom de boutique.');
      return;
    }
    setState(() => _busy = true);
    try {
      final store = await widget.client.webClaim(slug, name);
      widget.onClaimed(store);
    } catch (e) {
      if (mounted) {
        setState(() {
          _hint = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card14(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.storefront_rounded, size: 38, color: T.mintDeep),
            const SizedBox(height: 10),
            Text('Créez la boutique en ligne du magasin', style: T.h2),
            const SizedBox(height: 6),
            Text(
                'Votre stock devient un site web où vos clients commandent '
                '(paiement à la livraison). Le site reste en ligne même quand '
                'ce PC est éteint.',
                style: T.bodyMuted.copyWith(height: 1.5),
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            webField('Nom de la boutique', _name,
                required: true, help: 'Affiché en haut du site.'),
            const SizedBox(height: 12),
            webField(
              'Adresse du site',
              _slug,
              required: true,
              hint: 'mon-magasin',
              suffix: '.shops.example.com',
              help: 'Lettres minuscules, chiffres et tirets.',
              onChanged: (_) => setState(() {
                _available = null;
                _hint = null;
              }),
            ),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_hint!,
                    style: T.small.copyWith(
                        color: _available == true ? T.mintDeep : T.dangerDark,
                        fontWeight: FontWeight.w700)),
              ),
            ],
            const SizedBox(height: 16),
            Row(children: [
              OutlinedButton(
                  onPressed: _busy ? null : _check,
                  child: const Text('Vérifier la disponibilité')),
              const Spacer(),
              PrimaryButton(
                  label: _busy ? '…' : 'Créer ma boutique',
                  onPressed: _busy ? null : _claim),
            ]),
          ]),
        ),
      ),
    );
  }
}
