#if os(Linux)
    @_exported import RopeLinux
#else
    @_exported import RopeMacOS
#endif

public enum RopeError: Error {
    case connectionFailed(message: String)
    case emptyQuery
    case invalidQuery(message: String)
    case fatalError(message: String)
}

public final class Rope {

    private(set) var conn: OpaquePointer!

    public var connected: Bool {
        guard let conn = conn, PQstatus(conn) == CONNECTION_OK else {
            return false
        }
        return true
    }

    deinit {
        try? close()
    }

    public static func connect(host: String = "localhost", port: Int = 5432, dbName: String, user: String, password: String) throws -> Rope {
        let rope = Rope()
        try rope.establishConnection(host: host, port: port, dbName: dbName, user: user, password: password)

        return rope
    }

    private func establishConnection(host: String, port: Int, dbName: String, user: String, password: String) throws {
        let conn = PQsetdbLogin(host, String(port), "", "", dbName, user, password)

        guard PQstatus(conn) == CONNECTION_OK else {
            try failWithError(conn); return
        }

        self.conn = conn
    }

    public func query(_ statement: String) throws -> RopeResult? {
        return try execQuery(statement: statement)
    }

    public func query(statement: String, params: [Any]) throws -> RopeResult? {
        return try execQuery(statement: statement, params: params)
    }
    
    private func execQuery(statement: String, params: [Any]? = nil) throws -> RopeResult? {
        if statement.isEmpty {
            throw RopeError.emptyQuery
        }
        
        guard let params = params else {
            guard let res = PQexec(self.conn, statement) else {
                try failWithError(); return nil
            }
            
            return RopeResult(res)
        }
        
        let paramsCount = params.count
        let values = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(capacity: paramsCount)
        
        defer {
            values.deinitialize(count: paramsCount)
            values.deallocate(capacity: paramsCount)
        }
        
        var tempValues = [Array<UInt8>]()
        for (idx, value) in params.enumerated() {
            
            let s = String(describing: value).utf8
            
            tempValues.append(Array<UInt8>(s) + [0])
            values[idx] = UnsafePointer<Int8>(OpaquePointer(tempValues.last!))
        }
        
        guard let res = PQexecParams(self.conn, statement, Int32(params.count), nil, values, nil, nil, Int32(0)) else {
            try failWithError(); return nil
        }
        
        switch PQresultStatus(res) {
        case PGRES_COMMAND_OK, PGRES_TUPLES_OK:
            return RopeResult(res)
        case PGRES_FATAL_ERROR:
            let message = String(cString: PQresultErrorMessage(res))
            throw RopeError.fatalError(message: message)
        default:
            let message = String(cString: PQresultErrorMessage(res))
            throw RopeError.invalidQuery(message: message)
        }
    }

    private func close() throws {
        guard self.connected else {
            try failWithError(); return
        }

        PQfinish(conn)
        conn = nil
    }

    private func failWithError(_ conn: OpaquePointer? = nil) throws {
        let message = String(cString: PQerrorMessage(conn ?? self.conn))
        throw RopeError.connectionFailed(message: message)
    }
}
