import Vapor
import HTTP

public class WalletPassesNotificationService {
    
    var apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func notifyDevices(with deviceTokens: [String], about passTypeIdentifier: String) throws -> Response {
        let body = try Body(JSON(node: ["passTypeIdentifier": passTypeIdentifier, "pushTokens": try deviceTokens.makeNode()]))
        return try drop.client.post("https://walletpasses.appspot.com/api/v1/push", headers: [.contentType: "application/json", .authorization: apiKey], body: body)
    }
}

public enum WalletPassesError: Error {
    case missingAPIKey
}

public extension Droplet {
    func walletPassesNotificationService() throws -> WalletPassesNotificationService {
        guard let key = try? config.extract("app", "wpns", "key") as String else {
            throw WalletPassesError.missingAPIKey
        }
        return WalletPassesNotificationService(apiKey: key)
    }
}
