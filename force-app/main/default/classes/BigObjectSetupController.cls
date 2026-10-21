/**
 * Controller for the bigObjectSetupAssistant LWC: guides an admin through creating the
 * Metadata API Named Credential the Big Object tool needs, and verifies it works.
 *
 * The tool calls the SOAP Metadata API through the apex-mdapi MetadataService port, which
 * authenticates via a Named Credential (named principal). This controller detects whether that
 * Named Credential exists and runs a lightweight live callout to confirm it is configured correctly.
 */
public with sharing class BigObjectSetupController {
    // Must match MetadataServiceFactory.NAMED_CREDENTIAL ('callout:Metadata_API').
    private static final String NAMED_CREDENTIAL = 'Metadata_API';
    private static final String API_VERSION = '67.0';

    /** Setup status surfaced to the Setup Assistant UI. */
    public class SetupStatus {
        @AuraEnabled public String namedCredentialName = NAMED_CREDENTIAL;
        @AuraEnabled public Boolean exists = false;
        @AuraEnabled public String endpoint;        // configured URL, when it exists
        @AuraEnabled public String recommendedUrl;   // My Domain URL to paste into Setup
        @AuraEnabled public String setupUrl;         // deep link to the Named Credentials Setup page
    }

    /** Result of the live Test Connection callout. */
    public class ConnectionResult {
        @AuraEnabled public Boolean isSuccess = false;
        @AuraEnabled public String message;
    }

    /**
     * Reports whether the Metadata API Named Credential exists and the values the admin needs.
     * @return Setup status for the assistant.
     */
    @AuraEnabled(cacheable=true)
    public static SetupStatus getSetupStatus() {
        try {
            SetupStatus status = new SetupStatus();
            status.recommendedUrl = Url.getOrgDomainUrl().toExternalForm();
            status.setupUrl = '/lightning/setup/NamedCredential/home';

            // NamedCredential is a queryable sObject in Apex (no Tooling API needed).
            List<NamedCredential> matches = [
                SELECT DeveloperName, Endpoint
                FROM NamedCredential
                WHERE DeveloperName = :NAMED_CREDENTIAL
                WITH USER_MODE
                LIMIT 1
            ];
            if (!matches.isEmpty()) {
                status.exists = true;
                status.endpoint = matches[0].Endpoint;
            }
            return status;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to read setup status: ' + e.getMessage());
        }
    }

    /**
     * Runs a minimal live Metadata API callout through the Named Credential to confirm it works.
     * Uses describeMetadata, the cheapest authenticated call that proves end-to-end connectivity.
     * @return Success flag plus a user-facing message.
     */
    @AuraEnabled
    public static ConnectionResult testConnection() {
        ConnectionResult result = new ConnectionResult();
        try {
            // Reuse the exact authenticated port the Big Object engine uses: endpoint via the Named
            // Credential + an API-enabled session in the SessionHeader (resolved from a VF page).
            // Building a bare port without the SessionHeader fails with INVALID_SESSION_ID.
            MetadataService.MetadataPort service = MetadataServiceFactory.createService();

            // A successful describe proves auth + endpoint + SOAP are all correct.
            MetadataService.DescribeMetadataResult describe = service.describeMetadata(Double.valueOf(API_VERSION));
            result.isSuccess = (describe != null);
            result.message = result.isSuccess
                ? 'Connection successful. The Metadata API is reachable and authenticated.'
                : 'The callout returned no result. Re-check the Named Credential configuration.';
        } catch (System.CalloutException e) {
            // Most misconfigurations (missing cred, bad URL, auth failure) surface here.
            result.isSuccess = false;
            result.message = 'Connection failed: ' + e.getMessage()
                + ' Verify the Named Credential name, URL, and that it is authenticated.';
        } catch (Exception e) {
            result.isSuccess = false;
            result.message = 'Connection failed: ' + e.getMessage();
        }
        return result;
    }

    /**
     * Disconnects the integration by removing the Metadata API Named Credential. NamedCredential is
     * not deletable via Apex DML, so deletion goes through the Metadata API using the same
     * authenticated port the tool uses.
     * @return Result flag plus a user-facing message.
     */
    @AuraEnabled
    public static ConnectionResult disconnect() {
        ConnectionResult result = new ConnectionResult();
        try {
            MetadataService.MetadataPort service = MetadataServiceFactory.createService();
            List<MetadataService.DeleteResult> deletes =
                service.deleteMetadata('NamedCredential', new List<String>{ NAMED_CREDENTIAL });
            MetadataService.DeleteResult deleteResult =
                (deletes != null && !deletes.isEmpty()) ? deletes[0] : null;
            result.isSuccess = (deleteResult != null && deleteResult.success == true);
            if (result.isSuccess) {
                result.message = 'Disconnected. The Named Credential "' + NAMED_CREDENTIAL + '" was removed.';
            } else {
                String detail = (deleteResult != null && deleteResult.errors != null && !deleteResult.errors.isEmpty())
                    ? deleteResult.errors[0].message
                    : 'Unknown error';
                result.message = 'Disconnect failed: ' + detail;
            }
        } catch (Exception e) {
            result.isSuccess = false;
            result.message = 'Disconnect failed: ' + e.getMessage();
        }
        return result;
    }
}
