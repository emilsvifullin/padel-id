import SwiftUI

@main
struct PadelIDApp: App {
    #if !TENNIS_PREVIEW
    @State private var auth = TennisAuth()
    #endif

    init() { Theme.applyNavigationTypography() }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    #if TENNIS_PREVIEW
                    TennisPreviewView(scenario: TennisPreviewView.launchScenario ?? .account())
                    #elseif DEBUG && targetEnvironment(simulator)
                    if let preview = TennisPreviewView.launchScenario {
                        TennisPreviewView(scenario: preview)
                    } else {
                        liveContent
                    }
                    #else
                    liveContent
                    #endif
                }
                .background { Color.black.ignoresSafeArea() }
                .toolbar(.hidden, for: .navigationBar)
            }
            .tint(Theme.accent)
            .headerProminence(.increased)
            .padelTypesetting()
        }
    }

    #if !TENNIS_PREVIEW
    private var liveContent: some View {
        TennisEntryView { userID in
            SignedInTennisView(userID: userID)
        }
        .environment(auth)
        .task { await auth.observeSession() }
        .onOpenURL { url in Task { await auth.open(url) } }
        .alert("Tennis ID", isPresented: Binding(
            get: { auth.notice != nil },
            set: { if !$0 { auth.notice = nil } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(auth.notice ?? "")
        }
    }
    #endif
}

private struct SignedInTennisView: View {
    @Environment(TennisAuth.self) private var auth
    @AppStorage private var history: TrainingHistory?
    @AppStorage private var assessment: AssessmentRole?

    init(userID: UUID) {
        _history = AppStorage("tennis-training-history-\(userID.uuidString)")
        _assessment = AppStorage("tennis-assessment-\(userID.uuidString)")
    }

    var body: some View {
        if auth.hasPlayerName {
            MatchPointView(history: $history, assessment: $assessment) {
                Task { await auth.signOut() }
            }
        } else {
            CompletePlayerNameView()
        }
    }
}
