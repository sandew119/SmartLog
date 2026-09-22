import 'dart:io';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../database/local_db.dart';
import '../models/log_defect.dart';
import '../models/log_face_outline.dart';
import '../models/log_model.dart';
import '../models/log_report.dart';
import '../models/sawing_models.dart';
import '../painters/defect_overlay_painter.dart';
import '../painters/sawing_pattern_painter.dart';
import '../services/defect_advisor.dart';
import '../services/defect_impact.dart';
import '../services/defect_scan_controller.dart';
import '../services/diagnostics_service.dart';
import '../services/sawing_engine.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../utils/calculator.dart';
import '../utils/snapshot.dart';
import '../utils/timber_volume.dart';
import '../utils/unit_display.dart';
import '../widgets/cutting_setup_sheet.dart';
import '../widgets/image_source_sheet.dart';
import '../widgets/scan_widgets.dart';
import '../widgets/ui_kit.dart';
import 'defect_detection_screen.dart';
import 'log_face_trace_screen.dart';
import 'log_report_screen.dart';

class _ImpactJob {
  final LogFaceOutline outline;
  final List<LogDefect> defects;
  final SawingSetup setup;

  const _ImpactJob(this.outline, this.defects, this.setup);
}

List<DefectImpact> _impactsInBackground(_ImpactJob job) =>
    const DefectImpactAnalyser().analyse(
      outline: job.outline,
      defects: job.defects,
      setup: job.setup,
    );

/// Builds a Log Passport: one log, fully documented.
///
/// Four sections, filled in any order, each usable on its own: the log's
/// measurements, a photo of its cut face (traced for shape and scanned for
/// defects in the same step), a cutting plan, and notes. Whatever is filled
/// in goes into the report; whatever is not is marked "not assessed" rather
/// than silently left out -- a report that hides what it never checked is
/// worse than no report.
class LogReportBuilderScreen extends StatefulWidget {
  /// A photo already taken -- when arriving from Defect Detection.
  final File? initialPhoto;

  /// That photo's scan, so the review already made there carries over.
  final DefectScanController? scan;

  const LogReportBuilderScreen({super.key, this.initialPhoto, this.scan});

  @override
  State<LogReportBuilderScreen> createState() => _LogReportBuilderScreenState();
}

class _LogReportBuilderScreenState extends State<LogReportBuilderScreen> {
  late final DefectScanController _scan = widget.scan ?? DefectScanController();

  bool get _ownsScan => widget.scan == null;

  final _createdAt = DateTime.now();
  late final String _reference = LogReportData.newReference(_createdAt);

  final _girth = TextEditingController();
  final _length = TextEditingController();
  final _rate = TextEditingController();
  final _notes = TextEditingController();

  String? _species;
  final _otherSpecies = TextEditingController();

  int? _linkedLogId;
  String _source = "Tape measure";

  File? _photo;
  LogFaceTraceResult? _trace;

  SawingSetup? _setup;
  SawingComparison? _plans;
  SawingComparison? _soundPlans;
  String _planKey = "";
  bool _planning = false;

  bool _generating = false;
  String _stage = "";

  static const _speciesOptions = [
    "Teak",
    "Mahogany",
    "Jak",
    "Rubber",
    "Eucalyptus",
    "Pine",
    "Kumbuk",
    "Other",
  ];

  @override
  void initState() {
    super.initState();

    _photo = widget.initialPhoto;

    for (final c in [_girth, _length, _rate]) {
      c.addListener(_refresh);
    }

    _scan.addListener(_refresh);
  }

