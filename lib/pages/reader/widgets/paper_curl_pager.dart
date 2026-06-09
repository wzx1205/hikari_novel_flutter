import 'dart:math' as math;

import 'package:flutter/material.dart';

class PaperCurlPagerController {
  void Function(int target)? _jumpTo;

  void _bind(void Function(int target) jumpTo) {
    _jumpTo = jumpTo;
  }

  void _unbind(void Function(int target) jumpTo) {
    if (_jumpTo == jumpTo) {
      _jumpTo = null;
    }
  }

  void jumpToPage(int target) {
    _jumpTo?.call(target);
  }
}

class PaperCurlPager extends StatefulWidget {
  const PaperCurlPager({
    super.key,
    this.controller,
    required this.pages,
    required this.initialIndex,
    this.interactivePageIndices = const <int>{},
    this.reverse = false,
    this.duration = const Duration(milliseconds: 520),
    this.animationEnabled = true,
    this.backgroundColor,
    this.backsideColor,
    this.onIndexChanged,
    this.onCenterTap,
    this.onReachStart,
    this.onReachEnd,
    this.edgeTapWidthFactor = 0.28,
  });

  final PaperCurlPagerController? controller;
  final List<Widget> pages;
  final int initialIndex;
  final Set<int> interactivePageIndices;
  final bool reverse;
  final Duration duration;
  final bool animationEnabled;
  final Color? backgroundColor;
  final Color? backsideColor;
  final ValueChanged<int>? onIndexChanged;
  final VoidCallback? onCenterTap;
  final VoidCallback? onReachStart;
  final VoidCallback? onReachEnd;
  final double edgeTapWidthFactor;

  @override
  State<PaperCurlPager> createState() => _PaperCurlPagerState();
}

