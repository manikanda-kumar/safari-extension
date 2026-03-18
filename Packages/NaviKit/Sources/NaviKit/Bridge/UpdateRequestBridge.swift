import Foundation

public enum UpdateRequestBridge {
    public static let appGroupID = "group.com.finnvoorhees.Navi"
    public static let pendingCheckKey = "pendingSparkleCheckForUpdates"
    public static let notificationName = Notification.Name("com.finnvoorhees.Navi.checkForUpdates")

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
