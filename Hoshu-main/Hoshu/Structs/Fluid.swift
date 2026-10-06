import FluidGradient
import SwiftUI

struct Fluid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            FluidGradient(
                blobs: [.gray],
                highlights: [.black],
                speed: 0.25,
                blur: 0.75
            ).background(.black)
                .ignoresSafeArea()
                .overlay(
                    content()
                )
        }
    }
}
