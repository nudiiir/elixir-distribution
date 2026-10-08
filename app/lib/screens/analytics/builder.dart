part of '../analytics_screen.dart';

// =================================================================== constructeur guidé

/// Opérateurs de filtre en mots simples.
const _kOpWords = <String, String>{
  'eq': 'est',
  'ne': "n'est pas",
  'gt': 'plus grand que',
  'gte': 'au moins',
  'lt': 'plus petit que',
  'lte': 'au plus',
  'between': 'entre',
  'in': 'fait partie de',
  'not_in': 'sauf',
  'contains': 'contient',
  'starts_with': 'commence par',
  'ends_with': 'finit par',
  'is_null': 'est vide',
  'is_not_null': 'est renseigné',
};

/// Facteur entre la valeur saisie (DA, quantité) et la valeur stockée.
num _unitFactor(AField f) => switch (f.unit) {
  'centimes' => 100,
  'milli' => 1000,
  _ => f.format == 'currency' ? 100 : (f.format == 'quantity' ? 1000 : 1),
};

String _unitHint(AField f) => switch (_unitFactor(f)) {
  100 => 'en DA',
  1000 => 'en quantité',
  _ => '',
};

String _numText(num v) {
  final d = v.toDouble();
  if (d == d.roundToDouble()) return d.round().toString();
  return d.toString().replaceAll('.', ',');
}

