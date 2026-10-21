import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBigObjects from '@salesforce/apex/BigObjectBrowserController.getBigObjects';
import getRecords from '@salesforce/apex/BigObjectBrowserController.getRecords';
import unarchiveRecords from '@salesforce/apex/BigObjectBrowserController.unarchiveRecords';
import unarchiveAll from '@salesforce/apex/BigObjectBrowserController.unarchiveAll';

const VIEW_ACTION = {
    type: 'button-icon',
    fixedWidth: 60,
    typeAttributes: {
        name: 'view',
        title: 'View full record',
        iconName: 'utility:preview',
        variant: 'bare',
        alternativeText: 'View'
    }
};

const UNARCHIVE_ACTION = {
    type: 'button',
    fixedWidth: 150,
    typeAttributes: {
        label: 'Unarchive',
        name: 'unarchive',
        title: 'Unarchive this record',
        variant: 'brand-outline',
        iconName: 'utility:undo',
        iconPosition: 'left'
    }
};

export default class BigObjectRecordViewer extends LightningElement {
    @track bigObjectOptions = [];
    @track columns = [];
    @track rows = [];
    @track fieldDefs = []; // data-column defs (label/fieldName/type) for the detail view

    // Detail modal state.
    showDetail = false;
    detailRow;

    selectedBigObject = '';
    selectedKeys = [];
    hasMore = false;

    isLoadingObjects = false;
    isLoadingRecords = false;
    isWorking = false;
    errorMessage;
    lastRefreshed;

    // Confirmation modal state.
    showConfirm = false;
    confirmMode; // 'single' | 'selected' | 'all'
    pendingKeys = [];

    connectedCallback() {
        this.loadBigObjects();
    }

    // ---- data loading ------------------------------------------------------

    loadBigObjects() {
        this.isLoadingObjects = true;
        getBigObjects()
            .then((options) => {
                this.bigObjectOptions = (options || []).map((o) => ({
                    label: `${o.label} (${o.apiName})`,
                    value: o.apiName
                }));
            })
            .catch((error) => {
                this.errorMessage = this.reduceError(error);
            })
            .finally(() => {
                this.isLoadingObjects = false;
            });
    }

    handleObjectChange(event) {
        this.selectedBigObject = event.detail.value;
        this.loadRecords();
    }

    loadRecords() {
        if (!this.selectedBigObject) {
            return;
        }
        this.isLoadingRecords = true;
        this.errorMessage = undefined;
        this.selectedKeys = [];

        getRecords({ bigObjectApiName: this.selectedBigObject })
            .then((result) => {
                this.columns = this.buildColumns(result.columns);
                this.rows = this.flattenRows(result.rows);
                this.hasMore = result.hasMore === true;
                this.lastRefreshed = result.queriedAt ? new Date(result.queriedAt) : new Date();
            })
            .catch((error) => {
                this.rows = [];
                this.columns = [];
                this.errorMessage = this.reduceError(error);
            })
            .finally(() => {
                this.isLoadingRecords = false;
            });
    }

    buildColumns(apexColumns) {
        const dataColumns = (apexColumns || []).map((col) => ({
            label: col.label,
            fieldName: col.fieldName,
            type: this.mapColumnType(col.type)
        }));
        this.fieldDefs = dataColumns; // kept for the detail view
        // View (left) + the data columns + a per-row Unarchive button on the right.
        return [{ ...VIEW_ACTION }, ...dataColumns, { ...UNARCHIVE_ACTION }];
    }

    // Big Object rows arrive as { recordKey, values:{field:value} }; flatten for the datatable.
    flattenRows(apexRows) {
        return (apexRows || []).map((row) => ({ key: row.recordKey, ...row.values }));
    }

    mapColumnType(apexType) {
        switch (apexType) {
            case 'datetime':
                return 'date';
            case 'double':
            case 'currency':
            case 'integer':
            case 'percent':
                return 'number';
            case 'email':
                return 'email';
            case 'phone':
                return 'phone';
            case 'url':
                return 'url';
            default:
                return 'text';
        }
    }

    // ---- selection + actions ----------------------------------------------

    handleRowSelection(event) {
        this.selectedKeys = event.detail.selectedRows.map((row) => row.key);
    }

    handleRowAction(event) {
        const name = event.detail.action.name;
        const row = event.detail.row;
        if (name === 'unarchive') {
            this.openConfirm('single', [row.key]);
        } else if (name === 'view') {
            this.openDetail(row);
        }
    }

    // ---- detail view -------------------------------------------------------

    openDetail(row) {
        this.detailRow = row;
        this.showDetail = true;
    }

    closeDetail() {
        this.showDetail = false;
        this.detailRow = undefined;
    }

    // Unarchive the record currently open in the detail modal.
    unarchiveFromDetail() {
        const key = this.detailRow && this.detailRow.key;
        this.closeDetail();
        if (key) {
            this.openConfirm('single', [key]);
        }
    }

