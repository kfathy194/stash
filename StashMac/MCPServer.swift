import Foundation
import Network
import AppKit
import SwiftUI
import Security
import Observation
import StashCore

@MainActor @Observable final class MCPServer {
    static let port: UInt16 = 47841
    unowned let model: AppModel
    private(set) var clients: [MCPClient] = []
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: MCPConnection] = [:]
    @ObservationIgnored private var pairing = false
    init(model: AppModel) throws { self.model = model; if let data = UserDefaults.standard.data(forKey: "MCPClients") { clients = try JSONDecoder().decode([MCPClient].self, from: data) } }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] state in if case .failed(let error) = state { Task { @MainActor in self?.model.message("MCP: " + error.localizedDescription); self?.stop() } } }
        listener.start(queue: .main); self.listener = listener
    }
    func stop() { listener?.cancel(); listener = nil; connections.values.forEach { $0.close() }; connections.removeAll() }
    func revoke(_ id: UUID) { TokenVault.delete(id.uuidString); clients.removeAll { $0.id == id }; saveClients() }
    private func saveClients() { if let data = try? JSONEncoder().encode(clients) { UserDefaults.standard.set(data, forKey: "MCPClients") } }
    private func accept(_ connection: NWConnection) { guard connections.count < 20 else { connection.cancel(); return }; let session = MCPConnection(connection: connection, server: self); connections[session.id] = session; session.start() }
    func finished(_ id: UUID) { connections.removeValue(forKey: id) }
    func respond(path: String, headers: [String:String], data: Data) -> (Int, Data) {
        func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
        guard headers["origin"] == nil, ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"].contains(headers["host"]?.lowercased() ?? "") else { return (403, json(["error":"Local clients only"])) }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else { return (400, json(["error":"Invalid JSON"])) }
        if path == "/pair" {
            guard !pairing else { return (429,json(["error":"Pairing already in progress"])) }; pairing = true; defer { pairing = false }
            let name = String((request["clientName"] as? String ?? "Unknown tool").prefix(80))
            let alert = NSAlert(); alert.messageText = "Allow \(name) to connect to Stash?"; alert.informativeText = "This local program is asking for access. Select what it may do. Only approve a connection you initiated."; alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Deny")
            let history = NSButton(checkboxWithTitle: "Read clipboard history", target: nil, action: nil), pinboards = NSButton(checkboxWithTitle: "Read pinboards", target: nil, action: nil), write = NSButton(checkboxWithTitle: "Create items and pinboards", target: nil, action: nil)
            pinboards.state = .on; let stack = NSStackView(views: [history,pinboards,write]); stack.orientation = .vertical; stack.alignment = .leading; stack.frame = NSRect(x: 0,y: 0,width: 320,height: 85); alert.accessoryView = stack
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return (403,json(["error":"Access denied"])) }
            let scopes: [MCPScope] = [(history,MCPScope.readHistory),(pinboards,MCPScope.readPinboards),(write,MCPScope.writeItems)].compactMap { $0.0.state == .on ? $0.1 : nil }
            guard !scopes.isEmpty else { return (403,json(["error":"No permissions granted"])) }
            let client = MCPClient(name: name, scopes: scopes)
            do { let token = try TokenVault.generate(); try TokenVault.save(token, account: client.id.uuidString); clients.append(client); saveClients(); return (200,json(["clientID":client.id.uuidString,"token":token])) } catch { return (500,json(["error":"Unable to save client credentials"])) }
        }
        guard path == "/mcp", let authorization = headers["authorization"], authorization.hasPrefix("Bearer ") else { return (401,json(["error":"Authorization required"])) }
        let token = String(authorization.dropFirst(7))
        guard let client = clients.first(where: { TokenVault.read($0.id.uuidString).map { Self.equal($0,token) } == true }) else { return (403,json(["error":"Access revoked or token invalid"])) }
        let id = request["id"] ?? NSNull()
        func success(_ value: Any) -> (Int,Data) { (200,json(["jsonrpc":"2.0","id":id,"result":value])) }
        func failure(_ code: Int, _ message: String) -> (Int,Data) { (200,json(["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]])) }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return failure(-32600,"Invalid request") }
        if method.hasPrefix("notifications/") { return (202,Data()) }
        if method == "initialize" { return success(["protocolVersion":"2025-03-26","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"Stash","version":"0.1.0"]]) }
        if method == "ping" { return success([:]) }
        if method == "tools/list" { return success(["tools":Self.toolDefinitions.filter { definition in let name = definition["name"] as! String; return name == "list_pinboards" ? client.scopes.contains(.readPinboards) : ["create_item","create_pinboard","add_to_pinboard"].contains(name) ? client.scopes.contains(.writeItems) : client.scopes.contains(.readHistory) || client.scopes.contains(.readPinboards) }]) }
        guard method == "tools/call", let params = request["params"] as? [String:Any], let name = params["name"] as? String else { return failure(-32601,"Method not found") }
        let args = params["arguments"] as? [String:Any] ?? [:]
        do {
            let result = try call(name, args: args, client: client)
            return success(["content":[["type":"text","text":String(decoding: json(result),as:UTF8.self)]],"isError":false])
        } catch { return success(["content":[["type":"text","text":error.localizedDescription]],"isError":true]) }
    }
    private func call(_ name: String, args: [String:Any], client: MCPClient) throws -> Any {
        let accessible = model.store.items.filter { client.canRead($0) }
        func itemObject(_ item: ClipItem) -> [String:Any] { ["id":item.id.uuidString,"type":item.kind.rawValue,"title":item.displayTitle,"text":item.text,"ocrText":item.ocrText,"app":item.sourceAppName,"device":item.device,"createdAt":ISO8601DateFormatter().string(from:item.createdAt),"pinboardID":item.pinboardID?.uuidString ?? ""] }
        func writeAllowed() throws { guard client.scopes.contains(.writeItems) else { throw MCPError.denied } }
        switch name {
        case "search_items", "list_recent":
            guard !client.scopes.filter({ $0 == .readHistory || $0 == .readPinboards }).isEmpty else { throw MCPError.denied }
            var filter = SearchFilter(); if let type = args["type"] as? String { filter.kind = ClipKind(rawValue:type) }; filter.sourceAppID = args["app"] as? String
            let formatter = ISO8601DateFormatter(); filter.after = (args["after"] as? String).flatMap(formatter.date(from:)); filter.before = (args["before"] as? String).flatMap(formatter.date(from:))
            if (args["period"] as? String) == "today" { filter.after = Calendar.current.startOfDay(for: .now) }
            let limit = min(200,max(1,args["limit"] as? Int ?? 50)); let allowed = Set(accessible.map(\.id))
            return model.store.results(query: args["query"] as? String ?? "",filter:filter,allLocations:true).filter { allowed.contains($0.id) }.prefix(limit).map(itemObject)
        case "get_item": guard let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)), let item = accessible.first(where: { $0.id == id }) else { throw MCPError.denied }; return itemObject(item)
        case "list_pinboards": guard client.scopes.contains(.readPinboards) else { throw MCPError.denied }; return model.store.pinboards.map { ["id":$0.id.uuidString,"name":$0.name,"color":$0.colorHex] }
        case "create_item": try writeAllowed(); guard let text = args["text"] as? String, !text.isEmpty, text.utf8.count <= 500_000 else { throw MCPError.invalid }; var item = ClipItem(kind:ContentClassifier.kind(for:text),text:text); item.title = args["title"] as? String; item.creatorClientID = client.id; item.sourceAppName = client.name; item.device = Host.current().localizedName ?? "Mac"; try model.store.add(item); return ["id":item.id.uuidString]
        case "create_pinboard": try writeAllowed(); guard let name = args["name"] as? String, !name.isEmpty else { throw MCPError.invalid }; let board = try model.store.createBoard(name:String(name.prefix(200)),colorHex:args["color"] as? String ?? "30B7A8"); return ["id":board.id.uuidString]
        case "add_to_pinboard": try writeAllowed(); guard let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)), (accessible.contains(where: { $0.id == id }) || model.store.items.contains(where: { $0.id == id && $0.creatorClientID == client.id })), let board = (args["pinboardID"] as? String).flatMap(UUID.init(uuidString:)), model.store.pinboards.contains(where: { $0.id == board }) else { throw MCPError.denied }; try model.store.pin([id],to:board); return ["success":true]
        default: throw MCPError.invalid
        }
    }
    private static func equal(_ a: String,_ b: String) -> Bool { let x = Array(a.utf8), y = Array(b.utf8); guard x.count == y.count else { return false }; return zip(x,y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 }
    private static var toolDefinitions: [[String:Any]] {
        func tool(_ name: String,_ description: String,_ properties:[String:Any],_ required:[String] = []) -> [String:Any] { ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false]] }
        let string: [String:String] = ["type":"string"]
        return [tool("search_items","Search clipboard content, titles, URLs and OCR text.",["query":string,"type":string,"app":string,"after":string,"before":string,"limit":["type":"integer"]]),tool("get_item","Read one permitted clipboard item.",["id":string],["id"]),tool("list_recent","List recent permitted items, optionally from today.",["period":string,"limit":["type":"integer"]]),tool("create_item","Create a text item.",["text":string,"title":string],["text"]),tool("list_pinboards","List permitted pinboards.",[:]),tool("create_pinboard","Create a named pinboard.",["name":string,"color":string],["name"]),tool("add_to_pinboard","Move a permitted item to a pinboard.",["id":string,"pinboardID":string],["id","pinboardID"])]
    }
    enum MCPError: LocalizedError { case denied, invalid; var errorDescription: String? { self == .denied ? "Access is not permitted." : "Invalid tool or arguments." } }
}

