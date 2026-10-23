import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDashboardMetrics from '@salesforce/apex/BigObjectAdminController.getDashboardMetrics';
import getBigObjectInventory from '@salesforce/apex/BigObjectAdminController.getBigObjectInventory';
import refreshRecordCounts from '@salesforce/apex/BigObjectAdminController.refreshRecordCounts';

const ACTIVITY_COLUMNS = [
    { label: 'Log #', fieldName: 'name', type: 'text', initialWidth: 110 },
    { label: 'Operation', fieldName: 'operation', type: 'text', initialWidth: 110 },
    { label: 'Source Object', fieldName: 'sourceObject', type: 'text' },
    { label: 'Target Big Object', fieldName: 'targetBigObject', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text', cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'By', fieldName: 'performedBy', type: 'text' },
    { label: 'When', fieldName: 'performedDate', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } }
];

const INVENTORY_COLUMNS = [
    { label: 'Label', fieldName: 'label', type: 'text' },
    { label: 'API Name', fieldName: 'apiName', type: 'text' },
    { label: 'Index Fields', fieldName: 'indexFieldsText', type: 'text', wrapText: true },
    { label: 'Approx. Records', fieldName: 'approxRecordCount', type: 'number', cellAttributes: { alignment: 'left' } },
    { label: 'Last Counted', fieldName: 'lastCounted', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { type: 'button', typeAttributes: { label: 'Open in Setup', name: 'setup', variant: 'base' } }
];

export default class BigObjectAdmin extends LightningElement {
    activityColumns = ACTIVITY_COLUMNS;
    inventoryColumns = INVENTORY_COLUMNS;

    metrics;
    activity = [];
    inventory = [];
    metricsError;
    inventoryError;
    isRefreshing = false;
    lastRefreshed = new Date();

    _wiredMetrics;
    _wiredInventory;

    @wire(getDashboardMetrics)
    wiredMetrics(result) {
        this._wiredMetrics = result;
        if (result.data) {
            this.metrics = result.data;
            this.activity = (result.data.recentActivity || []).map((a) => ({
                ...a,
                statusClass: a.status === 'Failed' ? 'slds-text-color_error' : 'slds-text-color_success'
            }));
            this.metricsError = undefined;
            this.lastRefreshed = new Date();
        } else if (result.error) {
            this.metricsError = this.reduceError(result.error);
        }
    }

    @wire(getBigObjectInventory)
    wiredInventory(result) {
        this._wiredInventory = result;
        if (result.data) {
            this.inventory = result.data.map((item) => ({
                ...item,
                indexFieldsText: (item.indexFields || []).join(', ')
            }));
            this.inventoryError = undefined;
        } else if (result.error) {
            this.inventoryError = this.reduceError(result.error);
        }
    }

    // ---- KPI tile getters --------------------------------------------------

    get totalBigObjects() {
        return this.metrics ? this.metrics.totalBigObjects : 0;
    }

    get totalArchived() {
        return this.metrics ? this.metrics.totalArchived : 0;
    }

    get totalUnarchived() {
        return this.metrics ? this.metrics.totalUnarchived : 0;
    }

    get failedCount() {
        return this.metrics ? this.metrics.failedCount : 0;
    }

    get unarchiveFailedCount() {
        return this.metrics ? this.metrics.unarchiveFailedCount : 0;
    }

    get unarchiveFailedTextClass() {
        return this.unarchiveFailedCount > 0 ? 'slds-text-color_error' : 'slds-text-color_success';
    }

    get usagePercent() {
        return this.metrics ? this.metrics.usagePercent : 0;
    }

    get usageLabel() {
        if (!this.metrics) {
            return '';
        }
        return `${this.formatNumber(this.metrics.totalArchived)} / ${this.formatNumber(this.metrics.recordLimit)} records`;
    }

    // Status palette by threshold — reserved status colors, with a text label (never color alone).
    get usageStatus() {
        const pct = this.usagePercent;
        if (pct >= 90) {
            return { label: 'Critical', theme: 'slds-theme_error' };
        }
        if (pct >= 75) {
            return { label: 'Warning', theme: 'slds-theme_warning' };
        }
        return { label: 'Healthy', theme: 'slds-theme_success' };
    }

    get usageBadgeClass() {
        return `slds-badge ${this.usageStatus.theme}`;
    }

    get hasFailures() {
        return this.failedCount > 0;
    }

    get failedTextClass() {
        return this.failedCount > 0 ? 'slds-text-color_error' : 'slds-text-color_success';
    }

    // ---- actions -----------------------------------------------------------

    handleRefreshCounts() {
        if (this.isRefreshing) {
            return;
        }
        this.isRefreshing = true;
        refreshRecordCounts()
            .then(() => Promise.all([refreshApex(this._wiredInventory), refreshApex(this._wiredMetrics)]))
            .then(() => {
                this.toast('Success', 'Record counts refreshed.', 'success');
            })
            .catch((error) => {
                this.toast('Refresh failed', this.reduceError(error), 'error');
            })
            .finally(() => {
                this.isRefreshing = false;
            });
    }

    handleReload() {
        this.isRefreshing = true;
        Promise.all([refreshApex(this._wiredMetrics), refreshApex(this._wiredInventory)]).finally(() => {
            this.isRefreshing = false;
        });
    }

    handleInventoryRowAction(event) {
        if (event.detail.action.name === 'setup') {
            window.open(event.detail.row.setupUrl, '_blank');
        }
    }

    // ---- empty states ------------------------------------------------------

    get showNoActivity() {
        return this.activity.length === 0 && !this.metricsError;
    }

    get showNoInventory() {
        return this.inventory.length === 0 && !this.inventoryError;
    }

    get lastRefreshedLabel() {
        return this.lastRefreshed.toLocaleString();
    }

    // ---- helpers -----------------------------------------------------------

    formatNumber(value) {
        return value == null ? '0' : Number(value).toLocaleString();
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
