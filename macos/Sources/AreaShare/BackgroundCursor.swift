import AppKit

/// Lets this app choose the pointer shape while another app is active.
///
/// The frame never activates the app, and macOS ignores a background app's
/// pointer changes, so without this the resize and move pointers would never
/// appear over the frame. The window server has a per-connection switch for
/// it that is not in the public headers; it is looked up by name at run time,
/// and if a future macOS drops it the frame simply keeps the arrow pointer.
enum BackgroundCursor {
    static func enable() {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connectionSymbol = dlsym(anyImage, "CGSMainConnectionID"),
              let setSymbol = dlsym(anyImage, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)()
        _ = unsafeBitCast(setSymbol, to: SetProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
