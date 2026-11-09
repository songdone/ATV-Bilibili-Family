//
//  LivePlayerViewModel.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/13.
//

import Alamofire
import Foundation
import SwiftyJSON

enum LiveError: String, LocalizedError {
    case noLiving
    case noPlaybackUrl
    case fetchApiFail

    var errorDescription: String? {
        rawValue
    }
}

@MainActor
class LivePlayerViewModel {
    init(room: LiveRoom) {
        self.room = room
        roomID = room.room_id
        modeObserver = NotificationCenter.default.addObserver(forName: PlaybackCoordinator.modeWillChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            FamilyPlayer.onMain { self?.stop() }
        }
    }

    deinit {
        startTask?.cancel()
        retryTask?.cancel()
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        danMuProvider?.stop()
    }

    var onPluginReady: (([CommonPlayerPlugin]) -> Void)?
    var onError: ((String) -> Void)?

    private let playPlugin = URLPlayPlugin(referer: Keys.liveReferer, isLive: true)
    private let debugPlugin = DebugPlugin()
    private let modeGeneration = PlaybackCoordinator.shared.modeGeneration
    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var modeObserver: NSObjectProtocol?
    private var stopped = false
    private var started = false

    private func ensureActive() throws {
        guard !stopped, !Task.isCancelled,
              PlaybackCoordinator.shared.isModeCurrent(modeGeneration, child: false) else { throw CancellationError() }
    }

    func stop() {
        stopped = true
        startTask?.cancel()
        retryTask?.cancel()
        startTask = nil
        retryTask = nil
        playPlugin.onPlayFail = nil
        onPluginReady = nil
        onError = nil
        danMuProvider?.stop()
    }

    func start() {
        guard !started, (try? ensureActive()) != nil else { return }
        started = true
        playPlugin.onPlayFail = { [weak self] in self?.playerDidFailToPlay() }
        debugPlugin.additionDebugInfo = { [weak self] in self?.debugInfo() ?? "" }
        onPluginReady?([playPlugin, debugPlugin])
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try ensureActive()
                try await refreshRoomsID()
                try ensureActive()
                try await initPlayer()
                try ensureActive()
                let danmu = try await initDanmu()
                try ensureActive()
                let linePlugin = LineCandidatesPlugin(candidates: playInfos) { [weak self] url in
                    guard let self, (try? self.ensureActive()) != nil else { return }
                    self.playPlugin.play(urlString: url)
                }
                onPluginReady?(danmu + [linePlugin])
                let info = await fetchDespInfo()
                try ensureActive()
                if let info {
                    let subtitle = "\(room.ownerName)·\(info.parent_area_name) \(info.area_name)"
                    let desp = "\(info.description)\nTags:\(info.tags ?? "")"
                    onPluginReady?([BVideoInfoPlugin(title: info.title, subTitle: subtitle, desp: desp, pic: room.pic, viewPoints: nil)])
                } else {
                    onPluginReady?([BVideoInfoPlugin(title: room.title, subTitle: nil, desp: nil, pic: room.pic, viewPoints: nil)])
                }
            } catch {
                guard (try? ensureActive()) != nil else { return }
                onError?(String(describing: error))
            }
        }
    }

    func playerDidFailToPlay() {
        guard retryTask == nil, (try? ensureActive()) != nil else { return }
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { retryTask = nil }
            do {
                try ensureActive()
                playInfos = Array(playInfos.dropFirst())
                if playInfos.isEmpty {
                    retryCount += 1
                    if retryCount > 3 {
                        onError?("播放失败")
                        return
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try ensureActive()
                    try await initPlayer()
                    try ensureActive()
                } else {
                    try await playFirstInfo()
                    try ensureActive()
                }
            } catch {
                guard (try? ensureActive()) != nil else { return }
                onError?(error.localizedDescription)
            }
        }
    }

    func debugInfo() -> String {
        return "\(allPlayInfos.first?.formate ?? "") \(allPlayInfos.first?.current_qn ?? 0) retry:\(retryCount)"
    }

    func fetchDespInfo() async -> WebRequest.LiveRoomInfo? {
        return try? await WebRequest.requestLiveBaseInfo(roomID: roomID)
    }

    // Private
    private var allPlayInfos = [LivePlayUrlInfo]()
    private var playInfos = [LivePlayUrlInfo]()
    private var roomID: Int
    private let room: LiveRoom
    private var danMuProvider: LiveDanMuProvider?
    private var retryCount = 0

    private func refreshRoomsID() async throws {
        try ensureActive()
        let info = try await WebRequest.requestLiveRoomInit(roomID: roomID)
        try ensureActive()
        if info.live_status != 1 {
            throw LiveError.noLiving
        }
        roomID = info.room_id
    }

    private func initPlayer() async throws {
        allPlayInfos = []

        try ensureActive()
        let streams = try await WebRequest.requestLiveStreams(roomID: roomID)
        try ensureActive()

        for stream in streams {
            for content in stream.format {
                let formate = content.formatName
                let codecs = content.codec
                for codec in codecs {
                    let qn = codec.currentQn
                    let baseUrl = codec.baseurl
                    for url_info in codec.urlInfo {
                        let host = url_info.host
                        let extra = url_info.extra
                        let url = "\(host)\(baseUrl)\(extra)"
                        let playInfo = LivePlayUrlInfo(formate: formate, url: url, current_qn: qn, codec_name: codec.codecName)
                        allPlayInfos.append(playInfo)
                    }
                }
            }
        }

        allPlayInfos.sort { a, b in
            return a.current_qn ?? 0 > b.current_qn ?? 0
        }

        allPlayInfos.sort { a, b in
            return a.formate == "fmp4"
        }

        Logger.debug("all info arry:\(playInfos)")
        playInfos = allPlayInfos
        try await playFirstInfo()
    }

    func playFirstInfo() async throws {
        try ensureActive()
        if let info = playInfos.first {
            Logger.debug("play => \(playInfos)")
            playPlugin.play(urlString: info.url)
        } else {
            throw LiveError.noPlaybackUrl
        }
    }

    @MainActor private func initDanmu() async throws -> [CommonPlayerPlugin] {
        try ensureActive()
        let provider = LiveDanMuProvider(roomID: roomID, removeDup: Settings.enableDanmuRemoveDup)
        danMuProvider = provider
        let danmuPlugin = DanmuViewPlugin(provider: provider)

        try? await provider.start()
        do { try ensureActive() } catch { provider.stop(); throw error }
        var plugins: [CommonPlayerPlugin] = [danmuPlugin]
        if Settings.danmuMask, Settings.vnMask {
            let plugin = MaskViewPugin(maskView: danmuPlugin.danMuView, maskProvider: VMaskProvider())
            plugins.append(plugin)
        }

        return plugins
    }
}

