import XCTest
@testable import TVCore

private struct NativeFixture: HTTPTransport {
    let reply: @Sendable (URLRequest) throws -> HTTPReply
    func send(_ request:URLRequest) async throws -> HTTPReply { try reply(request) }
}
final class NativeCatalogTests:XCTestCase {
    func testTrailerSearchExcludesGlobalHotList() async throws {
        let source=MediaSource(id:"y",sourceID:"s",name:"预告",address:"csp_YGPGuard",kind:.website)
        let client=WebsiteClient(transport:NativeFixture { _ in HTTPReply(status:200,body:Data("<div class='movlist'><ul><li><a href='/movie/hot'><span title='无关热榜'>热榜</span></a></li></ul></div><h1 class='tabs-title'>搜索电影</h1><div class='movlist'><ul><li><a href='/movie/match'><span title='匹配影片'>匹配</span></a></li></ul></div>".utf8)) })
        let items=try await client.browse(source,keyword:"匹配")
        XCTAssertEqual(items.map(\.name),["匹配影片"])
    }
    func testCloudSearchExplicitZeroTotalIsNotMalformedData() async throws {
        let source=MediaSource(id:"s",sourceID:"s",name:"盘搜",address:"csp_S_zpsGuard",kind:.cloudSearch,ext:.object([:]))
        let client=CloudSearchClient(transport:NativeFixture { _ in HTTPReply(status:200,body:Data(#"{"code":0,"data":{"total":0}}"#.utf8)) })
        let result=try await client.search(source,keyword:"不存在的片名")
        XCTAssertTrue(result.isEmpty)
        let invalid=CloudSearchClient(transport:NativeFixture { _ in HTTPReply(status:200,body:Data(#"{"code":0,"data":{}}"#.utf8)) })
        do { _=try await invalid.search(source,keyword:"片名");XCTFail("缺少总数不能当成无结果") } catch { }
    }
    func testDm84ReadsBootstrapFromCurrentPlayerIframe() async throws {
        let source=MediaSource(id:"dm",sourceID:"s",name:"巴士",address:"csp_Dm84Guard",kind:.website)
        let client=WebsiteClient(transport:NativeFixture { request in
            if request.url?.host == "dmbus.cc" { return HTTPReply(status:200,body:Data("<iframe src='https://hhjx.hhplayer.com/?url=opaque'></iframe>".utf8)) }
            if request.url?.path == "/api/parse" {
                let payload=try JSON.parse(request.httpBody!)
                XCTAssertEqual(payload["key"].string,"sample-key")
                XCTAssertEqual(payload["t"].int,123)
                return HTTPReply(status:200,body:Data(#"{"url":"https://cdn.example/episode.m3u8"}"#.utf8))
            }
            return HTTPReply(status:200,body:Data(#"<script>window.__HHJX_BOOTSTRAP__ = {"url":"opaque","t":123,"key":"sample-key"};</script>"#.utf8))
        })
        let media=try await client.resolve(source,episode:Episode(name:"1",url:"/play/1.html"))
        XCTAssertEqual(media.url,"https://cdn.example/episode.m3u8")
    }
    func testChildrenJSONPAllowsTrailingSemicolonAndMarketingHomeFallsBack() async throws {
        let source = MediaSource(id:"kids",sourceID:"c",name:"儿童",address:"script",kind:.streamSite,ext:.string("https://example.test/兔小贝.js"))
        let client = PublicStreamClient(transport:NativeFixture { request in
            let text = request.url!.path == "/" ? "<title>兔小贝APP</title><div class='appInstallButton'>下载</div>" : "({\"status\":200,\"data\":{\"items\":[{\"video_id\":123,\"name\":\"儿歌\",\"image\":\"\",\"duration_string\":\"02:00\"}]}});"
            return HTTPReply(status:200,body:Data(text.utf8))
        })
        let category = try await client.browse(source,category:"2")
        XCTAssertEqual(category.first?.name,"儿歌")
        let home = try await client.browse(source)
        XCTAssertEqual(home.first?.id,"123")
    }
    func testPluginUnicodeConfigurationDecodesWithoutLosingCategories() throws {
        let decoded=try App99Crypto.configuration(.string("rfOIzPkSUkANv6AT2prC8aD6+WjO1tvj1zczL43gEA4bdEYQvW9krKRzc+NLx99vriLVQoLGPruyMroyXL6p4h8SOVQDpa7yc7A="))
        XCTAssertEqual(decoded["categories"].array.map(\.string),["电影","电视剧"])
        XCTAssertEqual(decoded["siteUrl"].string,"https://example.test/api")
    }
    func testAppSxEncryptedHomeSearchAndDetailUseNativeProtocol() async throws {
        let key=Data("0123456789abcdef".utf8)
        let client=AppSxClient(transport:NativeFixture { req in
            XCTAssertEqual(req.value(forHTTPHeaderField:"app-version-code"),"113")
            let root:JSON
            if req.url!.path.hasSuffix("initV119") { root = .object(["type_list":.array([.object(["type_id":.integer(1),"type_name":.string("电影")])]),"recommend_list":.array([.object(["vod_id":.integer(7),"vod_name":.string("示例")])])]) }
            else if req.url!.path.hasSuffix("searchList") { root = .object(["search_list":.array([.object(["vod_id":.integer(8),"vod_name":.string("搜索结果")])])]) }
            else { root = .object(["vod":.object(["vod_id":.integer(7),"vod_name":.string("示例")]),"vod_play_list":.array([.object(["player_info":.object(["show":.string("原线路"),"parse_type":.string("0")]),"urls":.array([.object(["name":.string("第1集"),"url":.string("https://cdn.example/a.m3u8"),"parse_api_url":.string("https://cdn.example/a.m3u8")])])])])]) }
            let cipher=try AppSxClient.crypt(root.data,key:key,iv:key,encrypt:true)
            return HTTPReply(status:200,body:JSON.object(["data":.string(cipher.base64EncodedString())]).data)
        })
        let source=MediaSource(id:"s",sourceID:"c",name:"剧圈",address:"csp_AppSxGuard",kind:.appsx,ext:.object(["host":.string("https://example.test"),"key":.string("0123456789abcdef")]))
        let home=try await client.browse(source);XCTAssertEqual(home.first?.name,"示例")
        let search=try await client.browse(source,keyword:"搜索");XCTAssertEqual(search.first?.id,"8")
        let detail=try await client.detail(source,id:"7");XCTAssertEqual(detail.episodes.first?.line,"原线路")
        let media=try await client.resolve(source,episode:detail.episodes[0]);XCTAssertEqual(media.url,"https://cdn.example/a.m3u8")
    }
    func testBiliUsesAndroidCompositeIDsAndAcceptsAndroidEpisodeLinks() async throws {
        let items=BiliClient.items(.array([.object(["bvid":.string("BVtest"),"aid":.integer(123),"title":.string("标题")])]))
        XCTAssertEqual(items.first?.id,"BVtest@123")
        let client=BiliClient(transport:NativeFixture { req in
            let query=URLComponents(url:req.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "avid" }?.value,"123")
            XCTAssertEqual(query.first { $0.name == "cid" }?.value,"456")
            return HTTPReply(status:200,body:Data(#"{"code":0,"data":{"durl":[{"url":"https://cdn.example/v.mp4"}]}}"#.utf8))
        })
        _=try await client.resolve(Episode(name:"集数",url:"123+456+64"))
    }
    func testT4PreservesEndpointQueryAndCategory() async throws {
        let client=T4Client(transport:NativeFixture { req in
            let query=URLComponents(url:req.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
            XCTAssertEqual(query.filter { $0.name == "ac" }.count,1)
            XCTAssertEqual(query.first { $0.name == "ac" }?.value,"detail")
            XCTAssertEqual(query.first { $0.name == "t" }?.value,"5")
            XCTAssertEqual(query.first { $0.name == "pg" }?.value,"2")
            XCTAssertEqual(query.first { $0.name == "scope" }?.value,"public")
            return HTTPReply(status:200,body:Data(#"{"list":[{"vod_id":1,"vod_name":"电影"}]}"#.utf8))
        })
        let source=MediaSource(id:"s",sourceID:"c",name:"T4",address:"csp_T4Guard",kind:.t4,ext:.object(["siteUrl":.string("https://example.test/api?ac=list&scope=public"),"type":.integer(1)]))
        let result=try await client.browse(source,page:2,category:"5");XCTAssertEqual(result.first?.id,"1")
    }
    func testAppTTParserMetadataSurvivesEpisodeSerialization() async throws {
        let client=AppTTClient(transport:NativeFixture { req in
            XCTAssertEqual(req.httpMethod,"POST")
            XCTAssertTrue(req.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data") == true)
            let body=String(data:req.httpBody!,encoding:.utf8)!
            XCTAssertTrue(body.contains("name=\"sign\""));XCTAssertTrue(body.contains("name=\"vod_id\""))
            return HTTPReply(status:200,body:Data(#"{"data":{"vod_id":7,"vod_name":"电影","vod_play_list":[{"flag":"线路一","parse_urls":[],"urls":[{"name":"第一集","url":"https://cdn.example/1.m3u8"}]}]}}"#.utf8))
        })
        let source=MediaSource(id:"s",sourceID:"c",name:"热播",address:"csp_AppTTGuard",kind:.apptt,ext:.string("https://example.test"))
        let detail=try await client.detail(source,id:"7")
        let saved=Episode(name:detail.episodes[0].name,url:detail.episodes[0].url,line:detail.episodes[0].line)
        let media=try await client.resolve(saved);XCTAssertEqual(media.url,"https://cdn.example/1.m3u8")
    }
    func testBiliPartitionsKeepStableIdentityAndRequiredHeaders() async throws {
        let client=BiliClient(transport:NativeFixture { req in
            XCTAssertEqual(req.url?.host,"api.bilibili.com")
            XCTAssertEqual(req.value(forHTTPHeaderField:"Referer"),"https://www.bilibili.com/")
            XCTAssertNil(req.value(forHTTPHeaderField:"Cookie"))
            if req.url?.path.hasSuffix("view") == true {
                return HTTPReply(status:200,body:Data(#"{"code":0,"data":{"bvid":"BVtest","title":"节目","pages":[{"cid":42,"part":"第一集"},{"cid":43,"part":"第二集"}],"owner":{"name":"作者"}}}"#.utf8))
            }
            XCTAssertTrue(req.url?.query?.contains("cid=43") == true)
            return HTTPReply(status:200,body:Data(#"{"code":0,"data":{"durl":[{"url":"https://cdn.example/video.mp4"}]}}"#.utf8))
        })
        let source=MediaSource(id:"1",sourceID:"1",name:"哔哩",address:"csp_BiliGuard",kind:.bili)
        let detail=try await client.detail(source,id:"BVtest")
        XCTAssertEqual(detail.episodes.count,2)
        XCTAssertNotEqual(detail.episodes[0].id,detail.episodes[1].id)
        let media=try await client.resolve(detail.episodes[1]);XCTAssertEqual(media.url,"https://cdn.example/video.mp4")
    }
    func testBiliRefusesRiskControlAndSegmentedVideo() async throws {
        let source=MediaSource(id:"1",sourceID:"1",name:"哔哩",address:"csp_BiliGuard",kind:.bili)
        let risk=BiliClient(transport:NativeFixture { _ in HTTPReply(status:200,body:Data(#"{"code":-412,"message":"denied"}"#.utf8)) })
        do { _=try await risk.browse(source,keyword:"测试");XCTFail("应显示风控失败") } catch { XCTAssertTrue(error.localizedDescription.contains("-412")) }
        let client=BiliClient(transport:NativeFixture { _ in HTTPReply(status:200,body:Data(#"{"code":0,"data":{"durl":[{"url":"https://a.test/1.mp4"},{"url":"https://a.test/2.mp4"}]}}"#.utf8)) })
        do { _=try await client.resolve(Episode(name:"1",url:#"{"bvid":"BVtest","cid":42}"#));XCTFail("不能静默只播第一段") } catch { }
    }
    func testFirstAidReadsAndroidSelectorsAndDirectPlayback() async throws {
        let client=WebsiteClient(transport:NativeFixture { req in
            if req.url?.path == "/jijiu" { return HTTPReply(status:200,body:Data(#"<img class="block100" src="/cover.jpg"><div class="jj-title-li"><div class="list-br3"><a href="/video/1.html">急救示例</a></div></div>"#.utf8)) }
            return HTTPReply(status:200,body:Data(#"<h1 class="video-title h1-title">急救示例</h1><video id="video"><source src="https://cdn.example/v.mp4"></video><div class="img-text-con">说明</div>"#.utf8))
        })
        let source=MediaSource(id:"1",sourceID:"1",name:"急救",address:"csp_FirstAidGuard",kind:.website)
        let items=try await client.browse(source);XCTAssertEqual(items.first?.id,"https://m.youlai.cn/video/1.html")
        let detail=try await client.detail(source,id:items[0].id)
        XCTAssertEqual(detail.episodes.first?.url,"https://cdn.example/v.mp4")
        do { _=try await client.detail(source,id:"https://other.example/video");XCTFail("拒绝跨站历史标识") } catch { }
    }
    func testYGPDownloadRequestUsesTrailerIdentity() async throws {
        let client=WebsiteClient(transport:NativeFixture { req in
            let query=URLComponents(url:req.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "ttid" }?.value,"321")
            return HTTPReply(status:200,body:Data(#"[{"movurl":"https://cdn.example/trailer.mp4"}]"#.utf8))
        })
        let source=MediaSource(id:"1",sourceID:"1",name:"预告",address:"csp_YGPGuard",kind:.website)
        let media=try await client.resolve(source,episode:Episode(name:"预告",url:"https://www.6huo.com/download/321/"))
        XCTAssertEqual(media.url,"https://cdn.example/trailer.mp4")
    }
    func testPluginRegistrationDoesNotPretendOtherPluginsWork() throws {
        let sites=try CatalogParser.configuration(data:Data(#"{"sites":[{"key":"b","api":"csp_BiliGuard","type":3},{"key":"f","api":"csp_FirstAidGuard","type":3},{"key":"y","api":"csp_YGPGuard","type":3},{"key":"d","api":"csp_Dm84Guard","type":3},{"key":"x","api":"csp_UnknownGuard","type":3}]}"#.utf8),address:"https://example/config",sourceID:"s")
        XCTAssertEqual(sites.map(\.kind),[.bili,.website,.website,.website,.unsupported])
    }
}