@MainActor final class MCPConnection {
    let id = UUID()
    let connection: NWConnection
    unowned let server: MCPServer
    var buffer = Data()
    var completed = false
    init(connection: NWConnection, server: MCPServer) { self.connection = connection; self.server = server }
    func start() { connection.start(queue: .main); receive(); Task { try? await Task.sleep(for:.seconds(30)); if !self.completed { self.close() } } }
    func close() { completed = true; connection.cancel(); server.finished(id) }
    func receive() { connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,ended,error in Task { @MainActor in guard let self,!self.completed else { return }; if let data { self.buffer.append(data) }; if self.buffer.count > 1_048_576 { self.send(413,Data()); return }; if self.parse() { return }; if ended || error != nil { self.close() } else { self.receive() } } } }
    func parse() -> Bool {
        guard let range = buffer.range(of:Data("\r\n\r\n".utf8)) else { if buffer.count > 16_384 { send(400,Data()); return true }; return false }
        let raw = String(decoding:buffer[..<range.lowerBound],as:UTF8.self); let lines = raw.components(separatedBy:"\r\n"); let start = lines[0].split(separator:" ")
        guard start.count == 3,start[0] == "POST" else { send(405,Data()); return true }
        var headers:[String:String] = [:]
        for line in lines.dropFirst() { if let colon = line.firstIndex(of:":") { let key = line[..<colon].lowercased(); if headers[key] != nil { send(400,Data()); return true }; headers[key] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) } }
        guard headers["transfer-encoding"] == nil, let size = headers["content-length"].flatMap(Int.init),size >= 0,size <= 1_000_000 else { send(400,Data()); return true }
        let offset = range.upperBound; guard buffer.count >= offset + size else { return false }
        let (status,data) = server.respond(path:String(start[1]),headers:headers,data:buffer.subdata(in:offset..<offset+size)); send(status,data); return true
    }
    func send(_ status:Int,_ data:Data) { completed = true; let response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Response")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + data; connection.send(content:response,completion:.contentProcessed { [weak self] _ in Task { @MainActor in self?.close() } }) }
}

