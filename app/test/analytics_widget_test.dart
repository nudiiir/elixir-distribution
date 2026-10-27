import 'package:elixir_app/api/analytics_models.dart';
import 'package:elixir_app/api/client.dart';
import 'package:elixir_app/api/models.dart';
import 'package:elixir_app/screens/analytics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final schemaJson = {
  'version': 1,
  'ranges': ['this_month'],
  'sources': [
    {
      'key': 'sale_lines',
      'label_fr': 'Ventes',
      'date_field': 'doc_date',
      'fields': [
        {'field': 'doc_date', 'label_fr': 'Date de vente', 'type': 'date', 'dimension': true, 'filterable': true, 'buckets': ['day', 'week', 'month'], 'allowed_ops': ['eq', 'between']},
        {'field': 'product_name', 'label_fr': 'Produit (nom)', 'type': 'string', 'dimension': true, 'filterable': true, 'allowed_ops': ['eq', 'contains']},
        {'field': 'category_name', 'label_fr': 'Catégorie (nom)', 'type': 'string', 'dimension': true, 'filterable': true, 'allowed_ops': ['eq']},
        {'field': 'line_ttc', 'label_fr': 'Montant TTC', 'type': 'number', 'unit': 'centimes', 'format': 'currency', 'measure': true, 'filterable': true, 'allowed_aggs': ['sum'], 'allowed_ops': ['gt', 'lt', 'between']},
      ],
      'named_measures': [
        {'key': 'ca_ttc', 'label_fr': "Chiffre d'affaires TTC", 'format': 'currency', 'unit': 'centimes'},
      ],
    },
  ],
};

Map<String, dynamic> resultJson(Map<String, dynamic> spec, {bool empty = false}) {
  final dims = [for (final d in (spec['dimensions'] as List? ?? const [])) '$d'];
  final cols = <Map<String, dynamic>>[
    for (var i = 0; i < dims.length; i++)
      {'key': 'd$i', 'kind': 'dimension', 'field': dims[i].split(':')[0], 'bucket': dims[i].contains(':') ? dims[i].split(':')[1] : '', 'label': dims[i]},
    {'key': 'm0', 'kind': 'measure', 'field': 'ca_ttc', 'label': "Chiffre d'affaires TTC", 'format': 'currency'},
  ];
  final rows = empty
      ? <List<dynamic>>[]
      : dims.isEmpty
          ? [
              [123400]
            ]
          : [
              for (var r = 0; r < 6; r++) [for (var i = 0; i < dims.length; i++) dims[i].startsWith('doc_date') ? '2026-10-0${r + 1}' : 'Produit $r', (r - 1) * 50000],
            ];
  return {
    'columns': cols,
    'rows': rows,
    'total_rows': rows.length,
    'range': {'from': '2026-10-01', 'to': '2026-10-08'},
  };
}

class FakeApi extends ApiClient {
  bool emptyThisMonth = false;
  final queries = <Map<String, dynamic>>[];
  final reports = <SavedReport>[];
  List<Map<String, dynamic>> layout = [];
  final savedLayouts = <List<Map<String, dynamic>>>[];

  @override
  Future<ASchema> analyticsSchema() async => ASchema.fromJson(schemaJson);
  @override
  Future<List<GalleryItem>> analyticsGallery() async => [
        GalleryItem.fromJson({
          'theme': 'Ventes',
          'title': 'Ventes du jour',
          'spec': {'source': 'sale_lines', 'dimensions': [], 'measures': [{'name': 'ca_ttc'}], 'range': {'type': 'today'}}
        })
      ];
  @override
  Future<AResult> analyticsQuery(Map<String, dynamic> spec) async {
    queries.add(spec);
    final empty = emptyThisMonth && (spec['range'] as Map)['type'] == 'this_month';
    return AResult.fromJson(resultJson(spec, empty: empty));
  }

  @override
  Future<Map<String, Object>> analyticsBatch(List<MapEntry<String, Map<String, dynamic>>> queries, {Map<String, dynamic>? globalRange, String? globalWarehouseId}) async =>
      {for (final q in queries) q.key: AResult.fromJson(resultJson(q.value))};

  @override
  Future<AskAnswer> analyticsAsk(String question) async => AskAnswer.fromJson({
        'question': question,
        'provider': 'local',
        'title': 'Ventes du mois',
        'explanation': 'Chiffre par jour',
        'spec': {'source': 'sale_lines', 'dimensions': ['doc_date:day'], 'measures': [{'name': 'ca_ttc'}], 'range': {'type': 'this_month'}},
        'result': resultJson({'dimensions': ['doc_date:day']}, empty: true),
      });

