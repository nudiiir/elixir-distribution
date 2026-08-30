import 'template_model.dart';

/// Factory-default layouts. They seed the designer when the user creates a
/// template, and they are what prints when no template has been saved yet.
TplDoc defaultTplDoc(String kind, String lang) => switch (kind) {
      'label' => _label(lang),
      'warranty' => _warranty(lang),
      _ => _invoice(lang),
    };

bool _ar(String lang) => lang == 'ar';

/// 50 × 30 mm shelf/product label.
TplDoc _label(String lang) => TplDoc(widthMm: 50, heightMm: 30, elements: [
      TplElement(
          type: 'field',
          field: 'shop.name',
          x: 2, y: 1, w: 46, h: 4,
          fontSize: 6, align: 'center'),
      TplElement(
          type: 'field',
          field: _ar(lang) ? 'product.name_ar' : 'product.name',
          x: 2, y: 5.5, w: 46, h: 8,
          fontSize: 8, bold: true, align: 'center'),
      TplElement(
          type: 'field',
          field: 'product.price',
          x: 2, y: 13, w: 46, h: 6.5,
          fontSize: 12, bold: true, mono: true, align: 'center'),
      TplElement(type: 'barcode', x: 8, y: 20, w: 34, h: 9),
    ]);

/// 148 × 210 mm (A5) warranty certificate.
TplDoc _warranty(String lang) {
  final ar = _ar(lang);
  final align = ar ? 'right' : 'left';
  String t(String fr, String arab) => ar ? arab : fr;
  return TplDoc(widthMm: 148, heightMm: 210, elements: [
    TplElement(
        type: 'field',
        field: 'shop.name',
        x: 10, y: 10, w: 128, h: 8,
        fontSize: 15, bold: true, align: 'center'),
    TplElement(
        type: 'field',
        field: 'shop.address',
        x: 10, y: 18, w: 128, h: 5,
        fontSize: 8, align: 'center'),
    TplElement(
        type: 'field',
        field: 'shop.phone',
        x: 10, y: 23, w: 128, h: 5,
        fontSize: 8, align: 'center'),
    TplElement(type: 'line', x: 10, y: 30, w: 128, h: 0, borderWidth: 0.6),
    TplElement(
        type: 'text',
        text: t('BON DE GARANTIE', 'شهادة الضمان'),
        x: 10, y: 36, w: 128, h: 10,
        fontSize: 18, bold: true, align: 'center'),
    TplElement(
        type: 'text',
        text: t('Produit', 'المنتج'),
        x: 10, y: 56, w: 40, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'product.name',
        x: 52, y: 56, w: 86, h: 6, fontSize: 10, align: align),
    TplElement(
        type: 'text',
        text: t('N° de vente', 'رقم البيع'),
        x: 10, y: 66, w: 40, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'doc.number',
        x: 52, y: 66, w: 86, h: 6, fontSize: 10, mono: true, align: align),
    TplElement(
        type: 'text',
        text: t("Date d'achat", 'تاريخ الشراء'),
        x: 10, y: 76, w: 40, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'doc.date',
        x: 52, y: 76, w: 86, h: 6, fontSize: 10, mono: true, align: align),
    TplElement(
        type: 'text',
        text: t('Client', 'الزبون'),
        x: 10, y: 86, w: 40, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'client.name',
        x: 52, y: 86, w: 86, h: 6, fontSize: 10, align: align),
    TplElement(
        type: 'text',
        text: t('Durée de garantie (mois)', 'مدة الضمان (أشهر)'),
        x: 10, y: 96, w: 60, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'warranty.months',
        x: 72, y: 96, w: 30, h: 6, fontSize: 10, mono: true, align: align),
    TplElement(
        type: 'text',
        text: t("Valable jusqu'au", 'صالح إلى غاية'),
        x: 10, y: 106, w: 60, h: 6, fontSize: 10, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'warranty.end',
        x: 72, y: 106, w: 40, h: 6, fontSize: 10, mono: true, align: align),
    TplElement(type: 'rect', x: 10, y: 120, w: 128, h: 50, borderWidth: 0.4),
    TplElement(
        type: 'text',
        text: t(
            'La garantie couvre les défauts de fabrication. Elle ne couvre '
                'ni la casse, ni une mauvaise utilisation, ni les dommages '
                "causés par l'eau ou les surtensions. Le produit doit être "
                'présenté avec ce bon.',
            'يغطي الضمان عيوب التصنيع فقط. لا يشمل الكسر أو سوء الاستعمال '
                'أو الأضرار الناتجة عن الماء أو التيار الكهربائي. يجب تقديم '
                'المنتج مرفقاً بهذه الشهادة.'),
        x: 14, y: 124, w: 120, h: 42,
        fontSize: 8.5, align: align),
    TplElement(
        type: 'text',
        text: t('Cachet et signature', 'الختم والإمضاء'),
        x: ar ? 10 : 88, y: 180, w: 50, h: 6, fontSize: 9, align: 'center'),
    TplElement(
        type: 'rect',
        x: ar ? 10 : 88, y: 187, w: 50, h: 18, borderWidth: 0.3),
  ]);
}

