/**
 * Controller for the Big Object Admin dashboard (Phase 5).
 *
 * All volume metrics come from Big_Object_Archive_Log__c (a normal object that supports COUNT/GROUP BY)
 * and the Big_Object_Count_Cache__c setting — never from counting Big Object rows synchronously, which
 * is unsupported and would not scale. Inventory and index fields come from describe.
 */
public with sharing class BigObjectAdminController {
    private static final Long DEFAULT_RECORD_LIMIT = 1000000L;
    private static final String STATUS_SUCCESS = 'Success';
    private static final String STATUS_FAILED = 'Failed';
    private static final String OPERATION_RESTORE = 'Restore';

    // ---- DTOs --------------------------------------------------------------

    public class DashboardMetrics {
        @AuraEnabled public Integer totalBigObjects;
        @AuraEnabled public Long totalArchived;
        @AuraEnabled public Long totalUnarchived;
        @AuraEnabled public Long recordLimit;
        @AuraEnabled public Decimal usagePercent;
        @AuraEnabled public Integer failedCount;
        @AuraEnabled public Integer unarchiveFailedCount;
        @AuraEnabled public List<ActivityEntry> recentActivity = new List<ActivityEntry>();
    }

    public class ActivityEntry {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String operation;
        @AuraEnabled public String sourceObject;
        @AuraEnabled public String targetBigObject;
        @AuraEnabled public String status;
        @AuraEnabled public String performedBy;
        @AuraEnabled public Datetime performedDate;
        @AuraEnabled public String errorMessage;
    }

    public class BigObjectInventory {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public List<String> indexFields = new List<String>();
        @AuraEnabled public Long approxRecordCount;
        @AuraEnabled public Datetime lastCounted;
        @AuraEnabled public String setupUrl;
    }

    public class AdminConfig {
        @AuraEnabled public Long recordLimit;
        @AuraEnabled public Boolean autoDeleteSource;
    }

    // ---- Dashboard metrics -------------------------------------------------

    /**
     * Returns the headline metrics for the admin dashboard.
     * @return Aggregated counts, usage, and recent activity.
     */
    @AuraEnabled(cacheable=true)
    public static DashboardMetrics getDashboardMetrics() {
        try {
            DashboardMetrics metrics = new DashboardMetrics();
            metrics.totalBigObjects = listBigObjectApiNames().size();
            metrics.recordLimit = getConfiguredRecordLimit();

            // Archive vs unarchive are both logged with Status Success/Failed; Operation__c tells
            // them apart. Legacy rows (null Operation) are treated as Archive, so archived counts =
            // all successes minus restore successes (never negative).
            Integer successTotal = [
                SELECT COUNT()
                FROM Big_Object_Archive_Log__c
                WHERE Status__c = :STATUS_SUCCESS
                WITH USER_MODE
            ];
            Integer unarchived = [
                SELECT COUNT()
                FROM Big_Object_Archive_Log__c
                WHERE Status__c = :STATUS_SUCCESS AND Operation__c = :OPERATION_RESTORE
                WITH USER_MODE
            ];
            Integer archived = successTotal - unarchived;
            metrics.totalArchived = archived;
            metrics.totalUnarchived = unarchived;
            metrics.usagePercent = (metrics.recordLimit == 0)
                ? 0
                : (Decimal.valueOf(archived) / metrics.recordLimit * 100).setScale(2);

            Integer failedTotal = [
                SELECT COUNT()
                FROM Big_Object_Archive_Log__c
                WHERE Status__c = :STATUS_FAILED
                WITH USER_MODE
            ];
            Integer unarchiveFailed = [
                SELECT COUNT()
                FROM Big_Object_Archive_Log__c
                WHERE Status__c = :STATUS_FAILED AND Operation__c = :OPERATION_RESTORE
                WITH USER_MODE
            ];
            metrics.failedCount = failedTotal - unarchiveFailed;
            metrics.unarchiveFailedCount = unarchiveFailed;

            metrics.recentActivity = getRecentActivity(10);
            return metrics;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load dashboard metrics: ' + e.getMessage());
        }
    }

    private static List<ActivityEntry> getRecentActivity(Integer rowLimit) {
        List<ActivityEntry> entries = new List<ActivityEntry>();
        for (Big_Object_Archive_Log__c log : [
            SELECT Name, Operation__c, Source_Object__c, Target_Big_Object__c, Status__c,
                   Archived_By__r.Name, Archived_Date__c, Error_Message__c
            FROM Big_Object_Archive_Log__c
            WITH USER_MODE
            ORDER BY Archived_Date__c DESC NULLS LAST
            LIMIT :rowLimit
        ]) {
            ActivityEntry entry = new ActivityEntry();
            entry.id = log.Id;
            entry.name = log.Name;
            entry.operation = String.isBlank(log.Operation__c) ? 'Archive' : log.Operation__c;
            entry.sourceObject = log.Source_Object__c;
            entry.targetBigObject = log.Target_Big_Object__c;
            entry.status = log.Status__c;
            entry.performedBy = (log.Archived_By__r == null) ? null : log.Archived_By__r.Name;
            entry.performedDate = log.Archived_Date__c;
            entry.errorMessage = log.Error_Message__c;
            entries.add(entry);
        }
        return entries;
    }

    // ---- Inventory ---------------------------------------------------------

    /**
     * Lists every Big Object in the org with its index fields and cached approximate count.
     * @return Inventory rows for the datatable.
     */
    @AuraEnabled(cacheable=true)
    public static List<BigObjectInventory> getBigObjectInventory() {
        try {
            Map<String, Big_Object_Count_Cache__c> cache = Big_Object_Count_Cache__c.getAll();
            List<BigObjectInventory> inventory = new List<BigObjectInventory>();
            for (String apiName : listBigObjectApiNames()) {
                Schema.DescribeSObjectResult describe = Schema.getGlobalDescribe().get(apiName).getDescribe();
                BigObjectInventory item = new BigObjectInventory();
                item.apiName = apiName;
                item.label = describe.getLabel();
                item.indexFields = getIndexFields(describe);
                item.setupUrl = '/lightning/setup/BigObjects/home';
                if (cache.containsKey(apiName)) {
                    Decimal count = cache.get(apiName).Record_Count__c;
                    item.approxRecordCount = (count == null) ? null : count.longValue();
                    item.lastCounted = cache.get(apiName).Last_Counted__c;
                }
                inventory.add(item);
            }
            return inventory;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load Big Object inventory: ' + e.getMessage());
        }
    }

    /**
     * Recomputes approximate record counts (per target Big Object) from the archive log and caches them.
     * @return The refreshed inventory.
     */
    @AuraEnabled
    public static List<BigObjectInventory> refreshRecordCounts() {
        try {
            Map<String, Big_Object_Count_Cache__c> existing = Big_Object_Count_Cache__c.getAll();
            List<Big_Object_Count_Cache__c> toUpsert = new List<Big_Object_Count_Cache__c>();
            for (AggregateResult ar : [
                SELECT Target_Big_Object__c target, COUNT(Id) cnt
                FROM Big_Object_Archive_Log__c
                WHERE Status__c = :STATUS_SUCCESS AND Target_Big_Object__c != null
                WITH USER_MODE
                GROUP BY Target_Big_Object__c
            ]) {
                String target = (String) ar.get('target');
                Big_Object_Count_Cache__c record = existing.containsKey(target)
                    ? existing.get(target)
                    : new Big_Object_Count_Cache__c(Name = target);
                record.Record_Count__c = (Integer) ar.get('cnt');
                record.Last_Counted__c = System.now();
                toUpsert.add(record);
            }
            if (!toUpsert.isEmpty()) {
                upsert toUpsert;
            }
            return getBigObjectInventory();
        } catch (Exception e) {
            throw new AuraHandledException('Unable to refresh record counts: ' + e.getMessage());
        }
    }

    // ---- Admin configuration ----------------------------------------------

    @AuraEnabled(cacheable=true)
    public static AdminConfig getAdminConfig() {
        Big_Object_Admin_Config__c cfg = Big_Object_Admin_Config__c.getOrgDefaults();
        AdminConfig config = new AdminConfig();
        config.recordLimit = (cfg.Record_Limit__c == null) ? DEFAULT_RECORD_LIMIT : cfg.Record_Limit__c.longValue();
        config.autoDeleteSource = cfg.Auto_Delete_Source__c == true;
        return config;
    }

    @AuraEnabled
    public static void saveAdminConfig(Long recordLimit, Boolean autoDeleteSource) {
        try {
            Big_Object_Admin_Config__c cfg = Big_Object_Admin_Config__c.getOrgDefaults();
            if (cfg.Id == null) {
                cfg.SetupOwnerId = UserInfo.getOrganizationId();
            }
            cfg.Record_Limit__c = recordLimit;
            cfg.Auto_Delete_Source__c = autoDeleteSource;
            upsert cfg;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save admin config: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Big_Object_Archive_Setting__c> getArchiveSettings() {
        return Big_Object_Archive_Setting__c.getAll().values();
    }

    @AuraEnabled
    public static void saveArchiveSetting(String objectApiName, Boolean enabled, String targetBigObject, Boolean autoDelete) {
        try {
            if (String.isBlank(objectApiName)) {
                throw new BigObjectAdminException('An object API name is required.');
            }
            Map<String, Big_Object_Archive_Setting__c> all = Big_Object_Archive_Setting__c.getAll();
            Big_Object_Archive_Setting__c setting = all.containsKey(objectApiName)
                ? all.get(objectApiName)
                : new Big_Object_Archive_Setting__c(Name = objectApiName);
            setting.Enabled__c = enabled == true;
            setting.Target_Big_Object__c = targetBigObject;
            setting.Auto_Delete_Source__c = autoDelete == true;
            upsert setting;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save archive setting: ' + e.getMessage());
        }
    }

    // ---- Helpers -----------------------------------------------------------

    public class BigObjectAdminException extends Exception {}

    /** All Big Object (__b) API names in the org. */
    private static List<String> listBigObjectApiNames() {
        List<String> apiNames = new List<String>();
        for (String apiName : Schema.getGlobalDescribe().keySet()) {
            if (apiName.endsWith('__b')) {
                apiNames.add(Schema.getGlobalDescribe().get(apiName).getDescribe().getName());
            }
        }
        apiNames.sort();
        return apiNames;
    }

    /** Index fields = required (non-nillable) createable fields, in a stable order. */
    private static List<String> getIndexFields(Schema.DescribeSObjectResult describe) {
        List<String> indexFields = new List<String>();
        for (String fieldName : describe.fields.getMap().keySet()) {
            Schema.DescribeFieldResult df = describe.fields.getMap().get(fieldName).getDescribe();
            if (!df.isNillable() && df.isCreateable()) {
                indexFields.add(df.getName());
            }
        }
        indexFields.sort();
        return indexFields;
    }

    private static Long getConfiguredRecordLimit() {
        Big_Object_Admin_Config__c cfg = Big_Object_Admin_Config__c.getOrgDefaults();
        return (cfg.Record_Limit__c == null) ? DEFAULT_RECORD_LIMIT : cfg.Record_Limit__c.longValue();
    }
}
