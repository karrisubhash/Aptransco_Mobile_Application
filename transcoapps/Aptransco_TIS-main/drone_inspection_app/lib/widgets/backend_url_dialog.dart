import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// Shows the backend-URL editor and persists the choice. Returns true if the
/// URL was changed, so the caller can retry whatever failed.
///
/// On corporate Wi-Fi that intercepts TLS (a FortiGate doing SSL inspection),
/// the ngrok HTTPS host fails with a certificate error — point this at the
/// laptop directly over plain HTTP on the LAN instead. Leave it blank in the
/// field to use the ngrok default over mobile data.
///
/// Nothing calls this today: the entry points were taken out of the app bars and
/// the login screen. It is kept for the corp-Wi-Fi case, so it is wired up ready
/// to use rather than left in the broken state those screens were removed with.
Future<bool> editBackendUrl(BuildContext context) async {
  // Null means cancelled (or the barrier was tapped); an empty string is a
  // deliberate "clear the override and use the default".
  final entered = await showDialog<String>(
    context: context,
    builder: (_) => const _BackendUrlDialog(),
  );
  if (entered == null) return false;
  await ApiService.setBaseUrl(entered);
  return true;
}

/// The editor itself. A widget rather than an inline `AlertDialog` so the field's
/// controller is disposed with the route: disposing it as soon as `showDialog`
/// resolved crashed on dismissal, because the route stays mounted for its exit
/// transition and rebuilt the TextField against a disposed controller.
class _BackendUrlDialog extends StatefulWidget {
  const _BackendUrlDialog();

  @override
  State<_BackendUrlDialog> createState() => _BackendUrlDialogState();
}

class _BackendUrlDialogState extends State<_BackendUrlDialog> {
  final _ctl = TextEditingController(
    text: ApiService.hasBaseUrlOverride ? ApiService.baseUrl : '',
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Backend URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'On corporate Wi-Fi (SSL inspection) point this at the laptop over '
            'plain HTTP, e.g. http://192.168.137.1:8000/api\n\n'
            'Leave blank to use the default over mobile data:',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(ApiService.defaultBaseUrl,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'http://192.168.137.1:8000/api',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
