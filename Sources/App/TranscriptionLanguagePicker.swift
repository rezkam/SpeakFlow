import SwiftUI
import SpeakFlowCore

struct TranscriptionLanguagePicker: View {
    let providerId: String
    @Binding var deepgramLanguage: String
    @Binding var mistralLanguage: String

    var body: some View {
        switch providerId {
        case ProviderId.deepgram:
            Picker("", selection: $deepgramLanguage) {
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Portuguese").tag("pt")
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese").tag("zh")
            }
            .labelsHidden()
            .fixedSize()
        case ProviderId.mistralBatch:
            Picker("", selection: $mistralLanguage) {
                Text("Auto-detect").tag("")
                Divider()
                Text("English").tag("en")
                Text("French").tag("fr")
                Text("German").tag("de")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Dutch").tag("nl")
                Text("Hindi").tag("hi")
                Text("Arabic").tag("ar")
                Divider()
                Text("Japanese").tag("ja")
                Text("Korean").tag("ko")
                Text("Chinese").tag("zh")
                Text("Russian").tag("ru")
            }
            .labelsHidden()
            .fixedSize()
        default:
            Text("Auto-detect")
                .foregroundStyle(Theme.text3)
                .font(.system(size: 12.5))
        }
    }
}
