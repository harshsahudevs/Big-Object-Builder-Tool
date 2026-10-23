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

    @isTest
    static void applySnapshotToRecord_RebuildsFullRecordWithTypes() {
        // The restore path rebuilds a record from the snapshot (not from non-index Big Object fields).
        Schema.DescribeSObjectResult describe = Archive_Source__c.SObjectType.getDescribe();
        String snapshotJson = '{"sourceObject":"Archive_Source__c","fields":['
            + '{"name":"Name","label":"Name","type":"string","value":"Acme Corp"},'
            + '{"name":"Amount__c","label":"Amount","type":"currency","value":"150.50"},'
            + '{"name":"Is_Archived__c","label":"Archived","type":"boolean","value":"true"}]}';
        SObject record = describe.getSObjectType().newSObject();

        Test.startTest();
        BigObjectArchiveService.applySnapshotToRecord(describe, record, snapshotJson);
        Test.stopTest();

        Assert.areEqual('Acme Corp', (String) record.get('Name'), 'Text field should restore from snapshot.');
        Assert.areEqual(150.50, (Decimal) record.get('Amount__c'),
            'Decimal value must be preserved end-to-end (no truncation to whole number).');
        Assert.areEqual(true, (Boolean) record.get('Is_Archived__c'), 'Boolean should restore from snapshot.');
    }

    @isTest
    static void coerceFromSnapshot_ConvertsByType() {
        Assert.areEqual(true, BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.BOOLEAN, 'true'),
            'Boolean should parse.');
        Assert.areEqual(150.5, (Double) BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.DOUBLE, '150.5'),
            'Decimal should parse.');
        Assert.areEqual(Date.newInstance(2026, 10, 23),
            BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.DATE, '2026-10-23 00:00:00'),
            'Date should parse, tolerating a trailing time.');
        Assert.isNull(BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.DOUBLE, 'not-a-number'),
            'Unparseable numeric should return null, not throw.');
        Assert.isNull(BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.STRING, ''),
            'Blank should return null.');
        Assert.areEqual('abc', BigObjectArchiveService.coerceFromSnapshot(Schema.DisplayType.STRING, 'abc'),
            'Plain text should pass through.');
    }
}
