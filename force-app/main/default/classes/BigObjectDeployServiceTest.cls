/**
 * Tests for BigObjectDeployService's field-name normalization. The deploy itself is callout-bound
 * (Metadata API SOAP) and not unit-tested here; this locks in the naming rules that decide whether
 * a deploy can even succeed — in particular, managed-package (namespaced) source fields.
 */
@isTest
private class BigObjectDeployServiceTest {
    @isTest
    static void toBigObjectFieldName_HandlesStandardCustomAndNamespaced() {
        // Standard field -> add __c.
        Assert.areEqual('Subject__c', BigObjectDeployService.toBigObjectFieldName('Subject'),
            'Standard fields should get a __c suffix.');
        // Local custom field -> unchanged.
        Assert.areEqual('Amount__c', BigObjectDeployService.toBigObjectFieldName('Amount__c'),
            'Local custom fields should be unchanged.');
        // Managed-package (namespaced) field -> collapse the namespace separator so it can be
        // created in THIS org's namespace (pi__score__c -> pi_score__c).
        Assert.areEqual('pi_score__c', BigObjectDeployService.toBigObjectFieldName('pi__score__c'),
            'Namespaced managed fields must collapse the namespace separator.');
        Assert.areEqual('et4ae5_HasOptedOutOfMobile__c',
            BigObjectDeployService.toBigObjectFieldName('et4ae5__HasOptedOutOfMobile__c'),
            'Longer namespaces should collapse too.');
    }

    @isTest
    static void sanitizeApiName_ProducesDeploySafeNames() {
        // Space -> underscore (the "Lead_Archive_test 1__b" failure).
        Assert.areEqual('Lead_Archive_test_1__b',
            BigObjectDeployService.sanitizeApiName('Lead_Archive_test 1__b', '__b'),
            'Spaces must become underscores.');
        // Punctuation -> underscore, collapsed.
        Assert.areEqual('A_B_C__c', BigObjectDeployService.sanitizeApiName('A & B / C', '__c'),
            'Punctuation collapses to single underscores.');
        // Leading digits + space stripped so the name begins with a letter.
        Assert.areEqual('Thing__c', BigObjectDeployService.sanitizeApiName('99 Thing', '__c'),
            'Leading digits/spaces are stripped so the name starts with a letter.');
        // Trailing underscore stripped before the suffix.
        Assert.areEqual('Name__c', BigObjectDeployService.sanitizeApiName('Name_', '__c'),
            'Trailing underscores are stripped.');
        // Blank -> safe fallback.
        Assert.areEqual('X__b', BigObjectDeployService.sanitizeApiName('   ', '__b'),
            'Blank input falls back to a valid name.');
        // Idempotent: a clean name is unchanged.
        Assert.areEqual('Account_Archive__b',
            BigObjectDeployService.sanitizeApiName('Account_Archive__b', '__b'),
            'A valid name should be unchanged (idempotent).');
        // 40-char base cap.
        String longBase = 'A'.repeat(60);
        String result = BigObjectDeployService.sanitizeApiName(longBase, '__c');
        Assert.areEqual(43, result.length(), 'Base is capped at 40 chars plus the 3-char suffix.');
    }
}
