import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../theme/tokens.dart';
import '../../util/feedback.dart';
import '../../widgets/app_page.dart';
import '../../widgets/data_table.dart';
import '../../widgets/ui.dart';
import 'general_widgets.dart';
import 'settings_shell.dart';

String backupKindLabel(String kind) => switch (kind) {
      'before_restore' => 'Avant une restauration',
      'before_reset' => 'Avant une réinitialisation',
      _ => 'Sauvegarde',
    };

String _size(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} Mo'
    : '${(bytes / 1024).ceil()} Ko';

/// Paramètres → Sauvegardes: list, back up now, open the folder, and a
/// guided restore applied at the next server start.
class BackupsSection extends StatefulWidget {
  const BackupsSection({super.key, required this.ctx});
  final SettingsContext ctx;

  @override
  State<BackupsSection> createState() => _BackupsSectionState();
}

class _BackupsSectionState extends State<BackupsSection> {
  BackupsStatus? _status;
  bool _loading = true;
  String? _error;
  bool _backingUp = false;

  ApiClient get _api => widget.ctx.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final st = await _api.backupsStatus();
      if (mounted) {
        setState(() {
          _status = st;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de lire les sauvegardes : $e';
        });
      }
    }
  }

  Future<void> _backupNow() async {
    setState(() => _backingUp = true);
    try {
      final path = await _api.runBackup();
      await _load();
      if (mounted) {
        showToast(context, 'Sauvegarde faite : ${path.split(RegExp(r'[\\/]')).last}',
            actionLabel: 'Ouvrir le dossier', onAction: _openFolder);
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  void _openFolder() {
    final dir = _status?.dir ?? '';
    if (dir.isNotEmpty && Directory(dir).existsSync()) {
      Process.run('explorer.exe', [dir]);
    } else {
      showToast(context,
          'Le dossier des sauvegardes est sur le PC serveur : $dir. Ouvrez-le depuis ce PC.',
          kind: ToastKind.info);
    }
  }

  Future<void> _restore(BackupInfo b) async {
    final ok = await confirmTyped(
      context,
      title: 'Restaurer la sauvegarde du ${fmtDateTime(b.modTime)} ?',
      message: 'Toutes les données du magasin reviendront à cet instant : les ventes, achats et '
          'modifications faites depuis seront retirées.\n\n'
          'Par sécurité, les données actuelles seront d’abord copiées dans une sauvegarde '
          '« Avant une restauration » : vous pourrez revenir en arrière.\n\n'
          'La restauration se fera au prochain démarrage du serveur.',
      word: 'RESTAURER',
      confirmLabel: 'Prévoir la restauration',
    );
    if (!ok) return;
    try {
      await _api.scheduleRestore(b.name);
      await _load();
      if (!mounted) return;
      await _showRestartHelp(b);
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _showRestartHelp(BackupInfo b) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.surface,
          title: const Text('Dernière étape : redémarrer le serveur', style: T.h2),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: const _RestartSteps(),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('J’ai compris')),
          ],
        ),
      );

  Future<void> _cancelRestore() async {
    final ok = await confirmAction(context,
        title: 'Annuler la restauration prévue ?',
        message: 'Les données actuelles seront gardées au prochain démarrage.',
        confirmLabel: 'Annuler la restauration');
    if (!ok) return;
    try {
      await _api.cancelRestore();
      await _load();
      if (mounted) showToast(context, 'Restauration annulée. Rien ne changera au redémarrage.');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, kind: ToastKind.error);
    }
  }

  Future<void> _pickAndRestore() async {
    final items = _status?.items ?? const [];
    if (items.isEmpty) {
      showToast(context, 'Aucune sauvegarde à restaurer.', kind: ToastKind.info);
      return;
    }
    final b = await showDialog<BackupInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: T.surface,
        title: const Text('Quelle sauvegarde restaurer ?', style: T.h2),
        children: [
          for (final b in items.take(30))
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(b),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  const Icon(Icons.history_rounded, size: 18, color: T.muted),
                  const SizedBox(width: 10),
                  Expanded(child: Text(fmtDateTime(b.modTime), style: T.body.copyWith(fontWeight: FontWeight.w600))),
                  Text(backupKindLabel(b.kind), style: T.bodyMuted),
                  const SizedBox(width: 12),
                  Text(_size(b.sizeBytes), style: T.monoSmall),
                ]),
              ),
            ),
        ],
      ),
    );
    if (b != null) await _restore(b);
  }

  List<Widget> _banners() {
    final st = _status;
    if (st == null) return const [];
    final out = <Widget>[];
    if (st.pendingRestore.isNotEmpty) {
      BackupInfo? b;
      for (final e in st.items) {
        if (e.name == st.pendingRestore) b = e;
      }
      out.add(InfoBanner(
        kind: ToastKind.warning,
        icon: Icons.restore_rounded,
        title: 'Restauration prévue au prochain démarrage',
        text: 'Sauvegarde ${b != null ? 'du ${fmtDateTime(b.modTime)}' : st.pendingRestore}. '
            'Elle sera appliquée quand le serveur redémarrera.',
        actions: [
          PageAction(
              label: 'Comment redémarrer ?',
              icon: Icons.help_outline_rounded,
              onPressed: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: T.surface,
                      title: const Text('Redémarrer le serveur', style: T.h2),
                      content: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480), child: const _RestartSteps()),
                      actions: [
                        FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Fermer')),
                      ],
                    ),
                  )),
          PageAction(label: 'Annuler la restauration', icon: Icons.close_rounded, onPressed: _cancelRestore),
        ],
      ));
    }
    final lr = st.lastRestore;
    if (lr != null && st.pendingRestore.isEmpty) {
      out.add(lr.error.isEmpty
          ? InfoBanner(
              kind: ToastKind.success,
              icon: Icons.check_circle_outline_rounded,
              text: 'Dernière restauration le ${fmtDateTime(lr.at)} : ${lr.backup}. '
                  'Les données d’avant sont gardées dans « ${lr.before} ».',
            )
          : InfoBanner(
              kind: ToastKind.error,
              title: 'La dernière restauration n’a pas pu se faire (${fmtDateTime(lr.at)})',
              text: '${lr.error}. Les données actuelles n’ont pas été modifiées.',
            ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final items = _status?.items ?? const <BackupInfo>[];
    final height = (170 + 50.0 * items.length).clamp(280.0, 560.0);
    return SettingsPage(
      title: 'Sauvegardes',
      intro: 'Une copie complète des données est faite automatiquement chaque jour (les 14 dernières '
          'sont gardées). Faites-en une avant une opération importante.',
      actions: [
        PageAction(label: 'Ouvrir le dossier', icon: Icons.folder_open_outlined, onPressed: _openFolder),
        PageAction(label: 'Restaurer…', icon: Icons.restore_rounded, onPressed: _loading ? null : _pickAndRestore),
        PageAction(
          label: _backingUp ? 'Sauvegarde…' : 'Sauvegarder maintenant',
          icon: Icons.backup_outlined,
          primary: true,
          onPressed: _backingUp ? null : _backupNow,
        ),
      ],
      children: [
        ..._banners(),
        SizedBox(
          height: height,
          child: DataListView<BackupInfo>(
            items: items,
            loading: _loading,
            error: _error,
            onRetry: _load,
            rowId: (b) => b.name,
            initialSortColumn: 0,
            initialAscending: false,
            columns: [
              ColumnSpec(
                label: 'Date',
                flex: 2,
                hideable: false,
                sortKey: (b) => b.modTime,
                exportValue: (b) => fmtDateTime(b.modTime),
                cell: (_, b) => Text(fmtDateTime(b.modTime), style: T.body.copyWith(fontWeight: FontWeight.w600)),
              ),
              ColumnSpec(
                label: 'Type',
                flex: 2,
                exportValue: (b) => backupKindLabel(b.kind),
                cell: (_, b) => Text(backupKindLabel(b.kind), style: T.bodyMuted),
              ),
              ColumnSpec(
                label: 'Taille',
                width: 110,
                numeric: true,
                sortKey: (b) => b.sizeBytes,
                exportValue: (b) => b.sizeBytes,
                cell: (_, b) => Text(_size(b.sizeBytes), style: T.monoBody),
              ),
              ColumnSpec(
                label: 'Fichier',
                flex: 3,
                visibleByDefault: false,
                exportValue: (b) => b.name,
                cell: (_, b) => Text(b.name, style: T.monoSmall, overflow: TextOverflow.ellipsis),
              ),
            ],
            rowMenu: (b) => [
              RowAction('Restaurer cette sauvegarde…', Icons.restore_rounded, _restore,
                  enabled: _status?.pendingRestore != b.name),
            ],
            empty: EmptyState(
              icon: Icons.backup_outlined,
              text: 'Aucune sauvegarde pour le moment.',
              actions: [('Sauvegarder maintenant', _backupNow)],
            ),
          ),
        ),
        const SizedBox(height: 16),
        PageSection(
          title: 'Où sont les sauvegardes ?',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sur le PC serveur, dans ce dossier :', style: T.bodyMuted),
            const SizedBox(height: 6),
            SelectableText(_status?.dir ?? '…', style: T.monoBody),
            const SizedBox(height: 10),
            Text('Conseil : copiez régulièrement ce dossier sur une clé USB ou un disque externe, '
                'pour garder vos données même si le PC tombe en panne.', style: T.bodyMuted),
          ]),
        ),
      ],
    );
  }
}

class _RestartSteps extends StatelessWidget {
  const _RestartSteps();

  @override
  Widget build(BuildContext context) {
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: T.mintTint, shape: BoxShape.circle),
              child: Text(n, style: T.body.copyWith(fontWeight: FontWeight.w700, color: T.mintDark)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: T.body)),
          ]),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('La restauration est enregistrée. Elle se fera au prochain démarrage du serveur :',
          style: T.bodyMuted),
      const SizedBox(height: 14),
      step('1', 'Terminez les ventes en cours et fermez Elixir Gestion sur toutes les caisses.'),
      step('2', 'Redémarrez le PC serveur (celui où Elixir Serveur est installé) : Démarrer → '
          'Marche/Arrêt → Redémarrer.'),
      step('3', 'Ou, sans redémarrer le PC : ouvrez « Services » de Windows, cherchez « Elixir Gestion — '
          'Serveur » (ElixirServer) et cliquez sur « Redémarrer ».'),
      step('4', 'Rouvrez Elixir Gestion : Paramètres → Sauvegardes confirme que la restauration est faite.'),
    ]);
  }
}
