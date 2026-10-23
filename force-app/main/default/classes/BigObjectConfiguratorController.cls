/**
 * Controller for the bigObjectConfigurator LWC (Phase 1).
 *
 * Responsibilities:
 *  - Describe: list selectable objects and their fields (mapped to Big Object field types).
 *  - Validate: enforce Big Object constraints server-side (defense in depth; the UI mirrors these).
 *  - Create:   build a Custom Big Object (__b) + Permission Set via the Metadata API.
 *
 * Metadata creation uses the apex-mdapi `MetadataService.cls` SOAP wrapper, because the native
 * Apex `Metadata.Operations` API does NOT support creating CustomObjects / Big Objects. Deploy
 * MetadataService.cls (generated from the API 67.0 Metadata WSDL so it includes `indexes`) and a
 * Named Credential / Remote Site Setting for the SOAP endpoint before invoking createBigObject.
 */
public with sharing class BigObjectConfiguratorController {
    // Big Object field types supported by this tool (Phase 1 scope).
    private static final Set<String> SUPPORTED_TYPES = new Set<String>{
        'Text', 'LongTextArea', 'Number', 'DateTime', 'Email', 'Phone', 'Url', 'Lookup'
    };
    private static final Integer MAX_INDEX_FIELDS = 5;
    private static final Integer MAX_TEXT_INDEX_LENGTH = 100;
    // LongTextArea and URL fields cannot be part of a Big Object index (platform rule).
    private static final Set<String> INDEX_DISALLOWED_TYPES = new Set<String>{ 'LongTextArea', 'Url' };
    // Email and Phone fields have a fixed character cost toward the 100-char index limit.
    private static final Integer EMAIL_INDEX_LENGTH = 80;
    private static final Integer PHONE_INDEX_LENGTH = 40;

    // ---------------------------------------------------------------------
    // DTOs exchanged with the LWC
    // ---------------------------------------------------------------------

    /** A selectable object (label + API name) for the object combobox. */
    public class ObjectOption {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public Boolean isCustom; // true for __c custom objects, false for standard
    }

    /** Describe metadata for one field, with its mapped Big Object type. */
    public class FieldInfo {
        @AuraEnabled public String label;
        @AuraEnabled public String apiName;
        @AuraEnabled public String type;        // mapped Big Object type, or raw type if unsupported
        @AuraEnabled public Integer length;      // text length / number precision
        @AuraEnabled public Integer scale;       // number scale (decimal places); 0 for non-numbers
        @AuraEnabled public Boolean isRequired;  // source field required?
        @AuraEnabled public Boolean isSupported; // can this field be archived (natively or via text coercion)?
        @AuraEnabled public Boolean isCoerced;  // unsupported native type stored as Text/LongTextArea (converted back on unarchive)
        @AuraEnabled public String sourceType;  // raw source DisplayType (e.g. PICKLIST, BOOLEAN)
        @AuraEnabled public Boolean requiredForRestore; // required on source insert (must be stored so unarchive can recreate the record)
        @AuraEnabled public String referenceTo;  // target object for Lookup fields
    }

    /** Request payload sent by the LWC on submit. */
    public class BigObjectRequest {
        @AuraEnabled public String label;
        @AuraEnabled public String pluralLabel;
        @AuraEnabled public String apiName;              // e.g. Account_Archive__b
        @AuraEnabled public List<FieldSelection> fields;
        @AuraEnabled public List<IndexFieldSelection> indexFields;
    }

    public class FieldSelection {
        @AuraEnabled public String apiName;              // source field API name
        @AuraEnabled public String bigObjectApiName;     // Big Object field API name (custom; defaults to apiName + __c)
        @AuraEnabled public String label;                // Big Object field label (user-editable)
        @AuraEnabled public String type;        // Big Object type
        @AuraEnabled public Integer length;
        @AuraEnabled public Integer scale;      // Number scale (defaults to 0)
        @AuraEnabled public Boolean required;
        @AuraEnabled public String referenceTo; // for Lookup
    }

    public class IndexFieldSelection {
        @AuraEnabled public String apiName;
        @AuraEnabled public String sortDirection; // 'ASC' | 'DESC'
    }

    /** Domain exception for user-facing validation/creation failures. */
    public class BigObjectConfiguratorException extends Exception {}

    // ---------------------------------------------------------------------
    // Describe
    // ---------------------------------------------------------------------

    /**
     * Lists Standard and Custom objects the running user can query.
     * @return Object options sorted by label.
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectOption> getObjects() {
        try {
            List<ObjectOption> options = new List<ObjectOption>();
            for (Schema.SObjectType sobjType : Schema.getGlobalDescribe().values()) {
                Schema.DescribeSObjectResult describe = sobjType.getDescribe();
                if (!isArchivableObject(describe)) {
                    continue;
                }
                ObjectOption option = new ObjectOption();
                option.label = describe.getLabel();
                option.apiName = describe.getName();
                option.isCustom = describe.isCustom();
                options.add(option);
            }
            options.sort(new ObjectOptionComparator());
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load objects: ' + e.getMessage());
        }
    }

    /**
     * Keep only real Standard and Custom objects a user would archive. Filters out the
     * system entities that otherwise flood the picker: Share/History/Feed/ChangeEvent/Tag
     * child objects, custom settings, and non-__c custom entities (custom metadata __mdt,
     * platform events __e, big objects __b, external objects __x).
     */
    private static Boolean isArchivableObject(Schema.DescribeSObjectResult describe) {
        if (!describe.isQueryable() || !describe.isAccessible()
            || !describe.isCreateable() || describe.isDeprecatedAndHidden()
            || describe.isCustomSetting()) {
            return false;
        }
        String name = describe.getName();
        if (describe.isCustom()) {
            // Custom objects only — __c, not __mdt / __e / __b / __x / __Share / __Feed / __History.
            return name.endsWithIgnoreCase('__c');
        }
        // Standard objects: drop the auto-generated system child entities.
        return !(name.endsWith('Share') || name.endsWith('History')
            || name.endsWith('Feed') || name.endsWith('ChangeEvent')
            || name.endsWith('Tag'));
    }

    /**
     * Describes all fields of an object and maps each to a Big Object field type.
     * @param objectApiName API name of the selected object.
     * @return Field metadata for the UI datatable.
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getFields(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('An object API name is required.');
        }
        try {
            Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectApiName);
            if (sobjType == null) {
                throw new BigObjectConfiguratorException('Unknown object: ' + objectApiName);
            }

            List<FieldInfo> fields = new List<FieldInfo>();
            for (Schema.SObjectField fieldToken : sobjType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult df = fieldToken.getDescribe();

                FieldInfo info = new FieldInfo();
                info.label = df.getLabel();
                info.apiName = df.getName();
                info.length = df.getLength();
                info.scale = 0;
                // Numeric fields: carry precision (as length) and scale so decimals are NOT lost.
                // df.getLength() is 0 for numbers, so use precision/scale from describe instead.
                if (isNumericType(df.getType())) {
                    info.length = df.getPrecision();
                    info.scale = df.getScale();
                }
                info.isRequired = !df.isNillable() && df.isCreateable();
                // Fields that MUST hold a value on insert (would block an unarchive/restore if not
                // stored): required, createable, and not auto-defaulted by the platform.
                info.requiredForRestore = !df.isNillable() && df.isCreateable() && !df.isDefaultedOnCreate();
                info.sourceType = String.valueOf(df.getType());
                info.type = mapToBigObjectType(df.getType());
                info.isSupported = info.type != null && SUPPORTED_TYPES.contains(info.type);
                info.isCoerced = isCoercedType(df.getType());
                // Coerced text fields need a valid Text length (Boolean/Date/Picklist report 0 or odd).
                if (info.isCoerced && info.type == 'Text') {
                    info.length = 255;
                }

                if (info.type == null) {
                    info.type = String.valueOf(df.getType()); // show raw type for truly unsupported fields
                }
                if (df.getType() == Schema.DisplayType.REFERENCE && !df.getReferenceTo().isEmpty()) {
                    info.referenceTo = df.getReferenceTo()[0].getDescribe().getName();
                }
                fields.add(info);
            }
            fields.sort(new FieldInfoComparator());
            return fields;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load fields: ' + e.getMessage());
        }
    }

    /**
     * Maps a Salesforce DisplayType to the Big Object field type this tool supports.
     * @param type The source field's DisplayType.
     * @return Big Object field type, or null when unsupported.
     */
    private static String mapToBigObjectType(Schema.DisplayType type) {
        switch on type {
            when STRING { return 'Text'; }
            when TEXTAREA { return 'LongTextArea'; }
            when EMAIL { return 'Email'; }
            when PHONE { return 'Phone'; }
            when URL { return 'Url'; }
            when DATETIME { return 'DateTime'; }
            when REFERENCE { return 'Lookup'; }
            when INTEGER, DOUBLE, CURRENCY, PERCENT, LONG { return 'Number'; }
            // Coerced: no native Big Object type, so store the value as text and convert it
            // back to the original type on unarchive. Preserves data with zero loss.
            when BOOLEAN, DATE, PICKLIST, COMBOBOX { return 'Text'; }
            when MULTIPICKLIST { return 'LongTextArea'; }
            when else { return null; }
        }
    }

    /** True for numeric source types that map to a Big Object Number (precision + scale matter). */
    private static Boolean isNumericType(Schema.DisplayType type) {
        return type == Schema.DisplayType.INTEGER
            || type == Schema.DisplayType.DOUBLE
            || type == Schema.DisplayType.CURRENCY
            || type == Schema.DisplayType.PERCENT
            || type == Schema.DisplayType.LONG;
    }

    /** True for source types with no native Big Object type — stored as text, restored to type. */
    private static Boolean isCoercedType(Schema.DisplayType type) {
        return type == Schema.DisplayType.BOOLEAN
            || type == Schema.DisplayType.DATE
            || type == Schema.DisplayType.PICKLIST
            || type == Schema.DisplayType.COMBOBOX
            || type == Schema.DisplayType.MULTIPICKLIST;
    }

    // ---------------------------------------------------------------------
    // Create
    // ---------------------------------------------------------------------

    /**
     * Validates the request and creates the Big Object + Permission Set via the Metadata API.
     * @param request The configuration captured in the UI.
     * @return A success message describing what was created.
     * @throws AuraHandledException when validation fails or the Metadata API returns errors.
     */
    @AuraEnabled
    public static String createBigObject(String requestJson) {
        try {
            BigObjectRequest request =
                (BigObjectRequest) JSON.deserialize(requestJson, BigObjectRequest.class);
            validateRequest(request);

            // File-based Metadata API deploy (async) — createMetadata does NOT make non-index Big
            // Object fields queryable, so the object + permission set are deployed as a package.
            // Returns a job id; the LWC polls checkCreateStatus until the deploy finishes.
            return BigObjectDeployService.startDeploy(request, false);
        } catch (BigObjectConfiguratorException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Big Object creation failed: ' + e.getMessage());
        }
    }

    /**
     * Polls the async Big Object deploy started by createBigObject.
     * @param jobId The deploy job id returned by createBigObject.
     * @return done / success / message for the LWC to render.
     */
    @AuraEnabled
    public static BigObjectDeployService.DeployStatus checkCreateStatus(String jobId) {
        try {
            return BigObjectDeployService.checkStatus(jobId);
        } catch (Exception e) {
            throw new AuraHandledException('Status check failed: ' + e.getMessage());
        }
    }

    /**
     * Server-side validation mirroring the UI rules (defense in depth).
     * @param request The configuration to validate.
     * @throws BigObjectConfiguratorException on the first rule violation.
     */
    @TestVisible
    private static void validateRequest(BigObjectRequest request) {
        if (request == null) {
            throw new BigObjectConfiguratorException('No request was provided.');
        }
        request.apiName = request.apiName == null ? null : request.apiName.trim();
        if (String.isBlank(request.apiName) || !request.apiName.endsWith('__b')) {
            throw new BigObjectConfiguratorException('The Big Object API name must end with "__b".');
        }
        if (String.isBlank(request.label)) {
            throw new BigObjectConfiguratorException('A label is required.');
        }
        if (request.fields == null || request.fields.isEmpty()) {
            throw new BigObjectConfiguratorException('Select at least one field.');
        }
        if (request.indexFields == null || request.indexFields.isEmpty()) {
            throw new BigObjectConfiguratorException('Select at least one index field.');
        }
        if (request.indexFields.size() > MAX_INDEX_FIELDS) {
            throw new BigObjectConfiguratorException(
                'An index may contain at most ' + MAX_INDEX_FIELDS + ' fields.');
        }

        Map<String, FieldSelection> fieldsByApiName = new Map<String, FieldSelection>();
        Set<String> bigObjectFieldNames = new Set<String>();
        for (FieldSelection field : request.fields) {
            if (!SUPPORTED_TYPES.contains(field.type)) {
                throw new BigObjectConfiguratorException(
                    'Field "' + field.apiName + '" has an unsupported type: ' + field.type);
            }
            // Normalize the Big Object field API name: every Big Object field must be custom (__c).
            String boName = String.isBlank(field.bigObjectApiName)
                ? field.apiName
                : field.bigObjectApiName.trim();
            if (!boName.endsWith('__c')) {
                boName += '__c';
            }
            if (bigObjectFieldNames.contains(boName.toLowerCase())) {
                throw new BigObjectConfiguratorException(
                    'Duplicate Big Object field API name: ' + boName);
            }
            bigObjectFieldNames.add(boName.toLowerCase());
            field.bigObjectApiName = boName;
            fieldsByApiName.put(field.apiName, field);
        }

        Integer combinedIndexLength = 0;
        for (IndexFieldSelection indexField : request.indexFields) {
            FieldSelection field = fieldsByApiName.get(indexField.apiName);
            if (field == null) {
                throw new BigObjectConfiguratorException(
                    'Index field "' + indexField.apiName + '" is not in the selected fields.');
            }
            // Index fields must be required on a Big Object.
            if (field.required != true) {
                throw new BigObjectConfiguratorException(
                    'Index field "' + field.apiName + '" must be marked required.');
            }
            // LongTextArea and URL fields can't be indexed.
            if (INDEX_DISALLOWED_TYPES.contains(field.type)) {
                throw new BigObjectConfiguratorException(
                    'Index field "' + field.apiName + '" is a ' + field.type
                    + ' field; LongTextArea and URL fields cannot be part of a Big Object index.');
            }
            combinedIndexLength += indexLengthFor(field);
        }
        // Text, Email (80), and Phone (40) all count toward the index character limit.
        if (combinedIndexLength > MAX_TEXT_INDEX_LENGTH) {
            throw new BigObjectConfiguratorException(
                'Combined length of text, email, and phone fields in the index (' + combinedIndexLength
                + ') exceeds the maximum of ' + MAX_TEXT_INDEX_LENGTH + '.');
        }
    }

    /**
     * Characters a single index field contributes toward the 100-char index limit.
     * @param field The selected field.
     * @return Text length, Email (80), Phone (40); 0 for types that don't count.
     */
    private static Integer indexLengthFor(FieldSelection field) {
        switch on field.type {
            when 'Text' { return field.length == null ? 0 : field.length; }
            when 'Email' { return EMAIL_INDEX_LENGTH; }
            when 'Phone' { return PHONE_INDEX_LENGTH; }
            when else { return 0; }
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /** Result of a Metadata API create operation. */
    public class MetadataCreateResult {
        public Boolean isSuccess = false;
        public String permissionSetName;
        public List<String> errors = new List<String>();
        public String errorSummary() {
            return String.join(errors, '; ');
        }
    }

    private class ObjectOptionComparator implements Comparator<ObjectOption> {
        public Integer compare(ObjectOption a, ObjectOption b) {
            return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        }
    }

    private class FieldInfoComparator implements Comparator<FieldInfo> {
        public Integer compare(FieldInfo a, FieldInfo b) {
            return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        }
    }
}
