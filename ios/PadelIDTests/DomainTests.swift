import Foundation
import Testing
@testable import PadelID

@MainActor
@Suite("Domain rules")
struct DomainTests {
    // MARK: Padel DNA

    @Test("DNA dimensions accept snake_case and camelCase keys")
    func dimensionKeys() {
        #expect(DNADimension.allCases.count == 6)
        for dimension in DNADimension.allCases {
            #expect(DNADimension(apiKey: dimension.rawValue) == dimension)
            #expect(DNADimension(apiKey: dimension.camelKey) == dimension)
            #expect(!dimension.title.isEmpty)
            #expect(!dimension.shortTitle.isEmpty)
            #expect(!dimension.explanation.isEmpty)
            #expect(!dimension.trainingFocus.isEmpty)
        }
        #expect(DNADimension(apiKey: "serve_return") == .serveReturn)
        #expect(DNADimension(apiKey: "serveReturn") == .serveReturn)
        #expect(DNADimension(apiKey: "transitionLob") == .transitionLob)
        #expect(DNADimension(apiKey: "consistencyDecisions") == .consistencyDecisions)
        #expect(DNADimension.consistencyDecisions.camelKey == "consistencyDecisions")
        #expect(DNADimension.netGame.camelKey == "netGame")
        #expect(DNADimension.defense.camelKey == "defense")
        #expect(DNADimension(apiKey: "smash") == nil)
        #expect(DNADimension(apiKey: "") == nil)
        #expect(DNADimension(apiKey: "Serve_Return") == nil)
    }

    @Test("Archetypes from the API")
    func archetypes() {
        let keys = ["forming", "all_rounder", "net_dominator", "finisher", "wall", "architect", "returner", "strategist"]
        for key in keys {
            let archetype = DNAArchetype(rawValue: key)
            #expect(archetype != nil, "\(key)")
            #expect(archetype?.title.isEmpty == false)
            #expect(archetype?.summary.isEmpty == false)
        }
    }

    // MARK: Level and reliability

    @Test("Level bands switch exactly at whole levels")
    func levelBands() {
        #expect(LevelBand(level: -0.5) == .beginner)
        #expect(LevelBand(level: 0) == .beginner)
        #expect(LevelBand(level: 0.99) == .beginner)
        #expect(LevelBand(level: 1.0) == .novice)
        #expect(LevelBand(level: 1.99) == .novice)
        #expect(LevelBand(level: 2.0) == .recreational)
        #expect(LevelBand(level: 2.999) == .recreational)
        #expect(LevelBand(level: 3.0) == .intermediate)
        #expect(LevelBand(level: 3.74) == .intermediate)
        #expect(LevelBand(level: 4.0) == .advanced)
        #expect(LevelBand(level: 5.0) == .competitive)
        #expect(LevelBand(level: 5.99) == .competitive)
        #expect(LevelBand(level: 6.0) == .elite)
        #expect(LevelBand(level: 7.0) == .elite)
        for band in LevelBand.allCases {
            #expect(LevelBand(level: band.range.lowerBound) == band)
            #expect(!band.title.isEmpty)
            #expect(!band.description.isEmpty)
        }
        #expect(Set(LevelBand.allCases.map(\.title)).count == LevelBand.allCases.count)
    }

    @Test("Reliability bands")
    func reliabilityBands() {
        #expect(ReliabilityBand(0) == .low)
        #expect(ReliabilityBand(39) == .low)
        #expect(ReliabilityBand(40) == .medium)
        #expect(ReliabilityBand(69) == .medium)
        #expect(ReliabilityBand(70) == .high)
        #expect(ReliabilityBand(100) == .high)
        #expect(ReliabilityBand(39).title == "Низкая")
        #expect(ReliabilityBand(55).title == "Средняя")
        #expect(ReliabilityBand(90).title == "Высокая")
    }

    @Test("DNA confidence bands")
    func confidence() {
        #expect(Confidence(0) == .low)
        #expect(Confidence(0.29) == .low)
        #expect(Confidence(0.3) == .medium)
        #expect(Confidence(0.59) == .medium)
        #expect(Confidence(0.6) == .high)
        #expect(Confidence(1) == .high)
    }

    // MARK: Password policy

    @Test("Passwords: at least 8 characters with letters and digits")
    func passwords() {
        #expect(PasswordPolicy.isValid("padel2026"))
        #expect(PasswordPolicy.isValid("пароль12"))
        #expect(PasswordPolicy.isValid("aaaaaaa1"))
        #expect(!PasswordPolicy.isValid("padel26"))
        #expect(!PasswordPolicy.isValid("padelpadel"))
        #expect(!PasswordPolicy.isValid("12345678"))
        #expect(!PasswordPolicy.isValid(""))
        // At most 72 bytes (bcrypt); Cyrillic letters take two bytes each.
        #expect(PasswordPolicy.isValid(String(repeating: "a1", count: 36)))
        #expect(!PasswordPolicy.isValid(String(repeating: "a1", count: 37)))
        #expect(PasswordPolicy.isValid(String(repeating: "я", count: 35) + "12"))
        #expect(!PasswordPolicy.isValid(String(repeating: "я", count: 36) + "1"))
        #expect(PasswordPolicy.hasLetter("1234a"))
        #expect(!PasswordPolicy.hasLetter("1234"))
        #expect(PasswordPolicy.hasDigit("abc9"))
        #expect(!PasswordPolicy.hasDigit("abc"))
    }

    @Test("E-mail plausibility")
    func emails() {
        #expect(PasswordPolicy.isPlausibleEmail("m.orlov@padelid.app"))
        #expect(PasswordPolicy.isPlausibleEmail("  m.orlov@padelid.app "))
        #expect(!PasswordPolicy.isPlausibleEmail("m.orlov@padelid"))
        #expect(!PasswordPolicy.isPlausibleEmail("m.orlov@padelid."))
        #expect(!PasswordPolicy.isPlausibleEmail("@padelid.app"))
        #expect(!PasswordPolicy.isPlausibleEmail("m orlov@padelid.app"))
        #expect(!PasswordPolicy.isPlausibleEmail("m.orlov.padelid.app"))
        #expect(!PasswordPolicy.isPlausibleEmail(""))
    }
}
