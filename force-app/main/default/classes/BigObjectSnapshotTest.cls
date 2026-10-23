/**
 * Tests the full-record snapshot that powers the archive viewer's "View" (the complete record page).
 *
 * These lock in the fix for the viewer showing only one field: the snapshot must capture EVERY
 * readable field of the source record — for any object — not just the subset that maps into the Big
 * Object (which is often only the index field). Runs without any Big Object DML, so it is immune to
 * the insertImmediate test-context ceiling.
 */
@isTest
private class BigObjectSnapshotTest {
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(1, true);
    }

    @isTest
    static void snapshotFieldList_IncludesAllReadableFields_NotJustIndex() {
        Schema.DescribeSObjectResult describe = Archive_Source__c.SObjectType.getDescribe();

        Test.startTest();
        List<String> fields = BigObjectArchiveService.buildSnapshotFieldList(describe);
        Test.stopTest();

        Set<String> lower = new Set<String>();
        for (String f : fields) {
            lower.add(f.toLowerCase());
        }
        Assert.isTrue(fields.size() >= 3,
            'The snapshot field list should cover the whole record, not just the index field. Got: ' + fields);
        Assert.isTrue(lower.contains('amount__c'), 'A non-index field (Amount__c) must be captured.');
        Assert.isTrue(lower.contains('name'), 'The standard Name field must be captured.');
    }

    @isTest
    static void buildRecordSnapshot_SerializesEveryFieldWithValues() {
        Schema.DescribeSObjectResult describe = Archive_Source__c.SObjectType.getDescribe();
        List<String> fieldNames = BigObjectArchiveService.buildSnapshotFieldList(describe);
        // Query the source with the SAME field list the snapshot reads (as the archive flow does).
        String soql = 'SELECT ' + String.join(fieldNames, ', ') + ' FROM Archive_Source__c LIMIT 1';
        SObject source = Database.query(soql);

        Test.startTest();
        String snapshotJson = BigObjectArchiveService.buildRecordSnapshot(describe, source, fieldNames);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(snapshotJson);
        Assert.areEqual('Archive_Source__c', (String) parsed.get('sourceObject'), 'Source object should round-trip.');
        List<Object> fields = (List<Object>) parsed.get('fields');
        Assert.isTrue(fields.size() >= 3,
            'The snapshot JSON should contain the full record, not a single field. Got ' + fields.size());

        // Every entry must carry the metadata the viewer renders.
        Boolean sawName = false;
        for (Object item : fields) {
            Map<String, Object> entry = (Map<String, Object>) item;
            Assert.isNotNull(entry.get('label'), 'Each snapshot field needs a label for the record page.');
            if ('Name'.equalsIgnoreCase((String) entry.get('name'))) {
                sawName = true;
            }
        }
        Assert.isTrue(sawName, 'The Name field should be present in the serialized snapshot.');
    }
}
