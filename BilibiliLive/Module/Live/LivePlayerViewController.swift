//
//  LivePlayerViewController.swift
//  BilibiliLive
//
//  Created by Etan on 2021/3/27.
//

import Alamofire
import AVKit
import Foundation
import SwiftyJSON
import UIKit

class LivePlayerViewController: CommonPlayerViewController {
    var room: LiveRoom?

    private var viewModel: LivePlayerViewModel?
    deinit {
        FamilyPlayer.onMain { viewModel?.stop() }
        Logger.debug("deinit live player")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if FamilyModeState.childActive { denyFamilyPlayback(.live); return }
        guard isPlaybackContextCurrent, let room else { return }
        viewModel = LivePlayerViewModel(room: room)
        viewModel?.onPluginReady = { [weak self] plugins in
            guard let self, self.isPlaybackContextCurrent else { return }
            plugins.forEach { self.addPlugin(plugin: $0) }
        }
        viewModel?.onError = { [weak self] message in
            guard let self, self.isPlaybackContextCurrent else { return }
            self.showErrorAlertAndExit(message: message)
        }
        viewModel?.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // PiP dismissal retains the context; a real close permanently cancels retries.
        if !isPlaybackContextCurrent { viewModel?.stop() }
    }

    override func stopPlayback() {
        viewModel?.stop()
        super.stopPlayback()
    }
}
