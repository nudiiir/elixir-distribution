part of '../analytics_screen.dart';

// =================================================================== save the view

class _SaveChoice {
  _SaveChoice({required this.name, required this.shared, required this.target, required this.asCopy});
  final String name;
  final bool shared;
  final String? target; // dashboard to add the view to (null = do not add)
  final bool asCopy; // editing: save as a new view
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({required this.initialName, required this.initialShared, required this.editing, required this.boards, required this.onBoards, required this.initialTarget});
  final String initialName;
  final bool initialShared, editing;
  final List<Dashboard> boards;
  final Set<String> onBoards; // dashboards already showing the view
  final String? initialTarget;
  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late bool _shared = widget.initialShared;
  late String? _target = widget.initialTarget;
  bool _asCopy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() {
    final n = _name.text.trim();
    if (n.isEmpty) {
      setState(() => _err = 'Donnez un nom à la vue');
      return;
    }
    if (n.length > 120) {
      setState(() => _err = '120 caractères au plus');
      return;
    }
    Navigator.pop(context, _SaveChoice(name: n, shared: _shared, target: _target, asCopy: _asCopy));
  }

  @override
  Widget build(BuildContext context) {
    final already = [
      for (final d in widget.boards)
        if (widget.onBoards.contains(d.id)) d.name,
    ];
    return AlertDialog(
      title: Text(widget.editing ? 'Enregistrer les modifications' : 'Enregistrer la vue', style: T.h2),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Nom de la vue', style: T.label),
                Text(' *', style: T.label.copyWith(color: T.dangerDark)),
              ],
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _name,
              autofocus: true,
              style: T.body,
              onSubmitted: (_) => _ok(),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
            FieldError(_err),
            const SizedBox(height: 14),
            const Text('Ajouter au tableau de bord', style: T.label),
            const SizedBox(height: 4),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(color: T.border3),
                borderRadius: BorderRadius.circular(T.rInner),
              ),
              child: DropdownButton<String?>(
                value: _target,
                isExpanded: true,
                underline: const SizedBox(),
                style: T.body,
                items: [
                  for (final d in widget.boards)
                    DropdownMenuItem<String?>(
                      value: d.id,
                      child: Text(widget.onBoards.contains(d.id) && !_asCopy ? '${d.name} (déjà dessus)' : d.name, style: T.body),
                    ),
                  const DropdownMenuItem<String?>(value: null, child: Text('Ne pas ajouter (seulement dans « Mes vues »)', style: T.body)),
                ],
                onChanged: (v) => setState(() => _target = v),
              ),
            ),
            if (widget.boards.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text("Aucun tableau de bord pour l'instant : la vue ira dans « Mes vues ».", style: T.small),
              ),
            if (already.isNotEmpty && !_asCopy)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Cette vue est déjà sur : ${already.join(', ')}.', style: T.small),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Switch(value: _shared, activeThumbColor: T.mint, onChanged: (v) => setState(() => _shared = v)),
                const SizedBox(width: 6),
                const Expanded(child: Text('Visible par tout le magasin', style: T.body)),
              ],
            ),
            if (widget.editing)
              Row(
                children: [
                  Checkbox(value: _asCopy, activeColor: T.mint, onChanged: (v) => setState(() => _asCopy = v == true)),
                  const Expanded(child: Text("Enregistrer comme une nouvelle vue (garder l'originale)", style: T.body)),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: 'Enregistrer', onPressed: _ok),
      ],
    );
  }
}

// =================================================================== Mes vues

class _MyViewsPanel extends StatefulWidget {
  const _MyViewsPanel({
    required this.views,
    required this.boards,
    required this.loading,
    required this.error,
    required this.currentId,
    required this.canEdit,
    required this.onRetry,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onAddTo,
    required this.onShowDashboard,
    required this.onCreate,
  });
  final List<SavedReport>? views;
  final List<Dashboard> boards;
  final bool loading;
  final String? error;
  final String? currentId;
  final bool Function(SavedReport) canEdit;
  final VoidCallback onRetry, onCreate;
  final ValueChanged<SavedReport> onOpen, onRename, onDelete;
  final void Function(SavedReport, Dashboard) onAddTo;
  final ValueChanged<Dashboard> onShowDashboard;

  @override
  State<_MyViewsPanel> createState() => _MyViewsPanelState();
}

