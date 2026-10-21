/**
 * Tests for BigObjectAdminController. Metrics/inventory derive from Big_Object_Archive_Log__c
 * (a normal object) and the Count Cache / Config custom settings — all deterministic, no Big
 * Object row reads. The Archive_Record__b fixture guarantees at least one Big Object exists.
 */
@isTest
private class BigObjectAdminControllerTest {

    // ---- Dashboard metrics -------------------------------------------------

    @isTest
    static void shouldReturnMetrics_WhenLogsExist() {
        TestDataFactory.createArchiveLogs(3, 'Success', true);
        TestDataFactory.createArchiveLogs(2, 'Failed', true);

        Test.startTest();
        BigObjectAdminController.DashboardMetrics metrics =
            BigObjectAdminController.getDashboardMetrics();
        Test.stopTest();

        Assert.areEqual(3, metrics.totalArchived, 'Total archived should count only Success logs');
        Assert.areEqual(2, metrics.failedCount, 'Failed count should count only Failed logs');
        Assert.isTrue(metrics.totalBigObjects >= 1,
            'At least the Archive_Record__b fixture should be counted');
        Assert.areEqual(5, metrics.recentActivity.size(),
            'Recent activity should list all five log rows (under the limit of 10)');
    }

    @isTest
    static void shouldComputeUsagePercent_WhenLimitConfigured() {
        BigObjectAdminController.saveAdminConfig(100L, false);
        TestDataFactory.createArchiveLogs(3, 'Success', true);

        Test.startTest();
        BigObjectAdminController.DashboardMetrics metrics =
            BigObjectAdminController.getDashboardMetrics();
        Test.stopTest();

        Assert.areEqual(100, metrics.recordLimit, 'Configured record limit should be used');
        Assert.areEqual(3.00, metrics.usagePercent, '3 of 100 should be 3.00%');
    }

    @isTest
    static void shouldCountAll_WhenBulkLogs() {
        TestDataFactory.createArchiveLogs(251, 'Success', true);

        Test.startTest();
        BigObjectAdminController.DashboardMetrics metrics =
            BigObjectAdminController.getDashboardMetrics();
        Test.stopTest();

        Assert.areEqual(251, metrics.totalArchived,
            'All 251 success logs should be counted (bulk-safe aggregate)');
    }

    // ---- Inventory ---------------------------------------------------------

    @isTest
    static void shouldListInventory_WhenBigObjectExists() {
        Test.startTest();
        List<BigObjectAdminController.BigObjectInventory> inventory =
            BigObjectAdminController.getBigObjectInventory();
        Test.stopTest();

        Assert.isFalse(inventory.isEmpty(), 'At least one Big Object should be inventoried');
        Boolean foundFixture = false;
        for (BigObjectAdminController.BigObjectInventory item : inventory) {
            if (item.apiName == 'Archive_Record__b') {
                foundFixture = true;
                Assert.isTrue(item.indexFields.contains('Record_Key__c'),
                    'Fixture Big Object should report its index field');
                Assert.isNotNull(item.setupUrl, 'Inventory should include a Setup deep link');
            }
        }
        Assert.isTrue(foundFixture, 'The Archive_Record__b fixture should appear in inventory');
    }

    @isTest
    static void shouldRefreshCounts_WhenCalled() {
        TestDataFactory.createArchiveLogs(5, 'Success', true); // Target_Big_Object__c = Account_Archive__b

        Test.startTest();
        BigObjectAdminController.refreshRecordCounts();
        Test.stopTest();

        Map<String, Big_Object_Count_Cache__c> cache = Big_Object_Count_Cache__c.getAll();
        Assert.isTrue(cache.containsKey('Account_Archive__b'),
            'A cache row should be created for the aggregated target Big Object');
        Assert.areEqual(5, cache.get('Account_Archive__b').Record_Count__c.intValue(),
            'Cached count should equal the number of success logs for that target');
    }

    // ---- Admin config ------------------------------------------------------

    @isTest
    static void shouldReturnDefaults_WhenNoAdminConfig() {
        Test.startTest();
        BigObjectAdminController.AdminConfig config = BigObjectAdminController.getAdminConfig();
        Test.stopTest();

        Assert.areEqual(1000000L, config.recordLimit,
            'Record limit should default to 1,000,000 when unset');
        Assert.isFalse(config.autoDeleteSource, 'Auto-delete should default to false');
    }

    @isTest
    static void shouldPersistConfig_WhenSaved() {
        Test.startTest();
        BigObjectAdminController.saveAdminConfig(500000L, true);
        Test.stopTest();

        BigObjectAdminController.AdminConfig config = BigObjectAdminController.getAdminConfig();
        Assert.areEqual(500000L, config.recordLimit, 'Saved record limit should be returned');
        Assert.isTrue(config.autoDeleteSource, 'Saved auto-delete flag should be returned');
    }

    // ---- Archive settings --------------------------------------------------

    @isTest
    static void shouldPersistSetting_WhenSaved() {
        Test.startTest();
        BigObjectAdminController.saveArchiveSetting('Account', true, 'Account_Archive__b', false);
        Test.stopTest();

        List<Big_Object_Archive_Setting__c> settings = BigObjectAdminController.getArchiveSettings();
        Boolean found = false;
        for (Big_Object_Archive_Setting__c s : settings) {
            if (s.Name == 'Account') {
                found = true;
                Assert.isTrue(s.Enabled__c, 'Saved setting should be enabled');
                Assert.areEqual('Account_Archive__b', s.Target_Big_Object__c,
                    'Saved setting should retain its target Big Object');
            }
        }
        Assert.isTrue(found, 'The saved archive setting should be returned');
    }

    @isTest
    static void shouldThrowAuraHandled_WhenArchiveSettingObjectBlank() {
        Test.startTest();
        try {
            BigObjectAdminController.saveArchiveSetting('', true, 'X__b', false);
            Assert.fail('Expected AuraHandledException for a blank object API name');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'A blank object API name should be rejected');
        }
        Test.stopTest();
    }
}
