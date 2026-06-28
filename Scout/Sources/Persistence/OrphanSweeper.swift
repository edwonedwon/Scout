import CoreData

/// Auto-removes records that are no longer reachable from any live project — "orphans" left
/// behind by a deleted project, a failed cascade, or CloudKit merge races. Run on launch and
/// after any action that can strand records (hard-deleting a project, emptying the trash).
///
/// CRASH-SAFETY (same approach as DataInspectorView): an orphan's to-one relationship may point
/// at a deleted object; faulting it crashes ("backing data could no longer be found"). So we
/// build the reachable-id set from the LIVE project graph (all valid), read only each orphan's
/// OWN `uuid` attribute (safe), then BATCH delete by uuid (store-level SQL that never materializes
/// the objects or their dangling relationships).
enum OrphanSweeper {
    @discardableResult
    static func sweep(context: NSManagedObjectContext) -> Int {
        var listIDs = Set<NSManagedObjectID>()
        var pinIDs = Set<NSManagedObjectID>()
        var scriptIDs = Set<NSManagedObjectID>()
        var highlightIDs = Set<NSManagedObjectID>()

        let projects = (try? context.fetch(NSFetchRequest<ProjectData>(entityName: "ProjectData"))) ?? []
        func walk(_ l: LocationListData) {
            guard listIDs.insert(l.objectID).inserted else { return }
            for pin in l.pins { pinIDs.insert(pin.objectID) }
            for child in l.childLists { walk(child) }
        }
        for p in projects {
            for l in p.lists where l.parentList == nil { walk(l) }
            for pin in p.importedPhotos { pinIDs.insert(pin.objectID) }
            for s in p.scripts {
                scriptIDs.insert(s.objectID)
                for h in s.highlights { highlightIDs.insert(h.objectID) }
            }
        }

        func orphanUUIDs<T: NSManagedObject>(_ type: T.Type, reachable: Set<NSManagedObjectID>,
                                             uuid: (T) -> UUID) -> [UUID] {
            let all = (try? context.fetch(NSFetchRequest<T>(entityName: String(describing: T.self)))) ?? []
            return all.filter { !reachable.contains($0.objectID) }.map(uuid)
        }

        let pinUUIDs = orphanUUIDs(PinnedLocationData.self, reachable: pinIDs) { $0.uuid }
        let listUUIDs = orphanUUIDs(LocationListData.self, reachable: listIDs) { $0.uuid }
        let scriptUUIDs = orphanUUIDs(ScriptData.self, reachable: scriptIDs) { $0.uuid }
        let highlightUUIDs = orphanUUIDs(ScriptHighlight.self, reachable: highlightIDs) { $0.uuid }

        var deleted = 0
        deleted += batchDelete(PinnedLocationData.self, uuids: pinUUIDs, context: context)
        deleted += batchDelete(LocationListData.self, uuids: listUUIDs, context: context)
        deleted += batchDelete(ScriptData.self, uuids: scriptUUIDs, context: context)
        deleted += batchDelete(ScriptHighlight.self, uuids: highlightUUIDs, context: context)
        if deleted > 0 { try? context.save() }
        return deleted
    }

    @discardableResult
    private static func batchDelete<T: NSManagedObject>(_ type: T.Type, uuids: [UUID],
                                                        context: NSManagedObjectContext) -> Int {
        guard !uuids.isEmpty else { return 0 }
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: T.self))
        req.predicate = NSPredicate(format: "uuidRaw IN %@", uuids)
        let delete = NSBatchDeleteRequest(fetchRequest: req)
        delete.resultType = .resultTypeObjectIDs
        guard let result = try? context.execute(delete) as? NSBatchDeleteResult,
              let ids = result.result as? [NSManagedObjectID], !ids.isEmpty else { return 0 }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
        return ids.count
    }
}