class _MyViewsPanelState extends State<_MyViewsPanel> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final views = widget.views;
    Widget body;
    if (views == null && widget.loading) {
      body = const Center(child: CircularProgressIndicator(color: T.mint));
    } else if (widget.error != null && views == null) {
      body = EmptyState(icon: Icons.cloud_off_rounded, text: 'Impossible de charger vos vues.\n${widget.error}', actions: [('Réessayer', widget.onRetry)]);
    } else if (views == null || views.isEmpty) {
      body = EmptyState(
        icon: Icons.bookmarks_outlined,
        text: "Vous n'avez encore enregistré aucune vue.\nConstruisez une vue à gauche (ou posez une question en haut), puis « Enregistrer la vue ».",
        actions: [('Créer une vue', widget.onCreate)],
      );
    } else {
      final shown = [
        for (final v in views)
          if (_q.isEmpty || v.name.toLowerCase().contains(_q.toLowerCase())) v,
      ];
      body = shown.isEmpty
          ? Center(child: Text('Aucune vue ne correspond à « $_q »', style: T.bodyMuted))
          : ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: T.border2),
              itemBuilder: (_, i) => _row(shown[i]),
            );
    }
    return Card14(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Mes vues', style: T.h2)),
              if (widget.loading && views != null) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: T.mint)),
            ],
          ),
          const SizedBox(height: 2),
          Text('Les vues enregistrées : ouvrez-les, renommez-les, ajoutez-les à un tableau de bord.', style: T.bodyMuted),
          const SizedBox(height: 10),
          if (views != null && views.isNotEmpty) ...[
            SizedBox(
              height: 42,
              child: TextField(
                style: T.body,
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: const InputDecoration(hintText: 'Rechercher une vue…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _row(SavedReport r) {
    final on = [
      for (final d in widget.boards)
        if (d.layout.any((t) => t.reportId == r.id)) d,
    ];
    final current = r.id == widget.currentId;
    final can = widget.canEdit(r);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(kChartIcons[r.chartType] ?? Icons.auto_graph_rounded, size: 22, color: T.mintDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            r.name,
                            style: T.body.copyWith(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (current) ...[const SizedBox(width: 8), const MintChip('Ouverte', color: T.mintTint2, fg: T.mintDark)],
                        if (!r.isShared) ...[const SizedBox(width: 8), const MintChip('Privée', color: T.border, fg: T.ink)],
                        if (r.missing.isNotEmpty) ...[const SizedBox(width: 8), const MintChip('À corriger', color: T.warnTint, fg: T.warnDark)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        Text('Affichage : ${_chartWord(r.chartType)} · ', style: T.small),
                        if (on.isEmpty)
                          Text('sur aucun tableau de bord', style: T.small)
                        else ...[
                          Text('sur ', style: T.small),
                          for (final d in on)
                            InkWell(
                              onTap: () => widget.onShowDashboard(d),
                              child: Text(
                                d.name,
                                style: T.small.copyWith(color: T.mintDark, decoration: TextDecoration.underline),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: T.ink,
                    side: const BorderSide(color: T.border3),
                    minimumSize: const Size(0, 38),
                  ),
                  onPressed: current ? null : () => widget.onOpen(r),
                  child: Text(current ? 'Ouverte' : 'Ouvrir'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Ajouter à un tableau de bord',
                  enabled: widget.boards.isNotEmpty,
                  onSelected: (id) {
                    final d = widget.boards.where((x) => x.id == id).firstOrNull;
                    if (d != null) widget.onAddTo(r, d);
                  },
                  itemBuilder: (_) => [
                    for (final d in widget.boards)
                      PopupMenuItem(
                        value: d.id,
                        enabled: !on.contains(d),
                        child: Text(on.contains(d) ? '${d.name} (déjà dessus)' : d.name, style: T.body),
                      ),
                  ],
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: T.border3),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Ajouter au tableau de bord',
                          style: T.body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, color: widget.boards.isEmpty ? T.ghost : T.ink),
                        ),
                        const Icon(Icons.arrow_drop_down_rounded, size: 20, color: T.muted),
                      ],
                    ),
                  ),
                ),
                if (can) TextButton(onPressed: () => widget.onRename(r), child: const Text('Renommer')),
                if (can)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                    onPressed: () => widget.onDelete(r),
                    child: const Text('Supprimer'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =================================================================== style

class _StylePanel extends StatelessWidget {
  const _StylePanel({required this.result, required this.chartType, required this.encoding, required this.onChanged, required this.onClose});
  final AResult result;
  final String chartType;
  final ChartEncoding encoding;
  final ValueChanged<ChartEncoding> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final e = encoding;
    final dims = r.dimensions;
    final meas = r.measures;
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.label.copyWith(color: T.muted)),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
    Widget sw(bool v, String label, ValueChanged<bool> on) => Row(
      children: [
        Switch(value: v, activeThumbColor: T.mint, onChanged: on),
        const SizedBox(width: 6),
        Expanded(child: Text(label, style: T.body)),
      ],
    );
    final isTable = chartType == 'table' || chartType == 'pivot';
    return Card14(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      child: ListView(
        padding: const EdgeInsets.only(right: 6),
        children: [
          Row(
            children: [
              const Expanded(child: Text('Couleurs et style', style: T.h2)),
              IconButton(
                tooltip: 'Fermer',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18, color: T.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (chartType == 'line' || chartType == 'bar' || chartType == 'donut') ...[
            row(chartType == 'donut' ? 'Parts' : 'En bas (axe horizontal)', _dd(dims, e.x, (v) => onChanged(e..x = v))),
            if (chartType != 'donut' && dims.length > 1) row('Une couleur par', _dd(dims.where((d) => d.key != e.x).toList(), e.series, (v) => onChanged(e..series = v), allowNone: true)),
            if (chartType != 'donut')
              row(
                'Valeurs affichées',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in meas)
                      FilterChip(
                        label: Text(m.label, style: T.body.copyWith(fontSize: 13)),
                        selected: e.y.contains(m.key),
                        onSelected: (s) => onChanged(
                          e
                            ..y = s
                                ? [...e.y, m.key]
                                : [
                                    for (final k in e.y)
                                      if (k != m.key) k,
                                  ],
                        ),
                      ),
                  ],
                ),
              ),
            if (chartType == 'bar' && (e.series != null || e.y.length > 1)) row('Barres', sw(e.stacked, e.stacked ? 'Empilées' : 'Côte à côte', (v) => onChanged(e..stacked = v))),
            if (chartType != 'donut' && e.y.length > 1)
              row(
                'Valeur sur un 2e axe (à droite)',
                _dd(
                  [
                    for (final m in meas)
                      if (e.y.contains(m.key)) m,
                  ],
                  e.secondary,
                  (v) => onChanged(e..secondary = v),
                  allowNone: true,
                ),
              ),
            if (chartType == 'bar') row('Chiffres sur les barres', sw(e.showValues, e.showValues ? 'Affichés' : 'Masqués', (v) => onChanged(e..showValues = v))),
            if (r.prevFrom != null) row('Période de comparaison', sw(e.showPrevious, e.showPrevious ? 'Affichée (pointillés)' : 'Masquée', (v) => onChanged(e..showPrevious = v))),
          ],
          if (chartType == 'pivot' && dims.length > 1) ...[
            row('Colonnes', _dd(dims, e.series ?? dims.last.key, (v) => onChanged(e..series = v))),
            row(
              'Valeurs',
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in meas)
                    FilterChip(
                      label: Text(m.label, style: T.body.copyWith(fontSize: 13)),
                      selected: e.y.contains(m.key),
                      onSelected: (s) => onChanged(
                        e
                          ..y = s
                              ? [...e.y, m.key]
                              : [
                                  for (final k in e.y)
                                    if (k != m.key) k,
                                ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (isTable) ...[if (chartType == 'pivot') const Divider(height: 24, color: T.border2), _CondEditor(result: r, encoding: e, onChanged: onChanged)],
        ],
      ),
    );
  }

  Widget _dd(List<AColumn> cols, String? value, ValueChanged<String?> onChanged, {bool allowNone = false}) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: T.border3),
        borderRadius: BorderRadius.circular(T.rInner),
      ),
      child: DropdownButton<String?>(
        value: cols.any((c) => c.key == value) ? value : (allowNone ? null : (cols.isEmpty ? null : cols.first.key)),
        isExpanded: true,
        hint: const Text('Aucune', style: T.body),
        underline: const SizedBox(),
        style: T.body,
        items: [
          if (allowNone) const DropdownMenuItem<String?>(value: null, child: Text('Aucune', style: T.body)),
          for (final c in cols)
            DropdownMenuItem<String?>(
              value: c.key,
              child: Text(c.label, style: T.body, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

// ------------------------------------------------------------------- conditional colours

/// Editor for a column's conditional colours: scale, bars,
/// top / bottom N, threshold rules. Everything is saved in
/// the view's encoding (`cond`).
class _CondEditor extends StatefulWidget {
  const _CondEditor({required this.result, required this.encoding, required this.onChanged});
  final AResult result;
  final ChartEncoding encoding;
  final ValueChanged<ChartEncoding> onChanged;
  @override
  State<_CondEditor> createState() => _CondEditorState();
}

class _CondEditorState extends State<_CondEditor> {
  String? _col;
  int _gen = 0; // refreshes the rule input fields after an add/remove

  List<AColumn> get _cols => [
    for (final c in widget.result.allMeasures)
      if (c.format != 'bool') c,
  ];

  @override
  Widget build(BuildContext context) {
    final cols = _cols;
    if (cols.isEmpty) return const SizedBox();
    final key = cols.any((c) => c.key == _col) ? _col! : (cols.firstWhere((c) => widget.encoding.cond[c.key]?.isEmpty == false, orElse: () => cols.first)).key;
    final col = cols.firstWhere((c) => c.key == key);
    final e = widget.encoding;
    final f = e.cond[key] ?? CondFormat();
    final unit = unitWord(col.format);
    void commit() {
      e.cond[key] = f;
      widget.onChanged(e);
    }

    void set(void Function() change) {
      change();
      commit();
    }

    Widget choice(String label, bool selected, VoidCallback onTap) => ChoiceChip(
      label: Text(label, style: T.body.copyWith(fontSize: 13, color: selected ? Colors.white : T.ink)),
      selected: selected,
      selectedColor: T.ink,
      backgroundColor: T.bg,
      showCheckmark: false,
      side: const BorderSide(color: T.border3),
      onSelected: (_) => onTap(),
    );
    Widget section(String title, Widget child, {String? help}) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: T.body.copyWith(fontWeight: FontWeight.w700)),
          if (help != null) Text(help, style: T.small),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Couleurs selon les valeurs', style: T.h2),
        const SizedBox(height: 4),
        Text('Faites ressortir les bons et les mauvais chiffres. Choisissez une colonne :', style: T.small),
        const SizedBox(height: 8),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: T.border3),
            borderRadius: BorderRadius.circular(T.rInner),
          ),
          child: DropdownButton<String>(
            value: key,
            isExpanded: true,
            underline: const SizedBox(),
            style: T.body,
            items: [
              for (final c in cols)
                DropdownMenuItem(
                  value: c.key,
                  child: Text('${c.label}${e.cond[c.key]?.isEmpty == false ? '  ●' : ''}', style: T.body, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() {
              _col = v;
              _gen++;
            }),
          ),
        ),
        const SizedBox(height: 12),
        section(
          'Dégradé de couleur',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              choice('Aucun', f.scale == 'none', () => set(() => f.scale = 'none')),
              choice('Plus haut = mieux', f.scale == 'up', () => set(() => f.scale = 'up')),
              choice('Plus bas = mieux', f.scale == 'down', () => set(() => f.scale = 'down')),
              choice('Neutre (bleu)', f.scale == 'neutral', () => set(() => f.scale = 'neutral')),
            ],
          ),
          help: 'Du rouge (mauvais) au vert (bon), selon la valeur.',
        ),
        section(
          'Barres dans les cellules',
          Row(
            children: [
              Switch(value: f.bars, activeThumbColor: T.mint, onChanged: (v) => set(() => f.bars = v)),
              const SizedBox(width: 6),
              Expanded(child: Text(f.bars ? 'Affichées' : 'Masquées', style: T.body)),
            ],
          ),
        ),
        section(
          'Mettre en évidence',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  choice('Rien', f.top == 'none', () => set(() => f.top = 'none')),
                  choice('Les premiers', f.top == 'top', () => set(() => f.top = 'top')),
                  choice('Les derniers', f.top == 'bottom', () => set(() => f.top = 'bottom')),
                ],
              ),
              if (f.top != 'none') ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Les', style: T.body),
                    SizedBox(
                      width: 70,
                      child: _NumField(value: f.topN, onChanged: (n) => set(() => f.topN = n.clamp(1, 500))),
                    ),
                    Text(f.top == 'top' ? 'plus hautes valeurs' : 'plus basses valeurs', style: T.body),
                  ],
                ),
              ],
            ],
          ),
        ),
        section(
          'Règles',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < f.rules.length; i++)
                _RuleRow(
                  key: ValueKey('$key-$_gen-$i'),
                  rule: f.rules[i],
                  unit: unit,
                  onChanged: commit,
                  onDelete: () {
                    f.rules.removeAt(i);
                    _gen++;
                    commit();
                  },
                ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: T.mintDark),
                    onPressed: () {
                      f.rules.add(CondRule(op: 'gt', a: 0, color: 'green'));
                      _gen++;
                      commit();
                    },
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('Ajouter une règle'),
                  ),
                  if (!f.rules.any((r) => r.op == 'lt' && r.a == 0))
                    TextButton(
                      onPressed: () {
                        f.rules.insert(0, CondRule(op: 'lt', a: 0, color: 'red'));
                        _gen++;
                        commit();
                      },
                      child: const Text('Négatif en rouge'),
                    ),
                ],
              ),
            ],
          ),
          help: 'Exemples : « inférieur à 0 » en rouge, « supérieur à 100 000 » en vert, « entre 0 et 1 000 » en orange. La première règle qui correspond gagne.',
        ),
        if (!f.isEmpty)
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: T.dangerDark),
            onPressed: () {
              e.cond.remove(key);
              _gen++;
              widget.onChanged(e);
            },
            icon: const Icon(Icons.format_color_reset_outlined, size: 18),
            label: const Text('Effacer les couleurs de cette colonne'),
          ),
      ],
    );
  }
}

