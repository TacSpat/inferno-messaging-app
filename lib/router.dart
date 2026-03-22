import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/auth/key_import_screen.dart';
import 'screens/auth/setup_wizard_screen.dart';
import 'screens/conversations/conversations_list_screen.dart';
import 'screens/conversations/conversation_detail_screen.dart';
import 'screens/channels/text_channel_screen.dart';
import 'screens/main_shell.dart';

/// No-animation page — content swaps instantly like Discord
CustomTransitionPage<void> _noAnimationPage(Widget child, GoRouterState state) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (_, __, ___, child) => child,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

class _PlaceholderScreen extends StatelessWidget {
  final String title;
  const _PlaceholderScreen({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

final router = GoRouter(
  initialLocation: '/auth/login',
  routes: [
    // Auth routes (these keep default transitions — they're full-screen flows)
    GoRoute(
      path: '/auth/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/auth/signup',
      builder: (context, state) => const SignupScreen(),
    ),
    GoRoute(
      path: '/auth/import',
      builder: (context, state) => const KeyImportScreen(),
    ),
    GoRoute(
      path: '/auth/setup',
      builder: (context, state) => const SetupWizardScreen(),
    ),

    // Main app shell — persistent 3-column layout, content swaps instantly
    ShellRoute(
      builder: (context, state, child) {
        final serverId = state.pathParameters['serverId'];
        final channelId = state.pathParameters['channelId'];
        return MainShell(
          activeServerId: serverId,
          activeChannelId: channelId,
          child: child,
        );
      },
      routes: [
        // DMs / Conversations
        GoRoute(
          path: '/conversations',
          pageBuilder: (context, state) => _noAnimationPage(
            ConversationsListScreen(
              initialTab: state.uri.queryParameters['tab'],
            ),
            state,
          ),
          routes: [
            GoRoute(
              path: ':id',
              pageBuilder: (context, state) => _noAnimationPage(
                ConversationDetailScreen(
                  conversationPublicId: state.pathParameters['id']!,
                ),
                state,
              ),
            ),
          ],
        ),

        // Servers / Channels
        GoRoute(
          path: '/servers/:serverId',
          pageBuilder: (context, state) => _noAnimationPage(
            const _PlaceholderScreen(title: 'Select a channel'),
            state,
          ),
          routes: [
            GoRoute(
              path: 'channels/:channelId',
              pageBuilder: (context, state) => _noAnimationPage(
                TextChannelScreen(
                  channelPublicId: state.pathParameters['channelId']!,
                  serverPublicId: state.pathParameters['serverId']!,
                ),
                state,
              ),
            ),
          ],
        ),

      ],
    ),
  ],
);
