/**
 * Read-side engine for Big Objects (Phase 3). Builds and runs dynamic SOQL against a Big Object
 * while strictly honoring Big Object query rules, and returns a generic wrapper the UI can render
 * without compile-time knowledge of the object.
 *
 * Big Object SOQL rules enforced here:
 *  - You may filter ONLY on index fields, following the index order with NO gaps.
 *  - Every filtered index field except the LAST must use '='; the last may use a range operator.
 *  - No OFFSET and no COUNT() — pagination is cursor based (the last row's index values seed the
 *    next page via a range filter).
 *  - ORDER BY is only valid on index fields in index order; LIMIT is supported.
 */
public with sharing class BigObjectQueryService {
    private static final Integer DEFAULT_PAGE_SIZE = 25;
    private static final Integer MAX_PAGE_SIZE = 200;
    private static final Set<String> RANGE_OPERATORS = new Set<String>{ '>', '<', '>=', '<=' };
    private static final Set<String> ALLOWED_OPERATORS = new Set<String>{ '=', '>', '<', '>=', '<=' };

    public class BigObjectQueryException extends Exception {}

    // ---- DTOs --------------------------------------------------------------

    /** One filter clause supplied by the UI; fields must be index fields in index order. */
    public class Filter {
        @AuraEnabled public String field;
        @AuraEnabled public String operator; // '=', '>', '<', '>=', '<='
        @AuraEnabled public String value;    // string form; coerced to the field's type
    }

    /** Everything needed to run one page of a Big Object query. */
    public class QueryRequest {
        @AuraEnabled public String bigObjectApiName;
        @AuraEnabled public List<Filter> filters;
        @AuraEnabled public List<String> displayFields;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public String sortDirection; // 'ASC' | 'DESC'
        @AuraEnabled public String cursor;        // opaque; serialized index values of the last row
    }

    /** A single Big Object row as display label/value pairs plus the raw map. */
    public class Row {
        @AuraEnabled public String recordKey;
        @AuraEnabled public Map<String, Object> values;
        public Row() {
            this.values = new Map<String, Object>();
        }
    }

    /** Column descriptor for the datatable. */
    public class Column {
        @AuraEnabled public String fieldName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean isIndexField;
    }

    /** One page of results plus pagination + metadata for the UI. */
    public class QueryResult {
        @AuraEnabled public List<Row> rows = new List<Row>();
        @AuraEnabled public List<Column> columns = new List<Column>();
        @AuraEnabled public List<String> indexFields = new List<String>();
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public String nextCursor;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Long queriedAt; // epoch ms, for the "last refreshed" indicator
    }

    // ---- Public API --------------------------------------------------------

    /**
     * Returns the Big Object's index fields in index order (used by the UI to build valid filters).
     * @param bigObjectApiName Big Object API name (e.g. Case_Archive__b).
     * @return Ordered index field columns.
     */
    @AuraEnabled(cacheable=true)
    public static List<Column> getIndexFields(String bigObjectApiName) {
        try {
            Schema.DescribeSObjectResult describe = describeBigObject(bigObjectApiName);
            List<Column> columns = new List<Column>();
            for (String fieldName : getOrderedIndexFields(describe)) {
                columns.add(toColumn(describe, fieldName, true));
            }
            return columns;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Runs one page of a Big Object query honoring index rules and cursor pagination.
     * @param request The query configuration.
     * @return A page of rows plus the cursor for the next page.
     */
    @AuraEnabled
    public static QueryResult getArchivedRecords(QueryRequest request) {
        try {
            if (request == null || String.isBlank(request.bigObjectApiName)) {
                throw new BigObjectQueryException('A Big Object API name is required.');
            }
            Schema.DescribeSObjectResult describe = describeBigObject(request.bigObjectApiName);
            List<String> indexFields = getOrderedIndexFields(describe);

            Integer pageSize = normalizePageSize(request.pageSize);
            String sortDirection = ('DESC'.equalsIgnoreCase(request.sortDirection)) ? 'DESC' : 'ASC';
            List<Filter> filters = (request.filters == null) ? new List<Filter>() : request.filters;
            validateFilterOrder(filters, indexFields);

            List<String> selectFields = resolveDisplayFields(describe, request.displayFields, indexFields);

            Map<String, Object> binds = new Map<String, Object>();
            String whereClause = buildWhereClause(describe, filters, indexFields, request.cursor, sortDirection, binds);

            // Fetch one extra row to detect whether another page exists.
            binds.put('pageSizePlusOne', pageSize + 1);

            // Apex describe can report phantom columns that are not actually queryable (seen after a
            // Big Object is deleted and recreated with the same name — the org's describe cache lags
            // behind the real schema). Self-heal: on "No such column 'X'", drop X and retry so the
            // viewer still loads instead of hard-failing.
            List<SObject> records;
            Integer attemptsLeft = selectFields.size() + 1;
            while (true) {
                String soql =
                    'SELECT ' + String.join(selectFields, ', ')
                    + ' FROM ' + request.bigObjectApiName
                    + (String.isBlank(whereClause) ? '' : ' WHERE ' + whereClause)
                    + (indexFields.isEmpty()
                        ? ''
                        : ' ORDER BY ' + String.join(indexFields, ' ' + sortDirection + ', ') + ' ' + sortDirection)
                    + ' LIMIT :pageSizePlusOne';
                try {
                    records = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
                    break;
                } catch (QueryException qe) {
                    String badColumn = extractMissingColumn(qe.getMessage());
                    attemptsLeft--;
                    Boolean removedFromSelect = (badColumn != null) && removeFieldIgnoreCase(selectFields, badColumn);
                    Boolean removedFromIndex = (badColumn != null) && removeFieldIgnoreCase(indexFields, badColumn);
                    if ((!removedFromSelect && !removedFromIndex) || selectFields.isEmpty() || attemptsLeft <= 0) {
                        throw qe;
                    }
                }
            }

            return buildResult(describe, records, selectFields, indexFields, pageSize, sortDirection);
        } catch (BigObjectQueryException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            // Index-rule violations surface here as query exceptions — give a clear message.
            throw new AuraHandledException('Big Object query failed: ' + e.getMessage());
        }
    }

    /** Parses the field API name from a "No such column 'X' on entity ..." SOQL error, or null. */
    private static String extractMissingColumn(String message) {
        if (String.isBlank(message)) {
            return null;
        }
        Matcher m = Pattern.compile('No such column \'([^\']+)\'').matcher(message);
        return m.find() ? m.group(1) : null;
    }

    /** Removes a field (case-insensitive) from the list in place; returns whether anything matched. */
    private static Boolean removeFieldIgnoreCase(List<String> fields, String target) {
        for (Integer i = fields.size() - 1; i >= 0; i--) {
            if (fields[i].equalsIgnoreCase(target)) {
                fields.remove(i);
                return true;
            }
        }
        return false;
    }

    // ---- Describe helpers --------------------------------------------------

    private static Schema.DescribeSObjectResult describeBigObject(String apiName) {
        SObjectType sobjType = Schema.getGlobalDescribe().get(apiName);
        if (sobjType == null) {
            throw new BigObjectQueryException('Unknown Big Object: ' + apiName);
        }
        if (!apiName.endsWith('__b')) {
            throw new BigObjectQueryException(apiName + ' is not a Big Object (must end in __b).');
        }
        return sobjType.getDescribe();
    }

    /**
     * Returns the Big Object's index fields. Index fields are required (non-nillable); they are
     * returned in a stable order. Supply an explicit order via a mapping store if your index order
     * differs from this derived order (see the Phase 3 notes).
     */
    private static List<String> getOrderedIndexFields(Schema.DescribeSObjectResult describe) {
        List<String> indexFields = new List<String>();
        for (String fieldName : describe.fields.getMap().keySet()) {
            Schema.DescribeFieldResult df = describe.fields.getMap().get(fieldName).getDescribe();
            if (!df.isNillable() && df.isCreateable()) {
                indexFields.add(df.getName());
            }
        }
        indexFields.sort();
        if (indexFields.isEmpty()) {
            throw new BigObjectQueryException('No index fields found on ' + describe.getName() + '.');
        }
        return indexFields;
    }

    private static Column toColumn(Schema.DescribeSObjectResult describe, String fieldName, Boolean isIndex) {
        Schema.DescribeFieldResult df = describe.fields.getMap().get(fieldName.toLowerCase()).getDescribe();
        Column col = new Column();
        col.fieldName = df.getName();
        col.label = df.getLabel();
        col.type = String.valueOf(df.getType()).toLowerCase();
        col.isIndexField = isIndex;
        return col;
    }

    // ---- Filter + where-clause construction --------------------------------

    /**
     * Validates that filters reference index fields in index order with no gaps, and that only the
     * last filtered field uses a range operator.
     */
    private static void validateFilterOrder(List<Filter> filters, List<String> indexFields) {
        for (Integer i = 0; i < filters.size(); i++) {
            Filter f = filters[i];
            if (String.isBlank(f.field) || !ALLOWED_OPERATORS.contains(f.operator)) {
                throw new BigObjectQueryException('Invalid filter operator for field "' + f.field + '".');
            }
            if (i >= indexFields.size() || !indexFields[i].equalsIgnoreCase(f.field)) {
                throw new BigObjectQueryException(
                    'Filters must follow index order with no gaps. Expected "'
                    + (i < indexFields.size() ? indexFields[i] : '(none)') + '" at position ' + (i + 1) + '.');
            }
            // Only the final filter in the list may use a range operator.
            Boolean isLast = (i == filters.size() - 1);
            if (!isLast && RANGE_OPERATORS.contains(f.operator)) {
                throw new BigObjectQueryException(
                    'Only the last index field in a filter may use a range operator ("' + f.field + '").');
            }
        }
    }

    /**
     * Builds the WHERE clause from the user filters plus the pagination cursor, binding all values.
     */
    private static String buildWhereClause(
        Schema.DescribeSObjectResult describe, List<Filter> filters, List<String> indexFields,
        String cursor, String sortDirection, Map<String, Object> binds
    ) {
        List<String> clauses = new List<String>();
        for (Integer i = 0; i < filters.size(); i++) {
            Filter f = filters[i];
            String bindName = 'f' + i;
            clauses.add(f.field + ' ' + f.operator + ' :' + bindName);
            binds.put(bindName, coerceValue(describe, f.field, f.value));
        }
        // Cursor: a forward range on the first index field beyond anything already equality-filtered.
        if (String.isNotBlank(cursor)) {
            Map<String, Object> cursorValues = (Map<String, Object>) JSON.deserializeUntyped(cursor);
            String cursorField = indexFields[0];
            String op = ('DESC'.equalsIgnoreCase(sortDirection)) ? '<' : '>';
            clauses.add(cursorField + ' ' + op + ' :cursorValue');
            binds.put('cursorValue', coerceValue(describe, cursorField, String.valueOf(cursorValues.get(cursorField))));
        }
        return String.join(clauses, ' AND ');
    }

    /** Coerces a string filter value to the field's Apex type so binds type-match the column. */
    private static Object coerceValue(Schema.DescribeSObjectResult describe, String fieldName, String value) {
        if (value == null) {
            return null;
        }
        Schema.DisplayType type = describe.fields.getMap().get(fieldName.toLowerCase()).getDescribe().getType();
        switch on type {
            when INTEGER, LONG { return Long.valueOf(value); }
            when DOUBLE, CURRENCY, PERCENT { return Double.valueOf(value); }
            when DATETIME { return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class); }
            when DATE { return Date.valueOf(value); }
            when BOOLEAN { return Boolean.valueOf(value); }
            when else { return value; }
        }
    }

    // ---- Field resolution + result assembly --------------------------------

    private static List<String> resolveDisplayFields(
        Schema.DescribeSObjectResult describe, List<String> requested, List<String> indexFields
    ) {
        Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
        // Preserve order (index fields first, then requested) while de-duplicating.
        List<String> fields = new List<String>();
        Set<String> seen = new Set<String>();
        for (String idx : indexFields) {
            if (seen.add(idx)) {
                fields.add(idx);
            }
        }
        if (requested != null) {
            for (String field : requested) {
                if (String.isNotBlank(field) && fieldMap.containsKey(field.toLowerCase())) {
                    String resolved = fieldMap.get(field.toLowerCase()).getDescribe().getName();
                    if (seen.add(resolved)) {
                        fields.add(resolved);
                    }
                }
            }
        }
        return fields;
    }

    private static QueryResult buildResult(
        Schema.DescribeSObjectResult describe, List<SObject> records, List<String> selectFields,
        List<String> indexFields, Integer pageSize, String sortDirection
    ) {
        QueryResult result = new QueryResult();
        result.pageSize = pageSize;
        result.indexFields = indexFields;
        result.queriedAt = System.now().getTime();

        Set<String> indexFieldSet = new Set<String>(indexFields);
        for (String field : selectFields) {
            result.columns.add(toColumn(describe, field, indexFieldSet.contains(field)));
        }

        // One extra row signals another page; trim it before returning.
        result.hasMore = records.size() > pageSize;
        Integer rowCount = Math.min(records.size(), pageSize);
        for (Integer i = 0; i < rowCount; i++) {
            SObject record = records[i];
            Row row = new Row();
            List<String> keyParts = new List<String>();
            for (String field : selectFields) {
                Object value = record.get(field);
                row.values.put(field, value);
                if (indexFieldSet.contains(field)) {
                    keyParts.add(value == null ? '' : String.valueOf(value));
                }
            }
            row.recordKey = String.join(keyParts, '|');
            result.rows.add(row);
        }

        // Build the next cursor from the last returned row's index values.
        if (result.hasMore && !result.rows.isEmpty()) {
            SObject lastRecord = records[rowCount - 1];
            Map<String, Object> cursorValues = new Map<String, Object>();
            for (String idx : indexFields) {
                cursorValues.put(idx, lastRecord.get(idx));
            }
            result.nextCursor = JSON.serialize(cursorValues);
        }
        return result;
    }

    private static Integer normalizePageSize(Integer requested) {
        if (requested == null || requested <= 0) {
            return DEFAULT_PAGE_SIZE;
        }
        return Math.min(requested, MAX_PAGE_SIZE);
    }
}