class _RuleRow extends StatefulWidget {
  const _RuleRow({super.key, required this.rule, required this.unit, required this.onChanged, required this.onDelete});
  final CondRule rule;
  final String unit;
  final VoidCallback onChanged, onDelete;
  @override
  State<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends State<_RuleRow> {
  late final _a = TextEditingController(text: _numText(widget.rule.a));
  late final _b = TextEditingController(text: widget.rule.b == null ? '' : _numText(widget.rule.b!));

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  Widget _box(Widget child, {double? width}) => Container(
    height: 40,
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      border: Border.all(color: T.border3),
      borderRadius: BorderRadius.circular(T.rInner),
      color: T.surface,
    ),
    child: child,
  );

  Widget _num(TextEditingController c, void Function(double) set) => SizedBox(
    width: 96,
    height: 40,
    child: TextField(
      controller: c,
      style: T.monoBody,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
      onChanged: (v) {
        final n = _parseNum(v);
        if (n != null) {
          set(n);
          widget.onChanged();
        }
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: T.bg,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Si la valeur est', style: T.small),
          const SizedBox(height: 4),
          _box(
            DropdownButton<String>(
              value: kCondOps.containsKey(r.op) ? r.op : 'lt',
              isExpanded: true,
              underline: const SizedBox(),
              style: T.body,
              items: [
                for (final e in kCondOps.entries)
                  DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, style: T.body),
                  ),
              ],
              onChanged: (v) {
                setState(() {
                  r.op = v ?? 'lt';
                  if (r.op == 'between' && r.b == null) {
                    r.b = r.a;
                    _b.text = _numText(r.a);
                  }
                });
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _num(_a, (n) => r.a = n),
              if (r.op == 'between') ...[const Text('et', style: T.body), _num(_b, (n) => r.b = n)],
              if (widget.unit.isNotEmpty && widget.unit != 'quantité') Text(widget.unit, style: T.body),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Text('alors en', style: T.body),
              const SizedBox(width: 6),
              Expanded(
                child: _box(
                  DropdownButton<String>(
                    value: kCondColors.containsKey(r.color) ? r.color : 'red',
                    isExpanded: true,
                    underline: const SizedBox(),
                    style: T.body,
                    items: [
                      for (final e in kCondColors.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Row(
                            children: [
                              Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: e.value.$2,
                                  border: Border.all(color: e.value.$3),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                e.value.$1,
                                style: T.body.copyWith(color: e.value.$3, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => r.color = v ?? 'red');
                      widget.onChanged();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: T.dangerDark),
                onPressed: widget.onDelete,
                child: const Text('Retirer'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
