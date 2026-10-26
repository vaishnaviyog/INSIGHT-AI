/// A trusted contact who can receive an SOS message.
class EmergencyContact {
  final String id;
  final String name;
  final String phoneNumber;

  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phoneNumber,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'phoneNumber': phoneNumber,
      };

  factory EmergencyContact.fromMap(Map<dynamic, dynamic> map) => EmergencyContact(
        id: map['id'] as String,
        name: map['name'] as String,
        phoneNumber: map['phoneNumber'] as String,
      );
}
