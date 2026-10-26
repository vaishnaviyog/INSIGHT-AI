/// One resolvable destination: a human-readable display name, a
/// SEARCH QUERY STRING (fed to the EXISTING
/// `LocationService.getCoordinatesFromAddress` geocoder — this
/// dictionary never fabricates coordinates itself, only gives the
/// geocoder a better string to work with than raw, possibly-
/// misheard STT output), and every alias (short forms, common STT
/// mistakes, Tamil/Hindi names) that should resolve to it.
class DestinationAliasEntry {
  final String canonicalDisplayName;
  final String canonicalSearchQuery;
  final List<String> aliases;

  const DestinationAliasEntry({
    required this.canonicalDisplayName,
    required this.canonicalSearchQuery,
    required this.aliases,
  });
}

/// A starting set of Chennai-area destinations, deliberately NOT
/// exhaustive — covers the specific examples this phase named
/// (Central, Airport, CMBT, Guindy + its common STT mistakes,
/// Tambaram, landmarks) plus the other named test locations from
/// prior stages, so the same places are resolvable by name, not just
/// by coordinate. Extending this list (a new city, more landmarks) is
/// adding entries here — no code changes needed elsewhere, which is
/// the "modular architecture for future languages/places" this phase
/// asked for.
class DestinationAliasDictionary {
  DestinationAliasDictionary._();

  static const List<DestinationAliasEntry> entries = [
    DestinationAliasEntry(
      canonicalDisplayName: 'Chennai Central',
      canonicalSearchQuery: 'Chennai Central Railway Station, Chennai',
      aliases: [
        'central', 'chennai central', 'சென்ட்ரல்', 'சென்னை சென்ட்ரல்', 'சென்ட்ரல் ரயில் நிலையம்',
        'सेंट्रल', 'चेन्नई सेंट्रल',
      ],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Chennai International Airport',
      canonicalSearchQuery: 'Chennai International Airport',
      aliases: ['airport', 'chennai airport', 'international airport', 'விமான நிலையம்', 'हवाई अड्डा', 'एयरपोर्ट'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Puratchi Thalaivar Dr. MGR Bus Terminus (CMBT)',
      canonicalSearchQuery: 'CMBT Koyambedu Chennai',
      aliases: ['cmbt', 'koyambedu', 'koyambedu bus terminus', 'mgr bus terminus', 'கோயம்பேடு', 'कोयंबेडु'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Guindy',
      canonicalSearchQuery: 'Guindy, Chennai',
      aliases: ['guindy', 'gundy', 'kindy', 'gindy', 'guindi', 'கிண்டி', 'गिंडी'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Tambaram',
      canonicalSearchQuery: 'Tambaram, Chennai',
      aliases: ['tambaram', 'tambram', 'thambaram', 'தாம்பரம்', 'தம்பரம்', 'तांबरम'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Egmore',
      canonicalSearchQuery: 'Egmore Railway Station, Chennai',
      aliases: ['egmore', 'egmoor', 'எழும்பூர்', 'एग्मोर'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Marina Beach',
      canonicalSearchQuery: 'Marina Beach, Chennai',
      aliases: ['marina', 'marina beach', 'மெரினா பீச்', 'மெரினா கடற்கரை', 'मरीना बीच'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'T Nagar',
      canonicalSearchQuery: 'T Nagar, Chennai',
      aliases: ['t nagar', 'tnagar', 'thiyagaraya nagar', 'தி நகர்', 'टी नगर'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Velachery',
      canonicalSearchQuery: 'Velachery, Chennai',
      aliases: ['velachery', 'velacherry', 'வேளச்சேரி', 'वेलाचेरी'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Adyar',
      canonicalSearchQuery: 'Adyar, Chennai',
      aliases: ['adyar', 'அடையார்', 'अडयार'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Saidapet',
      canonicalSearchQuery: 'Saidapet, Chennai',
      aliases: ['saidapet', 'சைதாப்பேட்டை', 'सैदापेट'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Anna Nagar',
      canonicalSearchQuery: 'Anna Nagar, Chennai',
      aliases: ['anna nagar', 'annanagar', 'அண்ணா நகர்', 'अन्ना नगर'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'VIT Chennai',
      canonicalSearchQuery: 'VIT Chennai, Kelambakkam',
      aliases: ['vit', 'vit chennai', 'vit university', 'वीआईटी चेन्नई'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Phoenix MarketCity',
      canonicalSearchQuery: 'Phoenix MarketCity, Velachery, Chennai',
      aliases: ['phoenix mall', 'phoenix marketcity', 'phoenix', 'फीनिक्स मॉल'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Express Avenue Mall',
      canonicalSearchQuery: 'Express Avenue Mall, Chennai',
      aliases: ['express avenue', 'ea mall', 'express avenue mall', 'एक्सप्रेस एवेन्यू'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'LIC Building',
      canonicalSearchQuery: 'LIC Building, Chennai',
      aliases: ['lic', 'lic building', 'एल आई सी'],
    ),
    DestinationAliasEntry(
      canonicalDisplayName: 'Government General Hospital',
      canonicalSearchQuery: 'Government General Hospital, Chennai',
      aliases: ['government hospital', 'general hospital', 'ghh', 'सरकारी अस्पताल'],
    ),
  ];

  /// Every (aliasText, entry) pair flattened — built once, reused by
  /// `DestinationResolver` for both exact and fuzzy lookup.
  static final List<(String alias, DestinationAliasEntry entry)> flattenedAliases = [
    for (final entry in entries)
      for (final alias in entry.aliases) (alias, entry),
  ];
}
