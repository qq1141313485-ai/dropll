import 'package:flutter/material.dart';

class HomeTabBar extends StatelessWidget {
  const HomeTabBar({required this.controller, super.key});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xffeef2ef),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final animation = controller.animation!;
          final segmentWidth = constraints.maxWidth / 2;
          return AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final position = animation.value.clamp(0.0, 1.0);
              return Stack(
                children: [
                  Positioned(
                    left: position * segmentWidth,
                    top: 4,
                    bottom: 4,
                    width: segmentWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                  Row(
                    children: List.generate(2, (index) {
                      final distance = (position - index).abs().clamp(0.0, 1.0);
                      final color = Color.lerp(
                        const Color(0xff079669),
                        const Color(0xff737980),
                        distance,
                      );
                      final label = index == 0 ? '即时' : '完场';
                      return Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(7),
                          onTap: () => controller.animateTo(
                            index,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                          ),
                          child: Center(
                            child: Text(
                              label,
                              style: TextStyle(
                                color: color,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
