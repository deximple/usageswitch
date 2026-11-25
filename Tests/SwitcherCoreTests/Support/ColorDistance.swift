import Foundation

/// How far apart two sRGB colors look, for the palette tests: the Euclidean distance in OKLab
/// times 100, measured as seen with normal vision or through a simulated color vision deficiency
/// (Machado, Oliveira and Fernandes 2009, severity 1.0, applied in linear sRGB).
enum ColorVision: String, CaseIterable, Sendable {
    case normal, protan, deutan, tritan

    private var matrix: [[Double]]? {
        switch self {
        case .normal: nil
        case .protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216],
                       [-0.003882, -0.048116, 1.051998]]
        case .deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413],
                       [-0.011820, 0.042940, 0.968881]]
        case .tritan: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602],
                       [0.004733, 0.691367, 0.303900]]
        }
    }

    /// Linear sRGB as this vision sees it, clamped to the gamut.
    private func seen(_ linear: [Double]) -> [Double] {
        guard let matrix else { return linear }
        return matrix.map { row in
            let mixed: Double = row[0] * linear[0] + row[1] * linear[1] + row[2] * linear[2]
            return min(max(mixed, 0), 1)
        }
    }

    private static func linear(_ hex: UInt32) -> [Double] {
        let shifts: [UInt32] = [16, 8, 0]
        return shifts.map { shift in
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }

    private static func oklab(_ rgb: [Double]) -> [Double] {
        let l: Double = cbrt(0.4122214708 * rgb[0] + 0.5363325363 * rgb[1] + 0.0514459929 * rgb[2])
        let m: Double = cbrt(0.2119034982 * rgb[0] + 0.6806995451 * rgb[1] + 0.1073969566 * rgb[2])
        let s: Double = cbrt(0.0883024619 * rgb[0] + 0.2817188376 * rgb[1] + 0.6299787005 * rgb[2])
        let lightness: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return [lightness, a, b]
    }

    /// OKLab ΔE×100 between two sRGB hex colors as this vision sees them.
    func distance(_ first: UInt32, _ second: UInt32) -> Double {
        let a = Self.oklab(seen(Self.linear(first)))
        let b = Self.oklab(seen(Self.linear(second)))
        let squares: Double = pow(a[0] - b[0], 2) + pow(a[1] - b[1], 2) + pow(a[2] - b[2], 2)
        return 100 * squares.squareRoot()
    }

    /// The least distance two neighboring levels need: 15 with normal vision, 8 with a deficiency.
    var minimumDistance: Double { self == .normal ? 15 : 8 }
}