class _PaperCurlPagerState extends State<PaperCurlPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  Size _size = Size.zero;
  Offset _downPos = Offset.zero;
  Offset _dragPos = Offset.zero;
  Offset _animStartPos = Offset.zero;
  Offset _animEndPos = Offset.zero;
  bool _fromTop = false;
  bool _isDragging = false;
  bool _isAnimating = false;
  bool _turningForward = true;
  int _index = 0;
  int? _targetIndex;
  double _progress = 0;
  double _dragDelta = 0;
  Curve _releaseCurve = Curves.easeInOutCubic;

  int get _lastIndex => widget.pages.isEmpty ? 0 : widget.pages.length - 1;

  int get _forwardDelta => widget.reverse ? -1 : 1;

  int get _backwardDelta => -_forwardDelta;

  bool get _currentPageInteractive =>
      widget.interactivePageIndices.contains(_index);

  bool get _canGoForward =>
      widget.pages.isNotEmpty && _targetForDirection(true) != _index;

  bool get _canGoBackward =>
      widget.pages.isNotEmpty && _targetForDirection(false) != _index;

  @override
  void initState() {
    super.initState();
    _index = _safeIndex(widget.initialIndex);
    _controller = AnimationController(vsync: this, duration: _effectiveDuration)
      ..addListener(_handleTick)
      ..addStatusListener(_handleStatus);
    widget.controller?._bind(_jumpToExternal);
  }

  @override
  void didUpdateWidget(covariant PaperCurlPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._unbind(_jumpToExternal);
      widget.controller?._bind(_jumpToExternal);
    }
    final newDuration = _effectiveDuration;
    if (_controller.duration != newDuration) {
      _controller.duration = newDuration;
    }
    final safeInitial = _safeIndex(widget.initialIndex);
    final shouldReset =
        widget.pages.length != oldWidget.pages.length || safeInitial != _index;
    if (!_isDragging && !_isAnimating && shouldReset) {
      _index = safeInitial;
      _resetGestureState(notify: false);
    }
  }

  @override
  void dispose() {
    widget.controller?._unbind(_jumpToExternal);
    _controller.dispose();
    super.dispose();
  }

  Duration get _effectiveDuration => widget.animationEnabled
      ? widget.duration
      : const Duration(milliseconds: 1);

  int _safeIndex(int raw) {
    if (widget.pages.isEmpty) return 0;
    return raw.clamp(0, widget.pages.length - 1);
  }

  int _targetForDirection(bool forward) {
    if (widget.pages.isEmpty) return 0;
    final delta = forward ? _forwardDelta : _backwardDelta;
    return (_index + delta).clamp(0, _lastIndex);
  }

  void _jumpToExternal(int target) {
    final safeTarget = _safeIndex(target);
    if (_index == safeTarget && !_isAnimating && !_isDragging) {
      return;
    }
    _controller.stop();
    _index = safeTarget;
    _resetGestureState();
    widget.onIndexChanged?.call(_index);
  }

  void _resetGestureState({bool notify = true}) {
    _isDragging = false;
    _isAnimating = false;
    _turningForward = true;
    _targetIndex = null;
    _progress = 0;
    _dragDelta = 0;
    _downPos = Offset.zero;
    _dragPos = Offset.zero;
    _animStartPos = Offset.zero;
    _animEndPos = Offset.zero;
    if (notify && mounted) {
      setState(() {});
    }
  }

  void _handleTick() {
    if (!_isAnimating) return;
    final t = _releaseCurve.transform(_controller.value);
    setState(() {
      _dragPos = Offset(
        _lerp(_animStartPos.dx, _animEndPos.dx, t),
        _lerp(_animStartPos.dy, _animEndPos.dy, t),
      );
      _dragDelta = _dragPos.dx - _downPos.dx;
      _progress = _progressForCurrentDrag();
    });
  }

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final didComplete =
        _targetIndex != null &&
        (_turningForward
            ? _dragPos.dx <= 0.5
            : _dragPos.dx >= _size.width - 0.5);
    if (didComplete) {
      _index = _targetIndex!;
      widget.onIndexChanged?.call(_index);
    }
    _resetGestureState();
  }

  void _ensureSize(Size size) {
    if (_size == size) return;
    _size = size;
  }

  Offset _logicalOffset(Offset physical) {
    if (!widget.reverse || _size.width <= 0) return physical;
    return Offset(
      (_size.width - physical.dx).clamp(0.0, _size.width),
      physical.dy,
    );
  }

  void _startGesture({required bool forward, required Offset localPos}) {
    _turningForward = forward;
    _targetIndex = _targetForDirection(forward);
    _fromTop = localPos.dy <= (_size.height / 2);
    _isDragging = true;
    _isAnimating = false;
    _downPos = localPos;
    _dragPos = localPos;
    _dragDelta = 0;
    _progress = 0;
  }

  double _progressForCurrentDrag() {
    if (_size.width <= 0) return 0;
    return (_dragDelta.abs() / _size.width).clamp(0.0, 1.0);
  }

  void _updateDrag(Offset localPos) {
    _dragPos = Offset(
      localPos.dx.clamp(0.0, _size.width),
      localPos.dy.clamp(0.0, _size.height),
    );
    _dragDelta = _dragPos.dx - _downPos.dx;
    _progress = _progressForCurrentDrag();
  }

  Offset _releaseTarget(bool complete) {
    final targetX = complete
        ? (_turningForward ? 0.0 : _size.width)
        : _downPos.dx;
    final targetY = _fromTop ? _size.height * 0.18 : _size.height * 0.82;
    return Offset(targetX, targetY);
  }

  void _animateRelease({required bool complete, required Curve curve}) {
    _isDragging = false;
    _isAnimating = true;
    _releaseCurve = curve;
    _animStartPos = _dragPos;
    _animEndPos = _releaseTarget(complete);
    _controller.forward(from: 0);
  }

  void _animateTapTurn(bool forward, {required bool fromTop}) {
    if ((forward && !_canGoForward) || (!forward && !_canGoBackward)) {
      return;
    }
    final startX = forward ? _size.width * 0.92 : _size.width * 0.08;
    final startY = fromTop ? _size.height * 0.18 : _size.height * 0.82;
    _startGesture(forward: forward, localPos: Offset(startX, startY));
    _dragPos = Offset(
      forward ? _size.width * 0.76 : _size.width * 0.24,
      startY,
    );
    _dragDelta = _dragPos.dx - _downPos.dx;
    _progress = _progressForCurrentDrag();
    _animateRelease(complete: true, curve: Curves.easeInOutCubic);
  }

  void _handleTap(TapUpDetails details) {
    if (_size.width <= 0 || _size.height <= 0) return;
    if (_currentPageInteractive) return;
    final pos = _logicalOffset(details.localPosition);
    final left = _size.width * widget.edgeTapWidthFactor;
    final right = _size.width * (1 - widget.edgeTapWidthFactor);
    final fromTop = pos.dy <= (_size.height / 2);
    if (pos.dx <= left) {
      if (!_canGoBackward) {
        widget.onReachStart?.call();
      } else {
        setState(() {
          _animateTapTurn(false, fromTop: fromTop);
        });
      }
      return;
    }
    if (pos.dx >= right) {
      if (!_canGoForward) {
        widget.onReachEnd?.call();
      } else {
        setState(() {
          _animateTapTurn(true, fromTop: fromTop);
        });
      }
      return;
    }
    widget.onCenterTap?.call();
  }

  void _handlePanDown(DragDownDetails details) {
    if (_size.width <= 0 || _size.height <= 0) return;
    _controller.stop();
    _isAnimating = false;
    final localPos = _logicalOffset(details.localPosition);
    _downPos = localPos;
    _dragPos = localPos;
    _dragDelta = 0;
    _progress = 0;
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (widget.pages.isEmpty || _size.width <= 0 || _size.height <= 0) {
      return;
    }
    final localPos = _logicalOffset(details.localPosition);
    if (!_isDragging) {
      final delta = localPos - _downPos;
      if (delta.distanceSquared < 16) {
        return;
      }
      final forward = delta.dx < 0;
      if (forward && !_canGoForward) {
        widget.onReachEnd?.call();
        return;
      }
      if (!forward && !_canGoBackward) {
        widget.onReachStart?.call();
        return;
      }
      setState(() {
        _startGesture(forward: forward, localPos: _downPos);
        _updateDrag(localPos);
      });
      return;
    }
    setState(() {
      _updateDrag(localPos);
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    if (!_isDragging) return;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final logicalVelocity = widget.reverse ? -velocity : velocity;
    final flingForward = logicalVelocity < -500;
    final flingBackward = logicalVelocity > 500;
    final shouldComplete = _turningForward
        ? (_progress > 0.2 || (_progress > 0.05 && flingForward))
        : (_progress > 0.2 || (_progress > 0.05 && flingBackward));
    _animateRelease(
      complete: shouldComplete,
      curve: shouldComplete ? Curves.easeInOutCubic : Curves.easeOutQuart,
    );
  }

  Widget _pageAt(int index) {
    if (widget.pages.isEmpty || index < 0 || index >= widget.pages.length) {
      return const SizedBox.shrink();
    }
    final background =
        widget.backgroundColor ?? Theme.of(context).colorScheme.surface;
    Widget page = ColoredBox(
      color: background,
      child: SizedBox.expand(child: widget.pages[index]),
    );
    if (widget.reverse) {
      page = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: page,
      );
    }
    return page;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensureSize(Size(constraints.maxWidth, constraints.maxHeight));
        final background =
            widget.backgroundColor ?? Theme.of(context).colorScheme.surface;
        final backside =
            widget.backsideColor ??
            Color.lerp(
              background,
              Colors.black,
              Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.08,
            )!;
        final showTurn =
            (_isDragging || _isAnimating) &&
            _targetIndex != null &&
            _progress > 0.0001;
        final underIndex = showTurn ? _targetIndex! : _index;
        final fold = _FoldGeometry.fromDrag(
          size: _size,
          dragPos: _dragPos,
          progress: _progress,
          forward: _turningForward,
          fromTop: _fromTop,
        );

        Widget child = DecoratedBox(
          decoration: BoxDecoration(color: background),
          child: ClipRect(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _handleTap,
              onPanDown: _handlePanDown,
              onPanUpdate: _handlePanUpdate,
              onPanEnd: _handlePanEnd,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: background, child: const SizedBox.expand()),
                  _pageAt(underIndex),
                  if (showTurn)
                    CustomPaint(
                      painter: _FoldShadowPainter(
                        geometry: fold,
                        shadowColor: Colors.black.withOpacity(
                          Theme.of(context).brightness == Brightness.dark
                              ? 0.34
                              : 0.22,
                        ),
                      ),
                    ),
                  if (showTurn)
                    ClipPath(
                      clipper: _PageRevealClipper(fold),
                      child: _pageAt(_index),
                    )
                  else
                    _pageAt(_index),
                  if (showTurn)
                    IgnorePointer(
                      child: ClipPath(
                        clipper: _FoldFrontClipper(fold),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: _turningForward
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              end: _turningForward
                                  ? Alignment.centerLeft
                                  : Alignment.centerRight,
                              colors: [
                                backside.withOpacity(0.96),
                                Color.lerp(backside, background, 0.48)!,
                                Color.lerp(background, Colors.white, 0.08)!,
                              ],
                              stops: const [0.0, 0.6, 1.0],
                            ),
                          ),
                          child: CustomPaint(
                            painter: _FoldHighlightPainter(
                              geometry: fold,
                              shadowColor: Colors.black.withOpacity(0.10),
                              highlightColor: Colors.white.withOpacity(0.24),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );

        if (widget.reverse) {
          child = Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(-1, 1, 1),
            child: child,
          );
        }
        return child;
      },
    );
  }
}

