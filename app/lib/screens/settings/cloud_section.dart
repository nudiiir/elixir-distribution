import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/cloud.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/cloud_card.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres → Cloud et téléphone: shop connection, phone pairing, and the
/// online store's address / status (managed in the « Boutique en ligne » module).
class CloudSection extends StatefulWidget {
  const CloudSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<CloudSection> createState() => _CloudSectionState();
}

class _CloudSectionState extends State<CloudSection> {
  bool _loading = true;
  CloudConfig? _cloud;
  WebStore? _store;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStore();
  }

  Future<void> _loadStore() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cloud = await widget.ctx.api.cloudStatus();
      WebStore? store;
      if (cloud.webReady && widget.ctx.api.token != null) {
        store = await CloudClient(config: cloud, token: widget.ctx.api.token!).webStore();
      }
      if (!mounted) return;
      setState(() {
        _cloud = cloud;
        _store = store;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Widget _storeBody() {
    if (!Features.instance.webstore) {
      return Text(
          'La boutique en ligne est désactivée dans « Profil du magasin ». Activez-la pour '
          'publier vos produits sur Internet.',
          style: T.bodyMuted);
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: T.mint)),
      );
    }
    if (_error != null) {
      return InfoBanner(
        kind: ToastKind.error,
        text: 'État de la boutique indisponible : $_error',
        actions: [PageAction(label: 'Réessayer', icon: Icons.refresh_rounded, onPressed: _loadStore)],
      );
    }
    if (_cloud?.webReady != true) {
      return Text(
          'Connectez d’abord le magasin (ci-dessus) : la boutique en ligne passe par cette connexion.',
          style: T.bodyMuted);
    }
    final s = _store;
    if (s == null || s.url.isEmpty) {
      return Text(
          'Pas encore de boutique. Ouvrez le module « Boutique en ligne » du menu pour choisir son '
          'adresse et publier vos produits.',
          style: T.bodyMuted);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FactGrid(facts: [
        ('Adresse', s.url),
        ('Nom', s.name),
        ('Publication', s.publishedAt == null ? 'Pas encore publiée' : 'Publiée le ${fmtDateTime(s.publishedAt!)}'),
        ('Produits visibles', '${s.visibleCount} sur ${s.productCount}'),
        ('Commandes à traiter', '${s.pendingOrders}'),
      ]),
      const SizedBox(height: 14),
      Wrap(runSpacing: 8, children: [
        PageAction(
          label: 'Ouvrir la boutique en ligne',
          icon: Icons.open_in_new_rounded,
          onPressed: () => Process.run('rundll32', ['url.dll,FileProtocolHandler', s.url]),
        ),
        PageAction(label: 'Actualiser', icon: Icons.refresh_rounded, onPressed: _loadStore),
      ]),
      const SizedBox(height: 10),
      Text('Les produits, le thème et les commandes se gèrent dans le module « Boutique en ligne » du menu.',
          style: T.small),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Cloud et téléphone',
      intro: 'Connectez le magasin pour utiliser l’application mobile, l’assistant, le scan de '
          'factures et la boutique en ligne. Le logiciel fonctionne normalement sans.',
      children: [
        CloudCard(api: widget.ctx.api),
        const SizedBox(height: 16),
        PageSection(title: 'Boutique en ligne', child: _storeBody()),
      ],
    );
  }
}