    // All stored field label/value pairs for the record open in the detail modal.
    get detailFields() {
        if (!this.detailRow) {
            return [];
        }
        return this.fieldDefs.map((def) => {
            let value = this.detailRow[def.fieldName];
            if (value === undefined || value === null || value === '') {
                value = '—';
            } else if (def.type === 'date') {
                const d = new Date(value);
                value = isNaN(d.getTime()) ? String(value) : d.toLocaleString();
            } else {
                value = String(value);
            }
            return { key: def.fieldName, label: def.label, value };
        });
    }

    handleUnarchiveSelected() {
        if (!this.selectedKeys.length) {
            this.toast('Nothing selected', 'Select one or more records first.', 'warning');
            return;
        }
        this.openConfirm('selected', [...this.selectedKeys]);
    }

    handleUnarchiveAll() {
        if (!this.hasRows) {
            return;
        }
        this.openConfirm('all', []);
    }

    openConfirm(mode, keys) {
        this.confirmMode = mode;
        this.pendingKeys = keys;
        this.showConfirm = true;
    }

    cancelConfirm() {
        this.showConfirm = false;
        this.confirmMode = undefined;
        this.pendingKeys = [];
    }

    confirmUnarchive() {
        const mode = this.confirmMode;
        this.showConfirm = false;
        this.isWorking = true;

        const call =
            mode === 'all'
                ? unarchiveAll({ bigObjectApiName: this.selectedBigObject })
                : unarchiveRecords({
                      bigObjectApiName: this.selectedBigObject,
                      recordKeys: this.pendingKeys
                  });

        call.then((results) => this.processResults(results))
            .catch((error) => {
                this.toast('Unarchive failed', this.reduceError(error), 'error');
            })
            .finally(() => {
                this.isWorking = false;
                this.pendingKeys = [];
                this.confirmMode = undefined;
                // No immediate server reload: the Big Object delete runs async (Queueable), so a
                // re-query here would race the cleanup and show the rows again. processResults()
                // removes the restored rows from the table optimistically instead.
            });
    }

    processResults(results) {
        const list = results || [];
        const succeeded = list.filter((r) => r.isSuccess).length;
        const failed = list.length - succeeded;

        // Drop the restored rows from the table immediately. Their Big Object delete runs async
        // (Queueable), so re-querying the server right now would still return them; removing them
        // client-side keeps the UI accurate without racing the cleanup job. Failed rows stay.
        const succeededKeys = new Set(
            list.filter((r) => r.isSuccess).map((r) => r.recordKey)
        );
        if (succeededKeys.size) {
            this.rows = this.rows.filter((row) => !succeededKeys.has(row.key));
            this.selectedKeys = [];
            this.lastRefreshed = new Date();
        }

        if (list.length === 0) {
            this.toast('Nothing to unarchive', 'There were no records to unarchive.', 'info');
            return;
        }
        if (failed === 0) {
            this.toast(
                'Unarchived',
                `${succeeded} record${succeeded === 1 ? '' : 's'} restored to the source object.`,
                'success'
            );
            return;
        }
        const firstError = (list.find((r) => !r.isSuccess) || {}).errorMessage || '';
        this.toast(
            'Partially unarchived',
            `${succeeded} succeeded, ${failed} failed. First error: ${firstError}`,
            failed === list.length ? 'error' : 'warning'
        );
    }

    // ---- helpers -----------------------------------------------------------

    handleRefresh() {
        this.loadRecords();
    }

    get isObjectChosen() {
        return !!this.selectedBigObject;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showEmptyState() {
        return this.isObjectChosen && !this.isLoadingRecords && !this.errorMessage && !this.hasRows;
    }

    get hasSelection() {
        return this.selectedKeys.length > 0;
    }

    get unarchiveSelectedLabel() {
        return this.hasSelection
            ? `Unarchive Selected (${this.selectedKeys.length})`
            : 'Unarchive Selected';
    }

    get disableSelected() {
        return !this.hasSelection || this.isWorking;
    }

    get disableAll() {
        return !this.hasRows || this.isWorking;
    }

    get recordCountLabel() {
        if (!this.hasRows) {
            return '';
        }
        return this.hasMore
            ? `Showing the first ${this.rows.length} archived records`
            : `${this.rows.length} archived record${this.rows.length === 1 ? '' : 's'}`;
    }

    get lastRefreshedLabel() {
        return this.lastRefreshed ? `Last refreshed ${this.lastRefreshed.toLocaleString()}` : '';
    }

    get confirmMessage() {
        if (this.confirmMode === 'all') {
            return 'Unarchive ALL loaded records? Each record is recreated in its source object and removed from the Big Object. This cannot be undone.';
        }
        const count = this.pendingKeys.length;
        return `Unarchive ${count} record${count === 1 ? '' : 's'}? Each is recreated in its source object and removed from the Big Object. This cannot be undone.`;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
