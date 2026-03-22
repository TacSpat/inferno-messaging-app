import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'providers/database_provider.dart';
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

final router = GoRouter(
  initialLocation: '/auth/login',
  routes: [
    // Auth routes
    GoRoute(path: '/auth/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/auth/signup', builder: (context, state) => const SignupScreen()),
    GoRoute(path: '/auth/import', builder: (context, state) => const KeyImportScreen()),
    GoRoute(path: '/auth/setup', builder: (context, state) => const SetupWizardScreen()),

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
            ConversationsListScreen(initialTab: state.uri.queryParameters['tab']),
            state,
          ),
          routes: [
            GoRoute(
              path: ':id',
              pageBuilder: (context, state) => _noAnimationPage(
                ConversationDetailScreen(conversationPublicId: state.pathParameters['id']!),
                state,
              ),
            ),
          ],
        ),

        // Server landing — redirects to first channel (matches Rails servers#show)
        GoRoute(
          path: '/servers/:serverId',
          pageBuilder: (context, state) => _noAnimationPage(
            _ServerRedirectScreen(serverId: state.pathParameters['serverId']!),
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

/// When navigating to /servers/:id with no channel, redirect to the first channel.
/// Matches Rails `ServersController#show` which redirects to `server_channel_path(@server, first_channel)`.
class _ServerRedirectScreen extends ConsumerStatefulWidget {
  final String serverId;
  const _ServerRedirectScreen({required this.serverId});

  @override
  ConsumerState<_ServerRedirectScreen> createState() => _ServerRedirectScreenState();
}

class _ServerRedirectScreenState extends ConsumerState<_ServerRedirectScreen> {
  @override
  void initState() {
    super.initState();
    _redirect();
  }

  Future<void> _redirect() async {
    final db = ref.read(databaseProvider);
    final server = await db.serversDao.getByPublicId(widget.serverId);
    if (server == null || !mounted) return;

    final channels = await (db.select(db.channels)
          ..where((c) => c.serverId.equals(server.id))
          ..orderBy([(c) => OrderingTerm.asc(c.position)])
          ..limit(1))
        .get();

    if (channels.isNotEmpty && mounted) {
      GoRouter.of(context).go('/servers/${widget.serverId}/channels/${channels.first.publicId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox(); // Brief flash while redirecting
  }
}
