import CoreML
import Foundation
import Tokenizers
import os

/// EmbeddingGemma-300m over Core ML. Resources load ASYNCHRONOUSLY after init; until they are
/// ready `embed` returns nil — callers already tolerate nil (rows stay unembedded) and the chunked
/// `backfill` re-embeds them on a later pass, so a slow first load degrades gracefully.
///
/// `@unchecked Sendable`: `resources` is written once by the loader task and only read afterwards,
/// always under `lock`.
public final class GemmaTextEmbedder: TextEmbedder, @unchecked Sendable {
    public let identity = EmbedderIdentity(id: "embeddinggemma-300m-256", dimension: 256)

    private struct Resources { let model: MLModel; let tokenizer: any Tokenizer }
    private let lock = NSLock()
    private var resources: Resources?
    private static let sequenceLength = 256   // must match scripts/convert_embeddinggemma.py SEQ_LEN
    /// Padding token id for positions beyond the encoded length. UNVERIFIED: the converted
    /// tokenizer's `tokenizer_config.json` (`pad_token_id`) is not on this machine yet — this must
    /// be confirmed against the real weights/tokenizer before shipping. If it differs, fix here only.
    private static let padTokenID: Int32 = 0

    /// Fails (returns nil) only when the files are visibly absent; load errors after that are
    /// logged and leave the embedder permanently returning nil (the app-level factory decides
    /// fallback at NEXT launch — within a run, nil-embeds are already the tolerated degraded mode).
    public init?(modelURL: URL, tokenizerDirectory: URL) {
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: tokenizerDirectory.path) else {
            EmberLog.embed.error("GemmaTextEmbedder: model or tokenizer missing — not constructing")
            return nil
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let compiled = modelURL.pathExtension == "mlmodelc"
                    ? modelURL
                    : try await MLModel.compileModel(at: modelURL)
                let model = try MLModel(contentsOf: compiled)
                let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
                self?.install(Resources(model: model, tokenizer: tokenizer))
                EmberLog.embed.info("GemmaTextEmbedder ready (dim=256)")
            } catch {
                EmberLog.embed.error("GemmaTextEmbedder load failed: \(error, privacy: .public)")
            }
        }
    }

    private func install(_ r: Resources) { lock.lock(); resources = r; lock.unlock() }

    public func embed(_ text: String, role: EmbeddingRole) -> [Float]? {
        lock.lock(); let r = resources; lock.unlock()
        guard let r else { return nil }   // still loading (or load failed) — tolerated nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var ids = r.tokenizer.encode(text: GemmaEmbeddingFormat.prompt(trimmed, role: role))
        ids = Array(ids.prefix(Self.sequenceLength))
        do {
            let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: Self.sequenceLength)], dataType: .int32)
            for i in 0..<Self.sequenceLength {
                inputIDs[i] = NSNumber(value: i < ids.count ? Int32(ids[i]) : Self.padTokenID)
                mask[i] = NSNumber(value: i < ids.count ? Int32(1) : Int32(0))
            }
            let out = try r.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIDs),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ]))
            guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
                EmberLog.embed.error("GemmaTextEmbedder: no 'embedding' output")
                return nil
            }
            let full = (0..<emb.count).map { Float(truncating: emb[$0]) }
            return GemmaEmbeddingFormat.truncateAndNormalize(full, to: identity.dimension)
        } catch {
            EmberLog.embed.notice("GemmaTextEmbedder embed failed (len=\(trimmed.count, privacy: .public)): \(error, privacy: .public)")
            return nil
        }
    }
}
