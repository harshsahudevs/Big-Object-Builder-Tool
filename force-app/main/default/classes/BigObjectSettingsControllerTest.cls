/**
 * Tests for BigObjectSettingsController (Object Mappings settings).
 * Describe-driven methods run against the Archive_Source__c fixture; mapping CRUD uses the
 * Big_Object_Field_Mapping__c object (FLS granted via Big_Object_Archive_Access).
 */
@isTest
private class BigObjectSettingsControllerTest {

    /** Mocks the Tooling API /query response used by getBigObjectFields. */
    private class ToolingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"size":2,"totalSize":2,"done":true,"records":['
                + '{"attributes":{"type":"CustomField"},"DeveloperName":"Amount"},'
                + '{"attributes":{"type":"CustomField"},"DeveloperName":"Record_Key"}]}');
            return res;
        }
    }

    private static String mappingJson(String bigField, String sourceField) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'bigObjectField' => bigField, 'sourceField' => sourceField }
        };
        return JSON.serialize(rows);
    }

    @isTest
    static void shouldListBigObjects_WhenCalled() {
        Test.startTest();
        List<BigObjectSettingsController.SelectableItem> items = BigObjectSettingsController.getBigObjects();
        Test.stopTest();
        Assert.isNotNull(items, 'A list should be returned');
        for (BigObjectSettingsController.SelectableItem item : items) {
            Assert.isTrue(item.apiName.endsWith('__b'), 'Only Big Objects should be listed: ' + item.apiName);
        }
    }

    @isTest
    static void shouldReturnFields_WhenObjectValid() {
        Test.startTest();
        List<BigObjectSettingsController.SelectableItem> fields =
            BigObjectSettingsController.getObjectFields('Archive_Source__c');
        Test.stopTest();
        Assert.isFalse(fields.isEmpty(), 'Archive_Source__c should expose accessible fields');
    }

    @isTest
    static void shouldReturnMappingOverview_WithStatus() {
        Test.setMock(HttpCalloutMock.class, new ToolingMock());
        Test.startTest();
        List<BigObjectSettingsController.MappingOverview> overview =
            BigObjectSettingsController.getMappingOverview();
        Test.stopTest();

        Assert.isFalse(overview.isEmpty(), 'Overview should list the org Big Objects');
        Boolean foundFixture = false;
        for (BigObjectSettingsController.MappingOverview o : overview) {
            Assert.isTrue(
                o.status == 'Mapped' || o.status == 'Partial' || o.status == 'Unmapped',
                'Status must be Mapped/Partial/Unmapped: ' + o.status
            );
            if (o.apiName == 'Archive_Record__b') {
                foundFixture = true;
                Assert.areEqual(0, o.mappedFields, 'No mappings seeded, so mappedFields should be 0');
                Assert.areEqual('Unmapped', o.status, 'A Big Object with no mappings should be Unmapped');
            }
        }
        Assert.isTrue(foundFixture, 'The Archive_Record__b fixture should appear in the overview');
    }

    @isTest
    static void shouldReturnAllBigObjectFields_ViaTooling() {
        Test.setMock(HttpCalloutMock.class, new ToolingMock());
        Test.startTest();
        List<BigObjectSettingsController.SelectableItem> fields =
            BigObjectSettingsController.getBigObjectFields('Archive_Record__b');
        Test.stopTest();
        Assert.isFalse(fields.isEmpty(), 'Tooling-based field list should not be empty');
        Set<String> names = new Set<String>();
        for (BigObjectSettingsController.SelectableItem f : fields) {
            names.add(f.apiName);
        }
        Assert.isTrue(
            names.contains('Amount__c'),
            'Non-index field Amount__c should be listed from the Tooling response: ' + names
        );
    }

    @isTest
    static void shouldThrow_WhenBigObjectFieldsBlank() {
        Test.startTest();
        try {
            BigObjectSettingsController.getBigObjectFields('');
            Assert.fail('Expected AuraHandledException for a blank Big Object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Blank Big Object should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenFieldsObjectBlank() {
        Test.startTest();
        try {
            BigObjectSettingsController.getObjectFields('');
            Assert.fail('Expected AuraHandledException for a blank object name');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Blank object name should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldSaveAndReturnMappings_WhenValid() {
        Test.startTest();
        BigObjectSettingsController.saveMappings(
            'Archive_Record__b', 'Archive_Source__c', mappingJson('Amount__c', 'Amount__c'));
        Test.stopTest();

        List<Big_Object_Field_Mapping__c> saved = BigObjectSettingsController.getMappings('Archive_Record__b');
        Assert.areEqual(1, saved.size(), 'Exactly one mapping should be stored');
        Assert.areEqual('Amount__c', saved[0].Big_Object_Field__c, 'Big Object field should persist');
        Assert.areEqual('Amount__c', saved[0].Source_Field__c, 'Source field should persist');
        Assert.areEqual('Archive_Source__c', saved[0].Source_Object__c, 'Source object should persist');
    }

    @isTest
    static void shouldReplaceAndSkipBlank_WhenResaved() {
        BigObjectSettingsController.saveMappings(
            'Archive_Record__b', 'Archive_Source__c', mappingJson('Amount__c', 'Amount__c'));

        Test.startTest();
        // Re-save with a blank source → that mapping is removed (and old rows replaced).
        BigObjectSettingsController.saveMappings(
            'Archive_Record__b', 'Archive_Source__c', mappingJson('Amount__c', ''));
        Test.stopTest();

        List<Big_Object_Field_Mapping__c> saved = BigObjectSettingsController.getMappings('Archive_Record__b');
        Assert.areEqual(0, saved.size(), 'A blank source field should leave no stored mapping');
    }

    @isTest
    static void shouldThrow_WhenSaveBigObjectBlank() {
        Test.startTest();
        try {
            BigObjectSettingsController.saveMappings('', 'Archive_Source__c', '[]');
            Assert.fail('Expected AuraHandledException for a blank Big Object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Blank Big Object should be rejected');
        }
        Test.stopTest();
    }
}
