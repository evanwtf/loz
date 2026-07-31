import CoreGraphics
import Foundation
import ImageIO
import NESCore

/// Compares a rendered overworld screen against the reference map.
///
/// The reference (map by Rick N. Bruns, NESMaps.com) is geometrically exact —
/// 16x8 screens of 256x176 after cropping its 256px legend panel — so a
/// rendered play area can be checked against it automatically. That turns
/// "does the overworld look right" from a human judgement into a number.
///
/// It cannot be a pixel comparison. The reference contains no Link, no enemies,
/// and was captured with a different palette table. So the check is
/// *structural*: both images are reduced to a grid of block luminances and
/// correlated. Terrain layout dominates that signal; sprites and palette shifts
/// do not.
enum MapCheck {
    /// Play area only — the top 64 scanlines are the HUD, which the map has no
    /// equivalent for.
    static let playAreaTop = 64
    static let screenWidth = 256
    static let screenHeight = 176

    /// The reference map's legend occupies the leftmost 256 pixels.
    static let mapLegendWidth = 256

    static func loadImage(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Extracts one screen from the reference map as 8-bit luminance.
    static func referenceLuminance(
        map: CGImage,
        column: Int,
        row: Int
    ) -> [UInt8]? {
        let x = mapLegendWidth + column * screenWidth
        let y = row * screenHeight
        guard x + screenWidth <= map.width, y + screenHeight <= map.height else {
            return nil
        }
        guard let cropped = map.cropping(
            to: CGRect(x: x, y: y, width: screenWidth, height: screenHeight))
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: screenWidth * screenHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: screenWidth, height: screenHeight,
            bitsPerComponent: 8, bytesPerRow: screenWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))

        return (0..<(screenWidth * screenHeight)).map { index in
            luminance(r: pixels[index * 4], g: pixels[index * 4 + 1], b: pixels[index * 4 + 2])
        }
    }

    /// Extracts the play area of a rendered frame as 8-bit luminance.
    static func renderedLuminance(_ framebuffer: [UInt32]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(screenWidth * screenHeight)
        for y in playAreaTop..<(playAreaTop + screenHeight) {
            for x in 0..<screenWidth {
                let pixel = framebuffer[y * 256 + x]
                result.append(luminance(
                    r: UInt8(pixel & 0xFF),
                    g: UInt8((pixel >> 8) & 0xFF),
                    b: UInt8((pixel >> 16) & 0xFF)))
            }
        }
        return result
    }

    private static func luminance(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        UInt8((UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8)
    }

    /// Reduces to a grid of block means, which is what makes the comparison
    /// robust to sprites and palette differences.
    static func blockMeans(_ luminance: [UInt8], blockSize: Int = 16) -> [Double] {
        let columns = screenWidth / blockSize
        let rows = screenHeight / blockSize
        var means = [Double]()
        means.reserveCapacity(columns * rows)

        for blockY in 0..<rows {
            for blockX in 0..<columns {
                var total = 0
                for y in 0..<blockSize {
                    let rowStart = (blockY * blockSize + y) * screenWidth + blockX * blockSize
                    for x in 0..<blockSize {
                        total += Int(luminance[rowStart + x])
                    }
                }
                means.append(Double(total) / Double(blockSize * blockSize))
            }
        }
        return means
    }

    /// Pearson correlation between two block grids. 1.0 is identical structure.
    static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let n = Double(lhs.count)
        let meanL = lhs.reduce(0, +) / n
        let meanR = rhs.reduce(0, +) / n

        var covariance = 0.0
        var varianceL = 0.0
        var varianceR = 0.0
        for index in 0..<lhs.count {
            let dl = lhs[index] - meanL
            let dr = rhs[index] - meanR
            covariance += dl * dr
            varianceL += dl * dl
            varianceR += dr * dr
        }
        let denominator = (varianceL * varianceR).squareRoot()
        return denominator == 0 ? 0 : covariance / denominator
    }

    /// Scores the current frame against the map screen the game reports.
    static func score(
        framebuffer: [UInt32],
        screen: UInt8,
        mapPath: String
    ) -> (column: Int, row: Int, correlation: Double)? {
        guard let map = loadImage(mapPath) else { return nil }
        let column = Int(screen & 0x0F)
        let row = Int(screen >> 4)
        guard let reference = referenceLuminance(map: map, column: column, row: row) else {
            return nil
        }
        let rendered = renderedLuminance(framebuffer)
        let value = correlation(blockMeans(reference), blockMeans(rendered))
        return (column, row, value)
    }
}
