/**
 * Executes one Archive Policy over its matching records in configurable chunks, dispatching by
 * Action Type, and writes an Archive_Execution_Log__c run summary in finish().
 *
 * Action types:
 *  - Soft Delete: stamps Is_Archived__c = true on the target (requires that field).
 *  - Hard Delete: Database.delete with partial success.
 *  - Move to Big Object: bulk archive via BigObjectArchiveService (one insertImmediate per chunk);
 *    with Cascade Children, each record goes through RecordArchivingEngine. Because a Big Object
 *    insertImmediate is a callout and cannot follow regular DML in a transaction, cascade runs ONE
 *    record per chunk (scope size forced to 1 — see scopeSizeFor) so each engine call's inserts
 *    complete before its own side-effect DML, and no second record's insert follows that DML.
 *  - External Store: not implemented in v1 (reported, not failed-silently).
 *
 * Stateful counters only (never holds records across chunks) to stay within heap limits.
 */
public with sharing class ArchivePolicyBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {
    public static final String ACTION_SOFT = 'Soft Delete';
    public static final String ACTION_HARD = 'Hard Delete';
    public static final String ACTION_MOVE = 'Move to Big Object';
    public static final String ACTION_EXTERNAL = 'External Store';
    private static final String SOFT_DELETE_FIELD = 'Is_Archived__c';
    private static final Integer MAX_ERROR_LENGTH = 32000;

    private final Id policyId;
    private final String executionType;

    private Archive_Policy__c policy;
    private Id executionLogId;
    private Datetime startedAt;
    private Integer processed = 0;
    private Integer successCount = 0;
    private Integer failureCount = 0;
    private List<String> errors = new List<String>();

    /**
     * @param policyId The Archive Policy to execute.
     * @param executionType 'Manual' (Run Now) or 'Scheduled'.
     */
    public ArchivePolicyBatch(Id policyId, String executionType) {
        this.policyId = policyId;
        this.executionType = String.isBlank(executionType) ? 'Manual' : executionType;
    }

    /**
     * Chunk size for executeBatch: forced to 1 for cascade Moves (callout-before-DML safety),
     * otherwise the policy's Batch Size clamped to a valid 1-2000 range.
     * @param policy A policy with Action_Type__c, Cascade_Children__c, and Batch_Size__c populated.
     * @return The scope size to pass to Database.executeBatch.
     */
    public static Integer scopeSizeFor(Archive_Policy__c policy) {
        if (policy.Action_Type__c == ACTION_MOVE && policy.Cascade_Children__c == true) {
            return 1;
        }
        Integer requested = (policy.Batch_Size__c == null) ? 200 : policy.Batch_Size__c.intValue();
        if (requested < 1) {
            return 1;
        }
        return Math.min(requested, 2000);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        startedAt = System.now();
        policy = [
            SELECT Id, Target_Object__c, Target_Big_Object__c, Action_Type__c,
                   Filter_Logic__c, Batch_Size__c, Cascade_Children__c
            FROM Archive_Policy__c
            WHERE Id = :policyId
            WITH USER_MODE
            LIMIT 1
        ];
        List<Archive_Policy_Condition__c> conditions = [
            SELECT Sequence__c, Field_API_Name__c, Operator__c, Value__c, Relative_Function__c
            FROM Archive_Policy_Condition__c
            WHERE Archive_Policy__c = :policyId
            WITH USER_MODE
            ORDER BY Sequence__c ASC NULLS LAST
        ];

        Archive_Execution_Log__c log = new Archive_Execution_Log__c(
            Archive_Policy__c = policyId,
            Status__c = 'In Progress',
            Execution_Type__c = executionType,
            Started__c = startedAt,
            Async_Job_Id__c = String.valueOf(context.getJobId()),
            Processed__c = 0,
            Success__c = 0,
            Failure__c = 0
        );
        Database.insert(log, AccessLevel.USER_MODE);
        executionLogId = log.Id;

        ArchivePolicyEngineHelper.QueryPlan plan = ArchivePolicyEngineHelper.buildQueryPlan(
            policy.Target_Object__c, conditions, policy.Filter_Logic__c);
        return Database.getQueryLocatorWithBinds(plan.soql, plan.binds, AccessLevel.USER_MODE);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        processed += scope.size();
        try {
            if (policy.Action_Type__c == ACTION_SOFT) {
                softDelete(scope);
            } else if (policy.Action_Type__c == ACTION_HARD) {
                hardDelete(scope);
            } else if (policy.Action_Type__c == ACTION_MOVE) {
                moveToBigObject(scope);
            } else if (policy.Action_Type__c == ACTION_EXTERNAL) {
                failureCount += scope.size();
                addError('External Store action is not implemented in this version; ' + scope.size() + ' record(s) skipped.');
            } else {
                failureCount += scope.size();
                addError('Unknown action type: ' + policy.Action_Type__c);
            }
        } catch (Exception e) {
            failureCount += scope.size();
            addError('Chunk failed: ' + e.getMessage());
        }
    }

    public void finish(Database.BatchableContext context) {
        Datetime finishedAt = System.now();
        String status = (failureCount > 0 && successCount == 0) ? 'Failed' : 'Completed';

        Archive_Execution_Log__c log = new Archive_Execution_Log__c(Id = executionLogId);
        log.Status__c = status;
        log.Processed__c = processed;
        log.Success__c = successCount;
        log.Failure__c = failureCount;
        log.Finished__c = finishedAt;
        log.Duration_Seconds__c = (finishedAt.getTime() - startedAt.getTime()) / 1000;
        log.Error_Summary__c = errors.isEmpty() ? null : truncate(String.join(errors, '\n'));
        Database.update(log, AccessLevel.USER_MODE);

        Database.update(
            new Archive_Policy__c(Id = policyId, Last_Run__c = finishedAt, Last_Run_Status__c = status),
            AccessLevel.USER_MODE
        );
    }

    // ---- Action handlers ---------------------------------------------------

    private void softDelete(List<SObject> scope) {
        Schema.DescribeSObjectResult describe = ArchivePolicyEngineHelper.describeObject(policy.Target_Object__c);
        if (!describe.fields.getMap().containsKey(SOFT_DELETE_FIELD.toLowerCase())) {
            failureCount += scope.size();
            addError('Soft Delete requires an ' + SOFT_DELETE_FIELD + ' checkbox on ' + describe.getName() + '.');
            return;
        }
        List<SObject> updates = new List<SObject>();
        for (SObject record : scope) {
            SObject update0 = describe.getSObjectType().newSObject(record.Id);
            update0.put(SOFT_DELETE_FIELD, true);
            updates.add(update0);
        }
        tallySaveResults(Database.update(updates, false, AccessLevel.USER_MODE));
    }

    private void hardDelete(List<SObject> scope) {
        for (Database.DeleteResult result : Database.delete(scope, false, AccessLevel.USER_MODE)) {
            if (result.isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                addError(formatErrors(result.getErrors()));
            }
        }
    }

    private void moveToBigObject(List<SObject> scope) {
        if (String.isBlank(policy.Target_Big_Object__c)) {
            failureCount += scope.size();
            addError('Move to Big Object requires a Target Big Object on the policy.');
            return;
        }
        if (policy.Cascade_Children__c == true) {
            // Scope size is forced to 1 (scopeSizeFor) so each engine call's inserts precede its DML.
            for (SObject record : scope) {
                try {
                    RecordArchivingEngine.ArchiveSetResult result =
                        RecordArchivingEngine.archiveRecordWithRelated(record.Id, policy.Target_Big_Object__c);
                    if (result.rootArchived == true) {
                        successCount++;
                    } else {
                        failureCount++;
                        addError('Record ' + record.Id + ' was not archived.');
                    }
                } catch (Exception e) {
                    failureCount++;
                    addError('Record ' + record.Id + ': ' + e.getMessage());
                }
            }
            return;
        }
        Set<Id> ids = new Map<Id, SObject>(scope).keySet();
        for (BigObjectArchiveService.ArchiveResult result :
                BigObjectArchiveService.archiveRecords(ids, policy.Target_Object__c, policy.Target_Big_Object__c)) {
            if (result.isSuccess == true) {
                successCount++;
            } else {
                failureCount++;
                addError(result.errorMessage);
            }
        }
    }

    // ---- Helpers -----------------------------------------------------------

    private void tallySaveResults(List<Database.SaveResult> results) {
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                successCount++;
            } else {
                failureCount++;
                addError(formatErrors(result.getErrors()));
            }
        }
    }

    private void addError(String message) {
        if (String.isBlank(message)) {
            return;
        }
        // Cap the retained errors so finish() never blows the LongTextArea or heap.
        if (errors.size() < 200) {
            errors.add(message);
        }
    }

    private static String formatErrors(List<Database.Error> errorList) {
        List<String> messages = new List<String>();
        for (Database.Error error : errorList) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(messages, '; ');
    }

    private static String truncate(String value) {
        return value.length() > MAX_ERROR_LENGTH ? value.substring(0, MAX_ERROR_LENGTH) : value;
    }
}
