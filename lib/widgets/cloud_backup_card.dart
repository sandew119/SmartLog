import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/cloud_restore_service.dart';
import '../services/cloud_sync_coordinator.dart';
import '../services/cloud_sync_engine.dart';
import '../services/cloud_sync_status.dart';

/// The state of the user's cloud backup, and the two things they can do
/// about it.
///
/// Backing up happens on its own; this card exists so it is *visible* that it
/// is happening. A backup nobody can confirm is one nobody trusts, and this
/// app spent its whole life so far silently failing to back anything up.
class CloudBackupCard extends StatefulWidget {
  /// Null in guest mode, which turns the card into an explanation rather
  /// than a set of controls.
  final bool signedIn;

  const CloudBackupCard({super.key, required this.signedIn});

  @override
  State<CloudBackupCard> createState() => _CloudBackupCardState();
}

class _CloudBackupCardState extends State<CloudBackupCard> {
  static final _timeFormat = DateFormat("MMM d, h:mm a");

  bool _busy = false;

  Future<void> _backUpEverything() async {
    setState(() => _busy = true);

    final messenger = ScaffoldMessenger.of(context);

    try {
      final queued = await CloudSyncCoordinator.instance.backUpEverythingNow();

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            queued == 0
                ? "Everything is already backed up."
                : "$queued item${queued == 1 ? '' : 's'} queued for backup.",
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);

    final safe = await CloudSyncCoordinator.instance.canRestoreSafely;
    if (!mounted) return;

    if (!safe) {
      // Restoring on top of existing work would leave two copies of every
      // stack and no way to tell which was which. Refusing is the only
      // honest answer until there is a real merge.
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Nothing to restore onto"),
          content: const Text(
            "This phone already has stacks and logs saved on it. Restoring "
            "would give you two copies of everything with no way to tell "
            "them apart.\n\nRestore is for a new phone, or after "
            "reinstalling — sign in there and your data comes back on its "
            "own.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
      return;
    }

    setState(() => _busy = true);

    try {
      final outcome = await CloudRestoreService.instance.restore();

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcome.restoredAnything
                ? "Restored ${outcome.stacks} stack"
                    "${outcome.stacks == 1 ? '' : 's'} and "
                    "${outcome.logs} log${outcome.logs == 1 ? '' : 's'}."
                : "There's nothing in the cloud to restore yet.",
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't reach the cloud just now.")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(IconData icon, Color colour, String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: colour),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.signedIn) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _row(
            Icons.cloud_off,
            Colors.grey,
            "Not backing up",
            "You're using the app as a guest. Everything is saved on this "
                "phone only — sign in to keep a copy in the cloud.",
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<CloudSyncSnapshot>(
              valueListenable: CloudSyncStatus.instance.listenable,
              builder: (context, status, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: CloudSyncEngine.instance.pending,
                  builder: (context, pending, __) {
                    final lastSuccess = status.lastSuccess;

                    final (icon, colour, title) = switch (status.state) {
                      CloudSyncState.failed when status.isPersistentlyFailing =>
                        (Icons.cloud_off, Colors.red, "Backup isn't working"),
                      CloudSyncState.failed => (
                          Icons.cloud_sync,
                          Colors.orange,
                          "Retrying",
                        ),
                      CloudSyncState.ok => (
                          Icons.cloud_done,
                          Colors.green,
                          pending > 0 ? "Backing up" : "Backed up",
                        ),
                      _ => (Icons.cloud_queue, Colors.grey, "Cloud backup"),
                    };

                    final detail = StringBuffer();

                    if (pending > 0) {
                      detail.write(
                        "$pending item${pending == 1 ? '' : 's'} waiting. ",
                      );
                    }

                    if (status.isPersistentlyFailing &&
                        status.message != null) {
                      detail.write(status.message);
                    } else if (lastSuccess != null) {
                      detail.write(
                        "Last backed up ${_timeFormat.format(lastSuccess)}.",
                      );
                    } else if (pending == 0) {
                      detail.write(
                        "Your stacks, logs and settings are copied to your "
                        "account automatically.",
                      );
                    }

                    return _row(
                      icon,
                      colour,
                      title,
                      detail.toString().trim(),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 14),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _backUpEverything,
                      icon: const Icon(Icons.backup, size: 18),
                      label: const Text("Back up now"),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _restore,
                      icon: const Icon(Icons.cloud_download, size: 18),
                      label: const Text("Restore"),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
