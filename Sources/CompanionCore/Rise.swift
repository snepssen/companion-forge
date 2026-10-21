import Foundation

// A question's rise: the pitch of its last stressed syllable to its end,
// glided up by a few semitones, everything else untouched.
//
// voice-forge tried bending pitch after synthesis and was turned down by ear
// each time, and its notes say why, which this follows:
//  - a contour that went up and down "rode an oscillating wave", so this is
//    one rise, never falling back;
//  - the crackle was at the consonant before a vowel, so only vowels and
//    sonorants are shifted, a vowel straight after a stop or a hiss starts
//    dry and crossfades in, and everything outside them is the same samples;
//  - nobody could place the rise from a recogniser's word times, so the runs
//    come from the voice's own phoneme durations;
//  - duration is unchanged: pitch-synchronous overlap-add (TD-PSOLA), one
//    period at a time, which keeps the voice's formants where they were.

public enum Rise {
    /// A stretch of samples that may be shifted: a vowel or sonorant run.
    public struct Run: Sendable, Equatable {
        public var start: Int
        public var end: Int
        /// Straight after a consonant: the first few milliseconds stay dry.
        public var guarded: Bool

        public init(start: Int, end: Int, guarded: Bool) {
            self.start = start
            self.end = end
            self.guarded = guarded
        }
    }

