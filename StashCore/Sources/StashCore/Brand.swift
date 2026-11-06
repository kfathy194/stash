import SwiftUI

public enum StashBrand {
    public static let name = "Stash"
    public static let tagline = "A home for the things you copy."
    public static let accent = Color("AccentColor")
    public static let jade = Color(red:0.13,green:0.71,blue:0.65)
    public static let midnight = Color(red:0.06,green:0.18,blue:0.20)
}

/// A small, single-color companion to the sculpted app icon.
public struct StashGlyph: Shape {
    public init() {}
    public func path(in rect:CGRect) -> Path {
        let sx = rect.width / 32, sy = rect.height / 32
        var p = Path()
        p.move(to:CGPoint(x:25*sx,y:5*sy))
        p.addLine(to:CGPoint(x:10*sx,y:9*sy))
        p.addCurve(to:CGPoint(x:9*sx,y:17*sy),control1:CGPoint(x:2*sx,y:11*sy),control2:CGPoint(x:3*sx,y:20*sy))
        p.addLine(to:CGPoint(x:23*sx,y:13*sy))
        p.addCurve(to:CGPoint(x:22*sx,y:23*sy),control1:CGPoint(x:31*sx,y:10*sy),control2:CGPoint(x:30*sx,y:21*sy))
        p.addLine(to:CGPoint(x:7*sx,y:27*sy))
        return p.strokedPath(StrokeStyle(lineWidth:min(sx,sy)*4.5,lineCap:.round,lineJoin:.round))
    }
}

public struct StashWordmark: View {
    public var size:CGFloat
    public init(size:CGFloat = 24) {self.size=size}
    public var body:some View { HStack(spacing:size*0.3) { StashGlyph().fill(StashBrand.accent).frame(width:size,height:size); Text(StashBrand.name).font(.system(size:size,weight:.semibold,design:.rounded)).tracking(-size*0.025) }.accessibilityElement(children:.ignore).accessibilityLabel(StashBrand.name) }
}
public struct StashAppBadge:View {
    public var size:CGFloat
    public init(size:CGFloat = 64) {self.size=size}
    public var body:some View { Image("StashBadge").resizable().interpolation(.high).scaledToFit().frame(width:size,height:size).accessibilityHidden(true) }
}
