import Darwin
import Foundation
import Libmpv

struct MPVLibrary: @unchecked Sendable {
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias RequestLogMessages = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias SetOption = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    typealias SetOptionString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    typealias Wakeup = @convention(c) (OpaquePointer?) -> Void
    typealias TerminateDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias SetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    typealias GetProperty = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    typealias GetPropertyString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeNodeContents = @convention(c) (UnsafeMutablePointer<mpv_node>?) -> Void
    typealias WaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeMutablePointer<mpv_event>?
    typealias EventName = @convention(c) (mpv_event_id) -> UnsafePointer<CChar>?
    typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias Command = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32

    let sourceDescription: String
    let create: Create
    let requestLogMessages: RequestLogMessages
    let setOption: SetOption
    let setOptionString: SetOptionString
    let initialize: Initialize
    let wakeup: Wakeup
    let terminateDestroy: TerminateDestroy
    let setProperty: SetProperty
    let getProperty: GetProperty
    let getPropertyString: GetPropertyString
    let free: Free
    let freeNodeContents: FreeNodeContents
    let waitEvent: WaitEvent
    let eventName: EventName
    let errorString: ErrorString
    let command: Command

    func eventNameString(_ eventID: mpv_event_id) -> String {
        guard let pointer = eventName(eventID) else { return "unknown" }
        return String(cString: pointer)
    }

    func errorMessage(_ status: Int32) -> String {
        guard let pointer = errorString(status) else { return "mpv error \(status)" }
        return String(cString: pointer)
    }

    static func load(settings: AppSettings = .shared) -> MPVLibrary {
        return linked
    }

    private static let linked = MPVLibrary(
        sourceDescription: "Bundled MPVKit \(SwiftTubeDependencyManager.requiredMPVKitVersion)",
        create: mpv_create,
        requestLogMessages: mpv_request_log_messages,
        setOption: mpv_set_option,
        setOptionString: mpv_set_option_string,
        initialize: mpv_initialize,
        wakeup: mpv_wakeup,
        terminateDestroy: mpv_terminate_destroy,
        setProperty: mpv_set_property,
        getProperty: mpv_get_property,
        getPropertyString: mpv_get_property_string,
        free: mpv_free,
        freeNodeContents: mpv_free_node_contents,
        waitEvent: mpv_wait_event,
        eventName: mpv_event_name,
        errorString: mpv_error_string,
        command: mpv_command
    )

    private static func loadDynamic(path: String) throws -> MPVLibrary {
        let loadPath = SwiftTubeDependencyManager.mpvLoadablePath(for: path) ?? path
        guard let handle = dlopen(loadPath, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw BackendClientError(message: "Could not load MPVKit at \(path): \(message)")
        }

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw BackendClientError(message: "The selected MPVKit copy is missing \(name).")
            }
            return unsafeBitCast(raw, to: type)
        }

        return MPVLibrary(
            sourceDescription: path,
            create: try symbol("mpv_create", as: Create.self),
            requestLogMessages: try symbol("mpv_request_log_messages", as: RequestLogMessages.self),
            setOption: try symbol("mpv_set_option", as: SetOption.self),
            setOptionString: try symbol("mpv_set_option_string", as: SetOptionString.self),
            initialize: try symbol("mpv_initialize", as: Initialize.self),
            wakeup: try symbol("mpv_wakeup", as: Wakeup.self),
            terminateDestroy: try symbol("mpv_terminate_destroy", as: TerminateDestroy.self),
            setProperty: try symbol("mpv_set_property", as: SetProperty.self),
            getProperty: try symbol("mpv_get_property", as: GetProperty.self),
            getPropertyString: try symbol("mpv_get_property_string", as: GetPropertyString.self),
            free: try symbol("mpv_free", as: Free.self),
            freeNodeContents: try symbol("mpv_free_node_contents", as: FreeNodeContents.self),
            waitEvent: try symbol("mpv_wait_event", as: WaitEvent.self),
            eventName: try symbol("mpv_event_name", as: EventName.self),
            errorString: try symbol("mpv_error_string", as: ErrorString.self),
            command: try symbol("mpv_command", as: Command.self)
        )
    }
}
