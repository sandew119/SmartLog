import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/local_db.dart';
import '../services/cloud_sync_engine.dart';
import '../services/cloud_sync_status.dart';

/// A read-only window onto the phone's own database and its sync queue.
///
/// Exists because the two most interesting claims this app makes -- that the
/// phone is the source of truth, and that nothing is lost when the signal
/// goes -- are both invisible from the normal screens. Proving them otherwise
/// means pulling the database off over a cable with the app closed, which
/// cannot be done while the app is running, let alone in front of anyone.
///
/// Deliberately behind a gesture. It is a window for whoever built the app,
/// not a feature, and it shows nothing a user would understand or want.
class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  static final _timeFormat = DateFormat("HH:mm:ss");

  int? _schemaVersion;
  List<TableSummary> _tables = const [];
  List<Map<String, dynamic>> _outbox = const [];
  Map<String, Object?> _preferences = const {};

  /// The keys that ride up to Firestore as part of the user's profile
  /// document. Everything else is deliberately device-local -- a device id or
  /// a "remember me" flag would be meaningless on someone's other phone.
  static const _syncedKeys = {
    "volume_method",
    "girth_deduction_inches",
    "avoid_defects",
  };

  Object? _error;

  /// Refreshes on a timer so the queue can be watched filling and emptying
  /// as the network comes and goes, rather than needing a button pressed at
  /// exactly the right moment.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();

    _load();
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final version = await LocalDB.currentSchemaVersion();
      final tables = await LocalDB.tableSummaries();
      final outbox = await LocalDB.pendingSyncItems(limit: 50);

      // Read every key that is actually stored rather than a hardcoded list,
      // for the same reason the tables are read from sqlite_master: a list
      // written by hand goes stale the first time somebody adds a setting.
      final prefs = await SharedPreferences.getInstance();
      final stored = {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };

      if (!mounted) return;

      setState(() {
        _schemaVersion = version;
        _tables = tables;
        _outbox = outbox;
        _preferences = stored;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Widget _card({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, Color colour) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: colour,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  // --- the local database ---------------------------------------------------

  Widget _databaseCard() {
    final version = _schemaVersion;

    return _card(
      title: "Local database (SQLite)",
      trailing: version == null
          ? const SizedBox.shrink()
          : _pill(
              "schema v$version",
              // Compared against what this build expects, so a device that
              // never ran the latest migration is obvious at a glance rather
              // than quietly reporting an old number in green.
              version == LocalDB.schemaVersion ? Colors.green : Colors.orange,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "This is the source of truth. Every figure the app shows is read "
            "from here, online or not.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          // Collapsed by default. Expanded, eight tables and their forty-odd
          // columns fill the whole screen and push the sync queue -- the card
          // that actually changes while you watch -- out of sight.
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                "${_tables.length} tables, "
                "${_tables.fold<int>(0, (sum, t) => sum + t.rows)} rows",
                style: const TextStyle(fontSize: 13),
              ),
              children: [
                for (final table in _tables) _tableTile(table),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableTile(TableSummary table) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Row(
          children: [
            Expanded(
              child: Text(
                table.name,
                style: const TextStyle(
                  fontFamily: "monospace",
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              "${table.rows} row${table.rows == 1 ? '' : 's'}",
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        children: [
          for (final column in table.columns)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Row(
                children: [
                  const Text("· ", style: TextStyle(color: Colors.grey)),
                  Expanded(
                    child: Text(
                      column,
                      style: const TextStyle(
                        fontFamily: "monospace",
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // --- key/value settings ---------------------------------------------------

  Widget _preferencesCard() {
    // Synced keys first: they are the ones the cloud story is about.
    final keys = _preferences.keys.toList()
      ..sort((a, b) {
        final aSynced = _syncedKeys.contains(a);
        final bSynced = _syncedKeys.contains(b);

        if (aSynced != bSynced) return aSynced ? -1 : 1;
        return a.compareTo(b);
      });

    return _card(
      title: "Device settings (SharedPreferences)",
      trailing: _pill("${keys.length} keys", Colors.blueGrey),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Settings are key/value, not rows, so they live here rather than "
            "in SQLite. The three marked below are mirrored into the user's "
            "profile document; the rest belong to this phone alone.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (keys.isEmpty)
            const Text(
              "Nothing stored yet.",
              style: TextStyle(fontSize: 13, color: Colors.grey),
            )
          else
            for (final key in keys) _preferenceRow(key),
        ],
      ),
    );
  }

  Widget _preferenceRow(String key) {
    final synced = _syncedKeys.contains(key);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            synced ? Icons.cloud_done : Icons.phone_android,
            size: 14,
            color: synced ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              key,
              style: const TextStyle(fontFamily: "monospace", fontSize: 11),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              "${_preferences[key]}",
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: "monospace",
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- the queue ------------------------------------------------------------

  Widget _outboxCard() {
    return _card(
      title: "Sync queue (sync_outbox)",
      trailing: _pill(
        _outbox.isEmpty ? "empty" : "${_outbox.length} waiting",
        _outbox.isEmpty ? Colors.green : Colors.orange,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Work that has not reached the cloud yet. Rows appear here the "
            "moment something is saved and disappear once the upload is "
            "confirmed — so an empty queue means everything is backed up.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (_outbox.isEmpty)
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                Text(
                  "Nothing waiting.",
                  style: TextStyle(color: Colors.green.shade700, fontSize: 13),
                ),
              ],
            )
          else
            for (final item in _outbox) _outboxRow(item),
        ],
      ),
    );
  }

  Widget _outboxRow(Map<String, dynamic> item) {
    final attempts = (item["attempts"] as int?) ?? 0;
    final error = item["lastError"] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: error == null
            ? Colors.grey.withValues(alpha: 0.06)
            : Colors.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "${item["operation"]} ${item["entity"]}"
                  "${item["localId"] == null ? '' : ' #${item["localId"]}'}",
                  style: const TextStyle(
                    fontFamily: "monospace",
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (attempts > 0)
                Text(
                  "$attempts attempt${attempts == 1 ? '' : 's'}",
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  // --- the cloud ------------------------------------------------------------

  Widget _cloudCard() {
    return ValueListenableBuilder<CloudSyncSnapshot>(
      valueListenable: CloudSyncStatus.instance.listenable,
      builder: (context, status, _) {
        final (label, colour) = switch (status.state) {
          CloudSyncState.ok => ("connected", Colors.green),
          CloudSyncState.failed => ("failing", Colors.red),
          CloudSyncState.signedOut => ("signed out", Colors.grey),
          CloudSyncState.idle => ("idle", Colors.grey),
        };

        return _card(
          title: "Cloud mirror (Firestore)",
          trailing: _pill(label, colour),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line("Last upload", _time(status.lastSuccess)),
              _line("Last failure", _time(status.lastFailure)),
              _line(
                "Failures in a row",
                status.consecutiveFailures.toString(),
              ),
              _line("Error code", status.code ?? "—"),
              if (status.message != null) ...[
                const SizedBox(height: 8),
                Text(
                  status.message!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _time(DateTime? value) =>
      value == null ? "never" : _timeFormat.format(value);

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontFamily: "monospace",
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffF5F7FA),
      appBar: AppBar(
        title: const Text("Developer"),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: "Force a sync now",
            onPressed: () async {
              await CloudSyncEngine.instance.drain();
              await _load();
            },
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't read the database.\n\n$_error",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _databaseCard(),
                _preferencesCard(),
                _outboxCard(),
                _cloudCard(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    "Refreshes every 2 seconds. Read-only — nothing on this "
                    "screen changes any data.",
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 30),
              ],
            ),
    );
  }
}
