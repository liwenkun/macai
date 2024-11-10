//
//  ContentView.swift
//  macai
//
//  Created by Renat Notfullin on 11.03.2023.
//

import AppKit
import Combine
import CoreData
import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openWindow) var openWindow

    @FetchRequest(
        entity: ChatEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ChatEntity.updatedDate, ascending: false)],
        animation: .default
    )
    private var chats: FetchedResults<ChatEntity>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \APIServiceEntity.addedDate, ascending: false)])
    private var apiServices: FetchedResults<APIServiceEntity>

    @State var selectedChat: ChatEntity?
    @AppStorage("gptToken") var gptToken = ""
    @AppStorage("gptModel") var gptModel = AppConstants.chatGptDefaultModel
    @AppStorage("systemMessage") var systemMessage = AppConstants.chatGptSystemMessage
    @AppStorage("lastOpenedChatId") var lastOpenedChatId = ""
    @AppStorage("apiUrl") var apiUrl = AppConstants.apiUrlChatCompletions
    @AppStorage("defaultApiService") private var defaultApiServiceID: String?

    @State private var windowRef: NSWindow?
    @State private var openedChatId: String? = nil

    var body: some View {
        NavigationView {
            List {
                ForEach(chats, id: \.id) { chat in

                    let isActive = Binding<Bool>(
                        get: { !chat.isDeleted && self.selectedChat?.id == chat.id },
                        set: { newValue in
                            if newValue {
                                selectedChat = chat
                            }
                            else if selectedChat?.id == chat.id {
                                selectedChat = nil
                            }
                        }
                    )

                    let messagePreview = chat.lastMessage
                    let messageTimestamp = messagePreview?.timestamp ?? Date()
                    let messageBody = messagePreview?.body ?? ""

                    MessageCell(
                        chat: chats[getIndex(for: chat)],
                        timestamp: messageTimestamp,
                        message: messageBody,
                        isActive: isActive,
                        viewContext: viewContext
                    )
                    .contextMenu {
                        Button(action: {
                            renameChat(chat)
                        }) {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(action: {
                            deleteChat(chat)
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .tag(chat.id)
                }

            }
            .listStyle(SidebarListStyle())
            .navigationTitle("Chats")

            if selectedChat == nil {
                WelcomeScreen(
                    chatsCount: chats.count,
                    apiServiceIsPresent: apiServices.count > 0,
                    customUrl: apiUrl != AppConstants.apiUrlChatCompletions,
                    openPreferencesView: openPreferencesView,
                    newChat: newChat
                )
            }
            else {
                ChatView(
                    viewContext: viewContext,
                    chat: selectedChat!
                        //chatViewModel: ChatViewModel(chat: selectedChat!, viewContext: viewContext)
                )
                .id(openedChatId)
            }

        }
        .onAppear(perform: {
            if let lastOpenedChatId = UUID(uuidString: lastOpenedChatId) {
                if let lastOpenedChat = chats.first(where: { $0.id == lastOpenedChatId }) {
                    selectedChat = lastOpenedChat
                }
            }
        })
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil
                    )
                }) {
                    Image(systemName: "sidebar.left")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    newChat()
                }) {
                    Image(systemName: "square.and.pencil")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Image(systemName: "gear")
                    }
                }
                else {
                    Button(action: {
                        openPreferencesView()
                    }) {
                        Image(systemName: "gear")
                    }
                }
            }

        }
        .onChange(of: scenePhase) { phase in
            print("Scene phase changed: \(phase)")
            if phase == .inactive {
                print("Saving state...")
            }
        }
        .onChange(of: selectedChat) { newValue in
            if self.openedChatId != newValue?.id.uuidString {
                self.openedChatId = newValue?.id.uuidString
            }
        }
    }

    func newChat() {
        let uuid = UUID()
        let newChat = ChatEntity(context: viewContext)

        newChat.id = uuid
        newChat.newChat = true
        newChat.temperature = 0.8
        newChat.top_p = 1.0
        newChat.behavior = "default"
        newChat.newMessage = ""
        newChat.createdDate = Date()
        newChat.updatedDate = Date()
        newChat.systemMessage = systemMessage
        newChat.gptModel = gptModel

        if let defaultServiceIDString = defaultApiServiceID,
            let url = URL(string: defaultServiceIDString),
            let objectID = viewContext.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        {

            do {
                let defaultService = try viewContext.existingObject(with: objectID) as? APIServiceEntity
                newChat.apiService = defaultService
                newChat.persona = defaultService?.defaultPersona
                // TODO: Refactor the following code along with ChatView.swift
                newChat.gptModel = defaultService?.model ?? AppConstants.chatGptDefaultModel
                newChat.systemMessage = newChat.persona?.systemMessage ?? AppConstants.chatGptSystemMessage
            }
            catch {
                print("Default API service not found: \(error)")
            }
        }

        do {
            try viewContext.save()
            DispatchQueue.main.async {
                self.selectedChat?.objectWillChange.send()
                self.selectedChat = newChat
            }
        }
        catch {
            print("Error saving new chat: \(error.localizedDescription)")
            viewContext.rollback()
        }
    }

    func openPreferencesView() {
        if #available(macOS 13.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func getIndex(for chat: ChatEntity) -> Int {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            return index
        }
        else {
            fatalError("Chat not found in array")
        }
    }

    func deleteChat(_ chat: ChatEntity) {
        let alert = NSAlert()
        alert.messageText = "Delete chat?"
        alert.informativeText = "Are you sure you want to delete this chat?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                // Clear selectedChat to prevent accessing deleted item
                if selectedChat?.id == chat.id {
                    selectedChat = nil
                }
                viewContext.delete(chat)
                DispatchQueue.main.async {
                    do {
                        try viewContext.save()
                    }
                    catch {
                        print("Error deleting chat: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func renameChat(_ chat: ChatEntity) {
        let alert = NSAlert()
        alert.messageText = "Rename chat"
        alert.informativeText = "Enter new name for this chat"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = chat.name
        alert.accessoryView = textField
        alert.beginSheetModal(for: NSApp.keyWindow!) { response in
            if response == .alertFirstButtonReturn {
                chat.name = textField.stringValue
                do {
                    try viewContext.save()
                }
                catch {
                    print("Error renaming chat: \(error.localizedDescription)")
                }
            }
        }
    }
}
