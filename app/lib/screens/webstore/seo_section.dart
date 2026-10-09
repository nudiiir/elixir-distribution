import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import 'media_section.dart';
import 'web_common.dart';

/// « Référencement » : what Google and social networks show for the home
/// page (title, description, share image).
class SeoSection extends StatefulWidget {
  const SeoSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<SeoSection> createState() => _SeoSectionState();
}

class _SeoSectionState extends State<SeoSection> {
  Map<String, dynamic> get _t => widget.ctx.store.theme;
  late final _title = TextEditingController(text: '${_t['meta_title'] ?? ''}');
  late final _desc = TextEditingController(text: '${_t['meta_description'] ?? ''}');
  late String? _og = (_t['og_image'] as String?)?.isEmpty ?? true ? null : _t['og_image'] as String;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.length > 120 || _desc.text.length > 320) {
      showToast(context, 'Texte trop long (titre 120, description 320 caractères).',
          kind: ToastKind.warning);
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await widget.ctx.client.webConfig({
        'theme': {
          'meta_title': _title.text.trim(),
          'meta_description': _desc.text.trim(),
          'og_image': _og ?? '',
        },
      });
      widget.ctx.onStore(s);
      if (mounted) showToast(context, 'Référencement enregistré.');
    } catch (e) {
      if (mounted) toastError(context, 'Enregistrement impossible', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.ctx.store;
    final title = _title.text.trim().isEmpty
        ? '${s.name} — boutique en ligne'
        : _title.text.trim();
    final about = '${_t['about'] ?? ''}';
    final desc = _desc.text.trim().isEmpty ? about : _desc.text.trim();
    return WebPane(
      title: 'Référencement',
      intro: 'Ce que Google, Facebook ou WhatsApp affichent quand on cherche ou '
          'partage votre boutique.',
      actions: [
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      children: [
        WebBlock(title: 'Résultat Google', children: [
          LabeledField(
            label: 'Titre de la page d’accueil (${_title.text.length}/120)',
            controller: _title,
            hint: '${s.name} — boutique en ligne',
            help: 'Vide = « ${s.name} — boutique en ligne ». Idéal : 50 à 60 caractères.',
            onChanged: (_) => setState(() {}),
          ),
          LabeledField(
            label: 'Description (${_desc.text.length}/320)',
            controller: _desc,
            maxLines: 3,
            help: 'Vide = votre présentation. Idéal : 120 à 160 caractères, avec la ville et '
                'ce que vous vendez.',
            onChanged: (_) => setState(() {}),
          ),
          FieldLabel('Aperçu'),
          const SizedBox(height: 6),
          Container(
            width: 600,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border3),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.ctx.publicUrl, style: T.small),
              const SizedBox(height: 2),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, color: Color(0xFF1A0DAB), fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(desc.length > 160 ? '${desc.substring(0, 157)}…' : desc,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: T.bodyMuted),
            ]),
          ),
        ]),
        WebBlock(
          title: 'Image de partage',
          help: 'Affichée quand le lien est partagé (WhatsApp, Facebook). Vide = la '
              'grande bannière, sinon le logo. Format conseillé : 1200 × 630 px.',
          children: [
            AssetField(
              ctx: widget.ctx,
              label: 'Image',
              value: _og,
              onChanged: (v) => setState(() => _og = v),
            ),
          ],
        ),
      ],
    );
  }
}
