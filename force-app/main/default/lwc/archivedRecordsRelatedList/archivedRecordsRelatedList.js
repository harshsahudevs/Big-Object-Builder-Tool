import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getArchiveHistory from '@salesforce/apex/BigObjectBrowserController.getArchiveHistory';

const COLUMNS = [
    {
        label: 'Archived Date',
        fieldName: 'archivedDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Big Object', fieldName: 'targetBigObject', type: 'text' },
    {
        label: 'Status',
        fieldName: 'status',
        type: 'text',
        cellAttributes: { class: { fieldName: 'statusClass' } }
    },
    { label: 'Archived By', fieldName: 'archivedByName', type: 'text' },
    { label: 'Error', fieldName: 'errorMessage', type: 'text', wrapText: true }
];

/**
 * Record-page related list of a record's archive history. Zero configuration: it reads the archive
 * log by the current record's Id (never a Big Object index field), so it works on any object and
 * never breaks on Big Object index/query rules.
 */
export default class ArchivedRecordsRelatedList extends LightningElement {
    @api recordId;
    @api title = 'Archived Records';

    // Legacy App Builder properties — retained only so existing record pages that still reference
    // them keep deploying. The component is now zero-config and ignores these.
    @api bigObjectApiName;
    @api relationshipField;
    @api displayFieldsCsv;
    @api pageSize;

    columns = COLUMNS;
    rows = [];
    isLoading = true;
    errorMessage;
    lastRefreshed;

    _wiredResult;

    @wire(getArchiveHistory, { recordId: '$recordId' })
    wiredHistory(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.rows = data.map((r) => ({
                ...r,
                statusClass: r.status === 'Failed' ? 'slds-text-color_error' : ''
            }));
            this.errorMessage = undefined;
            this.lastRefreshed = new Date();
            this.isLoading = false;
        } else if (error) {
            this.rows = [];
            this.errorMessage = this.reduceError(error);
            this.isLoading = false;
        }
    }

    handleRefresh() {
        if (!this._wiredResult) {
            return;
        }
        this.isLoading = true;
        refreshApex(this._wiredResult)
            .catch((error) => {
                this.errorMessage = this.reduceError(error);
            })
            .finally(() => {
                this.isLoading = false;
                this.lastRefreshed = new Date();
            });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.errorMessage && !this.hasRows;
    }

    get cardTitle() {
        return this.hasRows ? `${this.title} (${this.rows.length})` : this.title;
    }

    get lastRefreshedLabel() {
        return this.lastRefreshed ? `Last refreshed ${this.lastRefreshed.toLocaleString()}` : '';
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
