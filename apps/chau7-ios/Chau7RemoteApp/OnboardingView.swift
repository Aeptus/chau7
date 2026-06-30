import SwiftUI

/// First-run onboarding. Explains what the app does and that it needs a Mac
/// running Chau7, then routes the user into pairing. Shown once, gated by the
/// `hasCompletedOnboarding` AppStorage flag.
struct OnboardingView: View {
    /// Called when the user finishes onboarding. `startPairing` is true when the
    /// user chose to pair immediately.
    let onFinish: (_ startPairing: Bool) -> Void

    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "macbook.and.iphone",
            title: "Steer from your phone",
            message: "Chau7 Remote connects to Chau7 on your Mac so you can watch your AI coding sessions and respond from anywhere."
        ),
        OnboardingPage(
            systemImage: "lock.shield",
            title: "Approve on the go",
            message: "When an agent needs permission to run something, you get a notification and can allow or deny it in a tap — even from the Lock Screen."
        ),
        OnboardingPage(
            systemImage: "bolt.horizontal.circle",
            title: "Private and direct",
            message: "Everything is end-to-end encrypted between this phone and your Mac. No account required — you just pair the two devices."
        )
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.08),
                    Color(red: 0.08, green: 0.10, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish(false) }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        OnboardingPageView(page: item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 12) {
                    if page < pages.count - 1 {
                        Button {
                            withAnimation { page += 1 }
                        } label: {
                            Text("Next")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button {
                            onFinish(true)
                        } label: {
                            Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("I'll pair later") { onFinish(false) }
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: page.systemImage)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Color(red: 0.56, green: 0.82, blue: 0.92))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
