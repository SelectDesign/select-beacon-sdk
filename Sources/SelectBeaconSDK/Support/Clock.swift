/// Injectable clock so observation windows and upload timing are testable.
import Foundation

protocol Clock {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}
