import CoreGraphics
import Foundation

/// Turns the PPU's 256x240 RGBA buffer into a `CGImage` for display.
///
/// `NESPalette.rgba` packs pixels as 0xAABBGGRR, which on a little-endian
/// machine is the byte order R,G,B,A — exactly what `noneSkipLast` expects, so
/// the buffer uploads with no per-pixel conversion.
public enum FrameRenderer {

    public static let width = 256
    public static let height = 240

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

    public static func image(from framebuffer: [UInt32]) -> CGImage? {
        framebuffer.withUnsafeBytes { raw -> CGImage? in
            guard let provider = CGDataProvider(
                data: Data(raw) as CFData) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                // Nearest-neighbour: pixel art must never be smoothed.
                shouldInterpolate: false,
                intent: .defaultIntent)
        }
    }
}
