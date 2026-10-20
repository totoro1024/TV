import Foundation

/// 应用提供随包解释器，核心库只暴露类型化的目录与播放接口。
public enum EmbeddedAIRuntime {
    public typealias Executor = @Sendable (String, JSON) async throws -> JSON
    private final class State:@unchecked Sendable {
        let lock=NSLock();var executor:Executor?
    }
    private static let state=State()
    public static func install(_ executor:@escaping Executor) { state.lock.withLock { state.executor=executor } }
    public static func call(_ method:String,_ payload:JSON) async throws -> JSON {
        guard let executor=state.lock.withLock({state.executor}) else { throw TVError.message("AI播放组件尚未初始化，请在iPhone应用内重试") }
        try Task.checkCancellation();let result=try await executor(method,payload);try Task.checkCancellation();return result
    }
}
public struct EmbeddedAIClient:Sendable {
    public static let categories=[(id:"comic",name:"AI漫剧"),(id:"ai",name:"AI短剧")]
    public init() { }
    public func browse(keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let result=try await EmbeddedAIRuntime.call(keyword.isEmpty ? "browse":"search",.object(["keyword":.string(keyword),"page":.integer(Int64(page)),"category":.string(category.isEmpty ? "comic":category)]))
        return try CatalogParser.items(result.data)
    }
    public func detail(id:String) async throws -> MediaDetail {
        try await CatalogParser.detail(EmbeddedAIRuntime.call("detail",.object(["id":.string(id)])).data)
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        let root=try await EmbeddedAIRuntime.call("play",.object(["line":.string(episode.line),"id":.string(episode.url)]))
        guard root["parse"].int==0,CatalogParser.validHTTP(root["url"].string) else { throw TVError.message("AI短漫剧未能启动可播放媒体") }
        return ResolvedMedia(url:root["url"].string,headers:root["header"].object.mapValues(\.string))
    }
}
