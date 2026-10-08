import 'package:flutter/foundation.dart';

/// A one-shot instruction sent by the menu to a module screen: the sidebar
/// sub-item « Produits ▸ Nouveau produit » sets `new`, the screen performs it
/// and calls [done]. Each module screen receives its own channel.
///
/// Commands per module (strings, so the shell and the screens stay loosely
/// coupled):
/// - products : `list` · `new` · `categories` · `labels` · `import`
/// - stock    : `tab:levels` · `tab:ledger` · `inventory` · `tab:transfers`
///              · `tab:reorder` · `tab:lots` · `tab:adjustments`
/// - sales    : `list` · `new:SALE_INVOICE` · `type:QUOTE` · `type:DELIVERY_NOTE`
///              · `type:SALE_CREDIT_NOTE` · `type:SALE_TICKET`
/// - purchases: `list` · `new:PURCHASE_RECEIPT` · `type:PURCHASE_ORDER`
///              · `type:PURCHASE_INVOICE` · `type:PURCHASE_CREDIT_NOTE`
/// - partners : `kind:customer` · `kind:supplier` · `new:customer` · `new:supplier`
class ScreenCommand extends ValueNotifier<String?> {
  ScreenCommand() : super(null);

  /// Sends [command] even if it equals the previous one.
  void send(String command) {
    value = null;
    value = command;
  }

  void done() => value = null;
}
