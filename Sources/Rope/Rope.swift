import RopeLibpq

import Dispatch
import struct Foundation.UUID

public enum RopeError: Error {
    case connectionFailed(message: String)
    case emptyQuery
    case invalidQuery(message: String)
    case fatalError(message: String, code: PGErrorCode)
    case reconnectFailed
}

/// connection details to database
public struct RopeCredentials {

    private(set) public var host: String
    private(set) public var port: Int
    private(set) public var dbName: String
    private(set) public var user: String
    private(set) public var password: String

    public init(host: String, port: Int, dbName: String, user: String, password: String) {
        self.host = host
        self.port = port
        self.dbName = dbName
        self.user = user
        self.password = password
    }
}

public final class Rope {

    private(set) var conn: OpaquePointer!
    private let connectionQueue: DispatchQueue = DispatchQueue(label: "com.rope.connection-queue-\(UUID().uuidString)")

    public var connected: Bool {
        guard let conn = conn, PQstatus(conn) == CONNECTION_OK else {
            return false
        }
        return true
    }

    deinit {
        try? close()
    }

    /// connect to database using RopeCredentials struct
    public static func connect(credentials: RopeCredentials) throws -> Rope {
        let rope = Rope()
        try rope.establishConnection(host: credentials.host, port: credentials.port,
                                     dbName: credentials.dbName, user: credentials.user, password: credentials.password)

        return rope
    }

    /// connect to database using credential connection arguments
    public static func connect(host: String = "localhost", port: Int = 5432, dbName: String,
                               user: String, password: String) throws -> Rope {
        let rope = Rope()
        try rope.establishConnection(host: host, port: port, dbName: dbName, user: user, password: password)

        return rope
    }

    private func establishConnection(host: String, port: Int, dbName: String, user: String, password: String) throws {
        let conn = PQsetdbLogin(host, String(port), "", "", dbName, user, password)

        guard PQstatus(conn) == CONNECTION_OK else {
            throw failWithError(conn)
        }

        self.conn = conn
    }

    /// query database with SQL statement
    public func query(_ statement: String) throws -> RopeResult {
        return try execQuery(statement: statement)
    }

    /// query database with SQL statement, use $1, $2, etc. for params in SQL
    public func query(_ statement: String, params: [Any]) throws -> RopeResult {
        return try execQuery(statement: statement, params: params)
    }

    private func execQuery(statement: String, params: [Any]? = nil) throws -> RopeResult {

        if !self.connected {
            try self.reconnect()
        }

        if statement.isEmpty {
            throw RopeError.emptyQuery
        }

        guard let params = params else {
            let result = self.connectionQueue.sync {
                return PQexec(self.conn, statement)
            }

            guard let res = result else {
                throw failWithError()
            }

            return try validateQueryResultStatus(res)
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
        let result = self.connectionQueue.sync {
            return PQexecParams(self.conn, statement, Int32(params.count), nil, values, nil, nil, Int32(0))
        }
        guard let res = result else {
            throw failWithError()
        }

        return try validateQueryResultStatus(res)
    }

    func validateQueryResultStatus(_ res: OpaquePointer) throws -> RopeResult {
        switch PQresultStatus(res) {
        case PGRES_COMMAND_OK, PGRES_TUPLES_OK:
            return RopeResult(res)
        case PGRES_FATAL_ERROR:
            let message: String
            let code: PGErrorCode

            if let rawCodePointer = PQresultErrorField(res, 67) {
                let rawCode = String(cString: rawCodePointer)
                code = PGErrorCode(rawValue: rawCode) ?? .unknown
            } else {
                code = .unknown
            }

            if let errorMessage = PQresultErrorMessage(res) {
                message = String(cString: errorMessage)
            } else {
                message = "Unknown"
            }
            throw RopeError.fatalError(message: message, code: code)
        default:
            let message = String(cString: PQresultErrorMessage(res))
            throw RopeError.invalidQuery(message: message)
        }
    }

    private func close() throws {
        guard self.connected else {
            throw failWithError()
        }

        PQfinish(conn)
        conn = nil
    }

    private func reconnect() throws {
        if let conn = conn {
            PQreset(conn)
            let resetStatus = PQresetPoll(conn)
            switch resetStatus {
            case PGRES_POLLING_FAILED:
                throw RopeError.reconnectFailed
            case PGRES_POLLING_OK:
                print("Reconnection succeed")
            default:
                print("Unknown Status")
                break
            }
        }
    }

    private func failWithError(_ conn: OpaquePointer? = nil) -> Error {
        let message = String(cString: PQerrorMessage(conn ?? self.conn))
        return RopeError.connectionFailed(message: message)
    }
}
