import 'package:flutter/material.dart';

import '../models/emergency_contact.dart';

/// Step 5 — [contacts] is the SAME list `EmergencyService.contacts`
/// already returns; this page only collects name/phone pairs and
/// reports them back via [onContactsChanged]. The parent
/// (OnboardingScreen / ProfileSettingsScreen) is responsible for
/// actually calling `EmergencyService.addContact`/`removeContact`, so
/// this widget never touches Hive or EmergencyService directly —
/// consistent with every other page in this module being a pure,
/// reusable form.
class EmergencySetupPage extends StatefulWidget {
  final List<EmergencyContact> contacts;
  final ValueChanged<List<EmergencyContact>> onContactsChanged;

  const EmergencySetupPage({
    super.key,
    required this.contacts,
    required this.onContactsChanged,
  });

  @override
  State<EmergencySetupPage> createState() => _EmergencySetupPageState();
}

class _EmergencySetupPageState extends State<EmergencySetupPage> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _addContact() {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    if (name.isEmpty || phone.isEmpty) return;

    final updated = [
      ...widget.contacts,
      EmergencyContact(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        phoneNumber: phone,
      ),
    ];
    widget.onContactsChanged(updated);
    _nameController.clear();
    _phoneController.clear();
  }

  void _removeContact(String id) {
    widget.onContactsChanged(widget.contacts.where((c) => c.id != id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Semantics(
          header: true,
          child: const Text('Emergency Setup',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        const Text(
          'Add trusted contacts who will automatically receive an SOS alert with '
          'your location if you ever trigger it. You can add as many as you like, '
          'and skip this step if you prefer.',
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Semantics(
          label: 'Contact name',
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Contact Name', border: OutlineInputBorder()),
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          label: 'Contact phone number',
          child: TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone Number', border: OutlineInputBorder()),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Semantics(
            button: true,
            label: 'Add contact',
            child: ElevatedButton.icon(
              onPressed: _addContact,
              icon: const Icon(Icons.add),
              label: const Text('Add Contact'),
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (widget.contacts.isEmpty)
          const Text('No emergency contacts added yet.', style: TextStyle(color: Colors.grey))
        else
          ...widget.contacts.map((contact) => Card(
                child: Semantics(
                  label: '${contact.name}, ${contact.phoneNumber}',
                  child: ListTile(
                    leading: const Icon(Icons.contact_emergency),
                    title: Text(contact.name),
                    subtitle: Text(contact.phoneNumber),
                    trailing: Semantics(
                      button: true,
                      label: 'Remove ${contact.name}',
                      child: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeContact(contact.id),
                      ),
                    ),
                  ),
                ),
              )),
      ],
    );
  }
}
