/**
 * Shared test data factory for the Big Object tool test suite.
 * Keeps record creation out of @TestSetup bodies and reusable across test classes.
 * Annotated @isTest so it never counts against production code coverage.
 */
@isTest
public class TestDataFactory {
    /**
     * Builds (and optionally inserts) Accounts with unique names.
     * @param count Number of Accounts to build.
     * @param doInsert When true, inserts the records before returning.
     * @return The built/inserted Accounts.
     */
    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(Name = 'Archive Test Account ' + i));
        }
        if (doInsert && !accounts.isEmpty()) {
            insert accounts;
        }
        return accounts;
    }

    /**
     * Builds (and optionally inserts) Archive Source fixture records with a populated
     * Record Key and Amount so they map cleanly into the Archive_Record__b Big Object.
     * @param count Number of records to build.
     * @param doInsert When true, inserts the records before returning.
     * @return The built/inserted Archive Source records.
     */
    public static List<Archive_Source__c> createArchiveSources(Integer count, Boolean doInsert) {
        List<Archive_Source__c> sources = new List<Archive_Source__c>();
        for (Integer i = 0; i < count; i++) {
            sources.add(new Archive_Source__c(
                Name = 'Archive Source ' + i,
                Record_Key__c = 'KEY-' + String.valueOf(i).leftPad(6, '0'),
                Amount__c = 100 + i
            ));
        }
        if (doInsert && !sources.isEmpty()) {
            insert sources;
        }
        return sources;
    }

    /**
     * Builds (and optionally inserts) archive log rows.
     * @param count Number of log rows to build.
     * @param status Status value (e.g. 'Success' / 'Failed').
     * @param doInsert When true, inserts the records before returning.
     * @return The built/inserted log rows.
     */
    public static List<Big_Object_Archive_Log__c> createArchiveLogs(
        Integer count, String status, Boolean doInsert
    ) {
        List<Big_Object_Archive_Log__c> logs = new List<Big_Object_Archive_Log__c>();
        for (Integer i = 0; i < count; i++) {
            logs.add(new Big_Object_Archive_Log__c(
                Source_Record_Id__c = String.valueOf(i).leftPad(18, '0'),
                Source_Object__c = 'Account',
                Target_Big_Object__c = 'Account_Archive__b',
                Status__c = status,
                Archived_By__c = UserInfo.getUserId(),
                Archived_Date__c = System.now()
            ));
        }
        if (doInsert && !logs.isEmpty()) {
            insert logs;
        }
        return logs;
    }
}
