import XCTest
@testable import TVCore

private struct AdapterFixture:HTTPTransport {
    let reply:HTTPReply
    func send(_ request:URLRequest) async throws -> HTTPReply { reply }
}
private struct RoutedAdapterFixture:HTTPTransport {
    let replies:[String:JSON]
    func send(_ request:URLRequest) async throws -> HTTPReply {
        guard let body = replies[request.url?.path ?? ""] else { return HTTPReply(status:404) }
        return HTTPReply(status:200,body:body.data)
    }
}
private struct SeedhubFallbackFixture:HTTPTransport {
    func send(_ request:URLRequest) async throws -> HTTPReply {
        if request.url?.host == "seed.test" { return HTTPReply(status:200,body:Data("<h1>样本</h1><div class='module-row-info'><a class='netdisk-item' href='https://pan.quark.cn/s/expired'>失效</a><a class='netdisk-item' href='https://pan.quark.cn/s/valid'>可用</a></div>".utf8)) }
        if request.url?.path.hasSuffix("token") == true {
            let body=try JSON.parse(request.httpBody!)
            if body["pwd_id"].string == "expired" { return HTTPReply(status:404,body:Data(#"{"status":404,"code":41012}"#.utf8)) }
            return HTTPReply(status:200,body:Data(#"{"status":200,"code":0,"data":{"stoken":"synthetic"}}"#.utf8))
        }
        return HTTPReply(status:200,body:Data(#"{"status":200,"code":0,"data":{"list":[{"fid":"1","file_name":"样本.mp4","share_fid_token":"synthetic"}]}}"#.utf8))
    }
}
private struct MirrorRedirectFixture:HTTPTransport {
    func send(_ request:URLRequest) async throws -> HTTPReply {
        if request.url?.host == "mirror.test" { return HTTPReply(status:302,headers:["location":"http://mirror-new.test"+request.url!.path+"?wd=sample"]) }
        return HTTPReply(status:200,body:Data("<div class='module-search-item'><a title='样本' href='/index.php/vod/detail/id/123.html'></a></div>".utf8))
    }
}
final class RemainingAdapterTests:XCTestCase {
    func testSeedhubManyResourcesCanBeChosenBeforeOpeningShares() async throws {
        let links=(1...9).map{"<li><a data-link='pan.quark.cn' href='/link_start/?redirect_to=pan_id_\($0)'>版本\($0)</a></li>"}.joined()
        let html="<h1>影片</h1><ul class='pan-links'>"+links+"</ul>"
        let source=MediaSource(id:"s",sourceID:"s",name:"聚剧",address:"csp_SeedhubGuard",kind:.seedhub,ext:.string("https://seed.test/"))
        let detail=try await SeedhubClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(html.utf8)))).detail(source,id:"/movies/1/@folder",cookie:nil)
        XCTAssertEqual(detail.resources.count,9)
        XCTAssertTrue(detail.episodes.isEmpty)
    }
    func testLibvioNetdiskDetailUsesSyncedQuarkCookie() async throws {
        let source=MediaSource(id:"l",sourceID:"s",name:"立播",address:"csp_LibvioGuard",kind:.legacySite,ext:.object(["siteUrl":.string("https://seed.test/")]))
        let detail=try await CatalogClient(transport:SeedhubFallbackFixture()).detail(source,id:"123",quarkCookie:"synthetic=local-test")
        XCTAssertEqual(detail.episodes.count,2)
        XCTAssertTrue(source.usesQuark)
        XCTAssertTrue(source.isQuarkEpisode(detail.episodes[0]))
        XCTAssertFalse(source.isQuarkEpisode(Episode(name:"旧在线线路",url:"/w/123-1-1.html")))
    }
    func testCloudMirrorExpiredShareKeepsWorkingAlternative() async throws {
        let detail=try await CloudMirrorClient(transport:SeedhubFallbackFixture()).detail(id:"https://seed.test/&123",cookie:"synthetic=local-test")
        XCTAssertEqual(detail.episodes.count,2)
    }
    func testCloudMirrorRedirectKeepsUsableDetailOrigin() async throws {
        let source=MediaSource(id:"m",sourceID:"s",name:"优汐",address:"csp_UuSsGuard",kind:.cloudMirror,ext:.object(["pturl":.string("http://mirror.test/")]))
        let rows=try await CloudMirrorClient(transport:MirrorRedirectFixture()).search(source,keyword:"sample")
        XCTAssertEqual(rows.first?.id,"http://mirror-new.test/&123")
        XCTAssertEqual(rows.first?.name,"样本")
    }
    func testSeedhubExpiredShareDoesNotHideWorkingAlternative() async throws {
        let source=MediaSource(id:"s",sourceID:"s",name:"聚剧",address:"csp_SeedhubGuard",kind:.seedhub,ext:.string("https://seed.test/"))
        let detail=try await SeedhubClient(transport:SeedhubFallbackFixture()).detail(source,id:"/movies/1/@folder",cookie:"synthetic=local-test")
        XCTAssertEqual(detail.episodes.count,2)
        XCTAssertTrue(detail.episodes.allSatisfy{$0.name == "样本.mp4"})
    }
    func testSeedhubProviderLabelDoesNotHideSharePageHref() {
        let href="/link_start/?redirect_to=pan_id_123&movie_title=sample"
        XCTAssertEqual(SeedhubClient.sharePageLink(href:href,dataLink:"pan.quark.cn"),href)
        XCTAssertEqual(SeedhubClient.sharePageLink(href:"",dataLink:"https://seedhub.example/link_start/?pan_id=1"),"https://seedhub.example/link_start/?pan_id=1")
    }

    func testKanqiuXXTEAMatchesIndependentCipherVectorAndRejectsInvalidLength() throws {
        // 由独立 xxtea 库对“补零明文 + 小端长度”加密产生，非被测代码回环。
        let hex = "05c6acac609e10911b744f780a04ccb3af09719b3d57c924d69d6970b53733779ac1576b3e4606bd559e1a78"
        let cipher = Data(stride(from:0,to:hex.count,by:2).map { i in UInt8(hex.dropFirst(i).prefix(2),radix:16)! })
        let decoded = try KanqiuClient.decrypt(cipher,key:Data("ABCDEFGHIJKLMNOPQRSTUVWX".utf8))
        XCTAssertEqual(String(decoding:decoded,as:UTF8.self), "{\"url\":\"https://example.test/live.m3u8\"}")
        XCTAssertThrowsError(try KanqiuClient.decrypt(Data([1,2,3]),key:Data("key".utf8)))
        XCTAssertThrowsError(try KanqiuClient.decrypt(cipher,key:Data("wrong key".utf8)))
    }
    func testKanqiuFollowsAndroidIDPlayerWrapper() async throws {
        let client=KanqiuClient(transport:KanqiuWrapperFixture())
        let media=try await client.resolve(.init(name:"直播",url:"https://example.test/player?id=abc%2B123&other=1",line:"一"))
        XCTAssertEqual(media.url,"https://example.test/live.m3u8")
    }
    func testKanqiuSourceEnvelopeAndDirectURLDecodeOnce() async throws {
        let source = MediaSource(id:"sports",sourceID:"c",name:"八八",address:"csp_KanqiuGuard",kind:.kanqiu,ext:.string("https://example.test"))
        let links = JSON.object(["links":.array([.object(["name":.string("线路一"),"url":.string("https://example.test/player?url=https%3A%2F%2Fcdn.example%2Flive.m3u8%3Ftoken%3Da%252Bb")])])])
        let envelope = JSON.object(["data":.string("prefix"+links.data.base64EncodedString()+"xx")])
        let client = KanqiuClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:envelope.data)))
        let detail = try await client.detail(source,id:"https://example.test/play/123")
        XCTAssertEqual(detail.episodes.count,1)
        let resolved = try await client.resolve(detail.episodes[0])
        XCTAssertEqual(resolved.url,"https://cdn.example/live.m3u8?token=a%2Bb")
    }
    func testAllLiveKeepsPlatformRoomIdentityAndQualityLines() async throws {
        let source = MediaSource(id:"live",sourceID:"c",name:"一直播",address:"csp_AllliveGuard",kind:.alllive,ext:.string("https://example.test"))
        let body = JSON.object(["data":.object(["roomId":.number("123"),"title":.string("直播间"),"stream":.array([
            .object(["name":.string("高清"),"lines":.array([.object(["name":.string("主线"),"url":.string("//cdn.example/hd.m3u8")])])]),
            .object(["name":.string("流畅"),"lines":.array([.object(["name":.string("备用"),"url":.string("https://cdn.example/sd.flv")])])])])])])
        let client = AllLiveClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:body.data)))
        let detail = try await client.detail(source,id:"bilibili_123")
        XCTAssertEqual(detail.item.id,"bilibili_123")
        XCTAssertEqual(detail.episodes.map(\.line),["高清","流畅"])
        XCTAssertEqual(detail.episodes[0].url,"https://cdn.example/hd.m3u8")
        let resolved = try await client.resolve(detail.episodes[1])
        XCTAssertTrue(resolved.useVLC)
    }
    func testAllLiveHTMLChallengeIsNotInvalidSyncOrEmptyResults() async throws {
        let source = MediaSource(id:"live",sourceID:"c",name:"一直播",address:"csp_AllliveGuard",kind:.alllive,ext:.string("https://example.test"))
        let client = AllLiveClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data("<html>访问验证</html>".utf8))))
        do { _ = try await client.browse(source);XCTFail("验证页面不能当正常目录") }
        catch { XCTAssertTrue(error.localizedDescription.contains("聚合服务"));XCTAssertFalse(error.localizedDescription.contains("同步")) }
    }
    func testMusicMinuteSignatureUsesServerTimezone() {
        XCTAssertEqual(MusicClient.minuteKey(at:Date(timeIntervalSince1970:0)),"1970010108004c44")
    }
    func testMusicHomeChallengeIsNotSuccessfulEmptyCatalog() async throws {
        let source = MediaSource(id:"music",sourceID:"c",name:"易听",address:"csp_MusicGuard",kind:.music)
        let client = MusicClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data("<title>人机验证</title>".utf8))))
        do { _ = try await client.browse(source);XCTFail("验证页不能视作首页成功") }
        catch { XCTAssertTrue(error.localizedDescription.contains("验证")) }
    }
    func testMusicCatalogAndAudioResponse() async throws {
        let source = MediaSource(id:"music",sourceID:"c",name:"易听",address:"csp_MusicGuard",kind:.music,ext:.string("https://music.example/"))
        let html = "<div class='singer_list'><ul><li><img src='/poster.jpg'><span class='name'><a href='/play/123.html'>歌曲</a></span></li></ul></div>"
        let catalog = MusicClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(html.utf8))))
        let items = try await catalog.browse(source)
        XCTAssertEqual(items.first?.id,"/play/123.html")
        let data = JSON.object(["url":.string("https://cdn.example/song.mp3")])
        let playback = MusicClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:data.data)))
        let media = try await playback.resolve(source,episode:Episode(name:"歌曲",url:"/play/123.html"))
        XCTAssertEqual(media.url,"https://cdn.example/song.mp3")
    }
    func testMusicSiteNoMatchDoesNotBecomeFabricatedResult() async throws {
        let source = MediaSource(id:"music",sourceID:"c",name:"易听",address:"csp_MusicGuard",kind:.music)
        let html = "<title>信息提示:没有找到该关键词的相关歌曲。正在返回首页!</title><p>没有找到该关键词的相关歌曲。</p>"
        let client = MusicClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(html.utf8))))
        let items = try await client.browse(source,keyword:"站点不存在的关键词")
        XCTAssertTrue(items.isEmpty)
    }
    func testMusicSearchSongListCanOpenAsDetail() async throws {
        let source = MediaSource(id:"music",sourceID:"c",name:"易听",address:"csp_MusicGuard",kind:.music,ext:.string("https://music.example/"))
        let html = "<div class='play_list'><h1>周杰伦歌曲</h1><ul><li><span class='name'><a href='/play/123.html'>晴天</a></span></li></ul></div>"
        let client = MusicClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(html.utf8))))
        let items = try await client.browse(source,keyword:"周杰伦")
        XCTAssertEqual(items.count,1)
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(item.id.hasPrefix("/so/"))
        let detail = try await client.detail(source,id:item.id)
        XCTAssertEqual(detail.episodes.first?.name,"晴天")
    }
    func testSixVMagnetsStayExplicitAndQuarkNeedsSyncedCookie() async throws {
        let source = MediaSource(id:"six",sourceID:"c",name:"新6V",address:"csp_SixVGuard",kind:.sixv,ext:.string("https://six.example/"))
        let html = "<div class='article_container'><h1>影片</h1></div><div id='post_content'><table><tr><td><a href='magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567'>原画</a></td></tr></table></div>"
        let client = SixVClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(html.utf8))))
        let detail = try await client.detail(source,id:"/movie/123.html")
        XCTAssertEqual(detail.episodes.count,1)
        XCTAssertFalse(CatalogParser.playable(detail.episodes[0].url))
        let cloud = SixVClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data("<div id='post_content'><a href='https://pan.quark.cn/s/abcdef123'>夸克</a></div>".utf8))))
        do { _ = try await cloud.detail(source,id:"/movie/123.html");XCTFail("网盘不能绕过账号状态") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Cookie")) }
    }
    func testJPJDomainConfigurationAndSpecialProtocolRemainDistinct() async throws {
        let source = MediaSource(id:"jpj",sourceID:"c",name:"荐片",address:"csp_JPJGuard",kind:.jpj,ext:.string("https://jpj.example"))
        let detail = JSON.object(["data":.object(["id":.number("123"),"title":.string("节目"),"source_list_source":.array([
            .object(["name":.string("HTTP"),"source_list":.array([.object(["source_name":.string("第一集"),"url":.string("https://cdn.example/episode.m3u8")])])]),
            .object(["name":.string("P2P"),"source_list":.array([.object(["source_name":.string("第一集"),"url":.string("tvbox-xg:ftp://peer.example/file")])])])])])])
        let client = JPJClient(transport:RoutedAdapterFixture(replies:["/api/v2/settings/resourceDomainConfig":.object(["data":.object(["imgDomain":.string("image.example")])]),"/api/video/detailv2":detail,"/api/dyTag/list":.object(["data":.object(["dataList":.array([.object(["id":.string("123"),"title":.string("Netflix影片")])])])])]))
        let category = try await client.browse(source,category:"99")
        XCTAssertEqual(category.first?.id,"123")
        let result = try await client.detail(source,id:"123")
        XCTAssertEqual(result.episodes.count,2)
        let media = try await client.resolve(source,episode:result.episodes[0])
        XCTAssertEqual(media.url,"https://cdn.example/episode.m3u8")
        do { _ = try await client.resolve(source,episode:result.episodes[1]);XCTFail("P2P不能当HTTP直链") }
        catch { XCTAssertTrue(error.localizedDescription.contains("P2P")) }
    }
    func testUtilitySourcesAreIdentifiedAndNeverRequestedAsCatalogURLs() async throws {
        let plugins = ["csp_MyDriveGuard","csp_PushGuard","csp_XPathGuard"]
        let root = JSON.object(["sites":.array(plugins.enumerated().map { .object(["key":.string(String($0.offset)),"name":.string("功能入口"),"api":.string($0.element)]) })])
        let sources = try CatalogParser.configuration(data:root.data,address:"https://example.test/config",sourceID:"c")
        XCTAssertEqual(sources.map(\.kind),[.cloudConfiguration,.pushInput,.notice])
        for source in sources {
            XCTAssertTrue(source.isUtility);XCTAssertFalse(source.supportsSearch)
            do { _ = try await CatalogClient(transport:AdapterFixture(reply:HTTPReply(status:500))).browse(source);XCTFail("功能入口不能发送影视目录请求") }
            catch { XCTAssertEqual(error.localizedDescription,source.utilityDescription) }
        }
    }
    func testAllLiveCompressedResponseRestoresRoomList() async throws {
        let encoded = "N4IgJghgLhIFygDYEsDOV4G1QCcD2eAtgJJjwCMATADQhTJSICm8IgL26C1JiLQMZ4BuTHKwAWUKAAdUcAPQymADwiEJzAHRQm6GTzUArCQHNuIAHbIeAa1PKWcEIG45LgF8Aus+dA=="
        let source = MediaSource(id:"all",sourceID:"c",name:"一直播",address:"csp_AllliveGuard",kind:.alllive,ext:.string("https://example.test/"))
        let client = AllLiveClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data(encoded.utf8))))
        let items = try await client.browse(source)
        XCTAssertEqual(items.count,1)
        XCTAssertEqual(items.first?.id,"bilibili_12")
        XCTAssertEqual(items.first?.name,"直播")
    }
    func testLZResponseRejectsTruncationInvalidAlphabetAndOversizedInput() {
        XCTAssertThrowsError(try LZStringResponse.decode("not-json<"))
        XCTAssertThrowsError(try LZStringResponse.decode("N4IgJg"))
        XCTAssertThrowsError(try LZStringResponse.decode(String(repeating:"A",count:1024*1024+1)))
    }
    func testMusicVerificationCookiesStayOnVerifiedOriginPathAndHTTPS() async throws {
        let session = MusicVerificationSession()
        let secure = HTTPCookie(properties:[.name:"verification",.value:"fixture",.domain:"music.example",.path:"/catalog",.secure:"TRUE"])!
        let foreign = HTTPCookie(properties:[.name:"foreign",.value:"fixture",.domain:"foreign.example",.path:"/"])!
        await session.install([secure,foreign],origin:URL(string:"https://music.example")!)
        let good = await session.header(for:URL(string:"https://music.example/catalog/page")!)
        let otherPath = await session.header(for:URL(string:"https://music.example/catalogue")!)
        let insecure = await session.header(for:URL(string:"http://music.example/catalog/page")!)
        let foreignHeader = await session.header(for:URL(string:"https://foreign.example/")!)
        XCTAssertEqual(good,"verification=fixture")
        XCTAssertNil(otherPath);XCTAssertNil(insecure);XCTAssertNil(foreignHeader)
    }
    func testScriptAdaptersOnlyMatchKnownRulesAndDecodeChinesePath() throws {
        let root=JSON.object(["sites":.array([
            .object(["key":.string("h"),"name":.string("虎牙"),"api":.string("https://example.test/drpy.js"),"ext":.string("https://example.test/%E8%99%8E%E7%89%99.js")]),
            .object(["key":.string("d"),"name":.string("斗鱼"),"api":.string("https://example.test/drpy.js"),"ext":.string("https://example.test/斗鱼直播.js")]),
            .object(["key":.string("unknown"),"name":.string("未知规则"),"api":.string("https://example.test/drpy.js"),"ext":.string("https://example.test/custom.js")])])])
        let sites=try CatalogParser.configuration(data:root.data,address:"https://example.test/config",sourceID:"c")
        XCTAssertEqual(sites.map(\.kind),[.streamSite,.streamSite,.unsupported])
        XCTAssertEqual(PublicStreamClient.provider(sites[0]),"huya")
    }
    func testAueteCaptchaSearchCannotBecomeSuccessfulEmptyResults() async throws {
        let source=MediaSource(id:"a",sourceID:"c",name:"奥特",address:"csp_AueteGuard",kind:.legacySite)
        let client=LegacyWebsiteClient(transport:AdapterFixture(reply:HTTPReply(status:200,body:Data("<h3>安全验证</h3><input name='validate'>".utf8))))
        do { _=try await client.browse(source,keyword:"节目");XCTFail("验证码页不能视作零搜索结果") } catch { XCTAssertTrue(error.localizedDescription.contains("验证")) }
    }
    func testHmysSignsEveryResourcePathSeparatelyAndPreservesQueryAuthorization() throws {
        let signing=try HmysSigning(query:Data("k=test&Time=123".utf8).base64EncodedString(),key:"fixture-key")
        let first=try signing.signed(URL(string:"https://cdn.example/a/index.m3u8?old=expired")!,at:1700000000)
        let second=try signing.signed(URL(string:"https://cdn.example/a/001.ts")!,at:1700000000)
        let a=URLComponents(url:first,resolvingAgainstBaseURL:false)!.queryItems!
        let b=URLComponents(url:second,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(a.first{$0.name=="Time"}?.value,"123")
        XCTAssertEqual(a.first{$0.name=="wsTime"}?.value,"6553f100")
        XCTAssertNil(a.first{$0.name=="old"})
        XCTAssertNotEqual(a.first{$0.name=="wsSecret"}?.value,b.first{$0.name=="wsSecret"}?.value)
        XCTAssertThrowsError(try HmysSigning(query:"not-authorized",key:"fixture-key"))
    }
    func testCloudMirrorFailedServersAreNotEmptySuccessfulSearch() async throws {
        let source=MediaSource(id:"m",sourceID:"c",name:"镜像",address:"csp_KkSsGuard",kind:.cloudMirror,ext:.object(["pturl":.string("https://example.test/")]))
        let client=CloudMirrorClient(transport:AdapterFixture(reply:HTTPReply(status:403)))
        do { _=try await client.search(source,keyword:"节目");XCTFail("全部失败须显示错误") } catch { XCTAssertTrue(error.localizedDescription.contains("镜像")) }
    }
}

private struct KanqiuWrapperFixture:HTTPTransport {
    func send(_ request:URLRequest) async throws -> HTTPReply {
        if request.url?.path == "/player" {
            return HTTPReply(status:200,body:Data("<script>var id='unused';var html=\"<iframe src='/inner?id=\"+id+\"'></iframe>\";</script>".utf8))
        }
        guard request.url?.path == "/inner",URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value == "abc+123" else { return HTTPReply(status:404) }
        let hex="05c6acac609e10911b744f780a04ccb3af09719b3d57c924d69d6970b53733779ac1576b3e4606bd559e1a78"
        let bytes=Data(stride(from:0,to:hex.count,by:2).map{UInt8(hex.dropFirst($0).prefix(2),radix:16)!})
        return HTTPReply(status:200,body:Data("<script>encodedStr = '\(bytes.base64EncodedString())';</script>".utf8))
    }
}