class _FoldGeometry {
  const _FoldGeometry({
    required this.size,
    required this.progress,
    required this.forward,
    required this.fromTop,
    required this.foldX,
    required this.spineX,
    required this.controlY,
    required this.depth,
    required this.shadowWidth,
  });

  final Size size;
  final double progress;
  final bool forward;
  final bool fromTop;
  final double foldX;
  final double spineX;
  final double controlY;
  final double depth;
  final double shadowWidth;

  static _FoldGeometry fromDrag({
    required Size size,
    required Offset dragPos,
    required double progress,
    required bool forward,
    required bool fromTop,
  }) {
    final safeWidth = size.width <= 0 ? 1.0 : size.width;
    final safeHeight = size.height <= 0 ? 1.0 : size.height;
    final clampedProgress = progress.clamp(0.0, 1.0);
    final foldX = dragPos.dx.clamp(0.0, safeWidth);
    final depth = math.max(8.0, math.min(18.0, 8.0 + safeWidth * 0.028));
    final spineX = forward
        ? math.min(safeWidth, foldX + depth)
        : math.max(0.0, foldX - depth);
    final anchorY = dragPos.dy.clamp(0.0, safeHeight);
    final settleY = fromTop ? safeHeight * 0.5 : safeHeight * 0.5;
    final controlY = _lerp(anchorY, settleY, 0.72).clamp(0.0, safeHeight);
    final shadowWidth = math.max(12.0, 40.0 * clampedProgress);
    return _FoldGeometry(
      size: size,
      progress: clampedProgress,
      forward: forward,
      fromTop: fromTop,
      foldX: foldX,
      spineX: spineX,
      controlY: controlY,
      depth: depth,
      shadowWidth: shadowWidth,
    );
  }