/// 210 × 297 mm (A4) invoice.
TplDoc _invoice(String lang) {
  final ar = _ar(lang);
  final align = ar ? 'right' : 'left';
  String t(String fr, String arab) => ar ? arab : fr;
  return TplDoc(widthMm: 210, heightMm: 297, elements: [
    TplElement(
        type: 'field',
        field: 'shop.name',
        x: 15, y: 12, w: 110, h: 8, fontSize: 15, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'shop.address',
        x: 15, y: 20, w: 110, h: 5, fontSize: 8.5, align: align),
    TplElement(
        type: 'field',
        field: 'shop.phone',
        x: 15, y: 25, w: 110, h: 5, fontSize: 8.5, align: align),
    TplElement(
        type: 'field',
        field: 'doc.title',
        x: 130, y: 12, w: 65, h: 9, fontSize: 17, bold: true, align: 'right'),
    TplElement(
        type: 'field',
        field: 'doc.number',
        x: 130, y: 22, w: 65, h: 6, fontSize: 10, mono: true, align: 'right'),
    TplElement(
        type: 'field',
        field: 'doc.date',
        x: 130, y: 28, w: 65, h: 6, fontSize: 10, mono: true, align: 'right'),
    TplElement(type: 'line', x: 15, y: 36, w: 180, h: 0, borderWidth: 0.6),
    TplElement(
        type: 'text',
        text: t('Client', 'الزبون'),
        x: 15, y: 41, w: 40, h: 5, fontSize: 8, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'client.name',
        x: 15, y: 46, w: 90, h: 6, fontSize: 11, bold: true, align: align),
    TplElement(
        type: 'field',
        field: 'client.address',
        x: 15, y: 52, w: 90, h: 5, fontSize: 8.5, align: align),
    TplElement(
        type: 'field',
        field: 'client.nif',
        x: 15, y: 57, w: 90, h: 5, fontSize: 8.5, mono: true, align: align),
    TplElement(type: 'table', x: 15, y: 68, w: 180, h: 150, fontSize: 9),
    TplElement(
        type: 'text',
        text: t('Total HT', 'المجموع دون رسوم'),
        x: 120, y: 224, w: 40, h: 6, fontSize: 9, align: 'right'),
    TplElement(
        type: 'field',
        field: 'total.ht',
        x: 162, y: 224, w: 33, h: 6, fontSize: 9, mono: true, align: 'right'),
    TplElement(
        type: 'text',
        text: t('TVA', 'الرسم ع.ق.م'),
        x: 120, y: 230, w: 40, h: 6, fontSize: 9, align: 'right'),
    TplElement(
        type: 'field',
        field: 'total.vat',
        x: 162, y: 230, w: 33, h: 6, fontSize: 9, mono: true, align: 'right'),
    TplElement(
        type: 'text',
        text: t('Timbre', 'الطابع'),
        x: 120, y: 236, w: 40, h: 6, fontSize: 9, align: 'right'),
    TplElement(
        type: 'field',
        field: 'total.timbre',
        x: 162, y: 236, w: 33, h: 6, fontSize: 9, mono: true, align: 'right'),
    TplElement(
        type: 'text',
        text: t('TOTAL TTC', 'المجموع الإجمالي'),
        x: 120, y: 244, w: 40, h: 7,
        fontSize: 11, bold: true, align: 'right'),
    TplElement(
        type: 'field',
        field: 'total.ttc',
        x: 162, y: 244, w: 33, h: 7,
        fontSize: 11, bold: true, mono: true, align: 'right'),
    TplElement(
        type: 'field',
        field: 'total.lettres',
        x: 15, y: 256, w: 180, h: 10, fontSize: 9, italic: true, align: align),
    TplElement(
        type: 'text',
        text: t('Cachet et signature', 'الختم والإمضاء'),
        x: 150, y: 270, w: 45, h: 6, fontSize: 9, align: 'center'),
  ]);
}
