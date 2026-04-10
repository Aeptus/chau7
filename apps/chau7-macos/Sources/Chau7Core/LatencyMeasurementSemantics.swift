import Foundation

public enum LatencyMeasurementSemantics {
    public enum InputMeasurementKind: Equatable {
        case terminalResponsiveness
        case aiRoundTrip
    }

    public static func inputMeasurementKind(
        hasBackgroundAIContext: Bool,
        detectedLaunchableApp: String?
    ) -> InputMeasurementKind {
        if hasBackgroundAIContext || detectedLaunchableApp != nil {
            return .aiRoundTrip
        }
        return .terminalResponsiveness
    }
}
