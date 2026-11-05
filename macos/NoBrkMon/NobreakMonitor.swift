import SwiftUI
import AppKit
import Foundation
import Network
import UserNotifications

// MARK: - Níveis de alerta

enum Level {
    case ok, warn, bad, info

    var color: Color {
        switch self {
        case .ok:   return Color(red: 0.20, green: 0.83, blue: 0.45)
        case .warn: return Color(red: 1.00, green: 0.78, blue: 0.20)
        case .bad:  return Color(red: 1.00, green: 0.33, blue: 0.33)
        case .info: return Color(red: 0.55, green: 0.70, blue: 1.00)
        }
    }

    var label: String {
        switch self {
        case .ok: return "Normal"
        case .warn: return "Atenção"
        case .bad: return "Crítico"
        case .info: return "Info"
        }
    }
}

// MARK: - Configuração

/// Regra de faixas para uma variável:
///  - VERDE   se okMin <= valor <= okMax
///  - AMARELO se warnMin <= valor <= warnMax (e não é verde)
///  - VERMELHO caso contrário
/// Qualquer limite omitido é tratado como "sem limite".
struct Threshold: Codable, Equatable {
    var okMin: Double?
    var okMax: Double?
    var warnMin: Double?
    var warnMax: Double?

    func level(_ v: Double) -> Level {
        if v >= (okMin ?? -.infinity) && v <= (okMax ?? .infinity) { return .ok }
        if v >= (warnMin ?? -.infinity) && v <= (warnMax ?? .infinity) { return .warn }
        return .bad
    }

    func hint(_ unit: String) -> String {
        func g(_ d: Double) -> String { String(format: "%g", d) }
        let normal: String
        switch (okMin, okMax) {
        case let (a?, b?): normal = "\(g(a))–\(g(b)) \(unit)"
        case let (a?, nil): normal = "≥ \(g(a)) \(unit)"
        case let (nil, b?): normal = "≤ \(g(b)) \(unit)"
        default: normal = "—"
        }
        var crit: [String] = []
        if let a = warnMin { crit.append("< \(g(a))") }
        if let b = warnMax { crit.append("> \(g(b))") }
        var s = "Normal \(normal)"
        if !crit.isEmpty { s += " • crítico " + crit.joined(separator: " ou ") }
        return s
    }
}

/// Alarmes (bloco "alarms" do config.json)
struct AlarmConfig: Codable, Equatable {
    var enabled = true                       // liga/desliga todos os alarmes
    var notifications = true                 // notificações do macOS
    var sound = true                         // som de alarme
    var soundName = "Sosumi"                 // Sosumi, Basso, Glass, Funk, Hero, Submarine, Ping...
    var repeatSeconds = 60.0                 // repete o som a cada N s enquanto houver alarme crítico (0 = não repete)
    var alertOnWarning = false               // true = alarmes também para valores amarelos (limítrofes)
    var connectionFailuresBeforeAlarm = 3    // falhas seguidas de consulta até acusar "sem comunicação"
    var notifyOnRecovery = true              // avisa quando a situação normaliza

    enum CodingKeys: String, CodingKey {
        case enabled, notifications, sound, soundName, repeatSeconds
        case alertOnWarning, connectionFailuresBeforeAlarm, notifyOnRecovery
    }
}

extension AlarmConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? "Sosumi"
        repeatSeconds = try c.decodeIfPresent(Double.self, forKey: .repeatSeconds) ?? 60
        alertOnWarning = try c.decodeIfPresent(Bool.self, forKey: .alertOnWarning) ?? false
        connectionFailuresBeforeAlarm = try c.decodeIfPresent(Int.self, forKey: .connectionFailuresBeforeAlarm) ?? 3
        notifyOnRecovery = try c.decodeIfPresent(Bool.self, forKey: .notifyOnRecovery) ?? true
    }
}

struct AppConfig: Codable {
    var target: String
    var pollIntervalSeconds: Double
    var thresholds: [String: Threshold]
    var alarms: AlarmConfig

    enum CodingKeys: String, CodingKey {
        case target, pollIntervalSeconds, thresholds, alarms
    }

