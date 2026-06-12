/*
 * coredatacli.m — M6: CoreData persistence on the substrate (a whole framework
 * tier: NSManagedObjectModel + NSPersistentStoreCoordinator + NSManagedObject
 * Context, backed by the staged SQLite store).
 *
 * Loads a COMPILED model (.momd) via initWithContentsOfURL: — one entity "Note"
 * with a string `title` and an int `count`. (The programmatic NSAttributeDescription
 * path throws "abstract class" here: Darling's CoreData is Cocotron-based and its
 * NSPropertyDescription -init is an abstract stub. Loading a momc-compiled model
 * bypasses that.) Adds a SQLite store on disk, inserts rows, saves, then opens a
 * SECOND coordinator/context against the SAME file and fetches — proving the data
 * actually persisted through SQLite, not just lived in memory.
 *
 * Real Objective-C (compiler objc_msgSend), building on the proven Foundation/ObjC
 * runtime. Headless (no GUI), like the other CLI probes.
 *
 *   M6-MODEL-OK            model + entity + attributes constructed
 *   M6-STORE-OK            SQLite persistent store added
 *   M6-INSERTED-3          3 Note objects inserted + context saved
 *   M6-FILE-<bytes>        the .sqlite file exists on disk with non-zero size
 *   M6-REFETCH-3           a FRESH coordinator/context re-read 3 rows from the file
 *   M6-VALUE-ANSWER-42     a fetched object's attributes round-tripped (title+count)
 *   M6-DONE
 */
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>

// Load the compiled model from the bundled .momd (built on the host with momc).
// Avoids Cocotron's throwing programmatic NSAttributeDescription -init.
static NSManagedObjectModel* buildModel(void) {
    NSString* momPath = @"/usr/share/m6/Note.momd";
    NSURL* u = [NSURL fileURLWithPath:momPath];
    NSManagedObjectModel* model = [[NSManagedObjectModel alloc] initWithContentsOfURL:u];
    return model;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* path = @"/var/root/m6notes.sqlite";
        // Clean any leftover from a prior run so counts are deterministic.
        unlink([path UTF8String]);
        NSURL* url = [NSURL fileURLWithPath:path];

        NSManagedObjectModel* model = buildModel();
        if (!model || [[model entities] count] != 1) { printf("M6-MODEL-FAIL\n"); fflush(stdout); printf("M6-DONE\n"); return 0; }
        printf("M6-MODEL-OK\n"); fflush(stdout);

        // --- Phase 1: write ---
        NSPersistentStoreCoordinator* psc =
            [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSError* err = nil;
        NSPersistentStore* store =
            [psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                        URL:url options:nil error:&err];
        if (!store) { printf("M6-STORE-FAIL-%s\n", err ? [[err localizedDescription] UTF8String] : "nil"); fflush(stdout); printf("M6-DONE\n"); return 0; }
        printf("M6-STORE-OK\n"); fflush(stdout);

        NSManagedObjectContext* ctx =
            [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [ctx setPersistentStoreCoordinator:psc];

        for (int i = 0; i < 3; i++) {
            NSManagedObject* note =
                [NSEntityDescription insertNewObjectForEntityForName:@"Note"
                                             inManagedObjectContext:ctx];
            [note setValue:[NSString stringWithFormat:@"note-%d", i] forKey:@"title"];
            // Make object i==2 carry the recognizable value 42 (6*7) in `count`.
            [note setValue:@(i == 2 ? 42 : i) forKey:@"count"];
        }
        if (![ctx save:&err]) { printf("M6-SAVE-FAIL-%s\n", err ? [[err localizedDescription] UTF8String] : "nil"); fflush(stdout); printf("M6-DONE\n"); return 0; }
        printf("M6-INSERTED-3\n"); fflush(stdout);

        // The file should now exist with real content.
        struct stat st;
        if (stat([path UTF8String], &st) == 0) {
            printf("M6-FILE-%lld\n", (long long)st.st_size); fflush(stdout);
        } else {
            printf("M6-FILE-MISSING\n"); fflush(stdout);
        }

        // --- Phase 2: re-open with a FRESH coordinator/context and fetch ---
        // Proves the data went to SQLite, not just an in-memory context.
        @autoreleasepool {
            NSPersistentStoreCoordinator* psc2 =
                [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
            NSError* e2 = nil;
            if (![psc2 addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                              URL:url options:nil error:&e2]) {
                printf("M6-REOPEN-FAIL-%s\n", e2 ? [[e2 localizedDescription] UTF8String] : "nil"); fflush(stdout);
                printf("M6-DONE\n"); return 0;
            }
            NSManagedObjectContext* ctx2 =
                [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
            [ctx2 setPersistentStoreCoordinator:psc2];

            NSFetchRequest* req = [NSFetchRequest fetchRequestWithEntityName:@"Note"];
            NSError* fe = nil;
            NSArray* rows = [ctx2 executeFetchRequest:req error:&fe];
            printf("M6-REFETCH-%lu\n", (unsigned long)[rows count]); fflush(stdout);

            // Find the object whose count==42 and confirm its title round-tripped.
            for (NSManagedObject* o in rows) {
                NSNumber* c = [o valueForKey:@"count"];
                if ([c intValue] == 42) {
                    NSString* t = [o valueForKey:@"title"];
                    printf("M6-VALUE-%s-%d\n",
                           [t UTF8String] ? [[t uppercaseString] UTF8String] : "NIL",
                           [c intValue]);
                    fflush(stdout);
                    break;
                }
            }
        }

        printf("M6-DONE\n"); fflush(stdout);
    }
    return 0;
}
