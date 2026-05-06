#if os(macOS)
import AppKit
#endif

enum FlowSelectionModifier {

    static var isAdditiveSelectionActive: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

}
