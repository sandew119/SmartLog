import 'package:flutter/material.dart';

import '../services/user_preferences_service.dart';
import '../utils/timber_volume.dart';

/// The user's measurement settings, shown in their profile. These apply to
/// every volume the app calculates, so the card explains what each option
/// actually does rather than just naming it.
class MeasurementSettingsCard extends StatefulWidget {
  const MeasurementSettingsCard({super.key});

  @override
  State<MeasurementSettingsCard> createState() =>
      _MeasurementSettingsCardState();
}

class _MeasurementSettingsCardState extends State<MeasurementSettingsCard> {
  final _service = UserPreferencesService.instance;
  late final TextEditingController _deductionController;

  @override
  void initState() {
    super.initState();

    final current = _service.current.girthDeductionInches;
    _deductionController = TextEditingController(
      text: current > 0 ? _trim(current) : "",
    );
  }

  @override
  void dispose() {
    _deductionController.dispose();
    super.dispose();
  }

  static String _trim(double value) {
    // Show "2" rather than "2.0", but keep real decimals.
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
  }

  Future<void> _onDeductionChanged(String raw) async {
    final trimmed = raw.trim();

    if (trimmed.isEmpty) {
      await _service.setGirthDeductionInches(0);
      return;
    }

    final parsed = double.tryParse(trimmed);
    // Ignore intermediate un-parseable states (e.g. the user has typed just
    // "." on the way to "0.5") rather than resetting their input.
    if (parsed == null) return;

    await _service.setGirthDeductionInches(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UserPreferences>(
      valueListenable: _service.listenable,
      builder: (context, prefs, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.straighten, color: Colors.green),
                    const SizedBox(width: 10),
                    const Text(
                      "Measurement Settings",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 4),

                const Text(
                  "Applied to every log volume this app calculates.",
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),

                const SizedBox(height: 12),

                RadioGroup<VolumeMethod>(
                  groupValue: prefs.volumeMethod,
                  onChanged: (value) {
                    if (value != null) _service.setVolumeMethod(value);
                  },
                  child: const Column(
                    children: [
                      RadioListTile<VolumeMethod>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: VolumeMethod.referenceTable,
                        title: Text("Sri Lankan Method (ගණ අඩි)"),
                        subtitle: Text(
                          "Quarter-girth measure from the timber "
                          "ready-reckoner, shown as adi + angal exactly as "
                          "the book prints them.",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      RadioListTile<VolumeMethod>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: VolumeMethod.standard,
                        title: Text("Standard Method"),
                        subtitle: Text(
                          "True cylinder volume, shown as decimal cubic feet.",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 24),

                TextField(
                  controller: _deductionController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: _onDeductionChanged,
                  decoration: const InputDecoration(
                    labelText: "Girth Deduction",
                    hintText: "0",
                    suffixText: "inches",
                    isDense: true,
                    border: OutlineInputBorder(),
                    helperText:
                        "Subtracted from each girth measurement (e.g. a bark "
                        "allowance) before volume is calculated.",
                    helperMaxLines: 3,
                  ),
                ),

                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}
