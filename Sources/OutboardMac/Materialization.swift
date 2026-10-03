import Darwin

/// Stops this process from downloading ("materializing") dataless iCloud files, so no scan or metadata read can pull
/// content down from iCloud. Reading a dataless file then fails with EDEADLK instead (TN3150). Called first thing in the
/// app's init (BUILD_PLAN §3 rule 9); there is deliberately no way to turn it back on.
public enum Materialization {
    // Values from <sys/resource.h>, spelled out so we don't depend on how the C macros import. VERIFY on a Mac.
    private static let typeMaterializeDatalessFiles: Int32 = 3 // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    private static let scopeProcess: Int32 = 0                 // IOPOL_SCOPE_PROCESS
    private static let materializeOff: Int32 = 1               // IOPOL_MATERIALIZE_DATALESS_FILES_OFF

    @discardableResult
    public static func disableForProcess() -> Bool {
        setiopolicy_np(typeMaterializeDatalessFiles, scopeProcess, materializeOff) == 0
    }
}
