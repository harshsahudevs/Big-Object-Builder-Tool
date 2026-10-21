/**
 * Controller for the Big Object Tool "Settings" page — Object Mappings section.
 *
 * Lets an admin map a source object's fields to a Big Object's fields and persist those mappings
 * as Big_Object_Field_Mapping__c records. BigObjectArchiveService reads these at archive time
 * (admin mappings win; unmapped fields fall back to API-name matching).
 */
public with sharing class BigObjectSettingsController {

    // Tooling API version used to list a Big Object's full field set (see getBigObjectFields).
    private static final String TOOLING_API_VERSION = '62.0';

    /** A selectable {apiName, label} pair for a combobox or list. */
    public class SelectableItem {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;

        public SelectableItem(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }
    }

    /** One field-mapping row exchanged with the LWC. */
    public class MappingRow {
        @AuraEnabled public String bigObjectField;
        @AuraEnabled public String sourceField;
    }

    /** Per-Big-Object mapping summary for the Manage Record Mapping overview table. */
    public class MappingOverview {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String sourceObject;  // from saved mappings (null if none)
        @AuraEnabled public Integer totalFields;   // custom fields on the Big Object
        @AuraEnabled public Integer mappedFields;  // distinct fields with a saved mapping
        @AuraEnabled public String status;         // 'Mapped' | 'Partial' | 'Unmapped'
    }

    public class BigObjectSettingsException extends Exception {}

    /**
     * Lists every Big Object (__b) in the org, sorted by label.
     * @return Selectable Big Objects.
     */
    @AuraEnabled(cacheable=true)
    public static List<SelectableItem> getBigObjects() {
        try {
            List<SelectableItem> items = new List<SelectableItem>();
            for (String apiName : Schema.getGlobalDescribe().keySet()) {
                if (!apiName.endsWith('__b')) {
                    continue;
                }
                Schema.DescribeSObjectResult describe = Schema.getGlobalDescribe().get(apiName).getDescribe();
                items.add(new SelectableItem(describe.getName(), describe.getLabel()));
            }
            items.sort(new ItemComparator());
            return items;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to list Big Objects: ' + e.getMessage());
        }
    }

    /**
     * Returns the accessible, non-system fields of an object for mapping.
     * @param objectApiName API name of the object (Big Object or source).
     * @return Selectable fields sorted by label.
     */
    @AuraEnabled(cacheable=true)
    public static List<SelectableItem> getObjectFields(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('An object API name is required.');
        }
        try {
            Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectApiName);
            if (sobjType == null) {
                throw new BigObjectSettingsException('Unknown object: ' + objectApiName);
            }
            List<SelectableItem> items = new List<SelectableItem>();
            for (Schema.SObjectField token : sobjType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult df = token.getDescribe();
                if (!df.isAccessible()) {
                    continue;
                }
                items.add(new SelectableItem(df.getName(), df.getLabel()));
            }
            items.sort(new ItemComparator());
            return items;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load fields: ' + e.getMessage());
        }
    }

    /**
     * Returns ALL custom fields of a Big Object for mapping — including non-index fields that the
     * runtime describe/SOQL schema omits on some orgs. Big Object custom field metadata always
     * exists in the Tooling API even when a field is not yet in the queryable schema, so this
     * queries Tooling (CustomField) rather than Schema.describe. Degrades gracefully to the
     * describe-based list if the Tooling callout is unavailable (e.g. no Metadata_API credential).
     *
     * Not cacheable: it performs a callout.
     * @param bigObjectApiName The Big Object (__b) API name.
     * @return Selectable custom fields sorted by label.
     */
    @AuraEnabled
    public static List<SelectableItem> getBigObjectFields(String bigObjectApiName) {
        if (String.isBlank(bigObjectApiName)) {
            throw new AuraHandledException('A Big Object API name is required.');
        }
        try {
            String durableId = resolveEntityDurableId(bigObjectApiName);
            if (String.isBlank(durableId)) {
                return getObjectFields(bigObjectApiName);
            }
            List<SelectableItem> items = queryToolingFields(durableId, describeLabels(bigObjectApiName));
            if (items.isEmpty()) {
                return getObjectFields(bigObjectApiName);
            }
            items.sort(new ItemComparator());
            return items;
        } catch (Exception e) {
            // Never fail the mapping UI: fall back to the describe-based (queryable-only) list.
            return getObjectFields(bigObjectApiName);
        }
    }

    /** Resolves an object's EntityDefinition durable id (the Tooling CustomField.TableEnumOrId). */
    private static String resolveEntityDurableId(String objectApiName) {
        List<EntityDefinition> defs = [
            SELECT DurableId
            FROM EntityDefinition
            WHERE QualifiedApiName = :objectApiName
            WITH USER_MODE
            LIMIT 1
        ];
        return defs.isEmpty() ? null : defs[0].DurableId;
    }

    /** Lowercase field API name -> label from the runtime describe (nicer labels where available). */
    private static Map<String, String> describeLabels(String objectApiName) {
        Map<String, String> labels = new Map<String, String>();
        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectApiName);
        if (sobjType != null) {
            for (Schema.SObjectField token : sobjType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult df = token.getDescribe();
                labels.put(df.getName().toLowerCase(), df.getLabel());
            }
        }
        return labels;
    }

    /**
     * Queries the Tooling API for every custom field defined on the Big Object.
     * Authenticates with an API-enabled session (reused from MetadataServiceFactory) over the
     * Metadata_API Named Credential host.
     *
     * Note: the Authorization header is set explicitly (not via the Named Credential's
     * "Generate Authorization Header"). This app standardizes on that option being OFF so the SOAP
     * Metadata API can authenticate through its SessionHeader; the same platform-issued session is
     * reused here for REST. The value is a runtime session id, never a hardcoded secret — hence the
     * justified suppression of ApexSuggestUsingNamedCred (the endpoint IS a Named Credential).
     */
    @SuppressWarnings('PMD.ApexSuggestUsingNamedCred')
    private static List<SelectableItem> queryToolingFields(
        String durableId, Map<String, String> labelByApiName
    ) {
        List<SelectableItem> items = new List<SelectableItem>();
        // durableId comes from EntityDefinition, but validate before embedding in the Tooling SOQL.
        if (durableId == null || !Pattern.matches('[a-zA-Z0-9]{15,18}', durableId)) {
            return items;
        }
        String soql = 'SELECT DeveloperName FROM CustomField WHERE TableEnumOrId = \'' + durableId + '\'';
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setEndpoint(
            'callout:Metadata_API/services/data/v' + TOOLING_API_VERSION
            + '/tooling/query/?q=' + EncodingUtil.urlEncode(soql, 'UTF-8')
        );
        req.setHeader('Authorization', 'Bearer ' + MetadataServiceFactory.resolveSessionId());
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            return items;
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> records = (List<Object>) body.get('records');
        if (records == null) {
            return items;
        }
        for (Object rec : records) {
            Map<String, Object> row = (Map<String, Object>) rec;
            String devName = (String) row.get('DeveloperName');
            if (String.isBlank(devName)) {
                continue;
            }
            String apiName = devName + '__c';
            String label = labelByApiName.containsKey(apiName.toLowerCase())
                ? labelByApiName.get(apiName.toLowerCase())
                : devName;
            items.add(new SelectableItem(apiName, label));
        }
        return items;
    }

    /**
     * Builds a mapping-status overview for every Big Object in the org: source object, how many of
     * its fields are mapped, and a Mapped/Partial/Unmapped status. Field totals come from one
     * Tooling callout (so non-index fields are counted); mappings come from one SOQL.
     * @return One MappingOverview per Big Object, sorted by label.
     */
    @AuraEnabled
    public static List<MappingOverview> getMappingOverview() {
        try {
            Map<String, String> labelByApi = new Map<String, String>();
            for (String apiName : Schema.getGlobalDescribe().keySet()) {
                if (!apiName.endsWith('__b')) {
                    continue;
                }
                labelByApi.put(apiName, Schema.getGlobalDescribe().get(apiName).getDescribe().getLabel());
            }
            List<MappingOverview> result = new List<MappingOverview>();
            if (labelByApi.isEmpty()) {
                return result;
            }

            // Saved mappings (one SOQL), grouped by Big Object.
            Map<String, Set<String>> mappedByApi = new Map<String, Set<String>>();
            Map<String, String> sourceByApi = new Map<String, String>();
            for (Big_Object_Field_Mapping__c m : [
                SELECT Big_Object__c, Big_Object_Field__c, Source_Object__c
                FROM Big_Object_Field_Mapping__c
                WITH USER_MODE
            ]) {
                if (!mappedByApi.containsKey(m.Big_Object__c)) {
                    mappedByApi.put(m.Big_Object__c, new Set<String>());
                }
                mappedByApi.get(m.Big_Object__c).add(m.Big_Object_Field__c);
                sourceByApi.put(m.Big_Object__c, m.Source_Object__c);
            }

            for (String apiName : labelByApi.keySet()) {
                MappingOverview o = new MappingOverview();
                o.apiName = apiName;
                o.label = labelByApi.get(apiName);
                o.sourceObject = sourceByApi.get(apiName);
                o.mappedFields = mappedByApi.containsKey(apiName) ? mappedByApi.get(apiName).size() : 0;
                // Total = the Big Object's full custom-field count, from the SAME path the mapping
                // editor uses (Tooling with a describe fallback) so the numbers always agree.
                Integer total = getBigObjectFields(apiName).size();
                // Never display more mapped than total (guards against a transient field-count miss).
                if (total < o.mappedFields) {
                    total = o.mappedFields;
                }
                o.totalFields = total;
                if (o.mappedFields == 0) {
                    o.status = 'Unmapped';
                } else if (o.mappedFields >= o.totalFields) {
                    o.status = 'Mapped';
                } else {
                    o.status = 'Partial';
                }
                result.add(o);
            }
            result.sort(new OverviewComparator());
            return result;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load mapping overview: ' + e.getMessage());
        }
    }

    /**
     * Returns the saved field mappings for a Big Object.
     * @param bigObjectApiName The Big Object API name.
     * @return Mapping records for that Big Object.
     */
    @AuraEnabled(cacheable=true)
    public static List<Big_Object_Field_Mapping__c> getMappings(String bigObjectApiName) {
        if (String.isBlank(bigObjectApiName)) {
            throw new AuraHandledException('A Big Object API name is required.');
        }
        try {
            return [
                SELECT Id, Big_Object__c, Big_Object_Field__c, Source_Object__c, Source_Field__c
                FROM Big_Object_Field_Mapping__c
                WHERE Big_Object__c = :bigObjectApiName
                WITH USER_MODE
                ORDER BY Big_Object_Field__c
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load mappings: ' + e.getMessage());
        }
    }

    /**
     * Replaces the stored mappings for a Big Object + source object with the supplied rows.
     * Rows with a blank source field are ignored (that Big Object field stays auto-mapped).
     * @param bigObjectApiName Destination Big Object API name.
     * @param sourceObjectApiName Source object API name.
     * @param mappingsJson JSON array of {bigObjectField, sourceField}.
     */
    @AuraEnabled
    public static void saveMappings(
        String bigObjectApiName, String sourceObjectApiName, String mappingsJson
    ) {
        try {
            if (String.isBlank(bigObjectApiName) || String.isBlank(sourceObjectApiName)) {
                throw new BigObjectSettingsException('A Big Object and a source object are required.');
            }
            List<MappingRow> rows =
                (List<MappingRow>) JSON.deserialize(mappingsJson, List<MappingRow>.class);

            // Replace all mappings for this Big Object + source object pair.
            List<Big_Object_Field_Mapping__c> existing = [
                SELECT Id
                FROM Big_Object_Field_Mapping__c
                WHERE Big_Object__c = :bigObjectApiName AND Source_Object__c = :sourceObjectApiName
                WITH USER_MODE
            ];
            if (!existing.isEmpty()) {
                Database.delete(existing, true, AccessLevel.USER_MODE);
            }

            List<Big_Object_Field_Mapping__c> toInsert = new List<Big_Object_Field_Mapping__c>();
            if (rows != null) {
                for (MappingRow row : rows) {
                    if (row == null || String.isBlank(row.bigObjectField) || String.isBlank(row.sourceField)) {
                        continue;
                    }
                    toInsert.add(new Big_Object_Field_Mapping__c(
                        Big_Object__c = bigObjectApiName,
                        Big_Object_Field__c = row.bigObjectField,
                        Source_Object__c = sourceObjectApiName,
                        Source_Field__c = row.sourceField
                    ));
                }
            }
            if (!toInsert.isEmpty()) {
                Database.insert(toInsert, true, AccessLevel.USER_MODE);
            }
        } catch (BigObjectSettingsException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save mappings: ' + e.getMessage());
        }
    }

    private class ItemComparator implements Comparator<SelectableItem> {
        public Integer compare(SelectableItem a, SelectableItem b) {
            String labelA = a.label == null ? '' : a.label.toLowerCase();
            String labelB = b.label == null ? '' : b.label.toLowerCase();
            return labelA.compareTo(labelB);
        }
    }

    private class OverviewComparator implements Comparator<MappingOverview> {
        public Integer compare(MappingOverview a, MappingOverview b) {
            String labelA = a.label == null ? '' : a.label.toLowerCase();
            String labelB = b.label == null ? '' : b.label.toLowerCase();
            return labelA.compareTo(labelB);
        }
    }
}
