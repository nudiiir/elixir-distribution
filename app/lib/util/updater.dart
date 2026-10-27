import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Version embedded in the binary — bump on every release, together
/// with pubspec.yaml and installer/*.iss.
const kAppVersion = '0.4.0';

/// Public repository that hosts the installers (GitHub Releases).
/// GitHub "owner/name" of the releases repository. Empty in the public
/// build, which turns the update check off.
const kReleaseRepo = '';

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

/// Queries GitHub; returns null when up to date (or offline).
Future<UpdateInfo?> checkForUpdate() async {
  if (kReleaseRepo.isEmpty) return null;
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

/// Does this machine host the server service? (only this machine should
/// receive the server installer — not the secondary tills)
Future<bool> hasLocalServerService() async {
  try {
    final r = await Process.run('sc', ['query', 'ElixirServer']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Downloads the installers then launches the elevated reinstall.
///
/// LESSON LEARNED THE HARD WAY: a process started `detached` DIES with the app
/// on Windows — exiting right away killed the update before even
/// the UAC prompt. So we stay ALIVE until a flag file
/// confirms the elevation succeeded: the elevated process itself is started by
/// Windows (AppInfo) and survives the app closing.
///
/// Throws if the user declines the Windows authorization or if
/// nothing happens; quits the app ONLY once the installation has started.
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

  // ELEVATED script: waits for the app to close, installs, relaunches.
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

  // NON-elevated launcher: triggers UAC and writes the matching flag.
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

  // UAC may stay on screen for a while: we wait up to 3 minutes.
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (File(cancelFlag).existsSync()) {
      throw Exception(
          "autorisation Windows refusée — la mise à jour a été annulée");
    }
    if (File(okFlag).existsSync()) {
      onStatus?.call('Installation en cours — l\'application va redémarrer…');
      // The elevated installer runs under AppInfo: it outlives us.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    }
  }
  throw Exception(
      "aucune réponse à la demande d'autorisation — mise à jour annulée");
}
