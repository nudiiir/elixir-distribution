import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:win32/win32.dart';

import '../../api/client.dart';
import '../../api/cloud.dart';
import '../../api/models.dart';
import '../../api/webstore_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/ui.dart';
import '../settings/general_widgets.dart';

export '../../api/webstore_api.dart';
export '../settings/general_widgets.dart'
    show LabeledField, FieldLabel, FieldPair, SwitchRow, InfoBanner, fmtDateTime;

/// Everything a « Boutique en ligne » section needs.
class WebCtx {
  WebCtx({
    required this.api,
    required this.client,
    required this.store,
    required this.onStore,
    required this.reload,
    required this.publish,
    required this.open,
  });

  final ApiClient api;
  final CloudClient client;
  final WebStore store;

  /// A call returned a fresher store object (after save, pause…).
  final ValueChanged<WebStore> onStore;

  /// Reloads the store (counters).
  final Future<void> Function() reload;

  /// « Publier le catalogue » (+ photos).
  final Future<void> Function() publish;

  /// Opens another section of the module by id.
  final ValueChanged<String> open;

  static Future<List<Product>>? _products;
  static Future<List<Category>>? _categories;

  /// Shop products, loaded once per visit of the module (pickers, names).
  Future<List<Product>> products({bool refresh = false}) {
    if (refresh || _products == null) {
      _products = api.allProducts();
      _products!.catchError((_) {
        _products = null;
        return <Product>[];
      });
    }
    return _products!;
  }

  Future<List<Category>> categories({bool refresh = false}) {
    if (refresh || _categories == null) {
      _categories = api.categories();
      _categories!.catchError((_) {
        _categories = null;
        return <Category>[];
      });
    }
    return _categories!;
  }

  static void resetCaches() {
    _products = null;
    _categories = null;
  }

  /// Public address of the store (custom domain when verified).
  String get publicUrl =>
      store.publicUrl.isNotEmpty ? store.publicUrl : store.url;

  /// Image of the media library, served by the store.
  String assetUrl(String id) => '${store.url}/a/$id';
}

/// Opens [url] in the default browser (or the phone/WhatsApp app for tel:).
Future<void> openWebUrl(String url) async {
  try {
    final ok =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (ok) return;
  } catch (_) {}
  // Plan B: the Windows shell.
  await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
}

/// The message of an error, ready to show.
String errText(Object e) => e is CloudException ? e.message : '$e';

void toastError(BuildContext context, String what, Object e) {
  final details = e is WebApiException && e.errors.isNotEmpty
      ? '\n${e.errors.take(4).join('\n')}'
      : '';
  showToast(context, '$what : ${errText(e)}$details', kind: ToastKind.error);
}

Future<void> copyText(BuildContext context, String text,
    {String what = 'Copié'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, '$what dans le presse-papiers.');
}

// ---------------------------------------------------------------------------
// Value checks (DESKTOP_API.md §1 « Common value rules »)
// ---------------------------------------------------------------------------

final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');
bool isHexColor(String s) => _hex.hasMatch(s);

/// Null when [s] is empty or a link the site accepts, else the error text.
String? checkLink(String s) {
  final v = s.trim();
  if (v.isEmpty) return null;
  if (v.contains(RegExp(r'\s'))) return 'Pas d’espace dans un lien.';
  final l = v.toLowerCase();
  if (l.startsWith('https://') || l.startsWith('http://')) {
    return v.length > 8 ? null : 'Lien incomplet.';
  }
  if (l.startsWith('//')) return 'Commencez par https://';
  if (l.startsWith('/') || l.startsWith('#')) return null;
  if (l.startsWith('mailto:') || l.startsWith('tel:')) return null;
  return 'Lien invalide : https://…, /chemin, mailto: ou tel:';
}

String? checkEmail(String s) {
  final v = s.trim();
  if (v.isEmpty) return null;
  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v)
      ? null
      : 'Adresse e-mail invalide.';
}

Color hexColor(String s, [Color fallback = T.mint]) {
  if (!isHexColor(s)) return fallback;
  return Color(0xFF000000 | int.parse(s.substring(1), radix: 16));
}

