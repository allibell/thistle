import AVFoundation
import Foundation
import Security

enum OpenAIConfiguration {
    static let defaultFoodModel = "gpt-5.6-terra"
    static let defaultTranscriptionModel = "gpt-transcribe"

    private static let foodModelKey = "openai.foodModel"
    private static let transcriptionModelKey = "openai.transcriptionModel"

    static var foodModel: String {
        get { UserDefaults.standard.string(forKey: foodModelKey)?.nilIfEmpty ?? defaultFoodModel }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: foodModelKey) }
    }

    static var transcriptionModel: String {
        get { UserDefaults.standard.string(forKey: transcriptionModelKey)?.nilIfEmpty ?? defaultTranscriptionModel }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: transcriptionModelKey) }
    }
}

enum OpenAIAPIKeyStore {
    private static let service = "com.allibell.thistle.openai"
    private static let account = "personal-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.nilIfEmpty else {
            return nil
        }
        return value
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(lookup as CFDictionary)
        guard !trimmed.isEmpty else { return }

        var item = lookup
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OpenAIFoodLogError.keychain(status)
        }
    }
}

enum OpenAIFoodLogError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int, String)
    case emptyModelOutput
    case microphoneDenied
    case recordingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key before using AI logging."
        case .invalidResponse:
            return "OpenAI returned an unreadable response."
        case let .requestFailed(status, message):
            return "OpenAI request failed (\(status)): \(message)"
        case .emptyModelOutput:
            return "OpenAI did not return any food items."
        case .microphoneDenied:
            return "Microphone access is required to record a food description."
        case .recordingFailed:
            return "Thistle could not start an audio recording."
        case let .keychain(status):
            return "The API key could not be saved (Keychain status \(status))."
        }
    }
}

struct OpenAIFoodLogService: FreeformFoodLogParsing, Sendable {
    private let apiKey: String
    private let foodModel: String
    private let transcriptionModel: String
    private let session: URLSession

    init(
        apiKey: String,
        foodModel: String = OpenAIConfiguration.foodModel,
        transcriptionModel: String = OpenAIConfiguration.transcriptionModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.foodModel = foodModel
        self.transcriptionModel = transcriptionModel
        self.session = session
    }

