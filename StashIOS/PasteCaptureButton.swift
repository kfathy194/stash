import SwiftUI
import StashCore
import UniformTypeIdentifiers

final class PasteTargetView:UIView {
    var onItems:(([ClipItem]) -> Void)?
    override init(frame:CGRect) {
        super.init(frame:frame); pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers:[UTType.plainText.identifier,UTType.url.identifier,UTType.image.identifier,UTType.rtf.identifier,UTType.fileURL.identifier])
        let control = UIPasteControl(configuration:UIPasteControl.Configuration()); control.target = self; control.translatesAutoresizingMaskIntoConstraints = false; addSubview(control)
        NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo:leadingAnchor),control.topAnchor.constraint(equalTo:topAnchor),control.bottomAnchor.constraint(equalTo:bottomAnchor)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func paste(itemProviders:[NSItemProvider]) { Task { let items = await ProviderImport.items(from:itemProviders,source:"Clipboard"); onItems?(items) } }
}
struct PasteCaptureButton:UIViewRepresentable {
    var onItems:([ClipItem]) -> Void
    func makeUIView(context:Context) -> PasteTargetView { let view = PasteTargetView(); view.onItems = onItems; return view }
    func updateUIView(_ uiView:PasteTargetView,context:Context) { uiView.onItems = onItems }
}
