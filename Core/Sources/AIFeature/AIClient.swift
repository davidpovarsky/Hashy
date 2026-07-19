import Conduit
import Dependencies
import DependenciesMacros
import Foundation
import MarkdownStorage

// MARK: - AI Client

public struct AIClient: Sendable {
    public var sendMessage: @Sendable (
        _ apiKeys: APIKeys,
        _ model: String,
        _ messages: [ChatMessage],
        _ noteContext: String?,
        _ toolContext: NoteToolContext,
        _ onToolCall: @Sendable (String) async -> Void
    ) async throws -> ChatResult
}

// MARK: - Live Implementation

extension AIClient: DependencyKey {
    public static let liveValue = AIClient(
        sendMessage: { apiKeys, model, messages, noteContext, toolContext, onToolCall in
            let modelShort = model.split(separator: "/").last.map(String.init) ?? model

            // Build system prompt
            let existingTags = Set(toolContext.files.flatMap(\.tags)).sorted()
            let systemText = SystemPromptBuilder.build(
                noteCount: toolContext.files.count,
                existingTags: existingTags,
                currentNoteContext: noteContext
            )

            // Build tools
            let tools: [any Tool] = [
                CreateNoteTool(context: toolContext),
                ReadNoteTool(context: toolContext),
                UpdateNoteMetadataTool(context: toolContext),
                UpdateNoteContentTool(context: toolContext),
                DeleteNoteTool(context: toolContext),
                SearchNotesTool(context: toolContext),
                RenameNoteTool(context: toolContext),
                ListTags