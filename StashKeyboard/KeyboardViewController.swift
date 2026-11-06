import UIKit
import StashCore
import UniformTypeIdentifiers

@MainActor final class KeyboardViewController:UIInputViewController {
    private var store:LibraryStore?
    private let root = UIStackView()
    private let lists = UIButton(type:.system)
    private let scroll = UIScrollView()
    private let items = UIStackView()
    private let status = UILabel()
    private var selectedBoardID:UUID?
    private var page=0
    private let previousPageButton=UIButton(type:.system)
    private let nextPageButton=UIButton(type:.system)
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        root.axis = .vertical; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),root.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),root.topAnchor.constraint(equalTo:view.topAnchor,constant:10),root.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-8),view.heightAnchor.constraint(greaterThanOrEqualToConstant:240)])
        let toolbar = UIStackView(); toolbar.spacing = 10
        let globe = UIButton(type:.system); globe.setImage(UIImage(systemName:"globe"),for:.normal); globe.addTarget(self,action:#selector(handleInputModeList(from:with:)),for:.allTouchEvents); globe.isHidden = !needsInputModeSwitchKey
        let space = UIButton(type:.system); space.setTitle("Space",for:.normal); space.addTarget(self,action:#selector(insertSpace),for:.touchUpInside)
        let delete = UIButton(type:.system); delete.setImage(UIImage(systemName:"delete.left"),for:.normal); delete.addTarget(self,action:#selector(backspace),for:.touchUpInside)
        let done = UIButton(type:.system); done.setTitle("Return",for:.normal); done.addTarget(self,action:#selector(insertReturn),for:.touchUpInside)
        toolbar.addArrangedSubview(globe); toolbar.addArrangedSubview(space); toolbar.addArrangedSubview(delete); toolbar.addArrangedSubview(done)
        previousPageButton.setTitle("‹",for:.normal);previousPageButton.addTarget(self,action:#selector(previousPage),for:.touchUpInside);nextPageButton.setTitle("›",for:.normal);nextPageButton.addTarget(self,action:#selector(nextPage),for:.touchUpInside);toolbar.addArrangedSubview(previousPageButton);toolbar.addArrangedSubview(nextPageButton)
        lists.showsMenuAsPrimaryAction=true;lists.contentHorizontalAlignment = .leading;root.addArrangedSubview(lists)
        items.axis = .horizontal; items.spacing = 10; items.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(items); scroll.showsHorizontalScrollIndicator = false
        NSLayoutConstraint.activate([items.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),items.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),items.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),items.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),items.heightAnchor.constraint(equalTo:scroll.frameLayoutGuide.heightAnchor)])
        root.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive = true
        status.font = .preferredFont(forTextStyle:.caption1); status.numberOfLines = 2; root.addArrangedSubview(status)
        let pasteTarget = KeyboardPasteTarget(); pasteTarget.onItems = { [weak self] values in guard let self,let store = self.store else { return }; do { for item in values {try store.add(item)}; self.refreshItems() } catch { self.status.text = error.localizedDescription } }; pasteTarget.heightAnchor.constraint(equalToConstant:35).isActive = true; root.addArrangedSubview(pasteTarget)
        root.addArrangedSubview(toolbar); refresh()
    }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated); refresh() }
    override func textDidChange(_ textInput:(any UITextInput)?) { super.textDidChange(textInput) }
    private func refresh() {
        guard hasFullAccess else { status.text = "Allow Full Access in keyboard settings to read your on-device Stash library. Nothing is sent to a server."; return }
        do { if store == nil { store = try LibraryStore() }; try store?.reload(); var actions:[UIAction]=[UIAction(title:"Recent") {[weak self] _ in self?.chooseBoard(nil,name:"Recent")}]
            for board in store?.pinboards ?? [] {actions.append(UIAction(title:board.name) {[weak self] _ in self?.chooseBoard(board.id,name:board.name)})}
            lists.menu=UIMenu(children:actions);chooseBoard(nil,name:"Recent") } catch { status.text = error.localizedDescription }
    }
    @objc private func refreshItems() {
        for view in items.arrangedSubviews { items.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let store else {return};let all=store.results(boardID:selectedBoardID)
        page=min(page,max(0,(all.count-1)/40));previousPageButton.isEnabled=page>0;nextPageButton.isEnabled=(page+1)*40<all.count
        for item in all.dropFirst(page*40).prefix(40) {
            let button = UIButton(type:.system); var config = UIButton.Configuration.filled(); config.baseBackgroundColor = .tertiarySystemFill; config.baseForegroundColor = .label; config.title = String((item.text.isEmpty ? item.displayTitle : item.text).prefix(120)); config.subtitle = item.kind.label; config.image = UIImage(systemName:item.kind.symbol); config.imagePlacement = .top; config.imagePadding = 8; config.cornerStyle = .medium; button.configuration = config; button.titleLabel?.numberOfLines = 4; button.widthAnchor.constraint(equalToConstant:150).isActive = true
            button.addAction(UIAction { [weak self] _ in guard let self else {return}; if item.kind == .file,let full=try? store.materialized(item),let data=full.data {UIPasteboard.general.items=[[full.fileTypeIdentifier ?? UTType.data.identifier:data]];self.status.text="File copied. Use Paste in your app."} else if item.kind == .image { if let full = try? store.materialized(item),let data = full.data,let image = UIImage(data:data) { UIPasteboard.general.image = image; self.status.text = "Image copied. Use Paste in your app to insert it." } } else { self.textDocumentProxy.insertText(item.text); self.status.text = "Inserted" } },for:.touchUpInside); items.addArrangedSubview(button)
        }
        status.text = "Tap an item to insert. Use Paste below to save your clipboard."
    }
    private func chooseBoard(_ id:UUID?,name:String) {selectedBoardID=id;page=0;lists.setTitle(name+" ▾",for:.normal);refreshItems()}
    @objc private func previousPage() {page=max(0,page-1);refreshItems()}
    @objc private func nextPage() {page+=1;refreshItems()}
    @objc private func insertSpace() {textDocumentProxy.insertText(" ")}
    @objc private func backspace() {textDocumentProxy.deleteBackward()}
    @objc private func insertReturn() {textDocumentProxy.insertText("\n")}
}
final class KeyboardPasteTarget:UIView {
    var onItems:(([ClipItem]) -> Void)?
    override init(frame:CGRect) { super.init(frame:frame); pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers:[UTType.plainText.identifier,UTType.url.identifier,UTType.image.identifier]); let paste = UIPasteControl(); paste.target = self; paste.translatesAutoresizingMaskIntoConstraints = false; addSubview(paste); NSLayoutConstraint.activate([paste.leadingAnchor.constraint(equalTo:leadingAnchor),paste.topAnchor.constraint(equalTo:topAnchor),paste.bottomAnchor.constraint(equalTo:bottomAnchor)]) }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func paste(itemProviders:[NSItemProvider]) { Task { onItems?(await ProviderImport.items(from:itemProviders,source:"Stash Keyboard")) } }
}
