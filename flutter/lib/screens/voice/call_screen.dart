import 'package:flutter/material.dart';

enum CallState { ringing, incoming, active }

class CallScreen extends StatefulWidget {
  final String callerName;
  final CallState initialState;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final VoidCallback? onHangup;

  const CallScreen({
    super.key,
    required this.callerName,
    this.initialState = CallState.ringing,
    this.onAccept,
    this.onDecline,
    this.onHangup,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late CallState _state;
  int _callSeconds = 0;

  @override
  void initState() {
    super.initState();
    _state = widget.initialState;
    if (_state == CallState.active) _startTimer();
  }

  void _startTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || _state != CallState.active) return false;
      setState(() => _callSeconds++);
      return true;
    });
  }

  String get _timerText {
    final mins = _callSeconds ~/ 60;
    final secs = _callSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            // Avatar
            CircleAvatar(
              radius: 50,
              backgroundColor: const Color(0xFF2A3A5C),
              child: Text(
                widget.callerName.isNotEmpty ? widget.callerName[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 36, color: Color(0xFFE0E0E0)),
              ),
            ),
            const SizedBox(height: 24),
            // Name
            Text(widget.callerName,
              style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            // Status
            Text(
              _state == CallState.ringing ? 'Calling...'
                  : _state == CallState.incoming ? 'Incoming call'
                  : _timerText,
              style: const TextStyle(color: Color(0xFF8899A6), fontSize: 16),
            ),
            const Spacer(flex: 3),
            // Call action buttons
            if (_state == CallState.incoming)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Decline
                  FloatingActionButton(
                    heroTag: 'decline',
                    backgroundColor: const Color(0xFFFF4D4D),
                    onPressed: () {
                      widget.onDecline?.call();
                      Navigator.pop(context);
                    },
                    child: const Icon(Icons.call_end, color: Colors.white),
                  ),
                  // Accept
                  FloatingActionButton(
                    heroTag: 'accept',
                    backgroundColor: const Color(0xFF4CAF50),
                    onPressed: () {
                      setState(() => _state = CallState.active);
                      _startTimer();
                      widget.onAccept?.call();
                    },
                    child: const Icon(Icons.call, color: Colors.white),
                  ),
                ],
              )
            else
              // Hangup button (for ringing and active states)
              FloatingActionButton(
                heroTag: 'hangup',
                backgroundColor: const Color(0xFFFF4D4D),
                onPressed: () {
                  widget.onHangup?.call();
                  Navigator.pop(context);
                },
                child: const Icon(Icons.call_end, color: Colors.white, size: 32),
              ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}
