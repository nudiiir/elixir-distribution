import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../stock/stock_common.dart' show pickProduct;
import 'media_section.dart';
import 'web_common.dart';

// ---------------------------------------------------------------------------
// Section types (DESKTOP_API.md §5)
// ---------------------------------------------------------------------------

/// (name, icon, one-line explanation) of a section type.
(String, IconData, String) sectionMeta(String type) => switch (type) {
      'hero' => ('Grande bannière', Icons.panorama_outlined,
          'Image, titre et bouton en haut de la page.'),
      'banner_carousel' => ('Diaporama', Icons.view_carousel_outlined,
          'Plusieurs images qui défilent.'),
      'categories' => ('Rayons', Icons.category_outlined, 'Les catégories du catalogue.'),
      'products' => ('Produits', Icons.grid_view_rounded,
          'Promotions, nouveautés, sélection, une marque, une catégorie…'),
      'brands' => ('Marques', Icons.verified_outlined, 'Logos ou noms des marques.'),
      'text_image' => ('Texte et image', Icons.article_outlined,
          'Présentation du magasin, votre histoire…'),
      'features' => ('Points forts', Icons.star_outline_rounded,
          'Livraison, paiement à la livraison, conseils…'),
      'testimonials' => ('Avis clients', Icons.format_quote_rounded, 'Témoignages de clients.'),
      'faq' => ('Questions fréquentes', Icons.help_outline_rounded,
          'Questions et réponses dépliables.'),
      'contact_map' => ('Contact et carte', Icons.map_outlined,
          'Adresse, téléphone, horaires et carte.'),
      'cta' => ('Appel à l’action', Icons.campaign_outlined, 'Un message fort et un bouton.'),
      'countdown' => ('Compte à rebours', Icons.timer_outlined,
          'Offre limitée avec une date de fin.'),
      _ => (type, Icons.widgets_outlined, 'Section'),
    };

String sectionLabel(Map<String, dynamic> s) {
  final t = '${s['title'] ?? ''}'.trim();
  if (t.isNotEmpty) return t;
  final st = (s['settings'] as Map?) ?? const {};
  final inner = '${st['title'] ?? st['text'] ?? ''}'.trim();
  if (inner.isNotEmpty) return inner;
  return sectionMeta('${s['type']}').$1;
}

const _sources = [
  ('featured', 'Sélection du magasin'),
  ('promotions', 'Promotions'),
  ('new', 'Nouveautés'),
  ('category', 'Une catégorie'),
  ('brand', 'Une marque'),
  ('manual', 'Choix manuel'),
];

String sectionSummary(Map<String, dynamic> s) {
  final st = (s['settings'] as Map?) ?? const {};
  int n(String k) => (st[k] as List?)?.length ?? 0;
  return switch ('${s['type']}') {
    'hero' => st['image'] != null ? 'image choisie' : 'bannière du magasin',
    'banner_carousel' => '${n('slides')} image(s)',
    'categories' => st['mode'] == 'selection' ? '${n('items')} rayon(s) choisi(s)' : 'tous les rayons',
    'products' => [
        _sources.firstWhere((e) => e.$1 == st['source'], orElse: () => ('', '${st['source']}')).$2,
        if (st['category'] != null) '${st['category']}',
        if (st['brand'] != null) '${st['brand']}',
        if (st['source'] == 'manual') '${n('ids')} produit(s)',
        'max ${st['max'] ?? 8}',
      ].join(' · '),
    'brands' => st['source'] == 'manual' ? '${n('items')} marque(s)' : 'automatique',
    'features' => '${n('items')} point(s)',
    'testimonials' => '${n('items')} avis',
    'faq' => '${n('items')} question(s)',
    'countdown' => st['ends_at'] == null ? '' : 'jusqu’au ${fmtDateTime('${st['ends_at']}')}',
    _ => '',
  };
}

String? defaultSectionTitle(String type) => switch (type) {
      'products' => 'Nos produits',
      'categories' => 'Nos rayons',
      'features' => 'Pourquoi nous choisir',
      'testimonials' => 'Ils nous font confiance',
      'faq' => 'Questions fréquentes',
      'contact_map' => 'Nous trouver',
      _ => null,
    };

