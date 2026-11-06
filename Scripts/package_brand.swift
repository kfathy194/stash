import CoreGraphics
import ImageIO
import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let manager=FileManager.default
func png(_ image:CGImage,_ size:Int,opaque:Bool=false) -> Data {
    let bitmap:CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:bitmap.rawValue)!
    ctx.interpolationQuality = .high
    if opaque {ctx.setFillColor(CGColor(red:0.06,green:0.18,blue:0.20,alpha:1));ctx.fill(CGRect(x:0,y:0,width:size,height:size))}
    ctx.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
    let data=NSMutableData();let dest=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!;CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);CGImageDestinationFinalize(dest);return data as Data
}
func source(_ filename:String) -> CGImage {CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(root.appendingPathComponent(filename) as CFURL,nil)!,0,nil)!}
let mac=source("Branding/Stash-macOS-master.png")
let ios=source("Branding/Stash-iOS-master.png")
let info:[String:Any]=["author":"xcode","version":1]
let iconset=root.appendingPathComponent("Branding/Stash.iconset");try manager.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {for scale in [1,2] {try png(mac,size*scale).write(to:iconset.appendingPathComponent("icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"))}}
for folder in ["StashMac","StashIOS"] {
    let catalog=root.appendingPathComponent(folder+"/Assets.xcassets");let icons=catalog.appendingPathComponent("AppIcon.appiconset");try manager.createDirectory(at:icons,withIntermediateDirectories:true)
    let isMac=folder=="StashMac";let image=isMac ? mac : ios
    let sizes:[(String,Double,[Int])]=isMac ? [("mac",16,[1,2]),("mac",32,[1,2]),("mac",128,[1,2]),("mac",256,[1,2]),("mac",512,[1,2])] : [("iphone",20,[2,3]),("iphone",29,[2,3]),("iphone",40,[2,3]),("iphone",60,[2,3]),("ipad",20,[1,2]),("ipad",29,[1,2]),("ipad",40,[1,2]),("ipad",76,[1,2]),("ipad",83.5,[2]),("ios-marketing",1024,[1])]
    var entries:[[String:String]]=[]
    for (idiom,size,scales) in sizes {for scale in scales {let label=size.rounded()==size ? String(Int(size)):String(size);let filename="stash-\(idiom)-\(label)@\(scale)x.png";try png(image,Int(size*Double(scale)),opaque:!isMac).write(to:icons.appendingPathComponent(filename));entries.append(["idiom":idiom,"size":"\(label)x\(label)","scale":"\(scale)x","filename":filename])}}
    try JSONSerialization.data(withJSONObject:["images":entries,"info":info],options:.prettyPrinted).write(to:icons.appendingPathComponent("Contents.json"))
    let badge=catalog.appendingPathComponent("StashBadge.imageset");try manager.createDirectory(at:badge,withIntermediateDirectories:true)
    try png(mac,256).write(to:badge.appendingPathComponent("stash-badge.png"));try JSONSerialization.data(withJSONObject:["images":[["idiom":"universal","filename":"stash-badge.png"]],"info":info]).write(to:badge.appendingPathComponent("Contents.json"))
    let accent=catalog.appendingPathComponent("AccentColor.colorset");try manager.createDirectory(at:accent,withIntermediateDirectories:true)
    let light:[String:Any]=["idiom":"universal","color":["color-space":"srgb","components":["red":"0.067","green":"0.420","blue":"0.373","alpha":"1.000"]]]
    let dark:[String:Any]=["idiom":"universal","appearances":[["appearance":"luminosity","value":"dark"]],"color":["color-space":"srgb","components":["red":"0.345","green":"0.851","blue":"0.757","alpha":"1.000"]]]
    try JSONSerialization.data(withJSONObject:["colors":[light,dark],"info":info],options:.prettyPrinted).write(to:accent.appendingPathComponent("Contents.json"))
}
// A dedicated monochrome template keeps the menu bar legible in every appearance.
for scale in [1,2,3] {
    let size=18*scale;let s=CGFloat(size)/32
    let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.move(to:CGPoint(x:25*s,y:27*s));ctx.addLine(to:CGPoint(x:10*s,y:23*s));ctx.addCurve(to:CGPoint(x:9*s,y:15*s),control1:CGPoint(x:2*s,y:21*s),control2:CGPoint(x:3*s,y:12*s));ctx.addLine(to:CGPoint(x:23*s,y:19*s));ctx.addCurve(to:CGPoint(x:22*s,y:9*s),control1:CGPoint(x:31*s,y:22*s),control2:CGPoint(x:30*s,y:11*s));ctx.addLine(to:CGPoint(x:7*s,y:5*s));ctx.setLineWidth(4.5*s);ctx.setLineCap(.round);ctx.setLineJoin(.round);ctx.setStrokeColor(CGColor(gray:0,alpha:1));ctx.strokePath();let image=ctx.makeImage()!
    let set=root.appendingPathComponent("StashMac/Assets.xcassets/StashStatus.imageset");try manager.createDirectory(at:set,withIntermediateDirectories:true);try png(image,size).write(to:set.appendingPathComponent("stash-status@\(scale)x.png"))
}
let status=root.appendingPathComponent("StashMac/Assets.xcassets/StashStatus.imageset/Contents.json")
try JSONSerialization.data(withJSONObject:["images":[1,2,3].map{["idiom":"mac","scale":"\($0)x","filename":"stash-status@\($0)x.png"]},"properties":["template-rendering-intent":"template"],"info":info],options:.prettyPrinted).write(to:status)
print("Packaged Stash app icons, badge, status glyph and appearance-aware accent colors.")
