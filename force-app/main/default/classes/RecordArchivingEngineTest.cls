/**
 * Tests for RecordArchivingEngine.
 *
 * Coverage note: the full orchestration happy-path (root + related records archived via
 * Database.insertImmediate) cannot execute in Apex test context — insertImmediate throws an
 * uncatchable "pending uncommitted work" exception once @TestSetup has done DML. This is the same
 * Big Object test-context ceiling that applies to BigObjectArchiveServiceTest. These tests cover
 * the deterministic entry-point guard clauses, which run before any Big Object DML.
 */
@isTest
private class RecordArchivingEngineTest {
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(1, true);
    }

    @isTest
    static void shouldThrow_WhenRecordIdNull() {
        Test.startTest();
        try {
            RecordArchivingEngine.archiveRecordWithRelated(null, 'Archive_Record__b');
            Assert.fail('Expected an AuraHandledException when the record Id is null');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A null record Id should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenBigObjectBlank() {
        Id sourceId = [SELECT Id FROM Archive_Source__c LIMIT 1].Id;

        Test.startTest();
        try {
            RecordArchivingEngine.archiveRecordWithRelated(sourceId, '');
            Assert.fail('Expected an AuraHandledException when the root Big Object is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank root Big Object should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenBigObjectNotBigObject() {
        Id sourceId = [SELECT Id FROM Archive_Source__c LIMIT 1].Id;

        Test.startTest();
        try {
            RecordArchivingEngine.archiveRecordWithRelated(sourceId, 'Account');
            Assert.fail('Expected an AuraHandledException when the target does not end in __b');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A non-Big-Object target should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldExposeArchiveSetResultShape() {
        // Validates the DTO contract the LWC relies on, independent of any Big Object DML.
        RecordArchivingEngine.ArchiveSetResult result =
            new RecordArchivingEngine.ArchiveSetResult('001000000000000AAA', 'Account');
        result.summaries.add(new RecordArchivingEngine.ObjectArchiveSummary('Account', 'Account_Archive__b', true));

        Assert.areEqual('Account', result.rootObject, 'Root object should round-trip');
        Assert.areEqual(false, result.rootArchived, 'rootArchived should default to false');
        Assert.areEqual(0, result.totalArchived, 'totalArchived should default to 0');
        Assert.areEqual(1, result.summaries.size(), 'Summary should be retained');
        Assert.isTrue(result.summaries[0].isRoot, 'First summary should be the root');
    }
}
