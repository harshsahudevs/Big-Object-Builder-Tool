import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import archiveAndDeleteRecord from '@salesforce/apex/BigObjectArchiveService.archiveAndDeleteRecord';
import archiveRecordWithRelated from '@salesforce/apex/RecordArchivingEngine.archiveRecordWithRelated';
import getMappingOverview from '@salesforce/apex/BigObjectSettingsController.getMappingOverview';

export default class BigObjectArchive extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    isLoading = true;
    isWorking = false; // an archive or backup is running
    showConfirm = false; // archive + delete confirmation modal
    targets = []; // [{ label, value, status, isPartial }]
    selectedBigObject;
    error;

    // Result of the last whole-record archive (per-object counts + skipped related objects).
    resultSummaries = [];
    skippedObjects = [];
    hasResult = false;

    connectedCallback() {
        this.loadTargets();
    }

    // Load only the Big Objects relevant to THIS record's object: mapped from this source object.
    // Unmapped Big Objects are hidden; partially mapped ones are shown with a warning.
    loadTargets() {
        this.isLoading = true;
        getMappingOverview()
            .then((data) => {
                const relevant = (data || []).filter(
                    (o) => o.sourceObject === this.objectApiName && o.status !== 'Unmapped'
                );
                this.targets = relevant.map((o) => ({
                    label: `${o.label} (${o.apiName})`,
                    value: o.apiName,
                    status: o.status,
                    isPartial: o.status === 'Partial'
                }));
                if (this.targets.length) {
                    const match = this.targets.find((t) => t.value === this.suggestedBigObject);
                    this.selectedBigObject = match ? match.value : this.targets[0].value;
                }
                this.error = undefined;
            })
            .catch((e) => {
                this.error = this.reduceError(e);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    // Conventional default (e.g. Lead -> Lead_Archive__b); used only to preselect the dropdown.
    get suggestedBigObject() {
        const base = (this.objectApiName || '').replace(/__c$/, '');
        return `${base}_Archive__b`;
    }

    get hasTargets() {
        return this.targets.length > 0;
    }

    get noTargets() {
        return !this.isLoading && !this.error && this.targets.length === 0;
    }

    get selectedTarget() {
        return this.targets.find((t) => t.value === this.selectedBigObject);
    }

    get selectedIsPartial() {
        return !!(this.selectedTarget && this.selectedTarget.isPartial);
    }

    get actionsDisabled() {
        return this.isWorking || !this.selectedBigObject;
    }

    handleBigObjectChange(event) {
        this.selectedBigObject = event.detail.value;
    }

    // Whole-record archive via the Record Archiving Engine: archives this record AND its direct
    // related child records (each into its own Big Object). Source records are kept (no delete).
    handleBackup() {
        if (!this.selectedBigObject) {
            return;
        }
        const target = this.selectedBigObject;
        this.isWorking = true;
        this.hasResult = false;
        archiveRecordWithRelated({ rootRecordId: this.recordId, rootBigObjectApiName: target })
            .then((result) => {
                this.applyResult(result);
                const archived = result ? result.totalArchived : 0;
                const failed = result ? result.totalFailed : 0;
                const objects = result && result.summaries ? result.summaries.length : 0;
                if (failed === 0) {
                    this.showToast(
                        'Archived',
                        `${archived} record${archived === 1 ? '' : 's'} archived across ${objects} object${objects === 1 ? '' : 's'} (record + related). Source records kept.`,
                        'success'
                    );
                } else {
                    this.showToast(
                        'Archived with issues',
                        `${archived} archived, ${failed} failed. See the result breakdown below.`,
                        archived === 0 ? 'error' : 'warning'
                    );
                }
            })
            .catch((error) => this.showToast('Archive failed', this.reduceError(error), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    // Flattens the engine result into display rows for the result panel.
    applyResult(result) {
        const summaries = (result && result.summaries) || [];
        this.resultSummaries = summaries.map((s) => ({
            key: s.sourceObject,
            label: `${s.sourceLabel || s.sourceObject}${s.isRoot ? ' (this record)' : ''}`,
            bigObject: s.bigObject,
            detail: `${s.archivedCount} archived${s.failedCount ? `, ${s.failedCount} failed` : ''}`,
            hasError: s.failedCount > 0,
            errorMessage: s.errorMessage
        }));
        this.skippedObjects = (result && result.skippedObjects) || [];
        this.hasResult = this.resultSummaries.length > 0 || this.skippedObjects.length > 0;
    }

    get hasSkipped() {
        return this.skippedObjects && this.skippedObjects.length > 0;
    }

    get skippedLabel() {
        return this.skippedObjects.join(', ');
    }

    handleArchiveClick() {
        this.showConfirm = true;
    }

    handleCancel() {
        this.showConfirm = false;
    }

    // Archive + delete: copy the record into the Big Object, then remove it from the source object.
    handleConfirm() {
        if (!this.selectedBigObject) {
            this.showToast('Select a Big Object', 'Choose a target Big Object first.', 'warning');
            return;
        }
        const target = this.selectedBigObject;
        this.isWorking = true;
        archiveAndDeleteRecord({ recordId: this.recordId, targetBigObjectApiName: target })
            .then((result) => {
                if (result && result.isSuccess) {
                    const message = result.sourceDeleted
                        ? `Record archived to ${target} and deleted.`
                        : `Record archived to ${target}. (Source delete did not complete.)`;
                    this.showToast('Archived', message, 'success');
                    this.showConfirm = false;
                    if (result.sourceDeleted) {
                        this.navigateToList();
                    }
                } else {
                    this.showToast(
                        'Archive failed',
                        result && result.errorMessage ? result.errorMessage : 'Archive failed.',
                        'error'
                    );
                }
            })
            .catch((error) => {
                this.showToast('Archive failed', this.reduceError(error), 'error');
            })
            .finally(() => {
                this.isWorking = false;
            });
    }

    navigateToList() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: this.objectApiName, actionName: 'list' }
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
