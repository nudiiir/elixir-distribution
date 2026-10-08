import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../util/commands.dart';
import '../widgets/doc_editor.dart';
import '../widgets/doc_list.dart';
import '../widgets/list_toolbar.dart';

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

/// Ventes. Menu commands: `list` · `new:SALE_INVOICE` · `type:QUOTE` ·
/// `type:DELIVERY_NOTE` · `type:SALE_CREDIT_NOTE` · `type:SALE_TICKET`.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key, required this.api, this.command});
  final ApiClient api;
  final ScreenCommand? command;

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
    widget.command?.addListener(_onCommand);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCommand());
  }

  @override
  void didUpdateWidget(SalesScreen old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) {
      old.command?.removeListener(_onCommand);
      widget.command?.addListener(_onCommand);
    }
  }

  @override
  void dispose() {
    widget.command?.removeListener(_onCommand);
    super.dispose();
  }

  void _onCommand() {
    final cmd = widget.command?.value;
    if (cmd == null || !mounted) return;
    widget.command!.done();
    if (!popToModuleRoot(context)) return;
    if (cmd == 'list') {
      _listKey.currentState?.setType(null);
    } else if (cmd.startsWith('type:')) {
      _listKey.currentState?.setType(cmd.substring(5));
    } else if (cmd.startsWith('new:')) {
      final cfg = saleEditorFor(cmd.substring(4));
      if (cfg != null) _newDoc(cfg);
    }
  }

  Future<void> _loadPartners() async {
    try {
      final ps = await widget.api.partners(limit: 500);
      if (mounted) {
        setState(() => _partnerNames = {for (final p in ps) p.id: p.name});
      }
    } catch (_) {}
  }

  Future<void> _newDoc(DocEditorConfig cfg, {Partner? partner}) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          DocEditorScreen(api: widget.api, config: cfg, initialPartner: partner),
    ));
    if (changed == true) {
      _loadPartners();
      _listKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: 'Ventes',
            primaryLabel: 'Nouvelle facture',
            onPrimary: () => _newDoc(saleInvoiceConfig),
            more: [
              MenuEntry('Nouveau devis', Icons.request_quote_outlined,
                  () => _newDoc(quoteConfig)),
              MenuEntry('Nouveau bon de livraison', Icons.local_shipping_outlined,
                  () => _newDoc(deliveryNoteConfig)),
              MenuEntry('Nouvel avoir client', Icons.assignment_return_outlined,
                  () => _newDoc(saleCreditNoteConfig)),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DocListPane(
              key: _listKey,
              api: widget.api,
              allTypes: _saleTypes,
              quickTypes: const ['SALE_INVOICE', 'QUOTE', 'DELIVERY_NOTE'],
              partnerNames: _partnerNames,
              partnerKind: 'customer',
              editorFor: saleEditorFor,
              exportName: 'ventes',
              exportTitle: 'Ventes',
              prefsKey: 'sales',
              emptyActions: [
                ('Nouveau devis', () => _newDoc(quoteConfig)),
                ('Nouvelle facture', () => _newDoc(saleInvoiceConfig)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