  @override
  void dispose() {
    _scan.removeListener(_refresh);
    if (_ownsScan) _scan.dispose();

    for (final c in [_girth, _length, _rate, _notes, _otherSpecies]) {
      c.dispose();
    }

    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // --- values ----------------------------------------------------------------

  double? _number(TextEditingController c) {
    final value = double.tryParse(c.text.trim());
    return (value != null && value > 0) ? value : null;
  }

  double? get _girthInches => _number(_girth);
  double? get _lengthFeet => _number(_length);
  double get _ratePerCubicFoot => _number(_rate) ?? 0;

  bool get _detailsReady => _girthInches != null && _lengthFeet != null;

  String? get _speciesName {
    if (_species == null) return null;
    if (_species != "Other") return _species;

    final typed = _otherSpecies.text.trim();
    return typed.isEmpty ? null : typed;
  }

  VolumeResult? get _volume {
    final girth = _girthInches;
    final length = _lengthFeet;
    if (girth == null || length == null) return null;

    final prefs = UserPreferencesService.instance.current;

    return TimberVolumeCalculator.calculate(
      method: prefs.volumeMethod,
      girthInches: math.max(0, girth - prefs.girthDeductionInches),
      lengthFeet: length,
    );
  }

  /// The face in photo pixels, from the trace.
  ({Offset centre, double radius})? get _tracedFacePx {
    final trace = _trace;
    if (trace == null || trace.inchesPerPixel <= 0) return null;

    final outline = trace.outline;
    final centreIn = outline.centroid;

    return (
      centre: Offset(
        centreIn.dx / trace.inchesPerPixel + trace.faceOriginPx.dx,
        centreIn.dy / trace.inchesPerPixel + trace.faceOriginPx.dy,
      ),
      radius: outline.equivalentCircleDiameter / 2 / trace.inchesPerPixel,
    );
  }

  /// Defects marked by hand while tracing, placed on the photo.
  List<AssessedDefect> get _manualDefects {
    final trace = _trace;
    if (trace == null || trace.inchesPerPixel <= 0) return const [];

    final face = _tracedFacePx;

    return [
      for (final d in trace.defects)
        AssessedDefect.locate(
          kind: d.kind,
          label: d.kind.label,
          region: Rect.fromCircle(
            center: Offset(
              d.centre.dx / trace.inchesPerPixel + trace.faceOriginPx.dx,
              d.centre.dy / trace.inchesPerPixel + trace.faceOriginPx.dy,
            ),
            radius: d.radius / trace.inchesPerPixel,
          ),
          confirmed: true,
          manual: true,
          imageSize: trace.imageSize,
          faceCentre: face?.centre,
          faceRadius: face?.radius,
        ),
    ];
  }

  List<AssessedDefect> get _allDefects =>
      [..._scan.assessed, ..._manualDefects];

  /// Confirmed defects in the cutting engine's millimetres, on the traced
  /// face. Empty without a trace: there is nothing to place them on.
  List<LogDefect> get _engineDefects {
    final trace = _trace;
    if (trace == null) return const [];

    final mmPerPixel = trace.inchesPerPixel * 25.4;

    return [
      for (final d in _scan.confirmedDefects)
        d.translated(-trace.faceOriginPx).scaled(mmPerPixel),
      for (final d in trace.defects) d.scaled(25.4),
    ];
  }

  String get _currentPlanKey {
    final defects = _engineDefects
        .map((d) =>
            "${d.centre.dx.round()},${d.centre.dy.round()},${d.radius.round()}")
        .join("|");

    return "${_trace?.girthInches}|$defects";
  }

  bool get _planStale => _plans != null && _planKey != _currentPlanKey;

  // --- actions ---------------------------------------------------------------

  Future<void> _importSavedLog() async {
    final rows = await LocalDB.getAllLogs();
    if (!mounted) return;

    final logs = rows.map(LogModel.fromMap).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final chosen = await showModalBottomSheet<LogModel>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _SavedLogSheet(logs: logs),
    );

    if (chosen == null || !mounted) return;

    HapticFeedback.selectionClick();

    setState(() {
      _linkedLogId = chosen.id;
      _girth.text = TimberVolumeCalculator.girthInchesFromDiameter(
        chosen.diameter,
      ).toStringAsFixed(1);
      _length.text = chosen.lengthFeet.toStringAsFixed(2);
      _source = "Saved log #${chosen.id}";
    });
  }

  Future<void> _choosePhoto() async {
    final file = await pickImage(
      context,
      title: "Photo of the cut face",
      cameraHint: "Square on to the log end, filling the frame",
      galleryHint: "A photo of this log's end you already took",
    );

    if (file == null || !mounted) return;

    setState(() {
      _photo = file;
      _trace = null;
    });

    // The scan starts now and runs while the user traces the face -- by the
    // time they come back it is usually finished.
    _scan.scan(file);

    await _traceFace();
  }

