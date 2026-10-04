import 'package:flutter/material.dart';

import '../models/textbook.dart';

/// The part of a contain-fitted image that actually has pixels on screen.
Rect containedImageRect(Size availableSize, Size imageSize) {
  if (availableSize.isEmpty || imageSize.isEmpty) return Rect.zero;
  final fitted = applyBoxFit(BoxFit.contain, imageSize, availableSize);
  return Alignment.center.inscribe(
    fitted.destination,
    Offset.zero & availableSize,
  );
}

class InteractiveTextbookPage extends StatefulWidget {
  const InteractiveTextbookPage({
    super.key,
    required this.page,
    required this.activeSentenceId,
    required this.onSentenceTap,
    this.activeBubbleId,
  });

  final TextbookPage page;
  final String? activeSentenceId;
  final String? activeBubbleId;
  final ValueChanged<PointSentence> onSentenceTap;

  @override
  State<InteractiveTextbookPage> createState() =>
      InteractiveTextbookPageState();
}

class InteractiveTextbookPageState extends State<InteractiveTextbookPage> {
  static const _placeholderSize = Size(3, 4);

  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  Size _imageSize = _placeholderSize;
  bool _imageAvailable = false;

  /// Uses the same hit geometry for a parent that interrupts PageView animation,
  /// when Flutter temporarily ignores the page's own gesture detector.
  PointSentence? sentenceAtGlobalPosition(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return _sentenceAtLocalPosition(
      box.globalToLocal(globalPosition),
      box.size,
    );
  }

  PointSentence? _sentenceAtLocalPosition(Offset touch, Size size) {
    final renderRect = containedImageRect(size, _imageSize);
    if (!renderRect.contains(touch)) return null;
    final x = (touch.dx - renderRect.left) / renderRect.width;
    final y = (touch.dy - renderRect.top) / renderRect.height;
    for (final sentence in widget.page.sentences) {
      final rect = sentence.rect;
      if (x >= rect.left &&
          x <= rect.right &&
          y >= rect.top &&
          y <= rect.bottom) {
        return sentence;
      }
    }
    // Precise sentence hot spots take priority; remaining bubble space selects
    // its first child in reading order.
    for (final bubble in widget.page.playbackBubbles) {
      final rect = bubble.rect;
      if (x >= rect.left &&
          x <= rect.right &&
          y >= rect.top &&
          y <= rect.bottom) {
        for (final id in bubble.sentenceIds) {
          for (final sentence in widget.page.sentences) {
            if (sentence.id == id) return sentence;
          }
        }
      }
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant InteractiveTextbookPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.imagePath != widget.page.imagePath) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
    _imageSize = _placeholderSize;
    _imageAvailable = false;
    if (widget.page.imagePath.isEmpty) return;

    final stream = AssetImage(widget.page.imagePath)
        .resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        if (!mounted || _imageStream != stream) return;
        void update() {
          _imageSize = Size(
            imageInfo.image.width.toDouble(),
            imageInfo.image.height.toDouble(),
          );
          _imageAvailable = true;
        }

        if (synchronousCall) {
          update();
        } else {
          setState(update);
        }
      },
      onError: (error, stackTrace) {
        if (!mounted || _imageStream != stream) return;
        setState(() {
          _imageSize = _placeholderSize;
          _imageAvailable = false;
        });
      },
    );
    _imageStream = stream;
    _imageListener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
        return const SizedBox.shrink();
      }
      final renderRect = containedImageRect(size, _imageSize);
      NormalizedRect? activeRect;
      String? activeId;
      var isBubbleHighlight = false;
      for (final bubble in widget.page.playbackBubbles) {
        if (bubble.id == widget.activeBubbleId) {
          activeRect = bubble.rect;
          activeId = bubble.id;
          isBubbleHighlight = true;
          break;
        }
      }
      if (activeRect == null) {
        for (final sentence in widget.page.sentences) {
          if (sentence.id == widget.activeSentenceId) {
            activeRect = sentence.rect;
            activeId = sentence.id;
            break;
          }
        }
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final sentence = _sentenceAtLocalPosition(
            details.localPosition,
            size,
          );
          if (sentence != null) widget.onSentenceTap(sentence);
        },
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: renderRect,
              child: _imageAvailable
                  ? Image.asset(widget.page.imagePath, fit: BoxFit.contain)
                  : _PlaceholderPage(page: widget.page),
            ),
            if (activeRect != null)
              Positioned.fromRect(
                rect: Rect.fromLTRB(
                  renderRect.left + activeRect.left * renderRect.width,
                  renderRect.top + activeRect.top * renderRect.height,
                  renderRect.left + activeRect.right * renderRect.width,
                  renderRect.top + activeRect.bottom * renderRect.height,
                ),
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey(
                      '${isBubbleHighlight ? 'bubble' : 'sentence'}-$activeId',
                    ),
                    tween: Tween(begin: 0, end: 1),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    builder: (context, opacity, child) =>
                        Opacity(opacity: opacity, child: child),
                    child: DecoratedBox(
                      key: Key(
                        isBubbleHighlight
                            ? 'bubble-highlight'
                            : 'sentence-highlight',
                      ),
                      decoration: BoxDecoration(
                        color: Colors.yellow.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.page});

  final TextbookPage page;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Positioned(
              top: 24,
              left: 24,
              right: 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '第 ${page.pageIndex} 页',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '教材图片待导入 · 点按句子区域体验点读',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            for (final sentence in page.sentences)
              Positioned(
                left: sentence.rect.left * constraints.maxWidth,
                top: sentence.rect.top * constraints.maxHeight,
                width:
                    (sentence.rect.right - sentence.rect.left) *
                    constraints.maxWidth,
                height:
                    (sentence.rect.bottom - sentence.rect.top) *
                    constraints.maxHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    sentence.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: colors.onSurface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
