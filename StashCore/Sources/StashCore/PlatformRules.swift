import Foundation
import CoreGraphics

public enum FileBookmarks {
    public static func capture(urls:[URL],create:(URL) -> Data?) -> [Data] { urls.map { create($0) ?? Data() } }
    public static func bookmark(at offset:Int,in bookmarks:[Data]) -> Data? { guard bookmarks.indices.contains(offset),!bookmarks[offset].isEmpty else { return nil }; return bookmarks[offset] }
}
public struct WindowDescriptor:Sendable {
    public let id:UInt32
    public let pid:Int32
    public let frame:CGRect
    public let title:String
    public init(id:UInt32,pid:Int32,frame:CGRect,title:String) {self.id=id;self.pid=pid;self.frame=frame;self.title=title}
}
public enum FocusedWindowMatch {
    public static func select(_ windows:[WindowDescriptor],pid:Int32,frame:CGRect,title:String) -> UInt32? {
        let matches: [WindowDescriptor] = windows.filter { (candidate: WindowDescriptor) -> Bool in
            guard candidate.pid == pid else { return false }
            guard abs(candidate.frame.minX - frame.minX) < CGFloat(2) else { return false }
            guard abs(candidate.frame.minY - frame.minY) < CGFloat(2) else { return false }
            guard abs(candidate.frame.width - frame.width) < CGFloat(2) else { return false }
            guard abs(candidate.frame.height - frame.height) < CGFloat(2) else { return false }
            return title.isEmpty || candidate.title == title
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}
