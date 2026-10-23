/**
 * Unarchive Engine — the counterpart to RecordArchivingEngine. Restores a whole archived record:
 * the root row AND its direct (one-level) related child records, re-linking each restored child to
 * the newly-restored parent so the hierarchy comes back "as it was."
 *
 * How it works:
 *  - The root Big Object row (identified by its index key) is restored first. The platform cannot
 *    reuse the original Id, so the restored root gets a NEW Id — captured as newRootRecordId.
 *  - To pull the related rows back, the engine needs to know which archived child rows belonged to
 *    this root. That link is the child's original parent Id, which is only recoverable when:
 *      (a) the root Big Object stored the source record's original Id (a field resolving to `Id`),
 *          so the engine can read the root's ORIGINAL Id for the restored key, and
 *      (b) the child Big Object stored the child's parent-lookup value (e.g. AccountId).
 *    For each direct child object that has a mapped Big Object and stores its parent lookup, the
 *    engine finds the archived rows whose stored parent Id equals the root's original Id and
 *    restores them with that lookup OVERRIDDEN to the root's new Id (faithful re-link).
 *  - Where a fidelity precondition is not met (root Id not stored, parent lookup not stored, or the
 *    field is not queryable in this org), the engine restores what it can and reports the gap in
 *    `notes` / per-object `note` rather than failing or guessing.
 *
 * Ordering: unlike the archive engine, restore uses regular DML (record insert + log insert) and an
 * ASYNC Big Object delete (enqueued Queueable) — there is no synchronous Big Object callout here, so
 * the "callout-after-DML" two-phase constraint does not apply. Each object is restored sequentially.
 */
