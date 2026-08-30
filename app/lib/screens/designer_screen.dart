import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../templates/template_defaults.dart';
import '../templates/template_model.dart';
import '../templates/template_render.dart';
import '../theme/tokens.dart';
import '../widgets/ui.dart';

const _kindLabels = {
  'label': 'Étiquette',
  'invoice': 'Facture',
  'warranty': 'Garantie',
};

const _kindIcons = {
  'label': Icons.qr_code_2_rounded,
  'invoice': Icons.receipt_long_outlined,
  'warranty': Icons.verified_user_outlined,
};

/// The document designer: pick a template, edit it on a canvas — drag to
/// move, pull the handles to resize, type in the panel — then save.
class DesignerScreen extends StatefulWidget {
  const DesignerScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<DesignerScreen> createState() => _DesignerScreenState();
}

class _DesignerScreenState extends State<DesignerScreen> {
  List<Template> _templates = const [];
  Template? _current;
  TplDoc? _doc;
  int? _sel;
  bool _dirty = false;
  bool _busy = false;
  double _zoom = 0; // px per mm; 0 = fit

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.templates();
      if (mounted) setState(() => _templates = items);
    } catch (_) {}
  }

  void _open(Template t) {
    setState(() {
      _current = t;
      _doc = TplDoc.fromJson(t.body);
      _sel = null;
      _dirty = false;
      _zoom = 0;
    });
  }

  Future<void> _create() async {
    final res = await showDialog<(String, String, String)>(
      context: context,
      builder: (_) => const _NewTemplateDialog(),
    );
    if (res == null) return;
    final (kind, lang, name) = res;
    setState(() => _busy = true);
    try {
      final t = await widget.api.saveTemplate({
        'kind': kind,
        'lang': lang,
        'name': name,
        'body': defaultTplDoc(kind, lang).toJson(),
      });
      await _load();
      _open(t);
    } on ApiException catch (e) {
      _snack(e.message, danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final t = _current;
    final d = _doc;
    if (t == null || d == null) return;
    setState(() => _busy = true);
    try {
      final saved = await widget.api.saveTemplate({
        'name': t.name,
        'lang': t.lang,
        'body': d.toJson(),
      }, id: t.id);
      setState(() {
        _current = saved;
        _dirty = false;
      });
      _load();
      _snack('Modèle enregistré.');
    } on ApiException catch (e) {
      _snack(e.message, danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final t = _current;
    final d = _doc;
    if (t == null || d == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await renderTemplateBytes(
        d,
        lang: t.lang,
        data: tplSampleData,
        tableRows: const [
          ['Mixeur Moulinex 700W', '1', '6 638,66', '6 638,66'],
          ['Cafetière expresso', '2', '3 403,36', '6 806,72'],
        ],
      );
      await saveAndOpenPdf(bytes, 'apercu-${t.name}');
    } catch (e) {
      _snack('Aperçu impossible : $e', danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setDefault() async {
    final t = _current;
    if (t == null) return;
    try {
      final updated = await widget.api.setDefaultTemplate(t.id);
      setState(() => _current = updated);
      _load();
      _snack('« ${t.name} » est maintenant le modèle utilisé à l\'impression.');
    } on ApiException catch (e) {
      _snack(e.message, danger: true);
    }
  }

  Future<void> _delete() async {
    final t = _current;
    if (t == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rCard)),
        title: Text('Supprimer « ${t.name} » ?', style: T.h2),
        content: Text('Le modèle sera définitivement supprimé.', style: T.bodyMuted),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Annuler', style: T.small.copyWith(color: T.muted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Supprimer',
                  style: T.small.copyWith(color: T.dangerDark))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.deleteTemplate(t.id);
      setState(() {
        _current = null;
        _doc = null;
        _sel = null;
      });
      _load();
    } on ApiException catch (e) {
      _snack(e.message, danger: true);
    }
  }

  void _snack(String msg, {bool danger = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: danger ? T.danger : T.ink,
      behavior: SnackBarBehavior.floating,
      content: Text(msg,
          style: const TextStyle(fontFamily: T.sans, color: Colors.white)),
    ));
  }

  void _addElement(String type) {
    final d = _doc;
    if (d == null) return;
    final e = switch (type) {
      'text' => TplElement(
          type: 'text', text: 'Texte…', x: 5, y: 5, w: math.min(40, d.widthMm - 10), h: 8),
      'field' => TplElement(
          type: 'field',
          field: tplFields[_current!.kind]!.keys.first,
          x: 5, y: 5, w: math.min(40, d.widthMm - 10), h: 8),
      'barcode' =>
        TplElement(type: 'barcode', x: 5, y: 5, w: math.min(34, d.widthMm - 10), h: 10),
      'line' => TplElement(
          type: 'line', x: 5, y: 5, w: math.min(60, d.widthMm - 10), h: 0, borderWidth: 0.5),
      'rect' => TplElement(
          type: 'rect', x: 5, y: 5, w: math.min(40, d.widthMm - 10), h: 20),
      _ => TplElement(
          type: 'table', x: 5, y: 5, w: d.widthMm - 10, h: 60, fontSize: 9),
    };
    setState(() {
      d.elements.add(e);
      _sel = d.elements.length - 1;
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      _TemplateList(
        templates: _templates,
        currentId: _current?.id,
        onOpen: _open,
        onCreate: _busy ? null : _create,
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: _doc == null
            ? const EmptyState(
                icon: Icons.design_services_outlined,
                text:
                    'Choisissez un modèle à gauche, ou créez-en un nouveau.\n'
                    'Étiquettes, factures et bons de garantie — en français ou en arabe.')
            : Column(children: [
                _EditorToolbar(
                  template: _current!,
                  dirty: _dirty,
                  busy: _busy,
                  showTable: _current!.kind == 'invoice',
                  onAdd: _addElement,
                  onSave: _save,
                  onPreview: _preview,
                  onDefault: _setDefault,
                  onDelete: _delete,
                ),
                const Divider(),
                Expanded(
                  child: _Canvas(
                    doc: _doc!,
                    lang: _current!.lang,
                    sel: _sel,
                    zoom: _zoom,
                    onZoom: (z) => setState(() => _zoom = z),
                    onSelect: (i) => setState(() => _sel = i),
                    onChanged: () => setState(() => _dirty = true),
                  ),
                ),
              ]),
      ),
      const VerticalDivider(width: 1),
      _PropertiesPanel(
        template: _current,
        doc: _doc,
        sel: _sel,
        onChanged: () => setState(() => _dirty = true),
        onRename: (name, lang) {
          // Template objects are immutable json wrappers; track edits locally
          // by re-wrapping. Cheap and keeps a single source of truth on save.
          final t = _current;
          if (t == null) return;
          setState(() {
            _current = Template.fromJson({
              'id': t.id,
              'kind': t.kind,
              'name': name,
              'lang': lang,
              'body': _doc?.toJson() ?? t.body,
              'is_default': t.isDefault,
            });
            _dirty = true;
          });
        },
        onDeleteElement: () {
          final d = _doc;
          final i = _sel;
          if (d == null || i == null) return;
          setState(() {
            d.elements.removeAt(i);
            _sel = null;
            _dirty = true;
          });
        },
        onDuplicateElement: () {
          final d = _doc;
          final i = _sel;
          if (d == null || i == null) return;
          setState(() {
            final c = d.elements[i].copy();
            c.x += 3;
            c.y += 3;
            d.elements.add(c);
            _sel = d.elements.length - 1;
            _dirty = true;
          });
        },
      ),
    ]);
  }
}

// ---------------------------------------------------------------- list pane

class _TemplateList extends StatelessWidget {
  const _TemplateList({
    required this.templates,
    required this.currentId,
    required this.onOpen,
    required this.onCreate,
  });
  final List<Template> templates;
  final String? currentId;
  final ValueChanged<Template> onOpen;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final byKind = <String, List<Template>>{};
    for (final t in templates) {
      byKind.putIfAbsent(t.kind, () => []).add(t);
    }
    return SizedBox(
      width: 230,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Modèles', style: T.h1),
            const SizedBox(height: 4),
            Text('Étiquettes, factures, garanties', style: T.small),
            const SizedBox(height: 12),
            PrimaryButton(label: 'Nouveau modèle', onPressed: onCreate),
          ]),
        ),
        const Divider(),
        Expanded(
          child: templates.isEmpty
              ? const EmptyState(
                  icon: Icons.space_dashboard_outlined, text: 'Aucun modèle')
              : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                  for (final kind in ['label', 'invoice', 'warranty'])
                    if (byKind[kind] != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                        child: Text(_kindLabels[kind]!.toUpperCase(),
                            style: T.label),
                      ),
                      for (final t in byKind[kind]!)
                        InkWell(
                          onTap: () => onOpen(t),
                          child: Container(
                            color: t.id == currentId
                                ? T.mintTint
                                : Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 9),
                            child: Row(children: [
                              Icon(_kindIcons[kind],
                                  size: 15,
                                  color: t.id == currentId
                                      ? T.mintDeep
                                      : T.faint),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(t.name,
                                    style: T.body.copyWith(fontSize: 12.5),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              if (t.lang == 'ar')
                                const MintChip('AR',
                                    color: T.cream, fg: T.muted),
                              if (t.isDefault) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.star_rounded,
                                    size: 14, color: T.warn),
                              ],
                            ]),
                          ),
                        ),
                    ],
                ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- toolbar

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.template,
    required this.dirty,
    required this.busy,
    required this.showTable,
    required this.onAdd,
    required this.onSave,
    required this.onPreview,
    required this.onDefault,
    required this.onDelete,
  });
  final Template template;
  final bool dirty;
  final bool busy;
  final bool showTable;
  final ValueChanged<String> onAdd;
  final VoidCallback onSave, onPreview, onDefault, onDelete;

  @override
  Widget build(BuildContext context) {
    Widget addBtn(String type, IconData icon, String tip) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: () => onAdd(type),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              child: Icon(icon, size: 17, color: T.muted),
            ),
          ),
        );

    return Container(
      height: 52,
      color: T.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(children: [
        Text(template.name, style: T.h2),
        const SizedBox(width: 8),
        MintChip(_kindLabels[template.kind] ?? template.kind,
            color: T.mintTint, fg: T.mintDark),
        if (dirty) ...[
          const SizedBox(width: 6),
          const MintChip('modifié', color: T.cream, fg: T.warnDark),
        ],
        const SizedBox(width: 18),
        Container(width: 1, height: 24, color: T.border),
        const SizedBox(width: 8),
        addBtn('text', Icons.title_rounded, 'Ajouter du texte'),
        addBtn('field', Icons.data_object_rounded, 'Ajouter un champ (donnée)'),
        addBtn('barcode', Icons.qr_code_2_rounded, 'Ajouter le code-barres'),
        addBtn('line', Icons.horizontal_rule_rounded, 'Ajouter une ligne'),
        addBtn('rect', Icons.crop_din_rounded, 'Ajouter un cadre'),
        if (showTable)
          addBtn('table', Icons.table_rows_outlined, 'Tableau des articles'),
        const Spacer(),
        IconButton(
          tooltip: template.isDefault
              ? 'Modèle par défaut'
              : 'Utiliser à l\'impression',
          onPressed: template.isDefault ? null : onDefault,
          icon: Icon(
              template.isDefault
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              size: 19,
              color: template.isDefault ? T.warn : T.muted),
        ),
        IconButton(
          tooltip: 'Supprimer le modèle',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded,
              size: 18, color: T.muted),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 104,
          height: 36,
          child: OutlinedButton(
            onPressed: busy ? null : onPreview,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: T.border3),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.rInner)),
            ),
            child: Text('Aperçu PDF',
                style: T.small.copyWith(
                    color: T.ink, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: PrimaryButton(
              label: busy ? '…' : 'Enregistrer',
              onPressed: busy || !dirty ? null : onSave),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- canvas

class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.doc,
    required this.lang,
    required this.sel,
    required this.zoom,
    required this.onZoom,
    required this.onSelect,
    required this.onChanged,
  });
  final TplDoc doc;
  final String lang;
  final int? sel;
  final double zoom; // 0 = fit
  final ValueChanged<double> onZoom;
  final ValueChanged<int?> onSelect;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final fit = math.min((constraints.maxWidth - 80) / doc.widthMm,
          (constraints.maxHeight - 80) / doc.heightMm);
      final scale = zoom > 0 ? zoom : fit.clamp(0.5, 12.0);
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => onSelect(null),
            child: Container(
              color: const Color(0xFFECEDEC),
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: _Sheet(
                      doc: doc,
                      lang: lang,
                      scale: scale,
                      sel: sel,
                      onSelect: onSelect,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // zoom control
        PositionedDirectional(
          bottom: 14,
          end: 14,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: T.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    onZoom((scale / 1.25).clamp(0.5, 12.0)),
                icon: const Icon(Icons.remove, size: 14, color: T.muted),
              ),
              Text('${(scale * 100 / 3.7795).round()}%',
                  style: T.monoSmall.copyWith(fontSize: 10.5)),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    onZoom((scale * 1.25).clamp(0.5, 12.0)),
                icon: const Icon(Icons.add, size: 14, color: T.muted),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Ajuster',
                onPressed: () => onZoom(0),
                icon: const Icon(Icons.fit_screen_outlined,
                    size: 14, color: T.muted),
              ),
            ]),
          ),
        ),
      ]);
    });
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.doc,
    required this.lang,
    required this.scale,
    required this.sel,
    required this.onSelect,
    required this.onChanged,
  });
  final TplDoc doc;
  final String lang;
  final double scale;
  final int? sel;
  final ValueChanged<int?> onSelect;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: doc.widthMm * scale,
      height: doc.heightMm * scale,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: ClipRect(
        child: Stack(children: [
          Positioned.fill(
              child: CustomPaint(painter: _GridPainter(scale: scale))),
          for (var i = 0; i < doc.elements.length; i++)
            _ElementWidget(
              key: ValueKey(i),
              doc: doc,
              index: i,
              lang: lang,
              scale: scale,
              selected: sel == i,
              onSelect: () => onSelect(i),
              onChanged: onChanged,
            ),
        ]),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.scale});
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x0A000000)
      ..strokeWidth = 0.5;
    final step = 5 * scale; // 5mm grid
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.scale != scale;
}

