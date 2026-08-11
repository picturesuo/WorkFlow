import XCTest
@testable import OpenSuperWhisper

@MainActor
final class LatestDictationGateTests: XCTestCase {
    func testOnlyNewestGenerationCanFinish() {
        let gate = LatestDictationGate()

        let first = gate.begin()
        let second = gate.begin()

        let firstIsCurrent = gate.isCurrent(first)
        let secondIsCurrent = gate.isCurrent(second)
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
    }
}

final class BedrockCleanupServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedrockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        BedrockURLProtocol.handler = nil
        super.tearDown()
    }

    func testConverseRequestReturnsCleanedTextAndUsage() async throws {
        BedrockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-key")
            XCTAssertEqual(request.url?.host, "bedrock-runtime.us-east-1.amazonaws.com")
            XCTAssertTrue(request.url?.path.contains("us.amazon.nova-micro-v1:0") == true)

            let requestBody = try XCTUnwrap(Self.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["text"] as? String, "RAW_TRANSCRIPTION:\nUm, send the report tomorrow.")

            let responseBody = """
            {
              "output": {"message": {"content": [{"text": "Send the report tomorrow."}]}},
              "usage": {"inputTokens": 91, "outputTokens": 6}
            }
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        let result = try await BedrockCleanupService(session: session).clean(
            transcript: "Um, send the report tomorrow.",
            apiKey: "secret-test-key",
            configuration: BedrockCleanupConfiguration()
        )

        XCTAssertEqual(result.text, "Send the report tomorrow.")
        XCTAssertEqual(result.inputTokens, 91)
        XCTAssertEqual(result.outputTokens, 6)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testEmptySentinelBecomesEmptyTranscript() async throws {
        BedrockURLProtocol.handler = { request in
            let responseBody = """
            {"output": {"message": {"content": [{"text": "EMPTY"}]}}}
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        let result = try await BedrockCleanupService(session: session).clean(
            transcript: "um uh",
            apiKey: "secret-test-key",
            configuration: BedrockCleanupConfiguration()
        )

        XCTAssertEqual(result.text, "")
    }

    func testRejectsAssistantStyleExpansion() async throws {
        BedrockURLProtocol.handler = { request in
            let responseBody = """
            {"output": {"message": {"content": [{"text": "Sure, here is a much better answer."}]}}}
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        do {
            _ = try await BedrockCleanupService(session: session).clean(
                transcript: "Answer this",
                apiKey: "secret-test-key",
                configuration: BedrockCleanupConfiguration()
            )
            XCTFail("Expected an unsafe rewrite error")
        } catch let error as BedrockCleanupError {
            XCTAssertEqual(error, .unsafeRewrite)
        }
    }

    func testPreservesIntentionalOuterQuotes() async throws {
        BedrockURLProtocol.handler = { request in
            let responseBody = #"{"output":{"message":{"content":[{"text":"\"Ship it now.\""}]}}}"#
                .data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        let result = try await BedrockCleanupService(session: session).clean(
            transcript: "\"Ship it now.\"",
            apiKey: "secret-test-key",
            configuration: BedrockCleanupConfiguration()
        )

        XCTAssertEqual(result.text, "\"Ship it now.\"")
    }

    func testRejectsRegionThatCouldChangeTheBedrockHost() async throws {
        do {
            _ = try await BedrockCleanupService(session: session).clean(
                transcript: "Keep this private.",
                apiKey: "secret-test-key",
                configuration: BedrockCleanupConfiguration(region: "us-east-1.example.com")
            )
            XCTFail("Expected an invalid configuration error")
        } catch let error as BedrockCleanupError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
    }
}

final class TranscriptCleanupPipelineTests: XCTestCase {
    func testNetworkErrorFallsBackToRawTranscript() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedrockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            BedrockURLProtocol.handler = nil
        }

        BedrockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let pipeline = TranscriptCleanupPipeline(
            service: BedrockCleanupService(session: session),
            isEnabled: { true },
            credentialProvider: { "secret-test-key" },
            configurationProvider: { BedrockCleanupConfiguration(timeout: 0.5) }
        )
        let result = await pipeline.finalize("Um, keep this exact raw transcript.")

        XCTAssertEqual(result.text, "Um, keep this exact raw transcript.")
        XCTAssertEqual(result.source, .rawFallback)
        XCTAssertNil(result.inputTokens)
        XCTAssertNil(result.outputTokens)
    }
}

private final class BedrockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
