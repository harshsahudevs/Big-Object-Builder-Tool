import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import restoreRecord from '@salesforce/apex/BigObjectArchiveService.restoreRecord';

/**
 * Reusable Restore control: a button that opens a confirmation modal and restores one archived
 * Big Object row back to its source object. Embedded by the Detail page and the Related List.
 * Fires a `restored` event (detail: { restoredRecordId, recordKey }) on success.
 */
export default class RestoreArchivedRecord extends NavigationMixin(LightningElement) {
    @api bigObjectApiName;
    @api sourceObjectApiName;
    @api recordKey;
    @api deleteFromBigObject = false; // also remove the Big Object row after a successful restore
    @api buttonLabel = 'Restore';
    @api buttonVariant = 'brand';
    @api disabled = false; // caller sets true when the user lacks access / action not allowed

    showModal = false;
    isProcessing = false;

    get isButtonDisabled() {
        return this.disabled || this.isProcessing;
    }

    get confirmMessage() {
        return this.deleteFromBigObject
            ? 'This recreates the record in its original object and removes it from the archive. Continue?'
            : 'This recreates the record in its original object. The archived copy is kept. Continue?';
    }

    openModal() {
        if (!this.isButtonDisabled) {
            this.showModal = true;
        }
    }

    closeModal() {
        if (!this.isProcessing) {
            this.showModal = false;
        }
    }

    handleConfirm() {
        // Guard against double-submission while the Apex call is in flight.
        if (this.isProcessing) {
            return;
        }
        this.isProcessing = true;

        restoreRecord({
            bigObjectApiName: this.bigObjectApiName,
            sourceObjectApiName: this.sourceObjectApiName,
            recordKey: this.recordKey,
            deleteFromBigObject: this.deleteFromBigObject
        })
            .then((result) => {
                if (result && result.isSuccess) {
                    this.notifySuccess(result.restoredRecordId);
                    this.dispatchEvent(
                        new CustomEvent('restored', {
                            detail: { restoredRecordId: result.restoredRecordId, recordKey: this.recordKey }
                        })
                    );
                } else {
                    this.notifyError(result ? result.errorMessage : 'Restore did not complete.');
                }
            })
            .catch((error) => {
                this.notifyError(this.reduceError(error));
            })
            .finally(() => {
                this.isProcessing = false;
                this.showModal = false;
            });
    }

    notifySuccess(restoredRecordId) {
        const url = `/${restoredRecordId}`;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Record restored',
                message: 'The record was recreated. {0}',
                messageData: [{ url, label: 'Open restored record' }],
                variant: 'success'
            })
        );
    }

    notifyError(message) {
        this.dispatchEvent(
            new ShowToastEvent({ title: 'Restore failed', message, variant: 'error' })
        );
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
