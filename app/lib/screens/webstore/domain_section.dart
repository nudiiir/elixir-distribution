import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/ui.dart';
import 'web_common.dart';

/// « Domaine » : use your own address (boutique.mon-magasin.dz) — enter it,
/// create the DNS records at your registrar, click « Vérifier ».
class DomainSection extends StatefulWidget {
  const DomainSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<DomainSection> createState() => _DomainSectionState();
}

class _DomainSectionState extends State<DomainSection> {
  Future<WebDomain>? _future;
  WebDomain? _d;
  final _domain = TextEditingController();
  bool _busy = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _domain.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = widget.ctx.client.webDomain().then((d) {
        _d = d;
        _domain.text = d.domain ?? '';
        _editing = d.domain == null || d.domain!.isEmpty;
        return d;
      });
    });
  }

  Future<void> _run(Future<WebDomain> Function() f, String ok) async {
    setState(() => _busy = true);
    try {
      final d = await f();
      _d = d;
      _future = Future.value(d);
      _editing = false;
      await widget.ctx.reload();
      if (mounted) showToast(context, ok);
    } catch (e) {
      if (mounted) toastError(context, 'Action impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setDomain() async {
    var v = _domain.text.trim().toLowerCase();
    v = v.replaceFirst(RegExp(r'^https?://'), '');
    v = v.split('/').first;
    if (!RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(v)) {
      showToast(context, 'Adresse invalide. Exemple : boutique.mon-magasin.dz',
          kind: ToastKind.warning);
      return;
    }
    if (_d?.domain != null && _d!.domain != v && _d!.status == 'verified') {
      final ok = await confirmAction(context,
          title: 'Changer de domaine ?',
          message: 'L’ancien domaine cessera de fonctionner et le nouveau devra être vérifié.',
          confirmLabel: 'Changer');
      if (!ok) return;
    }
    await _run(() => widget.ctx.client.webPutDomain(v),
        'Domaine enregistré — créez maintenant les enregistrements DNS.');
  }

  Future<void> _verify() async {
    await _run(widget.ctx.client.webVerifyDomain, 'Vérification terminée.');
  }

  Future<void> _remove() async {
    final ok = await confirmAction(context,
        title: 'Retirer le domaine ?',
        message: 'La boutique ne répondra plus sur ${_d?.domain}. Elle reste '
            'accessible à ${widget.ctx.store.url}.',
        confirmLabel: 'Retirer le domaine',
        danger: true);
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await widget.ctx.client.webDeleteDomain();
      await widget.ctx.reload();
      if (mounted) showToast(context, 'Domaine retiré.');
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Action impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _record(String type, String name, String value, String help) {
    Widget cell(String label, String v) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: T.label),
            const SizedBox(height: 3),
            Row(children: [
              Flexible(child: SelectableText(v, style: T.monoBody)),
              IconButton(
                tooltip: 'Copier',
                icon: const Icon(Icons.copy_rounded, size: 16),
                onPressed: () => copyText(context, v, what: '« $v » copié'),
              ),
            ]),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 90,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Type', style: T.label),
              const SizedBox(height: 3),
              Text(type, style: T.monoBody.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
          cell('Nom (hôte)', name),
          const SizedBox(width: 12),
          cell(type == 'CNAME' ? 'Cible (valeur)' : 'Valeur', value),
        ]),
        Text(help, style: T.small),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebLoader<WebDomain>(
      future: _future,
      onRetry: _reload,
      builder: (_) {
        final d = _d!;
        final has = d.domain != null && d.domain!.isNotEmpty;
        final verified = d.status == 'verified';
        final check = d.check;
        final details = [for (final x in (check?['details'] as List? ?? const [])) '$x'];
        final apex = has && d.domain!.split('.').length == 2;
        return WebPane(
          title: 'Domaine',
          intro: 'Utilisez votre propre adresse (ex. boutique.mon-magasin.dz) au lieu de '
              '${Uri.tryParse(widget.ctx.store.url)?.host ?? widget.ctx.store.url}.',
          children: [
            WebBlock(
              title: '1. Votre adresse',
              trailing: has
                  ? StatusPill(
                      switch (d.status) {
                        'verified' => 'Vérifié',
                        'pending' => 'En attente de vérification',
                        _ => 'Non configuré',
                      },
                      kind: verified ? ToastKind.success : ToastKind.warning)
                  : null,
              children: [
                if (!_editing && has)
                  Row(children: [
                    Expanded(
                        child: SelectableText(d.domain!,
                            style: T.h2.copyWith(color: T.mintDark))),
                    PageAction(
                        label: 'Changer',
                        onPressed: _busy ? null : () => setState(() => _editing = true)),
                    PageAction(
                        label: 'Retirer le domaine',
                        danger: true,
                        onPressed: _busy ? null : _remove),
                  ])
                else ...[
                  LabeledField(
                    label: 'Nom de domaine',
                    controller: _domain,
                    hint: 'boutique.mon-magasin.dz',
                    help: 'Achetez d’abord le domaine chez un registraire (ex. un hébergeur .dz '
                        'ou international). Un sous-domaine (boutique.…) est le plus simple.',
                    onSubmitted: (_) => _setDomain(),
                  ),
                  Row(children: [
                    PrimaryButton(
                        label: _busy ? '…' : 'Enregistrer le domaine',
                        onPressed: _busy ? null : _setDomain),
                    if (has) ...[
                      const SizedBox(width: 10),
                      TextButton(
                          onPressed: () => setState(() {
                                _editing = false;
                                _domain.text = d.domain!;
                              }),
                          child: const Text('Annuler')),
                    ],
                  ]),
                ],
              ],
            ),
            if (has && !_editing) ...[
              WebBlock(
                title: '2. Créez ces enregistrements DNS',
                help: 'Chez votre registraire, ouvrez la « zone DNS » du domaine et ajoutez '
                    'les deux lignes ci-dessous (boutons de copie à droite). La prise en compte '
                    'peut prendre de quelques minutes à quelques heures.',
                children: [
                  if (d.txtName != null && d.txtValue != null)
                    _record('TXT', d.txtName!, d.txtValue!,
                        'Prouve que le domaine vous appartient.'),
                  if (d.cnameName != null && d.cnameTarget != null)
                    _record('CNAME', d.cnameName!, d.cnameTarget!,
                        'Envoie les visiteurs vers votre boutique.'),
                  if (apex)
                    const InfoBanner(
                      kind: ToastKind.warning,
                      text: 'Domaine principal (sans « www » ni « boutique. ») : beaucoup de '
                          'registraires refusent un CNAME à la racine. Utilisez plutôt un '
                          'sous-domaine, ou demandez au support Elixir l’adresse IP à mettre '
                          'en enregistrement A.',
                    ),
                ],
              ),
              WebBlock(
                title: '3. Vérifiez',
                children: [
                  if (verified)
                    InfoBanner(
                      kind: ToastKind.success,
                      icon: Icons.verified_rounded,
                      title: 'Domaine vérifié',
                      text: 'Votre boutique répond sur ${d.domain}. Le certificat HTTPS '
                          '(cadenas) est activé par la plateforme Elixir après la '
                          'vérification : cela peut prendre un petit moment. Si le navigateur '
                          'affiche une alerte de sécurité, réessayez un peu plus tard.',
                      actions: [
                        OutlinedButton(
                            onPressed: () => openWebUrl(d.url ?? 'https://${d.domain}'),
                            child: const Text('Ouvrir le site')),
                      ],
                    )
                  else
                    Text(
                        'Quand les enregistrements sont créés, cliquez « Vérifier ». Rien ne '
                        'change pour vos clients tant que la vérification n’a pas réussi.',
                        style: T.bodyMuted),
                  const SizedBox(height: 12),
                  if (check != null) ...[
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      StatusPill(check['txt_ok'] == true ? 'TXT trouvé' : 'TXT non trouvé',
                          kind: check['txt_ok'] == true ? ToastKind.success : ToastKind.error),
                      StatusPill(check['cname_ok'] == true ? 'CNAME correct' : 'CNAME non trouvé',
                          kind: check['cname_ok'] == true ? ToastKind.success : ToastKind.error),
                      if (check['points_to_platform'] == true)
                        const StatusPill('Pointe vers la plateforme', kind: ToastKind.success),
                    ]),
                    for (final x in details)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('• $x', style: T.small),
                      ),
                    if (d.checkedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Dernière vérification : ${fmtDateTime(d.checkedAt!)}',
                            style: T.small),
                      ),
                    const SizedBox(height: 12),
                  ],
                  PrimaryButton(
                      label: _busy ? 'Vérification…' : (verified ? 'Vérifier à nouveau' : 'Vérifier'),
                      onPressed: _busy ? null : _verify),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
