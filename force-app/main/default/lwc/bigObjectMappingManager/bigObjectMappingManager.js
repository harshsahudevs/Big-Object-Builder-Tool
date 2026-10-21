import { LightningElement } from 'lwc';
import getMappingOverview from '@salesforce/apex/BigObjectSettingsController.getMappingOverview';

// Status -> icon + lightning-icon variant (green / amber / neutral).
const STATUS_META = {
    Mapped: { icon: 'utility:success', variant: 'success' },
    Partial: { icon: 'utility:warning', variant: 'warning' },
    Unmapped: { icon: 'utility:dash', variant: undefined }
};

export default class BigObjectMappingManager extends LightningElement {
    rows = [];
    error;
    isLoading = true;

    // When set, the inline mapping editor is shown for this Big Object.
    managingBigObject;
    managingSource;

    connectedCallback() {
        this.loadOverview();
    }

    // getMappingOverview performs a Tooling callout, so it can't be cacheable/@wire — call it imperatively.
    loadOverview() {
        this.isLoading = true;
        return getMappingOverview()
            .then((data) => {
                this.rows = (data || []).map((o) => {
                    const meta = STATUS_META[o.status] || {};
                    return {
                        apiName: o.apiName,
                        label: o.label,
                        sourceObject: o.sourceObject,
                        sourceDisplay: o.sourceObject || '—',
                        fieldsDisplay: `${o.mappedFields} / ${o.totalFields}`,
                        status: o.status,
                        statusIcon: meta.icon || 'utility:dash',
                        statusVariant: meta.variant
                    };
                });
                this.error = undefined;
            })
            .catch((error) => {
                this.error = this.reduceError(error);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showList() {
        return !this.managingBigObject;
    }

    get totalCount() {
        return this.rows.length;
    }

    get mappedCount() {
        return this.rows.filter((r) => r.status === 'Mapped').length;
    }

    get partialCount() {
        return this.rows.filter((r) => r.status === 'Partial').length;
    }

    get unmappedCount() {
        return this.rows.filter((r) => r.status === 'Unmapped').length;
    }

    handleManage(event) {
        this.managingBigObject = event.currentTarget.dataset.id;
        this.managingSource = event.currentTarget.dataset.source || undefined;
    }

    handleBack() {
        this.managingBigObject = undefined;
        this.managingSource = undefined;
        return this.loadOverview();
    }

    handleRefresh() {
        return this.loadOverview();
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
