import Foundation

/// The NDJSON control-line grammar both control lanes speak: `{"id", "method", "params"}` in,
/// `{"id", "ok", …}` out, one object per line.
///
/// The host's agent-control listener (`slopdesk-ctl`'s peer) and the client's control dispatcher
/// (`slopdesk`'s peer) are different verb sets over different objects, and stay that way. What they
/// are not is different GRAMMARS — a request is a line of UTF-8 JSON with a string `id` and a string
/// `method`, and anything else is dropped without a reply. Both spelled that twice, character for
/// character, along with the `sortedKeys` encode and the fallback line for a failure that cannot
/// happen.
///
/// `JSONSerialization` and `[String: Any]` rather than `Codable`: the params are whatever a verb
/// takes, the results are whatever it produces, and a type per verb on both sides of two lanes would
/// be ceremony around a dictionary that is already the wire's shape.
public enum ControlLine {
    /// Parses one NDJSON request line. `nil` is validate-then-drop: not UTF-8, not a JSON object, or
    /// `id`/`method` missing or not strings. A dropped line gets NO reply, which is the point — there
    /// is no `id` to answer to.
    public static func parseRequest(_ line: String)
        -> (id: String, method: String, params: [String: Any])?
    {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let method = obj["method"] as? String
        else { return nil }
        let params = obj["params"] as? [String: Any] ?? [:]
        return (id, method, params)
    }

    /// One response object as a line, sorted-keys, WITHOUT the newline — a caller that frames its own
    /// lines adds it, and the two lanes disagreed about whether it was included.
    ///
    /// The fallback is a valid error line rather than an empty string: a client parsing NDJSON must
    /// get an object back or it will treat the connection as broken, and "the encoder refused a
    /// dictionary it built itself" is not a reason to hang up on it.
    public static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8)
        else { return #"{"ok":false,"error":"json encode failure"}"# }
        return text
    }

    /// The object an error reply is made of. Serialising it is the caller's, because one lane frames
    /// with a trailing newline here and the other adds it at the socket.
    public static func error(id: String, message: String) -> [String: Any] {
        ["id": id, "ok": false, "error": message]
    }
}