    /// How far into the glide `t` (0 to 1) is: slow to start, steepest at the
    /// end, as a spoken rise is.
    public static func shape(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t) * 0.5 + t * t * 0.5
    }

    /// `samples` with the pitch in `runs` raised along a glide from nothing at
    /// `from` to `semitones` at `to` (sample indices). Outside the runs the
    /// samples are returned unchanged.
    public static func apply(_ samples: [Float], runs: [Run], from: Int, to: Int,
                             semitones: Double, rate: Double) -> [Float] {
        guard semitones != 0, to > from else { return samples }
        // Only the voiced, audible part of each run, and the glide tops out
        // where the last of it ends.
        let runs = runs.compactMap { voiced(samples, $0, rate: rate) }
        guard let last = runs.last else { return samples }
        let to = max(from + 1, min(to, last.end))
        var out = samples
        let fade = Int(rate * 0.012), guardLength = Int(rate * 0.015)
        for run in runs where run.end - run.start > Int(rate * 0.03) {
            let ratio: (Int) -> Double = { i in
                pow(2, semitones * shape(Double(i - from) / Double(to - from)) / 12)
            }
            guard let wet = shifted(samples, run: run, ratio: ratio, rate: rate) else { continue }
            // Blend in over `fade`, after the guard where there is one, and out
            // again before the run ends.
            let opens = run.start + (run.guarded ? guardLength : 0)
            for i in run.start..<run.end {
                let rising = Double(i - opens) / Double(fade)
                let falling = Double(run.end - i) / Double(fade)
                let mix = Float(min(1, max(0, min(rising, falling))))
                if mix > 0 { out[i] = samples[i] * (1 - mix) + wet[i - run.start] * mix }
            }
        }
        return out
    }

    /// `samples` with `from..<to` read progressively faster, up to
    /// `semitones` higher at `to`: a varispeed glide. It needs no pitch marks,
    /// which a breathy voice doesn't give reliably, and moves everything in
    /// the stretch up together, so the stretch also comes out a little
    /// shorter (about 6% at +2, 12% at +4). Before `from` the samples are
    /// unchanged; after `to`, the same samples, sooner.
    public static func glide(_ samples: [Float], from: Int, to: Int, semitones: Double) -> [Float] {
        guard semitones != 0, from >= 0, to > from, to <= samples.count else { return samples }
        var out = Array(samples[..<from])
        out.reserveCapacity(samples.count)
        var position = Double(from)
        while position < Double(to) {
            let i = Int(position), f = Float(position - Double(i))
            // Four-point cubic between the neighbours.
            let a = samples[max(0, i - 1)], b = samples[i]
            let c = samples[min(samples.count - 1, i + 1)], d = samples[min(samples.count - 1, i + 2)]
            out.append(b + 0.5 * f * (c - a + f * (2 * a - 5 * b + 4 * c - d + f * (3 * (b - c) + d - a))))
            position += pow(2, semitones * shape((position - Double(from)) / Double(to - from)) / 12)
        }
        // Rejoin the original where reading left off, crossfaded over a few
        // milliseconds so the cut can't click.
        let rest = Int(position.rounded(.up))
        let blend = min(64, out.count - from, samples.count - rest)
        if blend > 0 {
            for k in 0..<blend {
                let t = Float(k + 1) / Float(blend + 1)
                out[out.count - blend + k] = out[out.count - blend + k] * (1 - t) + samples[rest - blend + k] * t
            }
        }
        if rest < samples.count { out += samples[rest...] }
        return out
    }

    /// The part of `run` that is voiced and within 20 dB of its loudest:
    /// voice-forge's voice fades a sentence's last vowel into a quiet creak,
    /// which has no period to move and only crackles when moved. nil when
    /// too little is left.
    static func voiced(_ x: [Float], _ run: Run, rate: Double) -> Run? {
        let step = Int(rate * 0.005), half = Int(rate * 0.01)
        let points = Array(stride(from: run.start, to: run.end, by: step))
        let levels = points.map { at -> Double in
            let range = max(0, at - half)..<min(x.count, at + half)
            return 10 * log10(range.reduce(0) { $0 + Double(x[$1] * x[$1]) } / Double(max(1, range.count)) + 1e-12)
        }
        guard let loudest = levels.max() else { return nil }
        let good = points.indices.map { levels[$0] > loudest - 20 && period(x, at: points[$0], rate: rate) != nil }
        guard let first = good.firstIndex(of: true), let last = good.lastIndex(of: true) else { return nil }
        let start = points[first], end = min(run.end, points[last] + step)
        guard end - start > Int(rate * 0.03) else { return nil }
        return Run(start: start, end: end, guarded: run.guarded && start == run.start)
    }

    /// The run, re-voiced at `ratio` times its pitch: each period cut out with
    /// a Hann window two periods wide, and laid down again closer together.
    /// nil where the run's pitch can't be followed (too short, unvoiced).
    static func shifted(_ x: [Float], run: Run, ratio: (Int) -> Double, rate: Double) -> [Float]? {
        let longest = Int(rate / 60)
        let lo = max(0, run.start - longest), hi = min(x.count, run.end + longest)
        let marks = pitchMarks(x, from: lo, to: hi, rate: rate)
        guard marks.count >= 4 else { return nil }
        var sum = [Double](repeating: 0, count: hi - lo)
        var weight = [Double](repeating: 0, count: hi - lo)
        // Period at each mark: the gap to its neighbours.
        func period(_ k: Int) -> Int {
            let before = k > 0 ? marks[k] - marks[k - 1] : marks[k + 1] - marks[k]
            let after = k + 1 < marks.count ? marks[k + 1] - marks[k] : before
            return max(1, (before + after) / 2)
        }
        var t = Double(marks[0])
        var k = 0
        while Int(t) < marks[marks.count - 1] {
            while k + 1 < marks.count, abs(Double(marks[k + 1]) - t) < abs(Double(marks[k]) - t) { k += 1 }
            let p = period(k)
            let centre = Int(t.rounded())
            for j in -p..<p {
                let source = marks[k] + j, target = centre + j
                guard source >= lo, source < hi, target >= lo, target < hi else { continue }
                let w = 0.5 + 0.5 * cos(Double.pi * Double(j) / Double(p))
                sum[target - lo] += w * Double(x[source])
                weight[target - lo] += w
            }
            t += Double(p) / max(1, ratio(centre))
        }
        // Only where marks on both sides cover it; the rest stays as it was.
        let covered = marks[1]...marks[marks.count - 2]
        return (run.start..<run.end).map { i in
            covered.contains(i) && weight[i - lo] > 0.3 ? Float(sum[i - lo] / weight[i - lo]) : x[i]
        }
    }

    /// One mark per glottal period between `from` and `to`, each on the
    /// period's highest sample, stepping by the local period. Empty where
    /// the stretch isn't voiced.
    static func pitchMarks(_ x: [Float], from: Int, to: Int, rate: Double) -> [Int] {
        guard let first = period(x, at: from, rate: rate) ?? period(x, at: (from + to) / 2, rate: rate)
        else { return [] }
        var marks: [Int] = []
        var p = first
        // The first mark: the highest sample in the first period.
        var mark = (from..<min(to, from + p)).max(by: { x[$0] < x[$1] }) ?? from
        while mark < to {
            marks.append(mark)
            p = period(x, at: mark, rate: rate).map { min(max($0, p * 3 / 4), p * 4 / 3) } ?? p
            let guess = mark + p, reach = max(1, p / 5)
            let window = max(mark + 1, guess - reach)..<min(x.count, guess + reach + 1)
            guard !window.isEmpty, let next = window.max(by: { x[$0] < x[$1] }) else { break }
            mark = next
        }
        return marks
    }

    /// The period at `at`, in samples, by normalised autocorrelation over
    /// 30 ms, 60 to 700 Hz: the shortest lag nearly as alike as the best one, so a period
    /// isn't mistaken for two. nil when nothing repeats.
    public static func period(_ x: [Float], at: Int, rate: Double) -> Int? {
        let frame = Int(rate * 0.03), low = Int(rate / 700), high = Int(rate / 60)
        let start = max(0, min(at - frame / 2, x.count - frame - high))
        guard start >= 0, start + frame + high <= x.count else { return nil }
        var scores = [Double](repeating: 0, count: high + 1)
        var e0 = 0.0
        for i in 0..<frame { e0 += Double(x[start + i] * x[start + i]) }
        guard e0 > 1e-6 else { return nil }
        for lag in low...high {
            var sum = 0.0, e1 = 0.0
            for i in 0..<frame {
                let a = Double(x[start + i]), b = Double(x[start + i + lag])
                sum += a * b
                e1 += b * b
            }
            scores[lag] = sum / max(1e-12, (e0 * e1).squareRoot())
        }
        guard let best = scores.max(), best > 0.5 else { return nil }
        for lag in (low + 1)..<high where scores[lag] >= best * 0.9
            && scores[lag] >= scores[lag - 1] && scores[lag] >= scores[lag + 1] {
            return lag
        }
        return scores.firstIndex(of: best)
    }
}
