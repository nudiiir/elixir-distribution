import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'web_common.dart';

/// « Vue d’ensemble » : address, counters, open / pause the store.
class OverviewSection extends StatefulWidget {
  const OverviewSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<OverviewSection> {
  late final _message =
      TextEditingController(text: widget.ctx.store.statusMessage ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _setStatus(String status) async {
    final msg = _message.text.trim();
    if (status == 'paused') {
      final ok = await confirmAction(context,
          title: 'Mettre la boutique en pause ?',
          message: 'Les visiteurs verront une page « Fermé temporairement »'
              '${msg.isEmpty ? '' : ' avec votre message'} et ne pourront plus '
              'commander. Vous pourrez la rouvrir à tout moment.',
          confirmLabel: 'Mettre en pause');
      if (!ok) return;
    }
    if (msg.length > 500) {
      if (mounted) showToast(context, 'Message trop long (500 caractères max).', kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await widget.ctx.client.webSetStatus(status,
          message: msg.isEmpty ? null : msg, clearMessage: msg.isEmpty);
      widget.ctx.onStore(s);
      widget.ctx.reload();
      if (mounted) {
        showToast(context,
            status == 'paused' ? 'Boutique en pause.' : 'Boutique rouverte.');
      }
    } catch (e) {
      if (mounted) toastError(context, 'Changement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _stat(String label, String value, {VoidCallback? onTap, String? action}) {
    return SizedBox(
      width: 200,
      child: Card14(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: T.label),
          const SizedBox(height: 6),
          Text(value, style: T.monoBig.copyWith(fontSize: 24)),
          if (onTap != null) ...[
            const SizedBox(height: 4),
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: onTap,
              child: Text(action ?? 'Ouvrir'),
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final s = ctx.store;
    final paused = s.status == 'paused';
    final suspended = s.status == 'suspended';
    final preview = s.previewUrl == null || s.previewUrl!.isEmpty
        ? null
        : '${ctx.client.config.webUrl}${s.previewUrl}';
    return WebPane(
      title: 'Vue d’ensemble',
      intro: 'Votre boutique en ligne en un coup d’œil.',
      children: [
        WebBlock(title: 'Adresse du site', children: [
          Row(children: [
            Expanded(
              child: SelectableText(s.publicUrl,
                  style: T.h2.copyWith(fontSize: 16, color: T.mintDark)),
            ),
            PageAction(
                label: 'Copier',
                icon: Icons.copy_rounded,
                onPressed: () => copyText(context, s.publicUrl, what: 'Adresse copiée')),
            PageAction(
                label: 'Ouvrir',
                icon: Icons.open_in_new_rounded,
                onPressed: () => openWebUrl(s.publicUrl)),
          ]),
          if (s.publicUrl != s.url) ...[
            const SizedBox(height: 6),
            Text('Adresse de secours : ${s.url}', style: T.small),
          ],
          if (preview != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                    'Aperçu privé (non référencé par Google) : $preview',
                    style: T.small),
              ),
              TextButton(
                  onPressed: () => openWebUrl(preview),
                  child: const Text('Ouvrir l’aperçu')),
            ]),
          ],
          const SizedBox(height: 8),
          Text(
              s.publishedAt == null
                  ? 'Catalogue jamais publié — cliquez « Publier le catalogue » à gauche.'
                  : 'Catalogue publié le ${fmtDateTime(s.publishedAt!)}.',
              style: T.bodyMuted),
        ]),
        Wrap(spacing: 14, runSpacing: 14, children: [
          _stat('Produits visibles', '${s.visibleCount} / ${s.productCount}',
              onTap: () => ctx.open('products'), action: 'Choisir les produits'),
          _stat('Commandes à traiter', '${s.pendingOrders}',
              onTap: () => ctx.open('orders'), action: 'Voir les commandes'),
          _stat('Demandes de devis', '${s.pendingQuotes}',
              onTap: () => ctx.open('orders'), action: 'Voir les demandes'),
          _stat('Alertes « Prévenez-moi »', '${s.openAlerts}',
              onTap: () => ctx.open('alerts'), action: 'Voir les alertes'),
        ]),
        const SizedBox(height: 16),
        WebBlock(
          title: suspended
              ? 'Boutique suspendue'
              : (paused ? 'La boutique est en pause' : 'La boutique est ouverte'),
          help: suspended
              ? 'La plateforme a suspendu cette boutique. Contactez le support Elixir.'
              : (paused
                  ? 'Les visiteurs voient une page « Fermé temporairement » avec votre message et vos contacts. Personne ne peut commander.'
                  : 'Les visiteurs peuvent consulter et commander. Mettez en pause pendant un inventaire, des congés…'),
          trailing: StatusPill(
              suspended ? 'Suspendue' : (paused ? 'En pause' : 'Ouverte'),
              kind: paused || suspended ? ToastKind.warning : ToastKind.success),
          children: [
            LabeledField(
              label: 'Message affiché pendant la pause',
              controller: _message,
              maxLines: 3,
              hint: 'ex. Inventaire annuel, retour lundi.',
              help: '500 caractères maximum. Laissez vide pour le message standard.',
              enabled: !suspended,
            ),
            if (!suspended)
              Row(children: [
                if (paused)
                  PrimaryButton(
                      label: _busy ? '…' : 'Rouvrir la boutique',
                      onPressed: _busy ? null : () => _setStatus('active'))
                else
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        foregroundColor: T.warnDark,
                        side: const BorderSide(color: T.warn)),
                    onPressed: _busy ? null : () => _setStatus('paused'),
                    icon: const Icon(Icons.pause_circle_outline_rounded, size: 18),
                    label: const Text('Mettre la boutique en pause'),
                  ),
                if (paused) ...[
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _setStatus('paused'),
                    child: const Text('Enregistrer le message'),
                  ),
                ],
              ]),
          ],
        ),
      ],
    );
  }
}