String fmtBytes(int b) {
  if (b < 1024) return '$b o';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} Ko';
  return '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} Mo';
}

/// « 09/10/2026 » from an ISO date or datetime.
String fmtDay(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// Standard frame of a section: title, one-line explanation, labelled
/// actions on the right, scrolling body.
class WebPane extends StatelessWidget {
  const WebPane({
    super.key,
    required this.title,
    required this.children,
    this.intro,
    this.actions = const [],
    this.maxWidth = 960,
  });
  final String title;
  final String? intro;
  final List<Widget> children;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            WebPaneHeader(title: title, intro: intro, actions: actions),
            const SizedBox(height: 18),
            ...children,
          ]),
        ),
      ),
    );
  }
}

class WebPaneHeader extends StatelessWidget {
  const WebPaneHeader(
      {super.key, required this.title, this.intro, this.actions = const []});
  final String title;
  final String? intro;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(title, style: T.h1)),
        ...actions,
      ]),
      if (intro != null) ...[
        const SizedBox(height: 6),
        Text(intro!, style: T.bodyMuted),
      ],
    ]);
  }
}

/// A titled white block inside a section.
class WebBlock extends StatelessWidget {
  const WebBlock(
      {super.key, required this.title, required this.children, this.help, this.trailing});
  final String title;
  final String? help;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: T.h2)),
          ?trailing,
        ]),
        if (help != null) ...[
          const SizedBox(height: 4),
          Text(help!, style: T.bodyMuted),
        ],
        const SizedBox(height: 14),
        ...children,
      ]),
    );
  }
}

/// Centered message with one action (loading errors, empty states).
class WebNotice extends StatelessWidget {
  const WebNotice(
      {super.key,
      required this.icon,
      required this.title,
      required this.body,
      this.action});
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card14(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 36, color: T.faint),
            const SizedBox(height: 12),
            Text(title, style: T.h2, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body,
                style: T.bodyMuted.copyWith(height: 1.5),
                textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 14),
              PrimaryButton(label: action!.$1, onPressed: action!.$2),
            ],
          ]),
        ),
      ),
    );
  }
}

const webSpinner = Center(
    child: CircularProgressIndicator(strokeWidth: 2.6, color: T.mintDeep));

/// Loads [future] and shows a spinner, an error with « Réessayer », or
/// [builder]'s result.
class WebLoader<V> extends StatelessWidget {
  const WebLoader(
      {super.key,
      required this.future,
      required this.builder,
      required this.onRetry});
  final Future<V>? future;
  final Widget Function(V) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<V>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return WebNotice(
              icon: Icons.error_outline_rounded,
              title: 'Chargement impossible',
              body: errText(snap.error!),
              action: ('Réessayer', onRetry));
        }
        if (!snap.hasData) return webSpinner;
        return builder(snap.data as V);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

/// A plain vertical field: label above (red « * » when required), the
/// input, then an optional helper line.
Widget webField(
  String label,
  TextEditingController c, {
  bool required = false,
  String? hint,
  String? help,
  String? suffix,
  int maxLines = 1,
  ValueChanged<String>? onChanged,
}) {
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text.rich(TextSpan(text: label, style: T.label, children: [
      if (required)
        const TextSpan(text: ' *', style: TextStyle(color: T.danger)),
    ])),
    const SizedBox(height: 6),
    TextField(
      controller: c,
      style: T.body,
      maxLines: maxLines,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: T.bodyMuted.copyWith(color: T.ghost),
        suffixText: suffix,
        filled: true,
        fillColor: T.bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rInner),
            borderSide: const BorderSide(color: T.mintDeep, width: 1.4)),
      ),
    ),
    if (help != null) ...[
      const SizedBox(height: 4),
      Text(help, style: T.small),
    ],
  ]);
}

/// « Libellé » above a row of choice chips, with one explanation line per
/// option when given.
class ChoiceRow<V> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.help,
  });
  final String label;
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FieldLabel(label),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (v, l) in options)
              ChoiceChip(
                label: Text(l, style: T.body.copyWith(fontSize: 14)),
                selected: v == value,
                selectedColor: T.mintTint2,
                onSelected: (_) => onChanged(v),
              ),
          ]),
          if (help != null) ...[
            const SizedBox(height: 6),
            Text(help!, style: T.small),
          ],
        ]),
      );
}