    static let defaults = AppConfig(
        target: "ragtech700@192.168.15.24:18083",
        pollIntervalSeconds: 5,
        thresholds: [
            "battery.charge":   Threshold(okMin: 80, warnMin: 50),
            "ups.load":         Threshold(okMax: 60, warnMax: 80),
            "battery.voltage":  Threshold(okMin: 12.4, okMax: 14.4, warnMin: 11.8, warnMax: 14.8),
            "input.voltage":    Threshold(okMin: 105, okMax: 132, warnMin: 98, warnMax: 138),
            "output.voltage":   Threshold(okMin: 108, okMax: 127, warnMin: 100, warnMax: 133),
            "output.frequency": Threshold(okMin: 59.5, okMax: 60.5, warnMin: 58.5, warnMax: 61.5),
            "ups.temperature":  Threshold(okMax: 45, warnMax: 60)
        ],
        alarms: AlarmConfig()
    )
}

extension AppConfig {
    /// Campos ausentes no JSON usam os valores padrão.
    /// Cada regra de faixa presente no arquivo substitui INTEIRA a regra padrão da variável.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.defaults
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? d.target
        pollIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        let custom = try c.decodeIfPresent([String: Threshold].self, forKey: .thresholds) ?? [:]
        thresholds = d.thresholds.merging(custom) { _, new in new }
        alarms = try c.decodeIfPresent(AlarmConfig.self, forKey: .alarms) ?? d.alarms
    }
}

// MARK: - Erros e monitor

enum UPSError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        if case .msg(let m) = self { return m }
        return nil
    }
}

@MainActor
final class UPSMonitor: ObservableObject {
    @Published var data: [String: String] = [:]
    @Published var error: String?
    @Published var lastUpdate: Date?
    @Published var loading = false
    @Published var config = AppConfig.defaults
    @Published var configError: String?

    private var configMTime: Date?

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nobreak-monitor/config.json")
    }

    init() { loadConfig() }

    // MARK: Config

    private func currentMTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.configURL.path))?[.modificationDate] as? Date
    }

    private func writeDefaultConfig() {
        let url = Self.configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(AppConfig.defaults) {
            try? data.write(to: url)
        }
    }

    func loadConfig() {
        let url = Self.configURL
        if !FileManager.default.fileExists(atPath: url.path) { writeDefaultConfig() }
        configMTime = currentMTime()
        do {
            let data = try Data(contentsOf: url)
            var cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            cfg.pollIntervalSeconds = max(1, cfg.pollIntervalSeconds)
            config = cfg
            configError = nil
        } catch {
            configError = "Config inválida (\(url.path)): mantendo valores anteriores. \(error.localizedDescription)"
        }
    }

    func reloadConfigIfChanged() {
        if currentMTime() != configMTime { loadConfig() }
    }

    // MARK: Consulta

    func refresh() async {
        loading = true
        let result: Result<[String: String], UPSError>
        if let session = NUTSession(target: config.target) {
            result = await session.run(timeout: 5)
        } else {
            result = .failure(.msg("Endereço inválido em \"target\". Use o formato nome@host:porta"))
        }
        switch result {
        case .success(let d):
            data = d; error = nil; lastUpdate = Date()
        case .failure(let e):
            error = e.localizedDescription
        }
        loading = false
    }
}

// MARK: - Cliente NUT nativo (conversa direto com o servidor, sem o comando upsc)

