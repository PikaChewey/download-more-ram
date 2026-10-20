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

// MARK: - Two-sample comparison (benchmarks)

public struct WelchResult: Codable, Sendable, Equatable {
    public var t: Double
    public var df: Double
    /// Two-sided p-value.
    public var p: Double
    /// Cohen's d with pooled standard deviation.
    public var cohenD: Double
    public var meanDifference: Double
}

extension Stats {
    /// Welch's unequal-variance t-test of `xs` vs `ys` (two-sided), plus Cohen's d.
    public static func welch(_ xs: [Double], _ ys: [Double]) -> WelchResult? {
        guard xs.count >= 2, ys.count >= 2 else { return nil }
        let (m1, s1) = meanSD(xs), (m2, s2) = meanSD(ys)
        let n1 = Double(xs.count), n2 = Double(ys.count)
        let v1 = s1 * s1 / n1, v2 = s2 * s2 / n2
        let pooled = (((n1 - 1) * s1 * s1 + (n2 - 1) * s2 * s2) / (n1 + n2 - 2)).squareRoot()
        let d = pooled > 0 ? (m1 - m2) / pooled : 0
        guard v1 + v2 > 0 else {
            return WelchResult(t: m1 == m2 ? 0 : .infinity, df: n1 + n2 - 2, p: m1 == m2 ? 1 : 0, cohenD: d, meanDifference: m1 - m2)
        }
        let t = (m1 - m2) / (v1 + v2).squareRoot()
        let df = (v1 + v2) * (v1 + v2) / (v1 * v1 / (n1 - 1) + v2 * v2 / (n2 - 1))
        let p = regularizedIncompleteBeta(a: df / 2, b: 0.5, x: df / (df + t * t))
        return WelchResult(t: t, df: df, p: min(1, max(0, p)), cohenD: d, meanDifference: m1 - m2)
    }

    /// I_x(a, b) via Lentz's continued fraction (Numerical Recipes 6.4).
    static func regularizedIncompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnBeta = lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x)
        let front = exp(lnBeta)
        if x < (a + 1) / (a + b + 2) { return front * betaContinuedFraction(a: a, b: b, x: x) / a }
        return 1 - front * betaContinuedFraction(a: b, b: a, x: 1 - x) / b
    }

    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let tiny = 1e-300, eps = 3e-16
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        d = 1 / (abs(d) < tiny ? tiny : d)
        var h = d
        for m in 1...300 {
            let md = Double(m), m2 = 2 * md
            var aa = md * (b - md) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d; d = 1 / (abs(d) < tiny ? tiny : d)
            c = 1 + aa / c; c = abs(c) < tiny ? tiny : c
            h *= d * c
            aa = -(a + md) * (qab + md) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d; d = 1 / (abs(d) < tiny ? tiny : d)
            c = 1 + aa / c; c = abs(c) < tiny ? tiny : c
            let del = d * c
            h *= del
            if abs(del - 1) < eps { break }
        }
        return h
    }
}
