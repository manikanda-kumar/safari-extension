import Foundation

public enum UpdateRequestBridge {
    public static let appGroupID = "AQ5WW4KNGB.group.com.manik.Navi"
    public static let pendingCheckKey = "pendingSparkleCheckForUpdates"
    public static let notificationName = Notification.Name("com.manik.Navi.checkForUpdates")

    public static func markPendingCheckForUpdates() {
        UserDefaults(suiteName: appGroupID)?.set(true, forKey: pendingCheckKey)
    }

    public static func consumePendingCheckForUpdates() -> Bool {
        let defaults = UserDefaults(suiteName: appGroupID)
        let isPending = defaults?.bool(forKey: pendingCheckKey) == true
        if isPending {
            defaults?.removeObject(forKey: pendingCheckKey)
        }
        return isPending
    }
}
