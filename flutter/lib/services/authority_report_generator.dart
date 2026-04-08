import 'package:intl/intl.dart';
import '../database/database.dart';

/// Generates plaintext reports for law enforcement from hidden messages.
///
/// Categories: csam, threats, terrorism, other_illegal.
/// Reports include message details, sender info, server/channel context,
/// attachment metadata, relay info, reporter info, and moderation history.
class AuthorityReportGenerator {
  static const categories = {
    'csam': 'Child Sexual Abuse Material (CSAM)',
    'threats': 'Credible Threats of Violence',
    'terrorism': 'Terrorism',
    'other_illegal': 'Other Illegal Activity',
  };

  final InfernoDatabase _db;
  final Message message;
  final String category;
  final String reporterPubkey;
  final String reporterUsername;

  AuthorityReportGenerator(
    this._db, {
    required this.message,
    required this.category,
    required this.reporterPubkey,
    required this.reporterUsername,
  });

  Future<String> generate() async {
    final lines = <String>[];
    final dateFmt = DateFormat('yyyy-MM-dd HH:mm:ss');

    lines.add('=' * 60);
    lines.add('INFERNO — REPORT FOR LAW ENFORCEMENT');
    lines.add('=' * 60);
    lines.add('');
    lines.add('Generated: ${dateFmt.format(DateTime.now().toUtc())} UTC');
    lines.add('Report Category: ${categories[category] ?? category}');
    lines.add('');

    // Message details
    lines.add('-' * 60);
    lines.add('MESSAGE DETAILS');
    lines.add('-' * 60);
    lines.add('');
    lines.add('Message ID: ${message.publicId}');
    lines.add('Nostr Event ID: ${message.nostrEventId ?? 'N/A (local message)'}');
    lines.add('Timestamp: ${message.createdAt.toUtc().let((d) => '${dateFmt.format(d)} UTC')}');
    lines.add('');

    // Sender info
    lines.add('Sender Nostr Public Key: ${message.nostrAuthorPubkey ?? 'N/A (local user)'}');
    if (message.nostrAuthorPubkey != null) {
      final contact = await (_db.select(_db.contacts)
            ..where((c) => c.pubkey.equals(message.nostrAuthorPubkey!)))
          .getSingleOrNull();
      if (contact != null) {
        lines.add('Sender Display Name: ${contact.displayName ?? 'Unknown'}');
      }
    }
    lines.add('');

    // Context (channel or DM)
    if (message.channelId != null) {
      final channel = await (_db.select(_db.channels)
            ..where((c) => c.id.equals(message.channelId!)))
          .getSingleOrNull();
      if (channel != null) {
        final server = await (_db.select(_db.servers)
              ..where((s) => s.id.equals(channel.serverId)))
            .getSingleOrNull();
        lines.add('Server: ${server?.name ?? 'Unknown'}');
        lines.add('Channel: #${channel.name}');
      }
    } else if (message.conversationId != null) {
      lines.add('Context: Direct Message');
      lines.add('Conversation ID: ${message.conversationId}');
    }
    lines.add('');

    // Message content
    lines.add('-' * 60);
    lines.add('MESSAGE CONTENT');
    lines.add('-' * 60);
    lines.add('');
    if (message.hiddenReason?.contains('csam') == true) {
      lines.add('[Content blocked by automated safety systems — not displayed]');
    } else if (message.content != null && message.content!.isNotEmpty) {
      lines.add(message.content!);
    } else {
      lines.add('[No text content]');
    }
    lines.add('');

    // Attachment metadata
    final attachments = await (_db.select(_db.hiddenAttachmentRecords)
          ..where((r) => r.messageId.equals(message.id)))
        .get();
    if (attachments.isNotEmpty) {
      lines.add('-' * 60);
      lines.add('ATTACHMENT METADATA');
      lines.add('-' * 60);
      lines.add('');
      lines.add('Note: Attachments were purged on hide. Only metadata is included.');
      lines.add('Law enforcement can retrieve original content from Nostr relays');
      lines.add('using the Event ID above with proper legal authority.');
      lines.add('');
      for (int i = 0; i < attachments.length; i++) {
        final rec = attachments[i];
        lines.add('  Attachment ${i + 1}:');
        lines.add('    Filename: ${rec.originalFilename}');
        if (rec.contentType != null) lines.add('    Content Type: ${rec.contentType}');
        if (rec.byteSize != null) lines.add('    Size: ${rec.byteSize} bytes');
        if (rec.checksum != null) lines.add('    Checksum: ${rec.checksum}');
        if (rec.purgedAt != null) {
          lines.add('    Purged At: ${dateFmt.format(rec.purgedAt!.toUtc())} UTC');
        }
        lines.add('');
      }
    }

    // Relay info
    final relays = await (_db.select(_db.relayConnections)
          ..where((r) => r.status.equals('active')))
        .get();
    if (relays.isNotEmpty) {
      lines.add('-' * 60);
      lines.add('RELAY INFORMATION');
      lines.add('-' * 60);
      lines.add('');
      lines.add('The message was seen on these Nostr relays:');
      for (final relay in relays) {
        lines.add('  - ${relay.url}');
      }
      lines.add('');
      lines.add('Law enforcement can request the original event (including any');
      lines.add('attachments) from these relays using the Nostr Event ID above.');
      lines.add('');
    }

    // Reporter info
    lines.add('-' * 60);
    lines.add('REPORTER INFORMATION');
    lines.add('-' * 60);
    lines.add('');
    lines.add('Reporter Username: $reporterUsername');
    lines.add('Reporter Nostr Public Key: $reporterPubkey');
    lines.add('');

    // Moderation history
    lines.add('-' * 60);
    lines.add('MODERATION HISTORY');
    lines.add('-' * 60);
    lines.add('');
    if (message.hiddenAt != null) {
      lines.add('Hidden At: ${dateFmt.format(message.hiddenAt!.toUtc())} UTC');
    }
    lines.add('Hidden Reason: ${message.hiddenReason ?? 'N/A'}');
    lines.add('');

    // Reporting resources
    lines.add('=' * 60);
    lines.add('HOW TO USE THIS REPORT');
    lines.add('=' * 60);
    lines.add('');
    lines.add('This report was generated by the Inferno messaging application.');
    lines.add('It contains metadata and identifiers that law enforcement can use');
    lines.add('to investigate the reported content.');
    lines.add('');
    lines.add('To retrieve the original content (including images/videos),');
    lines.add('law enforcement should request the Nostr event with the Event ID');
    lines.add('listed above from the relays listed in this report.');
    lines.add('');
    lines.add('REPORTING RESOURCES:');
    lines.add('  CSAM: NCMEC CyberTipline — https://report.cybertip.org');
    lines.add('  Terrorism/Threats: FBI IC3 — https://ic3.gov');
    lines.add('  UK: Internet Watch Foundation — https://iwf.org.uk');
    lines.add('  EU: Europol — https://europol.europa.eu/report-a-crime');
    lines.add('');
    lines.add('=' * 60);

    return lines.join('\n');
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}
