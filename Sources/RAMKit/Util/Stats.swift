import Foundation

/// Robust statistics for noisy memory time series.
public enum Stats {
    /// Median of pairwise slopes (Theil-Sen). Robust to ~29% outliers. Inputs are subsampled to
    /// at most 240 points to bound the O(n^2) pair count.
    public static func theilSenSlope(_ points: [(Double, Double)]) -> Double? {
        let pts = subsample(points, max: 240)
        guard pts.count >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(pts.count * (pts.count - 1) / 2)
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let dx = pts[j].0 - pts[i].0
                if dx != 0 { slopes.append((pts[j].1 - pts[i].1) / dx) }
            }
        }
        return median(slopes)
    }

    /// Spearman rank correlation in [-1, 1]; nil for fewer than 3 points or zero variance.
    public static func spearman(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 3 else { return nil }
        return pearson(ranks(xs), ranks(ys))
    }

    /// Mean and sample standard deviation (n - 1).
    public static func meanSD(_ xs: [Double]) -> (mean: Double, sd: Double) {
        guard !xs.isEmpty else { return (0, 0) }
        let m = xs.reduce(0, +) / Double(xs.count)
        guard xs.count > 1 else { return (m, 0) }
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return (m, v.squareRoot())
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        let (mx, _) = meanSD(xs)
        let (my, _) = meanSD(ys)
        var num = 0.0, dx2 = 0.0, dy2 = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - mx) * (y - my)
            dx2 += (x - mx) * (x - mx)
            dy2 += (y - my) * (y - my)
        }
        guard dx2 > 0, dy2 > 0 else { return nil }
        return num / (dx2 * dy2).squareRoot()
    }

    /// Average ranks (ties share the mean rank).
    static func ranks(_ xs: [Double]) -> [Double] {
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        var r = [Double](repeating: 0, count: xs.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && xs[order[j + 1]] == xs[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }

    static func subsample<T>(_ xs: [T], max: Int) -> [T] {
        guard xs.count > max, max > 1 else { return xs }
        let step = Double(xs.count - 1) / Double(max - 1)
        return (0..<max).map { xs[Int((Double($0) * step).rounded())] }
    }
}
