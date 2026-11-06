import Foundation
import Security

// Newline-delimited MCP stdio bridge. Credentials never appear on stdout.
func request(path:String,body:Data,token:String? = nil) throws -> Data {
    let semaphore = DispatchSemaphore(value:0)
    final class ResultBox: @unchecked Sendable { var result:Result<Data,Error>? }
    let box = ResultBox()
    var request = URLRequest(url:URL(string:"http://127.0.0.1:47841/" + path)!); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 120; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
    if let token { request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization") }
    let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
    URLSession(configuration:config).dataTask(with:request) { data,response,error in
        if let error { box.result = .failure(error) } else if let response = response as? HTTPURLResponse,(200..<300).contains(response.statusCode) { box.result = .success(data ?? Data()) } else { box.result = .failure(NSError(domain:"StashMCP",code:(response as? HTTPURLResponse)?.statusCode ?? 0,userInfo:[NSLocalizedDescriptionKey:"Stash denied this request. Check client permissions in Stash Settings."])) }; semaphore.signal()
    }.resume(); semaphore.wait(); return try box.result!.get()
}
let args = CommandLine.arguments
let name = args.firstIndex(of:"--client").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "Custom MCP Tool"
let account = "bridge:" + name
let base:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.kfathy.stash.mcp.bridge",kSecAttrAccount as String:account]
if args.contains("--reset") { SecItemDelete(base as CFDictionary); FileHandle.standardError.write(Data("Credential removed. Start this client again to request approval.\n".utf8)); exit(0) }
var query = base; query[kSecReturnData as String] = true; var result:CFTypeRef?
var token:String? = SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess ? (result as? Data).flatMap { String(data:$0,encoding:.utf8) } : nil
func log(_ text:String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
do {
    if token == nil {
        log("Approve the new client in Stash to continue.")
        let data = try request(path:"pair",body:JSONSerialization.data(withJSONObject:["clientName":name]))
        guard let pair = try JSONSerialization.jsonObject(with:data) as? [String:String], let value = pair["token"] else { throw NSError(domain:"StashMCP",code:1) }; token = value
        SecItemDelete(base as CFDictionary); var add = base; add[kSecValueData as String] = Data(value.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw NSError(domain:"StashMCP",code:2,userInfo:[NSLocalizedDescriptionKey:"Unable to store client credential in Keychain."]) }
    }
    while let line = readLine() {
        guard let data = line.data(using:.utf8),data.count <= 1_000_000 else { continue }
        do { let output = try request(path:"mcp",body:data,token:token); if !output.isEmpty { FileHandle.standardOutput.write(output + Data([10])) } }
        catch { log(error.localizedDescription); if let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],let id = object["id"], let output = try? JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":id,"error":["code":-32000,"message":"Stash request failed. Check that Stash is running and client access is allowed."]]) { FileHandle.standardOutput.write(output + Data([10])) } }
    }
} catch { log(error.localizedDescription); exit(1) }
