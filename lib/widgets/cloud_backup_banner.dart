import 'package:flutter/material.dart';

import '../services/cloud_sync_status.dart';

/// Tells the user when their logs have stopped reaching the cloud.
///
/// Shows nothing at all in the normal case, and nothing for a single failed
/// push either -- a yard with no signal is not a problem to interrupt anyone
/// about. It appears only once failures are persistent, which is exactly the
/// shape a misconfiguration has: every attempt, every time.
///
/// The wording never implies data loss, because there is none: the phone's
/// database holds every log whether the mirror works or not.
class CloudBackupBanner extends StatelessWidget {
  const CloudBackupBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CloudSyncSnapshot>(
      valueListenable: CloudSyncStatus.instance.listenable,
      builder: (context, snapshot, _) {
        if (!snapshot.isPersistentlyFailing) return const SizedBox.shrink();

        // A configuration problem will not clear on its own, so it is worth
        // saying so plainly rather than implying the user should just wait.
        final permanent = snapshot.code == "permission-denied";

        final colour = permanent ? Colors.red : Colors.orange;

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colour.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                permanent ? Icons.cloud_off : Icons.cloud_queue,
                color: colour,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      permanent
                          ? "Cloud backup isn't working"
                          : "Cloud backup is behind",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colour.shade800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      snapshot.message ??
                          "Your logs are saved on this phone but aren't "
                              "reaching the cloud.",
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
