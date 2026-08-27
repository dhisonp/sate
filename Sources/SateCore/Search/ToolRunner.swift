import Foundation

public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The result of executing a single tool call.
public struct ToolExecutionResult: Sendable, Hashable {
    public var toolCallID: String
    public var toolCallName: String
    public var results: [SearchResult]
    public var content: String
    public var error: String?
    public var latency: TimeInterval
    public var budgetSpent: Bool

    public init(
        toolCallID: String,
        toolCallName: String,
        results: [SearchResult] = [],
        content: String,
        error: String? = nil,
        latency: TimeInterval = 0,
        budgetSpent: Bool = false
    ) {
        self.toolCallID = toolCallID
        self.toolCallName = toolCallName
        self.results = results
        self.content = content
        self.error = error
        self.latency = latency
        self.budgetSpent = budgetSpent
    }
}

/// Owns the client-side tool execution loop (R2).
///
/// Enforces all hard bounds (rounds, calls per round, results per call, snippet
/// length). Executes parallel calls concurrently while preserving deterministic
/// index ordering in the returned results.
public actor ToolRunner {
    public static let maxRoundsDefault = 3
    public static let maxCallsPerRound = 4
    public static let maxResultsPerCall = 8
    public static let defaultResultsPerCall = 5

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    private let searchProvider: (any SearchProvider)?
    private let maxRounds: Int
    private let resultsPerQuery: Int

    public init(
        searchProvider: (any SearchProvider)? = nil,
        maxRounds: Int = ToolRunner.maxRoundsDefault,
        resultsPerQuery: Int = ToolRunner.defaultResultsPerCall
    ) {
        self.searchProvider = searchProvider
        self.maxRounds = maxRounds
        self.resultsPerQuery = min(max(resultsPerQuery, 1), Self.maxResultsPerCall)
    }

    /// Executes tool calls for a single round.
    ///
    /// - Parameters:
    ///   - toolCalls: The tool calls emitted by the model in this turn.
    ///   - round: 1-indexed round number.
    ///   - onSearching: Callback invoked when a search query is dispatched.
    /// - Returns: Ordered execution results matching `toolCalls` order.
    public func execute(
        toolCalls: [ToolCall],
        round: Int,
        onSearching: (@Sendable (String) -> Void)? = nil
    ) async -> [ToolExecutionResult] {
        guard !toolCalls.isEmpty else { return [] }

        // Enforce round budget.
        if round > maxRounds {
            return toolCalls.map { call in
                ToolExecutionResult(
                    toolCallID: call.id,
                    toolCallName: call.name,
                    content: "Search budget spent (maximum \(maxRounds) search rounds reached). Please synthesize your answer from the information retrieved so far or from your training cutoff.",
                    budgetSpent: true
                )
            }
        }

        // Parallel calls run concurrently up to maxCallsPerRound.
        let callsToRun = Array(toolCalls.prefix(Self.maxCallsPerRound))
        let excessCalls = Array(toolCalls.dropFirst(Self.maxCallsPerRound))

        var executedResults = [ToolExecutionResult?](repeating: nil, count: callsToRun.count)

        await withTaskGroup(of: (index: Int, result: ToolExecutionResult).self) { group in
            for (index, call) in callsToRun.enumerated() {
                group.addTask { [searchProvider, resultsPerQuery] in
                    let result = await Self.executeSingleCall(
                        call: call,
                        provider: searchProvider,
                        defaultLimit: resultsPerQuery,
                        onSearching: onSearching
                    )
                    return (index, result)
                }
            }

            for await (index, result) in group {
                executedResults[index] = result
            }
        }

        var results = executedResults.compactMap { $0 }

        // Any excess calls beyond maxCallsPerRound get a budget result.
        for excess in excessCalls {
            results.append(ToolExecutionResult(
                toolCallID: excess.id,
                toolCallName: excess.name,
                content: "Search call skipped: maximum \(Self.maxCallsPerRound) calls per round limit reached.",
                budgetSpent: true
            ))
        }

        return results
    }

    private static func executeSingleCall(
        call: ToolCall,
        provider: (any SearchProvider)?,
        defaultLimit: Int,
        onSearching: (@Sendable (String) -> Void)?
    ) async -> ToolExecutionResult {
        guard call.name == "web_search" else {
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                content: "Error: Unknown tool \"\(call.name)\". Only \"web_search\" is available.",
                error: "Unknown tool"
            )
        }

        // Parse query and limit from JSON arguments.
        let parsed = parseArguments(call.arguments)
        guard let query = parsed.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let errorMsg = parsed.parseError ?? "Missing or empty \"query\" parameter in arguments: \(call.arguments)"
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                content: "Error: \(errorMsg). Please provide valid JSON with a \"query\" string.",
                error: errorMsg
            )
        }

        let limit = min(max(parsed.limit ?? defaultLimit, 1), maxResultsPerCall)
        onSearching?(query)

        guard let provider else {
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                content: "Search unavailable: No search provider configured. Answer using your own knowledge as of your cutoff.",
                error: "Search provider not configured"
            )
        }

        let start = Date()
        do {
            let results = try await provider.search(query, limit: limit)
            let duration = Date().timeIntervalSince(start)
            let formattedContent = formatSearchResults(results, query: query)
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                results: results,
                content: formattedContent,
                latency: duration
            )
        } catch is CancellationError {
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                content: "Search cancelled.",
                error: "Cancelled",
                latency: Date().timeIntervalSince(start)
            )
        } catch {
            let duration = Date().timeIntervalSince(start)
            let failureMsg = "Search unavailable: \(error.localizedDescription). Answer using your own knowledge as of your cutoff."
            return ToolExecutionResult(
                toolCallID: call.id,
                toolCallName: call.name,
                content: failureMsg,
                error: error.localizedDescription,
                latency: duration
            )
        }
    }

    private static func parseArguments(_ arguments: String) -> (query: String?, limit: Int?, parseError: String?) {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil, "Malformed arguments JSON: \"\(arguments)\"")
        }

        let query = json["query"] as? String
        let limit: Int?
        if let intVal = json["limit"] as? Int {
            limit = intVal
        } else if let doubleVal = json["limit"] as? Double {
            limit = Int(doubleVal)
        } else if let strVal = json["limit"] as? String, let intFromStr = Int(strVal) {
            limit = intFromStr
        } else {
            limit = nil
        }

        return (query, limit, nil)
    }

    private static func formatSearchResults(_ results: [SearchResult], query: String) -> String {
        if results.isEmpty {
            return "No web search results found for \"\(query)\"."
        }

        let formattedList: [[String: String]] = results.enumerated().map { index, result in
            var item: [String: String] = [
                "citation": "[\(index + 1)]",
                "title": result.title,
                "url": result.url,
                "snippet": result.snippet,
            ]
            if let site = result.siteName {
                item["site"] = site
            }
            if let published = result.publishedAt {
                item["published_at"] = iso8601Formatter.string(from: published)
            }
            return item
        }

        if let data = try? JSONSerialization.data(withJSONObject: formattedList, options: [.sortedKeys, .prettyPrinted]),
           let jsonString = String(data: data, encoding: .utf8)
        {
            return jsonString
        }

        return results.enumerated().map { index, result in
            "[\(index + 1)] \(result.title)\nURL: \(result.url)\n\(result.snippet)"
        }.joined(separator: "\n\n")
    }
}
