import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/log_report.dart';
import '../models/sawing_models.dart';
import '../utils/timber_volume.dart';
import '../utils/unit_display.dart';
import 'defect_advisor.dart';
import 'defect_impact.dart';

/// Prints a [LogReportData] as a Log Passport PDF.
///
/// Laid out like a document a buyer would keep: a brand band, the grade and
/// the four numbers that matter up front, then one numbered section per
/// question -- how big, what is wrong with it, what that costs, how to cut
/// it, what to do. Every page carries the reference and a page count so a
/// loose sheet can always be put back with its log.
class LogReportPdf {
  const LogReportPdf._();

  static final _date = DateFormat("d MMM yyyy, h:mm a");

  static const _brand = PdfColor.fromInt(0xFF1E4D3A);
  static const _brandDeep = PdfColor.fromInt(0xFF12332A);
  static const _accent = PdfColor.fromInt(0xFFC0894A);
  static const _ink = PdfColor.fromInt(0xFF17211C);
  static const _muted = PdfColor.fromInt(0xFF5E6862);
  static const _faint = PdfColor.fromInt(0xFF8E968F);
  static const _line = PdfColor.fromInt(0xFFE5E2D9);
  static const _paper = PdfColor.fromInt(0xFFF6F5F1);
  static const _high = PdfColor.fromInt(0xFFC0392B);
  static const _medium = PdfColor.fromInt(0xFFE07A2E);
  static const _good = PdfColor.fromInt(0xFF2E8B57);

  /// The standard PDF fonts only carry Latin-1. Anything outside it -- the
  /// app's em dashes and curly quotes -- would print as a blank box, so it is
  /// swapped for the nearest plain character before it reaches the page.
  static String _t(String text) {
    const map = {
      "—": "-",
      "–": "-",
      "…": "...",
      "’": "'",
      "‘": "'",
      "“": '"',
      "”": '"',
      "≈": "~",
      "→": "->",
      "ft³": "cu ft",
      "m³": "cu m",
      "in³": "cu in",
    };

    var out = text;
    map.forEach((from, to) => out = out.replaceAll(from, to));

    return String.fromCharCodes(
      out.runes.map((r) => r <= 0xFF ? r : 0x3F),
    );
  }

  static PdfColor _gradeColour(LogGrade grade) => switch (grade) {
        LogGrade.prime => _good,
        LogGrade.select => const PdfColor.fromInt(0xFF4F9D69),
        LogGrade.standard => _medium,
        LogGrade.utility => _high,
      };

  static PdfColor _priorityColour(AdvicePriority priority) =>
      switch (priority) {
        AdvicePriority.critical => _high,
        AdvicePriority.important => _accent,
        AdvicePriority.tip => _brand,
      };

  static String _priorityLabel(AdvicePriority priority) => switch (priority) {
        AdvicePriority.critical => "DO THIS FIRST",
        AdvicePriority.important => "RECOMMENDED",
        AdvicePriority.tip => "GOOD TO KNOW",
      };

  static String _size(double extent) {
    if (extent < 0.08) return "Small";
    if (extent < 0.2) return "Medium";
    return "Large";
  }

  /// Builds the document and writes it to the app's documents folder.
  static Future<File> write(LogReportData data) async {
    final bytes = await build(data);

    final dir = await getApplicationDocumentsDirectory();
    final safeRef = data.reference.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_");
    final file = File("${dir.path}/SmartLog_LogPassport_$safeRef.pdf");

    await file.writeAsBytes(bytes);
    return file;
  }