struct LivePlayUrlInfo {
    let formate: String?
    let url: String
    let current_qn: Int?
    let codec_name: String?
}

extension WebRequest.EndPoint {
    static let liveRoomInfo = "https://api.live.bilibili.com/room/v1/Room/get_info"
    static let liveRoomStream = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo"
    static let liveRoomInit = "https://api.live.bilibili.com/room/v1/Room/room_init"
}

extension WebRequest {
    struct LiveRoomInfo: Codable {
        let description: String
        let parent_area_name: String
        let title: String
        let tags: String?
        let area_name: String
        let hot_words: [String]?
    }

    static func requestLiveBaseInfo(roomID: Int) async throws -> LiveRoomInfo {
        return try await request(url: EndPoint.liveRoomInfo, parameters: ["room_id": roomID])
    }

    struct LiveRoomInit: Codable {
        var live_status: Int
        var room_id: Int
    }

    static func requestLiveRoomInit(roomID: Int) async throws -> LiveRoomInit {
        return try await request(url: EndPoint.liveRoomInfo, parameters: ["id": roomID])
    }

    static func requestLiveStreams(roomID: Int) async throws -> [LiveStream] {
        struct LiveRoomStreamInfo: Codable {
            let playurl_info: PlayUrlInfo

            struct PlayUrlInfo: Codable {
                let playurl: PlayUrl
            }

            struct PlayUrl: Codable {
                let cid: Int
                let stream: [LiveStream]
            }
        }
        let info: LiveRoomStreamInfo = try await request(url: EndPoint.liveRoomStream,
                                                         parameters: ["room_id": roomID,
                                                                      "protocol": "1",
                                                                      "format": "0,1,2",
                                                                      "codec": "0,1",
                                                                      "qn": "10000",
                                                                      "platform": "web",
                                                                      "ptype": "8",
                                                                      "dolby": "5",
                                                                      "panorama": 1])
        return info.playurl_info.playurl.stream
    }
}

struct LiveStream: Codable {
    let format: [Format]
    let protocol_name: String

    struct Format: Codable {
        let formatName: String
        let codec: [Codec]
        let masterurl: String

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case codec
            case masterurl = "master_url"
        }

        struct Codec: Codable {
            let urlInfo: [URLInfo]
            let codecName: String
            let currentQn: Int
            let baseurl: String

            enum CodingKeys: String, CodingKey {
                case urlInfo = "url_info"
                case codecName = "codec_name"
                case currentQn = "current_qn"
                case baseurl = "base_url"
            }

            struct URLInfo: Codable {
                let host: String
                let extra: String
            }
        }
    }
}