final class NUTSession: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "nobrkmon.nut")
    private let upsName: String
    private var buffer = Data()
    private var done = false
    private var lastWaiting: String?
    private var cont: CheckedContinuation<Result<[String: String], UPSError>, Never>?

    /// target no formato  nome@host:porta  (porta padrão 3493)
    init?(target: String) {
        let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.count == 2 ? parts[0] : "ups"
        let hostPort = parts.count == 2 ? parts[1] : parts[0]
        let hp = hostPort.split(separator: ":").map(String.init)
        guard let host = hp.first, !host.isEmpty, !name.isEmpty else { return nil }
        let portNum = hp.count > 1 ? (UInt16(hp[1]) ?? 3493) : 3493
        guard let port = NWEndpoint.Port(rawValue: portNum) else { return nil }
        upsName = name
        conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func run(timeout: TimeInterval) async -> Result<[String: String], UPSError> {
        await withCheckedContinuation { (c: CheckedContinuation<Result<[String: String], UPSError>, Never>) in
            queue.async { [self] in
                self.cont = c
                self.conn.stateUpdateHandler = { state in self.handle(state) }
                self.conn.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    let hint = self.lastWaiting.map { " (\($0))" } ?? ""
                    self.finish(.failure(.msg("Tempo esgotado ao conectar no nobreak\(hint). Verifique a permissão de Rede Local do app.")))
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let cmd = "LIST VAR \(upsName)\n".data(using: .utf8)
            conn.send(content: cmd, completion: .contentProcessed({ [weak self] err in
                if let err = err { self?.finish(.failure(.msg("Erro ao enviar: \(err)"))) }
            }))
            receiveMore()
        case .waiting(let err):
            lastWaiting = "\(err)"
        case .failed(let err):
            finish(.failure(.msg("Falha de conexão: \(err)")))
        default:
            break
        }
    }

    private func receiveMore() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.done else { return }
            if let data = data { self.buffer.append(data) }
            let text = String(decoding: self.buffer, as: UTF8.self)
            if text.hasPrefix("ERR") {
                let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                self.finish(.failure(.msg("Servidor NUT respondeu: \(first)")))
            } else if text.contains("END LIST VAR") {
                let dict = NUTSession.parse(text)
                self.finish(dict.isEmpty ? .failure(.msg("Resposta vazia do servidor NUT")) : .success(dict))
            } else if let error = error {
                self.finish(.failure(.msg("Erro de leitura: \(error)")))
            } else if isComplete {
                self.finish(.failure(.msg("Conexão encerrada pelo servidor antes do fim da resposta")))
            } else {
                self.receiveMore()
            }
        }
    }

    private func finish(_ r: Result<[String: String], UPSError>) {
        if done { return }
        done = true
        conn.cancel()
        cont?.resume(returning: r)
        cont = nil
    }

    /// Linhas no formato:  VAR <ups> <chave> "<valor>"
    private static func parse(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("VAR ") else { continue }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4 else { continue }
            var v = String(parts[3])
            if v.count >= 2 && v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            dict[String(parts[2])] = v
        }
        return dict
    }
}

// MARK: - Alarmes

struct Alarm: Identifiable {
    let id: String
    let title: String
    let detail: String
    let level: Level
}

final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Mostra a notificação mesmo com o app em primeiro plano
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

@MainActor
final class AlarmEngine: ObservableObject {
    @Published var active: [Alarm] = []
    @Published var muted = false
    @Published var testResult: String?

    private var previous: [String: Alarm] = [:]
    private var failures = 0
    private var lastSound = Date.distantPast
    private let delegate = NotifDelegate()

    private static let metrics: [(key: String, title: String, unit: String)] = [
        ("ups.load", "Sobrecarga: carga do nobreak alta", "%"),
        ("battery.charge", "Carga da bateria baixa", "%"),
        ("battery.voltage", "Tensão da bateria fora da faixa", "V"),
        ("input.voltage", "Tensão de entrada fora da faixa", "V"),
        ("output.voltage", "Tensão de saída fora da faixa", "V"),
        ("output.frequency", "Frequência fora da faixa", "Hz"),
        ("ups.temperature", "Temperatura elevada", "°C")
    ]

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Chamado após cada consulta.
    func evaluate(_ mon: UPSMonitor) {
        let cfg = mon.config.alarms
        guard cfg.enabled else {
            previous = [:]; active = []; muted = false
            NSApp.dockTile.badgeLabel = nil
            return
        }

        if mon.error != nil { failures += 1 } else { failures = 0 }

        if failures >= max(1, cfg.connectionFailuresBeforeAlarm) {
            let a = Alarm(id: "comm", title: "Sem comunicação com o nobreak",
                          detail: mon.error ?? "Sem resposta do servidor NUT", level: .bad)
            apply([a], cfg)
        } else if mon.error != nil || mon.data.isEmpty {
            return   // falha isolada ou ainda sem dados: mantém o estado atual
        } else {
            apply(build(mon), cfg)
        }
    }

