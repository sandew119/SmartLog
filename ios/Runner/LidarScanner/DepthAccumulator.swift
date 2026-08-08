import Foundation
import simd

/// Merges depth samples from many frames into one world-space point cloud.
///
/// This exists because a single depth frame is not enough to measure a log.
/// From one viewpoint the sensor sees perhaps 100-180 degrees of the trunk's
/// curve, and fitting a circle to that narrow an arc is ill-conditioned: a
/// few millimetres of depth noise become centimetres of radius error, and
/// radius error squares into volume error. Walking the length of the log
/// while accumulating solves both halves of that problem -- each
/// cross-section ends up seen from a range of angles, and repeated samples
/// of the same patch of bark average out.
///
/// Points are binned into a voxel grid so that standing still does not pile
/// up thousands of duplicate samples in one spot and bias the fit towards
/// wherever the user lingered. Each voxel keeps a running mean, so a surface
/// seen fifty times is one well-averaged point rather than fifty noisy ones.
final class DepthAccumulator {

    /// A snapshot of progress, cheap enough to hand to the UI many times a
    /// second for live coaching.
    struct Stats {
        let pointCount: Int
        let frameCount: Int
        let boundsMin: simd_float3
        let boundsMax: simd_float3

        /// Longest side of the accumulated bounding box, in metres. Grows as
        /// the user sweeps and plateaus once the whole log has been covered,
        /// which is exactly the signal the guidance needs.
        var extent: Float {
            let size = boundsMax - boundsMin
            return max(size.x, max(size.y, size.z))
        }
    }

    private struct Key: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct Cell {
        var sum: simd_float3
        var count: Float
    }

    /// 8 mm bins. Comfortably finer than the millimetre-scale accuracy the
    /// circle fits need, while still collapsing the many samples a lingering
    /// camera puts on one spot.
    static let defaultVoxelSize: Float = 0.008

    /// Caps memory at roughly a handful of megabytes. A 3 m log at 8 mm
    /// needs far fewer cells than this, so the limit only bites if someone
    /// scans an entire yard.
    static let defaultMaxCells = 200_000

    private var cells: [Key: Cell] = [:]
    private let voxelSize: Float
    private let maxCells: Int

    private var minBound = simd_float3(repeating: .greatestFiniteMagnitude)
    private var maxBound = simd_float3(repeating: -.greatestFiniteMagnitude)

    private(set) var frameCount = 0

    init(
        voxelSize: Float = DepthAccumulator.defaultVoxelSize,
        maxCells: Int = DepthAccumulator.defaultMaxCells
    ) {
        self.voxelSize = voxelSize > 0
            ? voxelSize
            : DepthAccumulator.defaultVoxelSize
        self.maxCells = maxCells
    }

    /// Folds one frame's worth of world-space points into the cloud.
    func add(_ points: [simd_float3]) {
        guard !points.isEmpty else { return }

        frameCount += 1
        let inverseSize = 1 / voxelSize
        let atCapacity = cells.count >= maxCells

        for point in points {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                continue
            }

            let key = Key(
                x: Int32((point.x * inverseSize).rounded(.down)),
                y: Int32((point.y * inverseSize).rounded(.down)),
                z: Int32((point.z * inverseSize).rounded(.down))
            )

            if var cell = cells[key] {
                cell.sum += point
                cell.count += 1
                cells[key] = cell
            } else {
                // Once full, keep refining what is already there rather than
                // truncating the scan at an arbitrary point in space.
                if atCapacity { continue }
                cells[key] = Cell(sum: point, count: 1)
            }

            minBound = simd_min(minBound, point)
            maxBound = simd_max(maxBound, point)
        }
    }

    /// How many times a voxel must be seen before it counts as real surface.
    ///
    /// A patch of bark that stays in view across a sweep is sampled many
    /// times. A voxel hit exactly once is far more likely to be a depth
    /// artefact -- an edge return, a glint, a stray pixel at the silhouette
    /// -- and those sit *outside* the true surface, so they push fitted radii
    /// out and inflate the volume. Requiring a second sighting costs almost
    /// nothing on a real sweep and removes most of them.
    static let defaultMinSightings: Float = 2

    /// The accumulated cloud, one averaged point per occupied voxel.
    ///
    /// Voxels seen fewer than [minSightings] times are dropped, unless that
    /// would leave too little to measure -- a very short sweep is still
    /// better handed to the quality gate than thrown away here.
    func snapshot(
        minSightings: Float = DepthAccumulator.defaultMinSightings
    ) -> [simd_float3] {
        var confident: [simd_float3] = []
        var all: [simd_float3] = []

        confident.reserveCapacity(cells.count)
        all.reserveCapacity(cells.count)

        for cell in cells.values where cell.count > 0 {
            let point = cell.sum / cell.count

            all.append(point)
            if cell.count >= minSightings { confident.append(point) }
        }

        // A quarter of the cloud is a generous floor: below that the sweep
        // was so brief that filtering would leave nothing to fit.
        return confident.count >= all.count / 4 ? confident : all
    }

    var stats: Stats {
        let empty = cells.isEmpty

        return Stats(
            pointCount: cells.count,
            frameCount: frameCount,
            boundsMin: empty ? .zero : minBound,
            boundsMax: empty ? .zero : maxBound
        )
    }

    func reset() {
        cells.removeAll(keepingCapacity: true)
        frameCount = 0
        minBound = simd_float3(repeating: .greatestFiniteMagnitude)
        maxBound = simd_float3(repeating: -.greatestFiniteMagnitude)
    }
}
