import SwiftUI

struct LearnfoldIntroView: View {
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let indigo = Color(red: 0.294, green: 0.235, blue: 0.941)
    private let deepIndigo = Color(red: 0.122, green: 0.102, blue: 0.420)
    private let chartreuse = Color(red: 0.843, green: 1.000, blue: 0.271)
    private let paper = Color(red: 1.000, green: 0.976, blue: 0.910)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [indigo, deepIndigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            decorativeGlow

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    brandHeader
                    valueStatement
                    featureList
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 144)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            continuePanel
        }
        .preferredColorScheme(.dark)
    }

    private var decorativeGlow: some View {
        GeometryReader { geometry in
            Circle()
                .fill(chartreuse.opacity(0.16))
                .frame(width: geometry.size.width * 1.15)
                .blur(radius: 76)
                .offset(
                    x: geometry.size.width * 0.44,
                    y: geometry.size.height * 0.52
                )
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var brandHeader: some View {
        HStack(spacing: 14) {
            Group {
                if reduceMotion {
                    Image("brand_logo")
                        .resizable()
                        .scaledToFit()
                } else {
                    AnimatedLogo(size: 62)
                }
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text("Learnfold")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(paper)

                Text("Your personal learning studio")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(paper.opacity(0.68))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Learnfold. Your personal learning studio.")
    }

    private var valueStatement: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn anything\ninto a course.")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .tracking(-1.5)
                .foregroundStyle(paper)
                .minimumScaleFactor(0.72)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("learnfold-intro-title")

            Text("Bring a topic, document, or link. Learnfold shapes it into a course you can explore, question, and build on.")
                .font(.title3)
                .foregroundStyle(paper.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 38)
    }

    private var featureList: some View {
        VStack(spacing: 12) {
            IntroFeatureRow(
                icon: "sparkles.rectangle.stack.fill",
                title: "Start with anything",
                detail: "A question, a file, a link, or an idea.",
                tint: chartreuse,
                paper: paper
            )
            IntroFeatureRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Learn through conversation",
                detail: "Ask follow-ups and shape the path as you go.",
                tint: chartreuse,
                paper: paper
            )
            IntroFeatureRow(
                icon: "book.pages.fill",
                title: "Keep a living course",
                detail: "Your lessons, notes, and progress stay together.",
                tint: chartreuse,
                paper: paper
            )
        }
        .padding(.top, 34)
    }

    private var continuePanel: some View {
        VStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                Label("Choose your private course agent next", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(paper.opacity(0.72))
            }

            continueButton
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var continueButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: onContinue) {
                continueButtonLabel
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.roundedRectangle(radius: 22))
            .tint(chartreuse)
            .accessibilityIdentifier("learnfold-intro-continue")
            .accessibilityHint("Choose your private course agent next")
        } else {
            Button(action: onContinue) {
                continueButtonLabel
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.2))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("learnfold-intro-continue")
            .accessibilityHint("Choose your private course agent next")
        }
    }

    private var continueButtonLabel: some View {
        HStack(spacing: 10) {
            Text("Start learning")
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "arrow.right")
            }
        }
        .font(.headline)
        .foregroundStyle(deepIndigo)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 58)
    }
}

private struct IntroFeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let paper: Color

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(paper)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(paper.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.09))
        }
        .accessibilityElement(children: .combine)
    }
}