double? _parseNum(String s) => double.tryParse(s.trim().replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.'));

/// Format d'une mesure de la spec (pour convertir les seuils « Garder seulement… »).
String _measureFormat(ASource s, Map<String, dynamic> m) {
  if (m['name'] != null) return s.namedMeasure('${m['name']}')?.format ?? 'integer';
  final agg = '${m['agg'] ?? 'sum'}';
  if (agg == 'count' || agg == 'count_distinct') return 'integer';
  return s.field('${m['field']}')?.format ?? 'integer';
}

/// Valeur saisie (DA, quantité, %) → valeur du moteur (centimes, millièmes, ratio).
double _toRaw(double v, String format) => switch (format) {
  'currency' => v * 100,
  'quantity' => v * 1000,
  'percent' => v / 100,
  _ => v,
};

class _AskPanel extends StatefulWidget {
  const _AskPanel({
    required this.schema,
    required this.source,
    required this.dims,
    required this.measures,
    required this.filters,
    required this.having,
    required this.range,
    required this.compare,
    required this.params,
    required this.limit,
    required this.combo,
    required this.suggestions,
    required this.onSuggestion,
    required this.onSource,
    required this.onCompare,
    required this.onRange,
    required this.onLimit,
    required this.onChanged,
    required this.onCollapse,
    required this.autoBucket,
  });
  final ASchema schema;
  final ASource source;
  final List<String> dims;
  final List<Map<String, dynamic>> measures, filters, having;
  final Map<String, dynamic> range;
  final String? compare;
  final bool combo;
  final Map<String, int> params;
  final int limit;
  final List<GalleryItem> suggestions;
  final ValueChanged<GalleryItem> onSuggestion;
  final ValueChanged<ASource> onSource;
  final ValueChanged<String?> onCompare;
  final ValueChanged<Map<String, dynamic>> onRange;
  final ValueChanged<int> onLimit;
  final void Function(VoidCallback) onChanged;
  final VoidCallback onCollapse;
  final String Function() autoBucket;

  @override
  State<_AskPanel> createState() => _AskPanelState();
}

class _AskPanelState extends State<_AskPanel> {
  bool _moreSources = false;
  bool _advanced = false;

  ASource get source => widget.source;

  String _dimLabel(String d) {
    final parts = d.split(':');
    final f = source.field(parts[0]);
    final base = (f?.labelFr ?? parts[0]).replaceAll(' (nom)', '');
    return parts.length > 1 ? '$base · par ${(kBucketLabels[parts[1]] ?? parts[1]).toLowerCase()}' : base;
  }

  String _measureLabel(Map<String, dynamic> m) {
    if (m['name'] != null) return source.namedMeasure('${m['name']}')?.labelFr ?? '${m['name']}';
    final f = source.field('${m['field']}');
    return '${kAggLabels[m['agg'] ?? 'sum'] ?? m['agg']} · ${f?.labelFr ?? m['field']}';
  }

  String _measureLabelFor(String ref) {
    final n = source.namedMeasure(ref);
    if (n != null) return n.labelFr;
    final m = RegExp(r'^m(\d+)$').firstMatch(ref);
    if (m != null) {
      final i = int.parse(m.group(1)!);
      if (i < widget.measures.length) return _measureLabel(widget.measures[i]);
    }
    return ref;
  }

  String _formatFor(String ref) {
    final n = source.namedMeasure(ref);
    if (n != null) return n.format;
    final m = RegExp(r'^m(\d+)$').firstMatch(ref);
    if (m != null) {
      final i = int.parse(m.group(1)!);
      if (i < widget.measures.length) return _measureFormat(source, widget.measures[i]);
    }
    return 'integer';
  }

  String _filterLabel(Map<String, dynamic> f) {
    final fld = source.field('${f['field']}');
    final op = '${f['op']}';
    final v = f['value'];
    final factor = fld == null ? 1 : _unitFactor(fld);
    String one(dynamic e) {
      if (e is num && factor != 1) return '${_numText(e / factor)}${factor == 100 ? ' DA' : ''}';
      if (e is String && fld != null && fld.isDate) return frDate(e);
      return '$e';
    }

    final vs = v is List
        ? (op == 'between' && v.length == 2 ? '${one(v[0])} et ${one(v[1])}' : v.map(one).join(', '))
        : v == true
        ? 'oui'
        : v == false
        ? 'non'
        : v == null
        ? ''
        : one(v);
    return '${(fld?.labelFr ?? f['field']).toString().replaceAll(' (nom)', '')} ${_kOpWords[op] ?? op} $vs'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final primary = [
      for (final s in widget.schema.sources)
        if (_kPrimarySources.contains(s.key)) s,
    ];
    final others = [
      for (final s in widget.schema.sources)
        if (!_kPrimarySources.contains(s.key)) s,
    ];
    final showOthers = _moreSources || others.any((s) => s.key == source.key);
    final hasPeriod = source.dateField.isNotEmpty || source.key == 'product_performance';
    return Card14(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: ListView(
        padding: const EdgeInsets.only(right: 6),
        children: [
          Row(
            children: [
              const Expanded(child: Text('Construire ma vue', style: T.h2)),
              IconButton(
                tooltip: 'Réduire le panneau',
                onPressed: widget.onCollapse,
                icon: const Icon(Icons.chevron_left, size: 20, color: T.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Vous regardez :', style: T.label.copyWith(color: T.muted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in [...primary, if (showOthers) ...others])
                ChoiceChip(
                  label: Text(s.labelFr, style: T.body.copyWith(fontSize: 13.5, color: s.key == source.key && !widget.combo ? Colors.white : T.ink)),
                  selected: s.key == source.key && !widget.combo,
                  selectedColor: T.ink,
                  backgroundColor: T.bg,
                  showCheckmark: false,
                  side: const BorderSide(color: T.border3),
                  onSelected: (_) => widget.onSource(s),
                ),
              if (!showOthers)
                ActionChip(
                  label: Text('Autres sujets…', style: T.body.copyWith(fontSize: 13.5, color: T.mintDark)),
                  backgroundColor: Colors.transparent,
                  side: const BorderSide(color: T.border3),
                  onPressed: () => setState(() => _moreSources = true),
                ),
            ],
          ),
          if (widget.suggestions.isNotEmpty && !widget.combo) ...[
            const SizedBox(height: 12),
            Text('Idées de questions :', style: T.label.copyWith(color: T.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in widget.suggestions.take(5))
                  ActionChip(
                    avatar: const Icon(Icons.lightbulb_outline_rounded, size: 15, color: T.mintDark),
                    label: Text(g.title, style: T.body.copyWith(fontSize: 13)),
                    backgroundColor: T.mintTint,
                    side: BorderSide(color: T.mintDeep.withValues(alpha: 0.3)),
                    onPressed: () => widget.onSuggestion(g),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          if (widget.combo)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('Vue croisée (deux sujets) : choisissez un sujet ci-dessus pour repartir du constructeur.', style: T.bodyMuted),
            )
          else ...[
            _Step(
              n: 1,
              title: 'Que voulez-vous voir ?',
              help: "Un montant, une quantité, un nombre… (chiffre d'affaires, marge, quantité vendue)",
              chips: [
                for (var i = 0; i < widget.measures.length; i++) _chip(_measureLabel(widget.measures[i]), onDelete: () => widget.onChanged(() => widget.measures.removeAt(i)), color: T.mintTint2),
              ],
              addLabel: widget.measures.isEmpty ? 'Choisir une valeur' : 'Ajouter une valeur',
              onAdd: () => _pickMeasure(context),
            ),
            _Step(
              n: 2,
              title: 'Par quoi ?',
              help: widget.dims.isEmpty
                  ? 'Par jour, par produit, par catégorie… Sans regroupement : un seul chiffre.'
                  : 'Un 2e regroupement devient les colonnes. Cliquez une date pour changer jour / semaine / mois.',
              chips: [for (var i = 0; i < widget.dims.length; i++) _dimChip(context, i)],
              addLabel: 'Ajouter un regroupement',
              onAdd: widget.dims.length < 3 ? () => _pickDimension(context) : null,
            ),
          ],
          _StepHeader(n: widget.combo ? null : 3, title: 'Sur quelle période ?'),
          const SizedBox(height: 6),
          if (!hasPeriod && !widget.combo)
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 34),
              child: Text("Ce sujet montre l'état d'aujourd'hui (pas de période).", style: T.bodyMuted),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 34, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RangePicker(value: widget.range, onChanged: widget.onRange),
                  if (!widget.combo) ...[
                    const SizedBox(height: 8),
                    Text('Comparer à', style: T.label.copyWith(color: T.muted)),
                    const SizedBox(height: 4),
                    Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: T.surface,
                        border: Border.all(color: T.border3),
                        borderRadius: BorderRadius.circular(T.rInner),
                      ),
                      child: DropdownButton<String?>(
                        value: widget.compare,
                        isExpanded: true,
                        underline: const SizedBox(),
                        style: T.body,
                        items: const [
                          DropdownMenuItem<String?>(value: null, child: Text('Pas de comparaison', style: T.body)),
                          DropdownMenuItem<String?>(
                            value: 'previous_period',
                            child: Text('La période précédente', style: T.body),
                          ),
                          DropdownMenuItem<String?>(
                            value: 'previous_year',
                            child: Text("La même période l'an dernier", style: T.body),
                          ),
                        ],
                        onChanged: widget.onCompare,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          if (!widget.combo) ...[
            _Step(
              n: 4,
              title: 'Filtres',
              help: "Pour ne garder qu'un produit, un client, un dépôt… (facultatif)",
              chips: [
                for (var i = 0; i < widget.filters.length; i++)
                  _chip(_filterLabel(widget.filters[i]), onDelete: () => widget.onChanged(() => widget.filters.removeAt(i)), onTap: () => _editFilter(context, i)),
              ],
              addLabel: 'Ajouter un filtre',
              onAdd: () => _editFilter(context, null),
            ),
            InkWell(
              onTap: () => setState(() => _advanced = !_advanced),
              borderRadius: BorderRadius.circular(T.rChip),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 20, color: T.mintDark),
                    const SizedBox(width: 4),
                    Text(
                      'Options avancées',
                      style: T.body.copyWith(color: T.mintDark, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            if (_advanced) ...[
              const SizedBox(height: 6),
              if (widget.measures.isNotEmpty)
                _Step(
                  title: 'Garder seulement les lignes où…',
                  help: 'Exemple : chiffre d’affaires au moins 10 000 DA.',
                  chips: [for (var i = 0; i < widget.having.length; i++) _chip(_havingLabel(widget.having[i]), onDelete: () => widget.onChanged(() => widget.having.removeAt(i)))],
                  addLabel: 'Ajouter une condition',
                  onAdd: () => _editHaving(context),
                ),
              for (final p in source.params)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(p.labelFr, style: T.body)),
                      SizedBox(
                        width: 80,
                        child: _NumField(value: widget.params[p.key] ?? p.def, onChanged: (n) => widget.onChanged(() => widget.params[p.key] = n)),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(child: Text('Nombre de lignes au plus', style: T.body)),
                    SizedBox(
                      width: 80,
                      child: _NumField(value: widget.limit, onChanged: (n) => widget.onLimit(n.clamp(1, 5000))),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _havingLabel(Map<String, dynamic> h) {
    final ref = '${h['measure']}';
    final format = _formatFor(ref);
    final raw = (h['value'] as num?)?.toDouble() ?? 0;
    final shown = displayNum(raw, format);
    final unit = unitWord(format);
    return '${_measureLabelFor(ref)} ${_kOpWords[h['op']] ?? h['op']} ${_numText(shown)}${unit.isEmpty || unit == 'quantité' ? '' : ' $unit'}';
  }

  Widget _dimChip(BuildContext context, int i) {
    final d = widget.dims[i];
    final parts = d.split(':');
    final f = source.field(parts[0]);
    return _chip(
      i == 0 ? _dimLabel(d) : '${_dimLabel(d)} (en colonnes)',
      onDelete: () => widget.onChanged(() => widget.dims.removeAt(i)),
      onTap: f != null && f.isDate
          ? () async {
              final b = await _pickBucket(context, f);
              if (b != null) widget.onChanged(() => widget.dims[i] = '${f.key}:$b');
            }
          : null,
      color: T.bg,
    );
  }

  Widget _chip(String text, {required VoidCallback onDelete, VoidCallback? onTap, Color color = T.bg}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(T.rChip),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(T.rChip),
          border: Border.all(color: T.border3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(text, style: T.body.copyWith(fontSize: 13.5), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Retirer',
              child: InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(99),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 16, color: T.faint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMeasure(BuildContext context) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _MeasurePicker(source: source),
    );
    if (res != null) widget.onChanged(() => widget.measures.add(res));
  }

  Future<void> _pickDimension(BuildContext context) async {
    final f = await showDialog<AField>(
      context: context,
      builder: (_) => _FieldPicker(source: source, title: 'Regrouper par', onlyDimensions: true, exclude: {for (final d in widget.dims) d.split(':')[0]}),
    );
    if (f == null) return;
    var key = f.key;
    if (f.isDate) {
      // granularité automatique d'après la période ; modifiable en cliquant la puce
      key = '${f.key}:${f.key == source.dateField ? widget.autoBucket() : 'month'}';
    }
    widget.onChanged(() => widget.dims.add(key));
  }

  Future<String?> _pickBucket(BuildContext context, AField f) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${f.labelFr} : regrouper par', style: T.h2),
        children: [
          for (final b in f.buckets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: Text(kBucketLabels[b] ?? b, style: T.body),
            ),
        ],
      ),
    );
  }

  Future<void> _editFilter(BuildContext context, int? index) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FilterDialog(source: source, initial: index == null ? null : widget.filters[index]),
    );
    if (res == null) return;
    widget.onChanged(() {
      if (index == null) {
        widget.filters.add(res);
      } else {
        widget.filters[index] = res;
      }
    });
  }

  Future<void> _editHaving(BuildContext context) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _HavingDialog(labels: [for (var i = 0; i < widget.measures.length; i++) ('m$i', _measureLabel(widget.measures[i]), _measureFormat(source, widget.measures[i]))]),
    );
    if (res != null) widget.onChanged(() => widget.having.add(res));
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({this.n, required this.title});
  final int? n;
  final String title;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (n != null)
          Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(right: 10),
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: T.ink, shape: BoxShape.circle),
            child: Text(
              '$n',
              style: T.body.copyWith(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          )
        else
          const SizedBox(width: 34),
        Expanded(
          child: Text(title, style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      ],
    );
  }
}

/// Une étape numérotée du constructeur : titre, aide, puces, bouton « Ajouter ».
class _Step extends StatelessWidget {
  const _Step({this.n, required this.title, this.help, required this.chips, required this.addLabel, this.onAdd});
  final int? n;
  final String title;
  final String? help;
  final List<Widget> chips;
  final String addLabel;
  final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepHeader(n: n, title: title),
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (help != null) Text(help!, style: T.small),
                const SizedBox(height: 6),
                if (chips.isNotEmpty) ...[Wrap(spacing: 6, runSpacing: 6, children: chips), const SizedBox(height: 4)],
                if (onAdd != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: T.mintDark, padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 36)),
                    onPressed: onAdd,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: Text(addLabel, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- pickers

class _FieldPicker extends StatefulWidget {
  const _FieldPicker({required this.source, required this.title, this.onlyDimensions = false, this.onlyFilterable = false, this.exclude = const {}});
  final ASource source;
  final String title;
  final bool onlyDimensions, onlyFilterable;
  final Set<String> exclude;
  @override
  State<_FieldPicker> createState() => _FieldPickerState();
}

class _FieldPickerState extends State<_FieldPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<AField>>{};
    for (final f in widget.source.fields) {
      if (widget.onlyDimensions && !f.dimension) continue;
      if (widget.onlyFilterable && !f.filterable) continue;
      if (widget.exclude.contains(f.key)) continue;
      if (_q.isNotEmpty && !f.labelFr.toLowerCase().contains(_q.toLowerCase())) continue;
      groups.putIfAbsent(f.group.isEmpty ? 'Autres' : f.group, () => []).add(f);
    }
    return Dialog(
      child: SizedBox(
        width: 440,
        height: 540,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: T.h2)),
                  IconButton(tooltip: 'Fermer', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                style: T.body,
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(hintText: 'Rechercher…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              ),
            ),
            Expanded(
              child: groups.isEmpty
                  ? Center(child: Text('Rien ne correspond', style: T.bodyMuted))
                  : ListView(
                      padding: const EdgeInsets.all(8),
                      children: [
                        for (final g in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                            child: MicroLabel(g.key, color: T.mintDark),
                          ),
                          for (final f in g.value)
                            ListTile(
                              dense: true,
                              title: Text(f.labelFr, style: T.body),
                              subtitle: f.isDate ? Text('Date — par ${f.buckets.map((b) => (kBucketLabels[b] ?? b).toLowerCase()).join(', ')}', style: T.small) : null,
                              onTap: () => Navigator.pop(context, f),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeasurePicker extends StatefulWidget {
  const _MeasurePicker({required this.source});
  final ASource source;
  @override
  State<_MeasurePicker> createState() => _MeasurePickerState();
}

class _MeasurePickerState extends State<_MeasurePicker> {
  String _q = '';

  static String _formatWord(String f) => switch (f) {
    'currency' => 'montant (DA)',
    'quantity' => 'quantité',
    'percent' => 'pourcentage',
    'ratio' => 'rapport',
    _ => 'nombre',
  };

  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    final named = [
      for (final n in s.named)
        if (_q.isEmpty || n.labelFr.toLowerCase().contains(_q.toLowerCase())) n,
    ];
    final fields = [
      for (final f in s.fields)
        if (f.measure && (_q.isEmpty || f.labelFr.toLowerCase().contains(_q.toLowerCase()))) f,
    ];
    return Dialog(
      child: SizedBox(
        width: 500,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('Que voulez-vous voir ?', style: T.h2)),
                  IconButton(tooltip: 'Fermer', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                style: T.body,
                onChanged: (v) => setState(() => _q = v),
                decoration: const InputDecoration(hintText: 'Rechercher…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 10, 8, 4),
                    child: MicroLabel('Les plus utilisés', color: T.mintDark),
                  ),
                  for (final n in named)
                    ListTile(
                      dense: true,
                      title: Text(n.labelFr, style: T.body),
                      trailing: Text(_formatWord(n.format), style: T.small),
                      onTap: () => Navigator.pop(context, {'name': n.key}),
                    ),
                  if (fields.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 14, 8, 4),
                      child: MicroLabel('Calculer sur un champ', color: T.mintDark),
                    ),
                  for (final f in fields)
                    ListTile(
                      dense: true,
                      title: Text(f.labelFr, style: T.body),
                      subtitle: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final a in f.aggs)
                            ActionChip(
                              label: Text(kAggLabels[a] ?? a, style: T.body.copyWith(fontSize: 13)),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Navigator.pop(context, {'field': f.key, 'agg': a}),
                            ),
                          if (f.dimension)
                            ActionChip(
                              label: Text('Distincts', style: T.body.copyWith(fontSize: 13)),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Navigator.pop(context, {'field': f.key, 'agg': 'count_distinct'}),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterDialog extends StatefulWidget {
  const _FilterDialog({required this.source, this.initial});
  final ASource source;
  final Map<String, dynamic>? initial;
  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  AField? _field;
  String _op = 'eq';
  final _v1 = TextEditingController();
  final _v2 = TextEditingController();
  bool _bool = true;
  final Set<String> _multi = {};
  String? _err;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _field = widget.source.field('${i['field']}');
      _op = '${i['op']}';
      final v = i['value'];
      final factor = _field == null ? 1 : _unitFactor(_field!);
      String txt(dynamic e) => e is num ? _numText(e / factor) : '$e';
      if (v is List) {
        if (_op == 'between' && v.length == 2) {
          _v1.text = txt(v[0]);
          _v2.text = txt(v[1]);
        } else if (_field?.enumValues.isNotEmpty == true) {
          _multi.addAll(v.map((e) => '$e'));
        } else {
          _v1.text = v.map(txt).join(', ');
        }
      } else if (v is bool) {
        _bool = v;
      } else if (v != null) {
        _v1.text = txt(v);
      }
    }
  }

  @override
  void dispose() {
    _v1.dispose();
    _v2.dispose();
    super.dispose();
  }

  Widget _labelled(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: T.label),
      const SizedBox(height: 4),
      child,
    ],
  );

  Future<void> _pickDate(TextEditingController c) async {
    final d = await showDatePicker(context: context, initialDate: DateTime.tryParse(c.text) ?? DateTime.now(), firstDate: DateTime(2015), lastDate: DateTime(2100));
    if (d != null) setState(() => c.text = _iso(d));
  }

  Widget _valueField(TextEditingController c, AField f, String label) {
    if (f.isDate) {
      return _labelled(
        label,
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 42),
            foregroundColor: T.ink,
            side: const BorderSide(color: T.border3),
          ),
          onPressed: () => _pickDate(c),
          icon: const Icon(Icons.calendar_today_outlined, size: 16),
          label: Text(c.text.isEmpty ? 'Choisir une date' : frDate(c.text), style: T.body),
        ),
      );
    }
    final hint = _unitHint(f);
    return _labelled(
      hint.isEmpty ? label : '$label ($hint)',
      TextField(
        controller: c,
        autofocus: true,
        style: T.body,
        keyboardType: f.type == 'number' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
      ),
    );
  }

  void _apply() {
    final f = _field;
    if (f == null) {
      setState(() => _err = 'Choisissez sur quoi filtrer');
      return;
    }
    final factor = _unitFactor(f);
    dynamic num1(String s) {
      final v = _parseNum(s);
      if (v == null) return null;
      final raw = v * factor;
      return raw == raw.roundToDouble() ? raw.round() : raw;
    }

    dynamic value;
    if (_op == 'is_null' || _op == 'is_not_null') {
      value = null;
    } else if (f.type == 'bool') {
      value = _bool;
    } else if (_op == 'in' || _op == 'not_in') {
      value = f.enumValues.isNotEmpty
          ? _multi.toList()
          : [
              for (final p in _v1.text.split(','))
                if (p.trim().isNotEmpty) p.trim(),
            ];
      if ((value as List).isEmpty) {
        setState(() => _err = 'Choisissez au moins une valeur');
        return;
      }
    } else if (_op == 'between') {
      if (f.type == 'number') {
        final a = num1(_v1.text), b = num1(_v2.text);
        if (a == null || b == null) {
          setState(() => _err = 'Saisissez deux nombres');
          return;
        }
        value = [a, b];
      } else {
        if (_v1.text.trim().isEmpty || _v2.text.trim().isEmpty) {
          setState(() => _err = 'Saisissez les deux bornes');
          return;
        }
        value = [_v1.text.trim(), _v2.text.trim()];
      }
    } else if (f.type == 'number') {
      value = num1(_v1.text);
      if (value == null) {
        setState(() => _err = 'Saisissez un nombre');
        return;
      }
    } else {
      value = _v1.text.trim();
      if ((value as String).isEmpty) {
        setState(() => _err = 'Saisissez une valeur');
        return;
      }
    }
    Navigator.pop(context, {'field': f.key, 'op': _op, 'value': ?value});
  }

  @override
  Widget build(BuildContext context) {
    final f = _field;
    final ops = f?.ops ?? const <String>[];
    if (f != null && ops.isNotEmpty && !ops.contains(_op)) _op = ops.first;
    return AlertDialog(
      title: Text(widget.initial == null ? 'Ajouter un filtre' : 'Modifier le filtre', style: T.h2),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _labelled(
              'Filtrer sur',
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 42),
                  alignment: Alignment.centerLeft,
                  foregroundColor: T.ink,
                  side: const BorderSide(color: T.border3),
                ),
                onPressed: () async {
                  final x = await showDialog<AField>(
                    context: context,
                    builder: (_) => _FieldPicker(source: widget.source, title: 'Filtrer sur', onlyFilterable: true),
                  );
                  if (x != null) {
                    setState(() {
                      _field = x;
                      _multi.clear();
                      _v1.clear();
                      _v2.clear();
                      _err = null;
                    });
                  }
                },
                child: Text(f?.labelFr ?? 'Choisir…', style: T.body),
              ),
            ),
            if (f != null) ...[
              const SizedBox(height: 12),
              _labelled(
                'Condition',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final o in ops)
                      ChoiceChip(
                        label: Text(_kOpWords[o] ?? o, style: T.body.copyWith(fontSize: 13.5, color: _op == o ? Colors.white : T.ink)),
                        selected: _op == o,
                        selectedColor: T.ink,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _op = o),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_op == 'is_null' || _op == 'is_not_null')
                const SizedBox()
              else if (f.type == 'bool')
                Row(
                  children: [
                    Switch(value: _bool, activeThumbColor: T.mint, onChanged: (v) => setState(() => _bool = v)),
                    Text(_bool ? 'Oui' : 'Non', style: T.body),
                  ],
                )
              else if (f.enumValues.isNotEmpty && (_op == 'in' || _op == 'not_in'))
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final v in f.enumValues)
                      FilterChip(
                        label: Text(v, style: T.body.copyWith(fontSize: 13.5)),
                        selected: _multi.contains(v),
                        onSelected: (s) => setState(() => s ? _multi.add(v) : _multi.remove(v)),
                      ),
                  ],
                )
              else if (f.enumValues.isNotEmpty)
                _labelled(
                  'Valeur',
                  DropdownButton<String>(
                    value: f.enumValues.contains(_v1.text) ? _v1.text : null,
                    isExpanded: true,
                    hint: const Text('Choisir', style: T.body),
                    items: [
                      for (final v in f.enumValues)
                        DropdownMenuItem(
                          value: v,
                          child: Text(v, style: T.body),
                        ),
                    ],
                    onChanged: (v) => setState(() => _v1.text = v ?? ''),
                  ),
                )
              else if (_op == 'in' || _op == 'not_in')
                _labelled(
                  'Valeurs séparées par des virgules',
                  TextField(
                    controller: _v1,
                    style: T.body,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  ),
                )
              else if (_op == 'between')
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _valueField(_v1, f, f.isDate ? 'Du' : 'De')),
                    const SizedBox(width: 8),
                    Expanded(child: _valueField(_v2, f, f.isDate ? 'Au' : 'À')),
                  ],
                )
              else
                _valueField(_v1, f, 'Valeur'),
            ],
            FieldError(_err),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(label: 'Appliquer', onPressed: _apply),
      ],
    );
  }
}

