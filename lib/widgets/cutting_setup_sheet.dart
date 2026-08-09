import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sawing_models.dart';
import '../services/user_preferences_service.dart';
import '../utils/calculator.dart';

/// Collects everything the sawing engine needs that the log itself cannot
/// tell us. Returns null if the user backs out.
Future<SawingSetup?> showCuttingSetupSheet(
  BuildContext context, {
  double? logDiameterMm,
  double? logLengthMm,
  bool measuredViaLidar = false,
}) {
  return showModalBottomSheet<SawingSetup>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CuttingSetupSheet(
      logDiameterMm: logDiameterMm,
      logLengthMm: logLengthMm,
      measuredViaLidar: measuredViaLidar,
    ),
  );
}

class CuttingSetupSheet extends StatefulWidget {
  final double? logDiameterMm;
  final double? logLengthMm;
  final bool measuredViaLidar;

  /// The thin end, when the scan measured a tapered log.
  ///
  /// This, not the average, is what a full-length board has to fit through,
  /// so it is what the board size is checked against.
  final double? smallEndDiameterMm;

  const CuttingSetupSheet({
    super.key,
    this.logDiameterMm,
    this.logLengthMm,
    this.measuredViaLidar = false,
    this.smallEndDiameterMm,
  });

  @override
  State<CuttingSetupSheet> createState() => _CuttingSetupSheetState();
}

