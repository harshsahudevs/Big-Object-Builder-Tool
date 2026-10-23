/**
 * Tests for UnarchiveEngine.
 *
 * Coverage note: the full faithful-unarchive happy-path (root + related rows restored FROM a Big
 * Object) cannot execute in Apex test context — Big Object rows cannot be seeded in a test (an
 * insertImmediate throws an uncatchable "pending uncommitted work" exception once @TestSetup has
 * done DML), so restore queries always see an empty Big Object. These tests cover the deterministic
 * entry-point guard clauses, the DTO contract the LWC relies on, and the engine body up to the
 * point where a non-existent key yields no restore (exercising readOriginalRootId, restoreOne, and
 * the "related records not restored" note path) — all without any Big Object DML.
 */
@isTest
private class UnarchiveEngineTest {
    private static final String ROOT_BIG_OBJECT = 'Archive_Record__b';
    private static final String ROOT_SOURCE = 'Archive_Source__c';

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(1, true);
    }

    @isTest
    static void shouldThrow_WhenRootBigObjectBlank() {
        Test.startTest();
        try {
            UnarchiveEngine.unarchiveRecordWithRelated('', ROOT_SOURCE, 'key', false);
            Assert.fail('Expected an AuraHandledException when the root Big Object is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank root Big Object should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenRootBigObjectNotBigObject() {
        Test.startTest();
        try {
            UnarchiveEngine.unarchiveRecordWithRelated('Account', ROOT_SOURCE, 'key', false);
            Assert.fail('Expected an AuraHandledException when the target does not end in __b');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A non-Big-Object target should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenSourceObjectBlank() {
        Test.startTest();
        try {
            UnarchiveEngine.unarchiveRecordWithRelated(ROOT_BIG_OBJECT, '', 'key', false);
            Assert.fail('Expected an AuraHandledException when the source object is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank source object should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenRecordKeyBlank() {
        Test.startTest();
        try {
            UnarchiveEngine.unarchiveRecordWithRelated(ROOT_BIG_OBJECT, ROOT_SOURCE, '', false);
            Assert.fail('Expected an AuraHandledException when the record key is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank record key should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldReportRootNotRestored_WhenKeyHasNoArchivedRow() {
        // A key with no matching Big Object row restores nothing; the engine must report the root as
        // not restored and note that related records could not be pulled (no Big Object DML occurs).
        Test.startTest();
        UnarchiveEngine.UnarchiveSetResult result = UnarchiveEngine.unarchiveRecordWithRelated(
            ROOT_BIG_OBJECT, ROOT_SOURCE, 'no-such-key', false);
        Test.stopTest();

        Assert.isFalse(result.rootRestored, 'An unknown key should not restore the root');
        Assert.isNull(result.newRootRecordId, 'No new root Id should be produced');
        Assert.areEqual(0, result.totalRestored, 'Nothing should be restored');
        Assert.isFalse(result.summaries.isEmpty(), 'The root summary should always be present');
        Assert.isTrue(result.summaries[0].isRoot, 'First summary should be the root');
        Assert.isFalse(result.notes.isEmpty(), 'A fidelity note should explain why related rows were skipped');
    }

    @isTest
    static void shouldScanKeyedFieldValues_WhenBigObjectEmpty() {
        // scanKeyedFieldValues underpins both root-Id lookup and child matching; on an empty Big
        // Object it must return an empty map (and self-heal an unknown field rather than throw).
        Test.startTest();
        Map<String, Object> values =
            BigObjectArchiveService.scanKeyedFieldValues(ROOT_BIG_OBJECT, 'Not_A_Real_Field__c');
        Test.stopTest();

        Assert.isNotNull(values, 'Scan should return a map, not null');
        Assert.isTrue(values.isEmpty(), 'An empty Big Object should yield no keyed values');
    }

    @isTest
    static void shouldRestoreNothing_WithOverrides_WhenKeyHasNoArchivedRow() {
        // The overrides-capable restore (used for child re-linking) must behave like plain restore
        // when no row matches: one failed result, no DML, no exception.
        Test.startTest();
        List<BigObjectArchiveService.RestoreResult> results = BigObjectArchiveService.restoreRecordsWithOverrides(
            ROOT_BIG_OBJECT, ROOT_SOURCE, new List<String>{ 'no-such-key' }, false,
            new Map<String, Object>{ 'Name' => 'Ignored' });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'One result per requested key');
        Assert.isFalse(results[0].isSuccess, 'An unknown key should not restore');
    }

    @isTest
    static void shouldExposeUnarchiveSetResultShape() {
        // Validates the DTO contract the LWC relies on, independent of any Big Object DML.
        UnarchiveEngine.UnarchiveSetResult result =
            new UnarchiveEngine.UnarchiveSetResult(ROOT_BIG_OBJECT, ROOT_SOURCE, 'key-1');
        UnarchiveEngine.ObjectUnarchiveSummary summary =
            new UnarchiveEngine.ObjectUnarchiveSummary(ROOT_SOURCE, 'Archive Source', ROOT_BIG_OBJECT, true);
        summary.restoredCount = 2;
        summary.relinked = true;
        result.summaries.add(summary);

        Assert.areEqual(ROOT_SOURCE, result.rootObject, 'Root object should round-trip');
        Assert.areEqual('key-1', result.rootRecordKey, 'Root key should round-trip');
        Assert.isFalse(result.rootRestored, 'rootRestored should default to false');
        Assert.areEqual(0, result.totalRestored, 'totalRestored should default to 0');
        Assert.areEqual(1, result.summaries.size(), 'Summary should be retained');
        Assert.isTrue(result.summaries[0].isRoot, 'First summary should be the root');
        Assert.isTrue(result.summaries[0].relinked, 'relinked flag should round-trip');
    }
}