    func draft(for request: FreeformFoodLogRequest) async throws -> FreeformFoodLogDraft {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIFoodLogError.emptyModelOutput }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 90
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: responseRequestBody(text: text))

        let (data, response) = try await session.data(for: urlRequest)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        let responseContent = envelope.output.compactMap(\.content).flatMap { $0 }
        guard let outputText = responseContent.first(where: { $0.type == "output_text" })?.text,
              let payloadData = outputText.data(using: .utf8) else {
            throw OpenAIFoodLogError.emptyModelOutput
        }
        let payload = try JSONDecoder().decode(ParsedFoodPayload.self, from: payloadData)
        let items = buildTree(from: payload.items, inputMethod: request.inputMethod)
        guard !items.isEmpty else { throw OpenAIFoodLogError.emptyModelOutput }
        return FreeformFoodLogDraft(request: request, items: items)
    }

    func transcribe(fileURL: URL) async throws -> String {
        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Thistle-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "model", value: transcriptionModel, boundary: boundary)
        body.appendMultipartField(
            name: "prompt",
            value: "A food diary description with restaurant names, brands, serving sizes, fractions, ingredients, and nutrition terms.",
            boundary: boundary
        )
        body.appendMultipartFile(
            name: "file",
            filename: "food-log.m4a",
            contentType: "audio/mp4",
            data: audioData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let transcript = try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw OpenAIFoodLogError.emptyModelOutput }
        return transcript
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIFoodLogError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw OpenAIFoodLogError.requestFailed(http.statusCode, message)
        }
    }

    private func buildTree(from nodes: [ParsedFoodNode], inputMethod: FoodLogInputMethod) -> [FoodLogDraftItem] {
        let knownIDs = Set(nodes.map(\.id))
        let roots = nodes.filter { node in
            guard let parentID = node.parentID else { return true }
            return !knownIDs.contains(parentID)
        }

        func makeItem(_ node: ParsedFoodNode, lineage: Set<String>) -> FoodLogDraftItem {
            let nextLineage = lineage.union([node.id])
            let children = nodes
                .filter { $0.parentID == node.id && !nextLineage.contains($0.id) }
                .map { makeItem($0, lineage: nextLineage) }
            let confidence = min(max(node.confidence, 0), 1)
            let confidencePercent = Int((confidence * 100).rounded())
            let detail = node.notes.first ?? "Review the item and serving before logging."
            return FoodLogDraftItem(
                title: node.title,
                servings: min(max(node.servings, 0.01), 100),
                baseServingDescription: node.baseServingDescription,
                baseNutrition: NutritionFacts(
                    calories: max(node.calories, 0),
                    protein: max(node.proteinG, 0),
                    carbs: max(node.carbsG, 0),
                    fat: max(node.fatG, 0),
                    fiber: max(node.fiberG, 0)
                ),
                analysis: ProductAnalysis(
                    rating: .yellow,
                    summary: "AI estimate (\(confidencePercent)% confidence). \(detail)",
                    flags: []
                ),
                ingredients: node.ingredients,
                sourceLabel: "AI estimate",
                inputMethod: inputMethod,
                confidence: confidence,
                notes: node.notes,
                components: children
            )
        }

        return roots.map { makeItem($0, lineage: []) }
    }

    private func responseRequestBody(text: String) -> [String: Any] {
        [
            "model": foodModel,
            "store": false,
            "input": [
                [
                    "role": "system",
                    "content": """
                    Convert a free-form food diary description into editable food items and nutrition estimates.
                    Preserve explicit quantities and fractions. Create one root item per separately logged food.
                    Use child items only when a composed food is best explained by ingredients, such as squash, peppers, and oil.
                    A child may itself have children. Do not turn every food into a meal.
                    Include a concise ingredient list for every item. For restaurant or estimated foods, include only ingredients that are stated or reasonably inferred; describe uncertainty in notes.
                    Nutrition fields must be for ONE base serving; servings is the consumed multiplier.
                    Parent nutrition should represent the complete parent food and is what will count toward diary totals; children are explanatory and must not be added again.
                    Prefer label-like estimates for named packaged products and representative restaurant estimates for ordered drinks or dishes.
                    State important assumptions in notes. Never omit an item merely because nutrition is uncertain.
                    """
                ],
                ["role": "user", "content": text]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "food_log_draft",
                    "strict": true,
                    "schema": Self.foodSchema
                ]
            ]
        ]
    }

    private static var foodSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "parent_id": ["type": ["string", "null"]],
                        "title": ["type": "string"],
                        "servings": ["type": "number"],
                        "base_serving_description": ["type": "string"],
                        "calories": ["type": "integer"],
                        "protein_g": ["type": "number"],
                        "carbs_g": ["type": "number"],
                        "fat_g": ["type": "number"],
                        "fiber_g": ["type": "number"],
                        "ingredients": ["type": "array", "items": ["type": "string"]],
                        "confidence": ["type": "number"],
                        "notes": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": [
                        "id", "parent_id", "title", "servings", "base_serving_description",
                        "calories", "protein_g", "carbs_g", "fat_g", "fiber_g", "ingredients", "confidence", "notes"
                    ],
                    "additionalProperties": false
                ]
                ]
            ],
            "required": ["items"],
            "additionalProperties": false
        ]
    }
}

@MainActor
final class FoodVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() async throws {
        guard await requestPermission() else { throw OpenAIFoodLogError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            // Record-only sessions reject playback-oriented options such as duckOthers
            // with kAudio_ParamError (-50) on physical devices.
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("thistle-food-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.prepareToRecord()
            guard recorder.record() else { throw OpenAIFoodLogError.recordingFailed }
            self.recorder = recorder
            duration = 0
            isRecording = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.duration = recorder.currentTime
                }
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recorder.url
    }

    func cancel() {
        guard let url = stop() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private struct ResponseEnvelope: Decodable {
    struct Output: Decodable {
        var content: [Content]?
    }

    struct Content: Decodable {
        var type: String
        var text: String?
    }

    var output: [Output]
}

private struct ParsedFoodPayload: Decodable {
    var items: [ParsedFoodNode]
}

private struct ParsedFoodNode: Decodable {
    var id: String
    var parentID: String?
    var title: String
    var servings: Double
    var baseServingDescription: String
    var calories: Int
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double
    var ingredients: [String]
    var confidence: Double
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case title
        case servings
        case baseServingDescription = "base_serving_description"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case ingredients
        case confidence
        case notes
    }
}

private struct TranscriptionResponse: Decodable {
    var text: String
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        var message: String
    }

    var error: APIError
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
