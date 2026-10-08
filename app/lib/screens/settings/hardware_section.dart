import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/client.dart';
import '../../theme/tokens.dart';
import '../../util/config.dart';
import '../../util/escpos.dart';
import '../../util/feedback.dart';
import '../../util/print_to.dart';
import '../../util/raw_printer.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres → Impression et matériel — settings of THIS PC only
/// (LocalConfig): printers, cash drawer, scale barcodes, server address.
class HardwareSection extends StatefulWidget {
  const HardwareSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<HardwareSection> createState() => _HardwareSectionState();
}

class _HardwareSectionState extends State<HardwareSection> {
  List<String> _printers = const [];
  String? _printerError;

  late String? _ticket = widget.ctx.config.ticketPrinter;
  late String? _a4 = widget.ctx.config.a4Printer;
  late String? _label = widget.ctx.config.labelPrinter;
  late bool _drawer = widget.ctx.config.openDrawerOnCash;
  late final _weightPrefix = TextEditingController(text: widget.ctx.config.scaleWeightPrefix);
  late final _pricePrefix = TextEditingController(text: widget.ctx.config.scalePricePrefix);
  late final _server = TextEditingController(text: widget.ctx.config.server);
  String? _prefixError;
  String? _serverResult;
  bool _serverOk = false;
  final Set<String> _testing = {};
  bool _saving = false;