/// Label above a dropdown (vertical form).
class DropField<V> extends StatelessWidget {
  const DropField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width = 320,
    this.help,
    this.required = false,
  });
  final String label;
  final V? value;
  final List<(V, String)> options;
  final ValueChanged<V?> onChanged;
  final double width;
  final String? help;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final has = options.any((o) => o.$1 == value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label, required: required),
        const SizedBox(height: 6),
        Container(
          width: width,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<V>(
              isExpanded: true,
              value: has ? value : null,
              hint: Text('Choisir…', style: T.bodyMuted),
              style: T.body,
              items: [
                for (final (v, l) in options)
                  DropdownMenuItem<V>(
                      value: v,
                      child: Text(l, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
        if (help != null) ...[
          const SizedBox(height: 5),
          Text(help!, style: T.small),
        ],
      ]),
    );
  }
}

const webPalette = [
  '#00A87C', '#2563EB', '#D97706', '#DC2626', '#7C3AED', '#0F766E',
  '#DB2777', '#0F1113',
];

/// Colour chooser: ready-made swatches + a « #RRGGBB » field.
class ColorField extends StatefulWidget {
  const ColorField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    this.allowEmpty = false,
    this.emptyLabel = 'Par défaut',
  });
  final String label;
  final String value; // '' = default
  final ValueChanged<String> onChanged;
  final String? help;
  final bool allowEmpty;
  final String emptyLabel;

  @override
  State<ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<ColorField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant ColorField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && (isHexColor(widget.value) || widget.value.isEmpty)) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value.toUpperCase();
    final bad = v.isNotEmpty && !isHexColor(v);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(widget.label),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.allowEmpty)
                ChoiceChip(
                  label: Text(widget.emptyLabel,
                      style: T.body.copyWith(fontSize: 13.5)),
                  selected: v.isEmpty,
                  selectedColor: T.mintTint2,
                  onSelected: (_) {
                    _c.text = '';
                    widget.onChanged('');
                  },
                ),
              for (final c in webPalette)
                Tooltip(
                  message: c,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      _c.text = c;
                      widget.onChanged(c);
                    },
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: hexColor(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                            width: v == c ? 3 : 1,
                            color: v == c ? T.ink : T.border),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _c,
                  style: T.monoBody,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[#0-9A-Fa-f]')),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  onChanged: (s) => widget.onChanged(s.trim().toUpperCase()),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '#00A87C',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                            color: isHexColor(v) ? hexColor(v) : T.border2,
                            borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(T.rInner)),
                  ),
                ),
              ),
            ]),
        if (bad)
          const FieldError('Couleur au format #RRGGBB (ex. #00A87C).')
        else if (widget.help != null) ...[
          const SizedBox(height: 6),
          Text(widget.help!, style: T.small),
        ],
      ]),
    );
  }
}

/// Small coloured status pill.
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.kind = ToastKind.info});
  final String text;
  final ToastKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      ToastKind.success => (T.mintTint2, T.mintDark),
      ToastKind.warning => (const Color(0xFFFFF1DB), const Color(0xFFA96311)),
      ToastKind.error => (const Color(0xFFFBE3E3), T.dangerDark),
      ToastKind.info => (T.border2, T.muted),
    };
    return MintChip(text, color: bg, fg: fg);
  }
}

// ---------------------------------------------------------------------------
// Rendering of the server's markdown preview (safe subset → widgets)
// ---------------------------------------------------------------------------

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&amp;', '&');

List<InlineSpan> _inlineSpans(String html, TextStyle base) {
  final spans = <InlineSpan>[];
  var bold = 0, italic = 0, link = 0;
  final tag = RegExp(r'<(/?)(strong|em|a|br)(\s[^>]*)?>');
  var pos = 0;
  void text(String t) {
    if (t.isEmpty) return;
    spans.add(TextSpan(
      text: _unescape(t),
      style: base.copyWith(
        fontWeight: bold > 0 ? FontWeight.w800 : null,
        fontStyle: italic > 0 ? FontStyle.italic : null,
        color: link > 0 ? T.mintDark : null,
        decoration: link > 0 ? TextDecoration.underline : null,
      ),
    ));
  }

  for (final m in tag.allMatches(html)) {
    text(html.substring(pos, m.start));
    pos = m.end;
    final close = m.group(1) == '/';
    final d = close ? -1 : 1;
    switch (m.group(2)) {
      case 'strong':
        bold += d;
      case 'em':
        italic += d;
      case 'a':
        link += d;
      case 'br':
        spans.add(const TextSpan(text: '\n'));
    }
  }
  text(html.substring(pos));
  return spans;
}

