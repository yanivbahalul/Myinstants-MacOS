import UIKit

/// The images myinstants.com builds its buttons from: the same files, crops and positions the
/// desktop app uses in index.html. Downloaded once from the site and kept in the Caches folder,
/// so after the first launch they show up instantly (and offline).
@MainActor
final class ButtonArt: ObservableObject {
    static let shared = ButtonArt()

    /// Where things sit inside one button, in points (= CSS pixels in index.html).
    struct Layout {
        let width: CGFloat
        let height: CGFloat
        /// The colored disc under the glossy sprite.
        let disc: CGRect
        /// The sprite's normal and pressed frames inside the sprite sheet.
        let normalFrame: CGRect
        let pressedFrame: CGRect
    }

    struct Sprite {
        let normal: UIImage
        let pressed: UIImage
        let shadow: UIImage
        let layout: Layout
    }

    // .tile / .bg / .btn / .shadow in index.html
    static let smallLayout = Layout(width: 94, height: 89,
                                    disc: CGRect(x: 3, y: 3, width: 86, height: 84),
                                    normalFrame: CGRect(x: 5, y: 5, width: 94, height: 89),
                                    pressedFrame: CGRect(x: 109, y: 5, width: 94, height: 89))
    // .hero-wrap / .hero-circle / .hero-btn / .hero-shadow in index.html
    static let largeLayout = Layout(width: 200, height: 190,
                                    disc: CGRect(x: 6, y: 7, width: 188, height: 174),
                                    normalFrame: CGRect(x: 5, y: 5, width: 200, height: 190),
                                    pressedFrame: CGRect(x: 215, y: 5, width: 200, height: 190))

    @Published private(set) var small: Sprite?
    @Published private(set) var large: Sprite?

    nonisolated private static let base = "https://www.myinstants.com/media/images/"
    private var loading = false

    func load() async {
        guard !loading, small == nil || large == nil else { return }
        loading = true
        defer { loading = false }

        async let smallSheet = Self.image("transparent_button_small_sprite.png")
        async let smallShadow = Self.image("transparent_button_small_shadow.png")
        // Only served at this PageSpeed-rewritten path (see the .hero-btn comment in index.html).
        async let largeSheet = Self.image("xtransparent_button_sprite.png.pagespeed.ic.15KLBY15iy.webp")
        async let largeShadow = Self.image("transparent_button_shadow.png")

        if let sheet = await smallSheet, let shadow = await smallShadow {
            small = Self.sprite(sheet: sheet, shadow: shadow, layout: Self.smallLayout)
        }
        if let sheet = await largeSheet, let shadow = await largeShadow {
            large = Self.sprite(sheet: sheet, shadow: shadow, layout: Self.largeLayout)
        }
    }

    private static func sprite(sheet: UIImage, shadow: UIImage, layout: Layout) -> Sprite? {
        guard let normal = crop(sheet, layout.normalFrame), let pressed = crop(sheet, layout.pressedFrame) else {
            return nil
        }
        return Sprite(normal: normal, pressed: pressed, shadow: shadow, layout: layout)
    }

    /// Crops in CSS pixels; the site's images are 1x, like a CSS background with no background-size.
    private static func crop(_ image: UIImage, _ rect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        // A CSS background with no background-size draws one image pixel per CSS pixel.
        let pixels = rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixels.isEmpty, let cropped = cg.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// From the Caches folder if it's there, otherwise from myinstants.com (then cached).
    nonisolated private static func image(_ name: String) async -> UIImage? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ButtonArt", isDirectory: true)
        let file = cacheDir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            return image
        }
        guard let url = URL(string: base + name) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                return nil
            }
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            return nil
        }
    }
}
