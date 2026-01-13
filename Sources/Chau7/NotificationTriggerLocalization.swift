import Foundation
import Chau7Core

extension NotificationTriggerSourceInfo {
    var localizedLabel: String {
        L(labelKey, labelFallback)
    }
}

extension NotificationTrigger {
    var localizedLabel: String {
        L(labelKey, labelFallback)
    }

    var localizedDescription: String {
        L(descriptionKey, descriptionFallback)
    }
}
