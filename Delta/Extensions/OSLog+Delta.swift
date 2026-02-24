//
//  OSLog+Delta.swift
//  Delta
//
//  Created by Riley Testut on 8/10/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

@_exported import OSLog

extension OSLog.Category
{
    static var main: String { "Main" }
    static var database: String { "Database" }
    static var purchases: String { "Purchases" }
    static var achievements: String { "Achievements" }
}

extension Logger
{
    static var deltaSubsystem: String { "com.rileytestut.Delta" }
    
    static var main: Logger { Logger(subsystem: deltaSubsystem, category: OSLog.Category.main) }
    static var database: Logger { Logger(subsystem: deltaSubsystem, category: OSLog.Category.database) }
    static var purchases: Logger { Logger(subsystem: deltaSubsystem, category: OSLog.Category.purchases) }
    static var achievements: Logger { Logger(subsystem: deltaSubsystem, category: OSLog.Category.achievements) }
}

@available(iOS 15, *)
extension OSLogEntryLog.Level
{
    var localizedName: String {
        switch self
        {
        case .undefined: return NSLocalizedString("Undefined", comment: "")
        case .debug: return NSLocalizedString("Debug", comment: "")
        case .info: return NSLocalizedString("Info", comment: "")
        case .notice: return NSLocalizedString("Notice", comment: "")
        case .error: return NSLocalizedString("Error", comment: "")
        case .fault: return NSLocalizedString("Fault", comment: "")
        @unknown default: return NSLocalizedString("Unknown", comment: "")
        }
    }
}
