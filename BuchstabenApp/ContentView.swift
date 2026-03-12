import SwiftUI
import BuchstabenNative

struct ContentView: View {
    // 1. Create the ViewModel that the package expects
    @StateObject private var viewModel = TracingViewModel()

    var body: some View {
        // 2. Call the view and attach the ViewModel to its environment
        BuchstabenNative.ContentView()
            .environmentObject(viewModel)
    }
}
