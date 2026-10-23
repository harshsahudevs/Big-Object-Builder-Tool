/**
 * Tests for ArchivePolicyController — object/field metadata, save/load round-trip, safe preview
 * COUNT, Run Now (end-to-end Soft Delete), activate/deactivate scheduling, execution-log read, and
 * CRON generation. No Big Object DML, so everything runs deterministically in test context.
 */
@isTest
private class ArchivePolicyControllerTest {
    @TestSetup
    static void setupTestData() {
        TestDataFactory.createArchiveSources(5, true); // Amounts 100..104
    }

    private static String conditionsJson() {
        return JSON.serialize(new List<Archive_Policy_Condition__c>{
            new Archive_Policy_Condition__c(
                Sequence__c = 1, Field_API_Name__c = 'Amount__c',
                Operator__c = 'Greater Or Equal', Value__c = '100')
        });
    }

    private static Id saveSoftDeletePolicy(String name) {
        Archive_Policy__c policy = new Archive_Policy__c(
            Name = name, Target_Object__c = 'Archive_Source__c', Action_Type__c = 'Soft Delete',
            Batch_Size__c = 200, Status__c = 'Draft');
        return ArchivePolicyController.savePolicy(JSON.serialize(policy), conditionsJson());
    }

    @isTest
    static void getObjectOptions_ReturnsArchivableObjects() {
        Test.startTest();
        List<ArchivePolicyController.Option> options = ArchivePolicyController.getObjectOptions();
        Test.stopTest();

        Assert.isFalse(options.isEmpty(), 'Object options should not be empty.');
        Boolean found = false;
        for (ArchivePolicyController.Option option : options) {
            if (option.value == 'Archive_Source__c') {
                found = true;
            }
        }
        Assert.isTrue(found, 'The archivable Archive_Source__c object should be listed.');
    }

    @isTest
    static void getObjectOptions_ExcludesBigObjectsAndSystemEntities() {
        Test.startTest();
        List<ArchivePolicyController.Option> options = ArchivePolicyController.getObjectOptions();
        Test.stopTest();

        for (ArchivePolicyController.Option option : options) {
            String name = option.value.toLowerCase();
            Assert.isFalse(name.endsWith('__b'), 'Big Objects must be excluded: ' + option.value);
            Assert.isFalse(name.endsWith('__mdt'), 'Custom metadata types must be excluded: ' + option.value);
            Assert.isFalse(name.endsWith('__e'), 'Platform events must be excluded: ' + option.value);
            Assert.isFalse(name.endsWith('changeevent'), 'Change events must be excluded: ' + option.value);
        }
    }

    @isTest
    static void getBigObjectsForSource_ReturnsMappedOnly() {
        insert new Big_Object_Field_Mapping__c(
            Source_Object__c = 'Archive_Source__c',
            Big_Object__c = 'Archive_Record__b',
            Source_Field__c = 'Amount__c',
            Big_Object_Field__c = 'Amount__c'
        );

        Test.startTest();
        List<ArchivePolicyController.Option> mapped = ArchivePolicyController.getBigObjectsForSource('Archive_Source__c');
        List<ArchivePolicyController.Option> none = ArchivePolicyController.getBigObjectsForSource('Contact');
        Test.stopTest();

        Assert.areEqual(1, mapped.size(), 'Exactly the mapped Big Object should be returned.');
        Assert.areEqual('Archive_Record__b', mapped[0].value, 'The mapped Big Object should be returned.');
        Assert.isTrue(none.isEmpty(), 'An unmapped source should return no Big Objects.');
    }

    @isTest
    static void getPicklistValues_ReturnsActiveValues_EmptyForNonPicklist() {
        Test.startTest();
        List<ArchivePolicyController.Option> statusValues =
            ArchivePolicyController.getPicklistValues('Archive_Policy__c', 'Status__c');
        List<ArchivePolicyController.Option> notPicklist =
            ArchivePolicyController.getPicklistValues('Archive_Source__c', 'Amount__c');
        Test.stopTest();

        Assert.areEqual(3, statusValues.size(), 'Status has Draft/Active/Inactive.');
        Boolean hasActive = false;
        for (ArchivePolicyController.Option option : statusValues) {
            if (option.value == 'Active') {
                hasActive = true;
            }
        }
        Assert.isTrue(hasActive, 'The Active value should be present.');
        Assert.isTrue(notPicklist.isEmpty(), 'A non-picklist field should return no values.');
    }

    @isTest
    static void getFieldOptions_ReturnsFieldsWithType() {
        Test.startTest();
        List<ArchivePolicyController.Option> options = ArchivePolicyController.getFieldOptions('Archive_Source__c');
        Test.stopTest();

        Boolean foundAmount = false;
        for (ArchivePolicyController.Option option : options) {
            if (option.value == 'Amount__c') {
                foundAmount = true;
                Assert.isNotNull(option.type, 'Field options should carry a type.');
            }
        }
        Assert.isTrue(foundAmount, 'Amount__c should be listed for Archive_Source__c.');
    }

    @isTest
    static void savePolicy_And_GetPolicy_RoundTrips() {
        Test.startTest();
        Id policyId = saveSoftDeletePolicy('Round Trip');
        ArchivePolicyController.PolicyDetail detail = ArchivePolicyController.getPolicy(policyId);
        Test.stopTest();

        Assert.areEqual('Round Trip', detail.policy.Name, 'Policy name should round-trip.');
        Assert.areEqual(1, detail.conditions.size(), 'The one saved condition should load.');
        Assert.areEqual('Amount__c', detail.conditions[0].Field_API_Name__c, 'Condition field should round-trip.');
    }

