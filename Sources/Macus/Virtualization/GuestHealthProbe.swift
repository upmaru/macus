import Foundation

/// The guest helper's health request on vsock port 8444, shared by every guest driver.
enum GuestHealthProbe {
  static func fetch(_ stream: GuestStream) async throws -> GuestHealth {
    stream.socket.timeout(seconds: 2)
    do {
      let data = try await SocketIO.run {
        try stream.socket.write(
          Data("GET /health HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n".utf8))
        var result = Data()
        while true {
          let chunk = try stream.socket.read()
          if chunk.isEmpty { break }
          result.append(chunk)
          guard result.count < 1_048_576 else {
            throw RuntimeError(.unavailable, "Guest health response too large")
          }
        }
        return result
      }
      stream.socket.shutdown()
      await stream.release()
      guard let split = data.range(of: Data("\r\n\r\n".utf8)),
        String(data: data.prefix(split.lowerBound), encoding: .utf8)?.hasPrefix("HTTP/1.1 200 ")
          == true
      else {
        throw RuntimeError(.unavailable, "Incus helper is not healthy")
      }
      return try JSON.decoder().decode(GuestHealth.self, from: data.suffix(from: split.upperBound))
    } catch {
      stream.socket.shutdown()
      await stream.release()
      throw error
    }
  }
}
