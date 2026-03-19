import SwiftUI
import BuchstabenNative

struct ContentView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        BuchstabenNative.ContentView()
    }
}
