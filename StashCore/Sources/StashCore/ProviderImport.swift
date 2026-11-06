#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import Vision
import LinkPresentation

@MainActor public enum ProviderImport {
    public static func items(from providers:[NSItemProvider],source:String="Share Sheet") async -> [ClipItem] {
        var output:[ClipItem]=[]
        for provider in providers {
            var item:ClipItem?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                item=try? await file(provider,type:provider.registeredTypeIdentifiers.first(where:{$0 != UTType.fileURL.identifier}) ?? UTType.data.identifier)
                if item == nil,let data=try? await load(provider,type:UTType.fileURL.identifier),let raw=String(data:data,encoding:.utf8),let url=URL(string:raw.trimmingCharacters(in:.controlCharacters)) {item=try? FileAssets.importFile(from:url,name:provider.suggestedName ?? url.lastPathComponent,type:UTType(filenameExtension:url.pathExtension)?.identifier ?? UTType.data.identifier,directory:LibraryStore.defaultDirectory())}
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),let data=try? await load(provider,type:UTType.image.identifier),let image=UIImage(data:data) {
                var clip=ClipItem(kind:.image);clip.data=data;clip.byteCount=data.count;clip.imageWidth=Int(image.size.width*image.scale);clip.imageHeight=Int(image.size.height*image.scale);clip.thumbnail=thumbnail(image)
                clip.ocrText=await recognize(data);item=clip
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),let data=try? await load(provider,type:UTType.url.identifier),let raw=String(data:data,encoding:.utf8) {
                var clip=ClipItem(kind:ContentClassifier.kind(for:raw),text:raw)
                if let url=URL(string:raw),["http","https"].contains(url.scheme ?? "") {
                    let metadata=LPMetadataProvider();metadata.timeout=4
                    if let preview=try? await metadata.startFetchingMetadata(for:url) {clip.linkTitle=preview.title;clip.linkDomain=url.host;if let provider=preview.imageProvider,let data=try? await load(provider,type:UTType.image.identifier),let image=UIImage(data:data) {clip.thumbnail=thumbnail(image)}}
                };item=clip
            } else if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),let data=try? await load(provider,type:UTType.rtf.identifier),let text=try? NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) {var clip=ClipItem(kind:.richText,text:text.string);clip.richData=data;item=clip}
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),let data=try? await load(provider,type:UTType.plainText.identifier),let text=String(data:data,encoding:.utf8) {item=ClipItem(kind:ContentClassifier.kind(for:text),text:text)}
            else if let type=provider.registeredTypeIdentifiers.first(where:{UTType($0)?.conforms(to:.data)==true}) {item=try? await file(provider,type:type)}
            if var clip=item {clip.device=UIDevice.current.name;clip.sourceAppName=source;output.append(clip)}
        }
        return output
    }
    private static func file(_ provider:NSItemProvider,type:String) async throws -> ClipItem {
        let directory=LibraryStore.defaultDirectory();var name=provider.suggestedName ?? "File"
        if URL(fileURLWithPath:name).pathExtension.isEmpty,let ext=UTType(type)?.preferredFilenameExtension {name += "."+ext}
        let filename=name
        return try await withCheckedThrowingContinuation { continuation in provider.loadFileRepresentation(forTypeIdentifier:type) { url,error in
            guard let url else {continuation.resume(throwing:error ?? CocoaError(.fileReadUnknown));return}
            do {continuation.resume(returning:try FileAssets.importFile(from:url,name:filename,type:type,directory:directory))} catch {continuation.resume(throwing:error)}
        } }
    }
    private static func load(_ provider:NSItemProvider,type:String) async throws -> Data {try await withCheckedThrowingContinuation { continuation in provider.loadDataRepresentation(forTypeIdentifier:type) {data,error in if let data {continuation.resume(returning:data)} else {continuation.resume(throwing:error ?? CocoaError(.fileReadUnknown))}}}}
    private static func thumbnail(_ image:UIImage) -> Data {
        let ratio=min(1,500/max(image.size.width,image.size.height));let target=CGSize(width:max(1,image.size.width*ratio),height:max(1,image.size.height*ratio));return UIGraphicsImageRenderer(size:target).jpegData(withCompressionQuality:0.8) {_ in image.draw(in:CGRect(origin:.zero,size:target))}
    }
    nonisolated private static func recognize(_ data:Data) async -> String {await Task.detached(priority:.utility) {let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.automaticallyDetectsLanguage=true;do {try VNImageRequestHandler(data:data).perform([request]);return request.results?.compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n") ?? ""} catch {return ""}}.value}
}
#endif
