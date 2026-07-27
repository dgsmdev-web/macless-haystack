
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:macless_haystack/item_management/item_file_import.dart';
import 'dart:io';

class NewKeyAction extends StatelessWidget {
  /// If the action button is small.
  final bool mini;

  /// Displays a floating button that opens the file picker directly to
  /// import an accessory from a JSON file.
  ///
  /// This used to open an intermediate bottom sheet with a choice
  /// between "Import from JSON File" and "Create new Accessory" — now
  /// that only the JSON import option remains, that extra step was
  /// removed and the button jumps straight to the file picker.
  const NewKeyAction({
    super.key,
    this.mini = false,
  });

  /// Opens the file picker to import an accessory from a JSON file.
  Future<void> pickAccessoryFile(BuildContext context) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Выберите свой файл метки',
    );

    if (result != null) {
      var uploadfile = result.files.single.bytes;
      if (uploadfile != null && context.mounted) {
        Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ItemFileImport(bytes: uploadfile),
            ));
      } else if (result.paths.isNotEmpty) {
        String? filePath = result.paths[0];
        if (filePath != null) {
          var fileAsBytes = await File(filePath).readAsBytes();
          if (context.mounted) {
            Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ItemFileImport(bytes: fileAsBytes),
                ));
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      mini: mini,
      heroTag: null,
      onPressed: () {
        pickAccessoryFile(context);
      },
      tooltip: 'Import from JSON File',
      child: const Icon(Icons.add),
    );
  }
}
