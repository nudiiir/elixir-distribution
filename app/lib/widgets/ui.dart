import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// White card with hairline border — the standard Elixir surface.
class Card14 extends StatelessWidget {
  const Card14({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rCard),
        border: Border.all(color: T.border),
      ),
      child: child,
    );
  }
}

/// Field / column / section label. Plain words in normal case: a shopkeeper
/// reads « Prix de vente », not « PRIX DE VENTE » in a tiny mono font.
class MicroLabel extends StatelessWidget {
  const MicroLabel(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = text.isEmpty
        ? text
        : text.toUpperCase() == text && text.length > 1
            ? text[0] + text.substring(1).toLowerCase()
            : text;
    return Text(t, style: T.label.copyWith(color: color));
  }
}

/// Mint chip with mono label — like the PRIX/QTE chips on the Elixir website.
class MintChip extends StatelessWidget {
  const MintChip(this.text, {super.key, this.color = T.mint, this.fg = T.ink});
  final String text;
  final Color color;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: T.label.copyWith(color: fg, fontSize: 12)),
    );
  }
}

/// Solid primary button (mint) in the Elixir style.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.color = T.mint,
    this.fg = T.ink,
    this.big = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color fg;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: big ? 54 : 44,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: T.border2,
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rInner)),
          textStyle: TextStyle(
            fontFamily: T.sans,
            fontSize: big ? 16 : 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// Standard search field, keyboard-first.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    this.hint = 'Rechercher…',
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rInner),
        border: Border.all(color: T.border),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: T.body,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hint,
          hintStyle: T.bodyMuted.copyWith(color: T.ghost),
          prefixIcon: const Icon(Icons.search, size: 18, color: T.faint),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

/// Empty list / screen. Give it [actions] so the user always sees the next
/// step (« Importer un fichier », « Nouveau produit »…).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.actions = const [],
  });
  final IconData icon;
  final String text;
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: T.ghost),
          const SizedBox(height: 10),
          Text(text, style: T.bodyMuted, textAlign: TextAlign.center),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              for (var i = 0; i < actions.length; i++)
                i == actions.length - 1
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: T.mint, foregroundColor: T.ink),
                        onPressed: actions[i].$2,
                        child: Text(actions[i].$1),
                      )
                    : OutlinedButton(
                        onPressed: actions[i].$2,
                        child: Text(actions[i].$1),
                      ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// Grey shimmer-free placeholder bar for loading states.
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({super.key, this.width = 120, this.height = 10});
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: T.border2,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
}