  Path get frontPath {
    final outerX = forward ? foldX + depth : foldX - depth;
    return Path()
      ..moveTo(foldX, 0)
      ..quadraticBezierTo(spineX, controlY, foldX, size.height)
      ..lineTo(outerX, size.height)
      ..quadraticBezierTo(spineX, controlY, outerX, 0)
      ..close();
  }

  Path get revealPath {
    if (forward) {
      return Path()..addRect(Rect.fromLTWH(0, 0, foldX, size.height));
    }
    return Path()
      ..addRect(Rect.fromLTWH(foldX, 0, size.width - foldX, size.height));
  }
}

class _PageRevealClipper extends CustomClipper<Path> {
  const _PageRevealClipper(this.geometry);

  final _FoldGeometry geometry;

  @override
  Path getClip(Size size) => geometry.revealPath;

  @override
  bool shouldReclip(covariant _PageRevealClipper oldClipper) =>
      oldClipper.geometry != geometry;
}

class _FoldFrontClipper extends CustomClipper<Path> {
  const _FoldFrontClipper(this.geometry);

  final _FoldGeometry geometry;

  @override
  Path getClip(Size size) => geometry.frontPath;

  @override
  bool shouldReclip(covariant _FoldFrontClipper oldClipper) =>
      oldClipper.geometry != geometry;
}

