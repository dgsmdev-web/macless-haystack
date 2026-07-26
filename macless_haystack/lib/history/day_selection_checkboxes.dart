import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Displays one checkbox per calendar day, going back up to 7 days
/// (today plus the 6 previous days). Each day can be shown or hidden
/// independently — unlike the old slider, days are not cumulative, so
/// selecting only "3 days ago" shows just that day's points, without
/// mixing in any other day.
class DaySelectionCheckboxes extends StatelessWidget {
  /// Which day offsets (0 = today, 6 = six days ago) are currently
  /// selected/visible.
  final Set<int> selectedDayOffsets;

  /// How many days back to offer (fixed at 6, so together with today
  /// that's always exactly 7 checkboxes) — no longer tied to how much
  /// history data currently exists, so the set of buttons stays stable
  /// regardless of data timing.
  final int maxDayOffset;

  /// Called with the full updated set whenever a day is toggled.
  final ValueChanged<Set<int>> onChanged;

  const DaySelectionCheckboxes({
    super.key,
    required this.selectedDayOffsets,
    required this.maxDayOffset,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateFormat = DateFormat('EEE d MMM');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Which days to show?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 0,
            // Oldest day first (left), Today last (right).
            children: List.generate(maxDayOffset + 1, (i) => maxDayOffset - i)
                .map((offset) {
              final day = today.subtract(Duration(days: offset));
              final label = offset == 0 ? 'Today' : dateFormat.format(day);
              final selected = selectedDayOffsets.contains(offset);

              return FilterChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: selected,
                onSelected: (bool value) {
                  final updated = Set<int>.from(selectedDayOffsets);
                  if (value) {
                    updated.add(offset);
                  } else {
                    updated.remove(offset);
                  }
                  onChanged(updated);
                },
              );
            }).toList(),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => onChanged(
                    Set<int>.from(List.generate(maxDayOffset + 1, (i) => i))),
                child: const Text('All'),
              ),
              TextButton(
                onPressed: () => onChanged({}),
                child: const Text('None'),
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }
}
