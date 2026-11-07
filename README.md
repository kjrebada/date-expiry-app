# DateExpiryApp

A native SwiftUI app for tracking product use-by and best-before dates.

## Features

- Capture product labels with the device camera. On-device Vision OCR suggests a product name and date; numeric OCR dates are interpreted day-first (`DD/MM/YYYY`), and the suggestions should be confirmed or edited before saving.
- If OCR cannot suggest a name, the captured image remains in the confirmation form and saving stays disabled until a name is entered.
- Add products and dates manually when camera access is unavailable or not wanted.
- Product records and captured JPEG images are stored locally in the app's Application Support directory. The app does not send images or OCR text to a server.
- Expiry dates displayed by the app use `DD MMM YYYY` (for example, `07 Nov 2026`); persisted record dates remain `MM/DD/YYYY` (for example, `11/06/2026`).
- The app has Active and To Buy Again views. Tapping an Active product opens an edit form with Save and Cancel actions; existing images are retained when editing.
- Mark products consumed or thrown to move them to To Buy Again; remove products from that list when no longer needed.
- Dates are stored as Gregorian calendar days in the local time zone, not as time-zone-sensitive instants. Changing an expiry date clears an active snooze.
- Local reminders start three days before the date, at 9:00 AM local time. Overdue use-by items repeat hourly and overdue best-before items repeat daily. Notification actions mark an item consumed/thrown or snooze it for one day.

## Notifications and iOS limits

The app asks for notification permission after the first product is saved. Reminders are local notifications and require that permission. The app maintains a rolling queue of at most 60 pending requests, below iOS's 64-request pending-notification limit. Upcoming expiry reminders are prioritized, then spare queue entries are shared among overdue products.

iOS does not provide a way for an app to keep replenishing local hourly reminders indefinitely while it is suspended. The rolling queue is reconciled when the app returns to the foreground and after a notification action. Consequently, an overdue hourly series can pause after its already-scheduled requests are delivered if the app remains unopened and no notification action is used. iOS may also apply its own delivery timing policies.

## Run and build

Open `DateExpiryApp.xcodeproj` in Xcode, select an iOS 17 or later simulator/device, and run the `DateExpiryApp` target. A physical device is required to exercise camera capture; simulator users can enter products manually.

### Web version

From the repository root, start a local HTTP server:

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000/web/> in a browser. Expiry dates are displayed as `DD MMM YYYY` (for example, `07 Nov 2026`), while saved record dates use `MM/DD/YYYY`. Product records and image blobs are stored locally in IndexedDB for that browser and origin; this data is separate from the iOS app and is not synced. The web version does not upload data or images. Camera/file capture is best-effort, OCR is unavailable, and reliable scheduled notifications/background reminders are unsupported; expiry status is shown in the app.

If a web save succeeds but the list cannot refresh, the app confirms that the changes were saved and asks you to reload. Failed saves keep the form open and show the error inside it.

To build from a machine with Xcode installed:

```sh
xcodebuild -project DateExpiryApp.xcodeproj -scheme DateExpiryApp -destination 'platform=iOS Simulator,name=iPhone 16' build
```

The project has no separate test target. On a machine with the Apple SDK available, a syntax-only check can be run with:

```sh
swiftc -frontend -parse DateExpiryApp/*.swift
```

Camera access is described by the target's `NSCameraUsageDescription` privacy string. Notification permission is requested in context, after the first saved item.

### Regression checks

Run the dependency-free web checks from the repository root:

```sh
node tests/web.test.js
```

These cover calendar-date validation, recovery after correcting an invalid name, overlapping submissions, dismissal during a save, failed-write retries, committed writes followed by refresh failures, in-dialog error placement, and preserving edits/deletions from another tab. They use DOM and storage stubs and do not replace browser testing of IndexedDB, assistive technology, or camera capture.

On macOS with Xcode's Swift toolchain and Python 3 available, run the native calendar-planning checks from the repository root:

```sh
python3 tests/run-native-scheduling-tests.py
```

The runner extracts the unchanged production model declarations and pure calendar planner into a temporary Swift package and runs five Swift Testing checks for future hourly/daily follow-ups, snoozes, queue limits and priorities, fair allocation, and daylight-saving transitions. It excludes UIKit, persistence, and notification-center I/O; it does not replace an iOS build or device tests of notification delivery. No package dependencies are downloaded.

If the iOS app cannot read its saved records, it reports the failure and blocks writes to avoid overwriting existing data. Restart the app after resolving the storage issue; do not delete app data unless you intend to discard saved products.
