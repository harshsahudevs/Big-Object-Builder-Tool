/**
 * Builds safe, dynamic SOQL for Archive Policies. Field API names are validated against the target
 * object's describe (allowlist), operators come from a fixed map, values are passed as typed bind
 * variables, relative-date functions are validated numeric literals, and the Filter Logic string is
 * tokenized so only digits / AND / OR / parentheses survive. Nothing user-supplied is concatenated
 * raw into the query, so the generated SOQL is injection-safe.
 */
public with sharing class ArchivePolicyEngineHelper {
    public class PolicyException extends Exception {}

    /** A ready-to-run dynamic query: the SOQL string plus its typed bind variables. */
    public class QueryPlan {
        public String soql;
        public Map<String, Object> binds;
        public QueryPlan(String soql, Map<String, Object> binds) {
            this.soql = soql;
            this.binds = binds;
        }
    }

    // Condition operator -> SOQL comparison symbol (Contains, In, Relative Date handled specially).
    private static final Map<String, String> OPERATOR_SYMBOLS = new Map<String, String>{
        'Equals' => '=',
        'Not Equals' => '!=',
        'Greater Than' => '>',
        'Less Than' => '<',
        'Greater Or Equal' => '>=',
        'Less Or Equal' => '<='
    };
    private static final Set<String> RELATIVE_FUNCTIONS = new Set<String>{
        'N_DAYS_AGO', 'LAST_N_DAYS', 'LAST_N_WEEKS', 'LAST_N_MONTHS', 'LAST_N_YEARS'
    };

    /**
     * Builds a `SELECT Id` query plan for the Batch QueryLocator.
     * @param targetObject API name of the object to archive from.
     * @param conditions The policy's conditions (any order; Sequence drives filter logic).
     * @param filterLogic Boolean expression over sequence numbers, or blank to AND all conditions.
     * @return A QueryPlan whose SOQL selects matching record Ids.
     */
    public static QueryPlan buildQueryPlan(
        String targetObject, List<Archive_Policy_Condition__c> conditions, String filterLogic
    ) {
        return buildPlan(targetObject, conditions, filterLogic, 'SELECT Id FROM ');
    }

    /**
     * Builds a `SELECT COUNT()` query plan for the preview.
     * @param targetObject API name of the object to archive from.
     * @param conditions The policy's conditions.
     * @param filterLogic Boolean expression over sequence numbers, or blank to AND all conditions.
     * @return A QueryPlan whose SOQL counts matching records.
     */
    public static QueryPlan buildCountPlan(
        String targetObject, List<Archive_Policy_Condition__c> conditions, String filterLogic
    ) {
        return buildPlan(targetObject, conditions, filterLogic, 'SELECT COUNT() FROM ');
    }

    /**
     * Resolves and validates an object API name against the org schema.
     * @param apiName The object API name.
     * @return Its describe result.
     * @throws PolicyException when blank or unknown.
     */
    public static Schema.DescribeSObjectResult describeObject(String apiName) {
        if (String.isBlank(apiName)) {
            throw new PolicyException('A target object is required.');
        }
        SObjectType token = Schema.getGlobalDescribe().get(apiName);
        if (token == null) {
            throw new PolicyException('Unknown object: ' + apiName);
        }
        return token.getDescribe();
    }

    private static QueryPlan buildPlan(
        String targetObject, List<Archive_Policy_Condition__c> conditions,
        String filterLogic, String selectPrefix
    ) {
        Schema.DescribeSObjectResult describe = describeObject(targetObject);
        Map<String, Object> binds = new Map<String, Object>();
        Map<Integer, String> clausesBySequence = new Map<Integer, String>();

        Integer index = 0;
        for (Archive_Policy_Condition__c condition : (conditions == null ? new List<Archive_Policy_Condition__c>() : conditions)) {
            Integer sequence = (condition.Sequence__c == null) ? (index + 1) : condition.Sequence__c.intValue();
            clausesBySequence.put(sequence, buildClause(describe, condition, 'bind' + index, binds));
            index++;
        }

        String whereClause = buildWhere(clausesBySequence, filterLogic);
        String soql = selectPrefix + describe.getName()
            + (String.isBlank(whereClause) ? '' : ' WHERE ' + whereClause);
        return new QueryPlan(soql, binds);
    }

    private static String buildClause(
        Schema.DescribeSObjectResult describe, Archive_Policy_Condition__c condition,
        String bindKey, Map<String, Object> binds
    ) {
        if (String.isBlank(condition.Field_API_Name__c)) {
            throw new PolicyException('A condition is missing its field API name.');
        }
        Schema.SObjectField token = describe.fields.getMap().get(condition.Field_API_Name__c.toLowerCase());
        if (token == null) {
            throw new PolicyException('Unknown field "' + condition.Field_API_Name__c + '" on ' + describe.getName() + '.');
        }
        Schema.DescribeFieldResult field = token.getDescribe();
        if (!field.isAccessible()) {
            throw new PolicyException('You do not have access to the field "' + field.getName() + '".');
        }
        String fieldName = field.getName(); // real, correctly-cased API name (allowlisted)
        String operator = condition.Operator__c;

        if (operator == 'Relative Date') {
            if (field.getType() != Schema.DisplayType.DATE && field.getType() != Schema.DisplayType.DATETIME) {
                throw new PolicyException('Relative Date can only be used on a Date or Date/Time field ("' + fieldName + '").');
            }
            return fieldName + ' < ' + relativeLiteral(condition.Relative_Function__c, condition.Value__c);
        }
        if (operator == 'Contains') {
            binds.put(bindKey, '%' + (condition.Value__c == null ? '' : condition.Value__c) + '%');
            return fieldName + ' LIKE :' + bindKey;
        }
        if (operator == 'In') {
            List<String> placeholders = new List<String>();
            Integer i = 0;
            for (String part : (condition.Value__c == null ? new List<String>() : condition.Value__c.split(','))) {
                String key = bindKey + '_' + i;
                binds.put(key, coerce(field.getType(), part.trim()));
                placeholders.add(':' + key);
                i++;
            }
            if (placeholders.isEmpty()) {
                throw new PolicyException('The In operator needs at least one value.');
            }
            return fieldName + ' IN (' + String.join(placeholders, ', ') + ')';
        }

        String symbol = OPERATOR_SYMBOLS.get(operator);
        if (symbol == null) {
            throw new PolicyException('Unsupported operator "' + operator + '".');
        }
        binds.put(bindKey, coerce(field.getType(), condition.Value__c));
        return fieldName + ' ' + symbol + ' :' + bindKey;
    }

    private static String relativeLiteral(String function, String value) {
        if (String.isBlank(function) || !RELATIVE_FUNCTIONS.contains(function)) {
            throw new PolicyException('Invalid relative date function: ' + function);
        }
        if (String.isBlank(value) || !Pattern.matches('\\d+', value.trim())) {
            throw new PolicyException('A relative date value must be a whole number (e.g. 60).');
        }
        return function + ':' + value.trim();
    }

    private static Object coerce(Schema.DisplayType fieldType, String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        switch on fieldType {
            when INTEGER, LONG {
                return Long.valueOf(trimmed);
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Double.valueOf(trimmed);
            }
            when DATE {
                return Date.valueOf(trimmed);
            }
            when DATETIME {
                return (Datetime) JSON.deserialize('"' + trimmed + '"', Datetime.class);
            }
            when BOOLEAN {
                return Boolean.valueOf(trimmed);
            }
            when else {
                return trimmed;
            }
        }
    }

    /**
     * Assembles the WHERE body. With blank filter logic, all clauses are ANDed in sequence order.
     * Otherwise the logic string is tokenized to digits / AND / OR / parentheses only, each digit is
     * replaced by its parenthesized clause, and anything else is rejected.
     */
    private static String buildWhere(Map<Integer, String> clausesBySequence, String filterLogic) {
        if (clausesBySequence.isEmpty()) {
            return '';
        }
        if (String.isBlank(filterLogic)) {
            List<Integer> sequences = new List<Integer>(clausesBySequence.keySet());
            sequences.sort();
            List<String> clauses = new List<String>();
            for (Integer sequence : sequences) {
                clauses.add(clausesBySequence.get(sequence));
            }
            return String.join(clauses, ' AND ');
        }

        String compact = filterLogic.toUpperCase();
        Matcher matcher = Pattern.compile('\\d+|AND|OR|\\(|\\)').matcher(compact);
        List<String> output = new List<String>();
        Integer lastEnd = 0;
        while (matcher.find()) {
            if (compact.substring(lastEnd, matcher.start()).trim() != '') {
                throw new PolicyException('Invalid filter logic expression.');
            }
            String tokenValue = matcher.group();
            if (tokenValue == 'AND' || tokenValue == 'OR' || tokenValue == '(' || tokenValue == ')') {
                output.add(tokenValue);
            } else {
                Integer sequence = Integer.valueOf(tokenValue);
                if (!clausesBySequence.containsKey(sequence)) {
                    throw new PolicyException('Filter logic references condition ' + sequence + ', which does not exist.');
                }
                output.add('(' + clausesBySequence.get(sequence) + ')');
            }
            lastEnd = matcher.end();
        }
        if (compact.substring(lastEnd).trim() != '') {
            throw new PolicyException('Invalid filter logic expression.');
        }
        return String.join(output, ' ');
    }
}
