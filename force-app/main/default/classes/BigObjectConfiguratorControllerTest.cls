/**
 * Tests for BigObjectConfiguratorController.
 *
 * Describe-driven methods (getObjects/getFields) run against the Archive_Source__c fixture.
 * createBigObject's Metadata API SOAP callout is mocked with WebServiceMock (no real callout
 * or Named Credential needed). validateRequest is exercised directly (@TestVisible).
 */
@isTest
private class BigObjectConfiguratorControllerTest {

    // ---- WebServiceMock for the apex-mdapi createMetadata SOAP calls -------
    private class MetadataCreateMock implements WebServiceMock {
        private Boolean succeed;
        MetadataCreateMock(Boolean succeed) {
            this.succeed = succeed;
        }
        public void doInvoke(
            Object stub, Object request, Map<String, Object> response, String endpoint,
            String soapAction, String requestName, String responseNS, String responseName,
            String responseType
        ) {
            if (request instanceof MetadataService.deploy_element) {
                MetadataService.AsyncResult ar = new MetadataService.AsyncResult();
                ar.id = 'DEPLOYJOB0001';
                ar.done = false;
                ar.state = 'Queued';
                MetadataService.deployResponse_element resp =
                    new MetadataService.deployResponse_element();
                resp.result = ar;
                response.put('response_x', resp);
            } else if (request instanceof MetadataService.checkDeployStatus_element) {
                MetadataService.DeployResult dr = new MetadataService.DeployResult();
                dr.done = true;
                dr.status = this.succeed ? 'Succeeded' : 'Failed';
                if (!this.succeed) {
                    MetadataService.DeployMessage dm = new MetadataService.DeployMessage();
                    dm.fullName = 'Test_Archive__b';
                    dm.problem = 'Simulated deploy failure';
                    MetadataService.DeployDetails details = new MetadataService.DeployDetails();
                    details.componentFailures = new List<MetadataService.DeployMessage>{ dm };
                    dr.details = details;
                }
                MetadataService.checkDeployStatusResponse_element resp =
                    new MetadataService.checkDeployStatusResponse_element();
                resp.result = dr;
                response.put('response_x', resp);
            } else {
                MetadataService.SaveResult sr = new MetadataService.SaveResult();
                sr.success = this.succeed;
                sr.fullName = 'MockComponent';
                MetadataService.createMetadataResponse_element resp =
                    new MetadataService.createMetadataResponse_element();
                resp.result = new List<MetadataService.SaveResult>{ sr };
                response.put('response_x', resp);
            }
        }
    }

    // ---- Request builders --------------------------------------------------
    private static BigObjectConfiguratorController.FieldSelection field(
        String apiName, String type, Boolean required, Integer length
    ) {
        BigObjectConfiguratorController.FieldSelection f =
            new BigObjectConfiguratorController.FieldSelection();
        f.apiName = apiName;
        f.label = apiName.removeEnd('__c');
        f.type = type;
        f.required = required;
        f.length = length;
        return f;
    }

    private static BigObjectConfiguratorController.IndexFieldSelection idx(String apiName) {
        BigObjectConfiguratorController.IndexFieldSelection i =
            new BigObjectConfiguratorController.IndexFieldSelection();
        i.apiName = apiName;
        i.sortDirection = 'ASC';
        return i;
    }

