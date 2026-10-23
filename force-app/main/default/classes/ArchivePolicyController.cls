/**
 * LWC controller for the Archive Policy Manager. Exposes read APIs for the dashboard and wizard
 * (policies, object/field metadata, execution logs), save, a safe preview COUNT, Run Now (submits
 * the batch), and activate/deactivate (schedules/unschedules the policy via System.schedule).
 * All SOQL runs WITH USER_MODE and user-facing errors are rethrown as AuraHandledException.
 */
public with sharing class ArchivePolicyController {
    public class ControllerException extends Exception {}

    /** Dashboard row. */
    public class PolicyRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String status;
        @AuraEnabled public String actionType;
        @AuraEnabled public String scheduleType;
        @AuraEnabled public Datetime lastRun;
        @AuraEnabled public String lastRunStatus;
        @AuraEnabled public Integer conditionCount;
    }

    /** Full policy + its conditions, for the wizard edit view. */
    public class PolicyDetail {
        @AuraEnabled public Archive_Policy__c policy;
        @AuraEnabled public List<Archive_Policy_Condition__c> conditions;
    }

    /** API name + label option (objects and fields). */
    public class Option {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        public Option(String value, String label, String type) {
            this.value = value;
            this.label = label;
            this.type = type;
        }
    }

    /**
     * @return All policies as dashboard rows, newest first, each with its condition count.
     */
    @AuraEnabled(cacheable=true)
    public static List<PolicyRow> getPolicies() {
        try {
            Map<Id, Integer> countByPolicy = new Map<Id, Integer>();
            for (AggregateResult aggregate : [
                SELECT Archive_Policy__c policyId, COUNT(Id) total
                FROM Archive_Policy_Condition__c
                WITH USER_MODE
                GROUP BY Archive_Policy__c
            ]) {
                countByPolicy.put((Id) aggregate.get('policyId'), (Integer) aggregate.get('total'));
            }

            List<PolicyRow> rows = new List<PolicyRow>();
            for (Archive_Policy__c policy : [
                SELECT Id, Name, Target_Object__c, Status__c, Action_Type__c, Schedule_Type__c,
                       Last_Run__c, Last_Run_Status__c
                FROM Archive_Policy__c
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1000
            ]) {
                PolicyRow row = new PolicyRow();
                row.id = policy.Id;
                row.name = policy.Name;
                row.targetObject = policy.Target_Object__c;
                row.status = policy.Status__c;
                row.actionType = policy.Action_Type__c;
                row.scheduleType = policy.Schedule_Type__c;
                row.lastRun = policy.Last_Run__c;
                row.lastRunStatus = policy.Last_Run_Status__c;
                row.conditionCount = countByPolicy.containsKey(policy.Id) ? countByPolicy.get(policy.Id) : 0;
                rows.add(row);
            }
            return rows;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load policies: ' + e.getMessage());
        }
    }

    /**
     * @param policyId The policy to load.
     * @return The policy and its conditions for editing.
     */
    @AuraEnabled(cacheable=true)
    public static PolicyDetail getPolicy(Id policyId) {
        try {
            PolicyDetail detail = new PolicyDetail();
            detail.policy = [
                SELECT Id, Name, Target_Object__c, Status__c, Action_Type__c, Target_Big_Object__c,
                       Filter_Logic__c, Batch_Size__c, Cascade_Children__c, Schedule_Type__c,
                       Schedule_Time__c, Day_Of_Week__c, Day_Of_Month__c, Cron_Expression__c,
                       Scheduled_Job_Id__c, Last_Run__c, Last_Run_Status__c
                FROM Archive_Policy__c
                WHERE Id = :policyId
                WITH USER_MODE
                LIMIT 1
            ];
            detail.conditions = [
                SELECT Id, Sequence__c, Field_API_Name__c, Operator__c, Value__c, Relative_Function__c
                FROM Archive_Policy_Condition__c
                WHERE Archive_Policy__c = :policyId
                WITH USER_MODE
                ORDER BY Sequence__c ASC NULLS LAST
            ];
            return detail;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load the policy: ' + e.getMessage());
        }
    }

    /**
     * @return Archivable objects (queryable and updateable or deletable) as value/label options.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> getObjectOptions() {
        try {
            List<Option> options = new List<Option>();
            for (Schema.SObjectType token : Schema.getGlobalDescribe().values()) {
                Schema.DescribeSObjectResult describe = token.getDescribe();
                if (!describe.isQueryable() || describe.isCustomSetting() || !describe.isAccessible()) {
                    continue;
                }
                if (!describe.isUpdateable() && !describe.isDeletable()) {
                    continue;
                }
                options.add(new Option(describe.getName(), describe.getLabel(), null));
            }
            options.sort(new OptionComparator());
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load objects: ' + e.getMessage());
        }
    }

    /**
     * @param objectApiName Object whose fields to list.
     * @return Accessible fields as value/label/type options, sorted by label.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> getFieldOptions(String objectApiName) {
        try {
            Schema.DescribeSObjectResult describe = ArchivePolicyEngineHelper.describeObject(objectApiName);
            List<Option> options = new List<Option>();
            for (Schema.SObjectField token : describe.fields.getMap().values()) {
                Schema.DescribeFieldResult field = token.getDescribe();
                if (!field.isAccessible()) {
                    continue;
                }
                options.add(new Option(field.getName(), field.getLabel(), String.valueOf(field.getType()).toLowerCase()));
            }
            options.sort(new OptionComparator());
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load fields: ' + e.getMessage());
        }
    }

    /**
     * Inserts or updates a policy and replaces its conditions.
     * @param policyJson JSON of the Archive_Policy__c record (field API names as keys).
     * @param conditionsJson JSON array of Archive_Policy_Condition__c records.
     * @return The saved policy Id.
     */
    @AuraEnabled
    public static Id savePolicy(String policyJson, String conditionsJson) {
        try {
            Archive_Policy__c policy = (Archive_Policy__c) JSON.deserialize(policyJson, Archive_Policy__c.class);
            Database.upsert(policy, AccessLevel.USER_MODE);

            List<Archive_Policy_Condition__c> conditions = String.isBlank(conditionsJson)
                ? new List<Archive_Policy_Condition__c>()
                : (List<Archive_Policy_Condition__c>) JSON.deserialize(conditionsJson, List<Archive_Policy_Condition__c>.class);

            Set<Id> keepIds = new Set<Id>();
            for (Archive_Policy_Condition__c condition : conditions) {
                condition.Archive_Policy__c = policy.Id;
                if (condition.Id != null) {
                    keepIds.add(condition.Id);
                }
            }

            List<Archive_Policy_Condition__c> toDelete = new List<Archive_Policy_Condition__c>();
            for (Archive_Policy_Condition__c existing : [
                SELECT Id FROM Archive_Policy_Condition__c WHERE Archive_Policy__c = :policy.Id WITH USER_MODE
            ]) {
                if (!keepIds.contains(existing.Id)) {
                    toDelete.add(existing);
                }
            }
            if (!toDelete.isEmpty()) {
                Database.delete(toDelete, AccessLevel.USER_MODE);
            }
            if (!conditions.isEmpty()) {
                Database.upsert(conditions, AccessLevel.USER_MODE);
            }
            return policy.Id;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save the policy: ' + e.getMessage());
        }
    }

    /**
     * Counts records that match the given conditions without modifying any data (preview).
     * @param targetObject Object API name.
     * @param conditionsJson JSON array of conditions (unsaved is fine).
     * @param filterLogic Optional boolean filter-logic expression.
     * @return The number of matching records.
     */
    @AuraEnabled
    public static Integer getPreviewCount(String targetObject, String conditionsJson, String filterLogic) {
        try {
            List<Archive_Policy_Condition__c> conditions = String.isBlank(conditionsJson)
                ? new List<Archive_Policy_Condition__c>()
                : (List<Archive_Policy_Condition__c>) JSON.deserialize(conditionsJson, List<Archive_Policy_Condition__c>.class);
            ArchivePolicyEngineHelper.QueryPlan plan =
                ArchivePolicyEngineHelper.buildCountPlan(targetObject, conditions, filterLogic);
            return Database.countQueryWithBinds(plan.soql, plan.binds, AccessLevel.USER_MODE);
        } catch (ArchivePolicyEngineHelper.PolicyException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unable to preview matching records: ' + e.getMessage());
        }
    }

    /**
     * Submits the policy's batch immediately.
     * @param policyId The policy to run.
     * @return The AsyncApexJob (batch) Id.
     */
    @AuraEnabled
    public static Id runNow(Id policyId) {
        try {
            Archive_Policy__c policy = [
                SELECT Id, Action_Type__c, Cascade_Children__c, Batch_Size__c
                FROM Archive_Policy__c
                WHERE Id = :policyId
                WITH USER_MODE
                LIMIT 1
            ];
            return Database.executeBatch(new ArchivePolicyBatch(policyId, 'Manual'), ArchivePolicyBatch.scopeSizeFor(policy));
        } catch (Exception e) {
            throw new AuraHandledException('Unable to start the run: ' + e.getMessage());
        }
    }

    /**
     * Activates (schedules) or deactivates (unschedules) a policy.
     * @param policyId The policy.
     * @param active true to activate and schedule, false to deactivate and unschedule.
     */
    @AuraEnabled
    public static void setActive(Id policyId, Boolean active) {
        try {
            Archive_Policy__c policy = [
                SELECT Id, Status__c, Schedule_Type__c, Schedule_Time__c, Day_Of_Week__c,
                       Day_Of_Month__c, Cron_Expression__c, Scheduled_Job_Id__c
                FROM Archive_Policy__c
                WHERE Id = :policyId
                WITH USER_MODE
                LIMIT 1
            ];
            if (String.isNotBlank(policy.Scheduled_Job_Id__c)) {
                try {
                    System.abortJob(policy.Scheduled_Job_Id__c);
                } catch (Exception ignored) {
                    // Stale or already-removed job; safe to proceed.
                }
                policy.Scheduled_Job_Id__c = null;
            }
            if (active == true) {
                String jobName = 'ArchivePolicy_' + policyId + '_' + System.now().getTime();
                policy.Scheduled_Job_Id__c = System.schedule(jobName, buildCron(policy), new ArchivePolicyScheduler(policyId));
                policy.Status__c = 'Active';
            } else {
                policy.Status__c = 'Inactive';
            }
            Database.update(policy, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new AuraHandledException('Unable to change the policy status: ' + e.getMessage());
        }
    }

    /**
     * @param policyId The policy whose runs to list.
     * @return Up to 50 most recent execution logs for the policy.
     */
    @AuraEnabled(cacheable=true)
    public static List<Archive_Execution_Log__c> getExecutionLogs(Id policyId) {
        try {
            return [
                SELECT Id, Name, Status__c, Execution_Type__c, Processed__c, Success__c, Failure__c,
                       Started__c, Finished__c, Duration_Seconds__c, Error_Summary__c
                FROM Archive_Execution_Log__c
                WHERE Archive_Policy__c = :policyId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load execution logs: ' + e.getMessage());
        }
    }

    // ---- Helpers -----------------------------------------------------------

    private static final Map<String, Integer> DAY_OF_WEEK = new Map<String, Integer>{
        'Sunday' => 1, 'Monday' => 2, 'Tuesday' => 3, 'Wednesday' => 4,
        'Thursday' => 5, 'Friday' => 6, 'Saturday' => 7
    };

    /** Builds a Salesforce CRON expression from the policy's schedule fields. */
    @TestVisible
    private static String buildCron(Archive_Policy__c policy) {
        if (policy.Schedule_Type__c == 'Cron') {
            if (String.isBlank(policy.Cron_Expression__c)) {
                throw new ControllerException('A Cron Expression is required for a Cron schedule.');
            }
            return policy.Cron_Expression__c;
        }
        Integer hour = (policy.Schedule_Time__c == null) ? 0 : policy.Schedule_Time__c.hour();
        Integer minute = (policy.Schedule_Time__c == null) ? 0 : policy.Schedule_Time__c.minute();
        String base = '0 ' + minute + ' ' + hour + ' ';
        if (policy.Schedule_Type__c == 'Weekly') {
            Integer dow = DAY_OF_WEEK.containsKey(policy.Day_Of_Week__c) ? DAY_OF_WEEK.get(policy.Day_Of_Week__c) : 1;
            return base + '? * ' + dow;
        }
        if (policy.Schedule_Type__c == 'Monthly') {
            Integer dom = (policy.Day_Of_Month__c == null) ? 1 : policy.Day_Of_Month__c.intValue();
            return base + dom + ' * ?';
        }
        // Daily (default)
        return base + '* * ?';
    }

    /** Sorts options alphabetically by label. */
    private class OptionComparator implements Comparator<Option> {
        public Integer compare(Option a, Option b) {
            String labelA = (a.label == null) ? '' : a.label.toLowerCase();
            String labelB = (b.label == null) ? '' : b.label.toLowerCase();
            return labelA.compareTo(labelB);
        }
    }
}
