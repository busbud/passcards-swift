import FormData
import Foundation
import HTTP
import Routing
import Storage
import Vapor
import VaporAPNS

private extension Field {
    var data: Bytes {
        return part.body
    }

    var string: String? {
        return try? String(bytes: part.body)
    }
}

final class VanityCollection: RouteCollection {
    typealias Wrapped = HTTP.Responder

    let droplet: Droplet
    let apns: VaporAPNS
    let wpns: WalletPassesNotificationService
    let updatePassword: String?

    init(droplet: Droplet) throws {
        self.droplet = droplet
        self.apns = try droplet.vaporAPNS()
        self.wpns = try droplet.walletPassesNotificationService()
        self.updatePassword = try drop.config.extract("app", "updatePassword") as String?
    }

    func isAuthenticated(request: Request) -> Bool {
        guard let updatePassword = updatePassword else {
            // No password = always authenticated
            return true
        }

        if let authorization = request.headers[.authorization] {
            return authorization == "Bearer \(updatePassword)"
        } else {
            return false
        }
    }

    func findPass(vanityName: String) throws -> Pass? {
        return try Pass.query()
            .filter("vanity_name", vanityName)
            .first()
    }

    func parseVanityName(from fileName: String) -> String? {
        if let suffixRange = fileName.range(of: ".pkpass", options: [.anchored, .backwards, .caseInsensitive]) {
            return fileName[fileName.startIndex ..< suffixRange.lowerBound]
        } else {
            return nil
        }
    }

    func build<B: RouteBuilder>(_ builder: B) where B.Value == Wrapped {
        builder.get(String.self) { request, passName in
            guard let vanityName = self.parseVanityName(from: passName),
                let pass = try self.findPass(vanityName: vanityName),
                let passPath = pass.passPath
            else {
                return EmptyResponse(status: .notFound)
            }

            let updatedAt = pass.updatedAt ?? Date()
            let headers: [HeaderKey: String] = [
                .contentType: "application/vnd.apple.pkpass",
                .lastModified: rfc2616DateFormatter.string(from: updatedAt),
            ]
            let passBytes = try Storage.get(path: passPath)
            return Response(status: .ok, headers: headers, body: .data(passBytes))
        }

        builder.post(String.self) { request, passName in
            guard self.isAuthenticated(request: request) else {
                return EmptyResponse(status: .unauthorized)
            }

            guard let vanityName = self.parseVanityName(from: passName) else {
                return EmptyResponse(status: .notFound)
            }

            guard try self.findPass(vanityName: vanityName) == nil else {
                return EmptyResponse(status: .preconditionFailed)
            }

            guard let formData = request.formData,
                let authenticationToken = formData["authentication_token"]?.string,
                let passTypeIdentifier = formData["pass_type_identifier"]?.string,
                let serialNumber = formData["serial_number"]?.string,
                let passData = formData["pass"]?.data
            else {
                return EmptyResponse(status: .badRequest)
            }

            let passPath = try Storage.upload(bytes: passData, fileName: vanityName, fileExtension: "pkpass", mime: "application/vnd.apple.pkpass")

            var pass = Pass()
            pass.vanityName = vanityName
            pass.authenticationToken = authenticationToken
            pass.serialNumber = serialNumber
            pass.passTypeIdentifier = passTypeIdentifier
            pass.passPath = passPath
            pass.updatedAt = Date()
            try pass.save()

            return EmptyResponse(status: .created)
        }

        builder.put(String.self) { request, passName in
            guard self.isAuthenticated(request: request) else {
                return EmptyResponse(status: .unauthorized)
            }

            guard let vanityName = self.parseVanityName(from: passName),
                var pass = try self.findPass(vanityName: vanityName)
            else {
                return EmptyResponse(status: .notFound)
            }

            guard let formData = request.formData,
                let passData = formData["pass"]?.data
            else {
                return EmptyResponse(status: .badRequest)
            }

            let passPath = try Storage.upload(bytes: passData, fileName: vanityName, fileExtension: "pkpass", mime: "application/vnd.apple.pkpass")
            pass.passPath = passPath
            pass.updatedAt = Date()
            try pass.save()
            
            try self.sendNotifications(about: pass)
            
            return Response(status: .seeOther,
                            headers: [.location: String(describing: request.uri),
                                      .contentType: "application/vnd.apple.pkpass"])
        }
    }
    
    func sendNotifications(about pass: Pass) throws {
        
        let registrations = try Registration.query()
            .filter("pass_id", pass.id!)
            .run()
        
        var deviceTokensByClientApp: [Registration.Client: [String]] = [:]
        registrations.forEach { (reg) in
            let clientApp = reg.clientApp ?? .appleWallet
            deviceTokensByClientApp[clientApp] = (deviceTokensByClientApp[clientApp] ?? []) + [reg.deviceToken!]
        }
        
        drop.log.info("Notifying \(registrations.count) \(registrations.count == 1 ? "device" : "devices").")
        
        for (clientApp, deviceTokens) in deviceTokensByClientApp {
            try notifyDevices(with: deviceTokens, running: clientApp, about: pass.passTypeIdentifier!)
        }
    }
    
    func notifyDevices(with deviceTokens: [String], running clientApp: Registration.Client, about passTypeIdentifier: String) throws {
        
        switch clientApp {
        case .appleWallet:
            let message = ApplePushMessage(topic: passTypeIdentifier, priority: .immediately, payload: Payload(), sandbox: false)
            self.apns.send(message, to: deviceTokens) { result in
                switch result {
                case .success(_, _, let serviceStatus):
                    drop.log.info("APNS: \(serviceStatus)")
                case .networkError(let error):
                    drop.log.error("APNS: \(error)")
                case .error(_, _, let error):
                    drop.log.error("APNS: \(error)")
                }
            }
        case .walletPasses:
            let response = try wpns.notifyDevices(with: deviceTokens, about: passTypeIdentifier)
            if response.status.statusCode >= 300 {
                drop.log.error("WPNS: \(response)")
            } else {
                drop.log.info("WPNS: \(response.status)")
            }
        }
    }
}
