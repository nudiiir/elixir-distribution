import 'package:flutter/material.dart';

import '../api/client.dart';
import '../theme/tokens.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart';
import '../widgets/ui.dart';

const _saleTypes = [
  'SALE_TICKET',
  'SALE_INVOICE',
  'QUOTE',
  'DELIVERY_NOTE',
  'SALE_CREDIT_NOTE',
];

DocEditorConfig? saleEditorFor(String docType) => switch (docType) {
      'SALE_INVOICE' => saleInvoiceConfig,
      'QUOTE' => quoteConfig,
      'DELIVERY_NOTE' => deliveryNoteConfig,
      'SALE_CREDIT_NOTE' => saleCreditNoteConfig,
      _ => null,
    };

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  final _listKey = GlobalKey<DocListPaneState>();
  Map<String, String> _partnerNames = const {};

  @override
  void initState() {
    super.initState();
    _loadPartners();
  }

  Future<void> _loadPartners() async {
    try {
      final ps = await widget.api.partners(limit: 500);
      if (mounted) {
        setState(() => _partnerNames = {for (final p in ps) p.id: p.name});
      }
    } catch (_) {}
  }

  Future<void> _newDoc(DocEditorConfig cfg) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DocEditorScreen(api: widget.api, config: cfg),
    ));
    if (changed == true) _listKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Ventes', style: T.h1)),
            _NewMenu(onPick: _newDoc, items: const [
              (label: 'Devis', cfg: quoteConfig),
              (label: 'Bon de livraison', cfg: deliveryNoteConfig),
              (label: 'Avoir client', cfg: saleCreditNoteConfig),
            ]),
            const SizedBox(width: 8),
            SizedBox(
              width: 170,
              child: PrimaryButton(
                label: 'Nouvelle facture',
                onPressed: () => _newDoc(saleInvoiceConfig),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: DocListPane(
              key: _listKey,
              api: widget.api,
              allTypes: _saleTypes,
              partnerNames: _partnerNames,
              editorFor: saleEditorFor,
              exportName: 'ventes',
            ),
          ),
        ],
      ),
    );
  }
}

class _NewMenu extends StatelessWidget {
  const _NewMenu({required this.onPick, required this.items});
  final void Function(DocEditorConfig) onPick;
  final List<({String label, DocEditorConfig cfg})> items;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<DocEditorConfig>(
      tooltip: 'Autres documents',
      color: T.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rInner)),
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final it in items)
          PopupMenuItem(
              value: it.cfg, child: Text(it.label, style: T.body)),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rInner),
          border: Border.all(color: T.border3),
        ),
        child: const Row(children: [
          Text('Autres',
              style: TextStyle(
                  fontFamily: T.sans,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: T.muted)),
          SizedBox(width: 6),
          Icon(Icons.expand_more, size: 16, color: T.faint),
        ]),
      ),
    );
  }
}
