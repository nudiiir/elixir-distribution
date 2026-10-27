import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// One step of the breadcrumb (« Produits / Coca-Cola 1L »).
class Crumb {
  const Crumb(this.label, [this.onTap]);
  final String label;
  final VoidCallback? onTap;
}

/// A labelled action button of a page header. Exactly one per page should be
/// [primary] (mint); the others are neutral outlined buttons — always with a
/// word, never an icon alone.
class PageAction extends StatelessWidget {
  const PageAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.danger = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final child = Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 7)],
      Text(label),
    ]);
    const text = TextStyle(fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w700);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(T.rInner));
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: SizedBox(
        height: 42,
        child: primary
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger ? T.danger : T.mint,
                  foregroundColor: danger ? Colors.white : T.ink,
                  disabledBackgroundColor: T.border2,
                  textStyle: text,
                  shape: shape,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: onPressed,
                child: child,
              )
            : OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: danger ? T.dangerDark : T.ink,
                  backgroundColor: T.surface,
                  side: BorderSide(color: danger ? T.danger : T.border3),
                  textStyle: text,
                  shape: shape,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: onPressed,
                child: child,
              ),
      ),
    );
  }
}

/// The standard frame of every detail / edit page: breadcrumb, « Retour »,
/// title + subtitle, labelled actions on the right, scrolling body.
/// Pushed inside the module's own navigator, so the menu stays visible.
/// Escape = « Retour » (through [onBack] or a plain pop).
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.crumbs,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.onBack,
    this.scroll = true,
    this.maxWidth = 1180,
    this.bottomBar,
  });

  final List<Crumb> crumbs;
  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final Widget body;

  /// Called by « Retour » and Escape. Null = Navigator.maybePop.
  final VoidCallback? onBack;

  /// False when the body manages its own scrolling (lists, editors).
  final bool scroll;
  final double maxWidth;

  /// Pinned at the bottom (totals bar, save bar…).
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    void back() => onBack != null ? onBack!() : Navigator.of(context).maybePop();
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: T.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontFamily: T.sans, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: back,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Retour'),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 18, color: T.border3),
          const SizedBox(width: 12),
          Flexible(
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.chevron_right_rounded, size: 16, color: T.ghost),
                  ),
                InkWell(
                  onTap: crumbs[i].onTap,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    child: Text(crumbs[i].label,
                        style: T.body.copyWith(
                          fontSize: 14,
                          color: crumbs[i].onTap != null ? T.mintDark : T.muted,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                ),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.h1, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[const SizedBox(height: 6), subtitle!],
            ]),
          ),
          ...actions,
        ]),
      ]),
    );
    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          child: body,
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): back},
      child: Focus(
        autofocus: true,
        child: Material(
          color: T.bg,
          child: Column(children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth + 56),
                child: header,
              ),
            ),
            Expanded(
              child: scroll ? SingleChildScrollView(child: content) : content,
            ),
            ?bottomBar,
          ]),
        ),
      ),
    );
  }
}

/// A titled block of a detail page (« Informations », « Stock par dépôt »…).
class PageSection extends StatelessWidget {
  const PageSection({super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: T.h2)),
          ?trailing,
        ]),
        const SizedBox(height: 14),
        child,
      ]),
    );
  }
}

/// « Libellé : valeur » rows for detail pages (two columns of facts).
class FactGrid extends StatelessWidget {
  const FactGrid({super.key, required this.facts, this.columns = 2});
  final List<(String, String)> facts;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - (columns - 1) * 24) / columns;
      return Wrap(spacing: 24, runSpacing: 14, children: [
        for (final (k, v) in facts)
          SizedBox(
            width: w,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k, style: T.label),
              const SizedBox(height: 3),
              Text(v.isEmpty ? '—' : v, style: T.body),
            ]),
          ),
      ]);
    });
  }
}
