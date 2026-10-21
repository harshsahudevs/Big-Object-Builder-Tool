/**
 * Tests for BigObjectBrowserController. Covers Big Object listing, input-validation guards, and
 * source-object resolution deterministically. The query/unarchive happy paths delegate to
 * BigObjectQueryService / BigObjectArchiveService (covered by their own suites) and require Big
 * Object field-level security, so they are not re-exercised here.
 */
@isTest
private class BigObjectBrowserControllerTest {
    private static final String FIXTURE_BIG_OBJECT = 'Archive_Record__b';

    @isTest
    static void getBigObjects_ReturnsAccessibleBigObjects() {
        // When
        Test.startTest();
        List<BigObjectBrowserController.BigObjectOption> options =
            BigObjectBrowserController.getBigObjects();
        Test.stopTest();

        // Then
        Assert.isFalse(options.isEmpty(), 'At least the fixture Big Object should be returned.');
        Boolean foundFixture = false;
        for (BigObjectBrowserController.BigObjectOption option : options) {
            Assert.isTrue(
                option.apiName.endsWithIgnoreCase('__b'),
                'Every returned option must be a Big Object: ' + option.apiName
            );
            if (FIXTURE_BIG_OBJECT.equalsIgnoreCase(option.apiName)) {
                foundFixture = true;
            }
        }
        Assert.isTrue(foundFixture, 'The Archive_Record__b fixture should appear in the list.');
    }

    @isTest
    static void getArchiveHistory_NullId_ReturnsEmpty() {
        Test.startTest();
        List<BigObjectBrowserController.HistoryRow> rows =
            BigObjectBrowserController.getArchiveHistory(null);
        Test.stopTest();
        Assert.isTrue(rows.isEmpty(), 'A null record Id should return an empty list.');
    }

    @isTest
    static void getArchiveHistory_ReturnsRows_WhenRecordArchived() {
        Account src = new Account(Name = 'Archive History Test');
        insert src;
        insert new Big_Object_Archive_Log__c(
            Source_Record_Id__c = src.Id,
            Source_Object__c = 'Account',
            Target_Big_Object__c = 'Account_Archive__b',
            Status__c = 'Success',
            Archived_Date__c = System.now()
        );

        Test.startTest();
        List<BigObjectBrowserController.HistoryRow> rows =
            BigObjectBrowserController.getArchiveHistory(src.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The archived record should return one history row.');
        Assert.areEqual('Account_Archive__b', rows[0].targetBigObject, 'Target Big Object should match.');
        Assert.areEqual('Success', rows[0].status, 'Status should match.');
    }

    @isTest
    static void getRecords_BlankApiName_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.getRecords('');
            Assert.fail('Expected an AuraHandledException for a blank API name.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void getRecords_UnknownObject_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.getRecords('Totally_Not_Real__b');
            Assert.fail('Expected an AuraHandledException for an unknown Big Object.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void getRecords_NotABigObject_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.getRecords('Account');
            Assert.fail('Expected an AuraHandledException for a non-Big-Object.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void unarchiveRecords_BlankApiName_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.unarchiveRecords('', new List<String>{ 'KEY-000000' });
            Assert.fail('Expected an AuraHandledException for a blank API name.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void unarchiveRecords_NullKeys_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.unarchiveRecords(FIXTURE_BIG_OBJECT, null);
            Assert.fail('Expected an AuraHandledException for null keys.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void unarchiveRecords_EmptyKeys_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.unarchiveRecords(FIXTURE_BIG_OBJECT, new List<String>());
            Assert.fail('Expected an AuraHandledException for empty keys.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void unarchiveRecords_UnresolvableSource_Throws() {
        // Given a valid Big Object with no archive-log history and a non-conventional name,
        // the source object cannot be resolved.
        Test.startTest();
        try {
            BigObjectBrowserController.unarchiveRecords(
                FIXTURE_BIG_OBJECT, new List<String>{ 'KEY-000000' }
            );
            Assert.fail('Expected an AuraHandledException when the source object cannot be resolved.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void unarchiveAll_BlankApiName_Throws() {
        Test.startTest();
        try {
            BigObjectBrowserController.unarchiveAll('   ');
            Assert.fail('Expected an AuraHandledException for a blank API name.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }
}
