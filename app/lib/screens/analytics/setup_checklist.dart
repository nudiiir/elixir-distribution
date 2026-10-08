part of '../analytics_screen.dart';

// ================= « Bien démarrer » (first-run checklist) =================

/// First-run checklist shown at the top of the dashboard until every step is
/// done or the user hides it (remembered per user in [UiPrefs]
/// 'dashboard'/'setup_hidden'). Each step says whether it is done and has the
/// button that does it, through [onOpenModule] ('settings', 'products',
/// 'partners', 'purchases', 'pos').
class SetupChecklist extends StatefulWidget {
  const SetupChecklist({super.key, required this.api, this.onOpenModule});
  final ApiClient api;
  final void Function(String key)? onOpenModule;

  @override
  State<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends State<SetupChecklist> {
  static const _prefScreen = 'dashboard';
  static const _prefKey = 'setup_hidden';

  bool _hidden = UiPrefs.instance.get<bool>(_prefScreen, _prefKey) == true;
  bool _loaded = false;
  bool _checking = false;
  bool _company = false, _products = false, _supplier = false, _receipt = false, _caisse = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (!_hidden) {
      _check();
      // The dashboard stays alive while the user works in other modules:
      // re-check from time to time so the ticks follow what was done.
      _poll = Timer.periodic(const Duration(seconds: 90), (_) {
        if (!_hidden && !_allDone) _check();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool get _allDone => _company && _products && _supplier && _receipt && _caisse;
  int get _doneCount => [_company, _products, _supplier, _receipt, _caisse].where((b) => b).length;

  Future<bool> _safe(Future<bool> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return false;
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    final api = widget.api;
    final r = await Future.wait([
      _safe(() async => (await api.settings())['company_name']?.trim().isNotEmpty ?? false),
      _safe(() async => (await api.products(limit: 1)).isNotEmpty),
      _safe(() async => (await api.partners(kind: 'supplier', limit: 1)).isNotEmpty),
      _safe(() async => (await api.documents(type: 'PURCHASE_RECEIPT', status: 'posted', limit: 1)).isNotEmpty),
      _safe(() async => await api.caisseSessionCount() > 0),
    ]);
    if (!mounted) return;
    setState(() {
      _company = r[0];
      _products = r[1];
      _supplier = r[2];
      _receipt = r[3];
      _caisse = r[4];
      _loaded = true;
      _checking = false;
    });
    if (_allDone) _poll?.cancel();
  }

  void _hide() {
    UiPrefs.instance.set(_prefScreen, _prefKey, true);
    _poll?.cancel();
    setState(() => _hidden = true);
  }

  void _open(String key) => widget.onOpenModule?.call(key);

  @override
  Widget build(BuildContext context) {
    if (_hidden || !_loaded || _allDone) return const SizedBox.shrink();
    final can = widget.onOpenModule != null;
    final steps = <_SetupStep>[
      _SetupStep(
        title: "Informations de l'entreprise",
        help: 'Nom, adresse, NIF, RC : ils sont imprimés sur vos factures et tickets.',
        done: _company,
        actions: [('Ouvrir les paramètres', can ? () => _open('settings') : null)],
      ),
      _SetupStep(
        title: 'Ajouter vos produits',
        help: 'Importez votre liste (Excel, CSV) ou créez vos produits un par un.',
        done: _products,
        actions: [
          ('Importer un fichier', can ? () => _open('products') : null),
          ('Nouveau produit', can ? () => _open('products') : null),
        ],
      ),
      _SetupStep(
        title: 'Ajouter un fournisseur',
        help: 'Celui qui vous livre la marchandise.',
        done: _supplier,
        actions: [('Nouveau fournisseur', can ? () => _open('partners') : null)],
      ),
      _SetupStep(
        title: 'Premier bon de réception',
        help: 'Entrez la marchandise reçue : le stock et le coût moyen se mettent à jour.',
        done: _receipt,
        actions: [('Nouveau bon de réception', can ? () => _open('purchases') : null)],
      ),
      _SetupStep(
        title: 'Ouvrir la caisse',
        help: 'Saisissez le fond de caisse et faites votre première vente.',
        done: _caisse,
        actions: [('Aller à la caisse', can ? () => _open('pos') : null)],
      ),
    ];
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 18),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.mintDeep.withValues(alpha: 0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_outlined, size: 20, color: T.mintDark),
          const SizedBox(width: 8),
          const Text('Bien démarrer', style: T.h2),
          const SizedBox(width: 12),
          Text('$_doneCount sur ${steps.length} étapes faites', style: T.bodyMuted),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: _doneCount / steps.length,
                minHeight: 6,
                color: T.mint,
                backgroundColor: T.border,
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _checking ? null : _check,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Actualiser'),
          ),
          TextButton.icon(
            onPressed: _hide,
            style: TextButton.styleFrom(foregroundColor: T.muted),
            icon: const Icon(Icons.visibility_off_outlined, size: 18),
            label: const Text('Masquer'),
          ),
        ]),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          const gap = 12.0;
          final perRow = c.maxWidth >= 1250 ? 5 : (c.maxWidth >= 760 ? 3 : (c.maxWidth >= 500 ? 2 : 1));
          final w = (c.maxWidth - gap * (perRow - 1) - 8) / perRow;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (var i = 0; i < steps.length; i++) SizedBox(width: w, child: _stepCard(i + 1, steps[i])),
          ]);
        }),
      ]),
    );
  }

  Widget _stepCard(int n, _SetupStep s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: s.done ? T.mintTint : T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: s.done ? T.mintDeep.withValues(alpha: 0.5) : T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: s.done ? T.mint : T.surface,
              shape: BoxShape.circle,
              border: Border.all(color: s.done ? T.mint : T.border3),
            ),
            child: s.done
                ? const Icon(Icons.check_rounded, size: 17, color: T.ink)
                : Text('$n', style: T.monoSmall.copyWith(color: T.ink, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(s.title, style: T.body.copyWith(fontWeight: FontWeight.w700, color: s.done ? T.mintDark : T.ink)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(s.done ? 'Fait.' : s.help, style: T.small),
        if (!s.done) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (var i = 0; i < s.actions.length; i++)
              i == s.actions.length - 1
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: T.mint,
                        foregroundColor: T.ink,
                        minimumSize: const Size(0, 38),
                        textStyle: const TextStyle(fontFamily: T.sans, fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                      onPressed: s.actions[i].$2,
                      child: Text(s.actions[i].$1),
                    )
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: T.ink,
                        side: const BorderSide(color: T.border3),
                        minimumSize: const Size(0, 38),
                        textStyle: const TextStyle(fontFamily: T.sans, fontSize: 13.5, fontWeight: FontWeight.w700),
                      ),
                      onPressed: s.actions[i].$2,
                      child: Text(s.actions[i].$1),
                    ),
          ]),
        ],
      ]),
    );
  }
}

class _SetupStep {
  const _SetupStep({required this.title, required this.help, required this.done, required this.actions});
  final String title;
  final String help;
  final bool done;
  final List<(String, VoidCallback?)> actions;
}