class _CuttingSetupSheetState extends State<CuttingSetupSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController diameterController;
  late final TextEditingController lengthController;

  final boardWidthController = TextEditingController(text: "150");
  final thicknessController = TextEditingController(text: "50");
  final kerfController = TextEditingController(text: "3");
  final priceController = TextEditingController(text: "0");
  final minWidthController = TextEditingController(text: "75");
  final incrementController = TextEditingController();

  SawingMode _mode = SawingMode.fixedSize;

  double? get _smallEndDiameterMm => widget.smallEndDiameterMm;

  /// Only a sensor reading is locked. A traced outline also arrives as a
  /// measurement, but the user may still want to correct it by hand.
  bool get _logFieldsLocked => widget.measuredViaLidar;

  // Remembering the last setup is the whole of "presets" for a yard that
  // cuts the same product every day: they open the sheet and press go.
  static const _kMode = "saw_mode";
  static const _kWidth = "saw_board_width";
  static const _kThickness = "saw_thickness";
  static const _kKerf = "saw_kerf";
  static const _kPrice = "saw_price_ft3";
  static const _kMinWidth = "saw_min_width";
  static const _kIncrement = "saw_increment";

  @override
  void initState() {
    super.initState();

    diameterController = TextEditingController(
      text: widget.logDiameterMm?.toStringAsFixed(0) ?? "500",
    );
    lengthController = TextEditingController(
      text: widget.logLengthMm?.toStringAsFixed(0) ?? "3000",
    );

    diameterController.addListener(_refresh);
    lengthController.addListener(_refresh);

    _restoreLastUsed();
  }

  Future<void> _restoreLastUsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      setState(() {
        final storedMode = prefs.getString(_kMode);
        _mode = storedMode == SawingMode.fixedThickness.name
            ? SawingMode.fixedThickness
            : SawingMode.fixedSize;

        boardWidthController.text =
            prefs.getString(_kWidth) ?? boardWidthController.text;
        thicknessController.text =
            prefs.getString(_kThickness) ?? thicknessController.text;
        kerfController.text = prefs.getString(_kKerf) ?? kerfController.text;
        priceController.text = prefs.getString(_kPrice) ?? priceController.text;
        minWidthController.text =
            prefs.getString(_kMinWidth) ?? minWidthController.text;
        incrementController.text =
            prefs.getString(_kIncrement) ?? incrementController.text;
      });
    } catch (_) {
      // Remembering settings is a convenience; never let it block the sheet.
    }
  }

  Future<void> _rememberLastUsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(_kMode, _mode.name);
      await prefs.setString(_kWidth, boardWidthController.text);
      await prefs.setString(_kThickness, thicknessController.text);
      await prefs.setString(_kKerf, kerfController.text);
      await prefs.setString(_kPrice, priceController.text);
      await prefs.setString(_kMinWidth, minWidthController.text);
      await prefs.setString(_kIncrement, incrementController.text);
    } catch (_) {}
  }

  void _refresh() => setState(() {});

  /// Warns while the user is still typing, rather than only when they press
  /// the button: the fix is obvious at the moment the size becomes wrong.
  Widget _impossibleWarning() {
    final reason = _impossibleReason;
    if (reason == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(reason, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    diameterController.dispose();
    lengthController.dispose();
    boardWidthController.dispose();
    thicknessController.dispose();
    kerfController.dispose();
    priceController.dispose();
    minWidthController.dispose();
    incrementController.dispose();
    super.dispose();
  }

  double? get _volumeCubicFeet {
    final diameterMm = double.tryParse(diameterController.text);
    final lengthMm = double.tryParse(lengthController.text);

    if (diameterMm == null || lengthMm == null) return null;
    if (diameterMm <= 0 || lengthMm <= 0) return null;

    return Calculator.calculateVolume(
      diameter: diameterMm / 25.4,
      lengthFeet: lengthMm / 304.8,
    );
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required String unit,
    String? helper,
    bool readOnly = false,
    bool optional = false,
    VoidCallback? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        onChanged: onChanged == null ? null : (_) => onChanged(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return optional ? null : "Required";
          }

          final parsed = double.tryParse(value);
          if (parsed == null) return "Invalid number";
          if (parsed < 0) return "Cannot be negative";
          if (!optional && parsed <= 0) return "Must be greater than 0";

          return null;
        },
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          filled: readOnly,
          fillColor: Colors.green.withValues(alpha: 0.08),
          helperText: helper,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  /// Why the requested board cannot come out of this log, if it cannot.
  ///
  /// Checked before the search rather than after it. The engine would
  /// otherwise spend half a second trying every angle and offset and come
  /// back with "no plan", which tells the user nothing about what to change.
  String? get _impossibleReason {
    final diameter = double.tryParse(diameterController.text);
    final thickness = double.tryParse(thicknessController.text);

    if (diameter == null || thickness == null) return null;
    if (diameter <= 0) return null;

    // The board has to fit across the *thinnest* part of the log, because a
    // full-length board must pass through the whole thing.
    final acrossTheLog = _smallEndDiameterMm ?? diameter;

    if (thickness >= acrossTheLog) {
      return "A ${thickness.toStringAsFixed(0)} mm board is thicker than the "
          "log is wide (${acrossTheLog.toStringAsFixed(0)} mm).";
    }

    if (_mode != SawingMode.fixedSize) return null;

    final width = double.tryParse(boardWidthController.text);
    if (width == null) return null;

    if (width >= acrossTheLog) {
      return "A ${width.toStringAsFixed(0)} mm board is wider than the log "
          "(${acrossTheLog.toStringAsFixed(0)} mm across).";
    }

    // A rectangle only fits a round face if its diagonal does.
    final diagonal = math.sqrt(width * width + thickness * thickness);

    if (diagonal >= acrossTheLog) {
      return "A ${width.toStringAsFixed(0)} × ${thickness.toStringAsFixed(0)} "
          "mm board won't fit across a ${acrossTheLog.toStringAsFixed(0)} mm "
          "log — its corners fall outside.";
    }

    return null;
  }

  void _generate() {
    if (!_formKey.currentState!.validate()) return;

    final impossible = _impossibleReason;

    if (impossible != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(impossible)));
      return;
    }

    _rememberLastUsed();

    final increment = double.tryParse(incrementController.text.trim());

    Navigator.pop(
      context,
      SawingSetup(
        logDiameterMm: double.parse(diameterController.text),
        logLengthMm: double.parse(lengthController.text),
        mode: _mode,
        boardThicknessMm: double.parse(thicknessController.text),
        boardWidthMm: _mode == SawingMode.fixedSize
            ? double.parse(boardWidthController.text)
            : null,
        minBoardWidthMm: double.tryParse(minWidthController.text.trim()) ?? 50,
        widthIncrementMm:
            (increment != null && increment > 0) ? increment : null,
        kerfMm: double.parse(kerfController.text),
        pricePerCubicFoot: double.tryParse(priceController.text.trim()) ?? 0,
      ),
    );
  }

  Widget _modeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<SawingMode>(
          segments: const [
            ButtonSegment(
              value: SawingMode.fixedSize,
              label: Text("Exact size"),
              icon: Icon(Icons.crop_square, size: 18),
            ),
            ButtonSegment(
              value: SawingMode.fixedThickness,
              label: Text("Max yield"),
              icon: Icon(Icons.trending_up, size: 18),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          _mode == SawingMode.fixedSize
              ? "Every board the same size. Use this when filling an order."
              : "You set only the thickness; the app takes the widest boards "
                  "the log will give. Use this when you just want the most "
                  "timber out of the log.",
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _defectToggle() {
    return ValueListenableBuilder<UserPreferences>(
      valueListenable: UserPreferencesService.instance.listenable,
      builder: (context, prefs, _) {
        // The sheet paints its own white container, which sits between this
        // tile and the nearest Material -- without a transparent Material of
        // its own the switch's ink splash is painted underneath it.
        return Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: prefs.avoidDefects,
            onChanged: (value) =>
                UserPreferencesService.instance.setAvoidDefects(value),
            title: const Text("Avoid defects"),
            subtitle: Text(
              prefs.avoidDefects
                  ? "Boards are routed around rot, cracks and hollows marked "
                      "on the face. Fewer boards, but every one is sound."
                  : "Boards are packed across the whole face, defects and all.",
              style: const TextStyle(fontSize: 12),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final volume = _volumeCubicFeet;

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Form(
            key: _formKey,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const Text(
                  "How should this log be cut?",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _modeSelector(),
                const SizedBox(height: 20),
                Row(
                  children: [
                    _sectionTitle("Log"),
                    if (widget.measuredViaLidar) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          "Measured",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                _numberField(
                  controller: diameterController,
                  label: "Log diameter",
                  unit: "mm",
                  readOnly: _logFieldsLocked,
                  helper: "Only used if no face outline was traced.",
                ),
                _numberField(
                  controller: lengthController,
                  label: "Log length",
                  unit: "mm",
                  readOnly: _logFieldsLocked,
                ),
                if (volume != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.straighten, color: Colors.blue),
                        const SizedBox(width: 10),
                        Text(
                          "Log volume: ${volume.toStringAsFixed(2)} ft³",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                _sectionTitle("Boards"),
                if (_mode == SawingMode.fixedSize)
                  _numberField(
                    controller: boardWidthController,
                    label: "Board width",
                    unit: "mm",
                    onChanged: _refresh,
                  ),
                _numberField(
                  controller: thicknessController,
                  label: _mode == SawingMode.fixedSize
                      ? "Board thickness"
                      : "Board thickness (the only size you fix)",
                  unit: "mm",
                  onChanged: _refresh,
                ),
                _impossibleWarning(),
                if (_mode == SawingMode.fixedThickness) ...[
                  _numberField(
                    controller: minWidthController,
                    label: "Narrowest usable board",
                    unit: "mm",
                    helper: "Anything narrower is treated as slab waste "
                        "rather than a board.",
                  ),
                  _numberField(
                    controller: incrementController,
                    label: "Round widths down to (optional)",
                    unit: "mm",
                    optional: true,
                    helper: "Leave empty to take whatever width the log "
                        "gives. Set e.g. 25 to sell in standard widths.",
                  ),
                ],
                _numberField(
                  controller: kerfController,
                  label: "Saw kerf",
                  unit: "mm",
                  helper: "Timber the blade turns to sawdust on every pass.",
                ),
                _numberField(
                  controller: priceController,
                  label: "Price per ft³ (optional)",
                  unit: "Rs.",
                  optional: true,
                  helper: "Priced by volume, so it stays correct even when "
                      "board widths vary.",
                ),
                _defectToggle(),
                const SizedBox(height: 16),
                SizedBox(
                  height: 55,
                  child: ElevatedButton.icon(
                    onPressed: _generate,
                    icon: const Icon(Icons.auto_graph),
                    label: const Text(
                      "Plan the cut",
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Cancel"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
