import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/list_toolbar.dart';
import '../settings/config_widgets.dart' show NumberField;
import 'web_common.dart';

/// « Promotions » : promo codes typed at checkout, and quantity offers
/// (« 10 + 1 offert », « −5 % dès 20 ») published from the shop's rules.
class PromosSection extends StatefulWidget {
  const PromosSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<PromosSection> createState() => _PromosSectionState();
}

class _PromosSectionState extends State<PromosSection> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const WebPaneHeader(
          title: 'Promotions',
          intro: 'Codes promo à saisir au panier, et offres par quantité affichées sur les produits.',
        ),
        const SizedBox(height: 14),
        Row(children: [
          FilterPill(label: 'Codes promo', active: _tab == 0, onTap: () => setState(() => _tab = 0)),
          FilterPill(
              label: 'Offres par quantité', active: _tab == 1, onTap: () => setState(() => _tab = 1)),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: _tab == 0 ? _CodesTab(ctx: widget.ctx) : _VolumeTab(ctx: widget.ctx),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Promo codes
// ---------------------------------------------------------------------------

String promoValueText(WebPromoCode p) => switch (p.type) {
      'percent' => '−${p.value} %',
      'fixed' => '−${fmtDA(p.value)}',
      _ => 'Livraison offerte',
    };

class _CodesTab extends StatefulWidget {
  const _CodesTab({required this.ctx});
  final WebCtx ctx;

  @override
  State<_CodesTab> createState() => _CodesTabState();
}

class _CodesTabState extends State<_CodesTab> {
  Future<List<WebPromoCode>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _future = widget.ctx.client.webPromoCodes());

  Future<void> _edit([WebPromoCode? p]) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PromoCodeEditor(ctx: widget.ctx, promo: p),
    ));
    if (changed == true) _reload();
  }

  Future<void> _toggle(WebPromoCode p, bool active) async {
    try {
      await widget.ctx.client.webSavePromoCode({'active': active}, id: p.id);
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Modification impossible', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebLoader<List<WebPromoCode>>(
      future: _future,
      onRetry: _reload,
      builder: (items) {
        if (items.isEmpty) {
          return WebNotice(
              icon: Icons.local_offer_outlined,
              title: 'Aucun code promo',
              body: 'Créez un code (ex. BIENVENUE : −10 %) à partager sur vos réseaux. '
                  'Le client le saisit dans son panier.',
              action: ('Nouveau code promo', () => _edit()));
        }
        final mode = '${widget.ctx.store.policy['mode'] ?? ''}';
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (mode == 'catalog' || mode == 'showcase')
            const InfoBanner(
                kind: ToastKind.warning,
                text: 'Votre boutique n’est pas en mode « Boutique » : les codes promo '
                    'ne s’appliquent pas aux demandes de devis.'),
          Row(children: [
            Text('${items.length} code(s)', style: T.bodyMuted),
            const Spacer(),
            PageAction(
                label: 'Nouveau code promo',
                icon: Icons.add_rounded,
                primary: true,
                onPressed: () => _edit()),
          ]),
          const SizedBox(height: 10),
          const Row(children: [
            Expanded(flex: 2, child: Text('Code', style: T.label)),
            Expanded(flex: 2, child: Text('Remise', style: T.label)),
            Expanded(flex: 2, child: Text('Minimum', style: T.label)),
            Expanded(flex: 3, child: Text('Validité', style: T.label)),
            Expanded(flex: 2, child: Text('Utilisations', style: T.label)),
            SizedBox(width: 80, child: Text('Actif', style: T.label)),
            SizedBox(width: 110),
          ]),
          const Divider(),
          Expanded(
            child: ListView(children: [
              for (final p in items)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: T.border))),
                  child: Row(children: [
                    Expanded(
                        flex: 2,
                        child: Text(p.code,
                            style: T.monoBody.copyWith(fontWeight: FontWeight.w700))),
                    Expanded(flex: 2, child: Text(promoValueText(p), style: T.body)),
                    Expanded(
                        flex: 2,
                        child: Text(p.minOrderCentimes > 0 ? fmtDA(p.minOrderCentimes) : '—',
                            style: T.body)),
                    Expanded(
                      flex: 3,
                      child: Text(
                          [
                            if (p.startsAt != null) 'du ${fmtDay(p.startsAt)}',
                            if (p.endsAt != null) 'au ${fmtDay(p.endsAt)}',
                          ].join(' ').ifEmpty('Sans limite'),
                          style: T.body),
                    ),
                    Expanded(
                        flex: 2,
                        child: Text(p.maxUses == null ? '${p.uses}' : '${p.uses} / ${p.maxUses}',
                            style: T.monoBody)),
                    SizedBox(
                      width: 80,
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: Switch(value: p.active, onChanged: (v) => _toggle(p, v))),
                    ),
                    SizedBox(
                      width: 110,
                      child: OutlinedButton(
                          onPressed: () => _edit(p), child: const Text('Modifier')),
                    ),
                  ]),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Detail page of one promo code.
class PromoCodeEditor extends StatefulWidget {
  const PromoCodeEditor({super.key, required this.ctx, this.promo});
  final WebCtx ctx;
  final WebPromoCode? promo;

  @override
  State<PromoCodeEditor> createState() => _PromoCodeEditorState();
}

class _PromoCodeEditorState extends State<PromoCodeEditor> {
  WebPromoCode? get _p => widget.promo;
  late final _code = TextEditingController(text: _p?.code ?? '');
  late String _type = _p?.type ?? 'percent';
  late final _value = TextEditingController(
      text: _p == null
          ? ''
          : (_p!.type == 'fixed' ? editDA(_p!.value) : (_p!.type == 'percent' ? '${_p!.value}' : '')));
  late final _min = TextEditingController(
      text: (_p?.minOrderCentimes ?? 0) > 0 ? editDA(_p!.minOrderCentimes) : '');
  late final _maxUses = TextEditingController(text: _p?.maxUses?.toString() ?? '');
  late DateTime? _start = DateTime.tryParse(_p?.startsAt ?? '')?.toLocal();
  late DateTime? _end = DateTime.tryParse(_p?.endsAt ?? '')?.toLocal();
  late bool _active = _p?.active ?? true;
  bool _busy = false;
  final _errors = <String, String>{};

  @override
  void dispose() {
    _code.dispose();
    _value.dispose();
    _min.dispose();
    _maxUses.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _errors.clear();
    final code = _code.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{2,32}$').hasMatch(code)) {
      _errors['code'] = '2 à 32 caractères : lettres, chiffres, _ ou -.';
    }
    int? value;
    if (_type == 'percent') {
      value = int.tryParse(_value.text.trim());
      if (value == null || value < 1 || value > 100) _errors['value'] = 'Entre 1 et 100 %.';
    } else if (_type == 'fixed') {
      value = parseDA(_value.text);
      if (value == null || value <= 0) _errors['value'] = 'Montant invalide.';
    }
    final min = _min.text.trim().isEmpty ? 0 : parseDA(_min.text);
    if (min == null || min < 0) _errors['min'] = 'Montant invalide.';
    final maxUses = _maxUses.text.trim().isEmpty ? null : int.tryParse(_maxUses.text.trim());
    if (_maxUses.text.trim().isNotEmpty && (maxUses == null || maxUses < 1)) {
      _errors['max'] = 'Nombre invalide.';
    }
    if (_start != null && _end != null && _end!.isBefore(_start!)) {
      _errors['dates'] = 'La fin est avant le début.';
    }
    setState(() {});
    if (_errors.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.ctx.client.webSavePromoCode({
        'code': code,
        'type': _type,
        'value': ?value,
        'min_order_centimes': min,
        'starts_at': _start == null
            ? null
            : DateTime(_start!.year, _start!.month, _start!.day).toUtc().toIso8601String(),
        'ends_at': _end == null
            ? null
            : DateTime(_end!.year, _end!.month, _end!.day, 23, 59, 59).toUtc().toIso8601String(),
        'max_uses': maxUses,
        'active': _active,
      }, id: _p?.id);
      if (!mounted) return;
      showToast(context, 'Code $code enregistré.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        toastError(context, 'Enregistrement impossible', e);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final ok = await confirmAction(context,
        title: 'Supprimer le code ${_p!.code} ?',
        message: 'Les clients ne pourront plus l’utiliser. Les commandes déjà passées ne changent pas.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await widget.ctx.client.webDeletePromoCode(_p!.id);
      if (!mounted) return;
      showToast(context, 'Code supprimé.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toastError(context, 'Suppression impossible', e);
    }
  }

  Widget _date(String label, DateTime? v, ValueChanged<DateTime?> set, String emptyText) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label),
        const SizedBox(height: 6),
        Row(children: [
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: v ?? DateTime.now(),
                firstDate: DateTime(2024),
                lastDate: DateTime(2100),
              );
              if (d != null) setState(() => set(d));
            },
            icon: const Icon(Icons.event_outlined, size: 17),
            label: Text(v == null ? emptyText : fmtDay(v.toIso8601String())),
          ),
          if (v != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: () => setState(() => set(null)), child: const Text('Retirer')),
          ],
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = _p == null;
    return AppPage(
      crumbs: [
        Crumb('Promotions', () => Navigator.of(context).maybePop()),
        Crumb(isNew ? 'Nouveau code' : _p!.code),
      ],
      title: isNew ? 'Nouveau code promo' : 'Code ${_p!.code}',
      subtitle: isNew
          ? null
          : Text('Utilisé ${_p!.uses} fois${_p!.maxUses == null ? '' : ' sur ${_p!.maxUses}'}.',
              style: T.bodyMuted),
      actions: [
        if (!isNew) PageAction(label: 'Supprimer', danger: true, onPressed: _delete),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      maxWidth: 760,
      body: PageSection(
        title: 'Code promo',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledField(
            label: 'Code',
            controller: _code,
            required: true,
            mono: true,
            error: _errors['code'],
            hint: 'BIENVENUE',
            help: 'Ce que le client tape dans son panier (majuscules ou minuscules, peu importe).',
          ),
          ChoiceRow<String>(
            label: 'Type de remise',
            value: _type,
            options: const [
              ('percent', 'Pourcentage'),
              ('fixed', 'Montant fixe'),
              ('free_shipping', 'Livraison offerte'),
            ],
            onChanged: (v) => setState(() => _type = v),
          ),
          if (_type != 'free_shipping')
            NumberField(
              label: _type == 'percent' ? 'Remise en %' : 'Remise en DA',
              controller: _value,
              required: true,
              suffix: _type == 'percent' ? '%' : 'DA',
              decimals: _type == 'fixed',
              error: _errors['value'],
              help: _type == 'percent'
                  ? 'Sur le total des articles.'
                  : 'Jamais plus que le total des articles.',
            ),
          NumberField(
            label: 'Commande minimum',
            controller: _min,
            suffix: 'DA',
            decimals: true,
            error: _errors['min'],
            help: 'Vide = pas de minimum.',
          ),
          Wrap(spacing: 24, children: [
            _date('Début', _start, (d) => _start = d, 'Dès maintenant'),
            _date('Fin (incluse)', _end, (d) => _end = d, 'Sans fin'),
          ]),
          if (_errors['dates'] != null) FieldError(_errors['dates']),
          NumberField(
            label: 'Nombre maximum d’utilisations',
            controller: _maxUses,
            error: _errors['max'],
            help: 'Vide = illimité. Toutes commandes confondues.',
          ),
          SwitchRow(
            title: 'Code actif',
            explanation: 'Désactivez pour suspendre le code sans le supprimer.',
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Volume rules
// ---------------------------------------------------------------------------

class _VolumeTab extends StatefulWidget {
  const _VolumeTab({required this.ctx});
  final WebCtx ctx;

  @override
  State<_VolumeTab> createState() => _VolumeTabState();
}

class _VolumeTabState extends State<_VolumeTab> {
  Future<List<Map<String, dynamic>>>? _online;
  Future<(List<Map<String, dynamic>>, List<String>)>? _local;
  Map<String, String> _names = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.ctx.products().then((ps) {
      if (mounted) setState(() => _names = {for (final Product p in ps) p.id: p.name});
    }).catchError((_) {});
  }

  void _reload() => setState(() {
        _online = widget.ctx.client.webVolumeRules();
        _local = fetchWebVolumeRules(widget.ctx.api);
      });

  String _badge(Map<String, dynamic> r) => r['label'] is String && (r['label'] as String).isNotEmpty
      ? r['label'] as String
      : (r['type'] == 'free_goods'
          ? '${r['buy_qty']} + ${r['free_qty']} offert'
          : '−${r['percent']} % dès ${r['min_qty']}');

  String _scope(Map<String, dynamic> r) {
    final v = '${r['scope_value'] ?? ''}';
    return switch (r['scope']) {
      'product' => 'Produit : ${_names[v] ?? v}',
      'category' => 'Catégorie : $v',
      'brand' => 'Marque : $v',
      _ => 'Tout le catalogue',
    };
  }

  String _dates(Map<String, dynamic> r) {
    final s = r['starts'] as String?, e = r['ends'] as String?;
    if (s == null && e == null) return 'Sans limite';
    return [if (s != null) 'du ${fmtDay(s)}', if (e != null) 'au ${fmtDay(e)}'].join(' ');
  }

  Widget _list(List<Map<String, dynamic>> rules, String empty) {
    if (rules.isEmpty) return Text(empty, style: T.bodyMuted);
    return Column(children: [
      for (final r in rules)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(
                width: 170,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: StatusPill(_badge(r), kind: ToastKind.success))),
            Expanded(child: Text(_scope(r), style: T.body, overflow: TextOverflow.ellipsis)),
            SizedBox(width: 200, child: Text(_dates(r), style: T.small)),
          ]),
        ),
    ]);
  }

  Future<void> _publish() async {
    setState(() => _busy = true);
    try {
      final (n, skipped) = await publishVolumeRulesFromServer(widget.ctx.api, widget.ctx.client);
      if (mounted) {
        showToast(
            context,
            '$n offre(s) publiée(s) sur la boutique.'
            '${skipped.isEmpty ? '' : ' Non publiées : ${skipped.join(' · ')}'}',
            kind: skipped.isEmpty ? ToastKind.success : ToastKind.warning);
      }
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Publication impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clear() async {
    final ok = await confirmAction(context,
        title: 'Retirer toutes les offres du site ?',
        message: 'Les badges « 10 + 1 offert », « −5 % dès 20 » disparaissent du site. '
            'Les promotions du magasin ne changent pas.',
        confirmLabel: 'Retirer les offres',
        danger: true);
    if (!ok) return;
    try {
      await widget.ctx.client.webPutVolumeRules(const []);
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Action impossible', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      const InfoBanner(
        text: 'Les offres se créent dans le magasin (promotions « UG » et remises par '
            'quantité, canal « Tous » ou « Web », pour tous les clients). Cliquez '
            '« Publier les offres » pour les envoyer au site ; republiez après chaque changement.',
      ),
      WebBlock(
        title: 'Offres du magasin à publier',
        trailing: PageAction(
            label: _busy ? 'Publication…' : 'Publier les offres',
            icon: Icons.publish_rounded,
            primary: true,
            onPressed: _busy ? null : _publish),
        children: [
          FutureBuilder<(List<Map<String, dynamic>>, List<String>)>(
            future: _local,
            builder: (context, snap) {
              if (snap.hasError) {
                return Text('Lecture impossible : ${errText(snap.error!)}',
                    style: T.body.copyWith(color: T.dangerDark));
              }
              if (!snap.hasData) return const LinearProgressIndicator(color: T.mintDeep);
              final (rules, skipped) = snap.data!;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _list(rules, 'Aucune promotion active pour le web aujourd’hui.'),
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Ne peuvent pas être affichées sur le site :', style: T.label),
                  for (final s in skipped) Text('• $s', style: T.small),
                ],
              ]);
            },
          ),
        ],
      ),
      WebBlock(
        title: 'Actuellement sur le site',
        trailing: TextButton(
            onPressed: _clear,
            style: TextButton.styleFrom(foregroundColor: T.dangerDark),
            child: const Text('Tout retirer')),
        children: [
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _online,
            builder: (context, snap) {
              if (snap.hasError) {
                return Text('Lecture impossible : ${errText(snap.error!)}',
                    style: T.body.copyWith(color: T.dangerDark));
              }
              if (!snap.hasData) return const LinearProgressIndicator(color: T.mintDeep);
              return _list(snap.data!, 'Aucune offre publiée.');
            },
          ),
          const SizedBox(height: 8),
          Text('Les badges ne s’affichent que si les prix sont visibles (modes Boutique et Catalogue).',
              style: T.small),
        ],
      ),
    ]);
  }
}
