import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Shared building blocks for the redesigned screens.
///
/// Small on purpose: a card, a section heading, a stat, a pill, a banner and
/// two motion helpers. Every premium screen is built from these, so spacing,
/// radii and colour stay identical from one screen to the next -- which is
/// most of what makes an app feel finished.

/// A white rounded surface with a hairline border and a soft lift.
class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Gradient? gradient;
  final double radius;
  final bool shadow;
  final BorderSide? border;

  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.gradient,
    this.radius = AppTheme.radiusLarge - 4,
    this.shadow = true,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: border ??
          (gradient != null
              ? BorderSide.none
              : const BorderSide(color: AppTheme.line)),
    );

    final content = Padding(padding: padding, child: child);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow ? AppTheme.softShadow : null,
      ),
      child: Material(
        color: gradient == null ? (color ?? AppTheme.surface) : null,
        type:
            gradient == null ? MaterialType.canvas : MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: gradient == null
              ? null
              : BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(radius),
                ),
          child: onTap == null
              ? content
              : InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
                  child: content,
                ),
        ),
      ),
    );
  }
}

/// A heading above a group of cards: small caps eyebrow, bold title, and an
/// optional action on the right.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? eyebrow;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, 24, 4, 12),
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Text(eyebrow!.toUpperCase(), style: text.labelSmall),
                  const SizedBox(height: 4),
                ],
                Text(title, style: text.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: text.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A rounded square holding an icon on a tint of its own colour.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final Color? background;

  const IconBadge({
    super.key,
    required this.icon,
    this.color = AppTheme.primaryBright,
    this.size = 44,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(icon, color: color, size: size * 0.52),
    );
  }
}

/// One figure with its label: the building block of every summary row.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? caption;
  final IconData? icon;
  final Color color;
  final bool onDark;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon,
    this.color = AppTheme.primaryBright,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueColour = onDark ? Colors.white : AppTheme.textPrimary;
    final labelColour =
        onDark ? Colors.white.withValues(alpha: 0.72) : AppTheme.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: onDark ? Colors.white70 : color),
          const SizedBox(height: 8),
        ],
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: valueColour,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: labelColour,
          ),
        ),
        if (caption != null)
          Text(
            caption!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: onDark
                  ? Colors.white.withValues(alpha: 0.55)
                  : AppTheme.textTertiary,
            ),
          ),
      ],
    );
  }
}

/// A small rounded label: a status, a count, a category.
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool filled;
  final bool dot;

  const Pill({
    super.key,
    required this.text,
    this.color = AppTheme.primaryBright,
    this.icon,
    this.filled = false,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = filled ? Colors.white : color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(color: foreground, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// A tinted message block with an icon, a title and a body.
class InfoBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? body;
  final Widget? action;

  const InfoBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (body != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    body!,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: 10),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades and lifts its child into place once, after [delay].
///
/// Used to stagger a screen's cards so it assembles rather than pops. Runs
/// exactly once and then leaves the child alone -- it never loops, so it can
/// never keep a test's pumpAndSettle waiting.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final double offset;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 18,
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  static const _run = Duration(milliseconds: 420);

  // The delay is part of the animation itself rather than a timer: a timer
  // outliving its widget is a leak, and in tests a pending one is a failure.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _run + widget.delay,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      widget.delay.inMicroseconds / (_run + widget.delay).inMicroseconds,
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - _curve.value)),
          child: child,
        ),
      ),
    );
  }
}

/// Shrinks its child slightly while a finger is on it: the small physical
/// response that makes a tile feel like a button rather than a picture.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A full-width primary action with an optional busy state.
class PrimaryAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  final bool outlined;

  const PrimaryAction({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final spinner = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: outlined ? AppTheme.primary : Colors.white,
      ),
    );

    final iconWidget = busy ? spinner : (icon == null ? null : Icon(icon));
    final onTap = busy ? null : onPressed;

    final button = outlined
        ? (iconWidget == null
            ? OutlinedButton(onPressed: onTap, child: Text(label))
            : OutlinedButton.icon(
                onPressed: onTap,
                icon: iconWidget,
                label: Text(label),
              ))
        : (iconWidget == null
            ? FilledButton(onPressed: onTap, child: Text(label))
            : FilledButton.icon(
                onPressed: onTap,
                icon: iconWidget,
                label: Text(label),
              ));

    return SizedBox(
      width: double.infinity,
      height: outlined ? 50 : 54,
      child: button,
    );
  }
}

/// A key/value line for a details table.
class DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool emphasise;

  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.emphasise = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: emphasise ? 15.5 : 14,
                    fontWeight: emphasise ? FontWeight.w800 : FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
