import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct SupportTopic: Codable, Equatable {
    enum Kind: String, Codable {
        case training, payment
    }

    let kind: Kind
    let detail: String

    static func training(_ training: ScheduledTraining) -> Self {
        Self(kind: .training, detail: GroupPaymentView.trainingDate(training.startsAt))
    }

    static func payment(_ quote: TrainingQuote) -> Self {
        let amount = GroupPaymentView.rubles(quote.price)
        let format = HomeView.dateFormat.month(.abbreviated).year()
        let first = quote.periodStart.formatted(format)
        let last = quote.months.last?.start.formatted(format) ?? first
        let period = first == last ? first : "\(first) — \(last)"
        return Self(kind: .payment, detail: "\(period) · \(amount)")
    }

    var title: String {
        switch kind {
        case .training: "Тренировка"
        case .payment: "Оплата абонемента"
        }
    }

    var symbol: String {
        switch kind {
        case .training: "calendar"
        case .payment: "creditcard"
        }
    }
}

struct SupportMessage: Codable, Identifiable {
    let id: UUID
    let text: String
    let topic: SupportTopic?
    let sentAt: Date
    let fromPlayer: Bool
    let photos: [SupportPhoto]?

    init(id: UUID = UUID(), text: String, topic: SupportTopic? = nil, sentAt: Date = .now, fromPlayer: Bool, photos: [SupportPhoto]? = nil) {
        self.id = id
        self.text = text
        self.topic = topic
        self.sentAt = sentAt
        self.fromPlayer = fromPlayer
        self.photos = photos
    }
}

struct SupportDraftPhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let data: Data
    let aspectRatio: CGFloat

    init?(data: Data) {
        guard let image = PlayerPhoto.thumbnail(from: data, maxPixelSize: 1800),
              let jpeg = image.jpegData(compressionQuality: 0.88),
              let thumbnail = PlayerPhoto.thumbnail(from: jpeg, maxPixelSize: 224) else { return nil }
        self.thumbnail = thumbnail
        self.data = jpeg
        aspectRatio = image.size.width / image.size.height
    }
}

struct SupportPhoto: Codable, Identifiable {
    let id: UUID
    let aspectRatio: CGFloat

    private static let directory = URL.applicationSupportDirectory.appending(path: "Support Photos", directoryHint: .isDirectory)

    var url: URL { Self.directory.appending(path: id.uuidString + ".jpg") }

    static func save(_ drafts: [SupportDraftPhoto]) throws -> [Self] {
        guard !drafts.isEmpty else { return [] }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved: [Self] = []
        do {
            for draft in drafts {
                let photo = Self(id: draft.id, aspectRatio: draft.aspectRatio)
                try draft.data.write(to: photo.url, options: .atomic)
                saved.append(photo)
            }
            return saved
        } catch {
            for photo in saved { try? files.removeItem(at: photo.url) }
            throw error
        }
    }
}

