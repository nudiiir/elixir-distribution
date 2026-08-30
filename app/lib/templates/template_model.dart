/// The designer's document model. A template is a page size in millimetres
/// plus a list of absolutely-positioned elements. The same JSON is edited on
/// the canvas and fed to the PDF renderer, so what you see is what prints.
library;

class TplElement {
  TplElement({
    required this.type,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.text = '',
    this.field = '',
    this.fontSize = 10,
    this.bold = false,
    this.italic = false,
    this.mono = false,
    this.align = 'left', // left | center | right
    this.borderWidth = 0.4,
    this.filled = false,
  });

  /// text  = static content typed by the designer
  /// field = a data placeholder resolved at print time
  /// barcode = the product/document barcode drawn as EAN-13 / Code 128
  /// line / rect = plain strokes
  /// table = the document's line items (invoices only)
  String type;
  double x, y, w, h; // millimetres
  String text;
  String field;
  double fontSize; // points
  bool bold;
  bool italic;
  bool mono;
  String align;
  double borderWidth;
  bool filled;

  Map<String, dynamic> toJson() => {
        'type': type,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        if (text.isNotEmpty) 'text': text,
        if (field.isNotEmpty) 'field': field,
        'font_size': fontSize,
        if (bold) 'bold': true,
        if (italic) 'italic': true,
        if (mono) 'mono': true,
        'align': align,
        'border_width': borderWidth,
        if (filled) 'filled': true,
      };

  factory TplElement.fromJson(Map<String, dynamic> j) => TplElement(
        type: (j['type'] as String?) ?? 'text',
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        w: (j['w'] as num?)?.toDouble() ?? 30,
        h: (j['h'] as num?)?.toDouble() ?? 8,
        text: (j['text'] as String?) ?? '',
        field: (j['field'] as String?) ?? '',
        fontSize: (j['font_size'] as num?)?.toDouble() ?? 10,
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        mono: j['mono'] == true,
        align: (j['align'] as String?) ?? 'left',
        borderWidth: (j['border_width'] as num?)?.toDouble() ?? 0.4,
        filled: j['filled'] == true,
      );

  TplElement copy() => TplElement.fromJson(toJson());
}

class TplDoc {
  TplDoc({
    required this.widthMm,
    required this.heightMm,
    required this.elements,
  });

  double widthMm;
  double heightMm;
  List<TplElement> elements;

  Map<String, dynamic> toJson() => {
        'width_mm': widthMm,
        'height_mm': heightMm,
        'elements': [for (final e in elements) e.toJson()],
      };

  factory TplDoc.fromJson(Map<String, dynamic> j) => TplDoc(
        widthMm: (j['width_mm'] as num?)?.toDouble() ?? 210,
        heightMm: (j['height_mm'] as num?)?.toDouble() ?? 297,
        elements: [
          for (final e in (j['elements'] as List? ?? const []))
            TplElement.fromJson(e as Map<String, dynamic>)
        ],
      );
}

/// The placeholders each template kind may use, with French labels for the
/// designer's picker. Keys are what gets stored in the JSON.
const Map<String, Map<String, String>> tplFields = {
  'label': {
    'product.name': 'Nom du produit',
    'product.name_ar': 'Nom (arabe)',
    'product.price': 'Prix TTC',
    'product.barcode': 'Code-barres (texte)',
    'shop.name': 'Nom du commerce',
    'date': 'Date',
  },
  'invoice': {
    'shop.name': 'Nom du commerce',
    'shop.address': 'Adresse',
    'shop.phone': 'Téléphone',
    'shop.nif': 'NIF',
    'shop.rc': 'RC',
    'shop.ai': 'AI',
    'doc.title': 'Type du document',
    'doc.number': 'Numéro',
    'doc.date': 'Date',
    'client.name': 'Client — nom',
    'client.address': 'Client — adresse',
    'client.nif': 'Client — NIF',
    'client.rc': 'Client — RC',
    'total.ht': 'Total HT',
    'total.vat': 'Total TVA',
    'total.timbre': 'Timbre',
    'total.ttc': 'Total TTC',
    'total.lettres': 'Montant en lettres',
  },
  'warranty': {
    'shop.name': 'Nom du commerce',
    'shop.address': 'Adresse',
    'shop.phone': 'Téléphone',
    'doc.number': 'N° de vente',
    'doc.date': "Date d'achat",
    'client.name': 'Client',
    'product.name': 'Produit',
    'product.barcode': 'Code-barres (texte)',
    'warranty.months': 'Durée (mois)',
    'warranty.end': 'Fin de garantie',
  },
};

/// Sample values used by the designer's preview.
const Map<String, String> tplSampleData = {
  'product.name': 'Mixeur Moulinex 700W',
  'product.name_ar': 'خلاط مولينكس 700 واط',
  'product.price': '7 900,00 DA',
  'product.barcode': '2001234567893',
  'shop.name': 'Mon commerce',
  'shop.address': '12 rue Didouche Mourad, Alger',
  'shop.phone': '0555 12 34 56',
  'shop.nif': '000000000000000',
  'shop.rc': '00/00-0000000',
  'shop.ai': '00000000000',
  'doc.title': 'FACTURE',
  'doc.number': 'FA-2026-000042',
  'doc.date': '2026-08-30',
  'client.name': 'SARL Exemple',
  'client.address': 'Zone industrielle, Blida',
  'client.nif': '000000000000000',
  'client.rc': '00/00-0000000',
  'total.ht': '13 445,38 DA',
  'total.vat': '2 554,62 DA',
  'total.timbre': '160,00 DA',
  'total.ttc': '16 160,00 DA',
  'total.lettres': 'seize mille cent soixante dinars',
  'warranty.months': '12',
  'warranty.end': '2027-08-30',
  'date': '2026-08-30',
};
