import SwiftUI
import AppKit
import StashCore

extension Color {
    init(hex: String) { let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x30B7A8; self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1) }
}

@MainActor enum SourceAppearance {
    static var cache: [String: (NSImage?, Color)] = [:]
    static func appearance(_ bundleID: String) -> (NSImage?, Color) {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        var tint = Color.teal
        if let cg = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            var bytes: [UInt8] = [0,0,0,0]
            bytes.withUnsafeMutableBytes { buffer in if let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { ctx.draw(cg, in: CGRect(x: 0,y: 0,width: 1,height: 1)) } }
            tint = Color(red: Double(bytes[0])/255, green: Double(bytes[1])/255, blue: Double(bytes[2])/255)
        }
        cache[bundleID] = (icon, tint); return (icon,tint)
    }
}

struct CardView: View {
    let item: ClipItem
    let number: Int?
    let selected: Bool
    let compact: Bool
    let query: String
    var richPreview: Data? = nil
    var body: some View {
        let appearance = SourceAppearance.appearance(item.sourceAppID)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if let icon = appearance.0 { Image(nsImage: icon).resizable().frame(width: 18, height: 18) } else { Image(systemName: item.kind.symbol).frame(width: 18) }
                Text(item.kind.label).fontWeight(.semibold); Spacer(); Text(item.createdAt, style: .relative).font(.system(size: 10)).lineLimit(1)
            }.font(.system(size: 12)).padding(12).background(appearance.1.opacity(0.18))
            ZStack(alignment: .topLeading) {
                if item.kind == .color { Color(hex: item.text).overlay { Text(item.text.uppercased()).font(.system(size: compact ? 24 : 32, weight: .medium, design: .monospaced)).foregroundStyle(contrastColor) } }
                else if item.kind == .image, let data = item.thumbnail, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().padding(8).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if item.kind == .file { VStack(spacing: 8) { Image(systemName: "doc.fill").font(.system(size: compact ? 32 : 52)).foregroundStyle(appearance.1); Text(item.displayTitle).lineLimit(2).fontWeight(.medium) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding() }
                else if item.kind == .link { VStack(alignment: .leading, spacing: 8) { if !compact, let data = item.thumbnail, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill().frame(height: 60).clipped() }; highlighted(item.linkTitle ?? item.text).font(.system(size: 15, weight: .medium)).lineLimit(3); Text(item.linkDomain ?? URL(string: item.text)?.host ?? item.text).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.padding(14) }
                else if item.kind == .richText,let richPreview,let rich = try? NSAttributedString(data:richPreview,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) { RichCardText(text:rich).padding(14) }
                else { highlighted(item.text).font(.system(size: compact ? 13 : 15, design: item.kind == .code ? .monospaced : .default)).lineSpacing(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14).clipped() }
                if item.kind == .image, !query.isEmpty, item.ocrText.localizedCaseInsensitiveContains(query) { Text("Text match: " + item.ocrText).font(.caption2).lineLimit(2).padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            if !compact { Divider(); HStack { Text(item.title ?? item.metadata).lineLimit(1); Spacer(); if item.pinboardID != nil { Image(systemName: "pin.fill").foregroundStyle(.teal) }; if let number { Text("\(number)").font(.system(size: 10, weight: .semibold, design: .rounded)).frame(width: 18, height: 18).background(.quaternary, in: RoundedRectangle(cornerRadius: 5)) } }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 9) }
        }
        .background(.background.opacity(0.84), in: RoundedRectangle(cornerRadius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? .teal : .primary.opacity(0.07), lineWidth: selected ? 2.5 : 1) }
        .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
        .accessibilityElement(children: .combine).accessibilityLabel("\(item.displayTitle), \(item.text.prefix(120)), from \(item.sourceAppName)").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var contrastColor: Color { let raw = UInt64(item.text.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0; let l = Double((raw>>16)&255)*0.299 + Double((raw>>8)&255)*0.587 + Double(raw&255)*0.114; return l > 145 ? .black.opacity(0.8) : .white }
    private func highlighted(_ string: String) -> Text { var attributed = AttributedString(String(string.prefix(4000))); if !query.isEmpty, let range = attributed.range(of: query, options: .caseInsensitive) { attributed[range].backgroundColor = .yellow.opacity(0.45) }; return Text(attributed) }
}

struct RichCardText:NSViewRepresentable {
    let text:NSAttributedString
    func makeNSView(context:Context) -> NSTextField {let field=NSTextField(labelWithAttributedString:text);field.maximumNumberOfLines=8;field.lineBreakMode = .byTruncatingTail;field.isSelectable=false;return field}
    func updateNSView(_ field:NSTextField,context:Context) {field.attributedStringValue=text}
}
