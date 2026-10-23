/**
 * Schedulable entry point for Archive Policies. Scheduled per policy via System.schedule with the
 * CRON expression the controller generates on activation; each firing submits the policy's batch.
 * Constructed with no argument it runs every Active policy (useful for a single org-wide schedule).
 */
public with sharing class ArchivePolicyScheduler implements Schedulable {
    private final Id policyId;

    /** Runs every Active policy when fired. */
    public ArchivePolicyScheduler() {
        this.policyId = null;
    }

    /**
     * Runs a single policy when fired.
     * @param policyId The policy this schedule drives.
     */
    public ArchivePolicyScheduler(Id policyId) {
        this.policyId = policyId;
    }

    public void execute(SchedulableContext context) {
        if (policyId != null) {
            submit(policyId);
            return;
        }
        for (Archive_Policy__c policy : [
            SELECT Id FROM Archive_Policy__c WHERE Status__c = 'Active' WITH USER_MODE
        ]) {
            submit(policy.Id);
        }
    }

    private void submit(Id targetPolicyId) {
        List<Archive_Policy__c> policies = [
            SELECT Id, Action_Type__c, Cascade_Children__c, Batch_Size__c
            FROM Archive_Policy__c
            WHERE Id = :targetPolicyId
            WITH USER_MODE
            LIMIT 1
        ];
        if (policies.isEmpty()) {
            return;
        }
        Database.executeBatch(
            new ArchivePolicyBatch(targetPolicyId, 'Scheduled'),
            ArchivePolicyBatch.scopeSizeFor(policies[0])
        );
    }
}
