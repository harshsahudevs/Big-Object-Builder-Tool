/**
 * Integration layer that builds and deploys the Big Object (__b) and its Permission Set through
 * the Metadata API, using the apex-mdapi `MetadataService.cls` SOAP wrapper.
 *
 * DEPENDENCY: this class will not compile until MetadataService.cls (apex-mdapi) is added to the
 * project. Generate it from the API 67.0 Metadata WSDL so the CustomObject type exposes `indexes`.
 *
 * SETUP:
 *  - Recommended: a Named Credential (named principal) pointing at this org's SOAP Metadata
 *    endpoint; apex-mdapi then needs no manual session header.
 *  - Alternative: a Remote Site Setting for the org domain + a session id obtained from a
 *    Visualforce page (a Lightning session id cannot call the SOAP Metadata API directly).
 */
public with sharing class MetadataServiceFactory {
    // Point this at the Named Credential you create (see class header). The endpoint path is
    // appended by apex-mdapi; the version must match sourceApiVersion.
    private static final String NAMED_CREDENTIAL = 'callout:Metadata_API';
    private static final String API_VERSION = '67.0';

    /**
     * Every field on a Big Object must be a custom field. Source standard fields (e.g. AccountNumber)
     * carry no __c suffix, so append one; also prevents "cannot specify label on standard field".
     * @param sourceApiName The selected source field's API name.
     * @return A Big Object custom field API name ending in __c.
     */
    private static String toBigObjectFieldName(String sourceApiName) {
        return sourceApiName.endsWith('__c') ? sourceApiName : sourceApiName + '__c';
    }

    /**
     * Creates the Big Object with its fields + index, then a Permission Set granting access.
     * @param request The validated configuration from the controller.
     * @return Aggregated success/error result.
     */
    public static BigObjectConfiguratorController.MetadataCreateResult createBigObjectAndPermissionSet(
        BigObjectConfiguratorController.BigObjectRequest request
    ) {
        BigObjectConfiguratorController.MetadataCreateResult result =
            new BigObjectConfiguratorController.MetadataCreateResult();

        MetadataService.MetadataPort service = createService();

        // 1) Big Object (CustomObject whose fullName ends in __b).
        MetadataService.CustomObject bigObject = buildBigObject(request);
        List<MetadataService.SaveResult> objectResults =
            service.createMetadata(new List<MetadataService.Metadata>{ bigObject });
        collectErrors(result, objectResults);
        if (!result.errors.isEmpty()) {
            return result; // stop: the permission set references fields that were not created
        }

        // 2) Non-index fields. Big Objects do NOT reliably provision non-index fields sent inline
        // with the CustomObject via SOAP createMetadata — only index fields become queryable
        // (the rest show in Setup but never register in FieldDefinition/SOQL). Create them as
        // standalone CustomFields in their own call so they become queryable. Max 10 per call.
        List<MetadataService.Metadata> nonIndexFields = buildNonIndexFields(request);
        for (Integer i = 0; i < nonIndexFields.size(); i += 10) {
            List<MetadataService.Metadata> chunk = new List<MetadataService.Metadata>();
            for (Integer j = i; j < Math.min(i + 10, nonIndexFields.size()); j++) {
                chunk.add(nonIndexFields[j]);
            }
            collectErrors(result, service.createMetadata(chunk));
            if (!result.errors.isEmpty()) {
                return result;
            }
        }

        // 3) Permission Set granting read/create on the object and read on every field.
        MetadataService.PermissionSet permissionSet = buildPermissionSet(request);
        List<MetadataService.SaveResult> permSetResults =
            service.createMetadata(new List<MetadataService.Metadata>{ permissionSet });
        collectErrors(result, permSetResults);
        if (!result.errors.isEmpty()) {
            return result;
        }

        result.isSuccess = true;
        result.permissionSetName = permissionSet.fullName;
        return result;
    }

    /**
     * Builds the CustomObject metadata (fields + index) for the Big Object.
     */
    private static MetadataService.CustomObject buildBigObject(
        BigObjectConfiguratorController.BigObjectRequest request
    ) {
        Set<String> indexFieldApiNames = new Set<String>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            indexFieldApiNames.add(idx.apiName);
        }

        MetadataService.CustomObject bigObject = new MetadataService.CustomObject();
        bigObject.fullName = request.apiName;
        bigObject.label = request.label;
        bigObject.pluralLabel = String.isBlank(request.pluralLabel) ? request.label + 's' : request.pluralLabel;
        bigObject.deploymentStatus = 'Deployed';

        // Only index fields go inline with the object: the index references them, and they are
        // the only fields reliably provisioned inline. Non-index fields are created separately
        // afterward (see createBigObjectAndPermissionSet / buildNonIndexFields).
        List<MetadataService.CustomField> customFields = new List<MetadataService.CustomField>();
        for (BigObjectConfiguratorController.FieldSelection field : request.fields) {
            if (indexFieldApiNames.contains(field.apiName)) {
                customFields.add(buildField(field, true));
            }
        }
        bigObject.fields = customFields;

        // Index definition. Field order follows the order supplied by the UI.
        MetadataService.Index index = new MetadataService.Index();
        // fullName is the index developer name; without it the index shows as "null" in Setup.
        index.fullName = request.apiName.removeEnd('__b') + '_Index';
        index.label = request.label + ' Index';
        List<MetadataService.IndexField> indexFields = new List<MetadataService.IndexField>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            MetadataService.IndexField indexField = new MetadataService.IndexField();
            indexField.name = toBigObjectFieldName(idx.apiName);
            indexField.sortDirection = idx.sortDirection; // 'ASC' | 'DESC'
            indexFields.add(indexField);
        }
        index.fields = indexFields;
        bigObject.indexes = new List<MetadataService.Index>{ index };

        return bigObject;
    }

    /**
     * Builds one CustomField, mapping Big Object type to the Metadata API attributes.
     */
    private static MetadataService.CustomField buildField(
        BigObjectConfiguratorController.FieldSelection field, Boolean isIndexField
    ) {
        MetadataService.CustomField customField = new MetadataService.CustomField();
        customField.fullName = toBigObjectFieldName(field.apiName);
        customField.label = field.label;
        // Lookup -> Text(18) storing the related record Id. Big Objects can't reference arbitrary
        // lookup targets (polymorphic + system objects like Group/ActionCadence are invalid __b
        // targets); for an archive the historical Id as Text is universally valid and restorable.
        String effectiveType = (field.type == 'Lookup') ? 'Text' : field.type;
        customField.type_x = effectiveType; // apex-mdapi exposes "type" as "type_x"
        // Big Object rule: only index fields may be required. A non-index field marked required
        // on the source would be rejected ("cannot deploy to a required field").
        customField.required = isIndexField;

        switch on effectiveType {
            when 'Text' {
                customField.length = (field.type == 'Lookup')
                    ? 18
                    : ((field.length == null) ? 255 : field.length);
            }
            when 'LongTextArea' {
                customField.length = (field.length == null) ? 32768 : field.length;
                customField.visibleLines = 3;
            }
            when 'Number' {
                // Describe reports length 0 for Number fields, so default precision to 18.
                // The Metadata API requires precision > scale.
                Integer p = (field.length == null || field.length <= 0) ? 18 : Math.min(field.length, 18);
                Integer s = (field.scale == null || field.scale < 0) ? 0 : field.scale;
                if (s >= p) {
                    s = p - 1;
                }
                customField.precision = p;
                customField.scale = s;
            }
            // Email / Phone / Url / DateTime need no extra attributes.
        }
        return customField;
    }

    /**
     * Builds standalone CustomField metadata for every non-index field so they can be created in
     * their own createMetadata call (inline non-index fields are not reliably provisioned on a Big
     * Object). fullName is qualified as Object.Field__c, required for a standalone custom field.
     */
    private static List<MetadataService.Metadata> buildNonIndexFields(
        BigObjectConfiguratorController.BigObjectRequest request
    ) {
        Set<String> indexFieldApiNames = new Set<String>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            indexFieldApiNames.add(idx.apiName);
        }
        List<MetadataService.Metadata> fields = new List<MetadataService.Metadata>();
        for (BigObjectConfiguratorController.FieldSelection field : request.fields) {
            if (indexFieldApiNames.contains(field.apiName)) {
                continue;
            }
            MetadataService.CustomField cf = buildField(field, false);
            cf.fullName = request.apiName + '.' + toBigObjectFieldName(field.apiName);
            fields.add(cf);
        }
        return fields;
    }

    /**
     * Builds a Permission Set granting object + field access to the new Big Object.
     */
    private static MetadataService.PermissionSet buildPermissionSet(
        BigObjectConfiguratorController.BigObjectRequest request
    ) {
        MetadataService.PermissionSet permissionSet = new MetadataService.PermissionSet();
        permissionSet.fullName = request.apiName.removeEnd('__b') + '_Access';
        permissionSet.label = request.label + ' Access';

        // Big Objects support insert + query (no edit/delete of individual rows).
        MetadataService.PermissionSetObjectPermissions objectPerm =
            new MetadataService.PermissionSetObjectPermissions();
        objectPerm.object_x = request.apiName; // apex-mdapi exposes "object" as "object_x"
        objectPerm.allowRead = true;
        objectPerm.allowCreate = true;
        objectPerm.allowEdit = false;
        objectPerm.allowDelete = false;
        objectPerm.viewAllRecords = false;
        objectPerm.modifyAllRecords = false;
        permissionSet.objectPermissions = new List<MetadataService.PermissionSetObjectPermissions>{ objectPerm };

        // On the Big Object only index fields are required (see buildField). Required fields are
        // implicitly accessible and must NOT appear in fieldPermissions, or the deploy fails with
        // "cannot deploy to a required field" — so skip exactly the index fields.
        Set<String> indexFieldApiNames = new Set<String>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            indexFieldApiNames.add(idx.apiName);
        }

        List<MetadataService.PermissionSetFieldPermissions> fieldPerms =
            new List<MetadataService.PermissionSetFieldPermissions>();
        for (BigObjectConfiguratorController.FieldSelection field : request.fields) {
            if (indexFieldApiNames.contains(field.apiName)) {
                continue;
            }
            MetadataService.PermissionSetFieldPermissions fieldPerm =
                new MetadataService.PermissionSetFieldPermissions();
            fieldPerm.field = request.apiName + '.' + toBigObjectFieldName(field.apiName);
            fieldPerm.readable = true;
            fieldPerm.editable = true;
            fieldPerms.add(fieldPerm);
        }
        permissionSet.fieldPermissions = fieldPerms;

        return permissionSet;
    }

    /**
     * Creates an authenticated MetadataService port via the Named Credential.
     */
    public static MetadataService.MetadataPort createService() {
        MetadataService.MetadataPort service = new MetadataService.MetadataPort();
        service.endpoint_x = NAMED_CREDENTIAL + '/services/Soap/m/' + API_VERSION;
        service.timeout_x = 120000;
        // The SOAP Metadata API authenticates via the SessionHeader with an API-enabled session.
        // apex-mdapi uses WebServiceCallout, which does NOT substitute Named Credential merge
        // fields, so the session must be resolved in Apex. A Lightning session (UserInfo under LWC)
        // cannot call the Metadata API, so pull an API-enabled session from a Visualforce page.
        service.SessionHeader = new MetadataService.SessionHeader_element();
        service.SessionHeader.sessionId = resolveSessionId();
        // Big Object CRUD-based Metadata API calls require AllOrNoneHeader = true so the object,
        // its fields, and its index are created atomically.
        service.AllOrNoneHeader = new MetadataService.AllOrNoneHeader_element();
        service.AllOrNoneHeader.allOrNone = true;
        return service;
    }

    /**
     * Returns an API-enabled session id usable by the SOAP Metadata API AND the REST/Tooling API.
     * Uses a Visualforce page ({!$Api.Session_ID}) because a Lightning/LWC session id is rejected
     * by the Metadata API. Falls back to UserInfo in test context (no getContent callout).
     * Public so other controllers (e.g. BigObjectSettingsController's Tooling callout) can reuse it.
     */
    public static String resolveSessionId() {
        if (Test.isRunningTest()) {
            return UserInfo.getSessionId();
        }
        String content = Page.MetadataApiSession.getContent().toString();
        return content == null ? null : content.trim();
    }

    /**
     * Translates Metadata API SaveResults into the controller result's error list.
     */
    private static void collectErrors(
        BigObjectConfiguratorController.MetadataCreateResult result,
        List<MetadataService.SaveResult> saveResults
    ) {
        if (saveResults == null) {
            return;
        }
        for (MetadataService.SaveResult saveResult : saveResults) {
            if (saveResult.success) {
                continue;
            }
            if (saveResult.errors != null) {
                for (MetadataService.Error err : saveResult.errors) {
                    result.errors.add(err.statusCode + ': ' + err.message);
                }
            } else {
                result.errors.add('Unknown Metadata API error for ' + saveResult.fullName);
            }
        }
    }
}
