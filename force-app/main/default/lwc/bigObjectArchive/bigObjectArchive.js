import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import archiveAndDeleteRecord from '@salesforce/apex/BigObjectArchiveService.archiveAndDeleteRecord';
import archiveRecord from '@salesforce/apex/BigObjectArchiveService.archiveRecord';
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

    // Backup: copy the record into the Big Object WITHOUT deleting the source record.
    handleBackup() {
        if (!this.selectedBigObject) {
            return;
        }
        const target = this.selectedBigObject;
        this.isWorking = true;
        archiveRecord({ recordId: this.recordId, targetBigObjectApiName: target })
            .then((result) => {
                if (result && result.isSuccess) {
                    this.showToast('Backed up', `Record copied to ${target}. The source record was kept.`, 'success');
                } else {
                    this.showToast(
                        'Backup failed',
                        result && result.errorMessage ? result.errorMessage : 'Backup failed.',
                        'error'
                    );
                }
            })
            .catch((error) => this.showToast('Backup failed', this.reduceError(error), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
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
