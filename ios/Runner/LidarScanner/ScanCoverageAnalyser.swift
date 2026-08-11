import Foundation
import simd

/// Works out how much of a log has actually been seen.
///
/// The scan used to report the bounding box of everything captured, which
/// answers a different question from the one that matters. A bounding box
/// grows whether the user is walking the length of the trunk or backing away
/// from it, and it says nothing at all about whether the two cut ends have
/// been looked at. A sweep could stop halfway along a log and report a
/// perfectly healthy-looking extent.
///
/// This measures the log in its own frame instead: along the axis, around
/// the axis, and -- the part nothing else can answer -- whether the cloud
/// stops at each end because the log stops there, or because the user did.
struct ScanCoverageAnalyser {

    struct Coverage {
        let axisLengthMetres: Float

        /// Worst angular coverage of any section along the trunk, in
        /// degrees. The worst rather than the average: one thinly-seen
        /// section is where the circle fit will go wrong, and averaging
        /// hides exactly that.
        let angularCoverageDegrees: Float

        /// How full the cross-section is at each end of the observed span,
        /// 0..1. See `fill(of:)` for why this is the end test.
        let endFillStart: Float
        let endFillEnd: Float

        /// Occupancy per section, for the coverage bar in the UI.
        let axialBins: [Int]

        /// The fitted log, so the overlay can draw what the app has locked
        /// onto rather than leaving the user to guess from a haze of points.
        let centroid: simd_float3
        let axis: simd_float3
        let radius: Float
        let minT: Float
        let maxT: Float

        var isUsable: Bool { axisLengthMetres > 0 && radius > 0 }

        static let empty = Coverage(
            axisLengthMetres: 0,
            angularCoverageDegrees: 0,
            endFillStart: 0,
            endFillEnd: 0,
            axialBins: [],
            centroid: simd_float3(repeating: 0),
            axis: simd_float3(0, 1, 0),
            radius: 0,
            minT: 0,
            maxT: 0
        )
    }

    /// Sections along the log and sectors around it, when the cloud is dense
    /// enough to support them.
    static let maxBinCount = 48
    static let maxSectorCount = 36

    /// The coarsest the analysis will go. Below these, "have I been all the
    /// way round" stops meaning anything.
    static let minBinCount = 6
    static let minSectorCount = 8

    /// A sector counts as seen once this many points fall in it, so a single
    /// stray depth return cannot claim a whole sector was covered.
    static let minPointsPerSector = 3

    /// Below this the cloud is sparse enough that three per sector is a
    /// bigger share of it than the rule ever meant to demand.
    static let sparseCloudThreshold = 2000

    /// Points a sector needs before it counts as seen.
    ///
    /// Two on a sparse cloud: the rule exists to stop one stray return
    /// claiming a sector, and two already does that, while three on an
    /// object returning twenty points around its whole circumference
    /// rejects sectors the sensor genuinely saw.
    static func pointsPerSector(totalPoints: Int) -> Int {
        totalPoints < sparseCloudThreshold ? 2 : minPointsPerSector
    }

    /// Sections along the log, chosen from how many points there are.
    ///
    /// Fixed at 48, this was an assumption about density dressed up as a
    /// constant. A section is only judged once it holds a sector's worth of
    /// points, so on a sparse cloud no section is judged at all and angular
    /// coverage comes back zero however carefully the user walked round. A
    /// 10 cm object yields at most ~300 points -- six per section -- and so
    /// could never have finished a scan.
    ///
    /// Mirrors `LogCloudCoverage` in Dart, which is where this is tested.
    /// Keep the two in step.
    static func bins(forPointCount count: Int) -> Int {
        let affordable =
            count / (minSectorCount * pointsPerSector(totalPoints: count) * 2)

        return min(maxBinCount, max(minBinCount, affordable))
    }

    /// Sectors around the trunk, chosen from how many points a section holds.
    static func sectors(inSection sectionCount: Int, totalPoints: Int) -> Int {
        let affordable =
            sectionCount / (pointsPerSector(totalPoints: totalPoints) * 2)

        return min(maxSectorCount, max(minSectorCount, affordable))
    }

