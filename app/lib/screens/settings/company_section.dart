import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/features.dart';
import '../../util/feedback.dart';
import '../../util/file_dialog.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Company identity keys of the server settings. They feed the legal header
/// and footer of invoices (décret 05-468) and tickets.
const companyKeys = [
  'company_name',
  'company_address',
  'company_phone',
  'company_email',
  'company_website',
  'company_nif',
  'company_nis',
  'company_rc',
  'company_ai',
  'company_bank',
  'company_rib',
  'company_capital',
  'company_footer', // texte de pied de page des documents
  'company_legal', // mentions légales
];

/// Paramètres → Entreprise: name, logo, tax identifiers, bank, footer.
class CompanySection extends StatefulWidget {
  const CompanySection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<CompanySection> createState() => _CompanySectionState();
}

class _CompanySectionState extends State<CompanySection> {
  late final Map<String, TextEditingController> _c = {
    for (final k in companyKeys) k: TextEditingController(),
  };
  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  String? _nameError;
  int _logoRev = 0;
  bool _logoBusy = false;

  ApiClient get _api => widget.ctx.api;
  bool get _admin => widget.ctx.isAdmin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final s = await _api.settings();
      if (!mounted) return;
      setState(() {
        for (final k in companyKeys) {
          _c[k]!.text = s[k] ?? '';
        }
        _logoRev = int.tryParse(s['logo_rev'] ?? '') ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Impossible de lire les réglages : $e';
        });
      }
    }
  }

  Future<void> _save() async {
    final name = _c['company_name']!.text.trim();
    setState(() => _nameError = name.isEmpty ? 'Indiquez le nom de votre commerce.' : null);
    if (_nameError != null) return;
    setState(() => _saving = true);
    try {
      await _api.saveSettings({for (final k in companyKeys) k: _c[k]!.text.trim()});
      await Features.instance.load(_api);
      if (mounted) showToast(context, 'Informations de l’entreprise enregistrées.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickLogo() async {
    final path = pickFile('Images PNG ou JPEG', '*.png;*.jpg;*.jpeg');
    if (path == null) return;
    final lower = path.toLowerCase();
    if (!(lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg'))) {
      if (mounted) showToast(context, 'Choisissez une image PNG ou JPEG.', kind: ToastKind.warning);
      return;
    }
    final file = File(path);
    final size = await file.length();
    if (size > 1024 * 1024) {
      if (mounted) {
        showToast(context,
            'Cette image fait ${(size / 1024 / 1024).toStringAsFixed(1)} Mo. Le logo doit faire 1 Mo au plus.',
            kind: ToastKind.warning);
      }
      return;
    }
    setState(() => _logoBusy = true);
    try {
      final bytes = await file.readAsBytes();
      final rev = await _api.uploadCompanyLogo(bytes, imageContentType(path));
      if (mounted) {
        setState(() => _logoRev = rev);
        showToast(context, 'Logo enregistré.');
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } catch (e) {
      if (mounted) showToast(context, 'Lecture du fichier impossible : $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    final ok = await confirmAction(context,
        title: 'Retirer le logo ?',
        message: 'Le logo ne sera plus imprimé sur vos documents. Vous pourrez en remettre un à tout moment.',
        confirmLabel: 'Retirer le logo',
        danger: true);
    if (!ok) return;
    setState(() => _logoBusy = true);
    try {
      await _api.deleteCompanyLogo();
      if (mounted) {
        setState(() => _logoRev = 0);
        showToast(context, 'Logo retiré.');
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Widget _f(String key, String label,
          {bool required = false, String? help, String? hint, int maxLines = 1, bool mono = false, String? error}) =>
      LabeledField(
        label: label,
        controller: _c[key]!,
        required: required,
        help: help,
        hint: hint,
        maxLines: maxLines,
        mono: mono,
        error: error,
        enabled: _admin,
      );

  Widget _logo() {
    final preview = Container(
      width: 180,
      height: 110,
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      alignment: Alignment.center,
      child: _logoRev == 0
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.image_outlined, size: 30, color: T.faint),
              const SizedBox(height: 6),
              Text('Pas de logo', style: T.bodyMuted),
            ])
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Image.network(
                _api.companyLogoUrl(_logoRev),
                headers: _api.authHeaders,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Text('Aperçu indisponible', style: T.bodyMuted),
              ),
            ),
    );
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      preview,
      const SizedBox(width: 20),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Imprimé en haut de vos factures, devis et bons.', style: T.body),
          const SizedBox(height: 4),
          Text('Image PNG ou JPEG, 1 Mo au plus. Un fond blanc ou transparent rend mieux.',
              style: T.bodyMuted),
          const SizedBox(height: 12),
          if (_admin)
            Wrap(runSpacing: 8, children: [
              PageAction(
                label: _logoBusy
                    ? 'Envoi…'
                    : _logoRev == 0
                        ? 'Choisir un logo…'
                        : 'Changer le logo…',
                icon: Icons.upload_file_outlined,
                onPressed: _logoBusy ? null : _pickLogo,
              ),
              if (_logoRev != 0)
                PageAction(
                  label: 'Retirer le logo',
                  icon: Icons.delete_outline_rounded,
                  danger: true,
                  onPressed: _logoBusy ? null : _removeLogo,
                ),
            ]),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPage(
          title: 'Entreprise', children: [Center(child: CircularProgressIndicator(color: T.mint))]);
    }
    if (_loadError != null) {
      return SettingsPage(title: 'Entreprise', children: [
        InfoBanner(
          kind: ToastKind.error,
          icon: Icons.cloud_off_rounded,
          text: _loadError!,
          actions: [PageAction(label: 'Réessayer', icon: Icons.refresh_rounded, onPressed: _load)],
        ),
      ]);
    }
    return SettingsPage(
      title: 'Entreprise',
      intro: 'Ces informations sont imprimées sur vos factures, devis, bons et tickets.',
      actions: [
        if (_admin)
          PageAction(
            label: _saving ? 'Enregistrement…' : 'Enregistrer',
            icon: Icons.check_rounded,
            primary: true,
            onPressed: _saving ? null : _save,
          ),
      ],
      children: [
        if (!_admin) const AdminOnlyNotice(),
        PageSection(
          title: 'Votre commerce',
          child: Column(children: [
            _f('company_name', 'Raison sociale', required: true, error: _nameError,
                help: 'Le nom officiel, tel qu’il figure au registre de commerce.'),
            _f('company_address', 'Adresse', maxLines: 2),
            FieldPair(
              _f('company_phone', 'Téléphone', hint: '0550 12 34 56'),
              _f('company_email', 'Email', hint: 'contact@exemple.dz'),
            ),
            _f('company_website', 'Site web', hint: 'www.exemple.dz'),
          ]),
        ),
        PageSection(title: 'Logo', child: _logo()),
        PageSection(
          title: 'Identifiants fiscaux',
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text('Obligatoires sur une facture en Algérie (décret 05-468).', style: T.bodyMuted),
            ),
            FieldPair(
              _f('company_nif', 'NIF', mono: true, help: 'Numéro d’identification fiscale'),
              _f('company_nis', 'NIS', mono: true, help: 'Numéro d’identification statistique'),
            ),
            FieldPair(
              _f('company_rc', 'Registre de commerce (RC)', mono: true),
              _f('company_ai', 'Article d’imposition (AI)', mono: true),
            ),
            _f('company_capital', 'Capital social',
                hint: 'ex. 1 000 000 DA', help: 'Facultatif — pour les sociétés (SARL, EURL…).'),
          ]),
        ),
        PageSection(
          title: 'Banque',
          child: FieldPair(
            _f('company_bank', 'Banque', hint: 'ex. BNA agence Hydra'),
            _f('company_rib', 'RIB', mono: true, help: 'Imprimé sur les factures pour les virements.'),
          ),
        ),
        PageSection(
          title: 'Bas des documents',
          child: Column(children: [
            _f('company_footer', 'Texte de pied de page des documents', maxLines: 3,
                hint: 'ex. Merci de votre confiance !',
                help: 'Imprimé en bas de chaque facture, devis et bon.'),
            _f('company_legal', 'Mentions légales', maxLines: 4,
                hint: 'ex. Marchandise vendue ni reprise ni échangée après 7 jours.',
                help: 'Conditions de vente, garantie, pénalités de retard…'),
          ]),
        ),
        if (_admin)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: PageAction(
              label: _saving ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _saving ? null : _save,
            ),
          ),
      ],
    );
  }
}
