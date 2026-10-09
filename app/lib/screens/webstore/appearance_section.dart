import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/file_dialog.dart';
import '../../widgets/app_page.dart';
import 'image_prep.dart';
import 'web_common.dart';

/// « Apparence » : template, colours, background, font, corners, header,
/// announcement bar, contact block, footer, logo and banner.
class AppearanceSection extends StatefulWidget {
  const AppearanceSection({super.key, required this.ctx});
  final WebCtx ctx;

  @override
  State<AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<AppearanceSection> {
  Map<String, dynamic> get _t => widget.ctx.store.theme;
  String _s(String k) => '${_t[k] ?? ''}';

  late final _name = TextEditingController(text: widget.ctx.store.name);
  late final _about = TextEditingController(text: _s('about'));
  late final _announce = TextEditingController(text: _s('announcement'));
  late final _announceLink = TextEditingController(text: _s('announcement_link'));
  late final _phone = TextEditingController(text: _s('phone'));
  late final _whatsapp = TextEditingController(text: _s('whatsapp'));
  late final _email = TextEditingController(text: _s('email'));
  late final _instagram = TextEditingController(text: _s('instagram'));
  late final _facebook = TextEditingController(text: _s('facebook'));
  late final _address = TextEditingController(text: _s('address'));
  late final _maps = TextEditingController(text: _s('maps_url'));
  late final _hours = TextEditingController(text: _s('hours'));
  late final _footer = TextEditingController(text: _s('footer_text'));

  late String _template = _t['template'] == 'vitrine' ? 'vitrine' : 'grid';
  late String _primary = isHexColor(_s('primary')) ? _s('primary').toUpperCase() : '#00A87C';
  late String _secondary = isHexColor(_s('secondary')) ? _s('secondary').toUpperCase() : '';
  late String _announceColor =
      isHexColor(_s('announcement_color')) ? _s('announcement_color').toUpperCase() : '';
  late String _bg = ['light', 'cream', 'dark'].contains(_t['bg']) ? _t['bg'] as String : 'light';
  late String _font = _fonts.any((f) => f.$1 == _t['font']) ? _t['font'] as String : 'system';
  late double _radius = ((_t['radius'] as num?)?.toDouble() ?? 14).clamp(0, 24);
  late String _header = _t['header_layout'] == 'centered' ? 'centered' : 'left';
  late bool _sticky = _t['header_sticky'] != false;
  late bool _waButton = _t['whatsapp_button'] != false;

  bool _busy = false;
  final _errors = <String, String>{};

  static const _fonts = [
    ('system', 'Police du système'),
    ('inter', 'Inter'),
    ('poppins', 'Poppins'),
    ('roboto', 'Roboto'),
    ('montserrat', 'Montserrat'),
    ('cairo', 'Cairo (lettres arabes)'),
    ('lora', 'Lora (avec empattements)'),
  ];

  @override
  void dispose() {
    for (final c in [
      _name, _about, _announce, _announceLink, _phone, _whatsapp, _email,
      _instagram, _facebook, _address, _maps, _hours, _footer,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _validate() {
    _errors.clear();
    if (_name.text.trim().isEmpty) _errors['name'] = 'Le nom est obligatoire.';
    if (!isHexColor(_primary)) _errors['primary'] = 'Couleur invalide.';
    if (_secondary.isNotEmpty && !isHexColor(_secondary)) _errors['secondary'] = 'Couleur invalide.';
    final l1 = checkLink(_announceLink.text);
    if (l1 != null) _errors['announcement_link'] = l1;
    final l2 = checkLink(_maps.text);
    if (l2 != null) _errors['maps_url'] = l2;
    final em = checkEmail(_email.text);
    if (em != null) _errors['email'] = em;
    final wa = _whatsapp.text.trim();
    if (wa.isNotEmpty && !RegExp(r'^\d{8,15}$').hasMatch(wa)) {
      _errors['whatsapp'] = 'Chiffres seulement, avec l’indicatif (ex. 213550123456).';
    }
    if (_hours.text.length > 500) _errors['hours'] = '500 caractères maximum.';
    if (_footer.text.length > 1000) _errors['footer_text'] = '1000 caractères maximum.';
    setState(() {});
    return _errors.isEmpty;
  }

  Future<bool> _save() async {
    if (!_validate()) {
      showToast(context, 'Corrigez les champs en rouge.', kind: ToastKind.warning);
      return false;
    }
    setState(() => _busy = true);
    try {
      final s = await widget.ctx.client.webConfig({
        'name': _name.text.trim(),
        'theme': {
          'template': _template,
          'primary': _primary,
          'secondary': _secondary,
          'bg': _bg,
          'font': _font,
          'radius': _radius.round(),
          'header_layout': _header,
          'header_sticky': _sticky,
          'about': _about.text.trim(),
          'announcement': _announce.text.trim(),
          'announcement_link': _announceLink.text.trim(),
          'announcement_color': _announceColor,
          'phone': _phone.text.trim(),
          'whatsapp': _whatsapp.text.trim(),
          'whatsapp_button': _waButton,
          'email': _email.text.trim(),
          'instagram': _instagram.text.trim(),
          'facebook': _facebook.text.trim(),
          'address': _address.text.trim(),
          'maps_url': _maps.text.trim(),
          'hours': _hours.text.trim(),
          'footer_text': _footer.text.trim(),
        },
      });
      widget.ctx.onStore(s);
      if (mounted) showToast(context, 'Apparence enregistrée — le site est à jour.');
      if (mounted) setState(() => _busy = false);
      return true;
    } catch (e) {
      if (mounted) {
        toastError(context, 'Enregistrement impossible', e);
        setState(() => _busy = false);
      }
      return false;
    }
  }

  Future<void> _preview() async {
    if (await _save()) openWebUrl(widget.ctx.publicUrl);
  }

  Future<void> _upload(String kind) async {
    final path = pickImageFile();
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      final im = await prepareImage(
          bytes, kind == 'logo' ? ImagePreset.logo : ImagePreset.banner);
      if (im == null) {
        if (mounted) showToast(context, 'Image illisible ou trop lourde.', kind: ToastKind.error);
        return;
      }
      await widget.ctx.client.webUploadImage(kind, im.bytes, im.contentType);
      await widget.ctx.reload();
      if (mounted) {
        showToast(context, kind == 'logo' ? 'Logo mis à jour.' : 'Bannière mise à jour.');
      }
    } catch (e) {
      if (mounted) toastError(context, 'Envoi impossible', e);
    }
  }

  Widget _imageBox(String label, String path, bool has, String kind, String help) {
    final url = '${widget.ctx.store.url}/$path';
    return SizedBox(
      width: 300,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FieldLabel(label),
        const SizedBox(height: 6),
        Container(
          width: 300,
          height: kind == 'logo' ? 90 : 120,
          decoration: BoxDecoration(
            color: T.bg,
            borderRadius: BorderRadius.circular(T.rInner),
            border: Border.all(color: T.border3),
          ),
          clipBehavior: Clip.antiAlias,
          child: has
              ? Image.network('$url?v=${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
                  fit: kind == 'logo' ? BoxFit.contain : BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, color: T.ghost))
              : Center(child: Text('Aucune image', style: T.small)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _upload(kind),
          icon: const Icon(Icons.upload_rounded, size: 17),
          label: Text(has ? 'Changer' : 'Ajouter'),
        ),
        const SizedBox(height: 4),
        Text(help, style: T.small),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.ctx.store;
    return WebPane(
      title: 'Apparence',
      intro: 'L’allure de votre site : modèle, couleurs, police, bandeau, '
          'contacts. Enregistrez puis cliquez « Aperçu en direct ».',
      actions: [
        PageAction(
            label: 'Aperçu en direct',
            icon: Icons.open_in_new_rounded,
            onPressed: _busy ? null : _preview),
        PageAction(
            label: _busy ? 'Enregistrement…' : 'Enregistrer',
            primary: true,
            onPressed: _busy ? null : _save),
      ],
      children: [
        WebBlock(title: 'Nom et images', children: [
          LabeledField(
              label: 'Nom de la boutique',
              controller: _name,
              required: true,
              error: _errors['name']),
          LabeledField(
              label: 'Présentation',
              controller: _about,
              maxLines: 3,
              help: 'Une ou deux phrases sous le nom, sur la grande bannière. '
                  'Sert aussi de description pour Google.'),
          Wrap(spacing: 24, runSpacing: 16, children: [
            _imageBox('Logo', 'logo', s.hasLogo, 'logo',
                'Aussi utilisé comme icône d’onglet. PNG transparent conseillé.'),
            _imageBox('Grande bannière', 'cover', s.hasCover, 'cover',
                'Photo large (au moins 1200 px), affichée en haut de l’accueil.'),
          ]),
        ]),
        WebBlock(title: 'Modèle et couleurs', children: [
          ChoiceRow<String>(
            label: 'Modèle de page',
            value: _template,
            options: const [
              ('grid', 'Grille (catalogue dense)'),
              ('vitrine', 'Vitrine (grandes images)'),
            ],
            onChanged: (v) => setState(() => _template = v),
            help: _template == 'grid'
                ? 'Beaucoup de produits par ligne, pratique pour un grand catalogue.'
                : 'Moins de produits, plus grands et centrés, bannière plus haute.',
          ),
          ColorField(
            label: 'Couleur principale',
            value: _primary,
            onChanged: (v) => setState(() => _primary = v),
            help: 'Menu, liens, prix.',
          ),
          ColorField(
            label: 'Couleur d’accent',
            value: _secondary,
            allowEmpty: true,
            emptyLabel: 'Comme la principale',
            onChanged: (v) => setState(() => _secondary = v),
            help: 'Boutons « Commander », badges promo, compte à rebours.',
          ),
          ChoiceRow<String>(
            label: 'Fond des pages',
            value: _bg,
            options: const [('light', 'Clair'), ('cream', 'Crème'), ('dark', 'Sombre')],
            onChanged: (v) => setState(() => _bg = v),
          ),
          DropField<String>(
            label: 'Police d’écriture',
            value: _font,
            options: _fonts,
            onChanged: (v) => setState(() => _font = v ?? 'system'),
          ),
          FieldLabel('Arrondi des coins : ${_radius.round()} px'),
          SizedBox(
            width: 420,
            child: Slider(
              value: _radius,
              min: 0,
              max: 24,
              divisions: 24,
              label: '${_radius.round()} px',
              onChanged: (v) => setState(() => _radius = v),
            ),
          ),
          Row(children: [
            Container(
              width: 80,
              height: 50,
              decoration: BoxDecoration(
                color: T.surface,
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(color: hexColor(_primary), width: 2),
              ),
            ),
            const SizedBox(width: 10),
            Text('0 = coins droits · 24 = très arrondis', style: T.small),
          ]),
        ]),
        WebBlock(title: 'En-tête', children: [
          ChoiceRow<String>(
            label: 'Position du logo',
            value: _header,
            options: const [('left', 'À gauche'), ('centered', 'Centré')],
            onChanged: (v) => setState(() => _header = v),
          ),
          SwitchRow(
            title: 'En-tête toujours visible',
            explanation: 'Le menu reste en haut de l’écran quand le visiteur fait défiler la page.',
            value: _sticky,
            onChanged: (v) => setState(() => _sticky = v),
          ),
        ]),
        WebBlock(
          title: 'Bandeau d’annonce',
          help: 'Une phrase courte en haut de toutes les pages. Laissez vide pour ne pas en mettre.',
          children: [
            LabeledField(
                label: 'Texte',
                controller: _announce,
                hint: 'ex. Livraison 58 wilayas — paiement à la livraison'),
            LabeledField(
                label: 'Lien (facultatif)',
                controller: _announceLink,
                hint: 'ex. /l?promo=1 ou https://…',
                error: _errors['announcement_link'],
                help: 'Le bandeau devient cliquable.'),
            ColorField(
              label: 'Couleur du bandeau',
              value: _announceColor,
              allowEmpty: true,
              emptyLabel: 'Couleur principale',
              onChanged: (v) => setState(() => _announceColor = v),
            ),
          ],
        ),
        WebBlock(title: 'Contact', children: [
          FieldPair(
            LabeledField(label: 'Téléphone', controller: _phone),
            LabeledField(
                label: 'WhatsApp',
                controller: _whatsapp,
                hint: 'ex. 213550123456',
                error: _errors['whatsapp'],
                help: 'Avec l’indicatif 213, sans le 0.'),
          ),
          SwitchRow(
            title: 'Bouton WhatsApp flottant',
            explanation: 'Un bouton vert en bas de chaque page pour vous écrire (si le numéro WhatsApp est rempli).',
            value: _waButton,
            onChanged: (v) => setState(() => _waButton = v),
          ),
          const SizedBox(height: 8),
          FieldPair(
            LabeledField(label: 'E-mail', controller: _email, error: _errors['email']),
            LabeledField(label: 'Instagram', controller: _instagram, hint: 'ex. superette.demo'),
          ),
          LabeledField(
              label: 'Facebook', controller: _facebook, help: 'Lien de la page ou son nom.'),
          LabeledField(label: 'Adresse du magasin', controller: _address),
          LabeledField(
              label: 'Lien Google Maps',
              controller: _maps,
              error: _errors['maps_url'],
              hint: 'https://maps.app.goo.gl/… ou https://www.google.com/maps/embed?…',
              help: 'Dans Google Maps : Partager → Copier le lien. Pour une carte '
                  'intégrée, « Intégrer une carte » et copiez l’adresse (src).'),
          MarkdownField(
            label: 'Horaires d’ouverture',
            controller: _hours,
            client: widget.ctx.client,
            maxLength: 500,
            minLines: 3,
            help: 'ex. Samedi–jeudi : 8h–20h. Affichés en pied de page et dans la section contact.',
          ),
          if (_errors['hours'] != null) FieldError(_errors['hours']),
        ]),
        WebBlock(title: 'Pied de page', children: [
          MarkdownField(
            label: 'Texte du pied de page',
            controller: _footer,
            client: widget.ctx.client,
            maxLength: 1000,
            minLines: 3,
            help: 'Mentions légales, n° d’agrément, RC… Mise en forme simple acceptée.',
          ),
          if (_errors['footer_text'] != null) FieldError(_errors['footer_text']),
        ]),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              primary: true,
              onPressed: _busy ? null : _save),
        ),
      ],
    );
  }
}
