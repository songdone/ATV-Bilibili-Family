import UIKit

/// Optional private-build support image. Kept separate from the support page so
/// public builds can omit the image and still compile.
struct SupportConfig: Decodable {
    let imageName: String?

    static func load(bundle: Bundle = .main) -> SupportConfig {
        guard let url = bundle.url(forResource: "SupportConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SupportConfig.self, from: data)
        else { return SupportConfig(imageName: nil) }
        return config
    }

    func image(bundle: Bundle = .main) -> UIImage? {
        guard let imageName, !imageName.isEmpty,
              imageName == (imageName as NSString).lastPathComponent,
              !imageName.contains(".."),
              let url = bundle.url(forResource: imageName, withExtension: nil)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
