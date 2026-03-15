import SwiftUI
import BuchstabenNative

struct ContentView: View {
    @EnvironmentObject private var vm: TracingViewModel

    var body: some View {
        BuchstabenNative.ContentView()
    }
}