/// Shows the HTML returned by POST /store/markdown/preview.
class HtmlPreview extends StatelessWidget {
  const HtmlPreview(this.html, {super.key});
  final String html;

  @override
  Widget build(BuildContext context) {
    final blocks = RegExp(r'<(h2|h3|h4|p|ul|ol)>([\s\S]*?)</\1>');
    final out = <Widget>[];
    for (final m in blocks.allMatches(html)) {
      final t = m.group(1)!;
      final inner = m.group(2)!;
      switch (t) {
        case 'h2' || 'h3' || 'h4':
          final style = t == 'h2'
              ? T.h2.copyWith(fontSize: 19)
              : (t == 'h3' ? T.h2 : T.h2.copyWith(fontSize: 15.5));
          out.add(Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text.rich(TextSpan(children: _inlineSpans(inner, style))),
          ));
        case 'p':
          out.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(TextSpan(children: _inlineSpans(inner, T.body))),
          ));
        default:
          final items = RegExp(r'<li>([\s\S]*?)</li>').allMatches(inner).toList();
          for (var i = 0; i < items.length; i++) {
            out.add(Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 22,
                    child: Text(t == 'ol' ? '${i + 1}.' : '•', style: T.body)),
                Expanded(
                  child: Text.rich(TextSpan(
                      children: _inlineSpans(items[i].group(1)!, T.body))),
                ),
              ]),
            ));
          }
          out.add(const SizedBox(height: 6));
      }
    }
    if (out.isEmpty) {
      return Text('(rien à afficher)', style: T.bodyMuted);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: out);
  }
}

/// Text editor for the site's simple formatting, with « Aperçu » rendered
/// by the server exactly as the site will show it.
class MarkdownField extends StatefulWidget {
  const MarkdownField({
    super.key,
    required this.label,
    required this.controller,
    required this.client,
    this.maxLength,
    this.minLines = 6,
    this.help,
    this.required = false,
    this.onChanged,
  });
  final String label;
  final TextEditingController controller;
  final CloudClient client;
  final int? maxLength;
  final int minLines;
  final String? help;
  final bool required;
  final ValueChanged<String>? onChanged;

  @override
  State<MarkdownField> createState() => _MarkdownFieldState();
}

