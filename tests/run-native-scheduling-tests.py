#!/usr/bin/env python3
"""Run the production calendar planner on macOS without loading iOS services.

The app has no test target. A temporary Swift package compiles the unchanged
Foundation model declarations and pure planner from their source files; UIKit,
notification-center I/O and ProductStore persistence are excluded explicitly.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / "DateExpiryApp/Product.swift").read_text().split("@MainActor\nfinal class ProductStore", 1)[0]
model = model.replace("import Combine\n", "").replace("import UIKit\n", "")
# ProductRecord.imageURL is not used by planning; satisfy its store reference.
model += '\nenum ProductStore { static var imagesDirectory: URL { URL(fileURLWithPath: "/unused") } }\n'
notifications = (root / "DateExpiryApp/ReminderNotifications.swift").read_text()
planner = notifications.split("    static func scheduledCandidates(", 1)[1]
planner = "    static func scheduledCandidates(" + planner.rsplit("\n}\n\n@MainActor\nfinal class DateExpiryAppDelegate", 1)[0]
with tempfile.TemporaryDirectory(prefix="date-expiry-scheduling-") as directory:
    package = Path(directory)
    (package / "Sources/Scheduling").mkdir(parents=True)
    (package / "Tests/SchedulingTests").mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Scheduling", platforms: [.macOS(.v14)], targets: [
    .target(name: "Scheduling"),
    .testTarget(name: "SchedulingTests", dependencies: ["Scheduling"])
])
''')
    (package / "Sources/Scheduling/Scheduling.swift").write_text(
        model + "\n@MainActor\nenum ReminderNotifications {\n" + planner + "\n}\n")
    (package / "Tests/SchedulingTests/ReminderScheduleTests.swift").write_text(
        (root / "tests/ReminderScheduleTests.swift").read_text())
    subprocess.run(["swift", "test", "--package-path", str(package), "--cache-path", str(package / "cache")], check=True)