final _arabicRe = RegExp(r'[؀-ۿ]');

class _ElementWidget extends StatelessWidget {
  const _ElementWidget({
    super.key,
    required this.doc,
    required this.index,
    required this.lang,
    required this.scale,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
  });
  final TplDoc doc;
  final int index;
  final String lang;
  final double scale;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  TplElement get e => doc.elements[index];

  void _move(DragUpdateDetails d) {
    e.x = (e.x + d.delta.dx / scale).clamp(-e.w + 2, doc.widthMm - 2);
    e.y = (e.y + d.delta.dy / scale).clamp(-e.h + 2, doc.heightMm - 2);
    onChanged();
  }

  void _resize(DragUpdateDetails d, {required int hx, required int hy}) {
    final dx = d.delta.dx / scale;
    final dy = d.delta.dy / scale;
    if (hx == -1) {
      final nw = (e.w - dx).clamp(2.0, doc.widthMm);
      e.x += e.w - nw;
      e.w = nw;
    } else if (hx == 1) {
      e.w = (e.w + dx).clamp(2.0, doc.widthMm);
    }
    if (hy == -1) {
      final nh = (e.h - dy).clamp(0.0, doc.heightMm);
      e.y += e.h - nh;
      e.h = nh;
    } else if (hy == 1) {
      e.h = (e.h + dy).clamp(0.0, doc.heightMm);
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final content = _content();
    final handles = <Widget>[];
    if (selected) {
      for (final (hx, hy) in [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
      ]) {
        handles.add(Positioned(
          left: hx == -1 ? -4 : (hx == 0 ? e.w * scale / 2 - 4 : e.w * scale - 4),
          top: hy == -1 ? -4 : (hy == 0 ? e.h * scale / 2 - 4 : e.h * scale - 4),
          child: MouseRegion(
            cursor: (hx == 0 || hy == 0)
                ? (hx == 0
                    ? SystemMouseCursors.resizeUpDown
                    : SystemMouseCursors.resizeLeftRight)
                : (hx == hy
                    ? SystemMouseCursors.resizeUpLeftDownRight
                    : SystemMouseCursors.resizeUpRightDownLeft),
            child: GestureDetector(
              onPanUpdate: (d) => _resize(d, hx: hx, hy: hy),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: T.mintDeep, width: 1.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ));
      }
    }

    return Positioned(
      left: e.x * scale,
      top: e.y * scale,
      child: GestureDetector(
        onTap: onSelect,
        onPanStart: (_) => onSelect(),
        onPanUpdate: _move,
        child: MouseRegion(
          cursor: SystemMouseCursors.move,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              width: e.w * scale,
              height: math.max(e.h * scale, 4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? T.mintDeep : const Color(0x14000000),
                  width: selected ? 1.4 : 0.7,
                ),
              ),
              child: content,
            ),
            ...handles,
          ]),
        ),
      ),
    );
  }

  Widget _content() {
    switch (e.type) {
      case 'text':
      case 'field':
        final raw = e.type == 'text' ? e.text : (tplSampleData[e.field] ?? '');
        final arabic = lang == 'ar' || _arabicRe.hasMatch(raw);
        return Padding(
          padding: const EdgeInsets.all(1),
          child: Text(
            raw.isEmpty ? '…' : raw,
            textAlign: switch (e.align) {
              'center' => TextAlign.center,
              'right' => TextAlign.right,
              _ => TextAlign.left,
            },
            textDirection:
                _arabicRe.hasMatch(raw) ? TextDirection.rtl : TextDirection.ltr,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: e.mono
                  ? T.mono
                  : arabic
                      ? 'IBMPlexSansArabic'
                      : T.sans,
              // 1pt = 0.3528mm on paper
              fontSize: math.max(4, e.fontSize * 0.3528 * scale),
              fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
              fontStyle: e.italic ? FontStyle.italic : FontStyle.normal,
              color: e.type == 'field' ? T.mintDark : T.ink,
              height: 1.15,
            ),
          ),
        );
      case 'barcode':
        return CustomPaint(painter: _FakeBarcodePainter());
      case 'line':
        return Container(
            height: math.max(1, e.borderWidth * scale), color: T.ink);
      case 'rect':
        return Container(
          decoration: BoxDecoration(
            color: e.filled ? T.cream : null,
            border: Border.all(
                color: T.ink, width: math.max(0.5, e.borderWidth * scale)),
          ),
        );
      case 'table':
        return Container(
          decoration: BoxDecoration(border: Border.all(color: T.faint, width: 0.7)),
          child: Column(children: [
            Container(
              height: math.max(10, 6 * scale * 0.3528 * 2.2),
              color: T.cream,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                lang == 'ar'
                    ? 'البيان · الكمية · السعر · المبلغ'
                    : 'Désignation · Qté · PU · Montant',
                style: TextStyle(
                    fontFamily: lang == 'ar' ? 'IBMPlexSansArabic' : T.sans,
                    fontSize: math.max(5, e.fontSize * 0.3528 * scale),
                    fontWeight: FontWeight.w700,
                    color: T.muted),
              ),
            ),
            Expanded(
              child: Center(
                child: Text('Articles du document',
                    style: T.small.copyWith(color: T.ghost)),
              ),
            ),
          ]),
        );
    }
    return const SizedBox();
  }
}

