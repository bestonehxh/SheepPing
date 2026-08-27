//
//  SheepPingApp.swift
//  SheepPing
//
//  Created by Bestchaan on 2/5/2569 BE.
//

import SwiftUI

@main
struct SheepPingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .help) { }
        }
    }
}