Map<String, dynamic> defaultSectionSettings(String type) => switch (type) {
      'products' => {'source': 'featured', 'max': 8, 'layout': 'grid', 'show_more': true},
      'categories' => {'mode': 'all', 'max': 12},
      'brands' => {'source': 'auto', 'max': 12},
      'banner_carousel' => {'slides': <dynamic>[], 'autoplay': true, 'interval': 5},
      'features' => {
          'items': [
            {'icon': 'truck', 'title': 'Livraison', 'text': '{livraison}'},
            {'icon': 'cash', 'title': 'Paiement à la livraison', 'text': 'Vous payez à la réception.'},
            {'icon': 'phone', 'title': 'Conseil', 'text': 'Une question ? Appelez-nous.'},
          ]
        },
      'testimonials' => {'items': <dynamic>[]},
      'faq' => {'items': <dynamic>[]},
      'contact_map' => {'show_map': true},
      'cta' => {'text': ''},
      'countdown' => {
          'ends_at': DateTime.now().add(const Duration(days: 7)).toUtc().toIso8601String(),
          'link': '/l?promo=1',
        },
      _ => <String, dynamic>{},
    };

const _iconNames = {
  'truck': 'Camion (livraison)',
  'cash': 'Billets (paiement)',
  'shield': 'Bouclier (garantie)',
  'clock': 'Horloge (rapidité)',
  'phone': 'Téléphone',
  'star': 'Étoile',
  'gift': 'Cadeau',
  'leaf': 'Feuille (naturel)',
  'box': 'Colis',
  'check': 'Coche',
  'map': 'Carte',
  'card': 'Carte bancaire',
  'chat': 'Discussion',
  'return': 'Retour',
  'medal': 'Médaille',
};

// ---------------------------------------------------------------------------
// Editor page
// ---------------------------------------------------------------------------

/// Detail page of one landing-page section. [onSave] sends the whole list
/// with this section and returns the server's errors (null = saved).
class SectionEditorPage extends StatefulWidget {
  const SectionEditorPage({
    super.key,
    required this.ctx,
    required this.info,
    required this.section,
    required this.onSave,
    this.isNew = false,
  });
  final WebCtx ctx;
  final WebSectionsInfo info;
  final Map<String, dynamic> section;
  final Future<List<String>?> Function(Map<String, dynamic>) onSave;
  final bool isNew;

  @override
  State<SectionEditorPage> createState() => _SectionEditorPageState();
}

class _SectionEditorPageState extends State<SectionEditorPage> {
  late final Map<String, dynamic> _s = widget.section;
  late final Map<String, dynamic> _st = () {
    final m = _s['settings'];
    if (m is Map<String, dynamic>) return m;
    final n = <String, dynamic>{};
    _s['settings'] = n;
    return n;
  }();
  final _ctl = <String, TextEditingController>{};
  List<String> _errors = const [];
  bool _busy = false;
  List<Product> _products = const [];
  List<Category> _categories = const [];
  List<WebPromoCode> _codes = const [];

  String get _type => '${_s['type']}';

