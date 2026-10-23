import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBigObjects from '@salesforce/apex/BigObjectBrowserController.getBigObjects';
import getRecords from '@salesforce/apex/BigObjectBrowserController.getRecords';
import unarchiveRecords from '@salesforce/apex/BigObjectBrowserController.unarchiveRecords';
import unarchiveAll from '@salesforce/apex/BigObjectBrowserController.unarchiveAll';
import unarchiveRecordWithRelated from '@salesforce/apex/BigObjectBrowserController.unarchiveRecordWithRelated';
import getRecordSnapshot from '@salesforce/apex/BigObjectBrowserController.getRecordSnapshot';

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
    @track detailItems = []; // label/value rows rendered in the detail modal
    detailObjectName = '';
    detailSnapshotLoading = false;
    // True when only the queryable index fields are shown (no full-record snapshot was captured).
    detailPartial = false;

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
        this.detailObjectName = '';
        this.detailPartial = false;
        this.detailItems = [];
        this.loadDetail(row);
    }

    // Loads the full archived record from its snapshot; falls back to the queryable index fields
    // (shown with a note) when no snapshot was captured for the row.
    loadDetail(row) {
        this.detailSnapshotLoading = true;
        getRecordSnapshot({ bigObjectApiName: this.selectedBigObject, recordKey: row.key })
            .then((snapshotJson) => {
                const parsed = this.parseSnapshot(snapshotJson);
                if (parsed && parsed.fields.length) {
                    this.detailObjectName = parsed.sourceObject || '';
                    this.detailItems = parsed.fields;
                    this.detailPartial = false;
                } else {
                    this.detailItems = this.indexFieldItems(row);
                    this.detailPartial = true;
                }
            })
            .catch(() => {
                // Snapshot lookup failed — still show whatever the row (index fields) carries.
                this.detailItems = this.indexFieldItems(row);
                this.detailPartial = true;
            })
            .finally(() => {
                this.detailSnapshotLoading = false;
            });
    }

    parseSnapshot(snapshotJson) {
        if (!snapshotJson) {
            return null;
        }
        let data;
        try {
            data = JSON.parse(snapshotJson);
        } catch (e) {
            return null;
        }
        const fields = (data.fields || []).map((f, i) => ({
            key: f.name || `f${i}`,
            label: f.label || f.name,
            value: this.formatValue(f.type, f.value)
        }));
        return { sourceObject: data.sourceObject, fields };
    }

    // Fallback: the queryable index-field columns already loaded in the row.
    indexFieldItems(row) {
        return this.fieldDefs.map((def) => ({
            key: def.fieldName,
            label: def.label,
            value: this.formatValue(def.type, row[def.fieldName])
        }));
    }

    formatValue(type, value) {
        if (value === undefined || value === null || value === '') {
            return '—';
        }
        if (type === 'date' || type === 'datetime') {
            const d = new Date(value);
            return isNaN(d.getTime()) ? String(value) : d.toLocaleString();
        }
        return String(value);
    }

    closeDetail() {
        this.showDetail = false;
        this.detailRow = undefined;
        this.detailItems = [];
        this.detailObjectName = '';
        this.detailPartial = false;
    }

    // Unarchive the record currently open in the detail modal.
    unarchiveFromDetail() {
        const key = this.detailRow && this.detailRow.key;
        this.closeDetail();
        if (key) {
            this.openConfirm('single', [key]);
        }
    }

    get detailFieldCount() {
        return this.detailItems.length;
    }

    get detailHeading() {
        return this.detailObjectName
            ? `Archived ${this.detailObjectName} record`
            : 'Archived record';
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
        const rootKey = this.pendingKeys[0];
        this.showConfirm = false;
        this.isWorking = true;

        // Single-record unarchive goes through the engine so the record AND its related archived
        // records come back together (children re-linked to the restored parent). Bulk paths restore
        // the selected/all rows of this one Big Object as-is.
        const call =
            mode === 'single'
                ? unarchiveRecordWithRelated({
                      bigObjectApiName: this.selectedBigObject,
                      recordKey: rootKey
                  }).then((result) => this.processSetResult(result, rootKey))
                : (mode === 'all'
                      ? unarchiveAll({ bigObjectApiName: this.selectedBigObject })
                      : unarchiveRecords({
                            bigObjectApiName: this.selectedBigObject,
                            recordKeys: this.pendingKeys
                        })
                  ).then((results) => this.processResults(results));

        call.catch((error) => {
            this.toast('Unarchive failed', this.reduceError(error), 'error');
        }).finally(() => {
            this.isWorking = false;
            this.pendingKeys = [];
            this.confirmMode = undefined;
            // No immediate server reload: the Big Object delete runs async (Queueable), so a
            // re-query here would race the cleanup and show the rows again. The result handlers
            // remove the restored rows from the table optimistically instead.
        });
    }

    // Handles the whole-record (engine) result: drops the restored root row and reports the set
    // outcome — how many related records came back, re-link status, and any fidelity notes.
    processSetResult(result, rootKey) {
        if (!result) {
            return;
        }
        if (result.rootRestored) {
            this.rows = this.rows.filter((row) => row.key !== rootKey);
            this.selectedKeys = [];
            this.lastRefreshed = new Date();
        }

        const related = (result.totalRestored || 0) - (result.rootRestored ? 1 : 0);
        const noteList = result.notes || [];
        const noteSuffix = noteList.length ? ` Note: ${noteList[0]}` : '';

        if (!result.rootRestored) {
            const firstNote = noteList.length ? noteList[0] : 'The record could not be restored.';
            this.toast('Unarchive failed', firstNote, 'error');
            return;
        }
        if (result.totalFailed > 0) {
            this.toast(
                'Partially unarchived',
                `Record restored with ${related} related record${related === 1 ? '' : 's'}; ` +
                    `${result.totalFailed} related record${result.totalFailed === 1 ? '' : 's'} failed.${noteSuffix}`,
                'warning'
            );
            return;
        }
        const relatedLabel = related > 0
            ? ` and ${related} related record${related === 1 ? '' : 's'}`
            : '';
        this.toast(
            'Unarchived',
            `Record${relatedLabel} restored to the source object.${noteSuffix}`,
            'success'
        );
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
        if (this.confirmMode === 'single') {
            return 'Unarchive this record and its related archived records? The record is recreated in its source object, its related records are restored and re-linked to it, and all restored rows are removed from their Big Objects. This cannot be undone.';
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
