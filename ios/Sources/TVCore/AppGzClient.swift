import Foundation
import CryptoKit
import Security

/// 瓜子当前 Android 插件的 RSA 信封/AES 表单协议。
/// 下列 RSA 材料来自发布插件的固定 SDK 协议，不是用户的账号密钥。
public actor AppGzClient {
    public static let shared = AppGzClient()
    public static let categories=[(id:"1",name:"电影"),(id:"2",name:"电视剧"),(id:"4",name:"动漫"),(id:"3",name:"综艺")]
    private static let publicDER = Data(base64Encoded: "MIGJAoGBANQzn7/Lyw+xaR3X9FBLrhfbn0RTDEVcUTkeUDrkyqvGc+zQmqhJGiNIPLlCHC9E6VoPpPBFAcoxjY4BnpKdB5QmwKFMQUhH2pSTCuzf8xVQzGOy/olLo57+O5yXIkZOBWYOEHnkRp9ewPRJBhWP9BdezFHp7BHkTaQvnbIAAPjJAgMBAAE=")!
    private static let privateDER = Data(base64Encoded: "MIICXAIBAAKBgHuoSq1i4tc0Jo009aM2xOEHRXiRjcbm8ZXehqxRsYpsXzLDAegaSYaXE6LgKssABaaYinrVAQW18GLGFNcDa+uPF1Zj5gjAsuK2PL3ZYhZ2zFI9POg1Omfv6FwXVlN/29RtAzdxPcFC0UsHCmU98I/3AiNb7Apt4I9keUqpAPWNAgMBAAECgYACR/uAsVdP8wVXC4gQh70gDZtJex3rcm04f49qdGNbE166OAC8AGgk1HqnQY1oi0qPZTcAxxcqvM1/dPoDcWu3ORKnFlfRZpVV6/FYXwc3GaNZ13jXVxU+7UNsmof6HbXXMfr0TEhiXdbf+ZOWw3fcAL2HSA25TAIPsIiimeSnHQJBANXAmpBDeDXsZBebRz0a0elzmP1x35Kl8RITKpjWwfVN+LGkyZy1iBwvCF8rOkJs899E7cwo7jqikUcvhTDOE3cCQQCUGRT47BgvkanBuVL1TIjD4Z8Hv21xHoUoSvOsiSv4P1IiqzvO4d2hLuYHCagcoE6twQQaB9pnd6a/1voVDFgbAkEAoX4UyK3Q4pyoupUca3QZ59DoY4NnMLqiuc81PafzfkvcewpPMFCOdwypvI1CRPFgBu1i4/6AjlhIfonOjSME3QJBAI9F/J4cegF7IAmEapdZJW6rVZi/PveSmSuz5y1hvyH40FMt6TxqEmme33arhvG6vKMn+fnc4xP6E13Ackvul0UCQD/+XIstWy9zYVIbGjlcueTB15z43XE19BWi4vsm12SHyENj+K29fZlatX3jGwl4c/i9axvKGreZWCn6XvJPN2Q=")!
    public let transport: any HTTPTransport
    private var token=""
    private let device=UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private func registration() -> (String,String) {
        func hash(_ value:String)->Int32 { value.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) } }
        func bytes(_ value:UInt32)->Data { var x=value.bigEndian;return withUnsafeBytes(of:&x){Data($0)} }
        var data=bytes(UInt32(truncatingIfNeeded:SyncDocument.now/1000))+bytes(UInt32.random(in:0...UInt32.max))+Data([3,0])+bytes(UInt32(bitPattern:hash(device)))
        let key=SymmetricKey(data:Data("d6fc3a4a06adbde89223bvefedc24fecde188aaa9161".utf8))
        let hmac=Data(HMAC<Insecure.SHA1>.authenticationCode(for:data,using:key)).base64EncodedString()
        data.append(bytes(UInt32(bitPattern:hash(hmac))))
        let old=data.base64EncodedString(),new=Self.hex(Data(Insecure.SHA1.hash(data:Data(device.utf8))))
        return (old,new)
    }
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    private static func hex(_ data:Data)->String { data.map{String(format:"%02X",$0)}.joined() }
    private static func md5(_ value:String)->String { hex(Data(Insecure.MD5.hash(data:Data(value.utf8)))) }
    private static func rsa(_ data:Data,encrypt:Bool) throws -> Data {
        let attrs:[CFString:Any]=[kSecAttrKeyType:kSecAttrKeyTypeRSA,kSecAttrKeyClass:encrypt ? kSecAttrKeyClassPublic:kSecAttrKeyClassPrivate,kSecAttrKeySizeInBits:1024]
        var error:Unmanaged<CFError>?
        guard let key=SecKeyCreateWithData((encrypt ? publicDER:privateDER) as CFData,attrs as CFDictionary,&error) else { throw TVError.message("瓜子协议密钥初始化失败") }
        let size=encrypt ? 117:128
        var output=Data()
        for start in stride(from:0,to:data.count,by:size) {
            let block=data.subdata(in:start..<min(data.count,start+size))
            let result=encrypt ? SecKeyCreateEncryptedData(key,.rsaEncryptionPKCS1,block as CFData,&error):SecKeyCreateDecryptedData(key,.rsaEncryptionPKCS1,block as CFData,&error)
            guard let result else { throw TVError.message("瓜子协议信封解密失败") };output.append(result as Data)
        }
        return output
    }
    private func request(_ path:String,body:JSON) async throws -> JSON {
        let key=String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(16)),iv=String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(16))
        let keys=try Self.rsa(JSON.object(["key":.string(key),"iv":.string(iv)]).data,encrypt:true).base64EncodedString()
        let encrypted=try Self.hex(AppSxClient.crypt(body.data,key:Data(key.utf8),iv:Data(iv.utf8),encrypt:true))
        let now=String(SyncDocument.now/1000)
        let signature=Self.md5("token_id=,token="+token+",phone_type=1,request_key="+encrypted+",app_id=1,time="+now+",keys="+keys+"*&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br")
        let params=["token":token,"token_id":"","phone_type":"1","time":now,"phone_model":"apple-iphone","keys":keys,"request_key":encrypted,"signature":signature,"app_id":"1","ad_version":"1"]
        var form=URLComponents();form.queryItems=params.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        var req=URLRequest(url:URL(string:"https://api.gjjwgp3n.com/App/"+path)!);req.httpMethod="POST";req.httpBody=Data((form.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8)
        req.allHTTPHeaderFields=["Ver":"3.0.4.0", "code":"GZ0001", "PackageName":"com.r3ac892153.q1ed27199a.wf930fc6bf20260401", "Version":"2603002", "Referer":"https://api.gjjwgp3n.com", "User-Agent":"okhttp/3.12.0", "api-ver":"3.0.4.0", "Content-Type":"application/x-www-form-urlencoded"]
        let reply=try await transport.send(req);guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        let envelope=try JSON.parse(reply.body)["data"]
        guard let bytes=Data(base64Encoded:envelope["keys"].string) else { throw TVError.message("瓜子接口未返回加密信封") }
        let secret=try JSON.parse(Self.rsa(bytes,encrypt:false)),text=envelope["response_key"].string.replacingOccurrences(of:"\\",with:"")
        guard text.count%2==0,text.allSatisfy(\.isHexDigit) else { throw TVError.message("瓜子响应格式无效") }
        let chars=Array(text.utf8);var cipher=Data()
        for start in stride(from:0,to:chars.count,by:2) { guard let byte=UInt8(String(decoding:chars[start..<start+2],as:UTF8.self),radix:16) else { throw TVError.message("瓜子响应格式无效") };cipher.append(byte) }
        return try JSON.parse(AppSxClient.crypt(cipher,key:Data(secret["key"].string.utf8),iv:Data(secret["iv"].string.utf8),encrypt:false))
    }
    private func initialize() async throws {
        guard token.isEmpty else { return }
        let (old,new)=registration()
        let root=try await request("Authentication/Device/signUp",body:.object(["old_key":.string(old),"new_key":.string(new),"phone_type":.integer(1),"code":.string("")]))
        guard !root["token"].string.isEmpty else { throw TVError.message("瓜子匿名客户端初始化失败") };token=root["token"].string
    }
    private static func text(_ x:JSON)->String { x.string.isEmpty ? String(x.int):x.string }
    private static func item(_ x:JSON)->MediaItem? {
        let id=text(x["vod_id"]),name=x["vod_name"].string.isEmpty ? x["c_name"].string:x["vod_name"].string
        guard !id.isEmpty,id != "0",!name.isEmpty else { return nil }
        return MediaItem(id:id,name:name,picture:x["vod_pic"].string.isEmpty ? x["c_pic"].string:x["vod_pic"].string,remarks:x["vod_title"].string.isEmpty ? x["new_continue"].string:x["vod_title"].string)
    }
    public func browse(keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        try await initialize();let rows:[JSON]
        if !keyword.isEmpty {
            guard page==1 else { return [] }
            rows=try await request("Index/findMoreVod",body:.object(["keywords":.string(keyword),"order_val":.string("1")]))["list"].array
        } else if !category.isEmpty {
            rows=try await request("IndexList/indexList",body:.object(["tid":.string(category),"page":.string(String(page)),"pageSize":.string("20"),"sort":.string("d_id"),"sub":.string(""),"class":.string(""),"area":.string(""),"year":.string("")]))["list"].array
        } else {
            guard page==1 else { return [] }
            let modules=try await request("IndexList/index",body:.object(["pid":.string("1")]))["list"].array
            rows=modules.filter { $0["type"].string.contains("热门推荐") }.flatMap { $0["list"].array }
        }
        var seen=Set<String>();return rows.compactMap(Self.item).filter{seen.insert($0.id).inserted}
    }
    public func detail(id:String) async throws -> MediaDetail {
        try await initialize()
        let row=try await request("IndexPlay/playInfo",body:.object(["vod_id":.string(id),"token_id":.string(""),"mobile_time":.string(String(SyncDocument.now/1000)),"token":.string(token)]))["vodInfo"]
        guard let item=Self.item(row) else { throw TVError.message("瓜子未返回影片详情") }
        let lines=try await request("Resource/Vurl/show",body:.object(["vurl_cloud_id":.string("2"),"vod_d_id":.string(id)]))["list"].array
        let episodes=lines.flatMap { entry in ["1080","720","480"].compactMap { quality -> Episode? in
            let param=entry["play"][quality]["param"].string
            return param.isEmpty ? nil:Episode(name:entry["title"].string,url:param,line:quality+"P")
        } }
        return MediaDetail(item:item,episodes:episodes,synopsis:row["vod_content"].string)
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        try await initialize()
        let param=episode.url,parts=URLComponents(string:"https://example.invalid/?"+param)?.queryItems ?? []
        func value(_ name:String)->String { parts.first{$0.name==name}?.value ?? "" }
        let body=JSON.object(["domain_type":.string(value("domain_type")),"vod_id":.string(value("vod_d_id")),"type":.string(value("type")),"resolution":.string(value("resolution")),"vurl_id":.string(value("vurl_id"))])
        guard !value("vod_d_id").isEmpty,!value("vurl_id").isEmpty else { throw TVError.message("瓜子选集参数无效") }
        let row=try await request("Resource/VurlDetail/showOne",body:body)
        guard CatalogParser.validHTTP(row["url"].string) else { throw TVError.message("瓜子未返回可播放地址，可能需要重新授权") }
        return ResolvedMedia(url:row["url"].string,headers:["User-Agent":"Lavf/57.83.100"])
    }
}