  @override
  void initState() {
    super.initState();
    if (['products', 'categories', 'brands'].contains(_type)) {
      widget.ctx.products().then((v) {
        if (mounted) setState(() => _products = v);
      }).catchError((_) {});
      widget.ctx.categories().then((v) {
        if (mounted) setState(() => _categories = v);
      }).catchError((_) {});
    }
    if (_type == 'countdown') {
      widget.ctx.client.webPromoCodes().then((v) {
        if (mounted) setState(() => _codes = v);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- bound controllers --------------------------------------------------

  TextEditingController _text(Map m, String f) {
    return _ctl.putIfAbsent('${identityHashCode(m)}/$f', () {
      final c = TextEditingController(text: m[f] == null ? '' : '${m[f]}');
      c.addListener(() {
        if (c.text.trim().isEmpty) {
          m.remove(f);
        } else {
          m[f] = c.text;
        }
      });
      return c;
    });
  }

  TextEditingController _int(Map m, String f) {
    return _ctl.putIfAbsent('${identityHashCode(m)}/$f#i', () {
      final c = TextEditingController(text: m[f] == null ? '' : '${m[f]}');
      c.addListener(() {
        final v = int.tryParse(c.text.trim());
        if (v == null) {
          m.remove(f);
        } else {
          m[f] = v;
        }
      });
      return c;
    });
  }

  Widget _field(Map m, String f, String label,
      {String? help, String? hint, int maxLines = 1, bool required = false, int? max}) {
    final c = _text(m, f);
    return LabeledField(
      label: max == null ? label : '$label (${c.text.length}/$max)',
      controller: c,
      help: help,
      hint: hint,
      maxLines: maxLines,
      required: required,
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _link(Map m, String f, String label, {String? help, String? hint}) {
    final c = _text(m, f);
    return LabeledField(
      label: label,
      controller: c,
      hint: hint ?? '/l, /page/livraison, https://…',
      help: help ?? 'Une page du site (/l = tous les produits, /l?promo=1 = promotions, '
          '/marque/…, /page/…) ou une adresse https://.',
      error: checkLink(c.text),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _number(Map m, String f, String label, int min, int max, {String? help, int? def}) {
    final c = _int(m, f);
    final v = int.tryParse(c.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label),
        const SizedBox(height: 6),
        SizedBox(
          width: 140,
          child: TextField(
            controller: c,
            style: T.monoBody,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: def == null ? null : '$def',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(T.rInner)),
            ),
          ),
        ),
        if (v != null && (v < min || v > max))
          FieldError('Entre $min et $max.')
        else
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(help ?? 'De $min à $max${def == null ? '' : ' (vide = $def)'}.',
                style: T.small),
          ),
      ]),
    );
  }

  Widget _switch(Map m, String f, String title, {String? help, bool def = true}) => SwitchRow(
        title: title,
        explanation: help,
        value: m[f] is bool ? m[f] as bool : def,
        onChanged: (v) => setState(() => m[f] = v),
      );

  Widget _chips(Map m, String f, String label, List<(String, String)> options,
          {String? def, String? help}) =>
      ChoiceRow<String?>(
        label: label,
        value: (m[f] as String?) ?? def,
        options: options,
        help: help,
        onChanged: (v) => setState(() => v == null ? m.remove(f) : m[f] = v),
      );

  Widget _asset(Map m, String f, String label, {String? help, bool required = false}) =>
      AssetField(
        ctx: widget.ctx,
        label: label,
        value: m[f] as String?,
        required: required,
        help: help,
        onChanged: (v) => setState(() => v == null ? m.remove(f) : m[f] = v),
      );

  Widget _md(Map m, String f, String label, {int max = 2000, int minLines = 5, bool required = false}) =>
      MarkdownField(
        label: label,
        controller: _text(m, f),
        client: widget.ctx.client,
        maxLength: max,
        minLines: minLines,
        required: required,
      );

  List<dynamic> _list(String f) {
    final v = _st[f];
    if (v is List) return v;
    final l = <dynamic>[];
    _st[f] = l;
    return l;
  }

  /// Editable list of items (slides, FAQ, reviews…): each item in a card
  /// with « Monter », « Descendre », « Retirer ».
  Widget _items({
    required String field,
    required String addLabel,
    required int max,
    required Map<String, dynamic> Function() create,
    required String Function(Map item, int i) title,
    required List<Widget> Function(Map item) fields,
  }) {
    final items = _list(field);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < items.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rCard),
            border: Border.all(color: T.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${i + 1}. ${title(items[i] as Map, i)}',
                    style: T.body.copyWith(fontWeight: FontWeight.w700)),
              ),
              TextButton(
                  onPressed: i == 0
                      ? null
                      : () => setState(() => items.insert(i - 1, items.removeAt(i))),
                  child: const Text('Monter')),
              TextButton(
                  onPressed: i == items.length - 1
                      ? null
                      : () => setState(() => items.insert(i + 1, items.removeAt(i))),
                  child: const Text('Descendre')),
              TextButton(
                  style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                  onPressed: () => setState(() => items.removeAt(i)),
                  child: const Text('Retirer')),
            ]),
            const SizedBox(height: 8),
            ...fields(items[i] as Map),
          ]),
        ),
      OutlinedButton.icon(
        onPressed: items.length >= max ? null : () => setState(() => items.add(create())),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: Text(items.length >= max ? 'Maximum $max' : addLabel),
      ),
    ]);
  }

  // ---- lookups --------------------------------------------------------------

  List<String> get _categoryNames {
    final names = <String>{for (final c in _categories) c.name};
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<String> get _brandNames {
    final names = <String>{
      for (final p in _products)
        if (p.brand.trim().isNotEmpty) p.brand.trim()
    };
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // ---- validation ---------------------------------------------------------

  List<String> _validate() {
    final e = <String>[];
    final title = '${_s['title'] ?? ''}';
    if (title.length > 120) e.add('Titre : 120 caractères maximum.');
    void link(Map m, String f, String label) {
      final err = checkLink('${m[f] ?? ''}');
      if (err != null) e.add('$label : $err');
    }

    void maxLen(Map m, String f, int max, String label) {
      if ('${m[f] ?? ''}'.length > max) e.add('$label : $max caractères maximum.');
    }

    switch (_type) {
      case 'hero':
        link(_st, 'cta_link', 'Lien du bouton');
        maxLen(_st, 'title', 120, 'Titre');
        maxLen(_st, 'subtitle', 300, 'Sous-titre');
        maxLen(_st, 'cta_text', 40, 'Texte du bouton');
      case 'banner_carousel':
        final slides = _list('slides');
        if (slides.isEmpty) e.add('Ajoutez au moins une image.');
        for (var i = 0; i < slides.length; i++) {
          final sl = slides[i] as Map;
          if (sl['image'] == null) e.add('Image ${i + 1} : choisissez une image.');
          link(sl, 'link', 'Image ${i + 1}, lien');
        }
      case 'products':
        final src = _st['source'];
        if (src == 'category' && (_st['category'] ?? '').toString().isEmpty) {
          e.add('Choisissez la catégorie.');
        }
        if (src == 'brand' && (_st['brand'] ?? '').toString().isEmpty) e.add('Choisissez la marque.');
        if (src == 'manual' && _list('ids').isEmpty) e.add('Ajoutez au moins un produit.');
      case 'categories':
        if (_st['mode'] == 'selection' && _list('items').isEmpty) e.add('Choisissez au moins un rayon.');
      case 'brands':
        if (_st['source'] == 'manual') {
          final items = _list('items');
          if (items.isEmpty) e.add('Ajoutez au moins une marque.');
          for (var i = 0; i < items.length; i++) {
            final it = items[i] as Map;
            if ('${it['name'] ?? ''}'.trim().isEmpty) e.add('Marque ${i + 1} : nom obligatoire.');
            link(it, 'link', 'Marque ${i + 1}, lien');
          }
        }
      case 'text_image':
        link(_st, 'cta_link', 'Lien du bouton');
        maxLen(_st, 'body', 5000, 'Texte');
      case 'features':
        final items = _list('items');
        for (var i = 0; i < items.length; i++) {
          final it = items[i] as Map;
          if ('${it['title'] ?? ''}'.trim().isEmpty) e.add('Point ${i + 1} : titre obligatoire.');
          if (it['icon'] == null) e.add('Point ${i + 1} : choisissez une icône.');
        }
      case 'testimonials':
        final items = _list('items');
        for (var i = 0; i < items.length; i++) {
          final it = items[i] as Map;
          if ('${it['name'] ?? ''}'.trim().isEmpty) e.add('Avis ${i + 1} : nom obligatoire.');
          if ('${it['text'] ?? ''}'.trim().isEmpty) e.add('Avis ${i + 1} : texte obligatoire.');
        }
      case 'faq':
        final items = _list('items');
        for (var i = 0; i < items.length; i++) {
          final it = items[i] as Map;
          if ('${it['q'] ?? ''}'.trim().isEmpty) e.add('Question ${i + 1} : question obligatoire.');
          if ('${it['a'] ?? ''}'.trim().isEmpty) e.add('Question ${i + 1} : réponse obligatoire.');
        }
      case 'contact_map':
        link(_st, 'maps_url', 'Lien Google Maps');
        final em = checkEmail('${_st['email'] ?? ''}');
        if (em != null) e.add(em);
      case 'cta':
        if ('${_st['text'] ?? ''}'.trim().isEmpty) e.add('Le message est obligatoire.');
        link(_st, 'link', 'Lien du bouton');
        final col = '${_st['color'] ?? ''}';
        if (col.isNotEmpty && !isHexColor(col)) e.add('Couleur invalide.');
      case 'countdown':
        if (DateTime.tryParse('${_st['ends_at'] ?? ''}') == null) e.add('Choisissez la date de fin.');
        link(_st, 'link', 'Lien du bouton');
    }
    return e;
  }

  Future<void> _save() async {
    final local = _validate();
    if (local.isNotEmpty) {
      setState(() => _errors = local);
      return;
    }
    // Empty strings are not stored; strings are trimmed by the server.
    setState(() {
      _busy = true;
      _errors = const [];
    });
    final errs = await widget.onSave(_s);
    if (!mounted) return;
    if (errs == null) {
      showToast(context, 'Section enregistrée — le site est à jour.');
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _errors = errs;
      });
    }
  }

  // ---- per type -------------------------------------------------------------

  List<Widget> _hero() => [
        _asset(_st, 'image', 'Image de fond',
            help: 'Vide = la grande bannière du magasin (Apparence). Large, au moins 1600 px.'),
        _switch(_st, 'use_cover', 'Utiliser la bannière du magasin si aucune image n’est choisie'),
        const SizedBox(height: 8),
        _field(_st, 'title', 'Titre', hint: widget.ctx.store.name, help: 'Vide = nom de la boutique.', max: 120),
        _field(_st, 'subtitle', 'Sous-titre', maxLines: 2, help: 'Vide = votre présentation.', max: 300),
        FieldPair(
          _field(_st, 'cta_text', 'Texte du bouton', hint: 'Voir les produits', max: 40),
          _link(_st, 'cta_link', 'Lien du bouton', hint: '/l'),
        ),
        _slider(_st, 'overlay', 'Assombrir l’image', 0, 90, def: 30, unit: '%'),
        _chips(_st, 'align', 'Alignement du texte', const [('left', 'À gauche'), ('center', 'Centré')],
            def: 'left'),
        _chips(_st, 'height', 'Hauteur', const [('small', 'Petite'), ('medium', 'Moyenne'), ('large', 'Grande')],
            def: 'medium'),
      ];

  Widget _slider(Map m, String f, String label, int min, int max, {required int def, String unit = ''}) {
    final v = ((m[f] as num?)?.toInt() ?? def).clamp(min, max);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel('$label : $v$unit'),
        SizedBox(
          width: 420,
          child: Slider(
            value: v.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: '$v$unit',
            onChanged: (x) => setState(() => m[f] = x.round()),
          ),
        ),
      ]),
    );
  }

  List<Widget> _carousel() => [
        _items(
          field: 'slides',
          addLabel: 'Ajouter une image',
          max: 8,
          create: () => <String, dynamic>{},
          title: (it, i) => '${it['title'] ?? 'Image'}',
          fields: (it) => [
            _asset(it, 'image', 'Image', required: true, help: 'Format large, ≈ 1600 × 600 px.'),
            _link(it, 'link', 'Lien au clic (facultatif)'),
            _field(it, 'title', 'Titre sur l’image', max: 120),
            _field(it, 'subtitle', 'Texte sous le titre', max: 200),
            _field(it, 'alt', 'Description (pour Google et l’accessibilité)', max: 120),
          ],
        ),
        const SizedBox(height: 16),
        _switch(_st, 'autoplay', 'Défilement automatique'),
        _slider(_st, 'interval', 'Durée de chaque image', 3, 15, def: 5, unit: ' s'),
      ];

  List<Widget> _categoriesEditor() {
    final items = _list('items');
    final available = [for (final n in _categoryNames) if (!items.contains(n)) n];
    return [
      _chips(_st, 'mode', 'Rayons affichés',
          const [('all', 'Tous les rayons'), ('selection', 'Une sélection')],
          def: 'all', help: 'Avec « Tous », la section est cachée si le catalogue n’a qu’un rayon.'),
      if (_st['mode'] == 'selection') ...[
        FieldLabel('Rayons choisis (dans l’ordre d’affichage)'),
        const SizedBox(height: 6),
        for (var i = 0; i < items.length; i++)
          Row(children: [
            SizedBox(width: 28, child: Text('${i + 1}.', style: T.body)),
            Expanded(child: Text('${items[i]}', style: T.body)),
            TextButton(
                onPressed: i == 0 ? null : () => setState(() => items.insert(i - 1, items.removeAt(i))),
                child: const Text('Monter')),
            TextButton(
                style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                onPressed: () => setState(() => items.removeAt(i)),
                child: const Text('Retirer')),
          ]),
        const SizedBox(height: 8),
        if (items.length < 30)
          DropField<String>(
            label: 'Ajouter un rayon',
            value: null,
            options: [for (final n in available) (n, n)],
            onChanged: (v) {
              if (v != null) setState(() => items.add(v));
            },
            help: _categories.isEmpty ? 'Chargement des catégories…' : null,
          ),
      ],
      _number(_st, 'max', 'Nombre maximum de rayons', 1, 30, def: 12),
    ];
  }

  List<Widget> _productsEditor() {
    final src = (_st['source'] as String?) ?? 'featured';
    final ids = _list('ids');
    final names = {for (final p in _products) p.id: p.name};
    return [
      _chips(_st, 'source', 'Quels produits ?', _sources, def: 'featured',
          help: switch (src) {
            'featured' => 'Les produits marqués « En vedette » (étoile) dans « Produits ».',
            'promotions' => 'Les produits en promotion.',
            'new' => 'Les derniers produits ajoutés.',
            'category' => 'Les produits d’une catégorie (ou de ses sous-catégories).',
            'brand' => 'Les produits d’une marque.',
            _ => 'Les produits que vous choisissez, dans l’ordre.',
          }),
      if (src == 'category')
        DropField<String>(
          label: 'Catégorie',
          required: true,
          value: _st['category'] as String?,
          options: [for (final n in _categoryNames) (n, n)],
          onChanged: (v) => setState(() => v == null ? _st.remove('category') : _st['category'] = v),
        ),
      if (src == 'brand')
        _brandNames.isEmpty
            ? _field(_st, 'brand', 'Marque', required: true,
                help: 'Aucune marque dans vos fiches produit : tapez-la telle qu’elle est publiée.')
            : DropField<String>(
                label: 'Marque',
                required: true,
                value: _st['brand'] as String?,
                options: [for (final n in _brandNames) (n, n)],
                onChanged: (v) => setState(() => v == null ? _st.remove('brand') : _st['brand'] = v),
              ),
      if (src == 'manual') ...[
        FieldLabel('Produits choisis (${ids.length}/48)', required: true),
        const SizedBox(height: 6),
        for (var i = 0; i < ids.length; i++)
          Row(children: [
            SizedBox(width: 28, child: Text('${i + 1}.', style: T.body)),
            Expanded(
                child: Text(names['${ids[i]}'] ?? 'Produit ${ids[i]}',
                    style: T.body, overflow: TextOverflow.ellipsis)),
            TextButton(
                onPressed: i == 0 ? null : () => setState(() => ids.insert(i - 1, ids.removeAt(i))),
                child: const Text('Monter')),
            TextButton(
                style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                onPressed: () => setState(() => ids.removeAt(i)),
                child: const Text('Retirer')),
          ]),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: ids.length >= 48
              ? null
              : () async {
                  final p = await pickProduct(context, widget.ctx.api,
                      title: 'Ajouter un produit à la section');
                  if (p == null || ids.contains(p.id)) return;
                  setState(() {
                    ids.add(p.id);
                    if (!names.containsKey(p.id)) _products = [..._products, p];
                  });
                },
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Ajouter un produit'),
        ),
        const SizedBox(height: 4),
        Text('Le produit doit être publié (catalogue) et visible pour apparaître.', style: T.small),
        const SizedBox(height: 14),
      ],
      _number(_st, 'max', 'Nombre maximum de produits', 1, 48, def: 8),
      _chips(_st, 'layout', 'Présentation', const [('grid', 'Grille'), ('slider', 'Bandeau défilant')],
          def: 'grid'),
      _switch(_st, 'show_more', 'Lien « Voir tout → »',
          help: 'Mène à la liste complète (promotions, catégorie, marque…).', def: false),
    ];
  }

  List<Widget> _brandsEditor() => [
        _chips(_st, 'source', 'Marques affichées',
            const [('auto', 'Automatique (les plus présentes)'), ('manual', 'Choix manuel')],
            def: 'auto'),
        if (_st['source'] == 'manual')
          _items(
            field: 'items',
            addLabel: 'Ajouter une marque',
            max: 30,
            create: () => <String, dynamic>{},
            title: (it, i) => '${it['name'] ?? 'Marque'}',
            fields: (it) => [
              _field(it, 'name', 'Nom de la marque', required: true, max: 60,
                  help: _brandNames.isEmpty ? null : 'Vos marques : ${_brandNames.take(12).join(', ')}…'),
              _asset(it, 'image', 'Logo (facultatif)', help: 'PNG transparent conseillé.'),
              _link(it, 'link', 'Lien (facultatif)', hint: '/marque/…',
                  help: 'Vide = la page de la marque sur le site.'),
            ],
          ),
        const SizedBox(height: 12),
        _number(_st, 'max', 'Nombre maximum de marques', 1, 30, def: 12),
      ];

  List<Widget> _textImage() => [
        _md(_st, 'body', 'Texte', max: 5000, minLines: 8),
        _asset(_st, 'image', 'Image'),
        _chips(_st, 'image_position', 'Position de l’image',
            const [('left', 'À gauche'), ('right', 'À droite')], def: 'right'),
        FieldPair(
          _field(_st, 'cta_text', 'Texte du bouton (facultatif)', max: 40),
          _link(_st, 'cta_link', 'Lien du bouton'),
        ),
      ];

  List<Widget> _features() => [
        InfoBanner(
            text: 'Astuce : écrivez {livraison} dans un titre ou un texte, le site le remplace par '
                'le résumé de vos réglages (ex. « Livraison dans 57 wilayas · offerte dès 5 000 DA »).'),
        _items(
          field: 'items',
          addLabel: 'Ajouter un point fort',
          max: 8,
          create: () => <String, dynamic>{'icon': 'check'},
          title: (it, i) => '${it['title'] ?? 'Point fort'}',
          fields: (it) => [
            DropField<String>(
              label: 'Icône',
              required: true,
              value: it['icon'] as String?,
              options: [
                for (final k in widget.info.featureIcons.isEmpty
                    ? _iconNames.keys
                    : widget.info.featureIcons)
                  (k, _iconNames[k] ?? k)
              ],
              onChanged: (v) => setState(() => v == null ? it.remove('icon') : it['icon'] = v),
            ),
            _field(it, 'title', 'Titre', required: true, max: 60),
            _field(it, 'text', 'Texte', max: 160),
          ],
        ),
      ];

  List<Widget> _testimonials() => [
        _items(
          field: 'items',
          addLabel: 'Ajouter un avis',
          max: 12,
          create: () => <String, dynamic>{'rating': 5},
          title: (it, i) => '${it['name'] ?? 'Avis'}',
          fields: (it) => [
            FieldPair(
              _field(it, 'name', 'Nom du client', required: true, max: 60),
              _field(it, 'role', 'Qui est-ce ? (facultatif)', hint: 'ex. Supérette, Oran', max: 60),
            ),
            _field(it, 'text', 'Avis', required: true, maxLines: 3, max: 400),
            ChoiceRow<int?>(
              label: 'Note',
              value: (it['rating'] as num?)?.toInt(),
              options: const [(null, 'Aucune'), (1, '1 ★'), (2, '2 ★'), (3, '3 ★'), (4, '4 ★'), (5, '5 ★')],
              onChanged: (v) => setState(() => v == null ? it.remove('rating') : it['rating'] = v),
            ),
          ],
        ),
      ];

  List<Widget> _faq() => [
        _items(
          field: 'items',
          addLabel: 'Ajouter une question',
          max: 30,
          create: () => <String, dynamic>{},
          title: (it, i) => '${it['q'] ?? 'Question'}',
          fields: (it) => [
            _field(it, 'q', 'Question', required: true, max: 200),
            _md(it, 'a', 'Réponse', minLines: 3, required: true),
          ],
        ),
      ];

  List<Widget> _contact() => [
        Text('Laissez vide pour reprendre les contacts de « Apparence ».', style: T.bodyMuted),
        const SizedBox(height: 12),
        _field(_st, 'address', 'Adresse', max: 300),
        FieldPair(
          _field(_st, 'phone', 'Téléphone', max: 40),
          _field(_st, 'email', 'E-mail', max: 120),
        ),
        _md(_st, 'hours', 'Horaires', max: 500, minLines: 3),
        _link(_st, 'maps_url', 'Lien Google Maps',
            hint: 'https://www.google.com/maps/embed?…',
            help: 'Pour une carte précise : Google Maps → Partager → Intégrer une carte, copiez '
                'l’adresse « src ». Sinon la carte est construite à partir de l’adresse.'),
        _switch(_st, 'show_map', 'Afficher la carte'),
      ];

  List<Widget> _cta() => [
        _field(_st, 'text', 'Message', required: true, maxLines: 2, max: 200,
            hint: 'ex. -20 % sur toute la cosmétique ce week-end'),
        _field(_st, 'subtitle', 'Sous-titre', maxLines: 2, max: 300),
        FieldPair(
          _field(_st, 'button_text', 'Texte du bouton', hint: 'J’en profite', max: 40),
          _link(_st, 'link', 'Lien du bouton', hint: '/l'),
        ),
        _asset(_st, 'image', 'Image de fond (facultatif)'),
        ColorField(
          label: 'Couleur de fond',
          value: '${_st['color'] ?? ''}',
          allowEmpty: true,
          emptyLabel: 'Couleur d’accent',
          onChanged: (v) => setState(() => v.isEmpty ? _st.remove('color') : _st['color'] = v),
        ),
      ];

  List<Widget> _countdown() {
    final end = DateTime.tryParse('${_st['ends_at'] ?? ''}')?.toLocal();
    return [
      FieldLabel('Fin de l’offre', required: true),
      const SizedBox(height: 6),
      Row(children: [
        OutlinedButton.icon(
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
                context: context,
                initialDate: end != null && end.isAfter(now) ? end : now,
                firstDate: DateTime(now.year, now.month, now.day),
                lastDate: DateTime(now.year + 3));
            if (d == null || !mounted) return;
            final cur = end ?? DateTime(d.year, d.month, d.day, 23, 59);
            setState(() => _st['ends_at'] =
                DateTime(d.year, d.month, d.day, cur.hour, cur.minute).toUtc().toIso8601String());
          },
          icon: const Icon(Icons.event_outlined, size: 17),
          label: Text(end == null ? 'Choisir la date' : fmtDay(end.toIso8601String())),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: end == null
              ? null
              : () async {
                  final t = await showTimePicker(
                      context: context, initialTime: TimeOfDay.fromDateTime(end));
                  if (t == null) return;
                  setState(() => _st['ends_at'] =
                      DateTime(end.year, end.month, end.day, t.hour, t.minute).toUtc().toIso8601String());
                },
          icon: const Icon(Icons.schedule_rounded, size: 17),
          label: Text(end == null
              ? 'Heure'
              : '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}'),
        ),
      ]),
      const SizedBox(height: 4),
      Text('La section disparaît toute seule après cette date.', style: T.small),
      const SizedBox(height: 14),
      _field(_st, 'subtitle', 'Texte', maxLines: 2, max: 300),
      FieldPair(
        _field(_st, 'button_text', 'Texte du bouton', hint: 'Voir les promotions', max: 40),
        _link(_st, 'link', 'Lien du bouton', hint: '/l?promo=1'),
      ),
      if (_codes.isNotEmpty)
        DropField<String>(
          label: 'Code promo affiché (facultatif)',
          value: (_st['promo_code'] as String?) ?? '',
          options: [
            ('', 'Aucun'),
            for (final c in _codes) (c.code, '${c.code} (${c.active ? 'actif' : 'inactif'})')
          ],
          onChanged: (v) => setState(() =>
              (v ?? '').isEmpty ? _st.remove('promo_code') : _st['promo_code'] = v),
          help: 'Le code est seulement affiché ; créez-le dans « Promotions ».',
        )
      else
        _field(_st, 'promo_code', 'Code promo affiché (facultatif)', max: 40,
            help: 'Le code est seulement affiché ; créez-le dans « Promotions ».'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final meta = sectionMeta(_type);
    final showTitle = !['hero', 'cta', 'countdown'].contains(_type);
    final fields = switch (_type) {
      'hero' => _hero(),
      'banner_carousel' => _carousel(),
      'categories' => _categoriesEditor(),
      'products' => _productsEditor(),
      'brands' => _brandsEditor(),
      'text_image' => _textImage(),
      'features' => _features(),
      'testimonials' => _testimonials(),
      'faq' => _faq(),
      'contact_map' => _contact(),
      'cta' => _cta(),
      'countdown' => _countdown(),
      _ => [Text('Ce type de section ne se modifie pas ici.', style: T.bodyMuted)],
    };
    return AppPage(
      crumbs: [
        Crumb('Page d’accueil', () => Navigator.of(context).maybePop()),
        Crumb(widget.isNew ? 'Nouvelle section' : sectionLabel(_s)),
      ],
      title: widget.isNew ? 'Nouvelle section : ${meta.$1}' : sectionLabel(_s),
      subtitle: Text(meta.$3, style: T.bodyMuted),
      actions: [
        PageAction(label: 'Annuler', onPressed: () => Navigator.of(context).maybePop()),
        PageAction(
            label: _busy ? 'Enregistrement…' : (widget.isNew ? 'Ajouter la section' : 'Enregistrer'),
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      maxWidth: 900,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_errors.isNotEmpty)
          InfoBanner(
            kind: ToastKind.error,
            title: 'À corriger avant d’enregistrer',
            text: _errors.map((e) => '• $e').join('\n'),
          ),
        PageSection(
          title: 'Section',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (showTitle)
              _field(_s, 'title', 'Titre affiché au-dessus', max: 120,
                  help: 'Vide = pas de titre.'),
            _switch(_s, 'enabled', 'Section affichée sur le site'),
          ]),
        ),
        PageSection(
          title: 'Contenu',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: fields),
        ),
      ]),
    );
  }
}
