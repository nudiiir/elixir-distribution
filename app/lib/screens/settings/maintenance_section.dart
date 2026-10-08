import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres → Maintenance (admin): export everything, reset the data.
class MaintenanceSection extends StatefulWidget {
  const MaintenanceSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<MaintenanceSection> createState() => _MaintenanceSectionState();
}

class _MaintenanceSectionState extends State<MaintenanceSection> {
  bool _exporting = false;
  bool _resetting = false;
  String _scope = 'transactions';
  String? _lastExport;

  ApiClient get _api => widget.ctx.api;

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final bytes = await _api.exportAllData();
      final home = Platform.environment['USERPROFILE'] ?? '.';
      final dir = Directory('$home\\Documents\\Elixir\\exports');
      await dir.create(recursive: true);
      final d = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final f = File('${dir.path}\\elixir-donnees-${d.year}${two(d.month)}${two(d.day)}-'
          '${two(d.hour)}${two(d.minute)}${two(d.second)}.zip');
      await f.writeAsBytes(bytes, flush: true);
      Process.run('explorer.exe', ['/select,${f.path}']);
      if (!mounted) return;
      setState(() => _lastExport = f.path);
      showToast(context, 'Export enregistré dans Documents\\Elixir\\exports.',
          actionLabel: 'Ouvrir le dossier', onAction: () => Process.run('explorer.exe', ['/select,${f.path}']));
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Export impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _reset() async {
    final all = _scope == 'all';
    final ok = await confirmTyped(
      context,
      title: all ? 'Tout effacer sauf les utilisateurs et les paramètres ?' : 'Effacer les ventes, achats et mouvements ?',
      message: all
          ? 'Seront effacés : produits, catégories, clients, fournisseurs, ventes, achats, stock, '
              'caisses, paiements, cartes cadeaux.\nSeront gardés : utilisateurs, dépôts, paramètres, '
              'modèles d’impression, journal d’activité.'
          : 'Seront effacés : ventes, achats, devis, bons, mouvements et niveaux de stock, caisses, '
              'paiements, soldes des clients et fournisseurs, cartes cadeaux, lots.\nSeront gardés : '
              'produits, clients, fournisseurs, utilisateurs, dépôts, paramètres.',
      word: 'RÉINITIALISER',
      alsoAccepted: const ['REINITIALISER'],
      confirmLabel: 'Réinitialiser',
    );
    if (!ok) return;
    setState(() => _resetting = true);
    try {
      final (backup, deleted) = await _api.resetData(_scope);
      await Features.instance.load(_api);
      if (!mounted) return;
      final total = deleted.values.fold<int>(0, (a, b) => a + b);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.surface,
          title: const Text('Réinitialisation terminée', style: T.h2),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$total ligne(s) effacée(s).', style: T.body),
              const SizedBox(height: 10),
              Text('Les données d’avant ont été sauvegardées sous :', style: T.bodyMuted),
              const SizedBox(height: 4),
              SelectableText(backup, style: T.monoBody),
              const SizedBox(height: 10),
              Text('Pour revenir en arrière : Paramètres → Sauvegardes → restaurer cette sauvegarde.',
                  style: T.bodyMuted),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Fermer'))],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  Widget _scopeOption(String value, String title, String text) => InkWell(
        borderRadius: BorderRadius.circular(T.rInner),
        onTap: () => setState(() => _scope = value),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: _scope == value ? T.danger : T.border),
            color: _scope == value ? T.dangerTint : T.surface,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                _scope == value ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: _scope == value ? T.dangerDark : T.muted,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 6),
                Text(title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(text, style: T.bodyMuted),
              ]),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Maintenance',
      intro: 'Récupérer toutes vos données, ou repartir de zéro (par exemple après une période d’essai).',
      children: [
        PageSection(
          title: 'Exporter toutes les données',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'Un fichier ZIP avec des tableaux Excel (CSV) : produits, clients et fournisseurs, '
                'documents et leurs lignes, stock, mouvements de stock, paiements. Utile pour votre '
                'comptable ou pour garder une trace hors du logiciel.',
                style: T.bodyMuted),
            const SizedBox(height: 14),
            Row(children: [
              PageAction(
                label: _exporting ? 'Export en cours…' : 'Exporter toutes les données',
                icon: Icons.download_rounded,
                primary: true,
                onPressed: _exporting ? null : _export,
              ),
            ]),
            if (_lastExport != null) ...[
              const SizedBox(height: 10),
              SelectableText(_lastExport!, style: T.monoSmall),
            ],
          ]),
        ),
        PageSection(
          title: 'Réinitialiser les données',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const InfoBanner(
              kind: ToastKind.warning,
              icon: Icons.warning_amber_rounded,
              text: 'Une sauvegarde complète est faite automatiquement juste avant : vous pourrez '
                  'revenir en arrière depuis « Sauvegardes ». Clôturez la caisse avant de commencer.',
            ),
            const FieldLabel('Que voulez-vous effacer ?', required: true),
            const SizedBox(height: 8),
            _scopeOption(
              'transactions',
              'Effacer les ventes, achats et mouvements',
              'Garder les produits, clients, fournisseurs, utilisateurs et paramètres. Le stock '
                  'revient à zéro.',
            ),
            _scopeOption(
              'all',
              'Tout effacer sauf les utilisateurs et les paramètres',
              'Produits, clients et fournisseurs sont effacés aussi. Les utilisateurs, dépôts et '
                  'paramètres restent.',
            ),
            const SizedBox(height: 6),
            Row(children: [
              PageAction(
                label: _resetting ? 'Réinitialisation…' : 'Réinitialiser…',
                icon: Icons.delete_forever_outlined,
                danger: true,
                onPressed: _resetting ? null : _reset,
              ),
            ]),
          ]),
        ),
      ],
    );
  }
}