class _FakeBarcodePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = T.ink;
    final rng = math.Random(7);
    var x = size.width * 0.06;
    while (x < size.width * 0.94) {
      final w = (rng.nextInt(3) + 1) * size.width / 120;
      canvas.drawRect(
          Rect.fromLTWH(x, size.height * 0.08, w, size.height * 0.68), p);
      x += w + size.width / 90;
    }
    final tp = TextPainter(
      text: TextSpan(
          text: '2001234567893',
          style: TextStyle(
              fontFamily: T.mono,
              fontSize: math.max(5, size.height * 0.16),
              color: T.ink)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        Offset((size.width - tp.width) / 2, size.height * 0.8));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ------------------------------------------------------------- properties

class _PropertiesPanel extends StatefulWidget {
  const _PropertiesPanel({
    required this.template,
    required this.doc,
    required this.sel,
    required this.onChanged,
    required this.onRename,
    required this.onDeleteElement,
    required this.onDuplicateElement,
  });
  final Template? template;
  final TplDoc? doc;
  final int? sel;
  final VoidCallback onChanged;
  final void Function(String name, String lang) onRename;
  final VoidCallback onDeleteElement;
  final VoidCallback onDuplicateElement;

  @override
  State<_PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<_PropertiesPanel> {
  TplElement? get e {
    final d = widget.doc;
    final i = widget.sel;
    if (d == null || i == null || i >= d.elements.length) return null;
    return d.elements[i];
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.template;
    return Container(
      width: 262,
      color: T.surface,
      child: t == null
          ? const SizedBox()
          : ListView(
              padding: const EdgeInsets.all(14),
              children: e == null ? _templateProps(t) : _elementProps(e!),
            ),
    );
  }

  List<Widget> _templateProps(Template t) {
    final d = widget.doc!;
    return [
      const MicroLabel('MODÈLE'),
      const SizedBox(height: 8),
      _TextProp(
        label: 'Nom',
        value: t.name,
        onChanged: (v) => widget.onRename(v, t.lang),
      ),
      const SizedBox(height: 10),
      const MicroLabel('LANGUE'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, children: [
        for (final (code, label) in [('fr', 'Français'), ('ar', 'العربية')])
          ChoiceChip(
            label: Text(label,
                style: TextStyle(
                    fontFamily: code == 'ar' ? 'IBMPlexSansArabic' : T.sans,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.lang == code ? T.mintDark : T.muted)),
            selected: t.lang == code,
            selectedColor: T.mintTint,
            backgroundColor: T.bg,
            side: BorderSide(color: t.lang == code ? T.mintDeep : T.border),
            showCheckmark: false,
            onSelected: (_) => widget.onRename(t.name, code),
          ),
      ]),
      const SizedBox(height: 14),
      const MicroLabel('DIMENSIONS (MM)'),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
            child: _NumProp(
                label: 'Largeur',
                value: d.widthMm,
                onChanged: (v) {
                  d.widthMm = v.clamp(20, 500);
                  widget.onChanged();
                })),
        const SizedBox(width: 8),
        Expanded(
            child: _NumProp(
                label: 'Hauteur',
                value: d.heightMm,
                onChanged: (v) {
                  d.heightMm = v.clamp(15, 500);
                  widget.onChanged();
                })),
      ]),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
        ),
        child: Text(
          'Cliquez sur un élément du canevas pour le modifier : '
          'glissez pour le déplacer, tirez les poignées pour le '
          'redimensionner. La barre d\'outils ajoute du texte, des champs '
          'de données, le code-barres…',
          style: T.small.copyWith(fontSize: 11, height: 1.45),
        ),
      ),
    ];
  }

  List<Widget> _elementProps(TplElement el) {
    final kind = widget.template!.kind;
    final fields = tplFields[kind]!;
    return [
      Row(children: [
        Expanded(
          child: MicroLabel(switch (el.type) {
            'text' => 'TEXTE',
            'field' => 'CHAMP DE DONNÉES',
            'barcode' => 'CODE-BARRES',
            'line' => 'LIGNE',
            'rect' => 'CADRE',
            _ => 'TABLEAU DES ARTICLES',
          }),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Dupliquer',
          onPressed: widget.onDuplicateElement,
          icon: const Icon(Icons.copy_rounded, size: 15, color: T.muted),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Supprimer l\'élément',
          onPressed: widget.onDeleteElement,
          icon: const Icon(Icons.delete_outline_rounded,
              size: 16, color: T.dangerDark),
        ),
      ]),
      const SizedBox(height: 8),
      if (el.type == 'text') ...[
        _TextProp(
          label: 'Contenu',
          value: el.text,
          multiline: true,
          onChanged: (v) {
            el.text = v;
            widget.onChanged();
          },
        ),
        const SizedBox(height: 10),
      ],
      if (el.type == 'field') ...[
        const MicroLabel('DONNÉE AFFICHÉE'),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: fields.containsKey(el.field) ? el.field : fields.keys.first,
              isExpanded: true,
              style: T.body,
              dropdownColor: T.surface,
              items: [
                for (final f in fields.entries)
                  DropdownMenuItem(
                      value: f.key,
                      child: Text(f.value,
                          style: T.body.copyWith(fontSize: 12.5))),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => el.field = v);
                  widget.onChanged();
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
      const MicroLabel('POSITION & TAILLE (MM)'),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
            child: _NumProp(
                label: 'X',
                value: el.x,
                onChanged: (v) {
                  el.x = v;
                  widget.onChanged();
                })),
        const SizedBox(width: 8),
        Expanded(
            child: _NumProp(
                label: 'Y',
                value: el.y,
                onChanged: (v) {
                  el.y = v;
                  widget.onChanged();
                })),
      ]),
      Row(children: [
        Expanded(
            child: _NumProp(
                label: 'Largeur',
                value: el.w,
                onChanged: (v) {
                  el.w = v.clamp(2, 500);
                  widget.onChanged();
                })),
        const SizedBox(width: 8),
        Expanded(
            child: _NumProp(
                label: 'Hauteur',
                value: el.h,
                onChanged: (v) {
                  el.h = v.clamp(0, 500);
                  widget.onChanged();
                })),
      ]),
      if (el.type == 'text' || el.type == 'field' || el.type == 'table') ...[
        const SizedBox(height: 10),
        const MicroLabel('TYPOGRAPHIE'),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: _NumProp(
                label: 'Taille (pt)',
                value: el.fontSize,
                onChanged: (v) {
                  el.fontSize = v.clamp(4, 72);
                  widget.onChanged();
                }),
          ),
          const SizedBox(width: 8),
          _ToggleBtn(
              icon: Icons.format_bold_rounded,
              active: el.bold,
              tip: 'Gras',
              onTap: () {
                setState(() => el.bold = !el.bold);
                widget.onChanged();
              }),
          _ToggleBtn(
              icon: Icons.format_italic_rounded,
              active: el.italic,
              tip: 'Italique',
              onTap: () {
                setState(() => el.italic = !el.italic);
                widget.onChanged();
              }),
          _ToggleBtn(
              icon: Icons.code_rounded,
              active: el.mono,
              tip: 'Chiffres / codes',
              onTap: () {
                setState(() => el.mono = !el.mono);
                widget.onChanged();
              }),
        ]),
        const SizedBox(height: 8),
        const MicroLabel('ALIGNEMENT'),
        const SizedBox(height: 6),
        Row(children: [
          for (final (a, icon) in [
            ('left', Icons.format_align_left_rounded),
            ('center', Icons.format_align_center_rounded),
            ('right', Icons.format_align_right_rounded),
          ])
            _ToggleBtn(
                icon: icon,
                active: el.align == a,
                tip: a,
                onTap: () {
                  setState(() => el.align = a);
                  widget.onChanged();
                }),
        ]),
      ],
      if (el.type == 'rect' || el.type == 'line') ...[
        const SizedBox(height: 10),
        _NumProp(
            label: 'Épaisseur du trait (mm)',
            value: el.borderWidth,
            onChanged: (v) {
              el.borderWidth = v.clamp(0.1, 5);
              widget.onChanged();
            }),
        if (el.type == 'rect')
          InkWell(
            onTap: () {
              setState(() => el.filled = !el.filled);
              widget.onChanged();
            },
            child: Row(children: [
              Icon(
                  el.filled
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 18,
                  color: el.filled ? T.mintDeep : T.faint),
              const SizedBox(width: 8),
              Text('Fond grisé', style: T.bodyMuted),
            ]),
          ),
      ],
    ];
  }
}