    private func build(_ mon: UPSMonitor) -> [Alarm] {
        var out: [Alarm] = []
        func num(_ k: String) -> Double? { mon.data[k].flatMap { Double($0) } }
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }

        let tokens = (mon.data["ups.status"] ?? "").split(separator: " ").map(String.init)
        let charge = "bateria em \(fmt(num("battery.charge")))%"

        if tokens.contains("OB") {
            out.append(Alarm(id: "status.OB", title: "Queda de energia: operando na bateria",
                             detail: "Tensão de entrada: \(fmt(num("input.voltage"))) V • \(charge)", level: .bad))
        }
        if tokens.contains("LB") {
            out.append(Alarm(id: "status.LB", title: "Bateria fraca",
                             detail: "O nobreak pode desligar a qualquer momento • \(charge)", level: .bad))
        }
        if tokens.contains("RB") {
            out.append(Alarm(id: "status.RB", title: "Trocar a bateria",
                             detail: "O nobreak indica que a bateria precisa ser substituída", level: .bad))
        }
        if tokens.contains("OVER") {
            out.append(Alarm(id: "status.OVER", title: "Sobrecarga reportada pelo nobreak",
                             detail: "Carga atual: \(fmt(num("ups.load")))%. Desligue equipamentos da saída.", level: .bad))
        }
        if tokens.contains("ALARM") {
            out.append(Alarm(id: "status.ALARM", title: "Alarme ativo no nobreak",
                             detail: "ups.status: \(mon.data["ups.status"] ?? "")", level: .bad))
        }
        if tokens.contains("BYPASS") {
            out.append(Alarm(id: "status.BYPASS", title: "Nobreak em bypass (sem proteção)",
                             detail: "A carga está ligada direto na rede", level: .warn))
        }

        for m in Self.metrics {
            guard let v = num(m.key) else { continue }
            let thr = mon.config.thresholds[m.key] ?? Threshold()
            let lv = thr.level(v)
            if lv == .bad || (lv == .warn && mon.config.alarms.alertOnWarning) {
                let suffix = lv == .bad ? "bad" : "warn"
                out.append(Alarm(id: "metric.\(m.key).\(suffix)",
                                 title: m.title + (lv == .warn ? " (atenção)" : ""),
                                 detail: "Valor atual: \(fmt(v)) \(m.unit) • \(thr.hint(m.unit))",
                                 level: lv))
            }
        }
        return out
    }

    private func apply(_ list: [Alarm], _ cfg: AlarmConfig) {
        let newOnes = list.filter { previous[$0.id] == nil }
        let cleared = previous.values.filter { old in !list.contains(where: { $0.id == old.id }) }

        if cfg.notifications {
            for a in newOnes {
                notify(title: a.level == .bad ? "⚠️ \(a.title)" : a.title, body: a.detail)
            }
            if cfg.notifyOnRecovery {
                for a in cleared { notify(title: "✅ Normalizado", body: a.title) }
            }
        }

        if !newOnes.isEmpty {
            muted = false
            if cfg.sound { playSound(cfg) }
            if newOnes.contains(where: { $0.level == .bad }) {
                NSApp.requestUserAttention(.criticalRequest)
            }
        } else if cfg.sound, !muted, cfg.repeatSeconds > 0,
                  list.contains(where: { $0.level == .bad }),
                  Date().timeIntervalSince(lastSound) >= cfg.repeatSeconds {
            playSound(cfg)
        }
        if list.isEmpty { muted = false }

        previous = list.reduce(into: [String: Alarm]()) { $0[$1.id] = $1 }
        active = list
        NSApp.dockTile.badgeLabel = list.isEmpty ? nil : "\(list.count)"
    }

    func test(_ cfg: AlarmConfig) {
        testResult = "Testando…"

        let soundMsg: String
        if cfg.sound {
            let exists = NSSound(named: NSSound.Name(cfg.soundName)) != nil
            playSound(cfg)
            soundMsg = exists ? "som “\(cfg.soundName)” enviado (confira o volume do Mac)"
                              : "som “\(cfg.soundName)” não existe, usei beep"
        } else {
            soundMsg = "som desligado no config.json"
        }

        guard cfg.notifications else {
            testResult = "Notificações desligadas no config.json • \(soundMsg)"
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            if status == .denied {
                Task { @MainActor in
                    self?.testResult = "Notificações BLOQUEADAS para o app. Ative em Ajustes do Sistema → Notificações → NoBrkMon • \(soundMsg)"
                }
                return
            }
            if status == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                    Task { @MainActor in
                        self?.testResult = granted
                            ? "Permissão concedida. Clique em Testar alarme de novo • \(soundMsg)"
                            : "Permissão de notificação negada (\(err?.localizedDescription ?? "sem detalhe")) • \(soundMsg)"
                    }
                }
                return
            }
            let c = UNMutableNotificationContent()
            c.title = "⚠️ Teste de alarme"
            c.body = "Se você viu isto, as notificações estão funcionando."
            let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
            center.add(r) { error in
                let msg: String
                if let e = error {
                    msg = "Erro ao notificar: \(e.localizedDescription) • \(soundMsg)"
                } else {
                    msg = "Notificação enviada ao macOS (se não apareceu, verifique o modo Foco / Não Perturbe) • \(soundMsg)"
                }
                Task { @MainActor in self?.testResult = msg }
            }
        }
    }

    private func playSound(_ cfg: AlarmConfig) {
        lastSound = Date()
        if let s = NSSound(named: NSSound.Name(cfg.soundName)) {
            s.stop(); s.play()
        } else {
            NSSound.beep()
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    }
}