class _FoldShadowPainter extends CustomPainter {
  const _FoldShadowPainter({required this.geometry, required this.shadowColor});

  final _FoldGeometry geometry;
  final Color shadowColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.progress <= 0) return;
    final rect = geometry.forward
        ? Rect.fromLTWH(geometry.foldX, 0, geometry.shadowWidth, size.height)
        : Rect.fromLTWH(
            geometry.foldX - geometry.shadowWidth,
            0,
            geometry.shadowWidth,
            size.height,
          );
    final paint = Paint()
      ..shader = LinearGradient(
        begin: geometry.forward ? Alignment.centerLeft : Alignment.centerRight,
        end: geometry.forward ? Alignment.centerRight : Alignment.centerLeft,
        colors: [
          shadowColor.withOpacity(0.4 * geometry.progress),
          shadowColor.withOpacity(0.1 * geometry.progress),
          shadowColor.withOpacity(0.0),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);

    final edgePaint = Paint()
      ..color = shadowColor.withOpacity(0.3 * geometry.progress)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    final edgePath = Path()
      ..moveTo(geometry.foldX, 0)
      ..lineTo(geometry.foldX + (geometry.forward ? 3 : -3), 0)
      ..lineTo(geometry.foldX + (geometry.forward ? 3 : -3), size.height)
      ..lineTo(geometry.foldX, size.height)
      ..close();
    canvas.drawPath(edgePath, edgePaint);
  }

  @override
  bool shouldRepaint(covariant _FoldShadowPainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.shadowColor != shadowColor;
}

class _FoldHighlightPainter extends CustomPainter {
  const _FoldHighlightPainter({
    required this.geometry,
    required this.shadowColor,
    required this.highlightColor,
  });

  final _FoldGeometry geometry;
  final Color shadowColor;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.progress <= 0) return;

    final edgeRect = geometry.forward
        ? Rect.fromLTWH(geometry.foldX, 0, 15, size.height)
        : Rect.fromLTWH(geometry.foldX - 15, 0, 15, size.height);
    final edgeHighlightPaint = Paint()
      ..shader = LinearGradient(
        begin: geometry.forward ? Alignment.centerLeft : Alignment.centerRight,
        end: geometry.forward ? Alignment.centerRight : Alignment.centerLeft,
        colors: [
          highlightColor.withOpacity(0.9),
          highlightColor.withOpacity(0.0),
        ],
      ).createShader(edgeRect);
    canvas.drawRect(edgeRect, edgeHighlightPaint);

    final foldRect = geometry.forward
        ? Rect.fromLTWH(geometry.foldX, 0, geometry.depth, size.height)
        : Rect.fromLTWH(
            geometry.foldX - geometry.depth,
            0,
            geometry.depth,
            size.height,
          );
    final foldShadePaint = Paint()
      ..shader = LinearGradient(
        begin: geometry.forward ? Alignment.centerLeft : Alignment.centerRight,
        end: geometry.forward ? Alignment.centerRight : Alignment.centerLeft,
        colors: [
          highlightColor.withOpacity(0.7 * geometry.progress),
          shadowColor.withOpacity(0.06 * geometry.progress),
        ],
      ).createShader(foldRect);
    canvas.drawRect(foldRect, foldShadePaint);
  }

  @override
  bool shouldRepaint(covariant _FoldHighlightPainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.shadowColor != shadowColor ||
      oldDelegate.highlightColor != highlightColor;
}

double _lerp(num a, num b, double t) => a + (b - a) * t;