class _MarkdownFieldState extends State<MarkdownField> {
  String? _html;
  bool _busy = false;
  String? _error;

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _html = await widget.client.webMarkdownPreview(widget.controller.text);
    } catch (e) {
      _error = errText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _wrap(String left, [String? right]) {
    final c = widget.controller;
    final sel = c.selection;
    final text = c.text;
    if (!sel.isValid) {
      c.text = '$text$left${right ?? ''}';
    } else {
      final inner = sel.textInside(text);
      c.value = TextEditingValue(
        text: sel.textBefore(text) + left + inner + (right ?? '') + sel.textAfter(text),
        selection: TextSelection.collapsed(
            offset: sel.start + left.length + inner.length + (right?.length ?? 0)),
      );
    }
    widget.onChanged?.call(c.text);
    setState(() {});
  }

  void _linePrefix(String prefix) {
    final c = widget.controller;
    final sel = c.selection;
    final text = c.text;
    final at = sel.isValid ? sel.start : text.length;
    final lineStart = text.lastIndexOf('\n', at > 0 ? at - 1 : 0) + 1;
    final start = at == 0 ? 0 : lineStart;
    c.value = TextEditingValue(
      text: text.substring(0, start) + prefix + text.substring(start),
      selection: TextSelection.collapsed(offset: at + prefix.length),
    );
    widget.onChanged?.call(c.text);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final len = widget.controller.text.length;
    final over = widget.maxLength != null && len > widget.maxLength!;
    Widget tool(String label, String tip, VoidCallback onTap) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 6),
          child: Tooltip(
            message: tip,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: T.ink,
                side: const BorderSide(color: T.border3),
              ),
              onPressed: onTap,
              child: Text(label, style: T.small.copyWith(color: T.ink, fontWeight: FontWeight.w700)),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          FieldLabel(widget.label, required: widget.required),
          const Spacer(),
          if (widget.maxLength != null)
            Text('$len / ${widget.maxLength}',
                style: T.small.copyWith(color: over ? T.dangerDark : T.faint)),
        ]),
        const SizedBox(height: 6),
        Wrap(runSpacing: 6, children: [
          tool('Titre', 'Ligne de titre (## )', () => _linePrefix('## ')),
          tool('Gras', '**texte en gras**', () => _wrap('**', '**')),
          tool('Italique', '*texte en italique*', () => _wrap('*', '*')),
          tool('Liste', 'Ligne à puce (- )', () => _linePrefix('- ')),
          tool('Lien', '[texte](https://…)', () => _wrap('[', '](https://)')),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _busy ? null : _preview,
            icon: const Icon(Icons.visibility_outlined, size: 17),
            label: Text(_busy ? 'Aperçu…' : 'Aperçu'),
          ),
        ]),
        const SizedBox(height: 6),
        TextField(
          controller: widget.controller,
          minLines: widget.minLines,
          maxLines: widget.minLines + 10,
          style: T.body,
          onChanged: (v) {
            widget.onChanged?.call(v);
            setState(() {});
          },
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: T.surface,
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rInner),
                borderSide: BorderSide(color: over ? T.danger : T.border3)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rInner),
                borderSide: BorderSide(color: over ? T.danger : T.border3)),
          ),
        ),
        const SizedBox(height: 5),
        Text(
            widget.help ??
                'Mise en forme simple : ## titre, **gras**, *italique*, - liste, '
                    '[texte](lien). Ligne vide = nouveau paragraphe.',
            style: T.small),
        if (_error != null) FieldError(_error),
        if (_html != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: T.bg,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Aperçu (comme sur le site)', style: T.label),
                const Spacer(),
                TextButton(
                    onPressed: () => setState(() => _html = null),
                    child: const Text('Fermer l’aperçu')),
              ]),
              const SizedBox(height: 6),
              HtmlPreview(_html!),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Multi-file image picker (Windows common dialog)
// ---------------------------------------------------------------------------

/// « Ouvrir » dialog allowing several images at once. Empty list = cancelled.
List<String> pickImageFiles() {
  const size = 32768;
  final ofn = calloc<OPENFILENAME>();
  final buf = calloc<Uint16>(size);
  const filterSpec = 'Images (png, jpg, webp)\x00*.png;*.jpg;*.jpeg;*.webp\x00\x00';
  final filter = calloc<Uint16>(filterSpec.length + 1);
  for (var i = 0; i < filterSpec.length; i++) {
    filter[i] = filterSpec.codeUnitAt(i);
  }
  try {
    ofn.ref.lStructSize = sizeOf<OPENFILENAME>();
    ofn.ref.lpstrFile = buf.cast<Utf16>();
    ofn.ref.nMaxFile = size;
    ofn.ref.lpstrFilter = filter.cast<Utf16>();
    ofn.ref.Flags = OFN_FILEMUSTEXIST |
        OFN_PATHMUSTEXIST |
        OFN_EXPLORER |
        OFN_ALLOWMULTISELECT;
    if (GetOpenFileName(ofn) == 0) return const [];
    // dir\0file1\0file2\0\0  — or a single full path\0\0
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < size; i++) {
      if (buf[i] == 0) {
        if (i == start) break;
        parts.add(String.fromCharCodes(buf.asTypedList(size).sublist(start, i)));
        start = i + 1;
      }
    }
    if (parts.isEmpty) return const [];
    if (parts.length == 1) return parts;
    final dir = parts.first;
    return [for (final f in parts.skip(1)) '$dir\\$f'];
  } finally {
    free(filter);
    free(buf);
    free(ofn);
  }
}
