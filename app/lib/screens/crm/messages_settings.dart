import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/doc_list.dart' show DocChip;
import '../../widgets/list_toolbar.dart' show FilterPill;
import '../../widgets/ui.dart';
import '../settings/settings_shell.dart';
import 'crm_common.dart';

/// Paramètres › Messages : message templates (WhatsApp / SMS / e-mail),
/// e-mail sending (SMTP), reminder settings.
class MessagesSection extends StatefulWidget {
  const MessagesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<MessagesSection> createState() => _MessagesSectionState();
}

class _MessagesSectionState extends State<MessagesSection> {
  ApiClient get api => widget.ctx.api;
  List<MessageTemplate> _templates = const [];
  bool _loading = true;
  String? _error;
  String? _channel;
  String? _lang;

  // SMTP + reminders (shop settings).
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _from = TextEditingController();
  final _inactiveDays = TextEditingController();
  final _tracking = TextEditingController();
  String _security = 'starttls';
  bool _passSet = false;
  bool _savingSmtp = false;
  bool _savingCrm = false;
  Map<String, String> _settings = const {};

  bool get _canEditTemplates => crmEdit(api);
  bool get _canSettings => widget.ctx.isAdmin || crmCan(api, 'settings');

  @override
  void initState() {
    super.initState();
    _loadTemplates();
    _loadSettings();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _pass, _from, _inactiveDays, _tracking]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final t = await api.crmTemplates();
      if (mounted) setState(() => _templates = t);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadSettings() async {
    try {
      final s = await api.settings();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _host.text = s['smtp_host'] ?? '';
        _port.text = s['smtp_port'] ?? '';
        _user.text = s['smtp_user'] ?? '';
        _from.text = s['smtp_from'] ?? '';
        _security = (s['smtp_security'] ?? '').isEmpty ? 'starttls' : s['smtp_security']!;
        _passSet = s['smtp_pass_set'] == '1';
        _inactiveDays.text = s['crm_inactive_days'] ?? '';
        _tracking.text = s['order_tracking_url'] ?? '';
      });
    } catch (_) {}
  }

  Future<void> _saveSmtp() async {
    final port = _port.text.trim();
    if (port.isNotEmpty && int.tryParse(port) == null) {
      showToast(context, 'Port invalide (ex. 587).', kind: ToastKind.error);
      return;
    }
    setState(() => _savingSmtp = true);
    try {
      await api.saveSettings({
        'smtp_host': _host.text.trim(),
        'smtp_port': port,
        'smtp_user': _user.text.trim(),
        'smtp_from': _from.text.trim(),
        'smtp_security': _security,
        // Write-only: sent only when typed, so the saved one is kept.
        if (_pass.text.isNotEmpty) 'smtp_pass': _pass.text,
      });
      _pass.clear();
      if (mounted) showToast(context, 'Réglages d’envoi des e-mails enregistrés.');
      await _loadSettings();
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _savingSmtp = false);
    }
  }

  Future<void> _saveCrm() async {
    final d = _inactiveDays.text.trim();
    if (d.isNotEmpty && (int.tryParse(d) == null || int.parse(d) < 1)) {
      showToast(context, 'Nombre de jours invalide.', kind: ToastKind.error);
      return;
    }
    setState(() => _savingCrm = true);
    try {
      await api.saveSettings({'crm_inactive_days': d, 'order_tracking_url': _tracking.text.trim()});
      if (mounted) showToast(context, 'Réglages enregistrés.');
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _savingCrm = false);
    }
  }

  Future<void> _openTemplate([MessageTemplate? t]) async {
    final changed = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => TemplateFormPage(api: api, existing: t)));
    if (changed == true) _loadTemplates();
  }

  Future<void> _testEmail() async {
    final to = await showDialog<String>(context: context, builder: (_) => const _AskEmail());
    if (to == null || to.isEmpty || !mounted) return;
    try {
      await api.crmSendEmail(
          to: to,
          subject: 'Test d’envoi — ${_settings['company_name'] ?? 'Elixir'}',
          body: 'Ceci est un e-mail de test envoyé depuis le logiciel. Si vous le recevez, l’envoi fonctionne.');
      if (mounted) showToast(context, 'E-mail de test envoyé à $to.');
    } on CrmApiException catch (e) {
      if (mounted) {
        showToast(context, e.smtpNotConfigured ? 'Enregistrez d’abord le serveur d’envoi.' : e.message,
            kind: ToastKind.error);
      }
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final t in _templates)
        if ((_channel == null || t.channel == _channel) && (_lang == null || t.lang == _lang)) t
    ]..sort((a, b) => '${a.code}${a.channel}${a.lang}'.compareTo('${b.code}${b.channel}${b.lang}'));
    return SettingsPage(
      title: 'Messages',
      intro: 'Textes envoyés aux clients par WhatsApp, SMS ou e-mail (commande prête, relance de paiement…), '
          'et le serveur d’envoi des e-mails.',
      actions: [
        if (_canEditTemplates)
          PageAction(label: 'Nouveau modèle', icon: Icons.add_rounded, primary: true, onPressed: () => _openTemplate()),
      ],
      children: [
        PageSection(
          title: 'Modèles de messages',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(runSpacing: 6, children: [
              FilterPill(label: 'Tous', active: _channel == null, onTap: () => setState(() => _channel = null)),
              for (final e in messageChannelLabels.entries)
                FilterPill(
                    label: e.value,
                    active: _channel == e.key,
                    count: _templates.where((t) => t.channel == e.key).length,
                    onTap: () => setState(() => _channel = _channel == e.key ? null : e.key)),
              const SizedBox(width: 12),
              for (final e in messageLangLabels.entries)
                FilterPill(
                    label: e.value,
                    icon: Icons.translate_rounded,
                    active: _lang == e.key,
                    onTap: () => setState(() => _lang = _lang == e.key ? null : e.key)),
            ]),
            const SizedBox(height: 12),
            if (_loading)
              const SkeletonBar(width: 240, height: 14)
            else if (_error != null)
              FieldError(_error)
            else if (shown.isEmpty)
              Text('Aucun modèle.', style: T.bodyMuted)
            else
              for (final t in shown)
                InkWell(
                  onTap: () => _openTemplate(t),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: T.border))),
                    child: Row(children: [
                      Icon(
                          switch (t.channel) {
                            'email' => Icons.email_outlined,
                            'sms' => Icons.sms_outlined,
                            _ => Icons.chat_outlined,
                          },
                          size: 18,
                          color: T.muted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
                          Text(t.body.replaceAll('\n', ' '),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: T.small),
                        ]),
                      ),
                      const SizedBox(width: 10),
                      Text(t.code, style: T.monoSmall),
                      const SizedBox(width: 10),
                      DocChip(label: messageChannelLabels[t.channel] ?? t.channel, bg: T.cream, fg: T.muted),
                      const SizedBox(width: 6),
                      DocChip(label: t.lang.toUpperCase(), bg: T.cream, fg: T.muted),
                      if (!t.active) ...[
                        const SizedBox(width: 6),
                        const DocChip(label: 'Désactivé', bg: T.warnTint, fg: T.warnDark),
                      ],
                      if (t.isSystem) ...[
                        const SizedBox(width: 6),
                        const DocChip(label: 'Fourni', bg: T.mintTint, fg: T.mintDark),
                      ],
                      const SizedBox(width: 6),
                      TextButton(
                          onPressed: () => _openTemplate(t),
                          child: Text(_canEditTemplates ? 'Modifier' : 'Voir')),
                    ]),
                  ),
                ),
          ]),
        ),
        PageSection(
          title: 'Envoi des e-mails (SMTP)',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                'Les coordonnées du serveur d’envoi fournies par votre messagerie (Gmail, Outlook, hébergeur…). '
                'Pour Gmail : smtp.gmail.com, port 587, et un « mot de passe d’application ».',
                style: T.small),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: TextBlock(label: 'Serveur', controller: _host, hint: 'smtp.exemple.dz')),
              const SizedBox(width: 14),
              Expanded(
                  child: TextBlock(label: 'Port', controller: _port, hint: '587', keyboard: TextInputType.number)),
            ]),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: TextBlock(label: 'Identifiant', controller: _user, hint: 'contact@exemple.dz')),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Mot de passe', style: T.label),
                    const SizedBox(height: 5),
                    Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: T.surface,
                        borderRadius: BorderRadius.circular(T.rInner),
                        border: Border.all(color: T.border3),
                      ),
                      child: TextField(
                        controller: _pass,
                        obscureText: true,
                        enabled: _canSettings,
                        style: T.body,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: _passSet ? '•••••••• (déjà enregistré)' : '',
                          hintStyle: T.bodyMuted.copyWith(color: T.ghost),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_passSet ? 'Laissez vide pour garder le mot de passe enregistré.' : 'Jamais affiché après l’enregistrement.',
                        style: T.small),
                  ]),
                ),
              ),
            ]),
            TextBlock(
                label: 'Adresse d’expéditeur',
                controller: _from,
                hint: 'Ma Société <contact@exemple.dz>',
                helper: 'Vide = l’identifiant.'),
            Text('Sécurité', style: T.label),
            const SizedBox(height: 6),
            ChoiceRow<String>(
              options: const [('starttls', 'STARTTLS (port 587)'), ('ssl', 'SSL (port 465)'), ('none', 'Aucune')],
              value: _security,
              onSelect: (v) => setState(() => _security = v),
            ),
            const SizedBox(height: 16),
            Row(children: [
              if (_canSettings)
                SizedBox(
                  width: 220,
                  child: PrimaryButton(
                      label: _savingSmtp ? 'Enregistrement…' : 'Enregistrer', onPressed: _savingSmtp ? null : _saveSmtp),
                ),
              const SizedBox(width: 10),
              if (crmEdit(api) || crmCan(api, 'orders.manage'))
                OutlinedButton.icon(
                  onPressed: _testEmail,
                  icon: const Icon(Icons.send_outlined, size: 18),
                  label: const Text('Envoyer un e-mail de test'),
                ),
            ]),
          ]),
        ),
        if (_canSettings)
          PageSection(
            title: 'Relances et suivi',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 320,
                child: TextBlock(
                  label: 'Client inactif après (jours sans achat)',
                  controller: _inactiveDays,
                  hint: '30',
                  keyboard: TextInputType.number,
                  helper: 'Utilisé par « Générer les relances automatiques ».',
                ),
              ),
              TextBlock(
                label: 'Lien de suivi de commande',
                controller: _tracking,
                hint: 'https://boutique.exemple.dz/suivi/{ref}',
                helper: 'Remplace {{lien_suivi}} dans les messages ; {ref} devient le n° de la commande.',
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SizedBox(
                  width: 220,
                  child: PrimaryButton(
                      label: _savingCrm ? 'Enregistrement…' : 'Enregistrer', onPressed: _savingCrm ? null : _saveCrm),
                ),
              ),
            ]),
          ),
      ],
    );
  }
}

