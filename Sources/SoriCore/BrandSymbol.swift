import CoreGraphics

/// Canonical vector geometry shared by the app, SVG exports and the macOS icon.
/// The two repeated loops echo the two syllables in BungBung without a status indicator.
public enum BrandSymbol {
    public static func path() -> CGPath {
        let path = CGMutablePath()
        for y in [CGFloat(14), 54] {
            path.addRoundedRect(in: CGRect(x: 24, y: y, width: 52, height: 32),
                                cornerWidth: 16, cornerHeight: 16)
            path.addRoundedRect(in: CGRect(x: 39, y: y + 10.5, width: 22, height: 11),
                                cornerWidth: 5.5, cornerHeight: 5.5)
        }
        // A restrained lean connects the repeated forms into one compact silhouette.
        var lean = CGAffineTransform(a: 1, b: 0, c: -0.30, d: 1, tx: 15, ty: 0)
        return path.copy(using: &lean)!
    }

    public static func fitted(in frame: CGRect) -> CGPath {
        let shape = path()
        let bounds = shape.boundingBoxOfPath
        let scale = min(frame.width / bounds.width, frame.height / bounds.height)
        var placement = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: frame.midX - bounds.midX * scale, ty: frame.midY - bounds.midY * scale)
        return shape.copy(using: &placement)!
    }
}
