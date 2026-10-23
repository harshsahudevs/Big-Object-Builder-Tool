/**
 * Record Archiving Engine — orchestrates archiving a whole record AND its direct (one-level)
 * related child records into their respective Big Objects.
 *
 * Design (confirmed scope): depth = root + direct children (1 level); automatic discovery; any
 * related object WITHOUT a configured Big Object is skipped and reported (never a hard failure).
 *
 * How it works:
 *  - The root record is archived into the Big Object the caller chose.
 *  - Direct child relationships are discovered via describe. For each child object that has a
 *    mapped Big Object (from Big_Object_Field_Mapping__c, the same config the archive UI uses),
 *    the related child records are archived into that Big Object. Child objects with no Big Object
 *    are reported in `skippedObjects`.
 *  - Every single-object archive delegates to the proven BigObjectArchiveService.archiveRecords,
 *    so field mapping, index-key building, insertImmediate, source stamping, partial success, and
 *    archive logging all behave exactly as the single-record path.
 *
 * v1 is archive-only (backup semantics): it does NOT delete source records, because deleting a
 * parent that still has children can cascade-delete or orphan the children. Delete-with-hierarchy
 * is a deliberate later decision. Faithful unarchive (re-linking children to the restored parent)
 * is the separate unarchive engine, built next.
 */
