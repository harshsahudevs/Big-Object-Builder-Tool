/**
 * Thin @AuraEnabled controller backing the bigObjectRecordViewer LWC. Lists Big Objects, returns the
 * archived rows for a selected Big Object, and unarchives rows (restores them to the source object and
 * removes them from the Big Object). Querying is delegated to BigObjectQueryService and unarchiving to
 * BigObjectArchiveService so the Big Object read/write rules stay in one place.
 */
public with sharing class BigObjectBrowserController {
    // Viewer loads a single bounded page; Big Objects do not support COUNT()/OFFSET.
    private static final Integer MAX_ROWS = 200;

    public class BigObjectBrowserException extends Exception {}

    /** Option for the Big Object selector, sorted by label. */
    public class BigObjectOption implements Comparable {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;

        public BigObjectOption(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }

        public Integer compareTo(Object other) {
            return this.label.compareTo(((BigObjectOption) other).label);
        }
    }

    /**
     * Lists every Big Object (__b) the running user can access, for the viewer's picker.
     * @return Big Object options sorted by label.
     */
    @AuraEnabled(cacheable=true)
    public static List<BigObjectOption> getBigObjects() {
        try {
            List<BigObjectOption> options = new List<BigObjectOption>();
            Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
            for (String apiName : globalDescribe.keySet()) {
                if (!apiName.endsWithIgnoreCase('__b')) {
                    continue;
                }
                Schema.DescribeSObjectResult describe = globalDescribe.get(apiName).getDescribe();
                if (describe.isAccessible()) {
                    options.add(new BigObjectOption(describe.getName(), describe.getLabel()));
                }
            }
            options.sort();
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to list Big Objects: ' + e.getMessage());
        }
    }

    /** One archive-history entry for the record-page related list. */
    public class HistoryRow {
        @AuraEnabled public String id;
        @AuraEnabled public Datetime archivedDate;
        @AuraEnabled public String targetBigObject;
        @AuraEnabled public String sourceObject;
        @AuraEnabled public String status;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String archivedByName;
    }

    /**
     * Returns the archive history for a single source record (newest first), read from the archive
     * log. Backs archivedRecordsRelatedList on ANY record page with zero configuration: it keys off
     * the record Id, never off Big Object index fields, so it always works regardless of how the
     * Big Object was defined.
     * @param recordId The record whose archive history to list.
     * @return Archive-log rows for that record; empty when the record was never archived.
     */
    @AuraEnabled(cacheable=true)
    public static List<HistoryRow> getArchiveHistory(Id recordId) {
        List<HistoryRow> rows = new List<HistoryRow>();
        if (recordId == null) {
            return rows;
        }
        try {
            String recordKey = String.valueOf(recordId);
            for (Big_Object_Archive_Log__c logEntry : [
                SELECT Archived_Date__c, Target_Big_Object__c, Source_Object__c,
                       Status__c, Error_Message__c, Archived_By__r.Name
                FROM Big_Object_Archive_Log__c
                WHERE Source_Record_Id__c = :recordKey
                WITH USER_MODE
                ORDER BY Archived_Date__c DESC NULLS LAST
                LIMIT 200
            ]) {
                HistoryRow row = new HistoryRow();
                row.id = logEntry.Id;
                row.archivedDate = logEntry.Archived_Date__c;
                row.targetBigObject = logEntry.Target_Big_Object__c;
                row.sourceObject = logEntry.Source_Object__c;
                row.status = logEntry.Status__c;
                row.errorMessage = logEntry.Error_Message__c;
                row.archivedByName = (logEntry.Archived_By__r != null) ? logEntry.Archived_By__r.Name : null;
                rows.add(row);
            }
            return rows;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load archive history: ' + e.getMessage());
        }
    }

    /**
     * Returns up to MAX_ROWS archived rows for a Big Object, exposing every field as a column.
     * @param bigObjectApiName Big Object API name (e.g. Case_Archive__b).
     * @return Columns + rows; each row carries its index record key, used to unarchive it.
     */
    @AuraEnabled
    public static BigObjectQueryService.QueryResult getRecords(String bigObjectApiName) {
        try {
            return queryAll(bigObjectApiName);
        } catch (AuraHandledException e) {
            throw e; // preserve the original user-facing message from the delegated service
        } catch (BigObjectBrowserException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load archived records: ' + e.getMessage());
        }
    }

    /**
     * Returns the full-record JSON snapshot captured at archive time for a Big Object row, so the
     * viewer can render the complete record even where non-index Big Object fields are not
     * SOQL-queryable. Matches the most recent successful archive log by Big Object + record key.
     * @param bigObjectApiName Big Object holding the row.
     * @param recordKey The row's index record key (from getRecords).
     * @return The snapshot JSON string, or null when no snapshot was captured for this row.
     */
    @AuraEnabled(cacheable=true)
    public static String getRecordSnapshot(String bigObjectApiName, String recordKey) {
        try {
            if (String.isBlank(bigObjectApiName) || String.isBlank(recordKey)) {
                return null;
            }
            // Record_Snapshot__c is a LongTextArea and cannot be filtered in SOQL, so match on the
            // record key and the Archive operation, then pick the most recent row that has a snapshot.
            List<Big_Object_Archive_Log__c> logs = [
                SELECT Record_Snapshot__c
                FROM Big_Object_Archive_Log__c
                WHERE Target_Big_Object__c = :bigObjectApiName
                    AND Record_Key__c = :recordKey
                    AND Operation__c = 'Archive'
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];
            for (Big_Object_Archive_Log__c log : logs) {
                if (String.isNotBlank(log.Record_Snapshot__c)) {
                    return log.Record_Snapshot__c;
                }
            }
            return null;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load the record snapshot: ' + e.getMessage());
        }
    }

    /**
     * Unarchives selected rows: recreates each in the source object, then removes it from the Big
     * Object. Partial success is reported per record.
     * @param bigObjectApiName Big Object holding the rows.
     * @param recordKeys Index record keys of the rows to unarchive (from getRecords).
     * @return One restore outcome per key.
     */
    @AuraEnabled
    public static List<BigObjectArchiveService.RestoreResult> unarchiveRecords(
        String bigObjectApiName, List<String> recordKeys
    ) {
        try {
            if (String.isBlank(bigObjectApiName)) {
                throw new BigObjectBrowserException('A Big Object API name is required.');
            }
            if (recordKeys == null || recordKeys.isEmpty()) {
                throw new BigObjectBrowserException('Select at least one record to unarchive.');
            }
            String sourceObject = resolveSourceObject(bigObjectApiName);
            return BigObjectArchiveService.restoreRecords(bigObjectApiName, sourceObject, recordKeys, true);
        } catch (AuraHandledException e) {
            throw e; // preserve the original user-facing message from the delegated service
        } catch (BigObjectBrowserException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unarchive failed: ' + e.getMessage());
        }
    }

    /**
     * Unarchives a single row AND its related archived records as a set, re-linking the restored
     * children to the restored parent. Delegates to UnarchiveEngine; the source object is resolved
     * from the archive log the same way the per-record unarchive does.
     * @param bigObjectApiName Big Object holding the root row.
     * @param recordKey Index record key of the root row (from getRecords).
     * @return The whole-record unarchive outcome (per-object counts, re-link status, fidelity notes).
     */
    @AuraEnabled
    public static UnarchiveEngine.UnarchiveSetResult unarchiveRecordWithRelated(
        String bigObjectApiName, String recordKey
    ) {
        try {
            if (String.isBlank(bigObjectApiName)) {
                throw new BigObjectBrowserException('A Big Object API name is required.');
            }
            if (String.isBlank(recordKey)) {
                throw new BigObjectBrowserException('A record key is required.');
            }
            String sourceObject = resolveSourceObject(bigObjectApiName);
            return UnarchiveEngine.unarchiveRecordWithRelated(bigObjectApiName, sourceObject, recordKey, true);
        } catch (AuraHandledException e) {
            throw e; // preserve the original user-facing message from the delegated engine
        } catch (BigObjectBrowserException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unarchive failed: ' + e.getMessage());
        }
    }

    /**
     * Unarchives every row currently in the Big Object (up to MAX_ROWS per call): recreates each in
     * the source object, then removes it from the Big Object.
     * @param bigObjectApiName Big Object to empty back into its source object.
     * @return One restore outcome per key (empty list when there is nothing to unarchive).
     */
    @AuraEnabled
    public static List<BigObjectArchiveService.RestoreResult> unarchiveAll(String bigObjectApiName) {
        try {
            if (String.isBlank(bigObjectApiName)) {
                throw new BigObjectBrowserException('A Big Object API name is required.');
            }
            BigObjectQueryService.QueryResult result = queryAll(bigObjectApiName);
            List<String> keys = new List<String>();
            for (BigObjectQueryService.Row row : result.rows) {
                if (String.isNotBlank(row.recordKey)) {
                    keys.add(row.recordKey);
                }
            }
            if (keys.isEmpty()) {
                return new List<BigObjectArchiveService.RestoreResult>();
            }
            String sourceObject = resolveSourceObject(bigObjectApiName);
            return BigObjectArchiveService.restoreRecords(bigObjectApiName, sourceObject, keys, true);
        } catch (AuraHandledException e) {
            throw e; // preserve the original user-facing message from the delegated service
        } catch (BigObjectBrowserException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unarchive all failed: ' + e.getMessage());
        }
    }

    // ---- helpers -----------------------------------------------------------

    /** Builds a request that selects every field and reuses the query service's index-safe SOQL. */
    private static BigObjectQueryService.QueryResult queryAll(String bigObjectApiName) {
        Schema.DescribeSObjectResult describe = describeBigObject(bigObjectApiName);
        List<String> allFields = new List<String>();
        for (Schema.SObjectField token : describe.fields.getMap().values()) {
            allFields.add(token.getDescribe().getName());
        }
        BigObjectQueryService.QueryRequest request = new BigObjectQueryService.QueryRequest();
        request.bigObjectApiName = describe.getName();
        request.displayFields = allFields;
        request.pageSize = MAX_ROWS;
        request.sortDirection = 'ASC';
        return BigObjectQueryService.getArchivedRecords(request);
    }

    private static Schema.DescribeSObjectResult describeBigObject(String apiName) {
        if (String.isBlank(apiName)) {
            throw new BigObjectBrowserException('A Big Object API name is required.');
        }
        SObjectType sobjType = Schema.getGlobalDescribe().get(apiName);
        if (sobjType == null) {
            throw new BigObjectBrowserException('Unknown Big Object: ' + apiName);
        }
        if (!apiName.endsWithIgnoreCase('__b')) {
            throw new BigObjectBrowserException(apiName + ' is not a Big Object (must end in __b).');
        }
        return sobjType.getDescribe();
    }

    /**
     * Determines the source object a Big Object archives from. Prefers the authoritative archive log
     * (Source_Object__c of the most recent entry), falling back to the tool's <Source>_Archive__b
     * naming convention when no log entry exists yet.
     */
    private static String resolveSourceObject(String bigObjectApiName) {
        List<Big_Object_Archive_Log__c> logs = [
            SELECT Source_Object__c
            FROM Big_Object_Archive_Log__c
            WHERE Target_Big_Object__c = :bigObjectApiName AND Source_Object__c != null
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!logs.isEmpty() && String.isNotBlank(logs[0].Source_Object__c)) {
            return logs[0].Source_Object__c;
        }

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        String base = bigObjectApiName.removeEndIgnoreCase('__b');
        if (base.endsWithIgnoreCase('_Archive')) {
            base = base.removeEndIgnoreCase('_Archive');
        }
        if (globalDescribe.containsKey(base.toLowerCase())) {
            return globalDescribe.get(base.toLowerCase()).getDescribe().getName();
        }
        if (globalDescribe.containsKey((base + '__c').toLowerCase())) {
            return globalDescribe.get((base + '__c').toLowerCase()).getDescribe().getName();
        }
        throw new BigObjectBrowserException(
            'Could not determine the source object for ' + bigObjectApiName
            + '. Archive at least one record first so the source mapping is known.');
    }
}
