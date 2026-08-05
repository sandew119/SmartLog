import 'log_model.dart';
import 'stack_model.dart';

/// A single entry in the combined "everything saved" list: either a stack
/// or a standalone log, both carrying a [createdAt] for chronological
/// sorting/display.
class SavedItem {
  final StackModel? stack;
  final int logCount;
  final LogModel? log;

  SavedItem.stack(StackModel this.stack, {required this.logCount}) : log = null;

  SavedItem.log(LogModel this.log)
      : stack = null,
        logCount = 0;

  DateTime get createdAt => stack?.createdAt ?? log!.createdAt;
}
