/**
 * Tests for BigObjectArchiveService.
 *
 * Exercises the full engine against a deployed test fixture:
 *   Archive_Source__c (normal object)  ->  Archive_Record__b (Big Object)
 * The two share field API names (Record_Key__c, Amount__c) so buildFieldMap resolves,
 * and Record_Key__c is the Big Object's required index/primary key. Archive_Source__c
 * also carries Is_Archived__c / Archived_Date__c / Archived_By__c / Big_Object_Record_Key__c
 * so the describe-guarded source-stamping branch runs.
 *
 * Coverage split:
 *   - Deterministic everywhere: validation, unknown-object, preview, restore not-found,
 *     archive return values, source stamping, archive logs, DTO defaults.
 *   - Big-Object-read dependent (restore round-trip + cleanup): relies on insertImmediate
 *     rows being queryable within the same test transaction. Verify in a scratch/sandbox org.
 *
 * No connected org was available when authoring, so happy-path assertions are unrun —
 * run `sf apex run test --class-names BigObjectArchiveServiceTest --code-coverage`.
 */
@isTest
private class BigObjectArchiveServiceTest {

    private static final String BIG_OBJECT = 'Archive_Record__b';
    private static final String SOURCE_OBJECT = 'Archive_Source__c';
    private static final String GHOST_BIG_OBJECT = 'Ghost_Archive__b';

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(5, true);
    }

    private static Id getSourceId() {
        return [SELECT Id FROM Archive_Source__c LIMIT 1].Id;
    }

    // =====================================================================
    // Happy path — archive
    // =====================================================================

    @isTest
    static void shouldArchiveAndStampSource_WhenSingleValidRecord() {
        // Given
        Archive_Source__c src = [SELECT Id FROM Archive_Source__c LIMIT 1];

        // When
        Test.startTest();
        BigObjectArchiveService.ArchiveResult result =
            BigObjectArchiveService.archiveRecord(src.Id, BIG_OBJECT);
        Test.stopTest();

        // Then — outcome
        Assert.isTrue(result.isSuccess, 'Archive should succeed: ' + result.errorMessage);
        Assert.isNotNull(result.bigObjectRecordKey, 'Record key should be populated on success');

        // Then — source stamped (describe-guarded tracking fields)
        Archive_Source__c stamped = [
            SELECT Is_Archived__c, Archived_By__c, Archived_Date__c, Big_Object_Record_Key__c
            FROM Archive_Source__c WHERE Id = :src.Id
        ];
        Assert.isTrue(stamped.Is_Archived__c, 'Source should be flagged archived');
        Assert.areEqual(UserInfo.getUserId(), stamped.Archived_By__c,
            'Archived By should be stamped with the current user');
        Assert.isNotNull(stamped.Archived_Date__c, 'Archived Date should be stamped');
        Assert.areEqual(result.bigObjectRecordKey, stamped.Big_Object_Record_Key__c,
            'Stamped record key should match the archive result key');

        // Then — log written
        Integer successLogs = [
            SELECT COUNT() FROM Big_Object_Archive_Log__c
            WHERE Status__c = 'Success' AND Target_Big_Object__c = :BIG_OBJECT
        ];
        Assert.areEqual(1, successLogs, 'Exactly one success log should be written');
    }

    @isTest
    static void shouldArchiveThenDeleteSource_WhenArchiveAndDelete() {
        // Given
        Archive_Source__c src = [SELECT Id, Record_Key__c FROM Archive_Source__c LIMIT 1];

        // When
        Test.startTest();
        BigObjectArchiveService.ArchiveResult result =
            BigObjectArchiveService.archiveAndDeleteRecord(src.Id, BIG_OBJECT);
        Test.stopTest();

        // Then — archived and source deleted
        Assert.isTrue(result.isSuccess, 'Archive should succeed: ' + result.errorMessage);
        Assert.isTrue(result.sourceDeleted, 'Source record should be deleted after a successful archive');
        Assert.areEqual(0, [SELECT COUNT() FROM Archive_Source__c WHERE Id = :src.Id],
            'The source record should no longer exist');
    }

    @isTest
    static void shouldNotDelete_WhenArchiveAndDeleteFails() {
        // Given — a source with no Record_Key__c; the Big Object index field is required
        Archive_Source__c bad = new Archive_Source__c(Name = 'No Key', Amount__c = 5);
        insert bad;

        // When
        Test.startTest();
        BigObjectArchiveService.ArchiveResult result =
            BigObjectArchiveService.archiveAndDeleteRecord(bad.Id, BIG_OBJECT);
        Test.stopTest();

        // Then — archive failed, so the source must survive
        Assert.isFalse(result.isSuccess, 'Archive should fail when the required index key is blank');
        Assert.isFalse(result.sourceDeleted, 'Source must not be deleted when the archive fails');
        Assert.areEqual(1, [SELECT COUNT() FROM Archive_Source__c WHERE Id = :bad.Id],
            'The source record should still exist after a failed archive');
    }

    @isTest
    static void shouldArchiveAll_WhenBulk() {
        // Given — 251 crosses the 200-record boundary
        List<Archive_Source__c> sources = TestDataFactory.createArchiveSources(251, true);
        Set<Id> ids = new Map<Id, Archive_Source__c>(sources).keySet();

        // When
        Test.startTest();
        List<BigObjectArchiveService.ArchiveResult> results =
            BigObjectArchiveService.archiveRecords(ids, SOURCE_OBJECT, BIG_OBJECT);
        Test.stopTest();

        // Then
        Assert.areEqual(251, results.size(), 'Every source record should return a result');
        Integer successes = 0;
        for (BigObjectArchiveService.ArchiveResult r : results) {
            if (r.isSuccess) {
                successes++;
            }
        }
        Assert.areEqual(251, successes, 'All 251 archives should succeed');

        Integer successLogs = [
            SELECT COUNT() FROM Big_Object_Archive_Log__c WHERE Status__c = 'Success'
        ];
        Assert.areEqual(251, successLogs, 'One success log should be written per record');
    }

    @isTest
    static void shouldFailAndLog_WhenRequiredIndexKeyMissing() {
        // Given — a source with no Record_Key__c; the Big Object index field is required
        Archive_Source__c bad = new Archive_Source__c(Name = 'No Key', Amount__c = 5);
        insert bad;

        // When
        Test.startTest();
        BigObjectArchiveService.ArchiveResult result =
            BigObjectArchiveService.archiveRecord(bad.Id, BIG_OBJECT);
        Test.stopTest();

        // Then
        Assert.isFalse(result.isSuccess,
            'Archive should fail when the required index key is blank');
        Assert.isNotNull(result.errorMessage, 'A failure message should be captured');

        Integer failedLogs = [
            SELECT COUNT() FROM Big_Object_Archive_Log__c WHERE Status__c = 'Failed'
        ];
        Assert.areEqual(1, failedLogs, 'A failed attempt should be logged');

        Archive_Source__c notStamped = [
            SELECT Is_Archived__c FROM Archive_Source__c WHERE Id = :bad.Id
        ];
        Assert.isFalse(notStamped.Is_Archived__c,
            'A failed archive must not stamp the source record');
    }

    // =====================================================================
    // Archive preview — queries the SOURCE (no Big Object read)
    // =====================================================================

    @isTest
    static void shouldReturnMappedLines_WhenPreviewValidRecord() {
        // Given
        Id sourceId = getSourceId();

        // When
        Test.startTest();
        List<BigObjectArchiveService.FieldValuePreview> lines =
            BigObjectArchiveService.getArchivePreview(sourceId, BIG_OBJECT);
        Test.stopTest();

        // Then — the two shared fields map
        Assert.areEqual(2, lines.size(),
            'Preview should list the two mapped fields (Record Key, Amount)');
        Set<String> bigFields = new Set<String>();
        for (BigObjectArchiveService.FieldValuePreview line : lines) {
            bigFields.add(line.bigObjectField);
        }
        Assert.isTrue(bigFields.contains('Record_Key__c'),
            'Preview should include the Record Key mapping');
        Assert.isTrue(bigFields.contains('Amount__c'),
            'Preview should include the Amount mapping');
    }

    // =====================================================================
    // Restore — round-trip (depends on Big Object read-after-insert in test)
    // =====================================================================

    @isTest
    static void shouldRestoreRecord_WhenArchivedRowExists() {
        // Given — archive outside start/stop so the Big Object write settles first
        Archive_Source__c src = [SELECT Id, Record_Key__c FROM Archive_Source__c LIMIT 1];
        BigObjectArchiveService.ArchiveResult archived =
            BigObjectArchiveService.archiveRecord(src.Id, BIG_OBJECT);

        // When
        Test.startTest();
        BigObjectArchiveService.RestoreResult result = BigObjectArchiveService.restoreRecord(
            BIG_OBJECT, SOURCE_OBJECT, archived.bigObjectRecordKey, false);
        Test.stopTest();

        // Then
        Assert.isTrue(result.isSuccess, 'Restore should succeed: ' + result.errorMessage);
        Assert.isNotNull(result.restoredRecordId, 'A new source record should be created');
        Assert.isFalse(result.deletedFromBigObject,
            'Big Object row should remain when deleteFromBigObject is false');

        Archive_Source__c restored = [
            SELECT Record_Key__c FROM Archive_Source__c WHERE Id = :result.restoredRecordId
        ];
        Assert.areEqual(src.Record_Key__c, restored.Record_Key__c,
            'Restored record should carry the archived Record Key');
    }

    @isTest
    static void shouldDeleteBigObjectRow_WhenRestoreWithCleanup() {
        // Given
        Archive_Source__c src = [SELECT Id FROM Archive_Source__c LIMIT 1];
        BigObjectArchiveService.ArchiveResult archived =
            BigObjectArchiveService.archiveRecord(src.Id, BIG_OBJECT);

        // When — deleteFromBigObject = true
        Test.startTest();
        BigObjectArchiveService.RestoreResult result = BigObjectArchiveService.restoreRecord(
            BIG_OBJECT, SOURCE_OBJECT, archived.bigObjectRecordKey, true);
        Test.stopTest();

        // Then
        Assert.isTrue(result.isSuccess, 'Restore should succeed: ' + result.errorMessage);
        Assert.isTrue(result.deletedFromBigObject,
            'Big Object row should be deleted after a successful restore cleanup');
    }

    @isTest
    static void shouldReportNotFound_WhenRestoreKeyMissing() {
        // When — no archived row exists for this key (empty Big Object query, deterministic)
        Test.startTest();
        BigObjectArchiveService.RestoreResult result = BigObjectArchiveService.restoreRecord(
            BIG_OBJECT, SOURCE_OBJECT, 'NO-SUCH-KEY', false);
        Test.stopTest();

        // Then
        Assert.isFalse(result.isSuccess, 'A missing key should not restore');
        Assert.isTrue(result.errorMessage != null && result.errorMessage.contains('not found'),
            'Error should indicate the key was not found, got: ' + result.errorMessage);
    }

    // =====================================================================
    // archiveRecord — validation
    // =====================================================================

    @isTest
    static void shouldThrowAuraHandled_WhenArchiveRecordIdIsNull() {
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecord(null, BIG_OBJECT);
            Assert.fail('Expected AuraHandledException when recordId is null');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should be thrown for a null record Id');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowValidation_WhenArchiveRecordTargetNotBigObject() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecord(sourceId, SOURCE_OBJECT); // not __b
            Assert.fail('Expected BigObjectArchiveException for a non-Big-Object target');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('__b'),
                'Message should explain the target must end in __b, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // =====================================================================
    // archiveRecords — validation boundary (one behavior per method)
    // =====================================================================

    @isTest
    static void shouldThrowValidation_WhenRecordIdsNull() {
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(null, SOURCE_OBJECT, BIG_OBJECT);
            Assert.fail('Expected BigObjectArchiveException when recordIds is null');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('No records'),
                'Message should indicate no records were supplied, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowValidation_WhenRecordIdsEmpty() {
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(new Set<Id>(), SOURCE_OBJECT, BIG_OBJECT);
            Assert.fail('Expected BigObjectArchiveException when recordIds is empty');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('No records'),
                'Message should indicate no records were supplied, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowValidation_WhenSourceObjectBlank() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(new Set<Id>{ sourceId }, '', BIG_OBJECT);
            Assert.fail('Expected BigObjectArchiveException when source object is blank');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('required'),
                'Message should indicate object names are required, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowValidation_WhenTargetObjectBlank() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(new Set<Id>{ sourceId }, SOURCE_OBJECT, '');
            Assert.fail('Expected BigObjectArchiveException when target object is blank');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('required'),
                'Message should indicate object names are required, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowValidation_WhenTargetNotBigObject() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(
                new Set<Id>{ sourceId }, SOURCE_OBJECT, 'Archive_Record__c'); // __c, not __b
            Assert.fail('Expected BigObjectArchiveException for a non-Big-Object target');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('__b'),
                'Message should explain the target must end in __b, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowUnknownObject_WhenBigObjectDoesNotExist() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.archiveRecords(
                new Set<Id>{ sourceId }, SOURCE_OBJECT, GHOST_BIG_OBJECT);
            Assert.fail('Expected BigObjectArchiveException for an unknown Big Object');
        } catch (BigObjectArchiveService.BigObjectArchiveException e) {
            Assert.isTrue(e.getMessage().contains('Unknown object'),
                'Message should indicate the Big Object is unknown, got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // =====================================================================
    // getArchivePreview — error wrapping
    // =====================================================================

    @isTest
    static void shouldThrowAuraHandled_WhenPreviewRecordIdNull() {
        Test.startTest();
        try {
            BigObjectArchiveService.getArchivePreview(null, BIG_OBJECT);
            Assert.fail('Expected AuraHandledException when preview recordId is null');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap a null record Id');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenPreviewTargetBlank() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.getArchivePreview(sourceId, '');
            Assert.fail('Expected AuraHandledException when preview target is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap a blank target');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenPreviewBigObjectUnknown() {
        Id sourceId = getSourceId();
        Test.startTest();
        try {
            BigObjectArchiveService.getArchivePreview(sourceId, GHOST_BIG_OBJECT);
            Assert.fail('Expected AuraHandledException for an unknown Big Object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap the unknown-object error');
        }
        Test.stopTest();
    }

    // =====================================================================
    // restoreRecords — validation / error wrapping
    // =====================================================================

    @isTest
    static void shouldThrowAuraHandled_WhenRestoreBigObjectBlank() {
        Test.startTest();
        try {
            BigObjectArchiveService.restoreRecords(
                '', SOURCE_OBJECT, new List<String>{ 'key1' }, false);
            Assert.fail('Expected AuraHandledException when Big Object name is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap a blank Big Object name');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenRestoreSourceObjectBlank() {
        Test.startTest();
        try {
            BigObjectArchiveService.restoreRecords(
                BIG_OBJECT, '', new List<String>{ 'key1' }, false);
            Assert.fail('Expected AuraHandledException when source object is blank');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap a blank source object');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenRestoreKeysNull() {
        Test.startTest();
        try {
            BigObjectArchiveService.restoreRecords(BIG_OBJECT, SOURCE_OBJECT, null, false);
            Assert.fail('Expected AuraHandledException when record keys are null');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap null record keys');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenRestoreKeysEmpty() {
        Test.startTest();
        try {
            BigObjectArchiveService.restoreRecords(
                BIG_OBJECT, SOURCE_OBJECT, new List<String>(), false);
            Assert.fail('Expected AuraHandledException when record keys are empty');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'AuraHandledException should wrap empty record keys');
        }
        Test.stopTest();
    }

    // =====================================================================
    // DTO contracts
    // =====================================================================

    @isTest
    static void shouldDefaultToFailure_WhenArchiveResultConstructed() {
        Id sourceId = getSourceId();
        BigObjectArchiveService.ArchiveResult result =
            new BigObjectArchiveService.ArchiveResult(sourceId);
        Assert.areEqual(sourceId, result.sourceRecordId,
            'ArchiveResult should retain the source record Id');
        Assert.isFalse(result.isSuccess, 'ArchiveResult should default isSuccess to false');
    }

    @isTest
    static void shouldDefaultToFailure_WhenRestoreResultConstructed() {
        BigObjectArchiveService.RestoreResult result =
            new BigObjectArchiveService.RestoreResult('key-123');
        Assert.areEqual('key-123', result.recordKey,
            'RestoreResult should retain the record key');
        Assert.isFalse(result.isSuccess, 'RestoreResult should default isSuccess to false');
        Assert.isFalse(result.deletedFromBigObject,
            'RestoreResult should default deletedFromBigObject to false');
    }
}
