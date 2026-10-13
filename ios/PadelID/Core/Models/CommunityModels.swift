import Foundation

nonisolated struct CommunityPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let nextOffset: Int?
}

nonisolated struct ConversationMember: Codable, Hashable, Sendable, Identifiable {
    let player: PlayerCard
    let role: String
    /// The last message of the conversation this member has read.
    let lastReadId: Int64?
    var id: UUID { player.id }
}

nonisolated struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    let id: Int64
    let conversationId: UUID
    let sender: PlayerCard
    let body: String
    let createdAt: Date
    let clientId: UUID
    let deleted: Bool
}

nonisolated struct Conversation: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let kind: String
    let title: String
    let description: String?
    let visibility: String
    let gameId: UUID?
    let cityId: Int?
    let clubId: Int?
    let ownerId: UUID?
    let createdAt: Date
    let updatedAt: Date
    let members: [ConversationMember]
    let unreadCount: Int
    let latestMessage: ChatMessage?
}

nonisolated struct MessagePage: Decodable, Sendable {
    let items: [ChatMessage]
    let nextBefore: Int64?
    let latestId: Int64?
}

nonisolated struct SocialGroup: Decodable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let description: String?
    let visibility: String
    let cityId: Int?
    let clubId: Int?
    let ownerId: UUID
    let memberCount: Int
    let joined: Bool
}

nonisolated struct CommunityPost: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let author: PlayerCard
    let body: String
    let visibility: String
    let groupId: UUID?
    let clubId: Int?
    let createdAt: Date
    let reactionCount: Int
    let commentCount: Int
    let myReaction: String?
    let club: NamedRef?
}

nonisolated struct PostComment: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let postId: UUID
    let author: PlayerCard
    let body: String
    let createdAt: Date
}

nonisolated struct SocialNotification: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let kind: String
    let title: String
    let resourceId: UUID?
    let createdAt: Date
    let readAt: Date?
}

nonisolated struct SocialSettings: Codable, Sendable {
    var messagesFrom: String
    var notifyMessages: Bool
    var notifyActivity: Bool
}

nonisolated struct ModerationReport: Codable, Sendable, Identifiable {
    let id: UUID
    let targetType: String
    let targetId: String
    let reason: String
    let detail: String?
    let status: String
    let createdAt: Date
    let content: ModerationContent?
}

nonisolated struct ModerationContent: Codable, Sendable {
    let body: String?
    let authorName: String?
}

nonisolated struct ConversationCreate: Encodable, Equatable, Sendable {
    let kind: String
    var title: String? = nil
    var description: String? = nil
    var visibility: String? = nil
    var playerIds: [UUID]? = nil
    var playerId: UUID? = nil
    var gameId: UUID? = nil
    var cityId: Int? = nil
    var clubId: Int? = nil
}
