import SwiftUI
import BuchstabenNative

struct ContentView: View {
    @StateObject private var viewModel = TracingViewModel()

    var body: some View {
        BuchstabenNative.ContentView()
            .environmentObject(viewModel)
    }
}