class _HavingDialog extends StatefulWidget {
  const _HavingDialog({required this.labels});
  final List<(String, String, String)> labels; // ref, libellé, format
  @override
  State<_HavingDialog> createState() => _HavingDialogState();
}

class _HavingDialogState extends State<_HavingDialog> {
  late String _m = widget.labels.first.$1;
  String _op = 'gte';
  final _v = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  String get _format => widget.labels.firstWhere((l) => l.$1 == _m, orElse: () => widget.labels.first).$3;

  @override
  Widget build(BuildContext context) {
    final unit = unitWord(_format);
    return AlertDialog(
      title: const Text('Garder seulement les lignes où…', style: T.h2),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Valeur', style: T.label),
            DropdownButton<String>(
              value: _m,
              isExpanded: true,
              items: [
                for (final l in widget.labels)
                  DropdownMenuItem(
                    value: l.$1,
                    child: Text(l.$2, style: T.body),
                  ),
              ],
              onChanged: (v) => setState(() => _m = v!),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final o in const ['gte', 'gt', 'lte', 'lt', 'eq', 'ne'])
                  ChoiceChip(
                    label: Text(_kOpWords[o]!, style: T.body.copyWith(fontSize: 13.5, color: _op == o ? Colors.white : T.ink)),
                    selected: _op == o,
                    selectedColor: T.ink,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _op = o),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(unit.isEmpty ? 'Seuil' : 'Seuil (en $unit)', style: T.label),
            const SizedBox(height: 4),
            TextField(
              controller: _v,
              autofocus: true,
              style: T.body,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
            FieldError(_err),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        PrimaryButton(
          label: 'Appliquer',
          onPressed: () {
            final v = _parseNum(_v.text);
            if (v == null) {
              setState(() => _err = 'Saisissez un nombre');
              return;
            }
            Navigator.pop(context, {'measure': _m, 'op': _op, 'value': _toRaw(v, _format)});
          },
        ),
      ],
    );
  }
}
