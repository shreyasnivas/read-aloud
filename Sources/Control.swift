// GUI actions (M2). M1 calls these and gets nothing back until the tools exist.
import AppKit

enum Control {
    static func toolDefs() -> [[String: Any]] { [] }

    static func perform(_ name: String, _ args: [String: Any], confirm: (String, String) -> Bool) -> ToolResult? {
        _ = (name, args, confirm)
        return nil
    }
}
