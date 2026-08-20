public enum PressureSelectionStrategy: Sendable, Hashable {
    case maximum
    case average
    case touch(id: Int32)
    case firstTouch
}