  LocalConfig get _cfg => widget.ctx.config;
  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _loadPrinters();
  }

  @override
  void dispose() {
    _weightPrefix.dispose();
    _pricePrefix.dispose();
    _server.dispose();
    super.dispose();
  }

  void _loadPrinters() {
    try {
      final p = listPrinters();
      setState(() {
        _printers = p;
        _printerError = null;
      });
    } catch (e) {
      setState(() => _printerError = 'Liste des imprimantes indisponible : $e');
    }
  }

  bool get _dirty =>
      _ticket != _cfg.ticketPrinter ||
      _a4 != _cfg.a4Printer ||
      _label != _cfg.labelPrinter ||
      _drawer != _cfg.openDrawerOnCash ||
      _weightPrefix.text.trim() != _cfg.scaleWeightPrefix ||
      _pricePrefix.text.trim() != _cfg.scalePricePrefix;

  String? _validatePrefixes() {
    final w = _weightPrefix.text.trim(), p = _pricePrefix.text.trim();
    final two = RegExp(r'^\d{2}$');
    if (!two.hasMatch(w) || !two.hasMatch(p)) return 'Chaque préfixe fait exactement 2 chiffres.';
    if (w == p) return 'Les deux préfixes doivent être différents.';
    return null;
  }

  Future<void> _save() async {
    final err = _validatePrefixes();
    setState(() => _prefixError = err);
    if (err != null) return;
    setState(() => _saving = true);
    _cfg
      ..ticketPrinter = _ticket
      ..a4Printer = _a4
      ..labelPrinter = _label
      ..openDrawerOnCash = _drawer
      ..scaleWeightPrefix = _weightPrefix.text.trim()
      ..scalePricePrefix = _pricePrefix.text.trim();
    await _cfg.save();
    if (!mounted) return;
    setState(() => _saving = false);
    showToast(context, 'Réglages de ce poste enregistrés.');
  }

  Future<void> _test(String what, Future<void> Function() run, String okMsg) async {
    setState(() => _testing.add(what));
    try {
      await run();
      if (mounted) showToast(context, okMsg);
    } catch (e) {
      if (mounted) {
        showToast(context, '$e'.replaceFirst('Exception: ', ''), kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _testing.remove(what));
    }
  }

  Future<void> _testServer() async {
    final url = LocalConfig.normalizeServer(_server.text);
    setState(() => _serverResult = 'Test en cours…');
    final ok = await ApiClient(baseUrl: url).health();
    if (!mounted) return;
    setState(() {
      _serverOk = ok;
      _serverResult = ok ? 'Serveur joignable à $url' : 'Aucun serveur Elixir ne répond à $url';
    });
  }

  Future<void> _saveServer() async {
    final url = LocalConfig.normalizeServer(_server.text);
    if (url == _cfg.server) {
      showToast(context, 'C’est déjà l’adresse utilisée.', kind: ToastKind.info);
      return;
    }
    final ok = await ApiClient(baseUrl: url).health();
    if (!mounted) return;
    final go = await confirmAction(context,
        title: 'Changer l’adresse du serveur ?',
        message: ok
            ? 'Ce poste se connectera à $url. Si c’est un autre serveur, vous devrez vous reconnecter.'
            : 'Aucun serveur ne répond à $url pour le moment. Ce poste ne pourra plus travailler tant '
                'que ce serveur ne répond pas. Continuer quand même ?',
        confirmLabel: 'Changer l’adresse',
        danger: !ok);
    if (!go) return;
    _cfg.server = url;
    await _cfg.save();
    _api.baseUrl = url;
    if (!mounted) return;
    setState(() => _server.text = url);
    showToast(context, 'Adresse du serveur enregistrée : $url');
  }

  Widget _printerPicker({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
    required String noneLabel,
    bool rawOnly = false,
  }) {
    final known = value == null || _printers.contains(value);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FieldLabel(label),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rInner),
              border: Border.all(color: T.border3),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: known ? value : null,
                isExpanded: true,
                style: T.body,
                icon: const Icon(Icons.expand_more, size: 18, color: T.muted),
                hint: Text(known ? noneLabel : '$value (introuvable sur ce PC)', style: T.bodyMuted),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text(noneLabel)),
                  for (final p in _printers)
                    DropdownMenuItem<String?>(
                      value: p,
                      enabled: !(rawOnly && isVirtualPrinter(p)),
                      child: Text(
                        rawOnly && isVirtualPrinter(p) ? '$p — virtuelle, ne convient pas aux tickets' : p,
                        style: rawOnly && isVirtualPrinter(p) ? T.bodyMuted : T.body,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => onChanged(v),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        PageAction(label: 'Actualiser', icon: Icons.refresh_rounded, onPressed: _loadPrinters),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _testing.isNotEmpty;
    return SettingsPage(
      title: 'Impression et matériel',
      intro: 'Ces réglages concernent CE POSTE uniquement : chaque PC du magasin a les siens '
          '(imprimantes, tiroir, adresse du serveur).',
      actions: [
        PageAction(
          label: _saving ? 'Enregistrement…' : 'Enregistrer',
          icon: Icons.check_rounded,
          primary: true,
          onPressed: _saving || !_dirty ? null : _save,
        ),
      ],
      children: [
        if (_printerError != null) InfoBanner(kind: ToastKind.error, text: _printerError!),
        PageSection(
          title: 'Imprimante tickets (caisse)',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('L’imprimante thermique 80 mm de la caisse. Le ticket sort après chaque vente.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            _printerPicker(
              label: 'Imprimante tickets',
              value: _ticket,
              noneLabel: 'Aucune — pas de ticket imprimé',
              rawOnly: true,
              onChanged: (v) => setState(() => _ticket = v),
            ),
            const SizedBox(height: 12),
            Row(children: [
              PageAction(
                label: _testing.contains('ticket') ? 'Impression…' : 'Imprimer une page de test',
                icon: Icons.receipt_outlined,
                onPressed: _ticket == null || busy
                    ? null
                    : () => _test('ticket', () => printTestTicket(_ticket!),
                        'Ticket de test envoyé à « $_ticket ».'),
              ),
            ]),
          ]),
        ),
        PageSection(
          title: 'Tiroir-caisse',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Le tiroir se branche sur l’imprimante tickets (prise RJ11) : c’est elle qui l’ouvre.',
                style: T.bodyMuted),
            const SizedBox(height: 6),
            SwitchRow(
              title: 'Ouvrir le tiroir après une vente en espèces',
              explanation: _drawer
                  ? 'Oui : le tiroir s’ouvre quand un ticket payé en espèces est imprimé.'
                  : 'Non : le tiroir reste fermé (ouvrez-le avec la clé).',
              value: _drawer,
              onChanged: (v) => setState(() => _drawer = v),
            ),
            const SizedBox(height: 6),
            PageAction(
              label: _testing.contains('drawer') ? 'Ouverture…' : 'Ouvrir le tiroir (test)',
              icon: Icons.inbox_outlined,
              onPressed: _ticket == null || busy
                  ? null
                  : () => _test('drawer', () => rawPrint(_ticket!, drawerKick),
                      'Impulsion envoyée : le tiroir doit s’ouvrir.'),
            ),
            if (_ticket == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Choisissez d’abord l’imprimante tickets.', style: T.small),
              ),
          ]),
        ),
        PageSection(
          title: 'Imprimante A4 (documents)',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pour les factures, devis, bons de livraison et rapports.', style: T.bodyMuted),
            const SizedBox(height: 12),
            _printerPicker(
              label: 'Imprimante A4',
              value: _a4,
              noneLabel: 'Imprimante par défaut de Windows',
              onChanged: (v) => setState(() => _a4 = v),
            ),
            const SizedBox(height: 12),
            PageAction(
              label: _testing.contains('a4') ? 'Impression…' : 'Imprimer une page de test',
              icon: Icons.description_outlined,
              onPressed: busy
                  ? null
                  : () => _test('a4', () => printTestPdf(printer: _a4, label: false),
                      'Page de test envoyée à « ${_a4 ?? 'l’imprimante par défaut'} ».'),
            ),
          ]),
        ),
        PageSection(
          title: 'Imprimante étiquettes',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pour les étiquettes de prix et de codes-barres des produits.', style: T.bodyMuted),
            const SizedBox(height: 12),
            _printerPicker(
              label: 'Imprimante étiquettes',
              value: _label,
              noneLabel: 'Imprimante par défaut de Windows',
              onChanged: (v) => setState(() => _label = v),
            ),
            const SizedBox(height: 12),
            PageAction(
              label: _testing.contains('label') ? 'Impression…' : 'Imprimer une étiquette de test',
              icon: Icons.label_outline_rounded,
              onPressed: busy
                  ? null
                  : () => _test('label', () => printTestPdf(printer: _label, label: true),
                      'Étiquette de test (50 × 30 mm) envoyée à « ${_label ?? 'l’imprimante par défaut'} ».'),
            ),
          ]),
        ),
        PageSection(
          title: 'Balance : codes-barres des étiquettes',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'La balance imprime une étiquette dont le code-barres commence par un préfixe à 2 chiffres, '
                'suivi du code de l’article puis du poids ou du prix. La caisse lit ces étiquettes '
                'automatiquement. Ne changez ces valeurs que si votre balance utilise d’autres préfixes.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            FieldPair(
              LabeledField(
                label: 'Préfixe « poids »',
                controller: _weightPrefix,
                mono: true,
                help: 'Le code contient le poids en grammes (habituellement 21).',
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                onChanged: (_) => setState(() {}),
              ),
              LabeledField(
                label: 'Préfixe « prix »',
                controller: _pricePrefix,
                mono: true,
                help: 'Le code contient le prix à payer (habituellement 22).',
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                onChanged: (_) => setState(() {}),
              ),
            ),
            FieldError(_prefixError),
          ]),
        ),
        PageSection(
          title: 'Adresse du serveur',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                'Le PC où le serveur Elixir est installé (la base de données du magasin). Sur ce PC '
                'lui-même : 127.0.0.1. Sur une autre caisse : l’adresse IP du PC serveur, par exemple '
                '192.168.1.10.',
                style: T.bodyMuted),
            const SizedBox(height: 12),
            LabeledField(
              label: 'Adresse',
              controller: _server,
              mono: true,
              hint: '192.168.1.10:8543',
              onSubmitted: (_) => _testServer(),
            ),
            if (_serverResult != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Icon(_serverOk ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      size: 18, color: _serverOk ? T.mintDark : T.dangerDark),
                  const SizedBox(width: 8),
                  Flexible(
                      child: Text(_serverResult!,
                          style: T.body.copyWith(color: _serverOk ? T.mintDark : T.dangerDark))),
                ]),
              ),
            Wrap(runSpacing: 8, children: [
              PageAction(label: 'Tester la connexion', icon: Icons.wifi_tethering_rounded, onPressed: _testServer),
              PageAction(label: 'Utiliser cette adresse', icon: Icons.dns_outlined, onPressed: _saveServer),
            ]),
          ]),
        ),
        if (_dirty)
          const InfoBanner(
            kind: ToastKind.warning,
            icon: Icons.edit_note_rounded,
            text: 'Modifications non enregistrées — cliquez sur « Enregistrer » en haut de la page.',
          ),
      ],
    );
  }
}
