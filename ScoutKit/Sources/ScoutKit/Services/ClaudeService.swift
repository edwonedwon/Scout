import Foundation

/// Sends requests to the Anthropic Claude API using the user's own API key (BYOK).
public actor ClaudeService {
    public static let shared = ClaudeService()

    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-opus-4-8"
    private let anthropicVersion = "2023-06-01"

    private var apiKey: String? {
        KeychainService.load(forKey: KeychainService.anthropicAPIKey)
    }

    public var hasAPIKey: Bool {
        apiKey != nil
    }

    // MARK: - Location Search

    /// Asks Claude to search for film locations matching the given query.
    /// Claude uses tool calls to fan out to Google Places, web search, etc.
    public func searchLocations(
        query: String,
        mapRegion: GooglePlacesService.MapRegion? = nil,
        onLocation: @escaping (ScoutLocation) -> Void,
        onStatus: @escaping (String) -> Void = { _ in }
    ) async throws {
        guard let apiKey else {
            dlog("No Anthropic API key set", level: .error, tag: "Claude")
            throw ClaudeError.missingAPIKey
        }
        dlog("Starting AI Scout search: \"\(query)\"", level: .info, tag: "Claude")

        var systemPrompt = """
        You are an expert film location scout assistant. The user will describe locations they're looking for.
        Your job is to search for real, specific locations that match their description using the available tools.

        For each promising location you find:
        - Use search_google_places to get coordinates, photos, and details
        - Use search_web to find articles, images, and videos about the location
        - Return each location as a call to report_location with all available details

        Always include a Google Maps link in the format:
        https://www.google.com/maps/search/?api=1&query=LAT,LNG

        Search thoroughly and return as many relevant locations as possible.
        """

        if let r = mapRegion {
            systemPrompt += """

            IMPORTANT: The user is looking at a specific area on the map. Restrict all results to this viewport:
            Center: \(String(format: "%.4f", r.centerLat)), \(String(format: "%.4f", r.centerLng))
            Span: ±\(String(format: "%.3f", r.latDelta / 2))° lat, ±\(String(format: "%.3f", r.lngDelta / 2))° lng
            Only report locations within this bounding box. Do not return locations outside this area.
            """
        }

        let tools: [[String: Any]] = [
            googlePlacesTool(),
            webSearchTool(),
            reportLocationTool(),
        ]

        let messages: [[String: Any]] = [
            ["role": "user", "content": query]
        ]

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": systemPrompt,
            "tools": tools,
            "messages": messages,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Run the agentic tool loop
        try await runToolLoop(request: request, apiKey: apiKey, mapRegion: mapRegion, onLocation: onLocation, onStatus: onStatus)
    }

    // MARK: - Tool Loop

    private func runToolLoop(
        request: URLRequest,
        apiKey: String,
        mapRegion: GooglePlacesService.MapRegion?,
        onLocation: @escaping (ScoutLocation) -> Void,
        onStatus: @escaping (String) -> Void,
        messages: [[String: Any]] = [],
        depth: Int = 0
    ) async throws {
        guard depth < 10 else { return }

        dlog("Claude request (depth \(depth))", level: .network, tag: "Claude")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            dlog("Claude error \(http.statusCode): \(body.prefix(200))", level: .error, tag: "Claude")
            throw ClaudeError.apiError(http.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let stopReason = json["stop_reason"] as? String else {
            throw ClaudeError.invalidResponse
        }

        dlog("Claude response: stop_reason=\(stopReason), blocks=\(content.count)", level: .network, tag: "Claude")

        // Process tool calls
        var toolResults: [[String: Any]] = []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let toolName = block["name"] as? String,
                  let toolInput = block["input"] as? [String: Any],
                  let toolID = block["id"] as? String else { continue }

            dlog("Tool call: \(toolName)(\(toolInput.keys.joined(separator: ",")))", level: .info, tag: "Claude")
            let result = await executeTool(name: toolName, input: toolInput, mapRegion: mapRegion, onLocation: onLocation, onStatus: onStatus)
            dlog("Tool result: \(result.prefix(100))", level: .info, tag: "Claude")
            toolResults.append([
                "type": "tool_result",
                "tool_use_id": toolID,
                "content": result,
            ])
        }

        guard stopReason == "tool_use", !toolResults.isEmpty else {
            dlog("Claude done (stop_reason=\(stopReason))", level: .success, tag: "Claude")
            return
        }

        // Build next request with updated messages
        var nextMessages = messages
        nextMessages.append(["role": "assistant", "content": content])
        nextMessages.append(["role": "user", "content": toolResults])

        var nextRequest = request
        var nextBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        nextBody["messages"] = nextMessages
        nextRequest.httpBody = try JSONSerialization.data(withJSONObject: nextBody)

        try await runToolLoop(
            request: nextRequest,
            apiKey: apiKey,
            mapRegion: mapRegion,
            onLocation: onLocation,
            onStatus: onStatus,
            messages: nextMessages,
            depth: depth + 1
        )
    }

    // MARK: - Tool Execution

    private func executeTool(
        name: String,
        input: [String: Any],
        mapRegion: GooglePlacesService.MapRegion?,
        onLocation: @escaping (ScoutLocation) -> Void,
        onStatus: @escaping (String) -> Void
    ) async -> String {
        switch name {
        case "report_location":
            if let location = parseLocation(from: input) {
                onStatus("Pinning \(location.name)…")
                onLocation(location)
                return "Location reported successfully."
            }
            return "Failed to parse location."

        case "search_google_places":
            let query = input["query"] as? String ?? ""
            onStatus("Searching Google Places for \"\(query)\"…")
            do {
                let results = try await GooglePlacesService.shared.search(query: query, region: mapRegion)
                if results.isEmpty { return "No results found for '\(query)'." }
                let summary = results.map { "- \($0.name) (\($0.coordinate.latitude), \($0.coordinate.longitude)): \($0.description)" }.joined(separator: "\n")
                return "Found \(results.count) places:\n\(summary)"
            } catch {
                return "Google Places error: \(error.localizedDescription)"
            }

        case "search_web":
            let query = input["query"] as? String ?? ""
            onStatus("Searching the web for \"\(query)\"…")
            return "Web search for '\(query)' — integration coming in Phase 2."

        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Tool Definitions

    private func reportLocationTool() -> [String: Any] {
        [
            "name": "report_location",
            "description": "Report a found location to add it to the map. Call this for every promising location you find.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Location name"],
                    "description": ["type": "string", "description": "Why this location matches the search"],
                    "latitude": ["type": "number"],
                    "longitude": ["type": "number"],
                    "google_maps_url": ["type": "string", "description": "Google Maps link"],
                    "source_url": ["type": "string", "description": "URL where this was found"],
                    "image_urls": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Image URLs of the location",
                    ],
                ] as [String: Any],
                "required": ["name", "latitude", "longitude"],
            ] as [String: Any],
        ]
    }

    private func googlePlacesTool() -> [String: Any] {
        [
            "name": "search_google_places",
            "description": "Search Google Maps Places for locations matching a query. Returns coordinates, photos, and details.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search query, e.g. 'abandoned warehouse Tokyo'"],
                    "location_hint": ["type": "string", "description": "Optional city or region to bias results"],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    private func webSearchTool() -> [String: Any] {
        [
            "name": "search_web",
            "description": "Search the web for location information, articles, images, and videos.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "language": ["type": "string", "description": "Language hint, e.g. 'ja' for Japanese"],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    // MARK: - Parsing

    private func parseLocation(from input: [String: Any]) -> ScoutLocation? {
        guard let name = input["name"] as? String,
              let lat = input["latitude"] as? Double,
              let lng = input["longitude"] as? Double else { return nil }

        let description = input["description"] as? String ?? ""
        let googleMapsURL = (input["google_maps_url"] as? String).flatMap(URL.init)
        let sourceURL = (input["source_url"] as? String).flatMap(URL.init)

        let images: [ScoutImage] = (input["image_urls"] as? [String] ?? []).compactMap { urlStr in
            URL(string: urlStr).map { ScoutImage(url: $0, source: .googleMaps) }
        }

        return ScoutLocation(
            name: name,
            description: description,
            coordinate: .init(latitude: lat, longitude: lng),
            sourceURL: sourceURL,
            images: images,
            googleMapsURL: googleMapsURL ?? URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)")
        )
    }

    // MARK: - Errors

    public enum ClaudeError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key set. Please add your key in Settings."
            case .invalidResponse:
                return "Received an unexpected response from Claude."
            case .apiError(let code, let body):
                return "Claude API error \(code): \(body)"
            }
        }
    }
}
