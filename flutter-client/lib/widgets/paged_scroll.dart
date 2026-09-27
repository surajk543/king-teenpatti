import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A scroll view over a list the server pages (owner, 27 Sep 2026: "reported
/// user should be fetched using pagination, and same with friend list, as
/// user scroll, then it will fetch more pagination" — 20 a page): it asks for
/// the next page ([onMore]) as the list comes within [reach] of its end, and
/// at once when the pages read so far do not fill it — nothing to scroll is
/// no reason to stop at the first page.
///
/// [builder] builds the scroll view with the controller this listens to. A
/// page is asked for only while [hasMore] and not while one is [loading]; the
/// caller sets [loading] the moment it asks, so a burst of scroll events asks
/// once.
class PagedScroll extends StatefulWidget {
  const PagedScroll({
    super.key,
    required this.hasMore,
    required this.loading,
    required this.onMore,
    required this.builder,
  });

  final bool hasMore;
  final bool loading;
  final VoidCallback onMore;
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  /// How near the list's end the next page is asked for: a couple of rows
  /// before the player reaches it, so it is usually there when they do.
  static const double reach = 240;

  @override
  State<PagedScroll> createState() => _PagedScrollState();
}

class _PagedScrollState extends State<PagedScroll> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_check);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _check() {
    if (!mounted || !widget.hasMore || widget.loading) return;
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    if (position.extentAfter < PagedScroll.reach) widget.onMore();
  }

  @override
  Widget build(BuildContext context) {
    // After the frame: a page that does not fill the view asks for the next
    // one, and a page that has just come in is checked the same way.
    if (widget.hasMore && !widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
    return widget.builder(context, _controller);
  }
}

/// The row at a paged list's end while its next page is being read.
class PagedFooter extends StatelessWidget {
  const PagedFooter({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.md),
    child: Center(
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: AppTheme.inkMed),
        ),
      ),
    ),
  );
}
