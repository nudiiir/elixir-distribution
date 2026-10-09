import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'web_common.dart';

/// « Pages » : content pages (À propos, Conditions de vente, Livraison…)
/// shown in the menu and/or the footer.
class PagesSection extends StatefulWidget {
  const PagesSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<PagesSection> createState() => _PagesSectionState();
}

class _PagesSectionState extends State<PagesSection> {
  Future<WebPagesInfo>? _future;
  List<WebPage>? _pages;
  bool _orderDirty = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _orderDirty = false;
      _future = widget.ctx.client.webPages().then((info) {
        _pages = [...info.items]..sort((a, b) => a.position.compareTo(b.position));
        return info;
      });
    });
  }

  Future<void> _edit({WebPage? page, WebPage? template}) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PageEditor(
          ctx: widget.ctx,
          page: page,
          template: template,
          nextPosition: ((_pages?.length ?? 0) + 1) * 10),
    ));
    if (changed == true) _reload();
  }

  Future<void> _saveOrder() async {
    final pages = _pages ?? const [];
    setState(() => _busy = true);
    try {
      for (var i = 0; i < pages.length; i++) {
        final pos = (i + 1) * 10;
        if (pages[i].position != pos) {
          await widget.ctx.client.webPutPage(pages[i].slug, {'position': pos});
        }
      }
      if (mounted) showToast(context, 'Ordre des pages enregistré.');
      _reload();
    } catch (e) {
      if (mounted) toastError(context, 'Enregistrement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return WebLoader<WebPagesInfo>(
      future: _future,
      onRetry: _reload,
      builder: (info) {
        final pages = _pages ?? const [];
        final full = pages.length >= info.maxPages;
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WebPaneHeader(
              title: 'Pages',
              intro: 'Pages d’information de votre site. Glissez les lignes pour changer '
                  'l’ordre dans le menu et le pied de page.',
              actions: [
                if (_orderDirty)
                  PageAction(
                      label: _busy ? 'Enregistrement…' : 'Enregistrer l’ordre',
                      onPressed: _busy ? null : _saveOrder),
                PageAction(
                    label: 'Nouvelle page',
                    icon: Icons.add_rounded,
                    primary: true,
                    onPressed: full ? null : () => _edit()),
              ],
            ),
            const SizedBox(height: 14),
            if (info.suggestions.isNotEmpty)
              InfoBanner(
                icon: Icons.lightbulb_outline_rounded,
                title: 'Pages prêtes à l’emploi',
                text: 'Partez d’un modèle déjà rédigé, puis adaptez-le à votre magasin.',
                actions: [
                  for (final s in info.suggestions)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: OutlinedButton.icon(
                        onPressed: full ? null : () => _edit(template: s),
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: Text('Ajouter « ${s.title} »'),
                      ),
                    ),
                ],
              ),
            Expanded(
              child: pages.isEmpty
                  ? WebNotice(
                      icon: Icons.article_outlined,
                      title: 'Aucune page',
                      body: 'Ajoutez « À propos », vos conditions de vente ou vos '
                          'informations de livraison.',
                      action: ('Nouvelle page', () => _edit()))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.only(bottom: 18),
                      itemCount: pages.length,
                      onReorderItem: (a, b) => setState(() {
                        pages.insert(b, pages.removeAt(a));
                        _orderDirty = true;
                      }),
                      itemBuilder: (context, i) {
                        final p = pages[i];
                        return Container(
                          key: ValueKey(p.slug),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.fromLTRB(6, 10, 14, 10),
                          decoration: BoxDecoration(
                            color: T.surface,
                            borderRadius: BorderRadius.circular(T.rCard),
                            border: Border.all(color: T.border),
                          ),
                          child: Row(children: [
                            ReorderableDragStartListener(
                              index: i,
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.drag_indicator_rounded, color: T.faint),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(p.title,
                                        style: T.body.copyWith(fontWeight: FontWeight.w700)),
                                    Text('/page/${p.slug}', style: T.monoSmall),
                                  ]),
                            ),
                            Wrap(spacing: 6, children: [
                              if (!p.published)
                                const StatusPill('Brouillon', kind: ToastKind.warning),
                              if (p.showInMenu) const StatusPill('Menu'),
                              if (p.showInFooter) const StatusPill('Pied de page'),
                            ]),
                            const SizedBox(width: 12),
                            TextButton(
                                onPressed: () => openWebUrl('${widget.ctx.publicUrl}/page/${p.slug}'),
                                child: const Text('Voir')),
                            const SizedBox(width: 4),
                            OutlinedButton(
                                onPressed: () => _edit(page: p),
                                child: const Text('Modifier')),
                          ]),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

String slugify(String s) {
  const from = 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  var out = s.toLowerCase();
  for (var i = 0; i < from.length; i++) {
    out = out.replaceAll(from[i], to[i]);
  }
  out = out.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (out.length > 60) out = out.substring(0, 60).replaceAll(RegExp(r'-+$'), '');
  return out;
}

/// Detail page to create or edit one content page.
class PageEditor extends StatefulWidget {
  const PageEditor(
      {super.key, required this.ctx, this.page, this.template, this.nextPosition = 0});
  final WebCtx ctx;
  final WebPage? page;
  final WebPage? template;
  final int nextPosition;

  @override
  State<PageEditor> createState() => _PageEditorState();
}

class _PageEditorState extends State<PageEditor> {
  WebPage? get _src => widget.page ?? widget.template;
  bool get _isNew => widget.page == null;
  late final _title = TextEditingController(text: _src?.title ?? '');
  late final _slug = TextEditingController(text: _src?.slug ?? '');
  late final _body = TextEditingController(text: _src?.body ?? '');
  late bool _menu = _src?.showInMenu ?? false;
  late bool _footer = _src?.showInFooter ?? true;
  late bool _published = _src?.published ?? true;
  late bool _slugTouched = widget.template != null;
  bool _busy = false;
  String? _slugError;
  String? _titleError;

  @override
  void dispose() {
    _title.dispose();
    _slug.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final slug = _slug.text.trim();
    _titleError = _title.text.trim().isEmpty ? 'Le titre est obligatoire.' : null;
    _slugError = RegExp(r'^[a-z0-9](-?[a-z0-9]){0,59}$').hasMatch(slug)
        ? null
        : 'Lettres minuscules, chiffres et tirets (ex. conditions-de-vente).';
    if (_title.text.length > 120) _titleError = '120 caractères maximum.';
    setState(() {});
    if (_titleError != null || _slugError != null) return;
    if (_body.text.length > 20000) {
      showToast(context, 'Texte trop long (20 000 caractères max).', kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.ctx.client.webPutPage(slug, {
        'title': _title.text.trim(),
        'body': _body.text,
        'show_in_menu': _menu,
        'show_in_footer': _footer,
        'published': _published,
        if (_isNew) 'position': widget.nextPosition.clamp(0, 1000),
      });
      if (!mounted) return;
      showToast(context, 'Page « ${_title.text.trim()} » enregistrée.');
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
        title: 'Supprimer la page « ${widget.page!.title} » ?',
        message: 'Elle disparaît du site. Les liens vers /page/${widget.page!.slug} ne marcheront plus.',
        confirmLabel: 'Supprimer',
        danger: true);
    if (!ok || !mounted) return;
    try {
      await widget.ctx.client.webDeletePage(widget.page!.slug);
      if (!mounted) return;
      showToast(context, 'Page supprimée.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toastError(context, 'Suppression impossible', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      crumbs: [
        Crumb('Pages', () => Navigator.of(context).maybePop()),
        Crumb(_isNew ? 'Nouvelle page' : widget.page!.title),
      ],
      title: _isNew ? 'Nouvelle page' : widget.page!.title,
      actions: [
        if (!_isNew)
          PageAction(label: 'Supprimer', danger: true, onPressed: _busy ? null : _delete),
        if (!_isNew)
          PageAction(
              label: 'Voir sur le site',
              icon: Icons.open_in_new_rounded,
              onPressed: () => openWebUrl('${widget.ctx.publicUrl}/page/${widget.page!.slug}')),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      maxWidth: 900,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageSection(
          title: 'Page',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LabeledField(
              label: 'Titre',
              controller: _title,
              required: true,
              error: _titleError,
              onChanged: (v) {
                if (_isNew && !_slugTouched) _slug.text = slugify(v);
                setState(() {});
              },
            ),
            LabeledField(
              label: 'Adresse de la page',
              controller: _slug,
              required: true,
              enabled: _isNew,
              mono: true,
              error: _slugError,
              help: _isNew
                  ? 'La page sera à ${widget.ctx.publicUrl}/page/${_slug.text.isEmpty ? '…' : _slug.text}'
                  : 'L’adresse ne peut plus changer.',
              onChanged: (_) => setState(() => _slugTouched = true),
            ),
            MarkdownField(
              label: 'Contenu',
              controller: _body,
              client: widget.ctx.client,
              maxLength: 20000,
              minLines: 14,
            ),
          ]),
        ),
        PageSection(
          title: 'Affichage',
          child: Column(children: [
            SwitchRow(
                title: 'Publiée',
                explanation: 'Désactivé : la page est enregistrée mais invisible (brouillon).',
                value: _published,
                onChanged: (v) => setState(() => _published = v)),
            SwitchRow(
                title: 'Dans le menu',
                explanation: 'Lien dans la barre des rayons, en haut du site.',
                value: _menu,
                onChanged: (v) => setState(() => _menu = v)),
            SwitchRow(
                title: 'Dans le pied de page',
                explanation: 'Colonne « Informations » en bas de chaque page.',
                value: _footer,
                onChanged: (v) => setState(() => _footer = v)),
          ]),
        ),
      ]),
    );
  }
}