// MARK: - Componentes visuais

struct RingGauge: View {
    let value: Double
    let color: Color
    let text: String
    let caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 100) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 8)
                .animation(.easeOut(duration: 0.6), value: value)
            VStack(spacing: 2) {
                Text(text)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(width: 150, height: 150)
    }
}

struct HeroCard: View {
    let title: String
    let icon: String
    let value: Double
    let text: String
    let caption: String
    let level: Level

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: icon)
                Text(title).font(.headline)
                Spacer()
                LevelBadge(level: level)
            }
            .foregroundColor(.white.opacity(0.9))
            RingGauge(value: value, color: level.color, text: text, caption: caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .cardStyle(level)
    }
}

struct LevelBadge: View {
    let level: Level
    var body: some View {
        Text(level.label.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(level.color.opacity(0.18))
            .foregroundColor(level.color)
            .clipShape(Capsule())
    }
}

struct MetricCard: View {
    let title: String
    let icon: String
    let value: String
    let unit: String
    let hint: String
    let level: Level

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundColor(level.color)
                Text(title).font(.subheadline).foregroundColor(.white.opacity(0.75))
                Spacer()
                Circle().fill(level.color).frame(width: 9, height: 9)
                    .shadow(color: level.color, radius: 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(level.color)
                Text(unit).font(.callout).foregroundColor(.white.opacity(0.5))
            }
            Text(hint)
                .font(.caption).foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(level)
    }
}