class _AskEmail extends StatefulWidget {
  const _AskEmail();

  @override
  State<_AskEmail> createState() => _AskEmailState();
}

class _AskEmailState extends State<_AskEmail> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.surface,
      title: const Text('Envoyer un e-mail de test', style: T.h2),
      content: SizedBox(
          width: 380,
          child: TextBlock(label: 'À quelle adresse ?', controller: _c, autofocus: true, keyboard: TextInputType.emailAddress)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: T.mint, foregroundColor: T.ink),
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: const Text('Envoyer'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Template edit page — placeholder chips + live preview (POST /messages/render)
// ---------------------------------------------------------------------------

class TemplateFormPage extends StatefulWidget {
  const TemplateFormPage({super.key, required this.api, this.existing});
  final ApiClient api;
  final MessageTemplate? existing;

  @override
  State<TemplateFormPage> createState() => _TemplateFormPageState();
}

class _TemplateFormPageState extends State<TemplateFormPage> {
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _subject = TextEditingController(text: widget.existing?.subject ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  late String _channel = widget.existing?.channel ?? 'whatsapp';
  late String _lang = widget.existing?.lang ?? 'fr';
  late bool _active = widget.existing?.active ?? true;
  List<MessagePlaceholder> _placeholders = const [];
  RenderedMessage? _preview;
  String? _previewError;
  String? _previewPartnerId;
  String? _previewPartnerName;
  Timer? _debounce;
  bool _busy = false;
  Map<String, String> _err = const {};

  bool get _readOnly => !crmEdit(widget.api);

  @override
  void initState() {
    super.initState();
    widget.api.crmPlaceholders().then((p) {
      if (mounted) setState(() => _placeholders = p);
    }).catchError((_) {});
    _body.addListener(_schedulePreview);
    _subject.addListener(_schedulePreview);
    _renderPreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_code, _name, _subject, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _renderPreview);
  }

  Future<void> _renderPreview() async {
    if (_body.text.trim().isEmpty) {
      setState(() => _preview = null);
      return;
    }
    try {
      final r = await widget.api.crmRender(
        body: _body.text,
        subject: _channel == 'email' ? _subject.text : null,
        channel: _channel,
        partnerId: _previewPartnerId,
      );
      if (mounted) {
        setState(() {
          _preview = r;
          _previewError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _previewError = errText(e));
    }
  }

  void _insert(String key) {
    final token = '{{$key}}';
    final sel = _body.selection;
    final text = _body.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _body.value = TextEditingValue(
      text: text.replaceRange(start, end, token),
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  Future<void> _pickPreviewClient() async {
    final p = await pickCustomer(context, widget.api);
    if (p == null) return;
    setState(() {
      _previewPartnerId = p.id;
      _previewPartnerName = p.name;
    });
    _renderPreview();
  }

  Future<void> _save() async {
    final e = <String, String>{};
    final code = _code.text.trim();
    if (!RegExp(r'^[a-z0-9_]{2,40}$').hasMatch(code)) {
      e['code'] = '2 à 40 caractères : lettres minuscules, chiffres, « _ ».';
    }
    if (_body.text.trim().isEmpty) e['body'] = 'Écrivez le texte du message.';
    setState(() => _err = e);
    if (e.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.api.crmSaveTemplate({
        'code': code,
        'channel': _channel,
        'lang': _lang,
        'name': _name.text.trim(),
        'subject': _subject.text.trim(),
        'body': _body.text,
        'active': _active,
      }, id: widget.existing?.id);
      if (!mounted) return;
      showToast(context, 'Modèle enregistré.');
      Navigator.of(context).pop(true);
    } catch (ex) {
      setState(() => _err = {'form': errText(ex)});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final t = widget.existing!;
    final ok = await confirmAction(context,
        title: 'Supprimer le modèle « ${t.title} » ?', confirmLabel: 'Supprimer', danger: true);
    if (!ok) return;
    try {
      await widget.api.crmDeleteTemplate(t.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, errText(e), kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ex = widget.existing;
    final isNew = ex == null;
    final system = ex?.isSystem == true;
    return AppPage(
      crumbs: [Crumb('Messages', () => Navigator.of(context).pop()), Crumb(isNew ? 'Nouveau modèle' : ex.title)],
      title: isNew ? 'Nouveau modèle de message' : ex.title,
      subtitle: system
          ? Text('Modèle fourni : vous pouvez changer le texte, pas le supprimer (désactivez-le si besoin).',
              style: T.bodyMuted)
          : null,
      maxWidth: 1100,
      actions: [
        if (!isNew && !system && !_readOnly) PageAction(label: 'Supprimer', danger: true, onPressed: _delete),
        PageAction(label: _readOnly ? 'Fermer' : 'Annuler', onPressed: () => Navigator.of(context).pop()),
        if (!_readOnly)
          PageAction(
              label: _busy ? 'Enregistrement…' : 'Enregistrer',
              icon: Icons.check_rounded,
              primary: true,
              onPressed: _busy ? null : _save),
      ],
      body: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageSection(
              title: 'Modèle',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextBlock(label: 'Nom', controller: _name, hint: 'Ex. Commande prête'),
                TextBlock(
                    label: 'Code',
                    required: true,
                    controller: _code,
                    error: _err['code'],
                    hint: 'order_ready',
                    helper: 'Sert aux écrans qui envoient ce message automatiquement (ex. order_ready).'),
                Text('Canal', style: T.label),
                const SizedBox(height: 6),
                ChoiceRow<String>(
                  options: [for (final e in messageChannelLabels.entries) (e.key, e.value)],
                  value: _channel,
                  onSelect: (v) {
                    setState(() => _channel = v);
                    _renderPreview();
                  },
                ),
                const SizedBox(height: 14),
                Text('Langue', style: T.label),
                const SizedBox(height: 6),
                ChoiceRow<String>(
                  options: [for (final e in messageLangLabels.entries) (e.key, e.value)],
                  value: _lang,
                  onSelect: (v) => setState(() => _lang = v),
                ),
                const SizedBox(height: 8),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                  value: _active,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: T.mintDeep,
                  title: Text('Actif', style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  subtitle: Text('Un modèle désactivé n’est plus proposé.', style: T.small),
                  onChanged: _readOnly ? null : (v) => setState(() => _active = v),
                ),
                ),
              ]),
            ),
            PageSection(
              title: 'Texte',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_channel == 'email') TextBlock(label: 'Objet', controller: _subject),
                Text('Cliquez sur une information pour l’insérer à l’endroit du curseur :', style: T.small),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in _placeholders)
                    Tooltip(
                      message: '{{${p.key}}}',
                      child: ActionChip(
                        label: Text(p.label.isEmpty ? p.key : p.label, style: T.small.copyWith(color: T.ink)),
                        avatar: const Icon(Icons.add_rounded, size: 14, color: T.mintDark),
                        backgroundColor: T.mintTint,
                        side: const BorderSide(color: T.mintTint2),
                        onPressed: _readOnly ? null : () => _insert(p.key),
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: T.surface,
                    borderRadius: BorderRadius.circular(T.rInner),
                    border: Border.all(color: _err['body'] != null ? T.danger : T.border3),
                  ),
                  child: TextField(
                    controller: _body,
                    readOnly: _readOnly,
                    minLines: 8,
                    maxLines: 18,
                    style: T.body,
                    decoration: const InputDecoration(
                        isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.all(12)),
                  ),
                ),
                FieldError(_err['body']),
                FieldError(_err['form']),
              ]),
            ),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: PageSection(
            title: 'Aperçu',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(_previewPartnerName == null ? 'Sans client (informations vides)' : 'Pour $_previewPartnerName',
                      style: T.small),
                ),
                TextButton(onPressed: _pickPreviewClient, child: const Text('Choisir un client')),
              ]),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _channel == 'whatsapp' ? const Color(0xFFE7F8EE) : T.bg,
                  borderRadius: BorderRadius.circular(T.rInner),
                  border: Border.all(color: T.border),
                ),
                child: _previewError != null
                    ? Text(_previewError!, style: T.small.copyWith(color: T.dangerDark))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (_channel == 'email' && (_preview?.subject ?? '').isNotEmpty) ...[
                          Text(_preview!.subject, style: T.body.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                        ],
                        SelectableText(_preview?.body ?? '…', style: T.body),
                      ]),
              ),
              if ((_preview?.missing ?? const []).isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Vides pour cet aperçu : ${_preview!.missing.join(', ')}', style: T.small.copyWith(color: T.warnDark)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}
