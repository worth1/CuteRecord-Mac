//
//  RecordingError.swift
//  CuteRecord
//

import Foundation

enum RecordingError: LocalizedError {
    case audioSetupFailed
    case exportFailed(String)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .audioSetupFailed:
            return "Audio recording setup failed"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .invalidState:
            return "Recording is in an invalid state"
        }
    }
}
