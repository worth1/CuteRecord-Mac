import Foundation

/// Loads AI model provider presets from bundled JSON (generated from https://models.dev/api.json).
/// Data is loaded at runtime instead of compile-time to avoid Swift type-checker memory explosion.
extension AIScriptProviderCatalog {
    private static var _modelsDevProviders: [AIScriptProvider]?

    static var modelsDevProviders: [AIScriptProvider] {
        if let cached = _modelsDevProviders {
            return cached
        }
        let providers: [AIScriptProvider]
        if let url = Bundle.main.url(forResource: "models_dev_providers", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AIScriptProvider].self, from: data) {
            providers = decoded
        } else {
            // Fallback: try source-tree path for development builds
            let sourcePath = (#file as NSString)
                .deletingLastPathComponent
                .appending("/models_dev_providers.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
               let decoded = try? JSONDecoder().decode([AIScriptProvider].self, from: data) {
                providers = decoded
            } else {
                providers = []
            }
        }
        _modelsDevProviders = providers
        return providers
    }
}
