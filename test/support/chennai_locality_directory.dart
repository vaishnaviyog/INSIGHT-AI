/// A curated, geographically-spread set of REAL Chennai locality names
/// (not stop IDs, not route IDs) used as test/support infrastructure
/// for the network-wide routing correctness audit. Every string here
/// is a plausible spoken/typed destination request — none is a
/// fabricated place name. This file contains no production logic and
/// is imported only by tests.
///
/// Deliberately spans four geographic quadrants of Chennai (per the
/// explicit audit requirement) so no single region can be accidentally
/// over-represented, plus a scattering of colleges/hospitals/landmarks
/// distinct from pure locality names.
library;

class ChennaiLocalityDirectory {
  ChennaiLocalityDirectory._();

  static const List<String> north = [
    'Wimco Nagar',
    'Tondiarpet',
    'Washermanpet',
    'Royapuram',
    'Perambur',
  ];

  static const List<String> central = [
    'Chennai Central',
    'Egmore',
    'Egmore Railway Station',
    'Broadway',
    'Koyambedu',
    'CMBT',
    'Park Town',
  ];

  static const List<String> west = [
    'Ambattur',
    'Avadi',
    'Porur',
    'Vadapalani',
    'Ashok Nagar',
  ];

  static const List<String> south = [
    'Guindy',
    'Saidapet',
    'Adyar',
    'Velachery',
    'Pallavaram',
    'Chromepet',
    'Tambaram',
    'Tambaram Railway Station',
    'Sholinganallur',
    'Airport',
    'Chennai Airport',
    'T Nagar',
    'Anna Nagar',
    'VIT Chennai',
  ];

  /// Every locality across all four quadrants — the pool the
  /// destination-resolution statistics and the randomized network
  /// stress test both sample from.
  static List<String> get all => [...north, ...central, ...west, ...south];
}
