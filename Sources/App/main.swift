import HTTP
import Storage
import Vapor

func EmptyResponse(status: Status, headers: [HeaderKey: String] = [:]) -> Response {
    var headers = headers
    if status != .notModified {
        headers[.contentType] = headers[.contentType] ?? "text/plain"
    }
    return Response(status: status, headers: headers)
}

let drop = Droplet()
drop.database = try drop.postgresDatabase()
drop.preparations = [Pass.self, Registration.self]

try drop.addProvider(StorageProvider.self)

drop.collection(WalletCollection(droplet: drop))
drop.collection(try VanityCollection(droplet: drop))

drop.get { req in
    return EmptyResponse(status: .noContent)
}

drop.run()
