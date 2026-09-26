import Observation
import SwiftUI

/// O estado de alto nivel do app: primeira abertura, trancado, aberto.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case welcome
        case locked
        case unlocked
    }

    var phase: Phase = .welcome
}
