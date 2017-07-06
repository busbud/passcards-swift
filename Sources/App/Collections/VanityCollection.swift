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
    let updatePassword: String?

    init(droplet: Droplet) throws {
        self.droplet = droplet
        self.apns = try droplet.vaporAPNS()
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
                return try self.droplet.view.make("welcome")
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
                return Response(status: .unauthorized)
            }

            guard let vanityName = self.parseVanityName(from: passName) else {
                return Response(status: .notFound)
            }

            guard try self.findPass(vanityName: vanityName) == nil else {
                return Response(status: .preconditionFailed)
            }

            guard let formData = request.formData,
                let authenticationToken = formData["authentication_token"]?.string,
                let passTypeIdentifier = formData["pass_type_identifier"]?.string,
                let serialNumber = formData["serial_number"]?.string,
                let passData = formData["pass"]?.data
            else {
                return Response(status: .badRequest)
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

            return Response(status: .created)
        }

        builder.put(String.self) { request, passName in
            guard self.isAuthenticated(request: request) else {
                return Response(status: .unauthorized)
            }

            guard let vanityName = self.parseVanityName(from: passName),
                var pass = try self.findPass(vanityName: vanityName)
            else {
                return Response(status: .notFound)
            }

            guard let formData = request.formData,
                let passData = formData["pass"]?.data
            else {
                return Response(status: .badRequest)
            }

            let passPath = try Storage.upload(bytes: passData, fileName: vanityName, fileExtension: "pkpass", mime: "application/vnd.apple.pkpass")
            pass.passPath = passPath
            pass.updatedAt = Date()
            try pass.save()

            let registrations = try Registration.query()
                .filter("pass_id", pass.id!)
                .run()
            let deviceTokens = registrations.flatMap { $0.deviceToken }

            let message = ApplePushMessage(priority: .energyEfficient, payload: Payload(), sandbox: false)
            self.apns.send(message, to: deviceTokens, perDeviceResultHandler: { _ in })

            return Response(status: .seeOther, headers: [.location: String(describing: request.uri)])
        }
    }
}
