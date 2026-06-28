import SwiftUI

struct CuteRecordLogoView: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        Image("CuteRecordLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
    }
}
