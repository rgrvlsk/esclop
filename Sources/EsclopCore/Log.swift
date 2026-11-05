// SPDX-License-Identifier: GPL-3.0-or-later
//
// One logging subsystem for every module, so `log stream --predicate 'subsystem == "dev.esclop"'`
// shows the app, the CLI and the MCP server together.

import os

public enum Log {
    public static let subsystem = "dev.esclop"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let core = logger("core")
    public static let settings = logger("settings")
    public static let tools = logger("tools")
    public static let process = logger("process")
    public static let backups = logger("backups")
    public static let engine = logger("engine")
    public static let image = logger("image")
    public static let video = logger("video")
    public static let pdf = logger("pdf")
    public static let audio = logger("audio")
    public static let clipboard = logger("clipboard")
}
