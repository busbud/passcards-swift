import Vapor
import VaporAPNS

extension Droplet {
    func vaporAPNS() throws -> VaporAPNS {
        let apns = try config.extract("app", "apns") as Config
        let teamID = try apns.extract("teamID") as String
        let keyID = try apns.extract("keyID") as String
        let rawPrivateKey = try apns.extract("privateKey") as String
        guard let (privateKey, publicKey) = ECKeys(from: rawPrivateKey) else {
            throw TokenError.invalidAuthKey
        }

        // Topic should be set by each message to be the pass' type identifier (e.g. pass.com.example.ticket)
        let options = try Options(topic: "", teamId: teamID, keyId: keyID, rawPrivKey: privateKey, rawPubKey: publicKey)
        return try VaporAPNS(options: options)
    }
}
