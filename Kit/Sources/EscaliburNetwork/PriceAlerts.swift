import Foundation

/// Uma moeda que o dono quer acompanhar nos alertas de preco.
public struct WatchedCoin: Codable, Sendable, Hashable, Identifiable {
    /// Id do CoinGecko.
    public let id: String
    public let symbol: String
    public let name: String

    public init(id: String, symbol: String, name: String) {
        self.id = id
        self.symbol = symbol
        self.name = name
    }
}

/// O que um alerta diz. O texto e montado no app; aqui so o fato.
public enum PriceAlertEvent: Sendable, Equatable {
    /// O preco subiu e passou de um numero redondo.
    case crossedUp(level: Double)
    /// O preco caiu e ficou abaixo de um numero redondo.
    case crossedDown(level: Double)
    /// A variacao de 24 h passou da faixa escolhida, em %, com sinal.
    case moved(change: Double)
}

/// O que a checagem lembra de cada moeda entre uma vez e outra.
public struct PriceAlertMemory: Codable, Sendable, Equatable {
    /// O ultimo preco aceito, base para ver se um numero redondo foi cruzado.
    public var lastPrice: Double?
    public var lastPriceAt: Date?
    /// O ultimo numero redondo avisado, e quando.
    public var lastLevel: Double?
    public var lastLevelAt: Date?
    /// A faixa de variacao ja avisada: sinal da direcao vezes quantas vezes o limite.
    public var moveBand: Int = 0
    public var moveBandAt: Date?
    /// Um salto grande demais espera a leitura seguinte confirmar antes de virar aviso.
    public var suspectPrice: Double?

    public init() {}
}

/// As regras dos alertas de preco, sem rede e sem relogio proprio: o app passa o preco
/// lido e a hora, e recebe o que avisar.
///
/// Numero redondo: os niveis tem dois algarismos significativos (1,00; 1,10; 10;
/// 100; 1.000; 1.100; 80.000; 81.000). Entre dois niveis vizinhos ha de 1% a 10% de
/// distancia, em qualquer faixa de preco. Um nivel avisado nao volta a avisar em 12 h,
/// para o preco que oscila em cima dele nao virar uma fila de alertas.
///
/// Variacao em 24 h: a faixa e o numero de vezes que a variacao cabe no limite (com
/// limite de 10%, +23% e a faixa 2). Avisa quando a faixa cresce, quando a direcao
/// inverte, ou quando o ultimo aviso tem mais de 20 h.
///
/// Salto: preco que se afasta mais de 50% da base fica em suspeita e so avisa se a
/// leitura seguinte confirmar. Um provedor que erre ou minta uma vez nao poe uma queda
/// falsa na tela bloqueada. E a camada de dentro: o preco que chega aqui ja foi
/// confirmado por duas fontes (`MarketService.alertQuotes`).
public enum PriceAlertRules {
    public static let levelQuiet: TimeInterval = 12 * 3600
    public static let moveQuiet: TimeInterval = 20 * 3600
    public static let jumpLimit = 0.5
    public static let confirmTolerance = 0.05

    /// A potencia de 10 do algarismo mais alto do preco, sem o erro do `log10` nas
    /// pontas (1.000 e 0,001).
    static func magnitude(_ price: Double) -> Int {
        var exponent = Int(floor(log10(price)))
        if power(exponent) > price { exponent -= 1 }
        if power(exponent + 1) <= price { exponent += 1 }
        return exponent
    }

    /// 10 elevado a `exponent`; abaixo de zero, por divisao, que e exata ate 10^22.
    static func power(_ exponent: Int) -> Double {
        exponent >= 0 ? pow(10, Double(exponent)) : 1 / pow(10, Double(-exponent))
    }

    /// O nivel `count` vezes o passo de 10^`exponent`, montado do jeito que sai exato.
    static func level(_ count: Double, _ exponent: Int) -> Double {
        exponent >= 0 ? count * pow(10, Double(exponent)) : count / pow(10, Double(-exponent))
    }

    /// O maior numero redondo menor ou igual ao preco.
    public static func level(atOrBelow price: Double) -> Double {
        let exponent = magnitude(price) - 1
        let count = floor(price / power(exponent) * (1 + 1e-12))
        return level(count, exponent)
    }

    /// O menor numero redondo maior que o preco.
    public static func level(above price: Double) -> Double {
        let exponent = magnitude(price) - 1
        let count = floor(price / power(exponent) * (1 + 1e-12))
        return level(count + 1, exponent)
    }

    /// O numero redondo cruzado entre duas leituras, o mais perto do preco novo.
    public static func crossing(from old: Double, to new: Double) -> PriceAlertEvent? {
        guard old.isFinite, new.isFinite, old > 0, new > 0, old != new else { return nil }
        if new > old {
            let mark = level(atOrBelow: new)
            return mark > old ? .crossedUp(level: mark) : nil
        }
        let mark = level(above: new)
        return mark <= old ? .crossedDown(level: mark) : nil
    }

    /// Confere uma leitura e devolve o que avisar, atualizando a memoria da moeda.
    ///
    /// A primeira leitura de uma moeda so marca a base: ligar os alertas num dia de
    /// alta nao dispara uma rajada de avisos sobre o que ja tinha acontecido.
    public static func evaluate(
        price: Double,
        change24h: Double?,
        memory: inout PriceAlertMemory,
        roundNumbers: Bool,
        moveThreshold: Double?,
        now: Date
    ) -> [PriceAlertEvent] {
        guard price.isFinite, price > 0 else { return [] }
        let band = moveThreshold.flatMap { limit in change24h.map { Self.band($0, limit: limit) } } ?? 0

        guard let base = memory.lastPrice else {
            memory.lastPrice = price
            memory.lastPriceAt = now
            memory.moveBand = band
            memory.moveBandAt = band == 0 ? nil : now
            return []
        }

        if abs(price / base - 1) > jumpLimit {
            let confirmed = memory.suspectPrice.map { abs(price / $0 - 1) <= confirmTolerance } ?? false
            guard confirmed else {
                memory.suspectPrice = price
                return []
            }
        }
        memory.suspectPrice = nil

        var events: [PriceAlertEvent] = []
        if roundNumbers, let event = crossing(from: base, to: price) {
            let mark: Double
            switch event {
            case .crossedUp(let level), .crossedDown(let level): mark = level
            case .moved: mark = 0
            }
            let quiet = memory.lastLevel == mark && memory.lastLevelAt.map { now.timeIntervalSince($0) < levelQuiet } == true
            if !quiet {
                events.append(event)
                memory.lastLevel = mark
                memory.lastLevelAt = now
            }
        }

        if band != 0, let change24h {
            let expired = memory.moveBandAt.map { now.timeIntervalSince($0) >= moveQuiet } ?? true
            let flipped = memory.moveBand != 0 && (memory.moveBand > 0) != (band > 0)
            if expired || flipped || abs(band) > abs(memory.moveBand) {
                events.append(.moved(change: change24h))
                memory.moveBand = band
                memory.moveBandAt = now
            }
        }

        memory.lastPrice = price
        memory.lastPriceAt = now
        return events
    }

    /// Quantas vezes a variacao cabe no limite, com o sinal da direcao.
    static func band(_ change: Double, limit: Double) -> Int {
        guard change.isFinite, limit > 0 else { return 0 }
        let count = Int(floor(abs(change) / limit))
        return change < 0 ? -count : count
    }
}
