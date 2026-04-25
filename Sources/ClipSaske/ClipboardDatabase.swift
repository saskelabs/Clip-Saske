import Foundation
import SQLite3

enum ClipSaskeError: LocalizedError {
    case databaseOpenFailed(String)
    case databasePrepareFailed(String)
    case databaseStepFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message): "Database open failed: \(message)"
        case .databasePrepareFailed(let message): "Database prepare failed: \(message)"
        case .databaseStepFailed(let message): "Database step failed: \(message)"
        }
    }
}

final class ClipboardDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "clip-saske.database")
    /// AES-256-GCM encryption layer — key lives in Keychain.
    let encryption = DatabaseEncryption()

    var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Clip Saske", isDirectory: true).appendingPathComponent("clipsaske.sqlite3")
    }

    func open() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw ClipSaskeError.databaseOpenFailed(lastError)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func resetCorruptStore() throws {
        close()
        let directory = databaseURL.deletingLastPathComponent()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupDirectory = directory.appendingPathComponent("Corrupt Backup \(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let sidecars = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for url in sidecars where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: backupDirectory.appendingPathComponent(url.lastPathComponent))
        }

        try open()
        try migrate()
    }

    func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            timestamp REAL NOT NULL,
            app_source TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            is_sensitive INTEGER NOT NULL DEFAULT 0,
            sync_status TEXT NOT NULL DEFAULT 'pending'
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_clipboard_items_timestamp ON clipboard_items(timestamp DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_clipboard_items_flags ON clipboard_items(is_pinned, is_favorite);")
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_items_fts USING fts5(
            content,
            app_source,
            content='clipboard_items',
            content_rowid='rowid'
        );
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS clipboard_items_ai AFTER INSERT ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(rowid, content, app_source)
            VALUES (new.rowid, new.content, new.app_source);
        END;
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS clipboard_items_ad AFTER DELETE ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, content, app_source)
            VALUES ('delete', old.rowid, old.content, old.app_source);
        END;
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS clipboard_items_au AFTER UPDATE ON clipboard_items BEGIN
            INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, content, app_source)
            VALUES ('delete', old.rowid, old.content, old.app_source);
            INSERT INTO clipboard_items_fts(rowid, content, app_source)
            VALUES (new.rowid, new.content, new.app_source);
        END;
        """)
        /*
        try execute("INSERT INTO clipboard_items_fts(clipboard_items_fts) VALUES('rebuild');")
        */
    }

    func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? lastError
                sqlite3_free(error)
                throw ClipSaskeError.databaseStepFailed(message)
            }
        }
    }

    func insert(_ item: ClipboardItem) throws {
        try queue.sync {
            let sql = """
            INSERT OR REPLACE INTO clipboard_items
            (id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            // Encrypt content before persisting to disk.
            let encryptedContent = encryption.encrypt(item.content)
            bindText(statement, 1, item.id)
            bindText(statement, 2, encryptedContent)
            sqlite3_bind_double(statement, 3, item.timestamp.timeIntervalSince1970)
            bindText(statement, 4, item.appSource)
            sqlite3_bind_int(statement, 5, item.isPinned ? 1 : 0)
            sqlite3_bind_int(statement, 6, item.isFavorite ? 1 : 0)
            sqlite3_bind_int(statement, 7, item.isSensitive ? 1 : 0)
            bindText(statement, 8, item.syncStatus.rawValue)
            try stepDone(statement)
        }
    }

    func recent(limit: Int = 500, query: String? = nil) throws -> [ClipboardItem] {
        try queue.sync {
            let hasQuery = !(query ?? "").isEmpty
            let sql = hasQuery
                ? """
                SELECT id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status
                FROM clipboard_items
                WHERE rowid IN (
                    SELECT rowid FROM clipboard_items_fts WHERE clipboard_items_fts MATCH ?
                )
                ORDER BY is_pinned DESC, timestamp DESC
                LIMIT ?;
                """
                : """
                SELECT id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status
                FROM clipboard_items
                ORDER BY is_pinned DESC, timestamp DESC
                LIMIT ?;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if hasQuery {
                let search = ftsQuery(query ?? "")
                bindText(statement, 1, search)
                sqlite3_bind_int(statement, 2, Int32(limit))
            } else {
                sqlite3_bind_int(statement, 1, Int32(limit))
            }
            return try readItems(statement)
        }
    }

    func recentUsingLikeFallback(limit: Int = 500, query: String) throws -> [ClipboardItem] {
        try queue.sync {
            let statement = try prepare("""
            SELECT id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status
            FROM clipboard_items
            WHERE content LIKE ? OR app_source LIKE ?
            ORDER BY is_pinned DESC, timestamp DESC
            LIMIT ?;
            """)
            defer { sqlite3_finalize(statement) }
            let wildcard = "%\(query)%"
            bindText(statement, 1, wildcard)
            bindText(statement, 2, wildcard)
            sqlite3_bind_int(statement, 3, Int32(limit))
            return try readItems(statement)
        }
    }

    private func ftsQuery(_ query: String) -> String {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        return terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    func pinned(limit: Int = 50) throws -> [ClipboardItem] {
        try queue.sync {
            let statement = try prepare("""
            SELECT id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status
            FROM clipboard_items
            WHERE is_pinned = 1
            ORDER BY timestamp DESC
            LIMIT ?;
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            return try readItems(statement)
        }
    }

    func favorites() throws -> [ClipboardItem] {
        try queue.sync {
            let statement = try prepare("""
            SELECT id, content, timestamp, app_source, is_pinned, is_favorite, is_sensitive, sync_status
            FROM clipboard_items
            WHERE is_favorite = 1
            ORDER BY timestamp DESC;
            """)
            defer { sqlite3_finalize(statement) }
            return try readItems(statement)
        }
    }

    func setFlag(id: String, column: String, value: Bool) throws {
        precondition(["is_pinned", "is_favorite"].contains(column))
        try queue.sync {
            let sql = column == "is_pinned"
                ? "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?;"
                : "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?;"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, value ? 1 : 0)
            bindText(statement, 2, id)
            try stepDone(statement)
        }
    }

    func delete(id: String) throws {
        try queue.sync {
            let statement = try prepare("DELETE FROM clipboard_items WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, id)
            try stepDone(statement)
        }
    }

    func clearUnprotected() throws {
        try execute("DELETE FROM clipboard_items WHERE is_pinned = 0 AND is_favorite = 0;")
    }

    func cleanup(olderThan cutoff: Date, maxItems: Int) throws {
        try queue.sync {
            let byAge = try prepare("DELETE FROM clipboard_items WHERE is_pinned = 0 AND is_favorite = 0 AND timestamp < ?;")
            defer { sqlite3_finalize(byAge) }
            sqlite3_bind_double(byAge, 1, cutoff.timeIntervalSince1970)
            try stepDone(byAge)

            let byCount = try prepare("""
            DELETE FROM clipboard_items
            WHERE id IN (
                SELECT id FROM clipboard_items
                WHERE is_pinned = 0 AND is_favorite = 0
                ORDER BY timestamp DESC
                LIMIT -1 OFFSET ?
            );
            """)
            defer { sqlite3_finalize(byCount) }
            sqlite3_bind_int(byCount, 1, Int32(maxItems))
            try stepDone(byCount)
        }
    }

    func setting(key: String) throws -> String? {
        try queue.sync {
            let statement = try prepare("SELECT value FROM settings WHERE key = ?;")
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, key)
            if sqlite3_step(statement) == SQLITE_ROW {
                return columnText(statement, 0)
            }
            return nil
        }
    }

    func setSetting(key: String, value: String) throws {
        try queue.sync {
            let statement = try prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);")
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, key)
            bindText(statement, 2, value)
            try stepDone(statement)
        }
    }

    private var lastError: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw ClipSaskeError.databasePrepareFailed(lastError)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw ClipSaskeError.databaseStepFailed(lastError)
        }
    }

    private func readItems(_ statement: OpaquePointer?) throws -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // Decrypt content transparently; non-encrypted legacy rows pass through.
            let rawContent = columnText(statement, 1)
            let content    = encryption.decrypt(rawContent)
            items.append(ClipboardItem(
                id: columnText(statement, 0),
                content: content,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                appSource: columnText(statement, 3),
                isPinned: sqlite3_column_int(statement, 4) == 1,
                isFavorite: sqlite3_column_int(statement, 5) == 1,
                isSensitive: sqlite3_column_int(statement, 6) == 1,
                syncStatus: ClipboardItem.SyncStatus(rawValue: columnText(statement, 7)) ?? .pending
            ))
        }
        return items
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
