/**
 * Tests for ArchivePolicyEngineHelper — dynamic SOQL generation, bind typing, relative-date
 * literals, filter-logic parsing, and the security/validation guards. Runs a real COUNT against
 * seeded Archive_Source__c data (no Big Object DML), so it is fully deterministic.
 */
@isTest
private class ArchivePolicyEngineHelperTest {
    @TestSetup
    static void setupTestData() {
        // Amounts 100,101,102,103,104.
        TestDataFactory.createArchiveSources(5, true);
    }

    private static Archive_Policy_Condition__c condition(
        Decimal sequence, String field, String operator, String value, String relativeFunction
    ) {
        return new Archive_Policy_Condition__c(
            Sequence__c = sequence,
            Field_API_Name__c = field,
            Operator__c = operator,
            Value__c = value,
            Relative_Function__c = relativeFunction
        );
    }

    @isTest
    static void buildQueryPlan_SimpleComparison_BindsValue() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'Amount__c', 'Greater Than', '101', null)
        };

        Test.startTest();
        ArchivePolicyEngineHelper.QueryPlan plan =
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, null);
        Test.stopTest();

        Assert.isTrue(plan.soql.contains('Amount__c > :bind0'), 'Clause should use a bind variable: ' + plan.soql);
        Assert.isTrue(plan.soql.startsWith('SELECT Id FROM Archive_Source__c WHERE'), 'Should be a SELECT Id query: ' + plan.soql);
        Assert.areEqual(1, plan.binds.size(), 'One bind expected.');
        Assert.areEqual(101.0, (Double) plan.binds.get('bind0'), 'Value should be coerced to a number.');
    }

    @isTest
    static void buildCountPlan_RunsAgainstSeededData() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'Amount__c', 'Greater Than', '101', null)
        };

        Test.startTest();
        ArchivePolicyEngineHelper.QueryPlan plan =
            ArchivePolicyEngineHelper.buildCountPlan('Archive_Source__c', conditions, null);
        Integer count = Database.countQueryWithBinds(plan.soql, plan.binds, AccessLevel.USER_MODE);
        Test.stopTest();

        Assert.areEqual(3, count, 'Amounts 102, 103, 104 should match (> 101).');
    }

    @isTest
    static void buildQueryPlan_FilterLogicOr_BuildsExpression() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'Amount__c', 'Equals', '100', null),
            condition(2, 'Amount__c', 'Equals', '104', null)
        };

        Test.startTest();
        ArchivePolicyEngineHelper.QueryPlan plan =
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, '1 OR 2');
        Integer count = Database.countQueryWithBinds(
            ArchivePolicyEngineHelper.buildCountPlan('Archive_Source__c', conditions, '1 OR 2').soql,
            ArchivePolicyEngineHelper.buildCountPlan('Archive_Source__c', conditions, '1 OR 2').binds,
            AccessLevel.USER_MODE
        );
        Test.stopTest();

        Assert.isTrue(plan.soql.contains(' OR '), 'Filter logic OR should appear: ' + plan.soql);
        Assert.areEqual(2, count, 'Exactly the 100 and 104 records should match.');
    }

    @isTest
    static void buildQueryPlan_RelativeDate_InlinesLiteral() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'CreatedDate', 'Relative Date', '30', 'LAST_N_DAYS')
        };

        Test.startTest();
        ArchivePolicyEngineHelper.QueryPlan plan =
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, null);
        Test.stopTest();

        Assert.isTrue(plan.soql.contains('CreatedDate < LAST_N_DAYS:30'), 'Relative literal expected: ' + plan.soql);
        Assert.isTrue(plan.binds.isEmpty(), 'Relative literals are inlined, not bound.');
    }

    @isTest
    static void buildQueryPlan_UnknownField_Throws() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'Not_A_Field__c', 'Equals', 'x', null)
        };

        Test.startTest();
        try {
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, null);
            Assert.fail('Expected a PolicyException for an unknown field.');
        } catch (ArchivePolicyEngineHelper.PolicyException e) {
            Assert.isTrue(e.getMessage().contains('Unknown field'), 'Should name the unknown field: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void buildQueryPlan_RelativeDateNonNumeric_Throws() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'CreatedDate', 'Relative Date', 'sixty', 'LAST_N_DAYS')
        };

        Test.startTest();
        try {
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, null);
            Assert.fail('Expected a PolicyException for a non-numeric relative value.');
        } catch (ArchivePolicyEngineHelper.PolicyException e) {
            Assert.isNotNull(e.getMessage(), 'A message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void buildQueryPlan_InvalidFilterLogic_Throws() {
        List<Archive_Policy_Condition__c> conditions = new List<Archive_Policy_Condition__c>{
            condition(1, 'Amount__c', 'Equals', '100', null)
        };

        Test.startTest();
        try {
            ArchivePolicyEngineHelper.buildQueryPlan('Archive_Source__c', conditions, '1 AND DROP');
            Assert.fail('Expected a PolicyException for invalid filter logic.');
        } catch (ArchivePolicyEngineHelper.PolicyException e) {
            Assert.isNotNull(e.getMessage(), 'A message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void describeObject_Unknown_Throws() {
        Test.startTest();
        try {
            ArchivePolicyEngineHelper.describeObject('No_Such_Object__x');
            Assert.fail('Expected a PolicyException for an unknown object.');
        } catch (ArchivePolicyEngineHelper.PolicyException e) {
            Assert.isNotNull(e.getMessage(), 'A message should be present.');
        }
        Test.stopTest();
    }
}