    /// Radial rings and sectors the inner disc is divided into when judging
    /// whether a cross-section is a sawn face.
    static let fillRings = 3
    static let fillSectors = 12

    /// Points needed in a cell before it counts as occupied.
    ///
    /// Occupancy saturates, which is the whole reason it works -- but that
    /// also means a single stray return would claim a whole cell. Real depth
    /// data scatters a few points inside the trunk's silhouette, and thirteen
    /// of them landing in thirteen different cells would read as a sawn end
    /// and let the user finish a scan that never saw one. A real face puts
    /// dozens of points in every cell, so requiring three costs nothing.
    static let minPointsPerFillCell = 3

    static func analyse(points: [simd_float3]) -> Coverage {
        guard points.count >= 100 else { return .empty }

        let centroid = mean(of: points)
        let axis = principalAxis(of: points, about: centroid)

        // A degenerate axis means the cloud has no dominant direction --
        // a wall or the ground rather than a log.
        guard simd_length(axis) > 0.5 else { return .empty }

        // An orthonormal basis across the axis, so the angle round the trunk
        // is well defined.
        let (u, v) = basis(perpendicularTo: axis)

        var axialPositions = [Float](repeating: 0, count: points.count)
        var radii = [Float](repeating: 0, count: points.count)
        var angles = [Float](repeating: 0, count: points.count)

        var minT = Float.greatestFiniteMagnitude
        var maxT = -Float.greatestFiniteMagnitude

        for (i, point) in points.enumerated() {
            let offset = point - centroid

            let t = simd_dot(offset, axis)
            let radial = offset - t * axis

            axialPositions[i] = t
            radii[i] = simd_length(radial)
            angles[i] = atan2(simd_dot(radial, v), simd_dot(radial, u))

            minT = min(minT, t)
            maxT = max(maxT, t)
        }

        let length = maxT - minT
        guard length > 0.01 else { return .empty }

        // --- bin along the axis ------------------------------------------

        let binCount = bins(forPointCount: points.count)
        var binPoints = [[Int]](repeating: [], count: binCount)

        for i in 0..<points.count {
            let normalised = (axialPositions[i] - minT) / length
            let bin = min(binCount - 1, max(0, Int(normalised * Float(binCount))))
            binPoints[bin].append(i)
        }

        let counts = binPoints.map { $0.count }

        // --- angular coverage, worst interior section ---------------------

        // End sections are skipped: a sawn face is a disc, not a ring, so
        // its points cluster near the axis and its "angular coverage" means
        // nothing. The circle fits that matter happen along the trunk.
        let skip = max(1, binCount / 12)
        var worstAngular = Float(360)
        var sawAnySection = false

        for bin in skip..<(binCount - skip) {
            let indices = binPoints[bin]

            let sectorCount = sectors(
                inSection: indices.count, totalPoints: points.count
            )
            guard indices.count >= sectorCount else { continue }

            // Angles are measured about this section's own fitted centre,
            // not the cloud's centroid.
            //
            // The centroid of a partial arc sits inside the bulge of that
            // arc, so angles taken from it fan out wider than the arc really
            // is: a 170 degree sweep measured 250. Overstating coverage is
            // the dangerous direction -- it lets a thin arc finish a scan,
            // and a circle fitted to a thin arc is exactly what puts
            // centimetres of error into a radius, which then squares into
            // the volume someone is paid on.
            let section = indices.map { i in
                SIMD2<Float>(
                    radii[i] * cos(angles[i]),
                    radii[i] * sin(angles[i])
                )
            }

            let centre = fitCircleCentre(of: section)

            var sectorCounts = [Int](repeating: 0, count: sectorCount)

            for p in section {
                let angle = atan2(p.y - centre.y, p.x - centre.x)

                var normalised = angle / (2 * Float.pi) + 0.5
                normalised = min(max(normalised, 0), 0.999_9)

                let sector = Int(normalised * Float(sectorCount))
                sectorCounts[sector] += 1
            }

            let required = pointsPerSector(totalPoints: points.count)
            let seen = sectorCounts.filter { $0 >= required }.count
            let degrees = Float(seen) * (360 / Float(sectorCount))

            worstAngular = min(worstAngular, degrees)
            sawAnySection = true
        }

        // A representative trunk radius: the median over interior sections,
        // which is robust to the end faces (whose points run in to the axis)
        // and to a stray return beyond the surface.
        var interiorRadii: [Float] = []
        for bin in skip..<(binCount - skip) {
            for i in binPoints[bin] { interiorRadii.append(radii[i]) }
        }
        interiorRadii.sort()

        let radius = interiorRadii.isEmpty
            ? 0
            : interiorRadii[interiorRadii.count / 2]

        return Coverage(
            axisLengthMetres: length,
            angularCoverageDegrees: sawAnySection ? worstAngular : 0,
            endFillStart: fill(
                of: binPoints.first ?? [], radii: radii, angles: angles
            ),
            endFillEnd: fill(
                of: binPoints.last ?? [], radii: radii, angles: angles
            ),
            axialBins: counts,
            centroid: centroid,
            axis: axis,
            radius: radius,
            minT: minT,
            maxT: maxT
        )
    }

