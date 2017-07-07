import HTTP
import Storage
import Vapor

func EmptyResponse(status: Status) -> Response {
    return Response(status: status, headers: [.contentType: "text/plain"])
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
