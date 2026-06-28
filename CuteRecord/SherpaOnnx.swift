//
//  SherpaOnnx.swift
//  CuteRecord
//

import Foundation

// Placeholder file for SherpaOnnx functionality
// This allows the project to compile without the actual SherpaOnnx library

// Placeholder structures and functions to satisfy compilation requirements
struct SherpaOnnxOnlineTransducerModelConfig {
    let encoder: String
    let decoder: String
    let joiner: String
    let joinerEncoder: String?
    let joinerDecoder: String?
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
}

struct SherpaOnnxOnlineParaformerModelConfig {
    let encoder: String
    let decoder: String
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
}

struct SherpaOnnxOnlineZipformer2CtcModelConfig {
    let model: String
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
}

struct SherpaOnnxOnlineNemoCtcModelConfig {
    let model: String
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
}

struct SherpaOnnxOnlineToneCtcModelConfig {
    let model: String
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
}

struct SherpaOnnxOnlineModelConfig {
    let transducer: SherpaOnnxOnlineTransducerModelConfig?
    let paraformer: SherpaOnnxOnlineParaformerModelConfig?
    let zipformer2Ctc: SherpaOnnxOnlineZipformer2CtcModelConfig?
    let nemoCtc: SherpaOnnxOnlineNemoCtcModelConfig?
    let toneCtc: SherpaOnnxOnlineToneCtcModelConfig?
    let tokens: String
    let numThreads: Int
    let provider: String
    let debug: Bool
    let modelType: String
    let modelingUnit: String
    let bpeVocab: String
    let telespeechCtc: String
}

struct SherpaOnnxOnlineRecognizerConfig {
    let featConfig: SherpaOnnxFeatureConfig
    let modelConfig: SherpaOnnxOnlineModelConfig
    let decodingMethod: String
    let maxActivePaths: Int
    let enableEndpoint: Bool
    let rule1MinTrailingSilence: Float
    let rule2MinTrailingSilence: Float
    let rule3MinUtteranceLength: Float
    let hotwordsFile: String
    let hotwordsScore: Float
}

struct SherpaOnnxFeatureConfig {
    let sampleRate: Int
    let featureDim: Int
}

class SherpaOnnxRecognizer {
    let config: SherpaOnnxOnlineRecognizerConfig
    
    init(config: SherpaOnnxOnlineRecognizerConfig) {
        self.config = config
    }
    
    func acceptWaveform(samples: [Float]) {
        // Placeholder implementation
    }
    
    func getResult() -> String {
        return ""
    }
    
    func reset() {
        // Placeholder implementation
    }
    
    func isReady() -> Bool {
        return true
    }
}

// Add SherpaOnnxModelLocator for compatibility
enum SherpaOnnxModelLocator {
    static let modelName = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
    static let modelDisplayName = "Paraformer zh-en int8 (Placeholder)"
}