import IOKit.pwr_mgt
import os

/// Keeps the display from idling to sleep while lyrics show on the lock screen. The lock screen
/// otherwise dims and sleeps the display within a minute, long before a song ends.
///
/// One IOKit power assertion, held only while `isHeld` is true. Releasing it hands display sleep
/// straight back to the system's own settings.
@MainActor
final class ScreenAwake {
    private let logger = Logger(subsystem: "com.openlyrics.app", category: "ScreenAwake")
    private var assertionID: IOPMAssertionID = 0

    private(set) var isHeld = false

    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        if held {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "OpenLyrics is showing lyrics on the lock screen" as CFString,
                &assertionID
            )
            guard status == kIOReturnSuccess else {
                logger.error("Couldn't keep the display awake: \(status, privacy: .public)")
                return
            }
            isHeld = true
            logger.info("Keeping the display awake")
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHeld = false
            logger.info("Display may sleep again")
        }
    }
}
