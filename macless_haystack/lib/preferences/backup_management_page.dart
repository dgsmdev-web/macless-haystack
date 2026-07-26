import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:macless_haystack/accessory/accessory_registry.dart';

/// Lets the user review accessories that were deleted but whose location
/// history is still kept as a backup (restored automatically if the
/// same accessory is ever re-added — see [AccessoryRegistry.addAccessory]),
/// and permanently purge that backup if it's no longer wanted. Also
/// offers restoring the separate rolling hourly history snapshot, as a
/// safety net against accidental data loss in general.
class BackupManagementPage extends StatefulWidget {
  const BackupManagementPage({super.key});

  @override
  State<BackupManagementPage> createState() => _BackupManagementPageState();
}

class _BackupManagementPageState extends State<BackupManagementPage> {
  List<Map<String, dynamic>> _deleted = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var registry = Provider.of<AccessoryRegistry>(context, listen: false);
    var index = await registry.getDeletedAccessoriesIndex();
    if (!mounted) return;
    setState(() {
      _deleted = index;
      _loading = false;
    });
  }

  Future<void> _purge(String id, String name) async {
    var confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Backup Permanently?'),
        content: Text(
            'This permanently erases the saved history for "$name". '
            'If you add this accessory again later, its history will '
            'NOT be restored anymore. This cannot be undone.'),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var registry = Provider.of<AccessoryRegistry>(context, listen: false);
    await registry.purgeDeletedAccessoryHistory(id);
    await _load();
  }

  Future<void> _restoreHourlySnapshot() async {
    var registry = Provider.of<AccessoryRegistry>(context, listen: false);
    var recovered = await registry.restoreHistoryFromBackup();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(recovered > 0
            ? 'Recovered $recovered location point(s) from the last backup.'
            : 'Nothing to recover — current data already matches the backup.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deleted Accessory Backups')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                ListTile(
                  title: const Text('Restore recent history snapshot'),
                  subtitle: const Text(
                      'Merges back the last automatic hourly backup for all current accessories'),
                  leading: const Icon(Icons.restore),
                  onTap: _restoreHourlySnapshot,
                ),
                const Divider(),
                Expanded(
                  child: _deleted.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24.0),
                            child: Text(
                              'No deleted accessories with recoverable history.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _deleted.length,
                          itemBuilder: (context, index) {
                            var entry = _deleted[index];
                            var name = entry['name'] ?? 'Unknown';
                            var deletedAt = entry['deletedAt'] ?? '';
                            return ListTile(
                              title: Text(name),
                              subtitle: Text('Deleted: $deletedAt'),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_forever,
                                    color: Colors.red),
                                tooltip: 'Delete backup permanently',
                                onPressed: () =>
                                    _purge(entry['id'], name),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