  @override
  Future<List<SavedReport>> savedReports() async => List.of(reports);
  @override
  Future<SavedReport> saveReport(Map<String, dynamic> data, {String? id}) async {
    final r = SavedReport.fromJson({...data, 'id': id ?? 'r${reports.length + 1}', 'owner_id': 'u1'});
    reports.removeWhere((x) => x.id == r.id);
    reports.add(r);
    return r;
  }

  @override
  Future<void> deleteReport(String id) async {
    reports.removeWhere((x) => x.id == id);
    layout.removeWhere((t) => t['report_id'] == id);
  }

  Dashboard get board => Dashboard.fromJson({'id': 'd1', 'name': 'Principal', 'is_shared': true, 'layout': layout, 'global_range': {'type': 'this_month'}});
  @override
  Future<List<Dashboard>> dashboards() async => [board];
  @override
  Future<Dashboard> saveDashboard(Map<String, dynamic> data, {String? id}) async {
    layout = [for (final t in data['layout'] as List) Map<String, dynamic>.from(t as Map)];
    savedLayouts.add(layout);
    return board;
  }
}

final session = Session('t', User.fromJson({'id': 'u1', 'username': 'admin', 'full_name': 'Admin', 'role': 'admin', 'active': true, 'perms': <String, dynamic>{}}));