extension View {
    func cardStyle(_ level: Level) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(level.color.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Tela principal

struct ContentView: View {
    @StateObject private var mon = UPSMonitor()
    @StateObject private var alarms = AlarmEngine()

    private func num(_ k: String) -> Double? { mon.data[k].flatMap { Double($0) } }
    private func f(_ v: Double?, _ d: Int = 1) -> String {
        guard let v = v else { return "—" }
        return String(format: "%.\(d)f", v)
    }

    /// Nível de uma variável segundo as faixas do arquivo de configuração.
    private func lvl(_ key: String) -> Level {
        guard let v = num(key) else { return .info }
        return (mon.config.thresholds[key] ?? Threshold()).level(v)
    }
    private func hint(_ key: String, _ unit: String, prefix: String = "") -> String {
        prefix + (mon.config.thresholds[key] ?? Threshold()).hint(unit)
    }

    // Status
    private var statusTokens: [String] {
        (mon.data["ups.status"] ?? "").split(separator: " ").map(String.init)
    }
    private var statusLevel: Level {
        if mon.data["ups.status"] == nil { return .info }
        if statusTokens.contains(where: { ["OB", "LB", "RB", "ALARM"].contains($0) }) { return .bad }
        if statusTokens.contains(where: { ["OVER", "TRIM", "BOOST", "CHRG", "DISCHRG", "BYPASS"].contains($0) }) { return .warn }
        if statusTokens.contains("OL") { return .ok }
        return .info
    }
    private var statusText: String {
        let names = ["OL": "Online (rede elétrica OK)", "OB": "Na bateria (sem rede!)", "LB": "Bateria fraca",
                     "RB": "Trocar bateria", "CHRG": "Carregando", "DISCHRG": "Descarregando",
                     "OVER": "Sobrecarga", "TRIM": "Reduzindo tensão", "BOOST": "Elevando tensão",
                     "BYPASS": "Bypass", "ALARM": "Alarme"]
        if statusTokens.isEmpty { return "Sem dados" }
        return statusTokens.map { names[$0] ?? $0 }.joined(separator: " • ")
    }

    private var estWatts: Double? {
        guard let l = num("ups.load"), let p = num("ups.realpower.nominal") else { return nil }
        return l / 100 * p
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.14),
                                    Color(red: 0.08, green: 0.10, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let r = alarms.testResult { infoBanner(r) }
                    if let e = mon.configError { configBanner(e) }
                    if let e = mon.error { errorBanner(e) }
                    if !alarms.active.isEmpty { alarmPanel }
                    statusBanner

                    HStack(spacing: 18) {
                        HeroCard(title: "Carga da bateria", icon: "battery.100.bolt",
                                 value: num("battery.charge") ?? 0,
                                 text: "\(f(num("battery.charge"), 0))%",
                                 caption: "\(f(num("battery.voltage"), 2)) V",
                                 level: lvl("battery.charge"))
                        HeroCard(title: "Carga do nobreak", icon: "gauge.with.dots.needle.50percent",
                                 value: num("ups.load") ?? 0,
                                 text: "\(f(num("ups.load"), 1))%",
                                 caption: "≈ \(f(estWatts, 0)) W em uso",
                                 level: lvl("ups.load"))
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        MetricCard(title: "Tensão de entrada", icon: "bolt.fill",
                                   value: f(num("input.voltage")), unit: "V",
                                   hint: hint("input.voltage", "V",
                                              prefix: "Nominal \(mon.data["input.voltage.nominal"] ?? "—") V • "),
                                   level: lvl("input.voltage"))
                        MetricCard(title: "Tensão de saída", icon: "powerplug.fill",
                                   value: f(num("output.voltage")), unit: "V",
                                   hint: hint("output.voltage", "V",
                                              prefix: "Nominal \(mon.data["output.voltage.nominal"] ?? "—") V • "),
                                   level: lvl("output.voltage"))
                        MetricCard(title: "Frequência", icon: "waveform.path.ecg",
                                   value: f(num("output.frequency"), 2), unit: "Hz",
                                   hint: hint("output.frequency", "Hz"),
                                   level: lvl("output.frequency"))
                        MetricCard(title: "Temperatura", icon: "thermometer.medium",
                                   value: f(num("ups.temperature"), 0), unit: "°C",
                                   hint: hint("ups.temperature", "°C"),
                                   level: lvl("ups.temperature"))
                        MetricCard(title: "Tensão da bateria", icon: "minus.plus.batteryblock.fill",
                                   value: f(num("battery.voltage"), 2), unit: "V",
                                   hint: hint("battery.voltage", "V",
                                              prefix: "Nominal \(mon.data["battery.voltage.nominal"] ?? "—") V • "),
                                   level: lvl("battery.voltage"))
                        MetricCard(title: "Corrente de saída", icon: "arrow.right.circle.fill",
                                   value: f(num("output.current"), 2), unit: "A",
                                   hint: "Potência nominal \(mon.data["ups.power.nominal"] ?? "—") VA / \(mon.data["ups.realpower.nominal"] ?? "—") W",
                                   level: .info)
                    }

                    details
                    footer
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            alarms.requestAuthorization()
            while !Task.isCancelled {
                mon.reloadConfigIfChanged()
                await mon.refresh()
                alarms.evaluate(mon)
                // Espera o intervalo configurado, checando mudanças no arquivo a cada 0,5 s
                var waited = 0.0
                while waited < mon.config.pollIntervalSeconds && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                    mon.reloadConfigIfChanged()
                }
            }
        }
    }