  Future<void> _traceFace() async {
    final photo = _photo;
    if (photo == null) return;

    final traced = await Navigator.push<LogFaceTraceResult?>(
      context,
      MaterialPageRoute(
        builder: (_) => LogFaceTraceScreen(
          photo: photo,
          initialGirthInches: _girthInches ?? _trace?.girthInches,
        ),
      ),
    );

    if (!mounted || traced == null) return;

    setState(() {
      _trace = traced;
      _girth.text = traced.girthInches.toStringAsFixed(1);
      _source = _linkedLogId == null
          ? "Tape girth + traced photo"
          : "Saved log #$_linkedLogId + traced photo";
    });

    final face = _tracedFacePx;
    if (face != null) _scan.useTracedFace(face.centre, face.radius);
  }

  Future<void> _reviewDefects() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DefectDetectionScreen(
          controller: _scan,
          reviewOnly: true,
        ),
      ),
    );

    _refresh();
  }

  Future<void> _planCut({bool reuseSetup = false}) async {
    final girth = _girthInches;
    final trace = _trace;

    SawingSetup? setup = reuseSetup ? _setup : null;

    if (setup == null) {
      final diameterMm = trace != null
          ? trace.outline.equivalentCircleDiameter * 25.4
          : (girth == null ? null : girth / math.pi * 25.4);

      setup = await showCuttingSetupSheet(
        context,
        logDiameterMm: diameterMm,
        logLengthMm: _lengthFeet == null ? null : _lengthFeet! * 304.8,
      );
    }

    if (setup == null || !mounted) return;

    setState(() {
      _setup = setup;
      _planning = true;
    });

    try {
      await _computePlans(setup);
    } finally {
      if (mounted) setState(() => _planning = false);
    }

    final plannedLengthFeet = setup.logLengthMm / 304.8;
    if (_lengthFeet == null ||
        (plannedLengthFeet - _lengthFeet!).abs() > 0.01) {
      _length.text = plannedLengthFeet.toStringAsFixed(2);
    }

    HapticFeedback.mediumImpact();
  }

  Future<void> _computePlans(SawingSetup setup) async {
    final trace = _trace;

    final outline = trace != null
        ? trace.outline.scaled(25.4)
        : LogFaceOutline.circle(setup.logDiameterMm);

    final defects = _engineDefects;
    final key = _currentPlanKey;

    final actual = await compute(
      SawingEngine.planBoth,
      setup.toRequest(
        outline,
        defects: defects,
        avoidDefects: defects.isNotEmpty,
      ),
    );

    final sound = defects.isEmpty
        ? actual
        : await compute(SawingEngine.planBoth, setup.toRequest(outline));

    if (!mounted) return;

    setState(() {
      _plans = actual;
      _soundPlans = sound;
      _planKey = key;
    });
  }

  Future<void> _generate() async {
    final girth = _girthInches;
    final length = _lengthFeet;
    final volume = _volume;

    if (girth == null || length == null || volume == null) return;

    HapticFeedback.lightImpact();

    setState(() {
      _generating = true;
      _stage = "Preparing…";
    });

    try {
      if (_planStale && _setup != null) {
        setState(() => _stage = "Updating the cutting plan…");
        await _computePlans(_setup!);
      }

      final trace = _trace;
      final setup = _setup;
      final plans = _plans;
      final plan = plans?.best;

      // --- impact, per defect ----------------------------------------------
      var impacts = <DefectImpact>[];
      final engineDefects = _engineDefects;

      if (trace != null && setup != null && engineDefects.isNotEmpty) {
        setState(() => _stage = "Measuring what each defect costs…");

        // Each defect is one more full sawing search, so the report measures
        // the eight largest individually. The total below always covers all
        // of them.
        final measured = [...engineDefects]
          ..sort((a, b) => b.radius.compareTo(a.radius));

        impacts = await compute(
          _impactsInBackground,
          _ImpactJob(
            trace.outline.scaled(25.4),
            measured.take(8).toList(),
            setup,
          ),
        );
      }

      // --- pictures --------------------------------------------------------
      setState(() => _stage = "Drawing the report…");

      final defectImage = _photo == null
          ? null
          : await _scan.renderOverlay(extraMarks: _manualMarks());

      final patternImage = plan == null ? null : await _renderPattern(plan);

      // --- words -----------------------------------------------------------
      final all = _allDefects;
      final sound = _soundPlans?.best?.boardVolumeCubicFeet;
      final actual = plan?.boardVolumeCubicFeet;
      final hasImpact = trace != null && sound != null && actual != null;
      final lost = hasImpact ? math.max(0.0, sound - actual) : 0.0;

      final advice = DefectAdvisor.advise(
        defects: all,
        hasTracedFace: trace != null,
        lostCubicFeet: lost,
        lostValue: lost * (setup?.pricePerCubicFoot ?? 0),
      );

      final prefs = UserPreferencesService.instance.current;
      final who = await _preparedBy();

      final axes = trace?.outline.axes;

      final data = LogReportData(
        reference: _reference,
        createdAt: _createdAt,
        species: _speciesName,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        preparedBy: who.name,
        company: who.company,
        girthInches: girth,
        lengthFeet: length,
        deductionInches: prefs.girthDeductionInches,
        volumeMethod: prefs.volumeMethod,
        volume: volume,
        cylinderCubicFeet: Calculator.calculateVolume(
          diameter: TimberVolumeCalculator.diameterInchesFromGirth(girth),
          lengthFeet: length,
        ),
        ratePerCubicFoot: _ratePerCubicFoot,
        measurementSource: _source,
        faceMajorInches: axes?.major,
        faceMinorInches: axes?.minor,
        defects: all,
        dismissedCount: _scan.dismissedCount,
        scanned: _scan.hasResult || _manualDefects.isNotEmpty,
        grade: LogQualityGrader.grade(all),
        advice: advice,
        defectImage: defectImage,
        impacts: impacts,
        soundYieldCubicFeet: hasImpact ? sound : null,
        actualYieldCubicFeet: hasImpact ? actual : null,
        comparison: plans,
        setup: setup,
        plan: plan,
        planAvoidsDefects: engineDefects.isNotEmpty && plan != null,
        patternImage: patternImage,
      );

      if (!mounted) return;

      HapticFeedback.mediumImpact();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LogReportScreen(data: data, logId: _linkedLogId),
        ),
      );
    } catch (error) {
      await DiagnosticsService.instance.recordError(
        module: DiagnosticsService.moduleReport,
        error: error,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't build the report. Try again."),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _generating = false;
          _stage = "";
        });
      }
    }
  }

  List<OverlayMark> _manualMarks() {
    final start = _scan.active.length;

    return [
      for (var i = 0; i < _manualDefects.length; i++)
        OverlayMark(
          region: _manualDefects[i].region,
          number: start + i + 1,
          label: _manualDefects[i].label,
          colour: DefectOverlayPainter.colourForKind(_manualDefects[i].kind),
        ),
    ];
  }

  /// The plan drawn on the photo (or on the outline, without one), as a PNG.
  Future<Uint8List?> _renderPattern(SawPlan plan) async {
    final trace = _trace;
    final photo = _scan.photo;

    if (trace != null && photo != null) {
      final size = trace.imageSize;
      final scale = 1100 / math.max(size.width, size.height);

      return paintToPng(
        SawingPatternPainter(
          plan: plan,
          mmPerPixel: trace.inchesPerPixel * 25.4,
          faceOriginPx: trace.faceOriginPx,
          imageSize: size,
          photo: photo,
          showCutNumbers: true,
        ),
        Size(size.width * scale, size.height * scale),
      );
    }

    // No photo to draw on: the outline alone, framed with a margin -- the
    // same frame the cutting result screen uses.
    final bounds = plan.outline.bounds;
    final pad = math.max(bounds.width, bounds.height) * 0.08 + 1;
    final frame = Size(bounds.width + pad * 2, bounds.height + pad * 2);
    final scale = 900 / math.max(frame.width, frame.height);

    return paintToPng(
      SawingPatternPainter(
        plan: plan,
        mmPerPixel: 1 / scale,
        faceOriginPx: Offset(pad - bounds.left, pad - bounds.top) * scale,
        imageSize: Size(frame.width * scale, frame.height * scale),
        showCutNumbers: true,
      ),
      Size(frame.width * scale, frame.height * scale),
    );
  }

  Future<({String? name, String? company})> _preparedBy() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return (name: null, company: null);

      final profile = await LocalDB.getUserProfile(user.uid);

      final name = (user.displayName?.trim().isNotEmpty ?? false)
          ? user.displayName!.trim()
          : (profile?["name"] as String?) ?? user.email;

      return (name: name, company: profile?["company"] as String?);
    } catch (_) {
      return (name: null, company: null);
    }
  }

  // --- build -----------------------------------------------------------------

  int get _sectionsDone => [
        _detailsReady,
        _photo != null,
        _scan.hasResult,
        _plans != null,
      ].where((d) => d).length;

  @override
  Widget build(BuildContext context) {
    final canGenerate = _detailsReady && !_scan.isBusy && !_planning;

    return Scaffold(
      appBar: AppBar(title: const Text("Log Passport")),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            FadeSlideIn(child: _intro()),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              child: _detailsStep(),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delay: const Duration(milliseconds: 110),
              child: _photoStep(),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delay: const Duration(milliseconds: 160),
              child: _defectStep(),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delay: const Duration(milliseconds: 210),
              child: _cuttingStep(),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delay: const Duration(milliseconds: 260),
              child: _notesStep(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            border: Border(top: BorderSide(color: AppTheme.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_detailsReady)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    "Enter the girth and length to generate the report.",
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                )
              else if (_scan.isBusy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    "Waiting for the defect scan to finish…",
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ),
              PrimaryAction(
                label: _generating ? _stage : "Generate Log Passport",
                icon: Icons.auto_awesome_rounded,
                busy: _generating,
                onPressed: canGenerate ? _generate : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge + 4),
        boxShadow: AppTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  gradient: AppTheme.timberGradient,
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Text(
                  _reference,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                "$_sectionsDone of 4 ready",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            "One log, fully documented",
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Measurements, defects, what they cost, the best cutting pattern "
            "and what to do — in one report you can hand to a buyer.",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _sectionsDone / 4),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.14),
                valueColor: const AlwaysStoppedAnimation(Color(0xFFE8C48F)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- 1. details ------------------------------------------------------------

  Widget _detailsStep() {
    final volume = _volume;
    final prefs = UserPreferencesService.instance.current;

    return _StepCard(
      number: 1,
      title: "Log details",
      subtitle: "Girth and length set the volume",
      done: _detailsReady,
      trailing: TextButton.icon(
        onPressed: _importSavedLog,
        icon: const Icon(Icons.download_rounded, size: 18),
        label: const Text("Saved log"),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Species",
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in _speciesOptions)
                ChoiceChip(
                  label: Text(option),
                  selected: _species == option,
                  showCheckmark: false,
                  onSelected: (on) {
                    HapticFeedback.selectionClick();
                    setState(() => _species = on ? option : null);
                  },
                ),
            ],
          ),
          if (_species == "Other") ...[
            const SizedBox(height: 10),
            TextField(
              controller: _otherSpecies,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: "Species name",
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _girth,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: "Girth",
                    suffixText: "in",
                    helperText: "Tape around the log",
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _length,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: "Length",
                    suffixText: "ft",
                    helperText: " ",
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: "Log price per ft³ (optional)",
              prefixText: "Rs. ",
            ),
          ),
          if (volume != null) ...[
            const SizedBox(height: 14),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppTheme.radius),
              ),
              child: Row(
                children: [
                  const Icon(Icons.view_in_ar_rounded,
                      color: AppTheme.primaryBright),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prefs.volumeMethod == VolumeMethod.referenceTable
                              ? "${volume.adi} adi ${volume.angal} angal"
                              : "${volume.cubicFeetDecimal.toStringAsFixed(3)} ft³",
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          "${volume.cubicFeetDecimal.toStringAsFixed(3)} ft³"
                          "${_ratePerCubicFoot > 0 ? '  ·  ${UnitDisplay.rupees(volume.cubicFeetDecimal * _ratePerCubicFoot, decimals: 0)}' : ''}",
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- 2. photo --------------------------------------------------------------

  Widget _photoStep() {
    final photo = _photo;
    final trace = _trace;

    return _StepCard(
      number: 2,
      title: "Cut face",
      subtitle: "One photo: traced for shape, scanned for defects",
      done: photo != null && trace != null,
      child: photo == null
          ? PrimaryAction(
              label: "Add a photo of the cut end",
              icon: Icons.add_a_photo_rounded,
              outlined: true,
              onPressed: _choosePhoto,
            )
          : Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: Image.file(photo, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (trace != null) ...[
                        const Pill(
                          text: "Face traced",
                          icon: Icons.check_rounded,
                          color: AppTheme.primaryBright,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "${trace.outline.axes.major.toStringAsFixed(1)} × "
                          "${trace.outline.axes.minor.toStringAsFixed(1)} in"
                          "${trace.defects.isEmpty ? '' : ' · ${trace.defects.length} marked by hand'}",
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ] else ...[
                        const Pill(
                          text: "Not traced yet",
                          icon: Icons.gesture_rounded,
                          color: AppTheme.accent,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Trace the face to measure what defects cost.",
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                      Row(
                        children: [
                          TextButton(
                            onPressed: _traceFace,
                            child:
                                Text(trace == null ? "Trace face" : "Retrace"),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: AppTheme.textSecondary,
                            ),
                            onPressed: _choosePhoto,
                            child: const Text("Change"),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // --- 3. defects ------------------------------------------------------------

  Widget _defectStep() {
    final Widget body;

    if (_photo == null) {
      body = const Text(
        "Add a photo above and the defect scan runs automatically.",
        style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      );
    } else if (_scan.isBusy) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _scan.phase == ScanPhase.scanning ? _scan.progress : null,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _scan.phase == ScanPhase.scanning
                ? "Scanning the face for cracks, holes and knots…"
                : "Checking the photo…",
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ],
      );
    } else if (_scan.phase == ScanPhase.failed) {
      body = Text(
        _scan.error ?? "The scan failed.",
        style: const TextStyle(fontSize: 13, color: AppTheme.error),
      );
    } else if (_scan.quality != null && !_scan.quality!.isUsable) {
      body = Text(
        _scan.quality!.message ?? "This photo can't be read reliably.",
        style: const TextStyle(fontSize: 13, color: AppTheme.warning),
      );
    } else if (!_scan.hasResult) {
      body = Text(
        _scan.detector.isAvailable
            ? "Waiting to scan…"
            : "No detection model is installed. Mark defects by hand while "
                "tracing the face.",
        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
      );
    } else {
      final all = _allDefects;
      final grade = LogQualityGrader.grade(all);
      final manual = _manualDefects.length;

      body = Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  all.isEmpty
                      ? "No defects found"
                      : "${all.length} defect${all.length == 1 ? '' : 's'}",
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in _scan.breakdown)
                      Pill(
                        text: "${entry.count} ${entry.label}",
                        color: DefectOverlayPainter.colourForKind(entry.kind),
                        dot: true,
                      ),
                    if (manual > 0)
                      Pill(
                        text: "$manual by hand",
                        color: AppTheme.primaryBright,
                        icon: Icons.touch_app_outlined,
                      ),
                    if (_scan.pendingCount > 0)
                      Pill(
                        text: "${_scan.pendingCount} to check",
                        color: AppTheme.accent,
                        icon: Icons.visibility_outlined,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _reviewDefects,
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text("Review & correct"),
                ),
              ],
            ),
          ),
          GradeBadge(grade: grade.grade, size: 52),
        ],
      );
    }

    return _StepCard(
      number: 3,
      title: "Defect scan",
      subtitle: "On-device AI, checked by you",
      done: _scan.hasResult && !_scan.isBusy,
      child: body,
    );
  }

  // --- 4. cutting ------------------------------------------------------------

  Widget _cuttingStep() {
    final plan = _plans?.best;

    final Widget body;

    if (_planning) {
      body = const Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              "Finding the best way to cut this log…",
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          ),
        ],
      );
    } else if (_plans == null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _trace == null
                ? "Plans on a round face of your girth. Trace the photo first "
                    "for the real shape, and to route boards around defects."
                : "Plans on the traced face, routing boards around confirmed "
                    "defects.",
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          PrimaryAction(
            label: "Plan the cut",
            icon: Icons.content_cut_rounded,
            outlined: true,
            onPressed:
                _detailsReady || _trace != null ? () => _planCut() : null,
          ),
        ],
      );
    } else if (plan == null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "No board of that size fits this log. Try a smaller board or a "
            "thinner blade.",
            style: TextStyle(fontSize: 13, color: AppTheme.warning),
          ),
          TextButton(
            onPressed: () => _planCut(),
            child: const Text("Change settings"),
          ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            plan.strategy.label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(label: "Boards", value: "${plan.boardCount}"),
              ),
              Expanded(
                child: StatTile(
                  label: "Sawn",
                  value: "${plan.boardVolumeCubicFeet.toStringAsFixed(2)} ft³",
                ),
              ),
              Expanded(
                child: StatTile(
                  label: "Yield",
                  value: "${plan.yieldPercent.toStringAsFixed(0)}%",
                ),
              ),
            ],
          ),
          if (_planStale) ...[
            const SizedBox(height: 12),
            InfoBanner(
              icon: Icons.sync_problem_rounded,
              color: AppTheme.accent,
              title: "The face or its defects changed",
              body: "The plan will be updated when you generate the report.",
              action: TextButton(
                onPressed: () => _planCut(reuseSetup: true),
                child: const Text("Update now"),
              ),
            ),
          ],
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => _planCut(),
            child: const Text("Change settings"),
          ),
        ],
      );
    }

    return _StepCard(
      number: 4,
      title: "Cutting plan",
      subtitle: "Pattern, boards and cut list",
      done: plan != null && !_planStale,
      child: body,
    );
  }

  Widget _notesStep() {
    return _StepCard(
      number: 5,
      title: "Notes",
      subtitle: "Optional — printed at the end",
      done: _notes.text.trim().isNotEmpty,
      optional: true,
      child: TextField(
        controller: _notes,
        minLines: 2,
        maxLines: 5,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => _refresh(),
        decoration: const InputDecoration(
          hintText: "Where it came from, who it's for, anything to remember",
        ),
      ),
    );
  }
}

