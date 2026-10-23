public enum ScrollStormThrottlePolicy {
    public static let enterDirtyThresholdNumerator = 85
    public static let enterDirtyThresholdDenominator = 100

    public static func shouldEnterScrollStorm(dirtyCells: Int, frameCells: Int) -> Bool {
        guard dirtyCells >= 0, frameCells > 0 else { return false }
        return dirtyCells * enterDirtyThresholdDenominator >= frameCells * enterDirtyThresholdNumerator
    }

    public static func shouldCountAsLowDirtyFrame(dirtyCells: Int, frameCells: Int) -> Bool {
        guard dirtyCells >= 0, frameCells > 0 else { return false }
        return dirtyCells * 2 < frameCells
    }
}