    private static BigObjectConfiguratorController.BigObjectRequest validRequest() {
        BigObjectConfiguratorController.BigObjectRequest req =
            new BigObjectConfiguratorController.BigObjectRequest();
        req.apiName = 'Test_Archive__b';
        req.label = 'Test Archive';
        req.pluralLabel = 'Test Archives';
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'Text', true, 50)
        };
        req.indexFields = new List<BigObjectConfiguratorController.IndexFieldSelection>{
            idx('Key__c')
        };
        return req;
    }

    // ---- getObjects --------------------------------------------------------

    @isTest
    static void shouldReturnObjectOptions_WhenCalled() {
        Test.startTest();
        List<BigObjectConfiguratorController.ObjectOption> options =
            BigObjectConfiguratorController.getObjects();
        Test.stopTest();

        Assert.isFalse(options.isEmpty(), 'The org should expose queryable objects');
        Assert.isNotNull(options[0].apiName, 'Each option should carry an API name');
        Assert.isNotNull(options[0].label, 'Each option should carry a label');
    }

    // ---- getFields ---------------------------------------------------------

    @isTest
    static void shouldMapFieldTypes_WhenFieldsDescribed() {
        Test.startTest();
        List<BigObjectConfiguratorController.FieldInfo> fields =
            BigObjectConfiguratorController.getFields('Archive_Source__c');
        Test.stopTest();

        Map<String, BigObjectConfiguratorController.FieldInfo> byApi =
            new Map<String, BigObjectConfiguratorController.FieldInfo>();
        for (BigObjectConfiguratorController.FieldInfo info : fields) {
            byApi.put(info.apiName, info);
        }
        Assert.areEqual('Text', byApi.get('Record_Key__c').type,
            'Text field should map to the Big Object Text type');
        Assert.isTrue(byApi.get('Record_Key__c').isSupported,
            'Text should be a supported Big Object type');
        Assert.areEqual('Lookup', byApi.get('Archived_By__c').type,
            'Lookup field should map to the Big Object Lookup type');
        Assert.areEqual('User', byApi.get('Archived_By__c').referenceTo,
            'Lookup should capture its referenceTo target');
        // Checkbox has no native Big Object type, so it is coerced to Text (stored, then
        // converted back on unarchive) — it is archivable, not skipped.
        Assert.isTrue(byApi.get('Is_Archived__c').isSupported,
            'Checkbox should be archivable via text coercion');
        Assert.isTrue(byApi.get('Is_Archived__c').isCoerced,
            'Checkbox should be flagged as coerced');
        Assert.areEqual('Text', byApi.get('Is_Archived__c').type,
            'Coerced Checkbox should be stored as Text');
    }

    @isTest
    static void shouldThrowAuraHandled_WhenGetFieldsObjectBlank() {
        Test.startTest();
        try {
            BigObjectConfiguratorController.getFields('');
            Assert.fail('Expected AuraHandledException for a blank object API name');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank object name should be rejected');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowAuraHandled_WhenGetFieldsObjectUnknown() {
        Test.startTest();
        try {
            BigObjectConfiguratorController.getFields('No_Such_Object__x');
            Assert.fail('Expected AuraHandledException for an unknown object');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'An unknown object should be rejected');
        }
        Test.stopTest();
    }

    // ---- validateRequest (one rule per method) -----------------------------

    @isTest
    static void shouldPassValidation_WhenRequestValid() {
        Test.startTest();
        BigObjectConfiguratorController.validateRequest(validRequest());
        Test.stopTest();
        Assert.isTrue(true, 'A valid request should not throw');
    }

    @isTest
    static void shouldFailValidation_WhenRequestNull() {
        assertValidationError(null, 'No request');
    }

    @isTest
    static void shouldFailValidation_WhenApiNameNotBigObject() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.apiName = 'Test_Archive__c';
        assertValidationError(req, '__b');
    }

    @isTest
    static void shouldFailValidation_WhenLabelBlank() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.label = '';
        assertValidationError(req, 'label is required');
    }

    @isTest
    static void shouldFailValidation_WhenNoFields() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = null;
        assertValidationError(req, 'at least one field');
    }

    @isTest
    static void shouldFailValidation_WhenNoIndexFields() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.indexFields = null;
        assertValidationError(req, 'at least one index field');
    }

    @isTest
    static void shouldFailValidation_WhenTooManyIndexFields() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.indexFields = new List<BigObjectConfiguratorController.IndexFieldSelection>();
        for (Integer i = 0; i < 6; i++) {
            req.indexFields.add(idx('Key__c'));
        }
        assertValidationError(req, 'at most');
    }

    @isTest
    static void shouldFailValidation_WhenUnsupportedFieldType() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'Blob', true, null)
        };
        assertValidationError(req, 'unsupported type');
    }

    @isTest
    static void shouldFailValidation_WhenIndexFieldNotSelected() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.indexFields = new List<BigObjectConfiguratorController.IndexFieldSelection>{
            idx('Other__c')
        };
        assertValidationError(req, 'not in the selected fields');
    }

    @isTest
    static void shouldFailValidation_WhenIndexFieldNotRequired() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'Text', false, 50)
        };
        assertValidationError(req, 'must be marked required');
    }

    @isTest
    static void shouldFailValidation_WhenTextIndexTooLong() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'Text', true, 150)
        };
        assertValidationError(req, 'exceeds the maximum');
    }

    @isTest
    static void shouldFailValidation_WhenIndexFieldLongTextArea() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'LongTextArea', true, 500)
        };
        assertValidationError(req, 'cannot be part of a Big Object index');
    }

    @isTest
    static void shouldFailValidation_WhenIndexFieldUrl() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Key__c', 'Url', true, null)
        };
        assertValidationError(req, 'cannot be part of a Big Object index');
    }

    @isTest
    static void shouldFailValidation_WhenEmailPhoneIndexTooLong() {
        // Email (80) + Email (80) = 160, over the 100-char index limit even with no Text fields.
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{
            field('Email1__c', 'Email', true, null),
            field('Email2__c', 'Email', true, null)
        };
        req.indexFields = new List<BigObjectConfiguratorController.IndexFieldSelection>{
            idx('Email1__c'), idx('Email2__c')
        };
        assertValidationError(req, 'exceeds the maximum');
    }

    @isTest
    static void shouldFailValidation_WhenDuplicateBigObjectFieldApiName() {
        // Two source fields resolve to the same Big Object field API name (custom override collision).
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        BigObjectConfiguratorController.FieldSelection a = field('Key__c', 'Text', true, 50);
        BigObjectConfiguratorController.FieldSelection b = field('Other__c', 'Text', false, 50);
        b.bigObjectApiName = 'Key__c';
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{ a, b };
        assertValidationError(req, 'Duplicate Big Object field API name');
    }

    @isTest
    static void shouldNormalizeBigObjectFieldApiName_WhenMissingSuffix() {
        // A custom Big Object field name without a __c suffix is normalized, not rejected.
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        BigObjectConfiguratorController.FieldSelection f = field('Key__c', 'Text', true, 50);
        f.bigObjectApiName = 'CustomKey';
        req.fields = new List<BigObjectConfiguratorController.FieldSelection>{ f };
        req.indexFields = new List<BigObjectConfiguratorController.IndexFieldSelection>{ idx('Key__c') };

        Test.startTest();
        BigObjectConfiguratorController.validateRequest(req);
        Test.stopTest();

        Assert.areEqual('CustomKey__c', req.fields[0].bigObjectApiName,
            'A custom Big Object field name without __c should be normalized to end with __c');
    }

    private static void assertValidationError(
        BigObjectConfiguratorController.BigObjectRequest req, String expectedFragment
    ) {
        try {
            BigObjectConfiguratorController.validateRequest(req);
            Assert.fail('Expected BigObjectConfiguratorException containing: ' + expectedFragment);
        } catch (BigObjectConfiguratorController.BigObjectConfiguratorException e) {
            Assert.isTrue(e.getMessage().containsIgnoreCase(expectedFragment),
                'Message should contain "' + expectedFragment + '", got: ' + e.getMessage());
        }
    }

    // ---- createBigObject (Metadata API mocked) -----------------------------

    @isTest
    static void shouldStartDeployAndReportSuccess() {
        Test.setMock(WebServiceMock.class, new MetadataCreateMock(true));

        Test.startTest();
        String jobId = BigObjectConfiguratorController.createBigObject(JSON.serialize(validRequest()));
        BigObjectDeployService.DeployStatus status =
            BigObjectConfiguratorController.checkCreateStatus(jobId);
        Test.stopTest();

        Assert.isNotNull(jobId, 'createBigObject should return a deploy job id');
        Assert.isTrue(status.done, 'Status should report done');
        Assert.isTrue(status.success, 'A succeeded deploy should report success=true');
    }

    @isTest
    static void shouldReportFailure_WhenDeployFails() {
        Test.setMock(WebServiceMock.class, new MetadataCreateMock(false));

        Test.startTest();
        String jobId = BigObjectConfiguratorController.createBigObject(JSON.serialize(validRequest()));
        BigObjectDeployService.DeployStatus status =
            BigObjectConfiguratorController.checkCreateStatus(jobId);
        Test.stopTest();

        Assert.isFalse(status.success, 'A failed deploy should report success=false');
        Assert.isTrue(String.isNotBlank(status.message),
            'A failed deploy should return a failure message');
    }

    @isTest
    static void shouldThrowAuraHandled_WhenCreateRequestInvalid() {
        BigObjectConfiguratorController.BigObjectRequest req = validRequest();
        req.apiName = 'Invalid__c'; // fails validation before any callout

        Test.startTest();
        try {
            BigObjectConfiguratorController.createBigObject(JSON.serialize(req));
            Assert.fail('Expected AuraHandledException for an invalid request');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'Validation failures should surface as AuraHandledException');
        }
        Test.stopTest();
    }
}
