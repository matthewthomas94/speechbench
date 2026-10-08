import SwiftUI

/// Static replica of the payments app's home screen. Nothing on it does anything.
struct HomeView: View {
    static let background = Color(hex: 0xF3F5FE)
    private static let ink = Color(hex: 0x213F49)
    private static let inkSoft = Color(hex: 0x335059)
    private static let grey = Color(hex: 0x7D939A)
    private static let blue = Color(hex: 0x2567B5)
    private static let paleBlue = Color(hex: 0xD0DEF7)
    private static let palerBlue = Color(hex: 0xECF1FD)
    private static let red = Color(hex: 0xE11D3D)

    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                header
                pointsCard
                tiles
                VStack(spacing: 16) {
                    sectionHeader("Payments to authorise")
                    Text("You have no payments to authorise.")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: 0x7091B2))
                        .frame(maxWidth: .infinity, minHeight: 67)
                        .background(Self.palerBlue, in: RoundedRectangle(cornerRadius: 12))
                }
                upcomingCard
                VStack(spacing: 16) {
                    sectionHeader("Transactions")
                    transactionCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Self.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("H")
                .font(.system(size: 22))
                .foregroundStyle(Color(hex: 0x003D84))
                .frame(width: 40, height: 40)
                .background(Self.paleBlue, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("HIDPRESS PTY LTD")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("Matthew Thomas")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.inkSoft)
            }
            Spacer()
            Image(systemName: "person.fill")
                .font(.system(size: 18))
                .foregroundStyle(Self.blue)
                .frame(width: 40, height: 40)
                .background(Color(hex: 0xE1E8FA), in: Circle())
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Self.red).frame(width: 9, height: 9).offset(x: 1, y: -1)
                }
        }
    }

    private var pointsCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("500,000")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("PayRewards Points")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.inkSoft)
            }
            Spacer()
            ZStack {
                coin.offset(x: -10, y: -6)
                coin.offset(x: 10, y: 6)
            }
            .frame(width: 60, height: 50)
        }
        .padding(.horizontal, 20)
        .frame(height: 90)
        .background(Self.paleBlue, in: RoundedRectangle(cornerRadius: 16))
    }

    private var coin: some View {
        Circle()
            .fill(Color(hex: 0x006EE2))
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5).padding(3))
            .overlay(Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.white))
            .frame(width: 36, height: 36)
    }

    private var tiles: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("$0")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Self.ink)
                Text("Total spending\nthis month")
                    .font(.system(size: 14))
                    .foregroundStyle(Self.grey)
                Spacer()
                chevronCircle(fill: Self.palerBlue, arrow: Self.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .tile(background: Color.white)

            VStack(alignment: .leading) {
                Text("Make a\npayment")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                chevronCircle(fill: Color(hex: 0x4D80D0), arrow: .white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .tile(
                background: LinearGradient(
                    colors: [Color(hex: 0x2B4391), Color(hex: 0x1268CE)], startPoint: .topLeading,
                    endPoint: .bottomTrailing))
        }
        .frame(height: 182)
    }

    private func chevronCircle(fill: Color, arrow: Color) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(arrow)
            .frame(width: 32, height: 32)
            .background(fill, in: Circle())
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Self.ink)
            Spacer()
            Text("See all")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Self.blue)
        }
    }

    private var upcomingCard: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Color(hex: 0x1E88E5).frame(height: 9)
                Color.white
            }
            .frame(width: 30, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            .rotationEffect(.degrees(-8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming payments")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Self.ink)
                Text("Scheduled: $0.00")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.inkSoft)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Self.blue)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(Self.paleBlue, in: RoundedRectangle(cornerRadius: 16))
    }

    private var transactionCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bunnings").foregroundStyle(Self.ink)
                Text("23 Mar, 6 months ago").foregroundStyle(Color(hex: 0x4A6A74))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("$241.26").foregroundStyle(Self.ink)
                Text("Cancelled").foregroundStyle(Self.red)
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .frame(height: 78)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension View {
    func tile(background: some ShapeStyle) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: 20))
    }
}