public with sharing class UnarchiveEngine {
    // Upper bound on distinct related objects processed in one transaction (keeps SOQL/DML bounded).
    private static final Integer MAX_RELATED_OBJECTS = 25;
    private static final String SOURCE_ID_FIELD = 'Id';

    public class UnarchiveException extends Exception {}

    /** Per-object outcome within an unarchive set (the root, or one related child object). */
    public class ObjectUnarchiveSummary {
        @AuraEnabled public String sourceObject;
        @AuraEnabled public String sourceLabel;
        @AuraEnabled public String bigObject;
        @AuraEnabled public Boolean isRoot;
        @AuraEnabled public Integer restoredCount;
        @AuraEnabled public Integer failedCount;
        // True when restored children were re-pointed to the root's new Id.
        @AuraEnabled public Boolean relinked;
        // Fidelity note when related rows could not be matched or re-linked.
        @AuraEnabled public String note;
        @AuraEnabled public String errorMessage;

        public ObjectUnarchiveSummary(String sourceObject, String sourceLabel, String bigObject, Boolean isRoot) {
            this.sourceObject = sourceObject;
            this.sourceLabel = sourceLabel;
            this.bigObject = bigObject;
            this.isRoot = isRoot;
            this.restoredCount = 0;
            this.failedCount = 0;
            this.relinked = false;
        }
    }

    /** Whole-record unarchive outcome returned to the LWC. */
    public class UnarchiveSetResult {
        @AuraEnabled public String rootBigObject;
        @AuraEnabled public String rootObject;
        @AuraEnabled public String rootRecordKey;
        @AuraEnabled public Boolean rootRestored;
        @AuraEnabled public Id newRootRecordId;
        @AuraEnabled public Integer totalRestored;
        @AuraEnabled public Integer totalFailed;
        @AuraEnabled public List<ObjectUnarchiveSummary> summaries = new List<ObjectUnarchiveSummary>();
        // Engine-level fidelity notes (e.g. related rows could not be located for this root).
        @AuraEnabled public List<String> notes = new List<String>();

        public UnarchiveSetResult(String rootBigObject, String rootObject, String rootRecordKey) {
            this.rootBigObject = rootBigObject;
            this.rootObject = rootObject;
            this.rootRecordKey = rootRecordKey;
            this.rootRestored = false;
            this.totalRestored = 0;
            this.totalFailed = 0;
        }
    }

    /**
     * Restores a root archived record and its direct related child records, re-linking the children
     * to the newly-restored parent.
     * @param rootBigObjectApiName Big Object holding the root archived row (ends in __b).
     * @param rootSourceObjectApiName Object the root record is recreated in.
     * @param rootRecordKey The root Big Object row's index key (as returned by the query service).
     * @param deleteFromBigObject When true, deletes each row from its Big Object after a successful
     *        restore (the delete runs asynchronously via BigObjectCleanupQueueable).
     * @return The unarchive-set outcome: per-object counts, re-link status, and fidelity notes.
     */
    @AuraEnabled
    public static UnarchiveSetResult unarchiveRecordWithRelated(
        String rootBigObjectApiName, String rootSourceObjectApiName,
        String rootRecordKey, Boolean deleteFromBigObject
    ) {
        if (String.isBlank(rootBigObjectApiName) || !rootBigObjectApiName.endsWith('__b')) {
            throw new AuraHandledException('A valid root Big Object (ending in __b) is required.');
        }
        if (String.isBlank(rootSourceObjectApiName)) {
            throw new AuraHandledException('A root source object API name is required.');
        }
        if (String.isBlank(rootRecordKey)) {
            throw new AuraHandledException('A root record key is required.');
        }
        Boolean removeFromBigObject = deleteFromBigObject == true;

        try {
            Schema.DescribeSObjectResult rootDescribe = describeObject(rootSourceObjectApiName);
            Schema.DescribeSObjectResult rootBigDescribe = describeObject(rootBigObjectApiName);
            UnarchiveSetResult result = new UnarchiveSetResult(
                rootBigObjectApiName, rootDescribe.getName(), rootRecordKey);

            // Read the root's ORIGINAL Id (before restoring) so related rows can be matched to it.
            Id originalRootId = readOriginalRootId(rootBigDescribe, rootBigObjectApiName, rootRecordKey, result);

            // Restore the root record; capture its NEW Id for re-linking children.
            ObjectUnarchiveSummary rootSummary = new ObjectUnarchiveSummary(
                rootDescribe.getName(), rootDescribe.getLabel(), rootBigObjectApiName, true);
            Id newRootId = restoreOne(
                rootBigObjectApiName, rootDescribe.getName(), rootRecordKey,
                removeFromBigObject, null, rootSummary);
            result.summaries.add(rootSummary);
            result.rootRestored = newRootId != null;
            result.newRootRecordId = newRootId;
            tally(result, rootSummary);

            // Related child records can only be located when the root's original Id is known.
            if (newRootId == null) {
                result.notes.add('Related records were not restored because the root record could not be restored.');
            } else if (originalRootId == null) {
                result.notes.add(
                    'Related records could not be located: this Big Object does not store the original record Id, '
                    + 'so archived children cannot be matched to this root. Only the root record was restored.');
            } else {
                restoreRelatedChildren(
                    rootDescribe, originalRootId, newRootId, removeFromBigObject, result);
            }
            return result;
        } catch (UnarchiveException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Record unarchiving failed: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------------
    // Root original Id + restore
    // ---------------------------------------------------------------------

    /**
     * Reads the root record's original Id from the Big Object row (the field resolving to source
     * `Id`). Returns null — and records a note — when the Big Object does not store it or the field
     * is not queryable in this org.
     */
    private static Id readOriginalRootId(
        Schema.DescribeSObjectResult rootBigDescribe, String rootBigObjectApiName,
        String rootRecordKey, UnarchiveSetResult result
    ) {
        String idBigField = resolveBigFieldForSource(rootBigDescribe, SOURCE_ID_FIELD);
        if (idBigField == null) {
            return null;
        }
        Map<String, Object> idByKey = BigObjectArchiveService.scanKeyedFieldValues(rootBigObjectApiName, idBigField);
        Object stored = idByKey.get(rootRecordKey);
        if (stored == null || String.isBlank(String.valueOf(stored))) {
            return null;
        }
        try {
            return (Id) String.valueOf(stored);
        } catch (System.StringException e) {
            return null;
        }
    }

    /**
     * Restores a single Big Object row into its source object, optionally applying a parent-lookup
     * override (used to re-link children). Populates the summary and returns the new record Id (or
     * null on failure).
     */
    private static Id restoreOne(
        String bigObjectApiName, String sourceObjectApiName, String recordKey,
        Boolean removeFromBigObject, Map<String, Object> overrides, ObjectUnarchiveSummary summary
    ) {
        List<String> keys = new List<String>{ recordKey };
        List<BigObjectArchiveService.RestoreResult> results = (overrides == null)
            ? BigObjectArchiveService.restoreRecords(bigObjectApiName, sourceObjectApiName, keys, removeFromBigObject)
            : BigObjectArchiveService.restoreRecordsWithOverrides(
                bigObjectApiName, sourceObjectApiName, keys, removeFromBigObject, overrides);
        if (results.isEmpty()) {
            summary.failedCount++;
            return null;
        }
        return applyRestoreResults(results, summary);
    }

    /** Folds a batch of RestoreResults into a summary; returns the first new record Id if any. */
    private static Id applyRestoreResults(
        List<BigObjectArchiveService.RestoreResult> results, ObjectUnarchiveSummary summary
    ) {
        Id firstNewId = null;
        for (BigObjectArchiveService.RestoreResult restore : results) {
            if (restore.isSuccess == true) {
                summary.restoredCount++;
                if (firstNewId == null) {
                    firstNewId = restore.restoredRecordId;
                }
            } else {
                summary.failedCount++;
                if (String.isBlank(summary.errorMessage) && String.isNotBlank(restore.errorMessage)) {
                    summary.errorMessage = restore.errorMessage;
                }
            }
        }
        return firstNewId;
    }

    // ---------------------------------------------------------------------
    // Related child restore + re-link
    // ---------------------------------------------------------------------

    /**
     * Walks the root's direct child relationships. For each child object that has a mapped Big
     * Object and stores its parent-lookup value, restores the archived child rows whose stored
     * parent Id equals originalRootId, re-pointing the lookup to newRootId. Fidelity gaps are
     * reported per object. Bounded to MAX_RELATED_OBJECTS.
     */
    private static void restoreRelatedChildren(
        Schema.DescribeSObjectResult rootDescribe, Id originalRootId, Id newRootId,
        Boolean removeFromBigObject, UnarchiveSetResult result
    ) {
        Map<String, String> bigObjectBySource = resolveBigObjectsBySource();
        String rootObject = rootDescribe.getName();

        // Group the parent-lookup relationship fields by child object (a child can relate via >1).
        Map<String, Set<String>> relFieldsByChild = new Map<String, Set<String>>();
        Map<String, String> labelByChild = new Map<String, String>();

        for (Schema.ChildRelationship rel : rootDescribe.getChildRelationships()) {
            Schema.SObjectType childType = rel.getChildSObject();
            Schema.SObjectField relField = rel.getField();
            if (childType == null || relField == null) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = childType.getDescribe();
            String childObject = childDescribe.getName();
            if (!childDescribe.isQueryable() || !childDescribe.isCreateable() || isSystemObject(childObject)) {
                continue;
            }
            if (childObject.equalsIgnoreCase(rootObject)) {
                continue;
            }
            if (!bigObjectBySource.containsKey(childObject.toLowerCase())) {
                continue; // no Big Object for this child — nothing was archived for it
            }
            if (!relFieldsByChild.containsKey(childObject)) {
                relFieldsByChild.put(childObject, new Set<String>());
                labelByChild.put(childObject, childDescribe.getLabel());
            }
            relFieldsByChild.get(childObject).add(relField.getDescribe().getName());
        }

        Integer processed = 0;
        for (String childObject : relFieldsByChild.keySet()) {
            if (processed >= MAX_RELATED_OBJECTS) {
                break;
            }
            restoreChildObject(
                childObject, labelByChild.get(childObject), bigObjectBySource.get(childObject.toLowerCase()),
                relFieldsByChild.get(childObject), originalRootId, newRootId, removeFromBigObject, result);
            processed++;
        }
    }

    /**
     * Restores one child object's archived rows that belong to the root. Finds matching rows by
     * scanning the child Big Object for each parent-lookup field whose stored value equals
     * originalRootId, then restores the union with every parent lookup overridden to newRootId.
     */
    private static void restoreChildObject(
        String childObject, String childLabel, String childBigObject, Set<String> relationshipFields,
        Id originalRootId, Id newRootId, Boolean removeFromBigObject, UnarchiveSetResult result
    ) {
        ObjectUnarchiveSummary summary = new ObjectUnarchiveSummary(childObject, childLabel, childBigObject, false);
        Schema.DescribeSObjectResult childBigDescribe = describeObject(childBigObject);

        Set<String> matchedKeys = new Set<String>();
        Map<String, Object> overrides = new Map<String, Object>();
        List<String> unresolvedFields = new List<String>();

        for (String relField : relationshipFields) {
            String parentBigField = resolveBigFieldForSource(childBigDescribe, relField);
            if (parentBigField == null) {
                unresolvedFields.add(relField);
                continue;
            }
            overrides.put(relField, newRootId);
            Map<String, Object> valueByKey =
                BigObjectArchiveService.scanKeyedFieldValues(childBigObject, parentBigField);
            for (String key : valueByKey.keySet()) {
                Object stored = valueByKey.get(key);
                if (stored != null && String.valueOf(stored) == String.valueOf(originalRootId)) {
                    matchedKeys.add(key);
                }
            }
        }

        if (!unresolvedFields.isEmpty()) {
            summary.note = 'Parent reference ' + String.join(unresolvedFields, ', ')
                + ' is not stored/queryable in the archive, so matching rows could not be re-linked.';
        }

        if (matchedKeys.isEmpty()) {
            if (String.isBlank(summary.note)) {
                summary.note = 'No archived ' + childLabel + ' rows were found for this record.';
            }
            result.summaries.add(summary);
            return;
        }

        List<BigObjectArchiveService.RestoreResult> results = BigObjectArchiveService.restoreRecordsWithOverrides(
            childBigObject, childObject, new List<String>(matchedKeys), removeFromBigObject, overrides);
        applyRestoreResults(results, summary);
        summary.relinked = summary.restoredCount > 0 && !overrides.isEmpty();
        result.summaries.add(summary);
        tally(result, summary);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /**
     * Resolves the Big Object field that stores a given source field. Mirrors the service's
     * API-name matching: a source field X maps to Big Object field X__c (standard) or X__c itself
     * (custom). Returns the actual Big Object field API name, or null when absent.
     */
    private static String resolveBigFieldForSource(
        Schema.DescribeSObjectResult bigDescribe, String sourceFieldName
    ) {
        String candidate = sourceFieldName.toLowerCase().endsWith('__c')
            ? sourceFieldName
            : sourceFieldName + '__c';
        Schema.SObjectField token = bigDescribe.fields.getMap().get(candidate.toLowerCase());
        return token == null ? null : token.getDescribe().getName();
    }

    /**
     * source object API name (lowercased) -> target Big Object API name, from the mapping config.
     * When a source object maps to more than one Big Object, the first (alphabetical) is used.
     */
    private static Map<String, String> resolveBigObjectsBySource() {
        Map<String, String> bigObjectBySource = new Map<String, String>();
        for (AggregateResult aggregate : [
            SELECT Source_Object__c src, MIN(Big_Object__c) bo
            FROM Big_Object_Field_Mapping__c
            WHERE Source_Object__c != null AND Big_Object__c != null
            WITH USER_MODE
            GROUP BY Source_Object__c
        ]) {
            String src = (String) aggregate.get('src');
            String bo = (String) aggregate.get('bo');
            if (String.isNotBlank(src) && String.isNotBlank(bo)) {
                bigObjectBySource.put(src.toLowerCase(), bo);
            }
        }
        return bigObjectBySource;
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

    private static Schema.DescribeSObjectResult describeObject(String apiName) {
        Schema.SObjectType token = Schema.getGlobalDescribe().get(apiName);
        if (token == null) {
            throw new UnarchiveException('Object not found: ' + apiName);
        }
        return token.getDescribe();
    }

    private static void tally(UnarchiveSetResult result, ObjectUnarchiveSummary summary) {
        result.totalRestored += summary.restoredCount;
        result.totalFailed += summary.failedCount;
    }
}