    /// How full a cross-section's disc is, 0..1.
    ///
    /// This is the measurement that tells "the log ends here" from "I
    /// stopped looking here", and nothing else in the cloud can. Along the
    /// trunk the sensor only ever sees the curved surface, so the points of
    /// a section sit in a ring at roughly the trunk radius and the middle of
    /// the disc is empty. At a sawn end the whole face is visible at once,
    /// so points fill in towards the axis.
    ///
    /// Measured as the share of *cells* inside half the outer radius that
    /// hold points -- not the share of points falling there. Counting points
    /// sounds equivalent and is not: the same section also holds the ring of
    /// surface points around it, so the figure gets diluted by however much
    /// trunk happens to sit in that section and by how long the user lingered
    /// on the face. A fully-seen cut face measured only 0.18 that way against
    /// 0.08 for an unscanned end -- far too narrow a gap to threshold on.
    /// Occupancy separates them at roughly 1.0 against 0.0.
    ///
    /// Mirrors `LogCloudCoverage.fill` in Dart, which is where this is
    /// tested. Keep the two in step.
    private static func fill(
        of indices: [Int], radii: [Float], angles: [Float]
    ) -> Float {
        guard indices.count >= 20 else { return 0 }

        let sectionRadii = indices.map { radii[$0] }.sorted()

        // A high percentile rather than the maximum: one stray point beyond
        // the surface would otherwise set the reference and make every real
        // end look empty.
        let outer = sectionRadii[Int(Float(sectionRadii.count) * 0.9)]
        guard outer > 0 else { return 0 }

        let limit = outer * 0.5

        // The grid is sized to the points there are to put in it.
        //
        // Fixed at 3 rings by 12 sectors, the disc needed 108 points before
        // it could read as full at all -- more than a small object's whole
        // end face returns -- so it read empty however squarely the user
        // pointed at it and the scan could never finish.
        //
        // Sized from the whole section, never from the inner points alone.
        // Sizing it from the inner points is self-fulfilling: a handful of
        // stray returns would then get a grid coarse enough for a handful to
        // fill, and read as a sawn face.
        let cellBudget = min(
            fillRings * fillSectors,
            max(4, indices.count / (minPointsPerFillCell * 6))
        )

        let rings = cellBudget <= 8 ? 1 : (cellBudget <= 18 ? 2 : fillRings)
        let sectors = max(4, cellBudget / rings)

        var cells = [Int](repeating: 0, count: rings * sectors)

        for i in indices where radii[i] < limit {
            let ring = min(
                rings - 1,
                max(0, Int((radii[i] / limit) * Float(rings)))
            )

            var normalised = angles[i] / (2 * Float.pi) + 0.5
            normalised = min(max(normalised, 0), 0.999_9)

            let sector = Int(normalised * Float(sectors))

            cells[ring * sectors + sector] += 1
        }

        let occupied = cells.filter { $0 >= minPointsPerFillCell }.count

        return Float(occupied) / Float(cells.count)
    }

