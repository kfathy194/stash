import Foundation
import CSQLite

@MainActor public final class SearchIndex {
    private let connection = SQLiteConnection()
    private var database: OpaquePointer? { connection.database }
    public convenience init(url: URL?) throws {
        try self.init(url: url, configureConnection: { _ in })
    }
    // Internal resource seam for deterministic native lifetime/failure tests.
    init(url: URL?, configureConnection: (OpaquePointer) throws -> Void) throws {
        guard sqlite3_open(url?.path ?? ":memory:", &connection.database) == SQLITE_OK else { throw failure() }
        if let database { try configureConnection(database) }
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS clips USING fts5(id UNINDEXED, content, tokenize='unicode61 remove_diacritics 2')")
    }
    // Queries stay on MainActor; the private owner also releases partial initialization.
    public func close() { connection.close() }
    public func rebuild(_ items: [ClipItem]) throws {
        try execute("BEGIN TRANSACTION")
        do { try execute("DELETE FROM clips"); for item in items { try insert(item) }; try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func upsert(_ item: ClipItem) throws { try remove(item.id); try insert(item) }
    public func remove(_ id: UUID) throws { try statement("DELETE FROM clips WHERE id = ?", bindings: [id.uuidString]) { _ in } }
    public func search(_ query: String, limit: Int = 5000) throws -> [UUID] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let safe = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        var ids: [UUID] = []
        try statement("SELECT id FROM clips WHERE clips MATCH ? ORDER BY rank LIMIT \(max(1, min(limit, 100000)))", bindings: [safe]) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW { if let bytes = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: bytes)) { ids.append(id) } }
        }
        return ids
    }
    private func insert(_ item: ClipItem) throws { try statement("INSERT INTO clips (id, content) VALUES (?, ?)", bindings: [item.id.uuidString, item.searchableText]) { _ in } }
    private func statement(_ sql: String, bindings: [String], body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else { throw failure() }
        defer { sqlite3_finalize(handle) }
        for (offset, value) in bindings.enumerated() { _ = value.withCString { sqlite3_bind_text(handle, Int32(offset + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
        if sql.hasPrefix("SELECT") { try body(handle) }
        else { guard sqlite3_step(handle) == SQLITE_DONE else { throw failure() }; try body(handle) }
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func failure() -> NSError { NSError(domain: "Stash.Search", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open search index"]) }
}

/// This owner does no querying. Its lifetime closes the handle even when the
/// actor-isolated index cannot finish initialization or is released off-actor.
private final class SQLiteConnection {
    var database: OpaquePointer?

    func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    deinit { close() }
}
