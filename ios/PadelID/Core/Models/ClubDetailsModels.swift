import Foundation

/// The richer directory keeps the original identity and affiliations intact.
/// Optional fields also decode the directory served by older gateways.
nonisolated struct ClubCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let cityId: Int
    let playersCount: Int
    let cityName: String?
    let description: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let photoUrls: [String]?
    let amenities: [String]?
    let contactPhone: String?
    let websiteUrl: String?
    let bookingUrl: String?
    let bookingVerifiedAt: Date?
    let metadataVersion: Int?
    let updatedAt: Date?
    let courtsCount: Int?
    let courts: [ClubCourt]?
    let viewer: ClubViewer?

    var club: Club { Club(id: id, name: name, cityId: cityId, playersCount: playersCount) }
    var coordinates: ClubCoordinates? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return ClubCoordinates(latitude: latitude, longitude: longitude)
    }
    var photos: [URL] { (photoUrls ?? []).compactMap(ClubExternalURL.publicHTTPS) }
    var officialBookingURL: URL? {
        guard bookingVerifiedAt != nil else { return nil }
        return bookingUrl.flatMap(ClubExternalURL.publicHTTPS)
    }
}

nonisolated struct ClubCoordinates: Hashable, Sendable { let latitude: Double; let longitude: Double }
nonisolated struct ClubViewer: Codable, Hashable, Sendable { let canEdit: Bool }
nonisolated struct ClubCourt: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let clubId: Int
    let name: String
    let indoor: Bool
    let surface: String
    let description: String
    let isActive: Bool
    let version: Int
    let updatedAt: Date
}

nonisolated enum ClubExternalURL {
    /// Public club links are opened separately, never through the authenticated
    /// API transport. Do not attach account credentials to a third-party URL.
    static func publicHTTPS(_ raw: String) -> URL? {
        guard raw.count <= 2048, raw.rangeOfCharacter(from: .controlCharacters) == nil,
              raw.range(of: #"^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(/[^\s\\]*)?$"#, options: .regularExpression) != nil,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".invalid"), !host.hasSuffix(".example"),
              !host.hasSuffix(".test"), host != "localhost", !host.contains(":"), url.port == nil else { return nil }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-"
            && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { return nil }
        return url
    }
}

nonisolated struct ClubMetadataBody: Encodable, Sendable {
    let version: Int
    let description: String
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let photoUrls: [String]
    let amenities: [String]
    let contactPhone: String?
    let websiteUrl: String?
    let bookingUrl: String?
    let bookingVerified: Bool
    let reason: String

    enum CodingKeys: String, CodingKey {
        case version, description, address, latitude, longitude, photoUrls, amenities
        case contactPhone, websiteUrl, bookingUrl, bookingVerified, reason
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(description, forKey: .description)
        try values.encode(address, forKey: .address)
        try values.encode(latitude, forKey: .latitude)
        try values.encode(longitude, forKey: .longitude)
        try values.encode(photoUrls, forKey: .photoUrls)
        try values.encode(amenities, forKey: .amenities)
        try values.encode(contactPhone, forKey: .contactPhone)
        try values.encode(websiteUrl, forKey: .websiteUrl)
        try values.encode(bookingUrl, forKey: .bookingUrl)
        try values.encode(bookingVerified, forKey: .bookingVerified)
        try values.encode(reason, forKey: .reason)
    }
}
nonisolated struct ClubCourtBody: Encodable, Sendable {
    let version: Int
    let name: String
    let indoor: Bool
    let surface: String
    let description: String
    let isActive: Bool
    let reason: String
}
