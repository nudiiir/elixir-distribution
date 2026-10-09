import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Version embarquée dans le binaire — à bumper à chaque release, en même
/// temps que pubspec.yaml et installer/*.iss.
const kAppVersion = '0.4.0';

/// Dépôt public qui porte les installateurs (GitHub Releases).
const kReleaseRepo = 'OWNER/elixir-gestion-releases';

class UpdateInfo {
  UpdateInfo({required this.version, required this.clientUrl, this.serverUrl});
  final String version;
  final String clientUrl;
  final String? serverUrl;
}

bool isNewer(String remote, String local) {
  List<int> parse(String v) => v
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final r = parse(remote), l = parse(local);
  for (var i = 0; i < 3; i++) {
    final a = i < r.length ? r[i] : 0;
    final b = i < l.length ? l[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}

/// Interroge GitHub ; renvoie null si on est à jour (ou hors ligne).
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$kReleaseRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    if (tag.isEmpty || !isNewer(tag, kAppVersion)) return null;
    String? client, server;
    for (final a in (j['assets'] as List? ?? const [])) {
      final name = a['name'] as String? ?? '';
      final url = a['browser_download_url'] as String?;
      if (name.startsWith('ElixirGestion-Setup')) client = url;
      if (name.startsWith('ElixirServeur-Setup')) server = url;
    }
    if (client == null) return null;
    return UpdateInfo(version: tag, clientUrl: client, serverUrl: server);
  } catch (_) {
    return null;
  }
}

/// Le poste actuel héberge-t-il le service serveur ? (seul ce poste doit
/// recevoir l'installateur serveur — pas les caisses secondaires)
Future<bool> hasLocalServerService() async {
  try {
    final r = await Process.run('sc', ['query', 'ElixirServer']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Télécharge les installateurs puis lance la réinstallation en élévation.
///
/// PIÈGE APPRIS À LA DURE : un process lancé en `detached` MEURT avec l'app
/// sous Windows — sortir tout de suite tuait la mise à jour avant même
/// l'invite UAC. On reste donc VIVANT jusqu'à ce qu'un fichier-drapeau
/// confirme que l'élévation a réussi : le process élevé, lui, est lancé par
/// Windows (AppInfo) et survit à la fermeture de l'app.
///
/// Jette une exception si l'utilisateur refuse l'autorisation Windows ou si
/// rien ne se passe ; ne quitte l'app QUE lorsque l'installation est lancée.
Future<void> downloadAndInstall(
  UpdateInfo u, {
  void Function(String status)? onStatus,
}) async {
  final dir = await Directory.systemTemp.createTemp('elixir-update-');

  Future<File> fetch(String url, String name) async {
    onStatus?.call('Téléchargement de $name…');
    final r = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
    if (r.statusCode != 200) {
      throw Exception('téléchargement échoué ($name : HTTP ${r.statusCode})');
    }
    final f = File('${dir.path}\\$name');
    await f.writeAsBytes(r.bodyBytes, flush: true);
    return f;
  }

  final client = await fetch(u.clientUrl, 'ElixirGestion-Setup.exe');
  File? server;
  if (u.serverUrl != null && await hasLocalServerService()) {
    server = await fetch(u.serverUrl!, 'ElixirServeur-Setup.exe');
  }

  // Script ÉLEVÉ : attend que l'app se ferme, installe, relance.
  final okFlag = '${dir.path}\\ok.flag';
  final cancelFlag = '${dir.path}\\cancel.flag';
  final log = '${dir.path}\\install.log';
  final install = File('${dir.path}\\install.ps1');
  await install.writeAsString([
    'Start-Transcript -Path "$log" -Force | Out-Null',
    'Start-Sleep -Seconds 2', // laisse l'app se fermer proprement
    if (server != null)
      'Start-Process -FilePath "${server.path}" -ArgumentList \'/VERYSILENT\' -Wait',
    'Start-Process -FilePath "${client.path}" -ArgumentList \'/VERYSILENT\' -Wait',
    r'Start-Process -FilePath "C:\Program Files\Elixir\Client\elixir_app.exe"',
    'Stop-Transcript | Out-Null',
  ].join('\r\n'), flush: true);

  // Lanceur NON élevé : déclenche l'UAC et pose le drapeau correspondant.
  final launcher = File('${dir.path}\\launch.ps1');
  await launcher.writeAsString([
    r'try {',
    '  Start-Process powershell -Verb RunAs -WindowStyle Hidden '
        '-ArgumentList \'-NoProfile -ExecutionPolicy Bypass -File "${install.path}"\'',
    '  Set-Content -Path "$okFlag" -Value ok',
    r'} catch {',
    '  Set-Content -Path "$cancelFlag" -Value "\$_"',
    r'}',
  ].join('\r\n'), flush: true);

  onStatus?.call("Autorisez l'installation dans la fenêtre Windows…");
  await Process.start(
    'powershell',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', launcher.path],
  );

  // L'UAC peut rester affichée un moment : on attend jusqu'à 3 minutes.
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (File(cancelFlag).existsSync()) {
      throw Exception(
          "autorisation Windows refusée — la mise à jour a été annulée");
    }
    if (File(okFlag).existsSync()) {
      onStatus?.call('Installation en cours — l\'application va redémarrer…');
      // L'installeur élevé tourne sous AppInfo : il nous survit.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    }
  }
  throw Exception(
      "aucune réponse à la demande d'autorisation — mise à jour annulée");
}
