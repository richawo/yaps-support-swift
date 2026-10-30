import Foundation

/// Server → client socket frames (§4). Unknown `t` values decode to `.unknown` and are ignored.
enum ServerFrame: Sendable, Equatable {
    case welcome(conversationId: String?, lastSeq: Int)
    case message(Message)
    case update(Message)
    case ack(cid: String, message: Message)
    case state(agentTyping: Bool?, agentReadSeq: Int?, customerReadSeq: Int?)
    case error(code: String, cid: String?, message: String?)
    case pong
    case unknown(String)

    private struct Envelope: Decodable {
        var t: String
    }

    private struct Welcome: Decodable { var conversationId: String?; var lastSeq: Int? }
    private struct MessageFrame: Decodable { var m: Message }
    private struct Ack: Decodable { var cid: String; var m: Message }
    private struct State: Decodable { var agentTyping: Bool?; var agentReadSeq: Int?; var customerReadSeq: Int? }
    private struct Err: Decodable { var code: String; var cid: String?; var message: String? }

    static func decode(_ data: Data, decoder: JSONDecoder = WireJSON.decoder()) throws -> ServerFrame {
        let type = try decoder.decode(Envelope.self, from: data).t
        switch type {
        case "welcome":
            let f = try decoder.decode(Welcome.self, from: data)
            return .welcome(conversationId: f.conversationId, lastSeq: f.lastSeq ?? 0)
        case "msg":
            return .message(try decoder.decode(MessageFrame.self, from: data).m)
        case "upd":
            return .update(try decoder.decode(MessageFrame.self, from: data).m)
        case "ack":
            let f = try decoder.decode(Ack.self, from: data)
            return .ack(cid: f.cid, message: f.m)
        case "state":
            let f = try decoder.decode(State.self, from: data)
            return .state(agentTyping: f.agentTyping, agentReadSeq: f.agentReadSeq, customerReadSeq: f.customerReadSeq)
        case "err":
            let f = try decoder.decode(Err.self, from: data)
            return .error(code: f.code, cid: f.cid, message: f.message)
        case "pong":
            return .pong
        default:
            return .unknown(type)
        }
    }
}

/// Client → server socket frames (§4).
enum ClientFrame: Sendable, Equatable {
    case hello(after: Int)
    case send(cid: String, text: String?, attachments: [String]?)
    case read(seq: Int)
    case typing(on: Bool)
    case ping

    func encoded() -> Data {
        var object: [String: Any]
        switch self {
        case .hello(let after):
            object = ["t": "hello", "after": after]
        case .send(let cid, let text, let attachments):
            object = ["t": "send", "cid": cid]
            if let text { object["text"] = text }
            if let attachments, !attachments.isEmpty { object["att"] = attachments }
        case .read(let seq):
            object = ["t": "read", "seq": seq]
        case .typing(let on):
            object = ["t": "typing", "on": on]
        case .ping:
            object = ["t": "ping"]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
