import 'dart:convert';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'section_editor.dart';
import 'web_common.dart';

/// « Page d’accueil » : the landing-page builder. Ordered list of sections
/// (drag to reorder, switch to hide, « Modifier » opens the section page).
class HomeSection extends StatefulWidget {
  const HomeSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<HomeSection> createState() => _HomeSectionState();
}

Map<String, dynamic> deepCopy(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

class _HomeSectionState extends State<HomeSection> {
  Future<WebSectionsInfo>? _future;
  WebSectionsInfo? _info;
  List<Map<String, dynamic>> _sections = [];
  bool _dirty = false;
  bool _busy = false;
  List<String> _errors = const [];
  List<String> _missing = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = widget.ctx.client.webSections().then((info) {
        _info = info;
        _sections = [for (final s in info.sections) deepCopy(s)];
        _dirty = false;
        _errors = const [];
        _missing = const [];
        return info;
      });
    });
  }

  /// Sends [list] (null = default layout). Returns the errors, or null.
  Future<List<String>?> _put(List<Map<String, dynamic>>? list) async {
    setState(() => _busy = true);
    try {
      final info = await widget.ctx.client.webPutSections(list);
      _info = WebSectionsInfo.fromJson({
        'sections': info.sections,
        'is_default': info.isDefault,
        'types': _info?.types ?? const [],
        'max_sections': _info?.maxSections ?? 30,
        'feature_icons': _info?.featureIcons ?? const [],
      });
      _sections = [for (final s in info.sections) deepCopy(s)];
      _dirty = false;
      _errors = const [];
      _missing = const [];
      if (mounted) setState(() => _busy = false);
      return null;
    } on WebApiException catch (e) {
      final errs = e.errors.isEmpty ? [e.message] : e.errors;
      if (mounted) {
        setState(() {
          _busy = false;
          _errors = errs;
          _missing = e.missingAssets;
        });
      }
      return [
        ...errs,
        if (e.missingAssets.isNotEmpty)
          'Images introuvables (supprimées ?) : ${e.missingAssets.length}'
      ];
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      return [errText(e)];
    }
  }

  Future<void> _save() async {
    final errs = await _put(_sections);
    if (!mounted) return;
    if (errs == null) {
      showToast(context, 'Page d’accueil enregistrée — le site est à jour.',
          actionLabel: 'Voir', onAction: () => openWebUrl(widget.ctx.publicUrl));
    } else {
      showToast(context, 'Rien n’a été enregistré : corrigez les erreurs affichées.',
          kind: ToastKind.error);
    }
  }

  Future<void> _reset() async {
    final ok = await confirmAction(context,
        title: 'Revenir à la page d’accueil d’origine ?',
        message: 'Vos sections sont remplacées par la mise en page standard (bannière, '
            'rayons, promotions, sélection, nouveautés). Les images restent dans la médiathèque.',
        confirmLabel: 'Revenir à l’origine',
        danger: true);
    if (!ok) return;
    final errs = await _put(null);
    if (mounted && errs == null) showToast(context, 'Mise en page d’origine rétablie.');
    if (mounted && errs != null) toastError(context, 'Action impossible', errs.join(' · '));
  }

  String _newId(String type) {
    final ids = {for (final s in _sections) '${s['id']}'};
    final base = type.replaceAll('_', '-');
    for (var i = 1;; i++) {
      final id = '$base-$i';
      if (!ids.contains(id)) return id;
    }
  }

  Future<void> _add() async {
    final info = _info!;
    if (_sections.length >= info.maxSections) {
      showToast(context, 'Maximum ${info.maxSections} sections.', kind: ToastKind.warning);
      return;
    }
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.surface,
        title: const Text('Ajouter une section', style: T.h2),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final t in info.types)
                InkWell(
                  borderRadius: BorderRadius.circular(T.rInner),
                  onTap: () => Navigator.of(ctx).pop(t),
                  child: Container(
                    width: 300,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(T.rInner),
                      border: Border.all(color: T.border3),
                    ),
                    child: Row(children: [
                      Icon(sectionMeta(t).$2, color: T.mintDeep),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(sectionMeta(t).$1,
                              style: T.body.copyWith(fontWeight: FontWeight.w700)),
                          Text(sectionMeta(t).$3, style: T.small),
                        ]),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Annuler')),
        ],
      ),
    );
    if (type == null || !mounted) return;
    final section = <String, dynamic>{
      'id': _newId(type),
      'type': type,
      'enabled': true,
      if (defaultSectionTitle(type) != null) 'title': defaultSectionTitle(type),
      'settings': defaultSectionSettings(type),
    };
    await _edit(section, _sections.length, isNew: true);
  }

  Future<void> _edit(Map<String, dynamic> section, int index, {bool isNew = false}) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => SectionEditorPage(
        ctx: widget.ctx,
        info: _info!,
        section: deepCopy(section),
        isNew: isNew,
        onSave: (edited) async {
          final list = [for (final s in _sections) deepCopy(s)];
          if (isNew) {
            list.add(edited);
          } else {
            list[index] = edited;
          }
          final errs = await _put(list);
          if (errs == null) return null;
          // Keep only the errors of this section when possible.
          final mine = [
            for (final e in errs)
              if (e.startsWith('sections[$index]'))
                e.replaceFirst(RegExp(r'^sections\[\d+\]\.?'), '')
          ];
          return mine.isEmpty ? errs : mine;
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _remove(int i) async {
    final s = _sections[i];
    final ok = await confirmAction(context,
        title: 'Retirer la section « ${sectionLabel(s)} » ?',
        message: 'Elle disparaît de la page d’accueil quand vous enregistrez.',
        confirmLabel: 'Retirer',
        danger: true);
    if (!ok) return;
    setState(() {
      _sections.removeAt(i);
      _dirty = true;
    });
  }

  int? _errorIndex(String e) {
    final m = RegExp(r'^sections\[(\d+)\]').firstMatch(e);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String _humanError(String e) {
    final i = _errorIndex(e);
    if (i == null || i >= _sections.length) return e;
    return 'Section ${i + 1} « ${sectionLabel(_sections[i])} » — '
        '${e.replaceFirst(RegExp(r'^sections\[\d+\]\.?'), '')}';
  }

  @override
  Widget build(BuildContext context) {
    return WebLoader<WebSectionsInfo>(
      future: _future,
      onRetry: _reload,
      builder: (_) {
        final badRows = {for (final e in _errors) ?_errorIndex(e)};
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WebPaneHeader(
              title: 'Page d’accueil',
              intro: 'Composez votre page d’accueil avec des sections. Glissez-les pour '
                  'changer l’ordre, désactivez-les pour les cacher.',
              actions: [
                PageAction(
                    label: 'Ajouter une section',
                    icon: Icons.add_rounded,
                    onPressed: _busy ? null : _add),
                PageAction(
                    label: 'Voir le site',
                    icon: Icons.open_in_new_rounded,
                    onPressed: () => openWebUrl(widget.ctx.publicUrl)),
                PageAction(
                    label: _busy ? 'Enregistrement…' : 'Enregistrer',
                    primary: true,
                    onPressed: _busy || !_dirty ? null : _save),
              ],
            ),
            const SizedBox(height: 12),
            if (_info?.isDefault == true && !_dirty)
              const InfoBanner(
                  text: 'Vous utilisez la page d’accueil standard. Modifiez, ajoutez ou '
                      'déplacez une section pour créer la vôtre.'),
            if (_errors.isNotEmpty)
              InfoBanner(
                kind: ToastKind.error,
                title: 'Rien n’a été enregistré',
                text: [
                  for (final e in _errors.take(10)) '• ${_humanError(e)}',
                  if (_missing.isNotEmpty)
                    '• ${_missing.length} image(s) introuvable(s) — choisissez une autre image.',
                ].join('\n'),
              ),
            if (_dirty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('Modifications non enregistrées.',
                    style: T.body.copyWith(color: T.warnDark, fontWeight: FontWeight.w700)),
              ),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: _sections.length,
                onReorderItem: (a, b) => setState(() {
                  _sections.insert(b, _sections.removeAt(a));
                  _dirty = true;
                  _errors = const [];
                }),
                itemBuilder: (context, i) {
                  final s = _sections[i];
                  final enabled = s['enabled'] != false;
                  final bad = badRows.contains(i);
                  return Container(
                    key: ValueKey('${s['id']}'),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: enabled ? T.surface : T.bg,
                      borderRadius: BorderRadius.circular(T.rCard),
                      border: Border.all(color: bad ? T.danger : T.border, width: bad ? 1.6 : 1),
                    ),
                    child: Row(children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_indicator_rounded, color: T.faint),
                        ),
                      ),
                      SizedBox(
                          width: 28,
                          child: Text('${i + 1}', style: T.monoSmall)),
                      Icon(sectionMeta('${s['type']}').$2,
                          color: enabled ? T.mintDeep : T.ghost),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(sectionLabel(s),
                              style: T.body.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: enabled ? T.ink : T.faint)),
                          Text(
                              '${sectionMeta('${s['type']}').$1} · ${sectionSummary(s)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: T.small),
                        ]),
                      ),
                      Text(enabled ? 'Affichée' : 'Cachée', style: T.small),
                      Switch(
                        value: enabled,
                        onChanged: (v) => setState(() {
                          s['enabled'] = v;
                          _dirty = true;
                        }),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                          onPressed: _busy || _dirty
                              ? (_dirty ? () => _askSaveFirst() : null)
                              : () => _edit(s, i),
                          child: const Text('Modifier')),
                      const SizedBox(width: 4),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                        onPressed: _busy ? null : () => _remove(i),
                        child: const Text('Retirer'),
                      ),
                    ]),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(children: [
                Text('${_sections.length} / ${_info?.maxSections ?? 30} sections', style: T.small),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _reset,
                  child: const Text('Revenir à la page d’accueil d’origine'),
                ),
                if (_dirty)
                  TextButton(
                      onPressed: _busy ? null : _reload,
                      child: const Text('Annuler les modifications')),
              ]),
            ),
          ]),
        );
      },
    );
  }

  void _askSaveFirst() {
    showToast(context,
        'Enregistrez d’abord l’ordre et l’affichage des sections (bouton « Enregistrer »), puis modifiez.',
        kind: ToastKind.info, actionLabel: 'Enregistrer', onAction: _save);
  }
}
