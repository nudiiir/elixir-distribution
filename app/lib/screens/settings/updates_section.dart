import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../util/updater.dart';
import '../../widgets/app_page.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

/// Paramètres → Mise à jour: installed version, server version, check and
/// install (same flow as the start-up check).
class UpdatesSection extends StatefulWidget {
  const UpdatesSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<UpdatesSection> createState() => _UpdatesSectionState();
}

enum _Check { idle, checking, upToDate, found }

class _UpdatesSectionState extends State<UpdatesSection> {
  String _serverVersion = '…';
  _Check _check = _Check.idle;
  UpdateInfo? _info;
  bool _installing = false;
  String _status = '';
  bool _serverHere = false;

  @override
  void initState() {
    super.initState();
    widget.ctx.api.systemInfo().then((j) {
      if (mounted) setState(() => _serverVersion = (j['version'] as String?) ?? 'inconnue');
    }).catchError((_) {
      if (mounted) setState(() => _serverVersion = 'inconnue (serveur ancien ou injoignable)');
    });
    hasLocalServerService().then((v) {
      if (mounted) setState(() => _serverHere = v);
    });
  }

  Future<void> _search() async {
    setState(() {
      _check = _Check.checking;
      _info = null;
    });
    final info = await checkForUpdate();
    if (!mounted) return;
    setState(() {
      _info = info;
      _check = info == null ? _Check.upToDate : _Check.found;
    });
  }

  Future<void> _install() async {
    final info = _info;
    if (info == null) return;
    final ok = await confirmAction(context,
        title: 'Installer la version ${info.version} ?',
        message: 'Terminez les ventes en cours avant. Après le téléchargement, Windows demandera une '
            'autorisation : cliquez « Oui ». L’application se fermera, s’installera et redémarrera '
            'toute seule.',
        confirmLabel: 'Installer maintenant');
    if (!ok || !mounted) return;
    setState(() {
      _installing = true;
      _status = 'Préparation…';
    });
    try {
      await downloadAndInstall(info, onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _installing = false);
      showToast(context, 'Mise à jour impossible : ${'$e'.replaceFirst('Exception: ', '')}',
          kind: ToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mismatch = _serverVersion != '…' &&
        RegExp(r'^\d').hasMatch(_serverVersion) &&
        _serverVersion != kAppVersion;
    return SettingsPage(
      title: 'Mise à jour',
      intro: 'Elixir vérifie aussi les mises à jour à chaque démarrage.',
      actions: [
        PageAction(
          label: _check == _Check.checking ? 'Recherche…' : 'Rechercher une mise à jour',
          icon: Icons.search_rounded,
          primary: _check != _Check.found,
          onPressed: _check == _Check.checking || _installing ? null : _search,
        ),
      ],
      children: [
        PageSection(
          title: 'Versions',
          child: FactGrid(facts: [
            ('Application (ce poste)', kAppVersion),
            ('Serveur', _serverVersion),
          ]),
        ),
        if (mismatch)
          const InfoBanner(
            kind: ToastKind.warning,
            text: 'L’application et le serveur n’ont pas la même version. Mettez à jour le PC serveur '
                'en premier, puis chaque caisse.',
          ),
        if (_check == _Check.upToDate)
          const InfoBanner(
            kind: ToastKind.success,
            icon: Icons.check_circle_outline_rounded,
            text: 'Aucune nouvelle version trouvée : vous êtes à jour. (Sans connexion Internet, la '
                'recherche ne peut pas aboutir.)',
          ),
        if (_check == _Check.found && _info != null)
          PageSection(
            title: 'Nouvelle version disponible : ${_info!.version}',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Vous avez la $kAppVersion. ${_serverHere && _info!.serverUrl != null ? 'Ce PC héberge le serveur : il sera mis à jour en même temps.' : 'Seule l’application de ce poste sera mise à jour.'}',
                  style: T.body),
              const SizedBox(height: 14),
              if (_installing)
                Row(children: [
                  const SizedBox(
                      width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: T.mintDeep)),
                  const SizedBox(width: 14),
                  Expanded(child: Text(_status, style: T.body)),
                ])
              else
                Row(children: [
                  PageAction(
                    label: 'Installer la version ${_info!.version}',
                    icon: Icons.system_update_alt_rounded,
                    primary: true,
                    onPressed: _install,
                  ),
                ]),
            ]),
          ),
      ],
    );
  }
}