    @isTest
    static void savePolicy_ReplacesConditions() {
        Id policyId = saveSoftDeletePolicy('Replace');
        Archive_Policy__c reload = [SELECT Id, Name, Target_Object__c, Action_Type__c FROM Archive_Policy__c WHERE Id = :policyId];

        Test.startTest();
        // Save again with NO conditions — the previously saved condition must be removed.
        ArchivePolicyController.savePolicy(JSON.serialize(reload), JSON.serialize(new List<Archive_Policy_Condition__c>()));
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Archive_Policy_Condition__c WHERE Archive_Policy__c = :policyId],
            'Conditions not resubmitted should be deleted.');
    }

    @isTest
    static void getPreviewCount_CountsMatchingRecords() {
        Test.startTest();
        Integer count = ArchivePolicyController.getPreviewCount('Archive_Source__c', conditionsJson(), null);
        Test.stopTest();

        Assert.areEqual(5, count, 'All five seeded records match Amount >= 100.');
    }

    @isTest
    static void getPreviewCount_InvalidField_Throws() {
        String bad = JSON.serialize(new List<Archive_Policy_Condition__c>{
            new Archive_Policy_Condition__c(Sequence__c = 1, Field_API_Name__c = 'Nope__c', Operator__c = 'Equals', Value__c = 'x')
        });

        Test.startTest();
        try {
            ArchivePolicyController.getPreviewCount('Archive_Source__c', bad, null);
            Assert.fail('Expected an AuraHandledException for an invalid field.');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e.getMessage(), 'A user-facing message should be present.');
        }
        Test.stopTest();
    }

    @isTest
    static void getPolicies_ReturnsRowsWithConditionCount() {
        saveSoftDeletePolicy('Dashboard Row');

        Test.startTest();
        List<ArchivePolicyController.PolicyRow> rows = ArchivePolicyController.getPolicies();
        Test.stopTest();

        Assert.isFalse(rows.isEmpty(), 'At least one policy row expected.');
        Boolean found = false;
        for (ArchivePolicyController.PolicyRow row : rows) {
            if (row.name == 'Dashboard Row') {
                found = true;
                Assert.areEqual(1, row.conditionCount, 'The row should report its condition count.');
            }
        }
        Assert.isTrue(found, 'The saved policy should appear on the dashboard.');
    }

    @isTest
    static void runNow_ExecutesBatch_AndLogs() {
        Id policyId = saveSoftDeletePolicy('Run Now');

        Test.startTest();
        Id jobId = ArchivePolicyController.runNow(policyId);
        Test.stopTest();

        Assert.isNotNull(jobId, 'Run Now should return a batch job Id.');
        Assert.areEqual(5, [SELECT COUNT() FROM Archive_Source__c WHERE Is_Archived__c = true],
            'Run Now should have archived the matching records.');
        List<Archive_Execution_Log__c> logs = ArchivePolicyController.getExecutionLogs(policyId);
        Assert.isFalse(logs.isEmpty(), 'An execution log should be created.');
        Assert.areEqual('Completed', logs[0].Status__c, 'The manual run should complete.');
    }

    @isTest
    static void setActive_SchedulesThenUnschedules() {
        Id policyId = saveSoftDeletePolicy('Scheduling');

        Test.startTest();
        ArchivePolicyController.setActive(policyId, true);
        Archive_Policy__c activated = [SELECT Status__c, Scheduled_Job_Id__c FROM Archive_Policy__c WHERE Id = :policyId];
        Assert.areEqual('Active', activated.Status__c, 'Policy should be Active.');
        Assert.isNotNull(activated.Scheduled_Job_Id__c, 'A scheduled job Id should be stored.');
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :activated.Scheduled_Job_Id__c],
            'A CronTrigger should exist for the scheduled policy.');

        ArchivePolicyController.setActive(policyId, false);
        Archive_Policy__c deactivated = [SELECT Status__c, Scheduled_Job_Id__c FROM Archive_Policy__c WHERE Id = :policyId];
        Test.stopTest();

        Assert.areEqual('Inactive', deactivated.Status__c, 'Policy should be Inactive.');
        Assert.isNull(deactivated.Scheduled_Job_Id__c, 'The scheduled job Id should be cleared.');
    }

    @isTest
    static void buildCron_GeneratesExpectedExpressions() {
        Time twoThirty = Time.newInstance(2, 30, 0, 0);

        Archive_Policy__c daily = new Archive_Policy__c(Schedule_Type__c = 'Daily', Schedule_Time__c = twoThirty);
        Assert.areEqual('0 30 2 * * ?', ArchivePolicyController.buildCron(daily), 'Daily CRON mismatch.');

        Archive_Policy__c weekly = new Archive_Policy__c(Schedule_Type__c = 'Weekly', Schedule_Time__c = twoThirty, Day_Of_Week__c = 'Monday');
        Assert.areEqual('0 30 2 ? * 2', ArchivePolicyController.buildCron(weekly), 'Weekly CRON mismatch.');

        Archive_Policy__c monthly = new Archive_Policy__c(Schedule_Type__c = 'Monthly', Schedule_Time__c = twoThirty, Day_Of_Month__c = 15);
        Assert.areEqual('0 30 2 15 * ?', ArchivePolicyController.buildCron(monthly), 'Monthly CRON mismatch.');

        Archive_Policy__c cron = new Archive_Policy__c(Schedule_Type__c = 'Cron', Cron_Expression__c = '0 0 1 * * ?');
        Assert.areEqual('0 0 1 * * ?', ArchivePolicyController.buildCron(cron), 'Raw Cron should pass through.');
    }
}
