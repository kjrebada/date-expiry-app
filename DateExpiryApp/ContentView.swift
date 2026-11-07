import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var store = ProductStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedScreen: ProductScreen = .active
    @State private var presentation: CaptureFlow = .idle
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var coverIsPresented = false
    @State private var pendingNotificationNotice = false

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: {
                switch presentation {
                case .camera, .editor:
                    true
                case .idle, .requestingCamera, .captured, .recognizing:
                    false
                }
            },
            set: { isPresented in
                guard !isPresented else { return }
                switch presentation {
                case .camera, .editor:
                    presentation = .idle
                case .idle, .requestingCamera, .captured, .recognizing:
                    break
                }
            }
        )
    }

    private var activeProducts: [ProductRecord] {
        store.products.filter { $0.status == .active }.sorted { $0.expiryDate < $1.expiryDate }
    }

    private var toBuyAgain: [ProductRecord] {
        store.products.filter { $0.status == .toBuyAgain }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Products", selection: $selectedScreen) {
                    ForEach(ProductScreen.allCases) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch selectedScreen {
                case .active:
                    activeList
                case .toBuyAgain:
                    repurchaseList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(Color(red: 35.0 / 255, green: 100.0 / 255, blue: 73.0 / 255))
            .navigationTitle("Expiry Tracker")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: startCamera) {
                        Label("Scan label", systemImage: "camera")
                    }
                    Button(action: createManualEntry) {
                        Label("Add product", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if case .recognizing = presentation {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        ProgressView("Reading label…")
                            .font(.headline)
                            .controlSize(.large)
                            .padding(28)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(.isModal)
                }
            }
            .fullScreenCover(isPresented: presentationBinding, onDismiss: handlePresentationDismissal) {
                Group {
                    switch presentation {
                    case .camera:
                        CameraPicker(onCapture: handleCapture, onCancel: cancelCamera)
                            .ignoresSafeArea()
                    case .editor(let draft):
                        ProductEditor(draft: draft) { name, date, kind, image in
                            try saveProduct(draft: draft, name: name, date: date, kind: kind, image: image)
                        }
                    case .idle, .requestingCamera, .captured, .recognizing:
                        EmptyView()
                    }
                }
                .onAppear { coverIsPresented = true }
            }
            .alert("Expiry Tracker", isPresented: $showingAlert) {
                if alertMessage.contains("Settings") {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .task {
                if let loadError = store.loadError {
                    alertMessage = "Saved products could not be loaded. Changes are disabled to protect your existing data. \(loadError)"
                    showingAlert = true
                    return
                }
                await ReminderNotifications.shared.reconcile()
            }
            .onChange(of: showingAlert) { _, isPresented in
                if !isPresented { presentPendingNotificationNotice() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                presentPendingNotificationNotice()
                Task {
                    await ReminderNotifications.shared.reconcile()
                }
            }
        }
    }

    private var activeList: some View {
        Group {
            if activeProducts.isEmpty {
                ContentUnavailableView {
                    Label("Nothing expiring yet", systemImage: "takeoutbag.and.cup.and.straw")
                } description: {
                    Text("Scan a label or add a product manually.")
                } actions: {
                    Button("Add product", action: createManualEntry)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(activeProducts) { product in
                            Button {
                                editProduct(product)
                            } label: {
                                ProductRow(product: product)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens product details for editing")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        moveToRepurchase(product, disposition: "Thrown")
                                    } label: {
                                        Label("Thrown", systemImage: "trash")
                                    }
                                    .tint(.orange)
                                    Button {
                                        moveToRepurchase(product, disposition: "Consumed")
                                    } label: {
                                        Label("Consumed", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                }
                        }
                    } header: {
                        Text("Active products")
                    } footer: {
                        Text("Tap a product to edit it. OCR results are suggestions—verify the product name and date before saving.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var repurchaseList: some View {
        Group {
            if toBuyAgain.isEmpty {
                ContentUnavailableView("Your To Buy Again list is empty", systemImage: "cart", description: Text("Mark an active product as consumed or thrown to add it here."))
            } else {
                List {
                    Section("To Buy Again") {
                        ForEach(toBuyAgain) { product in
                            ProductRow(product: product, showsDisposition: true)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        removeFromRepurchase(product)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete(perform: deleteRepurchaseRows)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func createManualEntry() {
        presentation = .editor(ProductDraft(image: nil, suggestedName: nil, suggestedDate: nil))
    }

    private func editProduct(_ product: ProductRecord) {
        presentation = .editor(ProductDraft(
            image: nil,
            suggestedName: product.name,
            suggestedDate: product.expiryDate,
            existingProduct: product
        ))
    }

    private func startCamera() {
        guard case .idle = presentation else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            alertMessage = "A device camera is not available. You can still add the product and its date manually."
            showingAlert = true
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentation = .camera
        case .notDetermined:
            presentation = .requestingCamera
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard case .requestingCamera = presentation else { return }
                    if granted {
                        presentation = .camera
                    } else {
                        presentation = .idle
                        showCameraPermissionMessage()
                    }
                }
            }
        case .denied, .restricted:
            showCameraPermissionMessage()
        @unknown default:
            showCameraPermissionMessage()
        }
    }

    private func showCameraPermissionMessage() {
        alertMessage = "Camera access is off. Allow camera access in Settings to scan labels, or add product details manually."
        showingAlert = true
    }

    private func cancelCamera() {
        DispatchQueue.main.async {
            guard case .camera = presentation else { return }
            presentation = .idle
        }
    }

    private func handleCapture(_ image: UIImage) {
        DispatchQueue.main.async {
            guard case .camera = presentation else { return }
            presentation = .captured(image)
        }
    }

    private func handlePresentationDismissal() {
        coverIsPresented = false
        guard case .captured(let image) = presentation else {
            presentPendingNotificationNotice()
            return
        }
        presentation = .recognizing(image)

        DispatchQueue.global(qos: .userInitiated).async {
            let suggestion = ExpiryOCR.recognize(in: image)
            DispatchQueue.main.async {
                guard case .recognizing = presentation else { return }
                presentation = .editor(ProductDraft(
                    image: image,
                    suggestedName: suggestion.productName,
                    suggestedDate: suggestion.date
                ))
            }
        }
    }

    private func saveProduct(
        draft: ProductDraft,
        name: String,
        date: LocalCalendarDate,
        kind: ProductDateKind,
        image: UIImage?
    ) throws {
        if let existingProduct = draft.existingProduct {
            try store.update(existingProduct.id, name: name, date: date, kind: kind)
            Task {
                await ReminderNotifications.shared.reconcile()
            }
        } else {
            try store.add(name: name, date: date, kind: kind, image: image)
            Task {
                let granted = await ReminderNotifications.shared.requestAuthorizationIfNeeded()
                await ReminderNotifications.shared.reconcile()
                if !granted {
                    pendingNotificationNotice = true
                    presentPendingNotificationNotice()
                }
            }
        }
    }

    private func presentPendingNotificationNotice() {
        // The cover binding can turn false during its dismissal animation. Wait for
        // onDismiss, and retain the notice if another flow or alert owns the screen.
        guard pendingNotificationNotice, !coverIsPresented, !showingAlert,
              scenePhase == .active, case .idle = presentation else { return }
        pendingNotificationNotice = false
        alertMessage = "Product saved. Notifications are off, so expiry reminders cannot be delivered. You can enable them in Settings."
        showingAlert = true
    }

    private func moveToRepurchase(_ product: ProductRecord, disposition: String) {
        do {
            try store.markForRepurchase(product.id, disposition: disposition)
            Task { await ReminderNotifications.shared.reconcile() }
        } catch {
            present(error)
        }
    }

    private func removeFromRepurchase(_ product: ProductRecord) {
        do {
            try store.removeFromRepurchase(product.id)
            Task { await ReminderNotifications.shared.reconcile() }
        } catch {
            present(error)
        }
    }

    private func deleteRepurchaseRows(at offsets: IndexSet) {
        let productsToRemove = offsets.map { toBuyAgain[$0] }
        for product in productsToRemove {
            removeFromRepurchase(product)
        }
    }

    private func present(_ error: Error) {
        alertMessage = "Could not update product: \(error.localizedDescription)"
        showingAlert = true
    }
}

private enum CaptureFlow {
    case idle
    case requestingCamera
    case camera
    case captured(UIImage)
    case recognizing(UIImage)
    case editor(ProductDraft)
}

private enum ProductScreen: String, CaseIterable, Identifiable {
    case active
    case toBuyAgain

    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: "Active"
        case .toBuyAgain: "To Buy Again"
        }
    }
}

private struct ProductDraft: Identifiable {
    var id = UUID()
    var image: UIImage?
    var suggestedName: String?
    var suggestedDate: LocalCalendarDate?
    var existingProduct: ProductRecord? = nil
}

private struct ProductRow: View {
    var product: ProductRecord
    var showsDisposition = false

    var body: some View {
        HStack(spacing: 12) {
            ProductThumbnail(url: product.imageURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(product.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(product.dateKind.rawValue) · \(product.expiryDate.formatted)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ExpiryStatusBadge(expiryDate: product.expiryDate)
                if showsDisposition, let disposition = product.lastDisposition {
                    Text(disposition)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct ProductThumbnail: View {
    var url: URL?
    var expanded = false

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "takeoutbag.and.cup.and.straw")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(width: expanded ? nil : 58, height: expanded ? 190 : 58)
        .frame(maxWidth: expanded ? .infinity : 58)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ExpiryStatusBadge: View {
    var expiryDate: LocalCalendarDate

    private var status: ExpiryStatus {
        ExpiryStatus(expiryDate: expiryDate)
    }

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Expiry status: \(status.title)")
    }
}

private enum ExpiryStatus {
    case overdue
    case dueToday
    case dueSoon
    case upcoming

    init(expiryDate: LocalCalendarDate, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let expiryComponents = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: expiryDate.year,
            month: expiryDate.month,
            day: expiryDate.day
        )

        guard let expiryDay = calendar.date(from: expiryComponents) else {
            self = .upcoming
            return
        }

        let today = calendar.startOfDay(for: now)
        let expiry = calendar.startOfDay(for: expiryDay)
        let dayDifference = calendar.dateComponents([.day], from: today, to: expiry).day ?? 0

        switch dayDifference {
        case ..<0:
            self = .overdue
        case 0:
            self = .dueToday
        case 1...3:
            self = .dueSoon
        default:
            self = .upcoming
        }
    }

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .dueToday: "Due today"
        case .dueSoon: "Due soon"
        case .upcoming: "Upcoming"
        }
    }

    var symbol: String {
        switch self {
        case .overdue: "exclamationmark.circle.fill"
        case .dueToday: "clock.fill"
        case .dueSoon: "clock"
        case .upcoming: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .overdue: .red
        case .dueToday: .orange
        case .dueSoon: .orange
        case .upcoming: .green
        }
    }
}

private struct ProductEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedDate: Date
    @State private var kind: ProductDateKind
    @State private var saveErrorMessage = ""
    @State private var showingSaveError = false

    var draft: ProductDraft
    var onSave: (String, LocalCalendarDate, ProductDateKind, UIImage?) throws -> Void

    init(
        draft: ProductDraft,
        onSave: @escaping (String, LocalCalendarDate, ProductDateKind, UIImage?) throws -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.suggestedName ?? "")
        _selectedDate = State(initialValue: draft.suggestedDate?.date() ?? Date())
        _kind = State(initialValue: draft.existingProduct?.dateKind ?? .useBy)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image = draft.image {
                    Section("Captured label") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .frame(maxWidth: .infinity)
                        Text(draft.suggestedName == nil
                             ? "Product name was not identified. Enter it below before saving; the captured image will be kept with the product."
                             : "OCR suggestions may be incorrect. Verify and correct the product name first, then confirm the expiry date.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(draft.image == nil ? "Product details" : "Verify product name") {
                    TextField("Product name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    if draft.image != nil {
                        Text("Check that this matches the product label, then correct it if needed.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Picker("Date type", selection: $kind) {
                        ForEach(ProductDateKind.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .environment(\.calendar, Calendar(identifier: .gregorian))
                    Text("Expiry date: \(LocalCalendarDate(date: selectedDate).formatted)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(
                draft.existingProduct != nil
                    ? "Edit Product"
                    : (draft.image == nil ? "Add Product" : "Confirm Scan")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(name, LocalCalendarDate(date: selectedDate), kind, draft.image)
                            dismiss()
                        } catch {
                            saveErrorMessage = error.localizedDescription
                            showingSaveError = true
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not save product", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage)
            }
        }
    }
}