public with sharing class RecordArchivingEngine {
    // Upper bound on distinct related objects processed in one transaction (keeps SOQL/DML bounded;
    // each related object needs its own query + insertImmediate, which cannot be batched together).
    private static final Integer MAX_RELATED_OBJECTS = 25;

    public class RecordArchivingException extends Exception {}

    /** Per-object outcome within an archive set (the root, or one related child object). */
    public class ObjectArchiveSummary {
        @AuraEnabled public String sourceObject;
        @AuraEnabled public String sourceLabel;
        @AuraEnabled public String bigObject;
        @AuraEnabled public Boolean isRoot;
        @AuraEnabled public Integer archivedCount;
        @AuraEnabled public Integer failedCount;
        @AuraEnabled public String errorMessage;

        public ObjectArchiveSummary(String sourceObject, String bigObject, Boolean isRoot) {
            this.sourceObject = sourceObject;
            this.bigObject = bigObject;
            this.isRoot = isRoot;
            this.archivedCount = 0;
            this.failedCount = 0;
        }
    }

    /** Whole-record archive outcome returned to the LWC. */
    public class ArchiveSetResult {
        @AuraEnabled public Id rootRecordId;
        @AuraEnabled public String rootObject;
        @AuraEnabled public Boolean rootArchived;
        @AuraEnabled public Integer totalArchived;
        @AuraEnabled public Integer totalFailed;
        @AuraEnabled public List<ObjectArchiveSummary> summaries = new List<ObjectArchiveSummary>();
        // Related objects that have records linked to the root but no configured Big Object.
        @AuraEnabled public List<String> skippedObjects = new List<String>();

        public ArchiveSetResult(Id rootRecordId, String rootObject) {
            this.rootRecordId = rootRecordId;
            this.rootObject = rootObject;
            this.rootArchived = false;
            this.totalArchived = 0;
            this.totalFailed = 0;
        }
    }

    /**
     * Archives a root record and its direct related child records into their Big Objects.
     * @param rootRecordId The record to archive (its object determines the hierarchy root).
     * @param rootBigObjectApiName The Big Object to archive the root record into (caller's choice).
     * @return The archive-set outcome: per-object counts plus the list of related objects skipped
     *         because they have no configured Big Object.
     */
    @AuraEnabled
    public static ArchiveSetResult archiveRecordWithRelated(Id rootRecordId, String rootBigObjectApiName) {
        if (rootRecordId == null) {
            throw new AuraHandledException('A record Id is required.');
        }
        if (String.isBlank(rootBigObjectApiName) || !rootBigObjectApiName.endsWith('__b')) {
            throw new AuraHandledException('A valid root Big Object (ending in __b) is required.');
        }
        try {
            Schema.DescribeSObjectResult rootDescribe = rootRecordId.getSObjectType().getDescribe();
            String rootObject = rootDescribe.getName();
            ArchiveSetResult result = new ArchiveSetResult(rootRecordId, rootObject);

            // Build the plan: root + direct children that have a Big Object (queries only, no DML).
            List<ArchivePlan> plans = new List<ArchivePlan>();
            plans.add(new ArchivePlan(
                rootObject, rootDescribe.getLabel(), rootBigObjectApiName, true, new Set<Id>{ rootRecordId }
            ));
            buildChildPlans(rootRecordId, rootDescribe, rootObject, plans, result);

            // Phase 1 — Big Object inserts for every object FIRST (each is a query + insertImmediate
            // callout, no regular DML), so a later object's callout never follows prior regular DML.
            for (ArchivePlan plan : plans) {
                plan.summary = new ObjectArchiveSummary(plan.sourceObject, plan.bigObject, plan.isRoot);
                plan.summary.sourceLabel = plan.sourceLabel;
                try {
                    plan.results = BigObjectArchiveService.insertIntoBigObject(
                        plan.ids, plan.sourceObject, plan.bigObject
                    );
                    for (BigObjectArchiveService.ArchiveResult r : plan.results) {
                        if (r.isSuccess == true) {
                            plan.summary.archivedCount++;
                        } else {
                            plan.summary.failedCount++;
                            if (String.isBlank(plan.summary.errorMessage) && String.isNotBlank(r.errorMessage)) {
                                plan.summary.errorMessage = r.errorMessage;
                            }
                        }
                    }
                } catch (Exception e) {
                    // A per-object failure (e.g. no matching fields) must not abort the whole set.
                    plan.summary.failedCount = plan.ids.size();
                    plan.summary.errorMessage = e.getMessage();
                    plan.results = null;
                }
            }

            // Phase 2 — side effects (source stamping + archive logging = regular DML) AFTER every
            // insertImmediate callout in the transaction has completed.
            for (ArchivePlan plan : plans) {
                if (plan.results != null && !plan.results.isEmpty()) {
                    BigObjectArchiveService.applyArchiveSideEffects(plan.sourceObject, plan.bigObject, plan.results);
                }
            }

            // Assemble the result.
            for (ArchivePlan plan : plans) {
                result.summaries.add(plan.summary);
                tally(result, plan.summary);
                if (plan.isRoot) {
                    result.rootArchived = plan.summary.archivedCount > 0;
                }
            }
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Record archiving failed: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Child discovery (queries only — no DML, so it runs before any insertImmediate)
    // ---------------------------------------------------------------------

    /** A single object's archive unit within the set (carries its records, results, and summary). */
    private class ArchivePlan {
        String sourceObject;
        String sourceLabel;
        String bigObject;
        Boolean isRoot;
        Set<Id> ids;
        List<BigObjectArchiveService.ArchiveResult> results;
        ObjectArchiveSummary summary;

        ArchivePlan(String sourceObject, String sourceLabel, String bigObject, Boolean isRoot, Set<Id> ids) {
            this.sourceObject = sourceObject;
            this.sourceLabel = sourceLabel;
            this.bigObject = bigObject;
            this.isRoot = isRoot;
            this.ids = ids;
        }
    }

    /**
     * Walks the root's direct child relationships. For each child object that has a mapped Big
     * Object and has related records, adds an ArchivePlan; child objects with a Big Object gap are
     * reported in result.skippedObjects. Bounded to MAX_RELATED_OBJECTS. Only queries are run here.
     */
    private static void buildChildPlans(
        Id rootRecordId, Schema.DescribeSObjectResult rootDescribe, String rootObject,
        List<ArchivePlan> plans, ArchiveSetResult result
    ) {
        Map<String, String> bigObjectBySource = resolveBigObjectsBySource();

        // Group relationship fields by child object (an object can relate to the root via >1 field).
        Map<String, Set<String>> relFieldsByChild = new Map<String, Set<String>>();
        Map<String, String> labelByChild = new Map<String, String>();
        Set<String> skipped = new Set<String>();

        for (Schema.ChildRelationship rel : rootDescribe.getChildRelationships()) {
            Schema.SObjectType childType = rel.getChildSObject();
            Schema.SObjectField relField = rel.getField();
            if (childType == null || relField == null) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = childType.getDescribe();
            String childObject = childDescribe.getName();
            // Only real, archivable data objects: queryable, createable, not a system child object.
            if (!childDescribe.isQueryable() || !childDescribe.isCreateable() || isSystemObject(childObject)) {
                continue;
            }
            if (childObject.equalsIgnoreCase(rootObject)) {
                continue; // don't treat the root object as its own child
            }
            if (bigObjectBySource.containsKey(childObject.toLowerCase())) {
                if (!relFieldsByChild.containsKey(childObject)) {
                    relFieldsByChild.put(childObject, new Set<String>());
                    labelByChild.put(childObject, childDescribe.getLabel());
                }
                relFieldsByChild.get(childObject).add(relField.getDescribe().getName());
            } else {
                skipped.add(childDescribe.getLabel() + ' (' + childObject + ')');
            }
        }

        Integer processed = 0;
        for (String childObject : relFieldsByChild.keySet()) {
            if (processed >= MAX_RELATED_OBJECTS) {
                break;
            }
            Set<Id> childIds = queryRelatedIds(childObject, relFieldsByChild.get(childObject), rootRecordId);
            if (childIds.isEmpty()) {
                continue; // no related records of this object; nothing to archive
            }
            plans.add(new ArchivePlan(
                childObject, labelByChild.get(childObject), bigObjectBySource.get(childObject.toLowerCase()),
                false, childIds
            ));
            processed++;
        }

        List<String> skippedList = new List<String>(skipped);
        skippedList.sort();
        result.skippedObjects = skippedList;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /**
     * source object API name (lowercased) -> target Big Object API name, from the mapping config.
     * When a source object maps to more than one Big Object, the first (alphabetical) is used.
     */
    private static Map<String, String> resolveBigObjectsBySource() {
        Map<String, String> bigObjectBySource = new Map<String, String>();
        for (AggregateResult ar : [
            SELECT Source_Object__c src, MIN(Big_Object__c) bo
            FROM Big_Object_Field_Mapping__c
            WHERE Source_Object__c != null AND Big_Object__c != null
            WITH USER_MODE
            GROUP BY Source_Object__c
        ]) {
            String src = (String) ar.get('src');
            String bo = (String) ar.get('bo');
            if (String.isNotBlank(src) && String.isNotBlank(bo)) {
                bigObjectBySource.put(src.toLowerCase(), bo);
            }
        }
        return bigObjectBySource;
    }

    /** Queries the Ids of related child records pointing at the root through any of the given fields. */
    private static Set<Id> queryRelatedIds(String childObject, Set<String> relationshipFields, Id rootRecordId) {
        List<String> clauses = new List<String>();
        for (String relField : relationshipFields) {
            clauses.add(String.escapeSingleQuotes(relField) + ' = :rootRecordId');
        }
        String query =
            'SELECT Id FROM ' + String.escapeSingleQuotes(childObject)
            + ' WHERE ' + String.join(clauses, ' OR ')
            + ' WITH USER_MODE LIMIT 10000';
        Set<Id> ids = new Set<Id>();
        for (SObject record : Database.query(query)) {
            ids.add((Id) record.get('Id'));
        }
        return ids;
    }

    /** True for auto-generated system child objects that are never meaningful archive targets. */
    private static Boolean isSystemObject(String apiName) {
        String lower = apiName.toLowerCase();
        return lower.endsWith('share')
            || lower.endsWith('history')
            || lower.endsWith('feed')
            || lower.endsWith('changeevent')
            || lower.endsWith('__tag')
            || lower.endsWith('tag');
    }

    private static void tally(ArchiveSetResult result, ObjectArchiveSummary summary) {
        result.totalArchived += summary.archivedCount;
        result.totalFailed += summary.failedCount;
    }
}
