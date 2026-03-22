import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router.dart';
import 'theme/theme_provider.dart';

class InfernoApp extends ConsumerWidget {
  const InfernoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeData = ref.watch(themeDataProvider);

    return MaterialApp.router(
      title: 'Inferno',
      theme: themeData,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
