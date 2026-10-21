/**
 * Tests for BigObjectSetupController: setup-status reporting and the live connection test.
 * The Metadata API SOAP callout is intercepted with WebServiceMock so no real credential is needed.
 */
@isTest
private class BigObjectSetupControllerTest {
    /** Returns a describe response with a non-null result (connection OK). */
    private class SuccessMock implements WebServiceMock {
        public void doInvoke(
            Object stub, Object request, Map<String, Object> response, String endpoint,
            String soapAction, String requestName, String responseNS, String responseName, String responseType
        ) {
            MetadataService.describeMetadataResponse_element resp = new MetadataService.describeMetadataResponse_element();
            resp.result = new MetadataService.DescribeMetadataResult();
            response.put('response_x', resp);
        }
    }

    /** Returns a describe response with a null result (reachable but unexpected empty response). */
    private class EmptyResultMock implements WebServiceMock {
        public void doInvoke(
            Object stub, Object request, Map<String, Object> response, String endpoint,
            String soapAction, String requestName, String responseNS, String responseName, String responseType
        ) {
            MetadataService.describeMetadataResponse_element resp = new MetadataService.describeMetadataResponse_element();
            resp.result = null;
            response.put('response_x', resp);
        }
    }

    @isTest
    static void getSetupStatusReturnsRecommendations() {
        Test.startTest();
        BigObjectSetupController.SetupStatus status = BigObjectSetupController.getSetupStatus();
        Test.stopTest();

        System.assertNotEquals(null, status, 'A status should always be returned.');
        System.assertEquals('Metadata_API', status.namedCredentialName, 'Named Credential name is fixed.');
        System.assertNotEquals(null, status.recommendedUrl, 'Recommended URL (My Domain) should be populated.');
        System.assertEquals('/lightning/setup/NamedCredential/home', status.setupUrl, 'Setup deep link.');
        // exists reflects whether the org already has the Named Credential (a NamedCredential SOQL
        // is not isolated by test data), so we don't assert on it — only that recommendations load.
        System.assertNotEquals(null, status.exists, 'exists flag should always be populated.');
    }

    @isTest
    static void testConnectionSucceedsWhenDescribeReturnsResult() {
        Test.setMock(WebServiceMock.class, new SuccessMock());
        Test.startTest();
        BigObjectSetupController.ConnectionResult result = BigObjectSetupController.testConnection();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'A non-null describe result means the connection works.');
        System.assertNotEquals(null, result.message, 'A user-facing message should accompany the result.');
    }

    @isTest
    static void testConnectionReportsFailureWhenResultIsNull() {
        Test.setMock(WebServiceMock.class, new EmptyResultMock());
        Test.startTest();
        BigObjectSetupController.ConnectionResult result = BigObjectSetupController.testConnection();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'A null describe result should be treated as failure.');
        System.assertNotEquals(null, result.message, 'A failure message should be returned, not thrown.');
    }

    /** Returns a successful deleteMetadata response (Named Credential removed). */
    private class DisconnectMock implements WebServiceMock {
        public void doInvoke(
            Object stub, Object request, Map<String, Object> response, String endpoint,
            String soapAction, String requestName, String responseNS, String responseName, String responseType
        ) {
            MetadataService.deleteMetadataResponse_element resp = new MetadataService.deleteMetadataResponse_element();
            MetadataService.DeleteResult deleteResult = new MetadataService.DeleteResult();
            deleteResult.success = true;
            resp.result = new List<MetadataService.DeleteResult>{ deleteResult };
            response.put('response_x', resp);
        }
    }

    @isTest
    static void disconnectRemovesNamedCredentialWhenDeleteSucceeds() {
        Test.setMock(WebServiceMock.class, new DisconnectMock());
        Test.startTest();
        BigObjectSetupController.ConnectionResult result = BigObjectSetupController.disconnect();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'A successful DeleteResult means the credential was removed.');
        System.assertNotEquals(null, result.message, 'A user-facing message should accompany the result.');
    }
}
