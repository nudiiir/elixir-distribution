// Vérification manuelle du canal de mise à jour : `dart run tool/check_update.dart`
import 'package:elixir_app/util/updater.dart';

Future<void> main() async {
  assert(isNewer('0.1.1', '0.1.0'));
  assert(!isNewer('0.1.1', '0.1.1'));
  assert(isNewer('0.2.0', '0.1.9'));
  assert(isNewer('1.0.0', '0.9.9'));
  assert(!isNewer('0.1.0', '0.1.1'));
  print('isNewer: OK');

  final u = await checkForUpdate();
  print(u == null
      ? 'checkForUpdate: à jour (kAppVersion=$kAppVersion) — attendu'
      : 'checkForUpdate: version ${u.version} → ${u.clientUrl} / ${u.serverUrl}');
}
