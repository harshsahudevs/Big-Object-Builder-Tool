/**
 * Tests for ArchivePolicyBatch and ArchivePolicyScheduler. Soft Delete and Hard Delete run fully in
 * test context (no Big Object DML), so their happy paths are asserted end-to-end including the
 * execution-log summary. Move to Big Object is covered on its validation branch (the archive
 * happy-path needs insertImmediate, which cannot run in a test). scopeSizeFor is unit-tested.
 */
@isTest
private class ArchivePolicyBatchTest {
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(5, true); // Amounts 100..104, Is_Archived__c = false
    }

    private static Archive_Policy__c insertPolicy(String actionType, String bigObject, Boolean cascade) {
        Archive_Policy__c policy = new Archive_Policy__c(
            Name = 'Test ' + actionType,
            Target_Object__c = 'Archive_Source__c',
            Action_Type__c = actionType,
            Target_Big_Object__c = bigObject,
            Cascade_Children__c = cascade,
            Batch_Size__c = 200,
            Status__c = 'Draft'
        );
        insert policy;
        insert new Archive_Policy_Condition__c(
            Archive_Policy__c = policy.Id,
            Sequence__c = 1,
            Field_API_Name__c = 'Amount__c',
            Operator__c = 'Greater Or Equal',
            Value__c = '100'
        );
        return policy;
    }

    private static Archive_Execution_Log__c logFor(Id policyId) {
        return [
            SELECT Status__c, Processed__c, Success__c, Failure__c, Duration_Seconds__c, Execution_Type__c
            FROM Archive_Execution_Log__c
            WHERE Archive_Policy__c = :policyId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    @isTest
    static void softDelete_FlagsAllMatchingRecords_AndLogsRun() {
        Archive_Policy__c policy = insertPolicy('Soft Delete', null, false);

        Test.startTest();
        Database.executeBatch(new ArchivePolicyBatch(policy.Id, 'Manual'), 200);
        Test.stopTest();

        Assert.areEqual(5, [SELECT COUNT() FROM Archive_Source__c WHERE Is_Archived__c = true],
            'All five matching records should be soft-deleted.');
        Archive_Execution_Log__c log = logFor(policy.Id);
        Assert.areEqual('Completed', log.Status__c, 'Run should complete.');
        Assert.areEqual(5, log.Success__c, 'Five successes expected.');
        Assert.areEqual(0, log.Failure__c, 'No failures expected.');
        Assert.areEqual(5, log.Processed__c, 'Five processed.');
    }

    @isTest
    static void hardDelete_DeletesAllMatchingRecords_AndLogsRun() {
        Archive_Policy__c policy = insertPolicy('Hard Delete', null, false);

        Test.startTest();
        Database.executeBatch(new ArchivePolicyBatch(policy.Id, 'Scheduled'), 200);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Archive_Source__c], 'All matching records should be deleted.');
        Archive_Execution_Log__c log = logFor(policy.Id);
        Assert.areEqual('Completed', log.Status__c, 'Run should complete.');
        Assert.areEqual(5, log.Success__c, 'Five deletions expected.');
        Assert.areEqual('Scheduled', log.Execution_Type__c, 'Execution type should round-trip.');
    }

    @isTest
    static void moveWithoutBigObject_ReportsFailure() {
        // Move with a blank Target Big Object fails validation in execute() with no Big Object DML.
        Archive_Policy__c policy = insertPolicy('Move to Big Object', null, false);

        Test.startTest();
        Database.executeBatch(new ArchivePolicyBatch(policy.Id, 'Manual'), 200);
        Test.stopTest();

        Archive_Execution_Log__c log = logFor(policy.Id);
        Assert.areEqual('Failed', log.Status__c, 'A Move with no Big Object should fail the run.');
        Assert.areEqual(5, log.Failure__c, 'All processed records should be counted as failures.');
        Assert.areEqual(0, log.Success__c, 'No successes expected.');
    }

    @isTest
    static void externalStore_IsReportedNotImplemented() {
        Archive_Policy__c policy = insertPolicy('External Store', null, false);

        Test.startTest();
        Database.executeBatch(new ArchivePolicyBatch(policy.Id, 'Manual'), 200);
        Test.stopTest();

        Archive_Execution_Log__c log = logFor(policy.Id);
        Assert.areEqual('Failed', log.Status__c, 'External Store is not implemented, so the run fails.');
        Assert.areEqual(5, log.Failure__c, 'All records counted as skipped/failed.');
    }

    @isTest
    static void scopeSizeFor_ForcesOneForCascadeMove_ClampsOtherwise() {
        Archive_Policy__c cascadeMove = new Archive_Policy__c(
            Action_Type__c = 'Move to Big Object', Cascade_Children__c = true, Batch_Size__c = 500);
        Assert.areEqual(1, ArchivePolicyBatch.scopeSizeFor(cascadeMove), 'Cascade Move must run one record per chunk.');

        Archive_Policy__c big = new Archive_Policy__c(
            Action_Type__c = 'Soft Delete', Cascade_Children__c = false, Batch_Size__c = 5000);
        Assert.areEqual(2000, ArchivePolicyBatch.scopeSizeFor(big), 'Batch size should clamp to 2000.');

        Archive_Policy__c none = new Archive_Policy__c(
            Action_Type__c = 'Soft Delete', Cascade_Children__c = false, Batch_Size__c = null);
        Assert.areEqual(200, ArchivePolicyBatch.scopeSizeFor(none), 'Null batch size should default to 200.');

        Archive_Policy__c zero = new Archive_Policy__c(
            Action_Type__c = 'Hard Delete', Cascade_Children__c = false, Batch_Size__c = 0);
        Assert.areEqual(1, ArchivePolicyBatch.scopeSizeFor(zero), 'A non-positive batch size should floor to 1.');
    }

    @isTest
    static void scheduler_SubmitsPolicyBatch() {
        Archive_Policy__c policy = insertPolicy('Soft Delete', null, false);

        Test.startTest();
        new ArchivePolicyScheduler(policy.Id).execute(null);
        Test.stopTest();

        Assert.areEqual(5, [SELECT COUNT() FROM Archive_Source__c WHERE Is_Archived__c = true],
            'The scheduler should have submitted the batch and archived the records.');
        Assert.areEqual('Scheduled', logFor(policy.Id).Execution_Type__c, 'Scheduler runs are logged as Scheduled.');
    }
}
