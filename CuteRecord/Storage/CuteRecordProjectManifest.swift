//
//  CuteRecordProjectManifest.swift
//  CuteRecord
//

import Foundation

struct CuteRecordProjectManifest: Codable, Equatable {
    static let metadataDirectoryName = ".cuterecord"
    static let fileName = "project.json"

    var version: Int
    var projectID: String
    var selectedFileID: String?
    var files: [CuteRecordProjectFileRecord]
    var recordings: [CuteRecordRecordingRecord]
    var updatedAt: Date

    init(
        version: Int = 1,
        projectID: String = UUID().uuidString,
        selectedFileID: String? = nil,
        files: [CuteRecordProjectFileRecord] = [],
        recordings: [CuteRecordRecordingRecord] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.projectID = projectID
        self.selectedFileID = selectedFileID
        self.files = files
        self.recordings = recordings
        self.updatedAt = updatedAt
    }
}

struct CuteRecordProjectFileRecord: Codable, Equatable, Identifiable {
    var id: String
    var relativePath: String
    var title: String
    var kind: String
    var createdAt: Date
    var updatedAt: Date
    var contentHash: String?

    init(
        id: String = UUID().uuidString,
        relativePath: String,
        title: String,
        kind: String = "markdown",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        contentHash: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentHash = contentHash
    }
}

struct CuteRecordRecordingRecord: Codable, Equatable, Identifiable {
    var id: String
    var relativePath: String
    var kind: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        relativePath: String,
        kind: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.kind = kind
        self.createdAt = createdAt
    }
}
