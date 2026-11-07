# iOS Project Style & Architecture Guidelines

## 🚀 Project Tech Stack
- **Language:** Swift 6 (Strict concurrency checked)
- **UI Framework:** SwiftUI exclusively (No UIKit unless explicitly asked)
- **Minimum iOS Target:** iOS 17+
- **Dependency Manager:** Swift Package Manager (SPM)

## 🏛️ Architecture & State Management
- We use the **MVVM (Model-View-ViewModel)** architectural pattern.
- **State Framework:** Use the modern `@Observable` macro for ViewModels (iOS 17+). Avoid deprecated `ObservableObject` or `@Published` unless working on legacy files.
- **Data Flow:** Views should remain passive. Keep formatting logic, networking calls, and business rules entirely inside the ViewModel.
- **Concurrency:** Prefer native `async/await` and Task blocks over legacy completion handlers or Combine futures.

## 🎨 UI & Layout Rules
- **Previews:** Always provide a `#Preview` macro block at the bottom of View files. Include a mock data container for preview states.
- **Design System:** Use semantic system colors (`Color.accentColor`, `.secondary`, etc.) to natively support Light/Dark mode. Avoid hardcoded hex values.
- **Extracting Views:** If a SwiftUI view exceeds 150 lines, modularize it by breaking subviews out into private computed properties or separate `View` structs.

## 🧪 Testing & Quality Standards
- **Testing Framework:** Use the modern `Swift Testing` framework (`@Test`, `#expect`) instead of legacy `XCTest`.
- **Mocking:** Always code against protocols for services (e.g., `APIServiceProtocol`) to allow seamless mock injection during unit tests.
- **Linting:** Adhere strictly to idiomatic Swift formatting (e.g., trailing closures, omitted `return` statements for single-expression bodies).

## 🚫 What NOT to Do
- Never generate third-party CocoaPods instructions.
- Do not import Force-Unwraps (`!`). Always use conditional binding (`if let`, `guard let`) or provide fallback default values.
- Do not use `AnyView` type erasure unless completely unavoidable; prefer generics or `@ViewBuilder` attributes instead.