enum TokenVault {
    static let service = "com.kfathy.stash.mcp"
    static func generate() throws -> String { var bytes = [UInt8](repeating:0,count:32); guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw NSError(domain:"Stash.Token",code:1) }; return Data(bytes).base64EncodedString() }
    static func save(_ token:String,account:String) throws { delete(account); let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]; let status = SecItemAdd(query as CFDictionary,nil); guard status == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) } }
    static func read(_ account:String) -> String? { let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true]; var result:CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data = result as? Data else { return nil }; return String(data:data,encoding:.utf8) }
    static func delete(_ account:String) { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] as CFDictionary) }
}

@MainActor enum MCPSetupWindow {
    static var window: NSWindow?
    static func open() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StashMCP").path
        let content = """
        Connect an AI tool

        1. Enable MCP in Stash Settings → Intelligence.
        2. Configure the tool to launch this bundled helper:
        \(helper)
        Arguments: --client <tool-name>
        3. Start the tool, then approve its first connection in Stash.

        Claude Desktop / Cursor / Windsurf / VS Code MCP JSON:
        {"mcpServers":{"stash":{"command":"\(helper)","args":["--client","Claude Desktop"]}}}
        VS Code uses a top-level \"servers\" key instead of \"mcpServers\".

        Claude Code:
        claude mcp add stash -- \"\(helper)\" --client \"Claude Code\"

        Codex config.toml:
        [mcp_servers.stash]
        command = \"\(helper)\"
        args = [\"--client\", \"Codex\"]

        Custom local HTTP clients: POST /pair with {"clientName":"My Tool"} on http://127.0.0.1:47841. After approval, use the returned token as Authorization: Bearer <token> for POST /mcp. Never publish tokens.

        After revoking access, run the helper with the same --client name and --reset to clear its old credential before reconnecting.

        Try: Find the notes I copied today in Stash. Draft a team update for the launch using them.
        """
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; let text = NSTextView(); text.isEditable = false; text.string = content; text.font = .monospacedSystemFont(ofSize:12,weight:.regular); text.textContainerInset = NSSize(width:20,height:20); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; scroll.documentView = text
        let controller = NSViewController(); controller.view = scroll; let result = NSWindow(contentViewController:controller); result.title = "Connect AI Tool"; result.setContentSize(NSSize(width:700,height:550)); result.isReleasedWhenClosed = false; result.center(); result.makeKeyAndOrderFront(nil); window = result
    }
}