Future<void> settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('explorer: liste, détail, enregistrement, vide', (t) async {
    t.view.physicalSize = const Size(1366, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeApi();
    final req = ValueNotifier<ExplorerRequest?>(ExplorerRequest(
      seed: {'source': 'sale_lines', 'dimensions': ['product_name'], 'measures': [{'name': 'ca_ttc'}], 'range': {'type': 'last_n_days', 'n': 90}, 'limit': 500},
      title: 'Ventes du produit',
      origin: 'Depuis la fiche produit',
    ));
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnalyticsExplorerScreen(api: api, session: session, request: req, onDone: () {}))));
    await settle(t);
    expect(find.text('Depuis la fiche produit'), findsOneWidget);
    expect(find.text('Ventes du produit'), findsWidgets);
    await t.tap(find.text('Liste'));
    await settle(t);
    expect(find.text('Produit 3'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('6 lignes'), findsOneWidget);
    // recherche
    await t.enterText(find.widgetWithText(TextField, 'Rechercher dans le tableau…'), 'Produit 2');
    await settle(t, 3);
    expect(find.text('1 sur 6 lignes'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Rechercher dans le tableau…'), '');
    await settle(t, 3);
    // detail
    await t.tap(find.text('Produit 3'));
    await settle(t, 4);
    expect(find.text('Détailler « Produit 3 »'), findsOneWidget);
    await t.tap(find.text('Par catégorie'));
    await settle(t);
    expect(find.text('Vue de départ'), findsOneWidget);
    final last = api.queries.last;
    expect((last['filters'] as List).first['value'], 'Produit 3');
    expect(last['dimensions'], ['category_name']);
    await t.tap(find.text('Vue de départ'));
    await settle(t);
    expect(api.queries.last['dimensions'], ['product_name']);
    // style + couleurs
    await t.tap(find.text('Couleurs et style'));
    await settle(t, 4);
    await t.tap(find.text('Plus haut = mieux'));
    await settle(t, 3);
    await t.ensureVisible(find.text('Ajouter une règle'));
    await settle(t, 2);
    await t.tap(find.text('Ajouter une règle'));
    await settle(t, 3);
    // enregistrer
    await t.tap(find.text('Enregistrer la vue'));
    await settle(t, 4);
    expect(find.text('Ajouter au tableau de bord'), findsWidgets);
    await t.tap(find.text('Enregistrer'));
    await settle(t, 6);
    expect(api.reports.length, 1);
    expect(api.reports.first.name, 'Ventes du produit');
    expect(api.reports.first.encoding['cond'], isNotNull);
    expect(api.layout.length, 1);
    expect(find.text('Voir sur le tableau de bord'), findsOneWidget);
    expect(AnalyticsBus.revision.value, greaterThan(0));
  });

  testWidgets('explorer: réponse IA vide → périodes plus larges', (t) async {
    t.view.physicalSize = const Size(1366, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeApi()..emptyThisMonth = true;
    final req = ValueNotifier<ExplorerRequest?>(null);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnalyticsExplorerScreen(api: api, session: session, request: req, onDone: () {}))));
    await settle(t);
    await t.enterText(find.byType(TextField).first, 'ventes ce mois');
    await t.tap(find.text('Demander'));
    await settle(t);
    expect(find.text('Réponse trouvée dans les questions prêtes'), findsOneWidget);
    expect(find.textContaining('Aucune vente ce mois-ci'), findsOneWidget);
    await t.tap(find.text('3 derniers mois'));
    await settle(t);
    expect((api.queries.last['range'] as Map)['type'], 'last_n_months');
    expect(find.textContaining('Aucune vente'), findsNothing);
  });

  testWidgets('explorer: tableau croisé, mes vues, tableau vide', (t) async {
    t.view.physicalSize = const Size(1366, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeApi();
    await api.saveReport({'name': 'Vue X', 'spec': {'source': 'sale_lines', 'dimensions': ['product_name'], 'measures': [{'name': 'ca_ttc'}]}, 'chart_type': 'table'});
    final req = ValueNotifier<ExplorerRequest?>(ExplorerRequest(
      seed: {'source': 'sale_lines', 'dimensions': ['category_name', 'product_name'], 'measures': [{'name': 'ca_ttc'}], 'range': {'type': 'this_month'}},
    ));
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnalyticsExplorerScreen(api: api, session: session, request: req, onDone: () {}))));
    await settle(t);
    expect(find.text('Tableau croisé'), findsWidgets);
    expect(find.text('Total'), findsWidgets);
    await t.ensureVisible(find.text('Total').first);
    await t.tap(find.text('Total').first, warnIfMissed: false);
    await settle(t, 3);
    await t.tap(find.text('Couleurs et style'));
    await settle(t, 4);
    await t.ensureVisible(find.text('Les premiers'));
    await settle(t, 2);
    await t.tap(find.text('Les premiers'));
    await settle(t, 4);
    await t.tap(find.text('Fermer le style'));
    await settle(t, 4);
    await t.tap(find.text('Mes vues'));
    await settle(t, 6);
    expect(find.text('Vue X'), findsOneWidget);
    expect(find.text('sur aucun tableau de bord'), findsOneWidget);
    await t.tap(find.text('Renommer'));
    await settle(t, 4);
    await t.enterText(find.byType(TextField).last, 'Vue Y');
    await t.tap(find.text('Renommer').last);
    await settle(t, 6);
    expect(api.reports.first.name, 'Vue Y');
    // tableau de bord vide
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnalyticsDashboardScreen(api: api, session: session, onEdit: (_) {}, onNew: () {}))));
    await settle(t);
    expect(find.text('Ajouter une vue existante'), findsWidgets);
    await t.tap(find.text('Ajouter une vue existante').last);
    await settle(t, 4);
    await t.tap(find.text('Vue Y'));
    await settle(t, 8);
    expect(api.layout.length, 1);
  });

  testWidgets('tableau de bord: rechargement + fusion', (t) async {
    t.view.physicalSize = const Size(1366, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeApi();
    for (final n in ['A', 'B']) {
      await api.saveReport({'name': n, 'spec': {'source': 'sale_lines', 'dimensions': ['product_name'], 'measures': [{'name': 'ca_ttc'}]}, 'chart_type': 'table'});
    }
    api.layout = [
      {'report_id': 'r1', 'x': 0, 'y': 0, 'w': 6, 'h': 4},
      {'report_id': 'r2', 'x': 6, 'y': 0, 'w': 6, 'h': 4},
    ];
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnalyticsDashboardScreen(api: api, session: session, onEdit: (_) {}, onNew: () {}))));
    await settle(t);
    expect(find.text('A'), findsOneWidget);
    // the explorer adds C on the server without notice
    await api.saveReport({'name': 'C', 'spec': {'source': 'sale_lines', 'dimensions': [], 'measures': [{'name': 'ca_ttc'}]}, 'chart_type': 'stat'});
    api.layout = [...api.layout, {'report_id': 'r3', 'x': 0, 'y': 4, 'w': 3, 'h': 2}];
    // we remove A: the save must keep C
    await t.tap(find.text('Actions').first);
    await settle(t, 4);
    await t.tap(find.text('Retirer du tableau de bord'));
    await settle(t, 8);
    expect([for (final x in api.layout) x['report_id']], unorderedEquals(['r2', 'r3']));
    expect(find.text('C'), findsWidgets);
    // a bump reloads
    await api.saveReport({'name': 'D', 'spec': {'source': 'sale_lines', 'dimensions': [], 'measures': [{'name': 'ca_ttc'}]}, 'chart_type': 'stat'});
    api.layout = [...api.layout, {'report_id': 'r4', 'x': 0, 'y': 8, 'w': 3, 'h': 2}];
    AnalyticsBus.bump();
    await settle(t, 8);
    expect(find.text('D'), findsWidgets);
    // menu de tuile
    await t.tap(find.text('Actions').first);
    await settle(t, 4);
    expect(find.text("Ouvrir dans l'explorateur"), findsOneWidget);
    expect(find.text('Modifier'), findsOneWidget);
  });
}
