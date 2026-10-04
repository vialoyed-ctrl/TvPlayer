import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_theme.dart';

class TvFocusWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final double scale;
  final double borderRadius;
  final Color focusBorderColor;
  final bool showGlow;
  final EdgeInsetsGeometry? padding;
  final ValueChanged<bool>? onFocusChange;

  const TvFocusWidget({
    super.key,
    required this.child,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.scale = 1.06,
    this.borderRadius = 12.0,
    this.focusBorderColor = TvTheme.primary,
    this.showGlow = true,
    this.padding,
    this.onFocusChange,
  });

  @override
  State<TvFocusWidget> createState() => _TvFocusWidgetState();
}

class _TvFocusWidgetState extends State<TvFocusWidget>
    with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;
  bool _isFocused = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: widget.scale).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );

    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    _animController.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hasFocus = _focusNode.hasFocus;
    setState(() {
      _isFocused = hasFocus;
    });
    if (hasFocus) {
      _animController.forward();
      // Auto-scroll focused element into view
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focusNode.hasFocus) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
    } else {
      _animController.reverse();
    }
    widget.onFocusChange?.call(hasFocus);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        widget.onTap?.call();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(scale: _scaleAnimation.value, child: child);
          },
          child: Container(
            padding: widget.padding,
            decoration: _isFocused && widget.showGlow
                ? TvTheme.focusDecoration(
                    borderRadius: widget.borderRadius,
                    focusColor: widget.focusBorderColor,
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                  ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