/// A numbered section of the builder that ticks itself off when complete.
class _StepCard extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final bool done;
  final bool optional;
  final Widget child;
  final Widget? trailing;

  const _StepCard({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.child,
    this.optional = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: done ? AppTheme.brandGradient : null,
                  color: done ? null : AppTheme.surfaceMuted,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: done
                      ? const Icon(
                          Icons.check_rounded,
                          key: ValueKey("done"),
                          color: Colors.white,
                          size: 18,
                        )
                      : Text(
                          "$number",
                          key: const ValueKey("number"),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
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
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// Picks a log that was already measured and saved.
class _SavedLogSheet extends StatelessWidget {
  final List<LogModel> logs;

  const _SavedLogSheet({required this.logs});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat("d MMM yyyy");

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.line,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Use a saved log",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        "No saved logs yet. Measure one with Scan Log or the "
                        "Manual Calculator first.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                    itemCount: logs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final log = logs[i];
                      final girth =
                          TimberVolumeCalculator.girthInchesFromDiameter(
                        log.diameter,
                      );

                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radius),
                          side: const BorderSide(color: AppTheme.line),
                        ),
                        leading: const IconBadge(icon: Icons.forest_rounded),
                        title: Text(
                          "${girth.toStringAsFixed(1)} in girth × "
                          "${log.lengthFeet.toStringAsFixed(1)} ft",
                        ),
                        subtitle: Text(
                          "${log.volume.toStringAsFixed(2)} ft³ · "
                          "${log.stackId == null ? 'Single log' : 'In a stack'}"
                          " · ${date.format(log.createdAt)}",
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.pop(context, log),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
