import UIKit
import AVFoundation

@objc(WalkDemoAppDelegate) final class WalkDemoAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = WalkDemoController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class WalkDemoController: UIViewController, AVAudioPlayerDelegate {
    private let coordinator = WalkAudioCoordinator()
    private var player: AVAudioPlayer?
    private var playingID: String?
    private var counter = 0
    private var events: [String] = []
    private let agent = UISegmentedControl(items: ["Russ", "Emma"])
    private let stateLabel = UILabel()
    private let detailLabel = UILabel()
    private let walkButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let transcript = UITextView()
    private let accent = UIColor(red: 0.05, green: 0.42, blue: 0.36, alpha: 1)
    private var chat: String { agent.selectedSegmentIndex == 0 ? "russ" : "emma" }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.96, green: 0.97, blue: 0.94, alpha: 1)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        func label(_ text: String, _ style: UIFont.TextStyle) -> UILabel {
            let result = UILabel()
            result.text = text
            result.font = .preferredFont(forTextStyle: style)
            result.adjustsFontForContentSizeCategory = true
            result.numberOfLines = 0
            return result
        }
        stack.addArrangedSubview(label("NANOVOICE · LOCAL DEMO", .caption1))
        stack.addArrangedSubview(label("Keep walking.", .largeTitle))
        stack.addArrangedSubview(label("Voice replies come to you. No Telegram login needed for this demo.", .body))
        agent.selectedSegmentIndex = 0
        agent.addTarget(self, action: #selector(changeAgent), for: .valueChanged)
        stack.addArrangedSubview(agent)
        stateLabel.font = .preferredFont(forTextStyle: .title1)
        stateLabel.textColor = accent
        stateLabel.accessibilityIdentifier = "walk.state"
        stack.addArrangedSubview(stateLabel)
        detailLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        stack.addArrangedSubview(detailLabel)
        configure(walkButton, title: "Start Walk mode", action: #selector(toggleWalk), primary: true)
        walkButton.accessibilityIdentifier = "walk.toggle"
        stack.addArrangedSubview(walkButton)
        configure(pauseButton, title: "Pause reply", action: #selector(togglePause))
        stack.addArrangedSubview(pauseButton)
        stack.addArrangedSubview(label("SIMULATE AN INCOMING REPLY", .caption1))
        let reply = UIButton(type: .system)
        configure(reply, title: "Receive voice reply", action: #selector(injectReply))
        reply.accessibilityIdentifier = "walk.receive"
        stack.addArrangedSubview(reply)
        let burst = UIButton(type: .system)
        configure(burst, title: "Receive two replies · test queue", action: #selector(injectBurst))
        stack.addArrangedSubview(burst)
        let history = UIButton(type: .system)
        configure(history, title: "Load older message · stays silent", action: #selector(injectHistory))
        stack.addArrangedSubview(history)
        transcript.isEditable = false
        transcript.font = .preferredFont(forTextStyle: .subheadline)
        transcript.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        transcript.layer.cornerRadius = 16
        transcript.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        transcript.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(transcript)
        stack.addArrangedSubview(label("Demo audio is generated speech. This tests local playback and queuing, not Telegram delivery while locked. Switching agents ends the session.", .footnote))

        coordinator.onChange = { [weak self] in self?.render() }
        coordinator.onPlay = { [weak self] message in self?.play(message) }
        coordinator.onStop = { [weak self] in
            self?.player?.stop()
            self?.player = nil
            self?.playingID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        coordinator.onPause = { [weak self] in self?.player?.pause(); self?.record("Paused") }
        coordinator.onResume = { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                guard self.player?.play() == true else { throw NSError(domain: "WalkDemo", code: 2) }
                self.record("Resumed")
            } catch {
                self.record("Resume failed: \(error.localizedDescription)")
                if let id = self.playingID { self.coordinator.failed(messageID: id) }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        record("Earlier · Russ: Your previous voice reply stays in history.")
        render()
        if ProcessInfo.processInfo.arguments.contains("--walk-demo-self-test") {
            runPlaybackCheck()
        }
    }

    private func configure(_ button: UIButton, title: String, action: Selector, primary: Bool = false) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.setTitleColor(primary ? .white : accent, for: .normal)
        button.backgroundColor = primary ? accent : .white
        button.layer.cornerRadius = 14
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func render() {
        let titles: [WalkAudioCoordinator.State: String] = [.off: "Ready when you are", .waiting: "Waiting for a reply", .playing: "\(chat.capitalized) is speaking", .paused: "Reply paused"]
        stateLabel.text = titles[coordinator.state]
        detailLabel.text = coordinator.state == .off ? "Start a session, then simulate a voice reply." : "\(coordinator.queue.count) queued · Only new replies from \(chat.capitalized) autoplay"
        walkButton.setTitle(coordinator.state == .off ? "Start Walk mode" : "End Walk mode", for: .normal)
        pauseButton.setTitle(coordinator.state == .paused ? "Resume reply" : "Pause reply", for: .normal)
        pauseButton.isEnabled = coordinator.state == .playing || coordinator.state == .paused
        pauseButton.alpha = pauseButton.isEnabled ? 1 : 0.4
    }

    @objc private func toggleWalk() {
        if coordinator.state == .off { coordinator.start(chatID: chat); record("Walk mode started with \(chat.capitalized)") }
        else { coordinator.end(); record("Walk mode ended · queue cleared") }
    }
    @objc private func changeAgent() { coordinator.end(); record("Selected \(chat.capitalized) · session off") }
    @objc private func togglePause() { coordinator.pauseOrResume() }
    @objc private func injectReply() { inject(isNew: true) }
    @objc private func injectBurst() { inject(isNew: true); inject(isNew: true) }
    @objc private func injectHistory() { inject(isNew: false) }

    private func inject(isNew: Bool) {
        counter += 1
        guard let url = Bundle.main.url(forResource: "\(chat)-reply", withExtension: "aiff") else {
            record("Missing bundled audio fixture")
            return
        }
        record("\(isNew ? "Incoming" : "History") · \(chat.capitalized) voice #\(counter)")
        coordinator.receive(WalkAudioMessage(id: String(counter), chatID: chat, fileURL: url), isNew: isNew)
    }

    private func play(_ message: WalkAudioMessage) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: message.fileURL)
            self.player = player
            playingID = message.id
            player.delegate = self
            guard player.play() else { throw NSError(domain: "WalkDemo", code: 1) }
            record("Playing #\(message.id)")
        } catch {
            record("Playback failed: \(error.localizedDescription)")
            coordinator.failed(messageID: message.id)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, let id = playingID else { return }
        record("Finished #\(id) · success=\(flag)")
        if flag { coordinator.finished(messageID: id) } else { coordinator.failed(messageID: id) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player, let id = playingID else { return }
        record("Decode failed #\(id)")
        coordinator.failed(messageID: id)
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        if coordinator.state == .playing { coordinator.pauseOrResume() }
    }
    @objc private func routeChanged(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        if coordinator.state == .playing { coordinator.pauseOrResume() }
    }

    private func record(_ event: String) {
        events.append(event)
        transcript.text = events.suffix(12).joined(separator: "\n\n")
        NSLog("WalkDemo: %@", event)
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? events.joined(separator: "\n").write(to: directory.appendingPathComponent("walk-demo-events.txt"), atomically: true, encoding: .utf8)
        }
        if !transcript.text.isEmpty { transcript.scrollRangeToVisible(NSRange(location: transcript.text.utf16.count - 1, length: 1)) }
    }

    /// Exercises real AVAudioPlayer callbacks without UI automation or Telegram login.
    private func runPlaybackCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.injectHistory()
            self.toggleWalk()
            self.injectBurst()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.togglePause() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.togglePause() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            let passed = self.coordinator.state == .waiting && self.events.filter { $0.hasPrefix("Finished") && $0.hasSuffix("success=true") }.count == 2
            self.record(passed ? "PLAYBACK CHECK PASSED" : "PLAYBACK CHECK FAILED")
            self.coordinator.end()
        }
    }
}
