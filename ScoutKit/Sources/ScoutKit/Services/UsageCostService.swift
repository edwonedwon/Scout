import Foundation

/// Fetches monthly Claude API cost from the Anthropic Admin API.
/// Requires an Admin API key (sk-ant-admin...).
@MainActor
public final class UsageCostService: ObservableObject {
    public static let shared = UsageCostService()

    @Published public var monthlyCost: Double? = nil
    @Published public var isLoading = false
    @Published public var error: String? = nil

    private let endpoint = "https://api.anthropic.com/v1/organizations/usage/cost"

    private init() {}

    public func refresh(adminKey: String) async {
        guard !adminKey.isEmpty else { monthlyCost = nil; return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Build start_date = first day of current month, end_date = today
        let calendar = Calendar.current
        let now = Date()
        let comps = calendar.dateComponents([.year, .month], from: now)
        guard let firstOfMonth = calendar.date(from: comps) else { return }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        let startDate = fmt.string(from: firstOfMonth)
        let endDate = fmt.string(from: now)

        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: startDate),
            URLQueryItem(name: "end_time", value: endDate),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                error = "API error \(http.statusCode): \(body)"
                return
            }
            let decoded = try JSONDecoder().decode(CostResponse.self, from: data)
            // Sum cost_usd across all entries
            monthlyCost = decoded.data.reduce(0) { $0 + $1.cost_usd }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Response shape

    private struct CostResponse: Decodable {
        let data: [CostEntry]
    }

    private struct CostEntry: Decodable {
        let cost_usd: Double
    }
}
