import XCTest
@testable import TVCore

private actor LoginFixture: HTTPTransport {
    var polls = 0
    func send(_ request: URLRequest) async throws -> HTTPReply {
        if request.url?.host == "drive.uc.cn" {
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            XCTAssertTrue(request.url!.query!.contains("st="))
            return HTTPReply(status:200,body:JSON.object(["data":.object(["__pus":.string("uc-only"),"serviceTicket":.string("synthetic-ticket")])]).data)
        }
        XCTAssertEqual(request.url?.host,"api.open.uc.cn")
        XCTAssertEqual(request.httpMethod,"POST")
        let form=String(decoding:request.httpBody!,as:UTF8.self)
        XCTAssertTrue(form.contains("client_id=381"));XCTAssertTrue(form.contains("request_id=test"))
        var data:JSON = .object([:])
        if request.url!.path.hasSuffix("getTokenForQrcodeLogin") { data = .object(["token":.string("test+token")]) }
        else {
            XCTAssertTrue(form.contains("token=test%2Btoken"))
            polls += 1
            if polls > 1 { data = .object(["service_ticket":.string("approved")]) }
        }
        return HTTPReply(status:200,body:JSON.object(["data":.object(["members":data])]).data)
    }
}
final class CloudLoginTests:XCTestCase {
    func testUCQRCodePendingApprovalAndCredentialExchange() async throws {
        let client=UCLoginClient(transport:LoginFixture(),requestID:"test")
        let token=try await client.token();XCTAssertEqual(token,"test+token")
        let url=UCLoginClient.qrURL(token:token)
        XCTAssertEqual(url.host,"broccoli.uc.cn")
        XCTAssertEqual(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="token"}?.value,token)
        let pending=try await client.poll(token:token);XCTAssertNil(pending)
        let approved=try await client.poll(token:token);XCTAssertEqual(approved,"approved")
        let account=try await client.account(ticket:approved!)
        XCTAssertEqual(account.cookie,"__pus=uc-only");XCTAssertEqual(account.serviceTicket,"synthetic-ticket")
    }
    func testFreshAccountIsEncodedForAndroidAndReadableOnIOS() throws {
        let credentials=CloudLoginCredentials(cookie:"__pus=synthetic; __puus=test-only")
        let value=try SyncedQuarkAccount.loginValue(in:SyncDocument(),drive:.quark,credentials:credentials)
        XCTAssertEqual(value["files"],.object([:]));XCTAssertEqual(value["defaults"],.object([:]))
        XCTAssertEqual(value["prefs"]["quark_ck"].string,"sbaP0PpKcE8T7fZQxofRvvenqSve282z0z4hadT2FRZR")
        var replica=Replica();replica.edit(id:SyncDocument.identity("cloudAccount","catvod-sp-utils-v1"),kind:"cloudAccount",value:value,device:"test")
        XCTAssertEqual(try SyncedQuarkAccount.cookie(in:replica.document),credentials.cookie)
    }
    func testLoginKeepsOtherDriveAndUnknownPluginFields() throws {
        let id=SyncDocument.identity("cloudAccount","catvod-sp-utils-v1")
        var replica=Replica()
        replica.edit(id:id,kind:"cloudAccount",value:.object(["adapter":.string("catvod-sp-utils-v1"),"prefs":.object(["quark_ck":.string("__pus=keep"),"uc_ck":.string("__pus=old"),"ucSt":.string("old-ticket"),"hide_appgz_token":.string("keep")]),"defaults":.object(["uc_ck":.string("__pus=stale"),"ucSt":.string("stale-ticket")]),"files":.object(["ali_info":.string("dGVzdA==")])]),device:"test")
        let value=try SyncedQuarkAccount.loginValue(in:replica.document,drive:.uc,credentials:.init(cookie:"__pus=new",serviceTicket:"new-ticket"))
        XCTAssertEqual(value["prefs"]["quark_ck"].string,"__pus=keep")
        XCTAssertEqual(value["prefs"]["hide_appgz_token"].string,"keep")
        XCTAssertEqual(value["files"]["ali_info"].string,"dGVzdA==")
        XCTAssertEqual(value["prefs"]["ucSt"].string,"new-ticket")
        XCTAssertEqual(value["defaults"]["uc_ck"],.null);XCTAssertEqual(value["defaults"]["ucSt"],.null)
        XCTAssertEqual(try App99Crypto.decodePluginText(value["prefs"]["uc_ck"].string),"__pus=new")
    }
    func testDeletedAccountAndMissingTicketCannotResurrectOldLogin() throws {
        var replica=Replica();let id=SyncDocument.identity("cloudAccount","catvod-sp-utils-v1")
        replica.edit(id:id,kind:"cloudAccount",value:nil,device:"test")
        let value=try SyncedQuarkAccount.loginValue(in:replica.document,drive:.uc,credentials:.init(cookie:"__pus=new"))
        XCTAssertEqual(value["prefs"]["ucSt"],.null)
        XCTAssertEqual(value["prefs"]["quark_ck"],.null)
        XCTAssertEqual(try App99Crypto.decodePluginText(value["prefs"]["uc_ck"].string),"__pus=new")
        XCTAssertThrowsError(try SyncedQuarkAccount.loginValue(in:replica.document,drive:.uc,credentials:.init(cookie:"__pus=x\r\nInjected:1")))
    }
    func testCASHTTPChunkedAndTruncatedResponses() throws {
        let reply=try UCLoginWire.decode(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntrue\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(reply.status,200);XCTAssertEqual(reply.body,Data("true".utf8))
        for raw in ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nx","HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n","HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nx"] { XCTAssertThrowsError(try UCLoginWire.decode(Data(raw.utf8))) }
    }
}
