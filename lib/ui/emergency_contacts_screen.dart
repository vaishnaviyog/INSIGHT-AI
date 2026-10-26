import 'package:flutter/material.dart';
import '../models/emergency_contact.dart';
import '../services/emergency_service.dart';

/// Minimal contact list management for [EmergencyService]. Add and
/// remove only, consistent with the "prepare architecture, keep scope
/// contained" spirit of this milestone — editing an existing contact
/// isn't supported yet (delete + re-add covers it for now).
class EmergencyContactsScreen extends StatefulWidget {
  final EmergencyService emergencyService;

  const EmergencyContactsScreen({super.key, required this.emergencyService});

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
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

    widget.emergencyService.addContact(EmergencyContact(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      phoneNumber: phone,
    ));
    _nameController.clear();
    _phoneController.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.emergencyService.contacts;

    return Scaffold(
      appBar: AppBar(title: const Text('Emergency Contacts')),
      body: Column(
        children: [
          Expanded(
            child: contacts.isEmpty
                ? const Center(child: Text('No emergency contacts added yet.'))
                : ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      return ListTile(
                        title: Text(contact.name),
                        subtitle: Text(contact.phoneNumber),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await widget.emergencyService.removeContact(contact.id);
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Contact name'),
                ),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _addContact,
                  child: const Text('Add Contact'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
