import SwiftUI

// MARK: - Onboarding pages

private enum OnboardingPage: Int, CaseIterable {
    case welcome, safety, warranty, beta

    var title: String {
        switch self {
        case .welcome:  return "Dynetra"
        case .safety:   return "Safety First"
        case .warranty: return "No Warranty"
        case .beta:     return "Developer Beta"
        }
    }

    var icon: String {
        switch self {
        case .welcome:  return "bolt.circle.fill"
        case .safety:   return "exclamationmark.triangle.fill"
        case .warranty: return "doc.text.fill"
        case .beta:     return "hammer.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .welcome:  return .cyan
        case .safety:   return .orange
        case .warranty: return .blue
        case .beta:     return .purple
        }
    }
}

// MARK: - Main onboarding view

struct OnboardingView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @State private var page: OnboardingPage = .welcome
    @State private var ackWarranty = false
    @State private var ackBeta = false
    @State private var slideIn = false

    private var isLastPage: Bool { page == .beta }
    private var canAccept: Bool { ackWarranty && ackBeta }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                pageIndicator
                    .padding(.top, 16)

                TabView(selection: $page) {
                    ForEach(OnboardingPage.allCases, id: \.self) { p in
                        pageContent(p)
                            .tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.35), value: page)

                bottomBar
                    .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { slideIn = true } }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [page.iconColor.opacity(0.18), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: page)
        }
    }

    // MARK: - Page indicator

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases, id: \.self) { p in
                Capsule()
                    .fill(p == page ? page.iconColor : Color.white.opacity(0.2))
                    .frame(width: p == page ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.35), value: page)
            }
        }
    }

    // MARK: - Page content

    @ViewBuilder
    private func pageContent(_ p: OnboardingPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Icon + title
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: p.icon)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(p.iconColor)
                        .shadow(color: p.iconColor.opacity(0.5), radius: 20)

                    if p == .welcome {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Dynetra")
                                .font(.system(size: 40, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text("BETA")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.cyan))
                        }
                    } else {
                        Text(p.title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }

                // Body
                Group {
                    switch p {
                    case .welcome:  welcomeBody
                    case .safety:   safetyBody
                    case .warranty: warrantyBody
                    case .beta:     betaBody
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Page bodies

    private var welcomeBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A full-featured VESC motor controller dashboard for iOS — live telemetry, motor configuration, and more, over Bluetooth. By DsSoft.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(4)

            Divider().overlay(Color.white.opacity(0.12))

            featureRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .cyan,
                       title: "Live Telemetry", body: "Real-time ERPM, speed, voltage, current, duty cycle, and temperatures.")
            featureRow(icon: "slider.horizontal.3", color: .blue,
                       title: "Motor Configuration", body: "FOC detection, current limits, battery cutoffs, and profiles.")
            featureRow(icon: "antenna.radiowaves.left.and.right", color: .purple,
                       title: "CAN Network", body: "Connect to and configure multiple VESCs over CAN bus.")
        }
    }

    private var safetyBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This app communicates directly with high-voltage motor controllers. Misconfiguration can result in:")
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(4)

            warningCard(items: [
                "Uncontrolled motor runaway or sudden acceleration",
                "Overheating, fire, or battery damage from incorrect current limits",
                "Physical injury if the motor is unsecured during testing",
                "Permanent damage to the ESC from incorrect FOC parameters",
            ])

            bulletItem(icon: "checkmark.shield.fill", color: .green,
                       text: "Always secure the motor and keep people clear before running detection or applying new settings.")
            bulletItem(icon: "checkmark.shield.fill", color: .green,
                       text: "Never rely on software limits alone — install appropriate physical safety measures.")
            bulletItem(icon: "checkmark.shield.fill", color: .green,
                       text: "VESC firmware is open-source and provided as-is. The firmware authors accept no liability for hardware damage or injury.")
        }
    }

    private var warrantyBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            legalBlock("""
THIS APPLICATION IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT.
""")

            Text("In no event shall the developer be liable for any claim, damages, or other liability — whether in an action of contract, tort, or otherwise — arising from, out of, or in connection with the software or the use or other dealings in the software.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.80))
                .lineSpacing(5)

            Divider().overlay(Color.white.opacity(0.12))

            Text("This includes, without limitation:")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            ForEach([
                "Loss or corruption of motor configuration data",
                "Hardware damage resulting from incorrect settings",
                "Personal injury arising from unexpected motor behaviour",
                "Data loss from app crashes or Bluetooth disconnections",
            ], id: \.self) { item in
                bulletItem(icon: "xmark.circle.fill", color: .red.opacity(0.8), text: item)
            }

            Text("VESC® is a trademark of Vedder Drives. This app is an independent third-party tool and is not affiliated with or endorsed by Vedder Drives or the VESC Project.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineSpacing(4)
                .padding(.top, 8)
        }
    }

    private var betaBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("You are running a developer sideload of Dynetra — a pre-release build distributed outside the App Store.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(4)

            warningCard(items: [
                "Bugs, crashes, and incomplete features are expected",
                "Settings written to your VESC may not be safe defaults",
                "This build will not receive automatic updates",
                "When an App Store or TestFlight build is published, delete this build and install the release version immediately",
            ])

            Divider().overlay(Color.white.opacity(0.12))

            Text("Acknowledgements")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .kerning(0.5)

            acknowledgementToggle(
                isOn: $ackWarranty,
                label: "I understand that this app and VESC firmware come with absolutely no warranty, and I accept all risks associated with using this software to configure motor controllers."
            )

            acknowledgementToggle(
                isOn: $ackBeta,
                label: "I understand this is a developer beta. I will abandon this build and install the official release as soon as it is published."
            )
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
                .padding(.bottom, 20)

            if isLastPage {
                Button(action: complete) {
                    Text("Accept & Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(canAccept ? page.iconColor : Color.white.opacity(0.1))
                        )
                        .foregroundStyle(canAccept ? .black : .white.opacity(0.3))
                }
                .disabled(!canAccept)
                .padding(.horizontal, 28)
                .animation(.easeInOut(duration: 0.2), value: canAccept)
            } else {
                Button(action: advance) {
                    HStack(spacing: 6) {
                        Text("Continue")
                            .font(.headline)
                        Image(systemName: "arrow.right")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(page.iconColor.opacity(0.85))
                    )
                    .foregroundStyle(.black)
                }
                .padding(.horizontal, 28)
            }
        }
    }

    // MARK: - Actions

    private func advance() {
        let all = OnboardingPage.allCases
        guard let idx = all.firstIndex(of: page), idx + 1 < all.count else { return }
        withAnimation { page = all[idx + 1] }
    }

    private func complete() {
        withAnimation(.easeInOut(duration: 0.3)) {
            onboardingComplete = true
        }
    }

    // MARK: - Sub-components

    private func featureRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(body).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineSpacing(3)
            }
        }
    }

    private func warningCard(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                        .padding(.top, 2)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(3)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.orange.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        )
    }

    private func bulletItem(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.subheadline)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(3)
        }
    }

    private func legalBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .lineSpacing(4)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            )
    }

    private func acknowledgementToggle(isOn: Binding<Bool>, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn.wrappedValue ? Color.purple : .white.opacity(0.4))
                    .animation(.spring(response: 0.25), value: isOn.wrappedValue)

                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isOn.wrappedValue ? Color.purple.opacity(0.12) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isOn.wrappedValue ? Color.purple.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .animation(.easeInOut(duration: 0.2), value: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
    }
}
