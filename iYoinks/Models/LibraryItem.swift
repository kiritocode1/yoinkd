import CoreData
import Foundation
import YoinksCore

/// Metadata for a file already committed to app storage. Capture drafts do not belong here.
@objc(LibraryItem)
final class LibraryItem: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var mediaKindRawValue: String
    @NSManaged var relativeFileName: String
    @NSManaged var sourceURL: URL?
    @NSManaged var addedAt: Date

    convenience init(context: NSManagedObjectContext, title: String, kind: MediaKind, fileName: MediaFileName, source: MediaLink? = nil, addedAt: Date = .now) {
        self.init(context: context)
        id = UUID()
        self.title = title
        mediaKindRawValue = kind.rawValue
        relativeFileName = fileName.value
        sourceURL = source?.url
        self.addedAt = addedAt
    }

    var mediaKind: MediaKind? {
        MediaKind(rawValue: mediaKindRawValue)
    }

    @MainActor
    static func makeModel() -> NSManagedObjectModel {
        func attribute(_ name: String, type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let entity = NSEntityDescription()
        entity.name = "LibraryItem"
        entity.managedObjectClassName = NSStringFromClass(LibraryItem.self)
        entity.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("title", type: .stringAttributeType),
            attribute("mediaKindRawValue", type: .stringAttributeType),
            attribute("relativeFileName", type: .stringAttributeType),
            attribute("sourceURL", type: .URIAttributeType, optional: true),
            attribute("addedAt", type: .dateAttributeType)
        ]
        entity.uniquenessConstraints = [["id"]]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    @MainActor
    static func previewContext() throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: makeModel())
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
