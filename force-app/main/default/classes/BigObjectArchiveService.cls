/**
 * Reusable, bulkified engine that archives source records into a Big Object (Phase 2).
 *
 * Responsibilities:
 *  - Map source fields to Big Object fields by matching API name.
 *  - Write rows to the Big Object with Database.insertImmediate (the only supported Big Object DML).
 *  - Handle partial success (Big Object writes are non-transactional; each row succeeds/fails on its own).
 *  - Optionally stamp archive-tracking fields on the source record (only when they exist — describe-guarded).
 *  - Write a Big_Object_Archive_Log__c row for every attempt (success and failure).
 *
 * All public APIs accept collections and keep SOQL/DML out of loops so the service is safe to call
 * from triggers, a Quick Action controller, or BigObjectArchiveBatch.
 */
public with sharing class BigObjectArchiveService {
    // Optional archive-tracking fields on the source object. Written only when present.
    private static final String FIELD_IS_ARCHIVED = 'Is_Archived__c';
    private static final String FIELD_ARCHIVED_DATE = 'Archived_Date__c';
    private static final String FIELD_ARCHIVED_BY = 'Archived_By__c';
    private static final String FIELD_RECORD_KEY = 'Big_Object_Record_Key__c';
    private static final String KEY_SEPARATOR = '|';

    public class BigObjectArchiveException extends Exception {}

    /** Per-record outcome returned to callers (and the LWC). */
    public class ArchiveResult {
        @AuraEnabled public Id sourceRecordId;
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String bigObjectRecordKey;
        @AuraEnabled public Boolean sourceDeleted;
        // JSON snapshot of the full archived record, persisted to the log for the viewer to render.
        public String recordSnapshot;

        public ArchiveResult(Id sourceRecordId) {
            this.sourceRecordId = sourceRecordId;
            this.isSuccess = false;
            this.sourceDeleted = false;
        }
    }

    /** Full-record snapshot persisted (as JSON) to the archive log so the viewer can render it. */
    private class RecordSnapshot {
        String sourceObject;
        Long capturedAt;
        List<SnapshotField> fields = new List<SnapshotField>();
    }

    /** One field within a RecordSnapshot: enough for the viewer to render a record-page row. */
    private class SnapshotField {
        String name;
        String label;
        String type;
        String value;
    }

    /**
     * Convenience single-record entry point for the Quick Action LWC.
     * @param recordId Source record to archive.
     * @param targetBigObjectApiName Destination Big Object API name (e.g. Case_Archive__b).
     * @return The archive outcome for the record.
     */
    @AuraEnabled
    public static ArchiveResult archiveRecord(Id recordId, String targetBigObjectApiName) {
        if (recordId == null) {
            throw new AuraHandledException('A record Id is required.');
        }
        String sourceObject = recordId.getSObjectType().getDescribe().getName();
        List<ArchiveResult> results = archiveRecords(
            new Set<Id>{ recordId }, sourceObject, targetBigObjectApiName
        );
        return results.isEmpty() ? new ArchiveResult(recordId) : results[0];
    }

    /**
     * Archives a single record and, only when the archive succeeds, deletes the source record.
     * A delete failure is reported but does not undo the archive (the row is already stored).
     * @param recordId Source record to archive then delete.
     * @param targetBigObjectApiName Destination Big Object API name.
     * @return The archive outcome, with sourceDeleted indicating whether the source was removed.
     */
    @AuraEnabled
    public static ArchiveResult archiveAndDeleteRecord(Id recordId, String targetBigObjectApiName) {
        ArchiveResult result = archiveRecord(recordId, targetBigObjectApiName);
        if (result == null || result.isSuccess != true) {
            return result;
        }
        try {
            List<SObject> toDelete = new List<SObject>{
                recordId.getSObjectType().newSObject(recordId)
            };
            List<Database.DeleteResult> deleteResults =
                Database.delete(toDelete, false, AccessLevel.USER_MODE);
            Database.DeleteResult deleteResult = deleteResults[0];
            result.sourceDeleted = deleteResult.isSuccess();
            if (!deleteResult.isSuccess()) {
                result.errorMessage = 'Archived, but the source record could not be deleted: '
                    + formatErrors(deleteResult.getErrors());
            }
        } catch (Exception e) {
            result.sourceDeleted = false;
            result.errorMessage = 'Archived, but the source record could not be deleted: ' + e.getMessage();
        }
        return result;
    }

    /**
     * Bulk entry point: archives a set of records of one object into one Big Object.
     * @param recordIds Source record Ids (all of sourceObjectApiName).
     * @param sourceObjectApiName API name of the source object.
     * @param targetBigObjectApiName API name of the destination Big Object.
     * @return One ArchiveResult per source record.
     */
    public static List<ArchiveResult> archiveRecords(
        Set<Id> recordIds, String sourceObjectApiName, String targetBigObjectApiName
    ) {
        List<ArchiveResult> results = insertIntoBigObject(recordIds, sourceObjectApiName, targetBigObjectApiName);
        applyArchiveSideEffects(sourceObjectApiName, targetBigObjectApiName, results);
        return results;
    }

    /**
     * Big Object insert ONLY — queries the source records and writes rows with insertImmediate, but
     * does NOT stamp the source or write archive logs. Each call is a SOQL query plus an
     * insertImmediate callout and performs no regular DML, so it can be called repeatedly in one
     * transaction before any regular DML. This is what lets RecordArchivingEngine archive several
     * objects together without hitting "callout after pending uncommitted work". Callers MUST run
     * applyArchiveSideEffects afterwards (once all inserts are done) to stamp and log.
     * @param recordIds Source record Ids (all of sourceObjectApiName).
     * @param sourceObjectApiName API name of the source object.
     * @param targetBigObjectApiName API name of the destination Big Object.
     * @return One ArchiveResult per source record (with bigObjectRecordKey populated).
     */
    public static List<ArchiveResult> insertIntoBigObject(
        Set<Id> recordIds, String sourceObjectApiName, String targetBigObjectApiName
    ) {
        validateInputs(recordIds, sourceObjectApiName, targetBigObjectApiName);

        Schema.DescribeSObjectResult sourceDescribe = describeObject(sourceObjectApiName);
        Schema.DescribeSObjectResult targetDescribe = describeObject(targetBigObjectApiName);

        // Big Object field API name -> source field API name (matched by API name).
        Map<String, String> fieldMap = buildFieldMap(sourceDescribe, targetDescribe);
        if (fieldMap.isEmpty()) {
            throw new BigObjectArchiveException(
                'No matching fields found between ' + sourceObjectApiName + ' and ' + targetBigObjectApiName + '.');
        }
        // Required (non-nillable) Big Object fields form the index / primary key.
        List<String> keyFieldApiNames = getKeyFieldApiNames(targetDescribe, fieldMap.keySet());

        // The snapshot captures the WHOLE source record (every readable field), not just the subset
        // that maps into the Big Object — so the viewer can show the full record for any object.
        List<String> snapshotFields = buildSnapshotFieldList(sourceDescribe);
        Set<String> queryFields = new Set<String>();
        queryFields.addAll(fieldMap.values());
        queryFields.addAll(snapshotFields);
        List<SObject> sourceRecords = querySourceRecords(sourceObjectApiName, queryFields, recordIds);

        // Build Big Object rows, keeping arrays index-aligned so SaveResults map back to source Ids.
        List<SObject> bigObjectRows = new List<SObject>();
        List<Id> alignedSourceIds = new List<Id>();
        Map<Id, String> keyBySourceId = new Map<Id, String>();

        SObjectType targetType = targetDescribe.getSObjectType();
        Map<String, Schema.SObjectField> targetFieldMap = targetDescribe.fields.getMap();
        Map<Id, String> snapshotBySourceId = new Map<Id, String>();
        for (SObject source : sourceRecords) {
            SObject row = targetType.newSObject();
            for (String bigField : fieldMap.keySet()) {
                Object value = source.get(fieldMap.get(bigField));
                row.put(bigField, coerceForStorage(targetFieldMap, bigField, value));
            }
            String recordKey = buildRecordKey(source, fieldMap, keyFieldApiNames);
            bigObjectRows.add(row);
            alignedSourceIds.add(source.Id);
            keyBySourceId.put(source.Id, recordKey);
            snapshotBySourceId.put(source.Id, buildRecordSnapshot(sourceDescribe, source, snapshotFields));
        }

        Map<Id, ArchiveResult> resultsBySourceId = insertBigObjectRows(
            bigObjectRows, alignedSourceIds, keyBySourceId);
        for (Id sourceId : resultsBySourceId.keySet()) {
            resultsBySourceId.get(sourceId).recordSnapshot = snapshotBySourceId.get(sourceId);
        }
        return resultsBySourceId.values();
    }

    /**
     * Post-insert side effects (regular DML): stamps archive-tracking fields on successfully
     * archived source records and writes one archive-log row per attempt. Run this only AFTER all
     * insertIntoBigObject calls in the transaction, since regular DML before a Big Object
     * insertImmediate callout throws "pending uncommitted work".
     * @param sourceObjectApiName API name of the source object the results belong to.
     * @param targetBigObjectApiName API name of the destination Big Object.
     * @param results The ArchiveResults returned by insertIntoBigObject for this object.
     */
    public static void applyArchiveSideEffects(
        String sourceObjectApiName, String targetBigObjectApiName, List<ArchiveResult> results
    ) {
        if (results == null || results.isEmpty()) {
            return;
        }
        Schema.DescribeSObjectResult sourceDescribe = describeObject(sourceObjectApiName);
        Map<Id, ArchiveResult> resultsBySourceId = new Map<Id, ArchiveResult>();
        Map<Id, String> keyBySourceId = new Map<Id, String>();
        for (ArchiveResult result : results) {
            resultsBySourceId.put(result.sourceRecordId, result);
            keyBySourceId.put(result.sourceRecordId, result.bigObjectRecordKey);
        }
        stampArchivedSourceRecords(sourceDescribe, resultsBySourceId, keyBySourceId);
        writeArchiveLogs(sourceObjectApiName, targetBigObjectApiName, resultsBySourceId);
    }

    // =====================================================================
    // Phase 4 — Archive Preview + Restore
    // =====================================================================

    /** One field's archive-preview line (source value that will be written to the Big Object). */
    public class FieldValuePreview {
        @AuraEnabled public String bigObjectField;
        @AuraEnabled public String sourceField;
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    /** Per-record restore outcome. */
    public class RestoreResult {
        @AuraEnabled public String recordKey;
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public Id restoredRecordId;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Boolean deletedFromBigObject;

        public RestoreResult(String recordKey) {
            this.recordKey = recordKey;
            this.isSuccess = false;
            this.deletedFromBigObject = false;
        }
    }

    /**
     * Previews exactly which source values will be written to the Big Object before archiving.
     * Reuses the same API-name field mapping the archive itself uses, so the preview is accurate.
     * @param recordId Source record to preview.
     * @param targetBigObjectApiName Destination Big Object.
     * @return One line per mapped field, with label and current value.
     */
    @AuraEnabled
    public static List<FieldValuePreview> getArchivePreview(Id recordId, String targetBigObjectApiName) {
        try {
            if (recordId == null || String.isBlank(targetBigObjectApiName)) {
                throw new BigObjectArchiveException('A record Id and target Big Object are required.');
            }
            String sourceObject = recordId.getSObjectType().getDescribe().getName();
            Schema.DescribeSObjectResult sourceDescribe = describeObject(sourceObject);
            Schema.DescribeSObjectResult targetDescribe = describeObject(targetBigObjectApiName);
            Map<String, String> fieldMap = buildFieldMap(sourceDescribe, targetDescribe); // bigField -> sourceField

            List<SObject> records = querySourceRecords(sourceObject, fieldMap.values(), new Set<Id>{ recordId });
            SObject record = records.isEmpty() ? null : records[0];

            Map<String, Schema.SObjectField> sourceFields = sourceDescribe.fields.getMap();
            List<FieldValuePreview> preview = new List<FieldValuePreview>();
            for (String bigField : fieldMap.keySet()) {
                String sourceField = fieldMap.get(bigField);
                Object value = (record == null) ? null : record.get(sourceField);
                FieldValuePreview line = new FieldValuePreview();
                line.bigObjectField = bigField;
                line.sourceField = sourceField;
                line.label = sourceFields.get(sourceField.toLowerCase()).getDescribe().getLabel();
                line.value = (value == null) ? '' : String.valueOf(value);
                preview.add(line);
            }
            return preview;
        } catch (BigObjectArchiveException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unable to build archive preview: ' + e.getMessage());
        }
    }

    /**
     * Single-record restore for the Detail page / Related List.
     * @param bigObjectApiName Big Object holding the archived row.
     * @param sourceObjectApiName Object to recreate the record in.
     * @param recordKey The Big Object row's index key (as returned by the query service).
     * @param deleteFromBigObject When true, deletes the Big Object row after a successful restore.
     * @return The restore outcome.
     */
    @AuraEnabled
    public static RestoreResult restoreRecord(
        String bigObjectApiName, String sourceObjectApiName, String recordKey, Boolean deleteFromBigObject
    ) {
        List<RestoreResult> results = restoreRecords(
            bigObjectApiName, sourceObjectApiName, new List<String>{ recordKey }, deleteFromBigObject
        );
        return results.isEmpty() ? new RestoreResult(recordKey) : results[0];
    }

    /**
     * Bulk restore: recreates source records from Big Object rows identified by their record keys.
     * Restored records get NEW Ids (the platform cannot reuse the original Id). Optionally deletes
     * the Big Object rows that restored successfully. Partial success is handled per record.
     * @param bigObjectApiName Big Object holding the archived rows.
     * @param sourceObjectApiName Object to recreate records in.
     * @param recordKeys Big Object row index keys to restore.
     * @param deleteFromBigObject When true, deletes successfully restored Big Object rows.
     * @return One RestoreResult per key.
     */
    @AuraEnabled
    public static List<RestoreResult> restoreRecords(
        String bigObjectApiName, String sourceObjectApiName, List<String> recordKeys, Boolean deleteFromBigObject
    ) {
        return restoreRecordsInternal(bigObjectApiName, sourceObjectApiName, recordKeys, deleteFromBigObject, null);
    }

    /**
     * Restore variant used by the Unarchive Engine. Applies sourceFieldOverrides to every restored
     * record AFTER field mapping — used to re-link a child to its newly-restored parent (the parent
     * lookup is overridden with the parent's new Id). Override entries whose field is not createable
     * on the source object are ignored.
     * @param bigObjectApiName Big Object holding the archived rows.
     * @param sourceObjectApiName Object to recreate records in.
     * @param recordKeys Big Object row index keys to restore.
     * @param deleteFromBigObject When true, deletes successfully restored Big Object rows.
     * @param sourceFieldOverrides source field API name -> value to force on every restored record.
     * @return One RestoreResult per key.
     */
    public static List<RestoreResult> restoreRecordsWithOverrides(
        String bigObjectApiName, String sourceObjectApiName, List<String> recordKeys,
        Boolean deleteFromBigObject, Map<String, Object> sourceFieldOverrides
    ) {
        return restoreRecordsInternal(
            bigObjectApiName, sourceObjectApiName, recordKeys, deleteFromBigObject, sourceFieldOverrides);
    }

    /**
     * Scans a Big Object (bounded) and returns record key -> the value of one field. The Unarchive
     * Engine uses this to read the root's original record Id and to find child rows whose stored
     * parent Id matches it. Self-heals phantom describe columns like the restore query; if the
     * requested field itself is not queryable here, every value comes back null (the caller then
     * reports that re-linking is not possible in this org).
     * @param bigObjectApiName Big Object to scan.
     * @param fieldApiName Big Object field whose value to return per row.
     * @return record key -> field value (value is null when the field is not queryable).
     */
    public static Map<String, Object> scanKeyedFieldValues(String bigObjectApiName, String fieldApiName) {
        Schema.DescribeSObjectResult targetDescribe = describeObject(bigObjectApiName);
        List<String> indexFields = getAllIndexFields(targetDescribe);
        List<String> selectFields = new List<String>();
        Set<String> added = new Set<String>();
        for (String field : indexFields) {
            if (added.add(field)) {
                selectFields.add(field);
            }
        }
        if (added.add(fieldApiName)) {
            selectFields.add(fieldApiName);
        }

        Map<String, Object> valueByKey = new Map<String, Object>();
        Boolean fieldSelected = true;
        Integer attemptsLeft = selectFields.size() + 1;
        while (true) {
            String soql = 'SELECT ' + String.join(selectFields, ', ')
                + ' FROM ' + targetDescribe.getName()
                + (indexFields.isEmpty() ? '' : ' ORDER BY ' + String.join(indexFields, ', '))
                + ' LIMIT 10000';
            try {
                for (SObject row : Database.query(soql, AccessLevel.USER_MODE)) {
                    String key = computeKeyForRow(row, indexFields);
                    valueByKey.put(key, fieldSelected ? row.get(fieldApiName) : null);
                }
                break;
            } catch (QueryException qe) {
                String badColumn = extractMissingColumn(qe.getMessage());
                attemptsLeft--;
                Boolean removed = (badColumn != null) && removeFieldIgnoreCase(selectFields, badColumn);
                removeFieldIgnoreCase(indexFields, badColumn);
                if (badColumn != null && badColumn.equalsIgnoreCase(fieldApiName)) {
                    fieldSelected = false;
                }
                if (!removed || selectFields.isEmpty() || attemptsLeft <= 0) {
                    throw qe;
                }
            }
        }
        return valueByKey;
    }

    private static List<RestoreResult> restoreRecordsInternal(
        String bigObjectApiName, String sourceObjectApiName, List<String> recordKeys,
        Boolean deleteFromBigObject, Map<String, Object> sourceFieldOverrides
    ) {
        try {
            if (String.isBlank(bigObjectApiName) || String.isBlank(sourceObjectApiName)) {
                throw new BigObjectArchiveException('Big Object and source object API names are required.');
            }
            if (recordKeys == null || recordKeys.isEmpty()) {
                throw new BigObjectArchiveException('No record keys were supplied to restore.');
            }
            Schema.DescribeSObjectResult sourceDescribe = describeObject(sourceObjectApiName);
            Schema.DescribeSObjectResult targetDescribe = describeObject(bigObjectApiName);

            // bigField -> sourceField, keeping only source fields writeable on insert.
            Map<String, String> restoreMap = buildRestoreMap(sourceDescribe, targetDescribe);
            // Record keys arrive from the query service, which builds them from EVERY index
            // (non-nillable) field in sorted order. Derive the key fields the same way so the
            // keys round-trip, regardless of which fields map back to the source object.
            List<String> indexFields = getAllIndexFields(targetDescribe);

            // Fetch the rows and match requested keys in memory (avoids fragile typed IN-binds).
            Map<String, SObject> rowsByKey = queryBigObjectRowsByKeys(targetDescribe, indexFields, recordKeys);

            List<SObject> toInsert = new List<SObject>();
            List<String> alignedKeys = new List<String>();
            Map<String, RestoreResult> resultsByKey = new Map<String, RestoreResult>();
            SObjectType sourceType = sourceDescribe.getSObjectType();

            for (String key : recordKeys) {
                RestoreResult result = new RestoreResult(key);
                resultsByKey.put(key, result);
                SObject bigRow = rowsByKey.get(key);
                if (bigRow == null) {
                    result.errorMessage = 'Archived record not found for key: ' + key;
                    continue;
                }
                SObject newRecord = sourceType.newSObject();
                // Only read fields actually present on the row. A phantom describe column (stale
                // cache after recreate) is dropped from the SELECT by the self-heal above, so it is
                // not populated here — reading it would throw "retrieved via SOQL without querying".
                Set<String> populated = new Set<String>();
                for (String p : bigRow.getPopulatedFieldsAsMap().keySet()) {
                    populated.add(p.toLowerCase());
                }
                for (String bigField : restoreMap.keySet()) {
                    if (populated.contains(bigField.toLowerCase())) {
                        String srcField = restoreMap.get(bigField);
                        Object stored = bigRow.get(bigField);
                        newRecord.put(srcField, coerceForRestore(sourceDescribe, srcField, stored));
                    }
                }
                toInsert.add(newRecord);
                alignedKeys.add(key);
            }

            insertRestoredRecords(toInsert, alignedKeys, resultsByKey);
            writeRestoreLogs(sourceObjectApiName, bigObjectApiName, resultsByKey);
            // A Big Object deleteImmediate is treated as a callout, and a callout cannot run after
            // the regular DML above (source insert + log insert) in the same transaction. So the
            // cleanup is enqueued to run in its own transaction, only for rows whose source record
            // restored successfully (no data loss if an insert failed).
            if (deleteFromBigObject == true) {
                deleteRestoredBigObjectRows(targetDescribe, indexFields, rowsByKey, resultsByKey);
            }
            return resultsByKey.values();
        } catch (BigObjectArchiveException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Restore failed: ' + e.getMessage());
        }
    }

    // ---- Type coercion -----------------------------------------------------

    /**
     * Prepare a source value for storage in a Big Object field. Fields whose source type has no
     * native Big Object type (Boolean, Date, Picklist, Multi-select) map to a Text/LongTextArea
     * column; their value is stringified so nothing is lost. Native types pass through unchanged.
     */
    private static Object coerceForStorage(
        Map<String, Schema.SObjectField> targetFields, String bigField, Object value
    ) {
        if (value == null) {
            return null;
        }
        Schema.DisplayType t = targetFields.get(bigField).getDescribe().getType();
        if ((t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA)
            && !(value instanceof String)) {
            return String.valueOf(value);
        }
        return value;
    }

    /**
     * Convert a stored Big Object value back to the source field's real type on unarchive.
     * Text-coerced values come back as Strings; parse Boolean/Date so the source insert accepts
     * them. Picklist/Multi-select/text keep their string form (the field accepts it directly).
     */
    private static Object coerceForRestore(
        Schema.DescribeSObjectResult sourceDescribe, String sourceField, Object stored
    ) {
        if (stored == null || !(stored instanceof String)) {
            return stored;
        }
        String s = (String) stored;
        Schema.DisplayType t = sourceDescribe.fields.getMap().get(sourceField).getDescribe().getType();
        switch on t {
            when BOOLEAN { return Boolean.valueOf(s); }
            when DATE { return Date.valueOf(s); }
            when else { return s; }
        }
    }

    // ---- Restore helpers ---------------------------------------------------

    /** bigField -> sourceField for restore: only source fields that are createable on insert. */
    private static Map<String, String> buildRestoreMap(
        Schema.DescribeSObjectResult sourceDescribe, Schema.DescribeSObjectResult targetDescribe
    ) {
        Map<String, Schema.SObjectField> sourceFields = sourceDescribe.fields.getMap();
        Map<String, String> restoreMap = new Map<String, String>();
        for (String bigFieldName : targetDescribe.fields.getMap().keySet()) {
            Schema.DescribeFieldResult bigField = targetDescribe.fields.getMap().get(bigFieldName).getDescribe();
            Schema.SObjectField sourceToken = resolveSourceToken(sourceFields, bigFieldName);
            if (sourceToken != null && sourceToken.getDescribe().isCreateable()) {
                restoreMap.put(bigField.getName(), sourceToken.getDescribe().getName());
            }
        }
        if (restoreMap.isEmpty()) {
            throw new BigObjectArchiveException(
                'No writeable source fields match the Big Object fields; cannot restore.');
        }
        return restoreMap;
    }

    /**
     * Fetches Big Object rows and returns only those whose index key matches a requested key.
     * Matching is done in memory from a full-field read so it never depends on a typed IN-bind
     * against an index column (which fails with "Invalid bind expression type of ANY").
     */
    private static Map<String, SObject> queryBigObjectRowsByKeys(
        Schema.DescribeSObjectResult targetDescribe, List<String> indexFields, List<String> recordKeys
    ) {
        // Select every Big Object field (index fields first) so restore has full data.
        List<String> selectFields = new List<String>();
        Set<String> added = new Set<String>();
        for (String field : indexFields) {
            if (added.add(field)) {
                selectFields.add(field);
            }
        }
        for (Schema.SObjectField token : targetDescribe.fields.getMap().values()) {
            String resolved = token.getDescribe().getName();
            if (added.add(resolved)) {
                selectFields.add(resolved);
            }
        }

        Set<String> wantedKeys = new Set<String>(recordKeys);

        // Apex describe can report phantom columns that are not actually queryable (seen after a Big
        // Object is deleted and recreated with the same name — the org's describe cache lags behind
        // the real schema). Self-heal: on "No such column 'X'", drop X and retry so restore does not
        // hard-fail. Mirrors BigObjectQueryService so the record key stays consistent.
        List<SObject> rows;
        Integer attemptsLeft = selectFields.size() + 1;
        while (true) {
            String soql = 'SELECT ' + String.join(selectFields, ', ')
                + ' FROM ' + targetDescribe.getName()
                + (indexFields.isEmpty() ? '' : ' ORDER BY ' + String.join(indexFields, ', '))
                + ' LIMIT 10000';
            try {
                rows = Database.query(soql, AccessLevel.USER_MODE);
                break;
            } catch (QueryException qe) {
                String badColumn = extractMissingColumn(qe.getMessage());
                attemptsLeft--;
                Boolean removedFromSelect = (badColumn != null) && removeFieldIgnoreCase(selectFields, badColumn);
                removeFieldIgnoreCase(indexFields, badColumn);
                if (!removedFromSelect || selectFields.isEmpty() || attemptsLeft <= 0) {
                    throw qe;
                }
            }
        }

        Map<String, SObject> rowsByKey = new Map<String, SObject>();
        for (SObject row : rows) {
            String key = computeKeyForRow(row, indexFields);
            if (wantedKeys.contains(key)) {
                rowsByKey.put(key, row);
            }
        }
        return rowsByKey;
    }

    /**
     * Returns the Big Object's index fields (non-nillable, createable) in sorted order — identical
     * to how BigObjectQueryService derives them, so record keys built by the query service match.
     */
    private static List<String> getAllIndexFields(Schema.DescribeSObjectResult describe) {
        List<String> indexFields = new List<String>();
        for (Schema.SObjectField token : describe.fields.getMap().values()) {
            Schema.DescribeFieldResult df = token.getDescribe();
            if (!df.isNillable() && df.isCreateable()) {
                indexFields.add(df.getName());
            }
        }
        indexFields.sort();
        return indexFields;
    }

    /** Parses the field API name from a "No such column 'X' on entity ..." SOQL error, or null. */
    private static String extractMissingColumn(String message) {
        if (String.isBlank(message)) {
            return null;
        }
        Matcher m = Pattern.compile('No such column \'([^\']+)\'').matcher(message);
        return m.find() ? m.group(1) : null;
    }

    /** Removes a field (case-insensitive) from the list in place; returns whether anything matched. */
    private static Boolean removeFieldIgnoreCase(List<String> fields, String target) {
        if (target == null) {
            return false;
        }
        Boolean removed = false;
        for (Integer i = fields.size() - 1; i >= 0; i--) {
            if (fields[i].equalsIgnoreCase(target)) {
                fields.remove(i);
                removed = true;
            }
        }
        return removed;
    }

    /** Rebuilds a row's index key the same way the archive/query services do (sorted index order). */
    private static String computeKeyForRow(SObject row, List<String> indexFields) {
        List<String> parts = new List<String>();
        for (String field : indexFields) {
            Object value = row.get(field);
            parts.add(value == null ? '' : String.valueOf(value));
        }
        return String.join(parts, KEY_SEPARATOR);
    }

    private static void insertRestoredRecords(
        List<SObject> toInsert, List<String> alignedKeys, Map<String, RestoreResult> resultsByKey
    ) {
        if (toInsert.isEmpty()) {
            return;
        }
        List<Database.SaveResult> saveResults = Database.insert(toInsert, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < saveResults.size(); i++) {
            RestoreResult result = resultsByKey.get(alignedKeys[i]);
            Database.SaveResult saveResult = saveResults[i];
            result.isSuccess = saveResult.isSuccess();
            if (saveResult.isSuccess()) {
                result.restoredRecordId = saveResult.getId();
            } else {
                String msg = formatErrors(saveResult.getErrors());
                // On some orgs (e.g. trial/demo), non-index Big Object fields are stored but can't
                // be read back via SOQL, so required values are missing on restore. The data is NOT
                // lost — it is archived; it just can't be queried here. Explain rather than show a
                // cryptic REQUIRED_FIELD_MISSING. Standard Developer/Enterprise/Production orgs allow
                // these queries, so restore recovers the whole record there.
                if (msg != null && msg.contains('REQUIRED_FIELD_MISSING')) {
                    msg += ' — These values are archived but can\'t be read back from the Big Object '
                        + 'in this org (non-index Big Object fields aren\'t SOQL-queryable here). '
                        + 'The data is safe; full restore works in a standard Salesforce org.';
                }
                result.errorMessage = msg;
            }
        }
    }

    /**
     * Enqueues async cleanup of the Big Object rows that restored successfully. A Big Object
     * deleteImmediate is a callout and cannot follow the restore's regular DML in the same
     * transaction, so it runs in its own Queueable transaction. Cleanup failures never fail the
     * restore — the record is already back in the source object.
     */
    private static void deleteRestoredBigObjectRows(
        Schema.DescribeSObjectResult targetDescribe, List<String> indexFields,
        Map<String, SObject> rowsByKey, Map<String, RestoreResult> resultsByKey
    ) {
        SObjectType targetType = targetDescribe.getSObjectType();
        List<SObject> toDelete = new List<SObject>();
        List<String> deleteKeys = new List<String>();
        for (String key : resultsByKey.keySet()) {
            RestoreResult result = resultsByKey.get(key);
            if (result.isSuccess != true || !rowsByKey.containsKey(key)) {
                continue;
            }
            // Big Object deleteImmediate matches on the full index key. A queried row carries the
            // placeholder Id (000000000000000AAA) + system fields, which makes deleteImmediate
            // silently match nothing. Build a fresh row populated with ONLY the index fields.
            SObject queried = rowsByKey.get(key);
            SObject keyRow = targetType.newSObject();
            for (String idxField : indexFields) {
                keyRow.put(idxField, queried.get(idxField));
            }
            toDelete.add(keyRow);
            deleteKeys.add(key);
        }
        if (toDelete.isEmpty()) {
            return;
        }
        // Only enqueue from a synchronous (LWC) transaction. If already async we skip rather than
        // risk a callout-after-DML error; this path is not reached from the viewer.
        if (System.isBatch() || System.isFuture() || System.isQueueable()) {
            return;
        }
        System.enqueueJob(new BigObjectCleanupQueueable(toDelete));
        for (String key : deleteKeys) {
            resultsByKey.get(key).deletedFromBigObject = true; // cleanup enqueued
        }
    }

    /**
     * Deletes Big Object rows in its own transaction so the deleteImmediate callout does not
     * conflict with the restore transaction's prior DML. Failures are swallowed — the source
     * record is already restored.
     */
    public class BigObjectCleanupQueueable implements Queueable {
        private List<SObject> rowsToDelete;
        public BigObjectCleanupQueueable(List<SObject> rowsToDelete) {
            this.rowsToDelete = rowsToDelete;
        }
        public void execute(QueueableContext context) {
            if (rowsToDelete == null || rowsToDelete.isEmpty()) {
                return;
            }
            try {
                Database.deleteImmediate(rowsToDelete);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Big Object cleanup failed: ' + e.getMessage());
            }
        }
    }

    /** Logs each restore attempt to the archive log (reuses existing fields). */
    private static void writeRestoreLogs(
        String sourceObject, String bigObject, Map<String, RestoreResult> resultsByKey
    ) {
        List<Big_Object_Archive_Log__c> logs = new List<Big_Object_Archive_Log__c>();
        for (RestoreResult result : resultsByKey.values()) {
            logs.add(new Big_Object_Archive_Log__c(
                Source_Record_Id__c = result.restoredRecordId,
                Source_Object__c = sourceObject,
                Target_Big_Object__c = bigObject,
                Status__c = result.isSuccess == true ? 'Success' : 'Failed',
                Operation__c = 'Restore',
                Error_Message__c = result.errorMessage,
                Archived_By__c = UserInfo.getUserId(),
                Archived_Date__c = System.now()
            ));
        }
        if (!logs.isEmpty()) {
            Database.insert(logs, false, AccessLevel.USER_MODE);
        }
    }

    // ---------------------------------------------------------------------
    // Validation + describe
    // ---------------------------------------------------------------------

    private static void validateInputs(Set<Id> recordIds, String sourceObject, String targetBigObject) {
        if (recordIds == null || recordIds.isEmpty()) {
            throw new BigObjectArchiveException('No records were supplied to archive.');
        }
        if (String.isBlank(sourceObject) || String.isBlank(targetBigObject)) {
            throw new BigObjectArchiveException('Source object and target Big Object are required.');
        }
        if (!targetBigObject.endsWith('__b')) {
            throw new BigObjectArchiveException('Target "' + targetBigObject + '" is not a Big Object (must end in __b).');
        }
    }

    private static Schema.DescribeSObjectResult describeObject(String apiName) {
        SObjectType sobjType = Schema.getGlobalDescribe().get(apiName);
        if (sobjType == null) {
            throw new BigObjectArchiveException('Unknown object: ' + apiName);
        }
        return sobjType.getDescribe();
    }

    // ---------------------------------------------------------------------
    // Field mapping
    // ---------------------------------------------------------------------

    /**
     * Resolves the source field that corresponds to a Big Object field. Every Big Object field is a
     * custom field (ends in __c), but the source field may be custom (same name) OR standard (the
     * name without __c, e.g. Big Object FirstName__c maps to standard Lead field FirstName).
     * @param sourceFields The source object's field map (lowercase keys).
     * @param bigFieldNameLower The Big Object field API name, lowercased.
     * @return The matching source field token, or null when none matches.
     */
    private static Schema.SObjectField resolveSourceToken(
        Map<String, Schema.SObjectField> sourceFields, String bigFieldNameLower
    ) {
        Schema.SObjectField token = sourceFields.get(bigFieldNameLower);
        if (token == null && bigFieldNameLower.endsWith('__c')) {
            token = sourceFields.get(bigFieldNameLower.removeEnd('__c'));
        }
        return token;
    }

    /**
     * Maps Big Object fields to source fields. Admin-defined mappings (Big_Object_Field_Mapping__c)
     * win; any Big Object field left unmapped falls back to API-name matching, where a Big Object
     * field X__c matches either a source field X__c (custom) or the standard field X (__c stripped).
     * Only createable Big Object fields with an accessible source field are included.
     */
    private static Map<String, String> buildFieldMap(
        Schema.DescribeSObjectResult sourceDescribe, Schema.DescribeSObjectResult targetDescribe
    ) {
        Map<String, Schema.SObjectField> sourceFields = sourceDescribe.fields.getMap();
        Map<String, Schema.SObjectField> targetFields = targetDescribe.fields.getMap();
        Map<String, String> fieldMap = new Map<String, String>();
        Set<String> handledBigFields = new Set<String>(); // lowercased Big Object field names already mapped

        // 1) Admin-defined mappings take precedence.
        for (Big_Object_Field_Mapping__c mapping : [
            SELECT Big_Object_Field__c, Source_Field__c
            FROM Big_Object_Field_Mapping__c
            WHERE Big_Object__c = :targetDescribe.getName()
                AND Source_Object__c = :sourceDescribe.getName()
                AND Big_Object_Field__c != null
                AND Source_Field__c != null
            WITH USER_MODE
        ]) {
            Schema.SObjectField bigToken = targetFields.get(mapping.Big_Object_Field__c.toLowerCase());
            Schema.SObjectField sourceToken = sourceFields.get(mapping.Source_Field__c.toLowerCase());
            if (bigToken == null || sourceToken == null) {
                continue;
            }
            Schema.DescribeFieldResult bigField = bigToken.getDescribe();
            if (bigField.isCreateable() && sourceToken.getDescribe().isAccessible()) {
                fieldMap.put(bigField.getName(), sourceToken.getDescribe().getName());
                handledBigFields.add(bigField.getName().toLowerCase());
            }
        }

        // 2) Fall back to API-name matching for Big Object fields the admin did not map.
        for (String bigFieldName : targetFields.keySet()) {
            Schema.DescribeFieldResult bigField = targetFields.get(bigFieldName).getDescribe();
            if (!bigField.isCreateable() || handledBigFields.contains(bigField.getName().toLowerCase())) {
                continue;
            }
            Schema.SObjectField sourceToken = resolveSourceToken(sourceFields, bigFieldName);
            if (sourceToken != null && sourceToken.getDescribe().isAccessible()) {
                fieldMap.put(bigField.getName(), sourceToken.getDescribe().getName());
            }
        }
        return fieldMap;
    }

    /** Returns the mapped Big Object fields that are required (its index / primary key), in field order. */
    private static List<String> getKeyFieldApiNames(
        Schema.DescribeSObjectResult targetDescribe, Set<String> mappedBigFields
    ) {
        List<String> keyFields = new List<String>();
        for (String bigFieldName : mappedBigFields) {
            if (!targetDescribe.fields.getMap().get(bigFieldName).getDescribe().isNillable()) {
                keyFields.add(bigFieldName);
            }
        }
        keyFields.sort();
        return keyFields;
    }

    /** Concatenates the source values of the key fields into a stable record key. */
    private static String buildRecordKey(
        SObject source, Map<String, String> fieldMap, List<String> keyFieldApiNames
    ) {
        List<String> parts = new List<String>();
        for (String keyField : keyFieldApiNames) {
            Object value = source.get(fieldMap.get(keyField));
            parts.add(value == null ? '' : String.valueOf(value));
        }
        return String.join(parts, KEY_SEPARATOR);
    }

    // ---------------------------------------------------------------------
    // Query + Big Object insert
    // ---------------------------------------------------------------------

    /**
     * Builds a JSON snapshot of the archived field values (API name, label, type, value) so the
     * viewer can render the full record even where non-index Big Object fields are not queryable.
     * Snapshots exactly the fields that were archived, ordered by label for a record-page layout.
     */
    /**
     * Every readable, scalar field on the source object — the set captured in the display snapshot.
     * Skips compound (Address/Location) and binary (base64) fields, which don't render as text.
     */
    @TestVisible
    private static List<String> buildSnapshotFieldList(Schema.DescribeSObjectResult sourceDescribe) {
        List<String> fields = new List<String>();
        for (Schema.SObjectField token : sourceDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult describe = token.getDescribe();
            Schema.DisplayType fieldType = describe.getType();
            if (!describe.isAccessible()
                || fieldType == Schema.DisplayType.ADDRESS
                || fieldType == Schema.DisplayType.LOCATION
                || fieldType == Schema.DisplayType.BASE64) {
                continue;
            }
            fields.add(describe.getName());
        }
        return fields;
    }

    @TestVisible
    private static String buildRecordSnapshot(
        Schema.DescribeSObjectResult sourceDescribe, SObject source, Iterable<String> sourceFieldNames
    ) {
        Map<String, Schema.SObjectField> fieldMap = sourceDescribe.fields.getMap();
        RecordSnapshot snapshot = new RecordSnapshot();
        snapshot.sourceObject = sourceDescribe.getName();
        snapshot.capturedAt = System.now().getTime();
        // Keep the serialized snapshot within the LongTextArea limit: cap each value and stop once
        // the accumulated value size nears the budget (very long multi-field records only).
        Integer remainingBudget = 120000;
        for (String fieldName : sourceFieldNames) {
            Schema.SObjectField token = fieldMap.get(fieldName.toLowerCase());
            if (token == null) {
                continue;
            }
            Schema.DescribeFieldResult describe = token.getDescribe();
            SnapshotField entry = new SnapshotField();
            entry.name = describe.getName();
            entry.label = describe.getLabel();
            entry.type = String.valueOf(describe.getType()).toLowerCase();
            Object value = source.get(describe.getName());
            String stringValue = (value == null) ? null : String.valueOf(value);
            if (stringValue != null && stringValue.length() > 2000) {
                stringValue = stringValue.substring(0, 2000) + '…';
            }
            entry.value = stringValue;
            snapshot.fields.add(entry);
            remainingBudget -= (stringValue == null ? 0 : stringValue.length()) + 60;
            if (remainingBudget <= 0) {
                break;
            }
        }
        snapshot.fields.sort(new SnapshotFieldComparator());
        return JSON.serialize(snapshot, true);
    }

    /** Orders snapshot fields by label so the viewer renders a stable, readable record page. */
    private class SnapshotFieldComparator implements Comparator<SnapshotField> {
        public Integer compare(SnapshotField a, SnapshotField b) {
            String labelA = (a.label == null) ? '' : a.label.toLowerCase();
            String labelB = (b.label == null) ? '' : b.label.toLowerCase();
            return labelA.compareTo(labelB);
        }
    }

    private static List<SObject> querySourceRecords(
        String sourceObject, Iterable<String> fields, Set<Id> recordIds
    ) {
        Set<String> selectFields = new Set<String>{ 'Id' };
        for (String field : fields) {
            selectFields.add(field);
        }
        String query =
            'SELECT ' + String.join(new List<String>(selectFields), ', ')
            + ' FROM ' + String.escapeSingleQuotes(sourceObject)
            + ' WHERE Id IN :recordIds WITH USER_MODE';
        return Database.query(query);
    }

    /**
     * Inserts rows into the Big Object and maps each SaveResult back to its source Id.
     * Big Object DML is non-transactional, so a thrown exception marks every row failed.
     */
    private static Map<Id, ArchiveResult> insertBigObjectRows(
        List<SObject> bigObjectRows, List<Id> alignedSourceIds, Map<Id, String> keyBySourceId
    ) {
        Map<Id, ArchiveResult> resultsBySourceId = new Map<Id, ArchiveResult>();
        for (Id sourceId : alignedSourceIds) {
            ArchiveResult result = new ArchiveResult(sourceId);
            result.bigObjectRecordKey = keyBySourceId.get(sourceId);
            resultsBySourceId.put(sourceId, result);
        }
        if (bigObjectRows.isEmpty()) {
            return resultsBySourceId;
        }

        try {
            List<Database.SaveResult> saveResults = Database.insertImmediate(bigObjectRows);
            for (Integer i = 0; i < saveResults.size(); i++) {
                ArchiveResult result = resultsBySourceId.get(alignedSourceIds[i]);
                Database.SaveResult saveResult = saveResults[i];
                result.isSuccess = saveResult.isSuccess();
                if (!saveResult.isSuccess()) {
                    result.errorMessage = formatErrors(saveResult.getErrors());
                }
            }
        } catch (Exception e) {
            for (ArchiveResult result : resultsBySourceId.values()) {
                result.isSuccess = false;
                result.errorMessage = e.getMessage();
            }
        }
        return resultsBySourceId;
    }

    private static String formatErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(messages, '; ');
    }

    // ---------------------------------------------------------------------
    // Source stamping (describe-guarded) + logging
    // ---------------------------------------------------------------------

    /**
     * Stamps archive-tracking fields on successfully archived source records, but only for the
     * tracking fields that actually exist on the object (keeps the tool usable on any object).
     */
    private static void stampArchivedSourceRecords(
        Schema.DescribeSObjectResult sourceDescribe,
        Map<Id, ArchiveResult> resultsBySourceId,
        Map<Id, String> keyBySourceId
    ) {
        Map<String, Schema.SObjectField> sourceFields = sourceDescribe.fields.getMap();
        Boolean hasIsArchived = sourceFields.containsKey(FIELD_IS_ARCHIVED.toLowerCase());
        if (!hasIsArchived) {
            return; // object is not archive-enabled; tracking is handled by the log only
        }
        Boolean hasDate = sourceFields.containsKey(FIELD_ARCHIVED_DATE.toLowerCase());
        Boolean hasBy = sourceFields.containsKey(FIELD_ARCHIVED_BY.toLowerCase());
        Boolean hasKey = sourceFields.containsKey(FIELD_RECORD_KEY.toLowerCase());

        List<SObject> updates = new List<SObject>();
        for (Id sourceId : resultsBySourceId.keySet()) {
            if (resultsBySourceId.get(sourceId).isSuccess != true) {
                continue;
            }
            SObject record = sourceDescribe.getSObjectType().newSObject(sourceId);
            record.put(FIELD_IS_ARCHIVED, true);
            if (hasDate) {
                record.put(FIELD_ARCHIVED_DATE, System.now());
            }
            if (hasBy) {
                record.put(FIELD_ARCHIVED_BY, UserInfo.getUserId());
            }
            if (hasKey) {
                record.put(FIELD_RECORD_KEY, keyBySourceId.get(sourceId));
            }
            updates.add(record);
        }
        if (!updates.isEmpty()) {
            Database.update(updates, false, AccessLevel.USER_MODE);
        }
    }

    /** Caps the record key at the Record_Key__c Text(255) limit so the log insert never fails. */
    private static String truncateKey(String recordKey) {
        if (recordKey == null) {
            return null;
        }
        return recordKey.length() > 255 ? recordKey.substring(0, 255) : recordKey;
    }

    /** Writes one Big_Object_Archive_Log__c row per attempt. */
    private static void writeArchiveLogs(
        String sourceObject, String targetBigObject, Map<Id, ArchiveResult> resultsBySourceId
    ) {
        List<Big_Object_Archive_Log__c> logs = new List<Big_Object_Archive_Log__c>();
        for (ArchiveResult result : resultsBySourceId.values()) {
            logs.add(new Big_Object_Archive_Log__c(
                Source_Record_Id__c = result.sourceRecordId,
                Source_Object__c = sourceObject,
                Target_Big_Object__c = targetBigObject,
                Status__c = result.isSuccess == true ? 'Success' : 'Failed',
                Operation__c = 'Archive',
                Error_Message__c = result.errorMessage,
                Record_Key__c = truncateKey(result.bigObjectRecordKey),
                Record_Snapshot__c = result.isSuccess == true ? result.recordSnapshot : null,
                Archived_By__c = UserInfo.getUserId(),
                Archived_Date__c = System.now()
            ));
        }
        if (!logs.isEmpty()) {
            Database.insert(logs, false, AccessLevel.USER_MODE);
        }
    }
}
