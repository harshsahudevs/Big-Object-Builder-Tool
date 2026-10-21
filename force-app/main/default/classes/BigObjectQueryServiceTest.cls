/**
 * Tests for BigObjectQueryService, driven by the Archive_Record__b fixture
 * (index field Record_Key__c). Validation and empty-page paths are deterministic;
 * row-bearing assertions are invariant-only so they never flake on Big Object
 * read-after-insert timing.
 */
@isTest
private class BigObjectQueryServiceTest {

    private static final String BIG_OBJECT = 'Archive_Record__b';
    private static final String SOURCE_OBJECT = 'Archive_Source__c';
    private static final String INDEX_FIELD = 'Record_Key__c';

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(3, true);
    }

    private static BigObjectQueryService.QueryRequest baseRequest() {
        BigObjectQueryService.QueryRequest req = new BigObjectQueryService.QueryRequest();
        req.bigObjectApiName = BIG_OBJECT;
        return req;
    }

    private static BigObjectQueryService.Filter filter(String field, String op, String value) {
        BigObjectQueryService.Filter f = new BigObjectQueryService.Filter();
        f.field = field;
        f.operator = op;
        f.value = value;
        return f;
    }

    // ---- getIndexFields ----------------------------------------------------

    @isTest
    static void shouldReturnIndexColumn_WhenBigObject() {
        Test.startTest();
        List<BigObjectQueryService.Column> columns =
            BigObjectQueryService.getIndexFields(BIG_OBJECT);
        Test.stopTest();

        Assert.areEqual(1, columns.size(), 'Archive_Record__b has one index field');
        Assert.areEqual(INDEX_FIELD, columns[0].fieldName, 'Index field should be Record Key');
        Assert.isTrue(columns[0].isIndexField, 'Column should be flagged as an index field');
    }

    @isTest
    static void shouldThrowAuraHandled_WhenIndexFieldsObjectUnknown() {
        Test.startTest();
        try {
            BigObjectQueryService.getIndexFields('Ghost_Archive__b');
            Assert.fail('Expected AuraHandledException for an unknown Big Object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Unknown Big Object should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenIndexFieldsNotBigObject() {
        Test.startTest();
        try {
            BigObjectQueryService.getIndexFields('Account'); // exists, but not __b
            Assert.fail('Expected AuraHandledException for a non-Big-Object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A non-Big-Object should be rejected');
        }
        Test.stopTest();
    }

    // ---- getArchivedRecords: validation ------------------------------------

    @isTest
    static void shouldThrowAuraHandled_WhenRequestNull() {
        Test.startTest();
        try {
            BigObjectQueryService.getArchivedRecords(null);
            Assert.fail('Expected AuraHandledException for a null request');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A null request should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenApiNameBlank() {
        BigObjectQueryService.QueryRequest req = baseRequest();
        req.bigObjectApiName = '';
        Test.startTest();
        try {
            BigObjectQueryService.getArchivedRecords(req);
            Assert.fail('Expected AuraHandledException for a blank Big Object API name');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank API name should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenFilterOperatorInvalid() {
        BigObjectQueryService.QueryRequest req = baseRequest();
        req.filters = new List<BigObjectQueryService.Filter>{ filter(INDEX_FIELD, 'LIKE', 'x') };
        Test.startTest();
        try {
            BigObjectQueryService.getArchivedRecords(req);
            Assert.fail('Expected AuraHandledException for an invalid operator');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'An invalid filter operator should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenFilterBreaksIndexOrder() {
        BigObjectQueryService.QueryRequest req = baseRequest();
        req.filters = new List<BigObjectQueryService.Filter>{ filter('Amount__c', '=', '5') };
        Test.startTest();
        try {
            BigObjectQueryService.getArchivedRecords(req);
            Assert.fail('Expected AuraHandledException when the filter is not the leading index field');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A filter that breaks index order should be rejected');
        }
        Test.stopTest();
    }

    // ---- getArchivedRecords: query paths -----------------------------------

    @isTest
    static void shouldReturnPage_WhenNoFilters() {
        Test.startTest();
        BigObjectQueryService.QueryResult result =
            BigObjectQueryService.getArchivedRecords(baseRequest());
        Test.stopTest();

        Assert.isNotNull(result, 'A result should always be returned');
        Assert.areEqual(25, result.pageSize, 'Default page size should be 25');
        Assert.isFalse(result.columns.isEmpty(), 'Columns should include the index field');
        Assert.isTrue(result.indexFields.contains(INDEX_FIELD),
            'Index fields should list Record Key');
        Assert.isTrue(result.rows.size() <= result.pageSize,
            'Row count must not exceed the page size');
        Assert.isNotNull(result.queriedAt, 'queriedAt should be stamped for the refresh indicator');
    }

    @isTest
    static void shouldApplyFilterAndDisplayFields_WhenProvided() {
        BigObjectQueryService.QueryRequest req = baseRequest();
        req.filters = new List<BigObjectQueryService.Filter>{ filter(INDEX_FIELD, '=', 'KEY-000000') };
        req.displayFields = new List<String>{ 'Amount__c' };
        req.pageSize = 10;

        Test.startTest();
        BigObjectQueryService.QueryResult result = BigObjectQueryService.getArchivedRecords(req);
        Test.stopTest();

        Assert.isNotNull(result, 'A filtered query should return a result');
        Assert.areEqual(10, result.pageSize, 'Requested page size should be honored');
        Set<String> columnNames = new Set<String>();
        for (BigObjectQueryService.Column col : result.columns) {
            columnNames.add(col.fieldName);
        }
        Assert.isTrue(columnNames.contains(INDEX_FIELD),
            'Index field should always be a column');
        Assert.isTrue(columnNames.contains('Amount__c'),
            'Requested display field should be a column');
    }

    @isTest
    static void shouldApplyCursor_WhenProvided() {
        BigObjectQueryService.QueryRequest req = baseRequest();
        req.sortDirection = 'DESC';
        req.cursor = '{"Record_Key__c":"KEY-000001"}';

        Test.startTest();
        BigObjectQueryService.QueryResult result = BigObjectQueryService.getArchivedRecords(req);
        Test.stopTest();

        Assert.isNotNull(result, 'A cursor-paged query should return a result');
        Assert.isTrue(result.rows.size() <= result.pageSize,
            'Row count must not exceed the page size');
    }

    @isTest
    static void shouldReturnWellFormedPage_WhenRecordsArchived() {
        // Best-effort row coverage: archive the fixture sources, then page them back.
        Set<Id> ids = new Map<Id, Archive_Source__c>(
            [SELECT Id FROM Archive_Source__c]
        ).keySet();
        BigObjectArchiveService.archiveRecords(ids, SOURCE_OBJECT, BIG_OBJECT);

        BigObjectQueryService.QueryRequest req = baseRequest();
        req.pageSize = 1; // force hasMore / cursor building if rows are visible

        Test.startTest();
        BigObjectQueryService.QueryResult result = BigObjectQueryService.getArchivedRecords(req);
        Test.stopTest();

        Assert.isNotNull(result, 'A result should be returned');
        Assert.isTrue(result.rows.size() <= 1, 'Page size of 1 must return at most one row');
        for (BigObjectQueryService.Row row : result.rows) {
            Assert.isNotNull(row.recordKey, 'Every returned row should expose a record key');
        }
    }
}
