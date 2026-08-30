import 'package:elixir_app/templates/template_defaults.dart';
import 'package:elixir_app/templates/template_model.dart';
import 'package:elixir_app/templates/template_render.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rows = [
    ['Mixeur Moulinex 700W', '1', '6 638,66', '6 638,66'],
    ['Cafetière expresso', '2', '3 403,36', '6 806,72'],
  ];

  for (final kind in ['label', 'invoice', 'warranty']) {
    for (final lang in ['fr', 'ar']) {
      test('renders default $kind template ($lang)', () async {
        final tpl = defaultTplDoc(kind, lang);
        final bytes = await renderTemplateBytes(
          tpl,
          lang: lang,
          data: tplSampleData,
          tableRows: rows,
        );
        expect(bytes.length, greaterThan(1000));
        // %PDF magic
        expect(bytes.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]);
      });
    }
  }

  test('round-trips template JSON', () {
    final tpl = defaultTplDoc('warranty', 'ar');
    final back = TplDoc.fromJson(tpl.toJson());
    expect(back.elements.length, tpl.elements.length);
    expect(back.widthMm, tpl.widthMm);
    expect(back.elements.first.type, tpl.elements.first.type);
  });
}
