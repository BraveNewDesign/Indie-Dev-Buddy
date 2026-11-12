import Quartz
import SwiftUI

extension View {
    func assetQuickLook(_ url: Binding<URL?>) -> some View {
        sheet(isPresented: Binding(get: { url.wrappedValue != nil }, set: { if !$0 { url.wrappedValue = nil } })) {
            if let file = url.wrappedValue {
                VStack(alignment: .trailing, spacing: 0) {
                    QuickLookFileView(url: file)
                    Button("Done") { url.wrappedValue = nil }
                        .keyboardShortcut(.cancelAction)
                        .padding()
                }
                .frame(minWidth: 500, idealWidth: 760, minHeight: 360, idealHeight: 600)
            }
        }
    }
}

private struct QuickLookFileView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        preview.autostarts = true
        preview.previewItem = url as NSURL
        return preview
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = view as? QLPreviewView else { return }
        preview.previewItem = url as NSURL
    }
}