    /// Algebraic (Kasa) circle fit, returning just the centre.
    ///
    /// Linear least squares rather than an iterative geometric fit: the
    /// centre is all that is wanted, it is wanted for every section on every
    /// progress tick four times a second, and a fit good to a few millimetres
    /// is ample for deciding which sectors have been seen.
    private static func fitCircleCentre(
        of points: [SIMD2<Float>]
    ) -> SIMD2<Float> {
        // Doubles throughout: the sums run to the fourth power of the
        // coordinates, and Float loses the determinant to rounding on a
        // section of a few hundred points.
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        var sxz = 0.0, syz = 0.0

        for p in points {
            let x = Double(p.x), y = Double(p.y)
            let z = x * x + y * y

            sx += x
            sy += y
            sxx += x * x
            syy += y * y
            sxy += x * y
            sxz += x * z
            syz += y * z
        }

        let n = Double(points.count)

        let a = 2 * (sx * sx - n * sxx)
        let b = 2 * (sx * sy - n * sxy)
        let c = 2 * (sy * sy - n * syy)

        let d = n * sxz - sx * (sxx + syy)
        let e = n * syz - sy * (sxx + syy)

        let determinant = a * c - b * b

        // Collinear or degenerate: fall back to the section's own mean,
        // which is no worse than what this did before the fit existed.
        guard abs(determinant) > 1e-12, n > 0 else {
            return SIMD2<Float>(Float(sx / n), Float(sy / n))
        }

        return SIMD2<Float>(
            Float((d * c - b * e) / determinant),
            Float((a * e - d * b) / determinant)
        )
    }

    // --- geometry ---------------------------------------------------------

    private static func mean(of points: [simd_float3]) -> simd_float3 {
        var total = simd_float3(repeating: 0)

        for point in points { total += point }

        return total / Float(points.count)
    }

    /// The direction the cloud is longest in, by power iteration on the
    /// covariance matrix.
    ///
    /// Power iteration rather than a full eigen-decomposition because simd
    /// offers none and the largest eigenvector is the only one wanted. It
    /// converges in a handful of steps for a shape as elongated as a log,
    /// which is precisely the case where the answer matters.
    private static func principalAxis(
        of points: [simd_float3],
        about centroid: simd_float3
    ) -> simd_float3 {
        var covariance = simd_float3x3(0)

        for point in points {
            let d = point - centroid
            covariance += simd_float3x3(
                simd_float3(d.x * d.x, d.x * d.y, d.x * d.z),
                simd_float3(d.y * d.x, d.y * d.y, d.y * d.z),
                simd_float3(d.z * d.x, d.z * d.y, d.z * d.z)
            )
        }

        // Seeded off-axis so a cloud that happens to lie along a coordinate
        // axis does not start on an exact eigenvector of the wrong one.
        var vector = simd_normalize(simd_float3(0.577, 0.577, 0.577))

        for _ in 0..<32 {
            let next = covariance * vector
            let magnitude = simd_length(next)

            guard magnitude > 1e-9 else { return simd_float3(0, 0, 0) }

            vector = next / magnitude
        }

        return vector
    }

    /// Two unit vectors spanning the plane across [axis].
    private static func basis(
        perpendicularTo axis: simd_float3
    ) -> (simd_float3, simd_float3) {
        // Cross with whichever world axis the log is least aligned to, so
        // the cross product is never near zero.
        let helper = abs(axis.y) < 0.9
            ? simd_float3(0, 1, 0)
            : simd_float3(1, 0, 0)

        let u = simd_normalize(simd_cross(axis, helper))
        let v = simd_normalize(simd_cross(axis, u))

        return (u, v)
    }
}
