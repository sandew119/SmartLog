import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database/local_db.dart';
import '../models/saved_item.dart';
import '../repositories/stack_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';
import 'auth/login_screen.dart';
import 'defect_detection_screen.dart';
import 'log_report_builder_screen.dart';
import 'manual_calculator_screen.dart';
import 'optimal_cutting_screen.dart';
import 'profile/profile_screen.dart';
import 'reports_screen.dart';
import 'saved_stacks_screen.dart';
import 'scan_log_screen.dart';
import 'stack_detail_screen.dart';

/// Everything saved on this phone, summed for the dashboard.
class _Overview {
  final int logs;
  final int stacks;
  final double cubicFeet;
  final List<SavedItem> recent;

  const _Overview({
    this.logs = 0,
    this.stacks = 0,
    this.cubicFeet = 0,
    this.recent = const [],
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Where the signed-in account comes from. A function rather than a direct
  /// call so the dashboard can be built in a test without Firebase.
  @visibleForTesting
  static Stream<User?> Function() authChanges =
      () => FirebaseAuth.instance.authStateChanges();

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Subscribed once. Calling authChanges() in build would hand the
  // StreamBuilder a new stream on every refresh and flash the signed-out
  // header while it resubscribed.
  late final Stream<User?> _auth = HomeScreen.authChanges();

  _Overview _overview = const _Overview();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final logs = await LocalDB.getAllLogs();
      final items = await StackRepository.instance.loadSavedItems();

      final stacks = items.where((i) => i.stack != null).length;
      final volume = logs.fold<double>(
        0,
        (sum, row) => sum + ((row["volume"] as num?)?.toDouble() ?? 0),
      );

      if (!mounted) return;

      setState(() {
        _overview = _Overview(
          logs: logs.length,
          stacks: stacks,
          cubicFeet: volume,
          recent: items.take(3).toList(),
        );
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  /// Opens a screen, then refreshes the figures -- whatever was done there
  /// has probably changed them.
  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  static String _greeting(DateTime now) {
    final hour = now.hour;
    if (hour < 12) return "Good morning";
    if (hour < 17) return "Good afternoon";
    return "Good evening";
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _auth,
      builder: (context, snapshot) {
        final user = snapshot.data;

        return Scaffold(
          body: RefreshIndicator(
            color: AppTheme.primary,
            onRefresh: _load,
            child: SafeArea(
              bottom: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
                children: [
                  FadeSlideIn(child: _header(user)),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 60),
                    child: _syncPill(user),
                  ),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 100),
                    child: _overviewCard(),
                  ),
                  const SizedBox(height: 14),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 150),
                    child: _passportCard(),
                  ),
                  const SectionHeader(
                    eyebrow: "Workspace",
                    title: "Tools",
                  ),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 200),
                    child: _toolGrid(),
                  ),
                  if (_overview.recent.isNotEmpty) ...[
                    SectionHeader(
                      eyebrow: "Recent",
                      title: "Latest work",
                      trailing: TextButton(
                        onPressed: () => _open(const SavedStacksScreen()),
                        child: const Text("See all"),
                      ),
                    ),
                    for (final item in _overview.recent)
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 240),
                        child: _recentRow(item),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- header ----------------------------------------------------------------

  Widget _header(User? user) {
    final now = DateTime.now();
    final first = user?.displayName?.trim().split(" ").first;
    final name = (first == null || first.isEmpty) ? null : first;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            "assets/logos/app_icon.png",
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const IconBadge(
              icon: Icons.forest_rounded,
              size: 40,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat("EEEE, d MMMM").format(now).toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 2),
              Text(
                name == null ? _greeting(now) : "${_greeting(now)}, $name",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (user == null)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: () => _open(const LoginScreen()),
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text("Login"),
          )
        else
          PressableScale(
            onTap: () => _open(const ProfileScreen()),
            child: Container(
              padding: const EdgeInsets.all(2.5),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.timberGradient,
              ),
              child: CircleAvatar(
                radius: 20,
                backgroundColor: AppTheme.primary,
                backgroundImage:
                    user.photoURL != null ? NetworkImage(user.photoURL!) : null,
                child: user.photoURL == null
                    ? Text(
                        (name ?? user.email ?? "S")[0].toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _syncPill(User? user) {
    final signedIn = user != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: PressableScale(
        onTap: signedIn ? null : () => _open(const LoginScreen()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: AppTheme.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                signedIn ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 17,
                color: signedIn ? AppTheme.success : AppTheme.warning,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  signedIn
                      ? "Cloud Sync Enabled · ${user.email ?? ''}"
                      : "Guest Mode · Login to sync your SmartLog data.",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- overview --------------------------------------------------------------

  Widget _overviewCard() {
    final o = _overview;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge + 4),
        boxShadow: AppTheme.softShadow,
      ),
      child: Stack(
        children: [
          // A faint ring pattern in the corner, like growth rings on a cut
          // end -- quiet texture, not decoration for its own sake.
          Positioned(
            right: -40,
            top: -50,
            child: IgnorePointer(
              child: CustomPaint(
                size: const Size(170, 170),
                painter: _RingsPainter(),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "AT A GLANCE",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _countUp(
                      label: "Logs measured",
                      value: o.logs.toDouble(),
                      format: (v) => "${v.round()}",
                    ),
                  ),
                  Expanded(
                    child: _countUp(
                      label: "Stacks",
                      value: o.stacks.toDouble(),
                      format: (v) => "${v.round()}",
                    ),
                  ),
                  Expanded(
                    child: _countUp(
                      label: "Total volume",
                      value: o.cubicFeet,
                      format: (v) =>
                          "${v.toStringAsFixed(v >= 100 ? 0 : 1)} ft³",
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _countUp({
    required String label,
    required double value,
    required String Function(double) format,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: _loaded ? value : 0),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => StatTile(
        label: label,
        value: format(v),
        onDark: true,
      ),
    );
  }

  Widget _passportCard() {
    return PressableScale(
      onTap: () => _open(const LogReportBuilderScreen()),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 16, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          border: Border.all(color: const Color(0xFFE9D9C2)),
          boxShadow: AppTheme.softShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                gradient: AppTheme.timberGradient,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.assignment_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        "Log Passport",
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "NEW",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.8,
                            color: Color(0xFF9C6431),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Full report for one log — volume, defects, their impact, "
                    "cutting pattern and suggestions. Export as PDF.",
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 16,
              color: AppTheme.accent,
            ),
          ],
        ),
      ),
    );
  }

  // --- tools -----------------------------------------------------------------

  Widget _toolGrid() {
    final tools = <({
      String title,
      String subtitle,
      IconData icon,
      Color colour,
      Widget screen
    })>[
      (
        title: "Scan Log",
        subtitle: "Measure with the camera",
        icon: Icons.camera_alt_rounded,
        colour: AppTheme.primaryBright,
        screen: const ScanLogScreen(),
      ),
      (
        title: "Manual Calculator",
        subtitle: "Girth × length to volume",
        icon: Icons.calculate_rounded,
        colour: const Color(0xFF2F6FB0),
        screen: const ManualCalculatorScreen(),
      ),
      (
        title: "Optimal Cutting",
        subtitle: "Most timber per log",
        icon: Icons.content_cut_rounded,
        colour: AppTheme.accent,
        screen: const OptimalCuttingScreen(),
      ),
      (
        title: "Defect Detection",
        subtitle: "Cracks, holes and knots",
        icon: Icons.center_focus_strong_rounded,
        colour: AppTheme.severityHigh,
        screen: const DefectDetectionScreen(),
      ),
      (
        title: "Saved Stacks",
        subtitle: "Every log you've saved",
        icon: Icons.layers_rounded,
        colour: const Color(0xFF6B5B95),
        screen: const SavedStacksScreen(),
      ),
      (
        title: "Reports",
        subtitle: "PDF and Excel exports",
        icon: Icons.bar_chart_rounded,
        colour: const Color(0xFF2E8B8B),
        screen: const ReportsScreen(),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final width = (constraints.maxWidth - gap) / 2;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tool in tools)
              SizedBox(
                width: width,
                child: PressableScale(
                  onTap: () => _open(tool.screen),
                  child: Container(
                    height: 132,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusLarge - 4),
                      border: Border.all(color: AppTheme.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconBadge(
                            icon: tool.icon, color: tool.colour, size: 42),
                        const Spacer(),
                        Text(
                          tool.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tool.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // --- recent ----------------------------------------------------------------

  Widget _recentRow(SavedItem item) {
    final stack = item.stack;
    final log = item.log;
    final date = DateFormat("d MMM · h:mm a");

    final title = stack != null ? stack.name : "Single log";
    final subtitle = stack != null
        ? "${item.logCount} log${item.logCount == 1 ? '' : 's'} · "
            "${stack.totalVolume.toStringAsFixed(2)} ft³"
        : "${log!.volume.toStringAsFixed(2)} ft³ · "
            "${log.lengthFeet.toStringAsFixed(1)} ft long";

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        shadow: false,
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        onTap: () => _open(
          stack != null
              ? StackDetailScreen(stackId: stack.id)
              : const SavedStacksScreen(),
        ),
        child: Row(
          children: [
            IconBadge(
              icon: stack != null ? Icons.layers_rounded : Icons.forest_rounded,
              color: stack != null ? AppTheme.primaryBright : AppTheme.accent,
              size: 38,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              date.format(item.createdAt),
              style:
                  const TextStyle(fontSize: 11.5, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Concentric rings, faint, like the growth rings on a sawn end.
class _RingsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);

    for (var i = 1; i <= 7; i++) {
      canvas.drawCircle(
        centre,
        size.shortestSide / 2 * i / 7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.06 + i * 0.006),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) => false;
}