class _TextProp extends StatefulWidget {
  const _TextProp({
    required this.label,
    required this.value,
    required this.onChanged,
    this.multiline = false,
  });
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool multiline;

  @override
  State<_TextProp> createState() => _TextPropState();
}

class _TextPropState extends State<_TextProp> {
  late final _ctrl = TextEditingController(text: widget.value);
  String _last = '';

  @override
  void initState() {
    super.initState();
    _last = widget.value;
  }

  @override
  void didUpdateWidget(_TextProp old) {
    super.didUpdateWidget(old);
    if (widget.value != _last && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
      _last = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      MicroLabel(widget.label.toUpperCase()),
      const SizedBox(height: 4),
      Container(
        decoration: BoxDecoration(
          color: T.bg,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border),
        ),
        child: TextField(
          controller: _ctrl,
          maxLines: widget.multiline ? 4 : 1,
          style: T.body.copyWith(fontSize: 12.5),
          onChanged: (v) {
            _last = v;
            widget.onChanged(v);
          },
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
        ),
      ),
    ]);
  }
}

class _NumProp extends StatefulWidget {
  const _NumProp(
      {required this.label, required this.value, required this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_NumProp> createState() => _NumPropState();
}

class _NumPropState extends State<_NumProp> {
  late final _ctrl = TextEditingController(text: _fmt(widget.value));
  final _focus = FocusNode();

  String _fmt(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  @override
  void didUpdateWidget(_NumProp old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _fmt(widget.value) != _ctrl.text) {
      _ctrl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final v = double.tryParse(_ctrl.text.replaceAll(',', '.'));
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MicroLabel(widget.label.toUpperCase()),
        const SizedBox(height: 4),
        Container(
          height: 32,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: T.border),
          ),
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            style: T.monoBody.copyWith(fontSize: 12),
            onChanged: (_) => _commit(),
            onSubmitted: (_) => _commit(),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  const _ToggleBtn(
      {required this.icon,
      required this.active,
      required this.tip,
      required this.onTap});
  final IconData icon;
  final bool active;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsetsDirectional.only(end: 4),
          decoration: BoxDecoration(
            color: active ? T.mintTint : T.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: active ? T.mintDeep : T.border),
          ),
          child: Icon(icon, size: 16, color: active ? T.mintDark : T.muted),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ new dialog

class _NewTemplateDialog extends StatefulWidget {
  const _NewTemplateDialog();

  @override
  State<_NewTemplateDialog> createState() => _NewTemplateDialogState();
}

class _NewTemplateDialogState extends State<_NewTemplateDialog> {
  String _kind = 'label';
  String _lang = 'fr';
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rCard)),
      child: SizedBox(
        width: 430,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nouveau modèle', style: T.h2),
              const SizedBox(height: 14),
              const MicroLabel('TYPE DE DOCUMENT'),
              const SizedBox(height: 6),
              Row(children: [
                for (final k in ['label', 'invoice', 'warranty'])
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _kind = k),
                      borderRadius: BorderRadius.circular(T.rInner),
                      child: Container(
                        margin: const EdgeInsetsDirectional.only(end: 8),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _kind == k ? T.mintTint : T.bg,
                          borderRadius: BorderRadius.circular(T.rInner),
                          border: Border.all(
                              color: _kind == k ? T.mintDeep : T.border),
                        ),
                        child: Column(children: [
                          Icon(_kindIcons[k],
                              size: 20,
                              color: _kind == k ? T.mintDark : T.muted),
                          const SizedBox(height: 5),
                          Text(_kindLabels[k]!,
                              style: T.small.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: _kind == k ? T.mintDark : T.muted)),
                        ]),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 12),
              const MicroLabel('LANGUE'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                for (final (code, label) in [('fr', 'Français'), ('ar', 'العربية')])
                  ChoiceChip(
                    label: Text(label,
                        style: TextStyle(
                            fontFamily:
                                code == 'ar' ? 'IBMPlexSansArabic' : T.sans,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _lang == code ? T.mintDark : T.muted)),
                    selected: _lang == code,
                    selectedColor: T.mintTint,
                    backgroundColor: T.bg,
                    side: BorderSide(
                        color: _lang == code ? T.mintDeep : T.border),
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _lang = code),
                  ),
              ]),
              const SizedBox(height: 12),
              const MicroLabel('NOM DU MODÈLE'),
              const SizedBox(height: 4),
              Container(
                height: 38,
                decoration: BoxDecoration(
                  color: T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: TextField(
                  controller: _name,
                  autofocus: true,
                  style: T.body,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'ex. Étiquette rayon, Garantie arabe…',
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Annuler', style: T.small.copyWith(color: T.muted)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: PrimaryButton(
                    label: 'Créer',
                    onPressed: () {
                      final name = _name.text.trim().isEmpty
                          ? _kindLabels[_kind]!
                          : _name.text.trim();
                      Navigator.of(context).pop((_kind, _lang, name));
                    },
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