struct PlayerSupportView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var account: LocalPlayerAccount
    @FocusState private var composerFocused: Bool
    @Namespace private var sendMotion
    @State private var draftMotionID = UUID()
    private enum TimestampDrag {
        case idle, vertical, horizontal(CGFloat)
    }

    @GestureState(resetTransaction: Transaction(animation: .smooth(duration: 0.25)))
    private var timestampDrag = TimestampDrag.idle
    @State private var showsGallery = false
    @State private var galleryDetent = Self.compactGallery
    @State private var confirmingGallery = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var loadedPhotos: [PhotosPickerItem: SupportDraftPhoto] = [:]
    @State private var completedSelection: [PhotosPickerItem] = []
    @State private var galleryInset: CGFloat = 0
    @State private var opensCameraAfterGallery = false
    @State private var showsCamera = false
    @State private var attachmentError: String?
    @State private var openedPhoto: SupportPhoto?
    @State private var historyPosition = ScrollPosition(edge: .bottom)
    @State private var initialHistoryOffset: CGFloat = 0

    private static let photoLimit = 50
    private static let timestampWidth: CGFloat = 54
    private static let galleryHeight: CGFloat = 300
    private static let compactGallery: PresentationDetent = .height(galleryHeight)

    private var loadingPhotos: Bool { selectedPhotos != completedSelection }
    private var galleryPhotos: [SupportDraftPhoto] { selectedPhotos.compactMap { loadedPhotos[$0] } }
    private var draftPhotos: [SupportDraftPhoto] { account.draftPhotos + galleryPhotos }
    private var canSend: Bool { !loadingPhotos && (account.canSend || !galleryPhotos.isEmpty) }
    private var selectionLimit: Int { max(1, Self.photoLimit - account.draftPhotos.count) }
    private var showsGalleryHeader: Bool { galleryDetent == .large || confirmingGallery }
    private var timestampOffset: CGFloat {
        guard case let .horizontal(offset) = timestampDrag else { return 0 }
        return offset
    }
    private var animatesTextSend: Bool {
        !reduceMotion && !showsGallery && canSend && draftPhotos.isEmpty && account.draftTopic == nil
    }

    var body: some View {
        chatContent
        .background { Color.black.ignoresSafeArea() }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .onChange(of: composerFocused) { _, focused in
            if focused && showsGallery { finishGallery() }
        }
        .task(id: selectedPhotos) {
            await loadSelection(selectedPhotos)
        }
        .sheet(isPresented: $showsGallery, onDismiss: galleryDismissed) { gallery }
        .fullScreenCover(isPresented: $showsCamera) {
            SupportCamera { photo in
                showsCamera = false
                if let photo { addCameraPhoto(photo) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $openedPhoto) { photo in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: photo.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Фото")
                }
                Button("Закрыть", systemImage: "xmark") { openedPhoto = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .padding(16)
            }
        }
        .alert("Вложение", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private var chatContent: some View {
        conversation
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    composer
                    Color.clear.frame(height: galleryInset)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(account.messages.enumerated()), id: \.element.id) { index, message in
                    let startsGroup = index == 0 || startsNewPeriod(message, after: account.messages[index - 1])
                    if startsGroup {
                        dateLabel(message.sentAt)
                    }
                    messageRows(message, joinsNext: joinsNext(at: index, message: message))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($historyPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        } action: { _, offset in
            if !historyPosition.isPositionedByUser { initialHistoryOffset = offset }
        }
        .task(id: initialHistoryOffset) {
            if initialHistoryOffset > 0 && !historyPosition.isPositionedByUser {
                historyPosition.scrollTo(y: initialHistoryOffset)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(DragGesture(minimumDistance: 8).updating($timestampDrag) { value, drag, transaction in
            if case .idle = drag {
                let horizontal = -value.translation.width > abs(value.translation.height) * 1.25
                drag = horizontal ? .horizontal(0) : .vertical
            }
            guard case .horizontal = drag else { return }
            let distance = max(0, -value.translation.width) * 0.85
            let overdrag = max(0, distance - Self.timestampWidth)
            transaction.animation = nil
            drag = .horizontal(min(distance, Self.timestampWidth) + 12 * overdrag / (overdrag + 42))
        })
        .overlay {
            if account.messages.isEmpty {
                ContentUnavailableView("Напишите в клуб", systemImage: "bubble.left.and.bubble.right")
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: account.messages.last?.id) { _, id in
            if id != nil {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    historyPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .accessibilityIdentifier("support.history")
    }

    private func startsNewPeriod(_ message: SupportMessage, after previous: SupportMessage) -> Bool {
        message.sentAt.timeIntervalSince(previous.sentAt) >= 60 * 60 ||
            !SubscriptionPricing.calendar.isDate(message.sentAt, inSameDayAs: previous.sentAt)
    }

    private func joinsNext(at index: Int, message: SupportMessage) -> Bool {
        guard account.messages.indices.contains(index + 1) else { return false }
        let next = account.messages[index + 1]
        return next.fromPlayer == message.fromPlayer && !startsNewPeriod(next, after: message)
    }

    private func dateLabel(_ date: Date) -> some View {
        let calendar = SubscriptionPricing.calendar
        let label: Text
        if calendar.isDateInToday(date) {
            label = Text("Сегодня")
        } else if calendar.isDateInYesterday(date) {
            label = Text("Вчера")
        } else if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            label = Text(date.formatted(HomeView.dateFormat.day().month(.wide)))
        } else {
            label = Text(date.formatted(HomeView.dateFormat.day().month(.wide).year()))
        }

        let time = date.formatted(HomeView.dateFormat.hour().minute())
        return Text("\(label) \(time)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private func messageRows(_ message: SupportMessage, joinsNext: Bool) -> some View {
        let time = message.sentAt.formatted(HomeView.dateFormat.hour().minute())
        let hasText = !message.text.isEmpty || message.topic != nil
        let photos = message.photos ?? []

        ForEach(photos) { photo in
            let endsMessage = !hasText && photo.id == photos.last?.id
            positionedBubble(fromPlayer: message.fromPlayer, time: endsMessage ? time : nil) {
                Button { openedPhoto = photo } label: {
                    SupportMessagePhotoView(photo: photo)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Фото")
                .accessibilityValue(time)
                .accessibilityIdentifier("support.messagePhoto")
            }
            .padding(.bottom, endsMessage && !joinsNext ? 12 : 4)
        }

        if hasText {
            positionedBubble(fromPlayer: message.fromPlayer, time: time) {
                textBubble(message, time: time, hasTail: !joinsNext)
                    .matchedGeometryEffect(id: message.id, in: sendMotion)
            }
            .padding(.bottom, joinsNext ? 4 : 12)
        }
    }

    private func positionedBubble<Content: View>(fromPlayer: Bool, time: String?, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(fromPlayer ? .leading : .trailing, dynamicTypeSize.isAccessibilitySize ? 20 : 52)
            .frame(maxWidth: .infinity, alignment: fromPlayer ? .trailing : .leading)
            .offset(x: -timestampOffset * (fromPlayer ? 1 : 0.55))
            .overlay(alignment: .trailing) {
                if let time {
                    Text(time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .offset(x: max(0, Self.timestampWidth - timestampOffset))
                        .opacity(min(1, timestampOffset / Self.timestampWidth))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private func textBubble(_ message: SupportMessage, time: String, hasTail: Bool) -> some View {
        let fill = message.fromPlayer ? Color(white: 0.92) : Color(white: 0.14)
        return VStack(alignment: .leading, spacing: 5) {
            if let topic = message.topic { topicLabel(topic) }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minWidth: 44, alignment: .leading)
        .foregroundStyle(message.fromPlayer ? Color.black : .white)
        .background(fill, in: SupportBubbleShape(pointsRight: message.fromPlayer, hasTail: hasTail))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.fromPlayer ? "Вы" : "Клуб")
        .accessibilityValue(message.topic.map { "\($0.title), \($0.detail). \(message.text), \(time)" }
                            ?? "\(message.text), \(time)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let topic = account.draftTopic {
                HStack(spacing: 8) {
                    topicLabel(topic)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Убрать тему", systemImage: "xmark") {
                        account.draftTopic = nil
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier("support.removeTopic")
                }
                .padding(.leading, 12)
                .background(.white.opacity(0.09), in: .rect(cornerRadius: 14))
            }

            if !draftPhotos.isEmpty || loadingPhotos {
                photoDraftStrip
            }

            HStack(alignment: .bottom, spacing: 6) {
                attachmentMenu
                messageField
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var attachmentMenu: some View {
        Menu {
            Button("Камера", systemImage: "camera") {
                Task { await openCamera() }
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Фото", systemImage: "photo.on.rectangle") {
                composerFocused = false
                if showsGallery {
                    finishGallery()
                } else {
                    showsGallery = true
                }
            }
        } label: {
            Label("Добавить вложение", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .menuOrder(.fixed)
        .disabled(draftPhotos.count >= Self.photoLimit)
        .accessibilityIdentifier("support.attach")
    }

    private var messageField: some View {
        TextField("Сообщение", text: $account.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($composerFocused)
            .lineLimit(1...4)
            .padding(.leading, 16)
            .padding(.trailing, 48)
            .padding(.vertical, 10)
            .frame(minHeight: 46)
            .glassEffect(.clear, in: .rect(cornerRadius: 23))
            .accessibilityIdentifier("support.composer")
            .background {
                if animatesTextSend {
                    Color.clear
                        .matchedGeometryEffect(id: draftMotionID, in: sendMotion)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if canSend {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(width: 36, height: 30)
                                .background(.white, in: .capsule)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Отправить")
                        .accessibilityIdentifier("support.send")
                        .transition(reduceMotion ? .identity : .scale(scale: 0.65).combined(with: .opacity))
                    }
                }
                .padding(1)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: canSend)
            }
    }

    private var photoDraftStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draftPhotos) { photo in
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 68, height: 68)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button { removeDraftPhoto(photo.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.75), in: .circle)
                                    .frame(width: 44, height: 44, alignment: .topTrailing)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Удалить фото")
                            .accessibilityIdentifier("support.removePhoto")
                            .padding(3)
                        }
                }
                if loadingPhotos {
                    ProgressView()
                        .frame(width: 60, height: 68)
                        .accessibilityLabel("Загрузка фото")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var gallery: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 22)
                .contentShape(.rect)
                .accessibilityElement()
                .accessibilityLabel("Размер галереи")
                .accessibilityAction(named: galleryDetent == .large ? "Свернуть" : "Развернуть") {
                    galleryDetent = galleryDetent == .large ? Self.compactGallery : .large
                }
                .accessibilityIdentifier("support.galleryHandle")

            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: selectionLimit,
                         selectionBehavior: .continuousAndOrdered, matching: .images, preferredItemEncoding: .current) {
                EmptyView()
            }
            .photosPickerStyle(.inline)
            .photosPickerAccessoryVisibility(showsGalleryHeader ? .visible : .hidden)
            .photosPickerDisabledCapabilities(.selectionActions)
        }
        .overlay(alignment: .topTrailing) {
            if galleryDetent == .large && !confirmingGallery {
                Button("Подтвердить выбор", systemImage: "checkmark", action: confirmGallery)
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .foregroundStyle(.black)
                .padding(.top, 114)
                .padding(.trailing, 18)
                .accessibilityIdentifier("support.galleryConfirm")
            }
        }
        .background {
            GalleryPositionObserver { visibleHeight in
                let inset = min(Self.galleryHeight, visibleHeight)
                if abs(inset - galleryInset) >= 0.5 { galleryInset = inset }
                if confirmingGallery && visibleHeight <= Self.galleryHeight + 6 {
                    confirmingGallery = false
                }
            }
            .allowsHitTesting(false)
        }
        .presentationDetents([Self.compactGallery, .large], selection: $galleryDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.resizes)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.compactGallery))
    }

    private func confirmGallery() {
        guard galleryDetent == .large, !confirmingGallery else { return }
        if reduceMotion {
            galleryDetent = Self.compactGallery
            return
        }

        confirmingGallery = true
        galleryDetent = Self.compactGallery
    }

    private func galleryDismissed() {
        galleryDetent = Self.compactGallery
        galleryInset = 0
        confirmingGallery = false
        if !loadingPhotos { commitGallerySelection() }
        if opensCameraAfterGallery {
            opensCameraAfterGallery = false
            showsCamera = true
        }
    }

    private func finishGallery() {
        showsGallery = false
        if !loadingPhotos { commitGallerySelection() }
    }

    private func commitGallerySelection() {
        account.draftPhotos += galleryPhotos
        selectedPhotos = []
        loadedPhotos = [:]
        completedSelection = []
    }

    private func loadSelection(_ selection: [PhotosPickerItem]) async {
        var photos: [PhotosPickerItem: SupportDraftPhoto] = [:]
        for item in selection {
            if let cached = loadedPhotos[item] {
                photos[item] = cached
            } else if let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled {
                photos[item] = SupportDraftPhoto(data: data)
            }
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled, selection == selectedPhotos else { return }
        loadedPhotos = photos
        completedSelection = selection
        if !showsGallery { commitGallerySelection() }
        if photos.count != selection.count {
            attachmentError = "Не удалось открыть фото. Попробуйте выбрать его ещё раз."
        }
    }

    private func removeDraftPhoto(_ id: UUID) {
        if let item = selectedPhotos.first(where: { loadedPhotos[$0]?.id == id }) {
            selectedPhotos.removeAll { $0 == item }
        } else {
            account.draftPhotos.removeAll { $0.id == id }
        }
    }

    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : status == .authorized
        guard allowed else {
            attachmentError = "Разрешите доступ к камере для Tennis ID в настройках iPhone."
            return
        }
        composerFocused = false
        if showsGallery {
            opensCameraAfterGallery = true
            finishGallery()
        } else {
            showsCamera = true
        }
    }

    private func addCameraPhoto(_ image: UIImage) {
        guard draftPhotos.count < Self.photoLimit else { return }
        if let data = image.jpegData(compressionQuality: 0.90), let photo = SupportDraftPhoto(data: data) {
            account.draftPhotos.append(photo)
        } else {
            attachmentError = "Не удалось добавить снимок."
        }
    }

    private func send() {
        guard canSend else { return }
        let animateText = animatesTextSend
        if showsGallery { finishGallery() }
        do {
            if animateText {
                try withAnimation(.smooth(duration: 0.34)) {
                    try account.send(messageID: draftMotionID, delaysReply: true)
                    draftMotionID = UUID()
                }
            } else {
                try account.send()
            }
        } catch {
            attachmentError = "Не удалось сохранить фото. Попробуйте отправить сообщение ещё раз."
        }
    }

    private func topicLabel(_ topic: SupportTopic) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title).font(.caption.weight(.semibold))
                Text(topic.detail).font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: topic.symbol)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct GalleryPositionObserver: UIViewRepresentable {
    let onPositionChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onPositionChange: ((CGFloat) -> Void)?
        private weak var view: UIView?
        private var displayLink: CADisplayLink?
        private var lastHeight: CGFloat?

        func observe(_ view: UIView) {
            self.view = view
            let link = CADisplayLink(target: self, selector: #selector(readPosition))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func readPosition() {
            guard let view, let window = view.window, view.bounds.height > 0 else { return }
            // The presentation layer follows the sheet during a swipe and while it settles.
            let layer = view.layer.presentation() ?? view.layer
            let windowLayer = window.layer.presentation() ?? window.layer
            let top = layer.convert(layer.bounds.origin, to: windowLayer).y
            let height = max(0, window.bounds.maxY - window.safeAreaInsets.bottom - top)
            if let lastHeight, abs(lastHeight - height) < 0.5 { return }
            lastHeight = height
            onPositionChange?(height)
        }
    }
}

nonisolated private struct SupportBubbleShape: Shape {
    let pointsRight: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(20, rect.width / 2, rect.height / 2)
        guard hasTail, rect.width >= 40, rect.height >= 34 else {
            return RoundedRectangle(cornerRadius: radius).path(in: rect)
        }
        let w = rect.width
        let h = rect.height
        let roundCorner = radius * 0.55
        let outline = Path { path in
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: w - radius, y: 0))
            path.addCurve(to: CGPoint(x: w, y: radius),
                          control1: CGPoint(x: w - radius + roundCorner, y: 0),
                          control2: CGPoint(x: w, y: radius - roundCorner))
            path.addLine(to: CGPoint(x: w, y: h - radius))
            path.addCurve(to: CGPoint(x: w - 10, y: h - 5),
                          control1: CGPoint(x: w, y: h - 10),
                          control2: CGPoint(x: w - 5, y: h - 8))
            path.addQuadCurve(to: CGPoint(x: w - 9, y: h + 4),
                              control: CGPoint(x: w - 13, y: h - 1))
            path.addQuadCurve(to: CGPoint(x: w - 11, y: h + 5),
                              control: CGPoint(x: w - 8, y: h + 6))
            path.addQuadCurve(to: CGPoint(x: w - 22, y: h),
                              control: CGPoint(x: w - 15, y: h + 4))
            path.addLine(to: CGPoint(x: radius, y: h))
            path.addCurve(to: CGPoint(x: 0, y: h - radius),
                          control1: CGPoint(x: radius - roundCorner, y: h),
                          control2: CGPoint(x: 0, y: h - radius + roundCorner))
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addCurve(to: CGPoint(x: radius, y: 0),
                          control1: CGPoint(x: 0, y: radius - roundCorner),
                          control2: CGPoint(x: radius - roundCorner, y: 0))
            path.closeSubpath()
        }
        let direction = pointsRight ? CGAffineTransform.identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        return outline.applying(direction.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct SupportMessagePhotoView: View {
    let photo: SupportPhoto
    @State private var image: UIImage?
    @State private var isVisible = false

    var body: some View {
        let width = min(244, 280 * photo.aspectRatio)
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Color(white: 0.14)
                    .overlay {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: width, height: width / photo.aspectRatio)
        .clipShape(.rect(cornerRadius: 20))
        .onScrollVisibilityChange(threshold: 0.04) { isVisible = $0 }
        .task(id: isVisible) {
            guard isVisible, let data = try? Data(contentsOf: photo.url) else {
                image = nil
                return
            }
            image = PlayerPhoto.thumbnail(from: data, maxPixelSize: 900)
        }
    }
}

private struct SupportCamera: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
