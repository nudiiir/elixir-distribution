import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/crm_api.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/side_panel.dart';
import '../../widgets/ui.dart';
import 'crm_common.dart';

/// « Envoyer un message » — reusable panel (client page, segments, orders…).
///
/// Choose a template + channel, the server fills the variables
/// (`POST /messages/render`), the text stays editable, then:
/// - WhatsApp → opens wa.me in the browser / WhatsApp Desktop;
/// - SMS → copy the text or open the `sms:` link;
/// - E-mail → sent by the server (SMTP of Paramètres › Messages).
/// Every message is written to the message log.
///
/// [templateCode] preselects a template (e.g. `order_ready`), [channel]
/// the channel (`whatsapp` default | `sms` | `email`). [orderId] fills the
/// order variables ({{numero}}, {{montant}}, {{lien_suivi}}…); the client is
/// deduced from the order when [partnerId] is null. [extra] completes or
/// replaces variables (`produit`, `promo`…).
///
/// Returns true when a message was sent or prepared (and logged).
Future<bool> showSendMessagePanel(
  BuildContext context,
  ApiClient api, {
  String? partnerId,
  String? partnerName,
  String? orderId,
  String? templateCode,
  String channel = 'whatsapp',
  Map<String, String>? extra,
}) async {
  final r = await showSidePanel<bool>(
    context,
    width: 640,
    builder: (_) => SendMessagePanel(
      api: api,
      partnerId: partnerId,
      partnerName: partnerName,
      orderId: orderId,
      templateCode: templateCode,
      channel: channel,
      extra: extra,
    ),
  );
  return r == true;
}

class SendMessagePanel extends StatefulWidget {
  const SendMessagePanel({
    super.key,
    required this.api,
    this.partnerId,
    this.partnerName,
    this.orderId,
    this.templateCode,
    this.channel = 'whatsapp',
    this.extra,
  });
  final ApiClient api;
  final String? partnerId;
  final String? partnerName;
  final String? orderId;
  final String? templateCode;
  final String channel;
  final Map<String, String>? extra;

  @override
  State<SendMessagePanel> createState() => _SendMessagePanelState();
}

