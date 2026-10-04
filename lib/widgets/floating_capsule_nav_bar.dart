import 'dart:ui';

import 'package:flutter/material.dart';

class FloatingCapsuleNavBar extends StatelessWidget {
  const FloatingCapsuleNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  }) : assert(selectedIndex == 0 || selectedIndex == 1);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  static const height = 64.0;
  static const contentClearance = height + 36 + 16;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SizedBox(
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xE61E1E24),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _destination(
                          context,
                          index: 0,
                          label: '书本',
                          icon: Icons.auto_stories_outlined,
                          selectedIcon: Icons.auto_stories,
                          duration: duration,
                        ),
                        const SizedBox(width: 8),
                        _destination(
                          context,
                          index: 1,
                          label: '我的',
                          icon: Icons.person_outline,
                          selectedIcon: Icons.person,
                          duration: duration,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _destination(
    BuildContext context, {
    required int index,
    required String label,
    required IconData icon,
    required IconData selectedIcon,
    required Duration duration,
  }) {
    final selected = index == selectedIndex;
    final foreground = selected
        ? const Color(0xFFA7EDD5)
        : const Color(0xFFCFD0D5);
    return Expanded(
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        onTap: () => onDestinationSelected(index),
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF294B43) : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('nav-$index'),
                borderRadius: BorderRadius.circular(24),
                onTap: () => onDestinationSelected(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(selected ? selectedIcon : icon, color: foreground),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: foreground,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