    // MARK: Partes da tela

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 34))
                .foregroundColor(statusLevel.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(mon.data["ups.model"] ?? "Nobreak")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(mon.data["ups.mfr"] ?? "—") • FW \(mon.data["ups.firmware"] ?? "—") • \(mon.config.target) • v2.2 alarmes")
                    .font(.caption).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            if mon.loading { ProgressView().controlSize(.small) }
            Menu {
                Button("Abrir configuração", systemImage: "doc.text") { openConfig() }
                Button("Recarregar configuração", systemImage: "arrow.triangle.2.circlepath") { mon.loadConfig() }
                Divider()
                Button("Testar alarme", systemImage: "bell.badge") { alarms.test(mon.config.alarms) }
            } label: {
                Label("Opções", systemImage: "gearshape")
            }
            .menuStyle(.button)
            .fixedSize()
            Button {
                Task { await mon.refresh() }
            } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Circle().fill(statusLevel.color).frame(width: 14, height: 14)
                .shadow(color: statusLevel.color, radius: 6)
            Text(statusText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(statusLevel.color)
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    legend(.ok, "Normal")
                    legend(.warn, "Limítrofe")
                }
                GridRow {
                    legend(.bad, "Ruim / crítico")
                    legend(.info, "Informativo")
                }
            }
            Spacer()
            Text("ups.status: \(mon.data["ups.status"] ?? "—")")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(statusLevel.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(statusLevel.color.opacity(0.5), lineWidth: 1.2))
    }

    private func openConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", UPSMonitor.configURL.path]
        try? p.run()
    }

    private func infoBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
            Text(text).font(.callout)
            Spacer()
            Button { alarms.testResult = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(Level.info.color)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Level.info.color.opacity(0.12)))
    }

    private func errorBanner(_ e: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Falha ao consultar o nobreak: \(e)").font(.callout)
            Spacer()
        }
        .foregroundColor(Level.bad.color)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Level.bad.color.opacity(0.12)))
    }

    private func configBanner(_ e: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
            Text(e).font(.callout)
            Spacer()
        }
        .foregroundColor(Level.warn.color)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Level.warn.color.opacity(0.12)))
    }

    private var alarmPanel: some View {
        VStack(spacing: 8) {
            ForEach(alarms.active) { a in
                HStack(spacing: 12) {
                    Image(systemName: a.level == .bad ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.headline)
                        Text(a.detail).font(.caption).opacity(0.85)
                    }
                    Spacer()
                }
                .foregroundColor(a.level.color)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(a.level.color.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(a.level.color.opacity(0.6), lineWidth: 1.2))
            }
            if mon.config.alarms.sound && !alarms.muted && alarms.active.contains(where: { $0.level == .bad }) {
                HStack {
                    Spacer()
                    Button("Silenciar som") { alarms.muted = true }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var details: some View {
        DisclosureGroup("Todos os dados brutos (\(mon.data.count))") {
            VStack(spacing: 0) {
                ForEach(mon.data.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k).foregroundColor(.white.opacity(0.55))
                        Spacer()
                        Text(mon.data[k] ?? "").foregroundColor(.white)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, 5)
                    Divider().opacity(0.15)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.04)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(UPSMonitor.configURL.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
            Spacer()
            if let d = mon.lastUpdate {
                Text("Atualizado às \(d.formatted(date: .omitted, time: .standard)) • a cada \(String(format: "%g", mon.config.pollIntervalSeconds)) s")
                    .font(.caption).foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private func legend(_ l: Level, _ t: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(l.color).frame(width: 9, height: 9)
            Text(t).font(.caption).foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - App

@main
struct NobreakMonitorApp: App {
    var body: some Scene {
        WindowGroup("Monitor de Nobreak") {
            ContentView().frame(minWidth: 780, minHeight: 720)
        }
    }
}