class _SendMessagePanelState extends State<SendMessagePanel> {
  late String _channel = messageChannelLabels.containsKey(widget.channel) ? widget.channel : 'whatsapp';
  String _lang = 'fr';
  List<MessageTemplate> _all = const [];
  String? _templateId; // null = message libre
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _to = TextEditingController();
  List<String> _missing = const [];
  bool _loading = true;
  bool _rendering = false;
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _body.addListener(_onBody);
    _init();
  }

  bool _hadText = false;
  void _onBody() {
    final has = _body.text.isNotEmpty;
    if (has != _hadText && mounted) setState(() => _hadText = has);
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      _all = await widget.api.crmTemplates();
    } catch (e) {
      _error = errText(e);
    }
    _templateId = _pickTemplate(widget.templateCode)?.id;
    if (mounted) setState(() => _loading = false);
    await _render();
  }

  List<MessageTemplate> get _forChannel =>
      [for (final t in _all) if (t.channel == _channel && t.active && t.lang == _lang) t];

  MessageTemplate? _pickTemplate(String? code) {
    if (code == null) return null;
    MessageTemplate? find(String lang) {
      for (final t in _all) {
        if (t.code == code && t.channel == _channel && t.lang == lang && t.active) return t;
      }
      return null;
    }

    return find(_lang) ?? find('fr');
  }

  MessageTemplate? get _template {
    for (final t in _all) {
      if (t.id == _templateId) return t;
    }
    return null;
  }

  Future<void> _render() async {
    setState(() {
      _rendering = true;
      _error = null;
    });
    try {
      final t = _template;
      final r = await widget.api.crmRender(
        templateId: t?.id,
        // Free message: the server still needs a body to find the recipient.
        body: t == null ? (_body.text.trim().isEmpty ? '…' : _body.text) : null,
        subject: t == null ? _subject.text : null,
        channel: _channel,
        lang: _lang,
        partnerId: widget.partnerId,
        orderId: widget.orderId,
        extra: widget.extra,
      );
      if (!mounted) return;
      setState(() {
        if (t != null) {
          _body.text = r.body;
          _subject.text = r.subject;
        }
        _to.text = _channel == 'email' ? r.recipient : (r.phoneIntl.isNotEmpty ? r.phoneIntl : r.recipient);
        _missing = r.missing;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  void _setChannel(String c) {
    if (c == _channel) return;
    final code = _template?.code ?? widget.templateCode;
    setState(() {
      _channel = c;
      _templateId = _pickTemplate(code)?.id;
    });
    _render();
  }

  String get _templateCode => _template?.code ?? widget.templateCode ?? '';

  Future<void> _log(String status, {String? recipient}) async {
    try {
      await widget.api.crmLogMessage(
        partnerId: widget.partnerId,
        orderId: widget.orderId,
        channel: _channel,
        templateCode: _templateCode,
        recipient: recipient ?? _to.text.trim(),
        subject: _channel == 'email' ? _subject.text.trim() : '',
        body: _body.text,
        status: status,
      );
      _done = true;
    } catch (e) {
      if (mounted) showToast(context, 'Message non noté dans le journal : ${errText(e)}', kind: ToastKind.warning);
    }
  }

  Future<void> _openWhatsApp() async {
    final phone = phoneIntl(_to.text.trim());
    final url = 'https://wa.me/${phone.isEmpty ? '' : phone}?text=${Uri.encodeComponent(_body.text)}';
    setState(() => _busy = true);
    final ok = await openExternal(context, url);
    if (ok) {
      await _log('prepared', recipient: phone);
      if (mounted) {
        showToast(context, 'WhatsApp ouvert : vérifiez puis appuyez sur Envoyer.');
        Navigator.of(context).pop(true);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _copySms() async {
    await copyText(context, _body.text, done: 'Texte copié : collez-le dans votre téléphone.');
    if (!_done) await _log('prepared');
  }

  Future<void> _openSms() async {
    final phone = _to.text.trim().replaceAll(' ', '');
    final ok = await openExternal(context, 'sms:$phone?body=${Uri.encodeComponent(_body.text)}');
    if (ok && !_done) await _log('prepared');
  }

  Future<void> _sendEmail() async {
    if (_subject.text.trim().isEmpty) {
      setState(() => _error = 'Écrivez un objet pour l’e-mail.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.crmSendEmail(
        partnerId: widget.partnerId,
        orderId: widget.orderId,
        to: _to.text.trim(),
        subject: _subject.text.trim(),
        body: _body.text,
        templateCode: _templateCode,
      );
      if (!mounted) return;
      showToast(context, 'E-mail envoyé à ${_to.text.trim()}.');
      Navigator.of(context).pop(true);
    } on CrmApiException catch (e) {
      if (e.smtpNotConfigured) {
        setState(() => _error =
            'L’envoi d’e-mails n’est pas encore réglé (Paramètres › Messages). Vous pouvez l’ouvrir dans votre messagerie.');
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMailto() async {
    final url = 'mailto:${_to.text.trim()}?subject=${Uri.encodeComponent(_subject.text)}'
        '&body=${Uri.encodeComponent(_body.text)}';
    final ok = await openExternal(context, url);
    if (ok) {
      await _log('prepared');
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = _forChannel;
    final hasTemplate = templates.any((t) => t.id == _templateId);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
        decoration: const BoxDecoration(color: T.surface, border: Border(bottom: BorderSide(color: T.border))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Envoyer un message', style: T.h1),
              if ((widget.partnerName ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('À ${widget.partnerName}', style: T.bodyMuted),
              ],
            ]),
          ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(_done),
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Fermer'),
          ),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.fromLTRB(24, 18, 24, 24), children: [
                Text('Canal', style: T.label),
                const SizedBox(height: 6),
                ChoiceRow<String>(
                  options: [for (final e in messageChannelLabels.entries) (e.key, e.value)],
                  value: _channel,
                  onSelect: _setChannel,
                ),
                const SizedBox(height: 14),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: DropdownBlock<String>(
                      label: 'Modèle',
                      value: hasTemplate ? _templateId : null,
                      noneLabel: 'Message libre (sans modèle)',
                      options: [for (final t in templates) (t.id, t.title)],
                      onChanged: (v) {
                        setState(() => _templateId = v);
                        _render();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownBlock<String>(
                    label: 'Langue',
                    width: 150,
                    value: _lang,
                    options: [for (final e in messageLangLabels.entries) (e.key, e.value)],
                    onChanged: (v) {
                      final code = _template?.code ?? widget.templateCode;
                      setState(() {
                        _lang = v ?? 'fr';
                        _templateId = _pickTemplate(code)?.id;
                      });
                      _render();
                    },
                  ),
                ]),
                TextBlock(
                  label: _channel == 'email' ? 'Adresse e-mail' : 'Numéro (WhatsApp / SMS)',
                  controller: _to,
                  hint: _channel == 'email' ? 'client@exemple.dz' : '213550123456',
                  helper: _channel == 'email'
                      ? 'Vide = e-mail du client, puis de son contact principal.'
                      : 'Numéro du client (WhatsApp, sinon téléphone, sinon contact principal).',
                ),
                if (_channel == 'email') TextBlock(label: 'Objet', controller: _subject),
                Row(children: [
                  Expanded(child: Text('Texte du message', style: T.label)),
                  if (_rendering)
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  else if (_template != null)
                    TextButton.icon(
                      onPressed: _render,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Remettre le texte du modèle'),
                    ),
                ]),
                const SizedBox(height: 5),
                Container(
                  decoration: BoxDecoration(
                    color: T.surface,
                    borderRadius: BorderRadius.circular(T.rInner),
                    border: Border.all(color: T.border3),
                  ),
                  child: TextField(
                    controller: _body,
                    minLines: 8,
                    maxLines: 16,
                    style: T.body,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('Vous pouvez modifier le texte avant l’envoi.', style: T.small),
                if (_missing.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: T.warnTint, borderRadius: BorderRadius.circular(T.rInner)),
                    child: Text(
                        'Informations manquantes (laissées vides) : ${_missing.join(', ')}. Complétez le texte si besoin.',
                        style: T.small.copyWith(color: T.warnDark)),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  FieldError(_error),
                ],
              ]),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        decoration: const BoxDecoration(color: T.surface, border: Border(top: BorderSide(color: T.border))),
        child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _body.text.isEmpty ? null : () => copyText(context, _body.text, done: 'Texte copié.'),
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('Copier le texte'),
          ),
          ...switch (_channel) {
            'sms' => [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openSms,
                  icon: const Icon(Icons.sms_outlined, size: 17),
                  label: const Text('Ouvrir l’appli SMS'),
                ),
                SizedBox(
                  width: 220,
                  child: PrimaryButton(label: 'Copier pour SMS', onPressed: _busy ? null : _copySms),
                ),
              ],
            'email' => [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openMailto,
                  icon: const Icon(Icons.open_in_new_rounded, size: 17),
                  label: const Text('Ouvrir dans ma messagerie'),
                ),
                SizedBox(
                  width: 200,
                  child: PrimaryButton(label: _busy ? 'Envoi…' : 'Envoyer l’e-mail', onPressed: _busy ? null : _sendEmail),
                ),
              ],
            _ => [
                SizedBox(
                  width: 220,
                  child: PrimaryButton(
                      label: _busy ? '…' : 'Ouvrir WhatsApp', onPressed: _busy || _body.text.isEmpty ? null : _openWhatsApp),
                ),
              ],
          },
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Bulk WhatsApp (segments, lists)
// ---------------------------------------------------------------------------

/// Prepares one WhatsApp message per client: choose a template, then open
/// them one by one (each is logged), or copy every link at once.
Future<void> showBulkWhatsAppPanel(BuildContext context, ApiClient api,
    {required List<(String, String)> clients, String? templateCode}) {
  return showSidePanel<void>(
    context,
    width: 720,
    builder: (_) => _BulkWhatsAppPanel(api: api, clients: clients, templateCode: templateCode),
  );
}

class _BulkWhatsAppPanel extends StatefulWidget {
  const _BulkWhatsAppPanel({required this.api, required this.clients, this.templateCode});
  final ApiClient api;
  final List<(String, String)> clients; // (partner id, name)
  final String? templateCode;

  @override
  State<_BulkWhatsAppPanel> createState() => _BulkWhatsAppPanelState();
}

class _BulkWhatsAppPanelState extends State<_BulkWhatsAppPanel> {
  List<MessageTemplate> _templates = const [];
  String? _templateId;
  final Map<String, RenderedMessage> _rendered = {};
  final Set<String> _sent = {};
  final Map<String, String> _errors = {};
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    widget.api.crmTemplates(channel: 'whatsapp').then((t) {
      if (!mounted) return;
      setState(() {
        _templates = [for (final x in t) if (x.active) x];
        final pre = _templates.where((x) => x.code == (widget.templateCode ?? 'promo') && x.lang == 'fr');
        _templateId = pre.isNotEmpty ? pre.first.id : (_templates.isEmpty ? null : _templates.first.id);
        _loading = false;
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _loading = false);
    });
  }

  MessageTemplate? get _template => _templates.where((t) => t.id == _templateId).firstOrNull;

  Future<RenderedMessage?> _renderFor(String partnerId) async {
    final cached = _rendered[partnerId];
    if (cached != null) return cached;
    final t = _template;
    if (t == null) return null;
    try {
      final r = await widget.api.crmRender(templateId: t.id, channel: 'whatsapp', partnerId: partnerId);
      _rendered[partnerId] = r;
      _errors.remove(partnerId);
      return r;
    } catch (e) {
      _errors[partnerId] = errText(e);
      return null;
    }
  }

  Future<void> _open((String, String) c) async {
    setState(() => _working = true);
    final r = await _renderFor(c.$1);
    if (r != null && mounted) {
      if (r.phoneIntl.isEmpty) _errors[c.$1] = 'Pas de numéro : choisissez le contact dans WhatsApp.';
      final ok = await openExternal(context, r.waLink);
      if (ok) {
        _sent.add(c.$1);
        try {
          await widget.api.crmLogMessage(
              partnerId: c.$1,
              channel: 'whatsapp',
              templateCode: _template?.code ?? '',
              recipient: r.phoneIntl,
              body: r.body,
              status: 'prepared');
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _working = false);
  }

  Future<void> _openNext() async {
    final next = widget.clients.where((c) => !_sent.contains(c.$1)).firstOrNull;
    if (next == null) {
      showToast(context, 'Tous les messages sont préparés.');
      return;
    }
    await _open(next);
  }

  Future<void> _copyAll() async {
    setState(() => _working = true);
    final lines = <String>[];
    for (final c in widget.clients) {
      final r = await _renderFor(c.$1);
      if (r != null) lines.add('${c.$2} : ${r.waLink}');
    }
    if (mounted) {
      setState(() => _working = false);
      await copyText(context, lines.join('\n'), done: '${lines.length} liens WhatsApp copiés.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.clients.length - _sent.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
        decoration: const BoxDecoration(color: T.surface, border: Border(bottom: BorderSide(color: T.border))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Message WhatsApp à plusieurs clients', style: T.h1),
              const SizedBox(height: 4),
              Text('${widget.clients.length} client(s) · ${_sent.length} préparé(s)', style: T.bodyMuted),
            ]),
          ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Fermer'),
          ),
        ]),
      ),
      if (_loading)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownBlock<String>(
              label: 'Modèle WhatsApp',
              value: _templateId,
              options: [for (final t in _templates) (t.id, '${t.title} (${messageLangLabels[t.lang] ?? t.lang})')],
              onChanged: (v) => setState(() {
                _templateId = v;
                _rendered.clear();
              }),
            ),
            Text(
                'WhatsApp ne permet pas l’envoi automatique : chaque message s’ouvre prêt à partir, '
                'vous appuyez sur Envoyer. Utilisez « Ouvrir le suivant » pour enchaîner.',
                style: T.small),
            const SizedBox(height: 10),
          ]),
        ),
        const Divider(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: widget.clients.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (_, i) {
              final c = widget.clients[i];
              final done = _sent.contains(c.$1);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 18, color: done ? T.mintDeep : T.ghost),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.$2, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                      if (_errors[c.$1] != null)
                        Text(_errors[c.$1]!, style: T.small.copyWith(color: T.warnDark)),
                    ]),
                  ),
                  TextButton.icon(
                    onPressed: _working || _template == null ? null : () => _open(c),
                    icon: const Icon(Icons.chat_outlined, size: 16),
                    label: Text(done ? 'Rouvrir' : 'Ouvrir WhatsApp'),
                  ),
                ]),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          decoration: const BoxDecoration(color: T.surface, border: Border(top: BorderSide(color: T.border))),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            OutlinedButton.icon(
              onPressed: _working || _template == null ? null : _copyAll,
              icon: const Icon(Icons.link_rounded, size: 17),
              label: const Text('Copier tous les liens'),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 240,
              child: PrimaryButton(
                label: left == 0 ? 'Tout est préparé' : 'Ouvrir le suivant ($left)',
                onPressed: _working || _template == null || left == 0 ? null : _openNext,
              ),
            ),
          ]),
        ),
      ],
    ]);
  }
}