  static Future<Uint8List> build(LogReportData data) async {
    final doc = pw.Document(
      title: "Log Passport ${data.reference}",
      author: data.preparedBy ?? "SmartLog",
      creator: "SmartLog",
      subject: "Log assessment report",
    );

    final defectImage =
        data.defectImage == null ? null : pw.MemoryImage(data.defectImage!);
    final patternImage =
        data.patternImage == null ? null : pw.MemoryImage(data.patternImage!);

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 34),
          theme: pw.ThemeData.withFont(
            base: pw.Font.helvetica(),
            bold: pw.Font.helveticaBold(),
          ),
        ),
        header: (context) => context.pageNumber == 1
            ? pw.SizedBox()
            : pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 14),
                padding: const pw.EdgeInsets.only(bottom: 6),
                decoration: const pw.BoxDecoration(
                  border: pw.Border(bottom: pw.BorderSide(color: _line)),
                ),
                child: pw.Row(
                  children: [
                    pw.Text(
                      "LOG PASSPORT",
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: _brand,
                        letterSpacing: 1.2,
                      ),
                    ),
                    pw.Spacer(),
                    pw.Text(
                      data.reference,
                      style: const pw.TextStyle(fontSize: 9, color: _muted),
                    ),
                  ],
                ),
              ),
        footer: (context) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 12),
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _line)),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Text(
                  _t(
                    "Generated by SmartLog on ${_date.format(data.createdAt)}. "
                    "The SmartLog grade is an indicative assessment of the "
                    "visible face, not a certified grading.",
                  ),
                  style: const pw.TextStyle(fontSize: 7.5, color: _faint),
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Text(
                "Page ${context.pageNumber} of ${context.pagesCount}",
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        ),
        build: (context) => [
          _cover(data),
          pw.SizedBox(height: 16),
          _headline(data),
          ..._withHeading(_section("1", "Measurements"), [_measurements(data)]),
          ..._withHeading(
            _section("2", "Defects"),
            _defects(data, defectImage),
          ),
          ..._withHeading(_section("3", "Impact of defects"), _impact(data)),
          ..._withHeading(
            _section("4", "Cutting pattern"),
            _cutting(data, patternImage),
          ),
          ..._withHeading(_section("5", "Suggestions"), _advice(data)),
          if (data.notes != null && data.notes!.trim().isNotEmpty)
            ..._withHeading(_section("6", "Notes"), [
              pw.Text(
                _t(data.notes!.trim()),
                style: const pw.TextStyle(fontSize: 10.5),
              ),
            ]),
        ],
      ),
    );

    return doc.save();
  }

  // --- cover -----------------------------------------------------------------

  static pw.Widget _cover(LogReportData data) {
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: pw.BoxDecoration(
        gradient: const pw.LinearGradient(
          colors: [_brand, _brandDeep],
          begin: pw.Alignment.topLeft,
          end: pw.Alignment.bottomRight,
        ),
        borderRadius: pw.BorderRadius.circular(12),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  "SMARTLOG",
                  style: pw.TextStyle(
                    fontSize: 9,
                    color: const PdfColor.fromInt(0xFFE8C48F),
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  "Log Passport",
                  style: pw.TextStyle(
                    fontSize: 26,
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  _t(
                    [
                      if (data.species != null) data.species!,
                      "Full assessment of one log",
                    ].join("  -  "),
                  ),
                  style: const pw.TextStyle(
                    fontSize: 10.5,
                    color: PdfColor.fromInt(0xFFCFE0D6),
                  ),
                ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                data.reference,
                style: pw.TextStyle(
                  fontSize: 13,
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                _date.format(data.createdAt),
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColor.fromInt(0xFFCFE0D6),
                ),
              ),
              if (data.company != null && data.company!.isNotEmpty) ...[
                pw.SizedBox(height: 8),
                pw.Text(
                  _t(data.company!),
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
              if (data.preparedBy != null && data.preparedBy!.isNotEmpty)
                pw.Text(
                  _t("Prepared by ${data.preparedBy}"),
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColor.fromInt(0xFFCFE0D6),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _headline(LogReportData data) {
    final grade = data.grade.grade;
    final colour = _gradeColour(grade);

    final volumeMain = data.volumeMethod == VolumeMethod.referenceTable
        ? "${data.volume.adi} adi ${data.volume.angal} angal"
        : "${data.volume.cubicFeetDecimal.toStringAsFixed(2)} cu ft";

    final volumeNote = data.volumeMethod == VolumeMethod.referenceTable
        ? "${data.volume.cubicFeetDecimal.toStringAsFixed(3)} cu ft"
        : "cylinder volume";

    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: _paper,
        borderRadius: pw.BorderRadius.circular(10),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Container(
            width: 58,
            height: 58,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: colour,
              shape: pw.BoxShape.circle,
            ),
            child: pw.Text(
              grade.letter,
              style: pw.TextStyle(
                fontSize: 28,
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(width: 12),
          pw.SizedBox(
            width: 130,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  "SMARTLOG GRADE",
                  style: pw.TextStyle(
                    fontSize: 7.5,
                    color: _faint,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                pw.Text(
                  grade.label,
                  style: pw.TextStyle(
                    fontSize: 15,
                    color: colour,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  _t(grade.meaning),
                  style: const pw.TextStyle(fontSize: 8, color: _muted),
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
            child: pw.Row(
              children: [
                _keyFigure("Volume", volumeMain, volumeNote),
                _keyFigure(
                  "Girth",
                  "${data.girthInches.toStringAsFixed(1)} in",
                  "${(data.girthInches * 2.54).toStringAsFixed(1)} cm",
                ),
                _keyFigure(
                  "Length",
                  "${data.lengthFeet.toStringAsFixed(1)} ft",
                  "${(data.lengthFeet * 0.3048).toStringAsFixed(2)} m",
                ),
                _keyFigure(
                  "Defects",
                  data.scanned || data.defects.isNotEmpty
                      ? "${data.defects.length}"
                      : "-",
                  data.scanned ? "on the face" : "not scanned",
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _keyFigure(String label, String value, String note) {
    return pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.only(left: 6),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          borderRadius: pw.BorderRadius.circular(8),
          border: pw.Border.all(color: _line),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              label.toUpperCase(),
              style: pw.TextStyle(
                fontSize: 6.5,
                color: _faint,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              _t(value),
              style: pw.TextStyle(
                fontSize: 11,
                color: _ink,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              _t(note),
              style: const pw.TextStyle(fontSize: 7, color: _muted),
            ),
          ],
        ),
      ),
    );
  }

  // --- sections --------------------------------------------------------------

  /// A heading glued to the first thing under it.
  ///
  /// The page breaker moves whole widgets. On their own, a heading can be
  /// left alone at the foot of a page with its content starting overleaf;
  /// wrapped with its first block, the two always move together.
  static List<pw.Widget> _withHeading(
      pw.Widget heading, List<pw.Widget> content) {
    if (content.isEmpty) return [heading];

    // Inseparable, not just a Column: a Column is itself allowed to split
    // across pages, which is exactly the break this exists to prevent.
    return [
      pw.Inseparable(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [heading, content.first],
        ),
      ),
      ...content.skip(1),
    ];
  }

  static pw.Widget _section(String number, String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 20, bottom: 8),
      child: pw.Row(
        children: [
          pw.Container(
            width: 20,
            height: 20,
            alignment: pw.Alignment.center,
            decoration: const pw.BoxDecoration(
              color: _brand,
              shape: pw.BoxShape.circle,
            ),
            child: pw.Text(
              number,
              style: pw.TextStyle(
                fontSize: 9.5,
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 14,
              color: _ink,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(child: pw.Container(height: 1, color: _line)),
        ],
      ),
    );
  }

  static pw.Widget _row(String label, String value, {String? note}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            flex: 4,
            child: pw.Text(
              _t(label),
              style: const pw.TextStyle(fontSize: 9.5, color: _muted),
            ),
          ),
          pw.Expanded(
            flex: 5,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  _t(value),
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: _ink,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (note != null)
                  pw.Text(
                    _t(note),
                    textAlign: pw.TextAlign.right,
                    style: const pw.TextStyle(fontSize: 7.5, color: _faint),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _measurements(LogReportData data) {
    final method = data.volumeMethod == VolumeMethod.referenceTable
        ? "quarter girth"
        : "cylinder";

    final rows = <pw.Widget>[
      _row(
        "Girth",
        "${data.girthInches.toStringAsFixed(1)} in",
        note: "${(data.girthInches * 2.54).toStringAsFixed(1)} cm",
      ),
      _row(
        "Mean diameter",
        "${data.diameterInches.toStringAsFixed(1)} in",
        note: "${(data.diameterInches * 2.54).toStringAsFixed(1)} cm",
      ),
      if (data.hasFaceShape)
        _row(
          "Cut face (widest x narrowest)",
          "${data.faceMajorInches!.toStringAsFixed(1)} x "
              "${data.faceMinorInches!.toStringAsFixed(1)} in",
          note: "traced from the photo",
        ),
      _row(
        "Length",
        "${data.lengthFeet.toStringAsFixed(2)} ft",
        note: "${(data.lengthFeet * 0.3048).toStringAsFixed(2)} m",
      ),
      if (data.deductionInches > 0)
        _row(
          "Girth allowance",
          "-${data.deductionInches.toStringAsFixed(1)} in",
          note: "taken off before the volume",
        ),
      _row(
        "Volume ($method)",
        data.volumeMethod == VolumeMethod.referenceTable
            ? "${data.volume.adi} adi ${data.volume.angal} angal"
            : "${data.volume.cubicFeetDecimal.toStringAsFixed(3)} cu ft",
        note: data.volumeMethod == VolumeMethod.referenceTable
            ? "${data.volume.cubicFeetDecimal.toStringAsFixed(3)} cu ft"
            : null,
      ),
      _row(
        "Geometric volume",
        "${data.cylinderCubicFeet.toStringAsFixed(3)} cu ft",
        note:
            "${(data.cylinderCubicFeet * 0.0283168).toStringAsFixed(4)} cu m, "
            "no allowance",
      ),
      if (data.ratePerCubicFoot > 0) ...[
        _row("Rate", "${UnitDisplay.rupees(data.ratePerCubicFoot)} per cu ft"),
        _row("Log value", UnitDisplay.rupees(data.logValue)),
      ],
      _row("Measured by", data.measurementSource),
    ];

    return pw.Column(children: rows);
  }

  static List<pw.Widget> _defects(LogReportData data, pw.MemoryImage? image) {
    if (!data.scanned && data.defects.isEmpty) {
      return [
        _note(
          "No defect scan was made for this log. Photograph the cut face "
          "to include one.",
        ),
      ];
    }

    final widgets = <pw.Widget>[];

    if (image != null) {
      widgets.add(
        pw.Center(
          child: pw.ClipRRect(
            horizontalRadius: 8,
            verticalRadius: 8,
            child: pw.Image(image, height: 250, fit: pw.BoxFit.contain),
          ),
        ),
      );
      widgets.add(pw.SizedBox(height: 10));
    }

    if (data.defects.isEmpty) {
      widgets.add(
        _note(
          data.dismissedCount > 0
              ? "No defects. ${data.dismissedCount} mark"
                  "${data.dismissedCount == 1 ? ' was' : 's were'} checked "
                  "and dismissed."
              : "No defects found on this face.",
          colour: _good,
        ),
      );
      return widgets;
    }

    final summary = data.defectBreakdown
        .map((e) => "${e.count} ${e.label}${e.count == 1 ? '' : 's'}")
        .join(", ");

    widgets.add(
      pw.Text(
        _t("${data.defects.length} defect${data.defects.length == 1 ? '' : 's'}: $summary."),
        style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold),
      ),
    );

    if (data.grade.reasons.isNotEmpty) {
      widgets.add(pw.SizedBox(height: 2));
      widgets.add(
        pw.Text(
          _t(data.grade.reasons.join("  |  ")),
          style: const pw.TextStyle(fontSize: 9, color: _muted),
        ),
      );
    }

    widgets.add(pw.SizedBox(height: 8));

    widgets.add(
      pw.TableHelper.fromTextArray(
        headers: const ["#", "Defect", "Size", "Position", "Status"],
        data: [
          for (var i = 0; i < data.defects.length; i++)
            [
              "${i + 1}",
              _t(data.defects[i].label),
              _size(data.defects[i].extent),
              _t(data.defects[i].zone == DefectZone.unknown
                  ? "-"
                  : data.defects[i].zone.label),
              data.defects[i].manual
                  ? "Marked by hand"
                  : (data.defects[i].confirmed ? "Confirmed" : "Check by eye"),
            ],
        ],
        headerStyle: pw.TextStyle(
          fontSize: 8.5,
          color: PdfColors.white,
          fontWeight: pw.FontWeight.bold,
        ),
        headerDecoration: const pw.BoxDecoration(color: _brand),
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellAlignment: pw.Alignment.centerLeft,
        columnWidths: const {
          0: pw.FixedColumnWidth(22),
          1: pw.FlexColumnWidth(3),
          2: pw.FlexColumnWidth(2),
          3: pw.FlexColumnWidth(2.4),
          4: pw.FlexColumnWidth(2.6),
        },
        oddRowDecoration: const pw.BoxDecoration(color: _paper),
        border: null,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      ),
    );

    if (data.dismissedCount > 0) {
      widgets.add(pw.SizedBox(height: 4));
      widgets.add(
        pw.Text(
          "${data.dismissedCount} further mark"
          "${data.dismissedCount == 1 ? ' was' : 's were'} checked by eye and "
          "dismissed as not being defects.",
          style: const pw.TextStyle(fontSize: 8, color: _faint),
        ),
      );
    }

    return widgets;
  }

  static List<pw.Widget> _impact(LogReportData data) {
    if (!data.hasImpact) {
      return [
        _note(
          data.plan == null
              ? "Plan the cut in the report builder to measure what the "
                  "defects cost in boards."
              : "The face was not traced, so the defects could not be placed "
                  "on it. Trace the cut face to measure their cost.",
        ),
      ];
    }

    final rate = data.setup?.pricePerCubicFoot ?? 0;

    final widgets = <pw.Widget>[
      pw.Row(
        children: [
          _impactFigure(
            "If the face were sound",
            "${data.soundYieldCubicFeet!.toStringAsFixed(2)} cu ft",
            "of boards",
            _brand,
          ),
          _impactFigure(
            "With these defects",
            "${data.actualYieldCubicFeet!.toStringAsFixed(2)} cu ft",
            "of boards",
            _ink,
          ),
          _impactFigure(
            "Lost to defects",
            "${data.lostCubicFeet.toStringAsFixed(2)} cu ft",
            rate > 0
                ? UnitDisplay.rupees(data.lostValue, decimals: 0)
                : "of boards",
            data.lostCubicFeet > 0.005 ? _high : _good,
          ),
        ],
      ),
    ];

    if (data.impacts.isNotEmpty) {
      widgets.add(pw.SizedBox(height: 10));
      widgets.add(
        pw.TableHelper.fromTextArray(
          headers: [
            "Defect",
            "Severity",
            "Effect",
            "Boards lost",
            if (rate > 0) "Value",
          ],
          data: [
            for (final impact in data.impacts)
              [
                impact.defect.kind.name[0].toUpperCase() +
                    impact.defect.kind.name.substring(1),
                impact.severity.label,
                impact.blocksBoards ? "Blocks boards" : "Lowers grade",
                "${impact.lostCubicFeet.toStringAsFixed(2)} cu ft",
                if (rate > 0) UnitDisplay.rupees(impact.lostValue, decimals: 0),
              ],
          ],
          headerStyle: pw.TextStyle(
            fontSize: 8.5,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          headerDecoration: const pw.BoxDecoration(color: _brand),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerLeft,
          oddRowDecoration: const pw.BoxDecoration(color: _paper),
          border: null,
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
      );
      widgets.add(pw.SizedBox(height: 4));
      widgets.add(
        pw.Text(
          "Each row is measured with the other defects still present, so "
          "overlapping defects never claim the same loss twice.",
          style: const pw.TextStyle(fontSize: 8, color: _faint),
        ),
      );
    }

    return widgets;
  }

  static pw.Widget _impactFigure(
    String label,
    String value,
    String note,
    PdfColor colour,
  ) {
    return pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.only(right: 6),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: _paper,
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              label,
              style: const pw.TextStyle(fontSize: 8, color: _muted),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 13,
                color: colour,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(note,
                style: const pw.TextStyle(fontSize: 8, color: _faint)),
          ],
        ),
      ),
    );
  }

  static List<pw.Widget> _cutting(LogReportData data, pw.MemoryImage? image) {
    final plan = data.plan;

    if (plan == null) {
      return [
        _note(
          "No cutting plan was made. Plan the cut in the report builder to "
          "include the pattern and cut list.",
        ),
      ];
    }

    final kerfCubicFeet =
        (plan.kerfAreaMm2 * plan.logLengthMm) / (304.8 * 304.8 * 304.8);
    final edgingCubicFeet =
        (plan.edgingAreaMm2 * plan.logLengthMm) / (304.8 * 304.8 * 304.8);

    final sizes = <String, int>{};
    for (final board in plan.boards) {
      final key = "${board.width.round()} x ${board.thickness.round()} mm";
      sizes[key] = (sizes[key] ?? 0) + 1;
    }

    final other = data.comparison?.plans
        .where((p) => p.strategy != plan.strategy)
        .firstOrNull;

    final widgets = <pw.Widget>[
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (image != null)
            pw.Container(
              width: 210,
              margin: const pw.EdgeInsets.only(right: 14),
              child: pw.ClipRRect(
                horizontalRadius: 8,
                verticalRadius: 8,
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  _t("Recommended: ${plan.strategy.label}"),
                  style: pw.TextStyle(
                    fontSize: 12,
                    color: _brand,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  _t(plan.strategy.explanation),
                  style: const pw.TextStyle(fontSize: 8.5, color: _muted),
                ),
                if (data.planAvoidsDefects) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    "Boards are routed around the confirmed defects.",
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      color: _accent,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
                pw.SizedBox(height: 8),
                _row("Boards", "${plan.boardCount}"),
                _row(
                  "Sawn timber",
                  "${plan.boardVolumeCubicFeet.toStringAsFixed(3)} cu ft",
                ),
                _row("Yield", "${plan.yieldPercent.toStringAsFixed(1)} %"),
                _row("Sawdust", "${kerfCubicFeet.toStringAsFixed(3)} cu ft"),
                _row(
                  "Edgings and slabs",
                  "${edgingCubicFeet.toStringAsFixed(3)} cu ft",
                ),
                _row("Saw passes", "${plan.sawPasses}"),
                if (plan.pricePerCubicFoot > 0)
                  _row(
                    "Sawn value",
                    UnitDisplay.rupees(plan.value),
                    note:
                        "at ${UnitDisplay.rupees(plan.pricePerCubicFoot, decimals: 0)}"
                        " per cu ft",
                  ),
                if (other != null)
                  _row(
                    "Alternative: ${other.strategy.label}",
                    "${other.boardCount} boards, "
                        "${other.boardVolumeCubicFeet.toStringAsFixed(2)} cu ft",
                  ),
              ],
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      if (sizes.isNotEmpty)
        pw.TableHelper.fromTextArray(
          headers: const ["Finished size", "Quantity", "Length"],
          data: [
            for (final entry in sizes.entries)
              [
                entry.key,
                "${entry.value}",
                "${(plan.logLengthMm / 304.8).toStringAsFixed(2)} ft",
              ],
          ],
          headerStyle: pw.TextStyle(
            fontSize: 8.5,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          headerDecoration: const pw.BoxDecoration(color: _brand),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerLeft,
          oddRowDecoration: const pw.BoxDecoration(color: _paper),
          border: null,
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
      if (plan.cuts.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text(
          "Cut list - setbacks from the same reference face, in order",
          style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: const ["#", "Pass", "Setback (mm)"],
          data: [
            for (final cut in plan.cuts)
              [
                "${cut.order}",
                _t(cut.description),
                cut.setback.toStringAsFixed(1),
              ],
          ],
          headerStyle: pw.TextStyle(
            fontSize: 8.5,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          headerDecoration: const pw.BoxDecoration(color: _brandDeep),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          cellAlignment: pw.Alignment.centerLeft,
          columnWidths: const {
            0: pw.FixedColumnWidth(24),
            1: pw.FlexColumnWidth(5),
            2: pw.FlexColumnWidth(1.6),
          },
          oddRowDecoration: const pw.BoxDecoration(color: _paper),
          border: null,
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        ),
      ],
    ];

    return widgets;
  }

  static List<pw.Widget> _advice(LogReportData data) {
    if (data.advice.isEmpty) {
      return [_note("Nothing to add for this log.")];
    }

    return [
      for (var i = 0; i < data.advice.length; i++)
        // One card, one page: split across a break it leaves an empty stub.
        pw.Inseparable(
          child: pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.only(bottom: 6),
            padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 8),
            // Square corners: the PDF renderer only rounds a border that is the
            // same on all four sides, and this one is a single coloured edge.
            decoration: pw.BoxDecoration(
              color: _paper,
              border: pw.Border(
                left: pw.BorderSide(
                  color: _priorityColour(data.advice[i].priority),
                  width: 3,
                ),
              ),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  _priorityLabel(data.advice[i].priority),
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    color: _priorityColour(data.advice[i].priority),
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  _t("${i + 1}. ${data.advice[i].title}"),
                  style: pw.TextStyle(
                      fontSize: 10.5, fontWeight: pw.FontWeight.bold),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  _t(data.advice[i].body),
                  style: const pw.TextStyle(fontSize: 9, color: _muted),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  static pw.Widget _note(String text, {PdfColor colour = _muted}) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _paper,
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child:
          pw.Text(_t(text), style: pw.TextStyle(fontSize: 9.5, color: colour)),
    );
  }
}
