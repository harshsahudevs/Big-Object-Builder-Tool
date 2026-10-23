import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjects from '@salesforce/apex/BigObjectConfiguratorController.getObjects';
import getFields from '@salesforce/apex/BigObjectConfiguratorController.getFields';
import createBigObject from '@salesforce/apex/BigObjectConfiguratorController.createBigObject';
import checkCreateStatus from '@salesforce/apex/BigObjectConfiguratorController.checkCreateStatus';

const MAX_INDEX_FIELDS = 5;
const MAX_TEXT_INDEX_LENGTH = 100;
// LongTextArea and URL fields cannot be part of a Big Object index.
const INDEX_DISALLOWED_TYPES = new Set(['LongTextArea', 'Url']);
// Email and Phone fields have a fixed character cost toward the 100-char index limit.
const EMAIL_INDEX_LENGTH = 80;
const PHONE_INDEX_LENGTH = 40;

// Columns for the field-selection datatable.
const FIELD_COLUMNS = [
    { label: 'Label', fieldName: 'label', type: 'text' },
    { label: 'API Name', fieldName: 'apiName', type: 'text' },
    { label: 'Field Type', fieldName: 'sourceType', type: 'text' },
    { label: 'Stored As', fieldName: 'type', type: 'text' },
    { label: 'Required', fieldName: 'isRequired', type: 'boolean' }
];

const SORT_OPTIONS = [
    { label: 'Ascending', value: 'ASC' },
    { label: 'Descending', value: 'DESC' }
];

// Field-type filter for the selection table. "Supported" is the default so the
// table stays small/fast; the user can opt into all or only-unsupported views.
const FILTER_SUPPORTED = 'supported';
const FILTER_ALL = 'all';
const FILTER_UNSUPPORTED = 'unsupported';
const FIELD_FILTER_OPTIONS = [
    { label: 'Supported field types', value: FILTER_SUPPORTED },
    { label: 'All fields', value: FILTER_ALL },
    { label: 'Unsupported field types', value: FILTER_UNSUPPORTED }
];

export default class BigObjectConfigurator extends LightningElement {
    fieldColumns = FIELD_COLUMNS;
    sortOptions = SORT_OPTIONS;
    fieldFilterOptions = FIELD_FILTER_OPTIONS;
    fieldFilter = FILTER_SUPPORTED;

    allObjects = []; // full list from the controller: [{ label, value, isCustom }]
    objectType; // 'standard' | 'custom' — drives which objects load in the second picklist
    objectSearch = ''; // free-text filter over the object list
    objectTypeOptions = [
        { label: 'Standard Objects', value: 'standard' },
        { label: 'Custom Objects', value: 'custom' }
    ];
    selectedObject;

    @track fields = []; // all fields of the selected object
    @track selectedFields = []; // field objects the user included in the Big Object
    @track selectedRowKeys = []; // apiNames kept in sync with the datatable's controlled selection
    @track requiredUnsupportedList = []; // required source fields that cannot be stored in a Big Object
    requiredSupportedNames = []; // required source fields auto-included so unarchive can recreate the record

    // Per-field Big Object overrides keyed by source apiName -> { label, boApiName }.
    @track fieldCustom = {};

    // index config keyed by field apiName -> { included: Boolean, sortDirection: String }
    @track indexConfig = {};

    bigObjectLabel = '';
    bigObjectPluralLabel = '';
    bigObjectApiName = '';

    isLoading = false;   // field-describe load
    isCreating = false;  // Big Object deploy in progress (shows the processing panel)

    // After a successful create we switch to the inline mapping step for the new Big Object.
    showMapping = false;
    createdBigObject;
    createdSource;

    // ---- object list -------------------------------------------------------

    @wire(getObjects)
    wiredObjects({ data, error }) {
        if (data) {
            this.allObjects = data.map((o) => ({
                label: `${o.label} (${o.apiName})`,
                value: o.apiName,
                isCustom: o.isCustom
            }));
        } else if (error) {
            this.showToast('Error', this.reduceError(error), 'error');
        }
    }

    // Objects shown in the second picklist, dependent on the chosen type and the search term.
    get objectOptions() {
        if (!this.objectType) {
            return [];
        }
        const wantCustom = this.objectType === 'custom';
        let list = this.allObjects.filter((o) => !!o.isCustom === wantCustom);
        const term = (this.objectSearch || '').trim().toLowerCase();
        if (term) {
            list = list.filter((o) => o.label.toLowerCase().includes(term));
        }
        return list;
    }

    get objectSearchDisabled() {
        return !this.objectType || this.isLoading;
    }

    get noObjectMatches() {
        return !!this.objectType && this.objectOptions.length === 0;
    }

    handleObjectSearch(event) {
        this.objectSearch = event.detail.value;
    }

    get objectPickerDisabled() {
        return !this.objectType || this.isLoading;
    }

    get objectPickerPlaceholder() {
        if (!this.objectType) {
            return 'Select an object type first';
        }
        return this.objectType === 'custom' ? 'Search custom objects…' : 'Search standard objects…';
    }

    // ---- object selection --------------------------------------------------

    // Type changed: clear any chosen object and reset the downstream build state.
    handleObjectTypeChange(event) {
        this.objectType = event.detail.value;
        this.objectSearch = '';
        this.selectedObject = undefined;
        this.bigObjectLabel = '';
        this.bigObjectPluralLabel = '';
        this.bigObjectApiName = '';
        this.resetDownstreamState();
    }

    handleObjectChange(event) {
        this.selectedObject = event.detail.value;
        this.resetDownstreamState();
        this.loadFields();
        this.suggestNames();
    }

    loadFields() {
        this.isLoading = true;
        getFields({ objectApiName: this.selectedObject })
            .then((data) => {
                this.fields = data;
                // Required source fields must be stored so a future unarchive can recreate the
                // record. Auto-include the storable ones (locked), and flag any that can't be stored.
                const required = data.filter((f) => f.requiredForRestore);
                this.requiredSupportedNames = required
                    .filter((f) => f.isSupported)
                    .map((f) => f.apiName);
                this.requiredUnsupportedList = required
                    .filter((f) => !f.isSupported)
                    .map((f) => ({ apiName: f.apiName, label: f.label, type: f.sourceType }));
                // Default: archive the WHOLE record — select every archivable field. The user can
                // deselect any they don't want. (Unsupported/compound fields aren't selectable.)
                this.selectedFields = data.filter((f) => f.isSupported);
                this.syncSelectedRowKeys();
                this.syncFieldCustom();
            })
            .catch((error) => {
                this.showToast('Error', this.reduceError(error), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    // ---- field selection ---------------------------------------------------

    // Rows shown in the selection table, filtered by field-type.
    get visibleFields() {
        if (this.fieldFilter === FILTER_SUPPORTED) {
            return this.fields.filter((f) => f.isSupported);
        }
        if (this.fieldFilter === FILTER_UNSUPPORTED) {
            return this.fields.filter((f) => !f.isSupported);
        }
        return this.fields;
    }

    handleFilterChange(event) {
        this.fieldFilter = event.detail.value;
        // Re-sync the controlled selection to the rows now visible so checks persist across views.
        this.syncSelectedRowKeys();
    }

    handleFieldSelection(event) {
        const rows = event.detail.selectedRows || [];
        const unsupported = rows.filter((r) => !r.isSupported);
        if (unsupported.length) {
            this.showToast(
                'Unsupported field type',
                `These fields can't be added to a Big Object: ${unsupported.map((r) => r.apiName).join(', ')}`,
                'warning'
            );
        }
        const selectedInView = rows.filter((r) => r.isSupported);

        // The datatable only reports selections for the currently-visible (filtered) rows.
        // Preserve selections for fields hidden by the current filter so switching views
        // never drops them.
        const visibleNames = new Set(this.visibleFields.map((f) => f.apiName));
        const hiddenSelected = this.selectedFields.filter((f) => !visibleNames.has(f.apiName));

        const byName = new Map();
        [...hiddenSelected, ...selectedInView].forEach((f) => byName.set(f.apiName, f));

        // Enforce required-for-restore fields: they must stay included so an unarchive can
        // recreate the source record (otherwise the insert fails with REQUIRED_FIELD_MISSING).
        const removedRequired = this.requiredSupportedNames.filter((n) => !byName.has(n));
        if (removedRequired.length) {
            this.fields
                .filter((f) => removedRequired.includes(f.apiName))
                .forEach((f) => byName.set(f.apiName, f));
            this.showToast(
                'Required field kept',
                `These fields are required by ${this.selectedObject} and must stay included for unarchive to work: ${removedRequired.join(', ')}`,
                'info'
            );
        }

        this.selectedFields = [...byName.values()];
        this.syncSelectedRowKeys();
        this.syncFieldCustom();
        this.pruneIndexConfig();
    }

    // ---- derived selection state -------------------------------------------

    // Mirror the datatable's controlled selection to the current selection,
    // intersected with the rows visible under the active filter.
    syncSelectedRowKeys() {
        const visibleNames = new Set(this.visibleFields.map((f) => f.apiName));
        this.selectedRowKeys = this.selectedFields
            .map((f) => f.apiName)
            .filter((n) => visibleNames.has(n));
    }

    // Seed a Big Object label/API-name override for any newly selected field, and
    // drop overrides for fields no longer selected.
    syncFieldCustom() {
        const names = new Set(this.selectedFields.map((f) => f.apiName));
        Object.keys(this.fieldCustom).forEach((k) => {
            if (!names.has(k)) {
                delete this.fieldCustom[k];
            }
        });
        // Track Big Object API names already in use (from existing overrides) so new defaults
        // never collide — e.g. standard "X" -> X__c clashing with a custom X__c.
        const used = new Set();
        Object.values(this.fieldCustom).forEach((c) => {
            if (c && c.boApiName) {
                used.add(c.boApiName.toLowerCase());
            }
        });
        this.selectedFields.forEach((f) => {
            if (!this.fieldCustom[f.apiName]) {
                const boApiName = this.uniqueBoApiName(this.defaultBoApiName(f.apiName), used);
                used.add(boApiName.toLowerCase());
                this.fieldCustom[f.apiName] = { label: f.label, boApiName };
            }
        });
        this.fieldCustom = { ...this.fieldCustom };
    }

    // Make a Big Object API name unique against already-used names by inserting _2, _3, …
    // before the required __c suffix.
    uniqueBoApiName(candidate, used) {
        if (!used.has(candidate.toLowerCase())) {
            return candidate;
        }
        const base = candidate.replace(/__c$/, '');
        let n = 2;
        let next = `${base}_${n}__c`;
        while (used.has(next.toLowerCase())) {
            n += 1;
            next = `${base}_${n}__c`;
        }
        return next;
    }

    pruneIndexConfig() {
        const names = new Set(this.selectedFields.map((f) => f.apiName));
        Object.keys(this.indexConfig).forEach((apiName) => {
            if (!names.has(apiName)) {
                delete this.indexConfig[apiName];
            }
        });
        this.indexConfig = { ...this.indexConfig };
    }

    // Default Big Object field API name (always a valid, local custom name).
    defaultBoApiName(sourceApiName) {
        return this.sanitizeName(sourceApiName, '__c');
    }

    /**
     * Turns any raw string into a deploy-safe Salesforce DeveloperName with the given suffix
     * ('__b' / '__c'). Handles: spaces/punctuation -> '_', managed-package namespaces and any
     * double underscores collapsed (pi__score -> pi_score), leading digits/underscores stripped,
     * trailing underscores stripped, 40-char cap. Deterministic, so the LWC and Apex agree.
     */
    sanitizeName(raw, suffix) {
        let s = (raw || '').trim();
        if (suffix && s.toLowerCase().endsWith(suffix.toLowerCase())) {
            s = s.slice(0, s.length - suffix.length);
        }
        s = s
            .replace(/[^A-Za-z0-9_]/g, '_')
            .replace(/_+/g, '_')
            .replace(/^[_0-9]+/, '')
            .replace(/_+$/, '');
        if (!s) {
            s = 'X';
        }
        if (s.length > 40) {
            s = s.slice(0, 40).replace(/_+$/, '');
        }
        return `${s}${suffix || ''}`;
    }

    // ---- field configuration (label / API name / index) --------------------

    // One row per selected field: editable Big Object label + API name, plus index controls.
    get fieldRows() {
        return this.selectedFields.map((field) => {
            const config = this.indexConfig[field.apiName] || {};
            const custom = this.fieldCustom[field.apiName] || {};
            const included = !!config.included;
            const indexDisabled = INDEX_DISALLOWED_TYPES.has(field.type);
            return {
                apiName: field.apiName,
                sourceLabel: field.label,
                sourceInfo: `${field.label} (${field.apiName}) · ${field.type}`,
                type: field.type,
                length: field.length,
                boLabel: custom.label !== undefined ? custom.label : field.label,
                boApiName: custom.boApiName !== undefined ? custom.boApiName : this.defaultBoApiName(field.apiName),
                included,
                indexDisabled,
                indexToggleLabel: indexDisabled
                    ? `Use in index — not allowed for ${field.type}`
                    : 'Use in index',
                sortDisabled: !included,
                sortDirection: config.sortDirection || 'ASC'
            };
        });
    }

    handleBoLabelChange(event) {
        const apiName = event.target.dataset.id;
        this.fieldCustom[apiName] = {
            ...(this.fieldCustom[apiName] || {}),
            label: event.detail.value
        };
        this.fieldCustom = { ...this.fieldCustom };
    }

    handleBoApiNameChange(event) {
        const apiName = event.target.dataset.id;
        this.fieldCustom[apiName] = {
            ...(this.fieldCustom[apiName] || {}),
            boApiName: (event.detail.value || '').trim()
        };
        this.fieldCustom = { ...this.fieldCustom };
    }

    handleIndexToggle(event) {
        const apiName = event.target.dataset.id;
        const included = event.target.checked;
        const field = this.selectedFields.find((f) => f.apiName === apiName);
        if (included && field && INDEX_DISALLOWED_TYPES.has(field.type)) {
            event.target.checked = false;
            this.showToast(
                'Not indexable',
                `${field.type} fields can't be part of a Big Object index.`,
                'warning'
            );
            return;
        }
        if (included && this.selectedIndexCount >= MAX_INDEX_FIELDS) {
            event.target.checked = false;
            this.showToast('Limit reached', `An index may contain at most ${MAX_INDEX_FIELDS} fields.`, 'warning');
            return;
        }
        this.indexConfig[apiName] = { ...(this.indexConfig[apiName] || {}), included };
        this.indexConfig = { ...this.indexConfig };
    }

    handleSortChange(event) {
        const apiName = event.target.dataset.id;
        this.indexConfig[apiName] = {
            ...(this.indexConfig[apiName] || {}),
            sortDirection: event.detail.value
        };
        this.indexConfig = { ...this.indexConfig };
    }

    get selectedIndexCount() {
        return Object.values(this.indexConfig).filter((c) => c.included).length;
    }

    // Characters an index field contributes toward the 100-char limit:
    // Text = its length, Email = 80, Phone = 40; other types don't count.
    indexLengthFor(candidate) {
        if (candidate.type === 'Text') {
            return candidate.length || 0;
        }
        if (candidate.type === 'Email') {
            return EMAIL_INDEX_LENGTH;
        }
        if (candidate.type === 'Phone') {
            return PHONE_INDEX_LENGTH;
        }
        return 0;
    }

    get combinedIndexLength() {
        return this.fieldRows
            .filter((c) => c.included)
            .reduce((sum, c) => sum + this.indexLengthFor(c), 0);
    }

    get indexLengthExceeded() {
        return this.combinedIndexLength > MAX_TEXT_INDEX_LENGTH;
    }

    get indexLengthClass() {
        return this.indexLengthExceeded ? 'slds-text-color_error' : 'slds-text-color_success';
    }

    // ---- Big Object naming -------------------------------------------------

    suggestNames() {
        const option = this.objectOptions.find((o) => o.value === this.selectedObject);
        const label = option ? option.label.split(' (')[0] : this.selectedObject;
        const base = this.selectedObject.replace(/__c$/, '');
        this.bigObjectLabel = `${label} Archive`;
        this.bigObjectPluralLabel = `${label} Archives`;
        this.bigObjectApiName = `${base}_Archive__b`;
    }

    handleLabelChange(event) {
        this.bigObjectLabel = event.detail.value;
    }

    handlePluralChange(event) {
        this.bigObjectPluralLabel = event.detail.value;
    }

    handleApiNameChange(event) {
        this.bigObjectApiName = (event.detail.value || '').trim();
    }

    // ---- validation + submit ----------------------------------------------

    get validationErrors() {
        const errors = [];
        if (!this.selectedObject) {
            errors.push('Select a source object.');
        }
        if (!this.selectedFields.length) {
            errors.push('Select at least one field.');
        }
        if (this.selectedIndexCount < 1) {
            errors.push('Select at least one index field.');
        }
        if (this.selectedIndexCount > MAX_INDEX_FIELDS) {
            errors.push(`An index may contain at most ${MAX_INDEX_FIELDS} fields.`);
        }
        if (this.indexLengthExceeded) {
            errors.push(
                `Combined index length (${this.combinedIndexLength}) exceeds ${MAX_TEXT_INDEX_LENGTH}.`
            );
        }
        const disallowedIndex = this.fieldRows.filter((c) => c.included && c.indexDisabled);
        if (disallowedIndex.length) {
            errors.push(
                `These index fields have a type not allowed in an index: ${disallowedIndex
                    .map((c) => c.apiName)
                    .join(', ')}.`
            );
        }
        // Per-field Big Object label / API name checks.
        const seen = new Set();
        this.fieldRows.forEach((row) => {
            if (!row.boLabel || !row.boLabel.trim()) {
                errors.push(`Enter a Big Object label for "${row.apiName}".`);
            }
            if (!row.boApiName || !row.boApiName.endsWith('__c')) {
                errors.push(`Big Object API name for "${row.apiName}" must end with "__c".`);
            } else {
                const key = row.boApiName.toLowerCase();
                if (seen.has(key)) {
                    errors.push(`Duplicate Big Object field API name: ${row.boApiName}.`);
                }
                seen.add(key);
            }
        });
        if (!this.bigObjectLabel) {
            errors.push('Enter a Big Object label.');
        }
        if (!this.bigObjectApiName || !this.bigObjectApiName.endsWith('__b')) {
            errors.push('The Big Object API name must end with "__b".');
        }
        return errors;
    }

    get isSubmitDisabled() {
        return this.validationErrors.length > 0 || this.isLoading || this.isCreating;
    }

    // Show the configuration steps only when we're neither creating nor in the mapping step.
    get showConfigure() {
        return !this.showMapping && !this.isCreating;
    }

    get hasValidationErrors() {
        return this.validationErrors.length > 0;
    }

    // Sanitize the Big Object API name and every field's Big Object API name, then de-duplicate the
    // field names (two different source names can collapse to the same valid name).
    normalizeNames() {
        this.bigObjectApiName = this.sanitizeName(this.bigObjectApiName, '__b');
        const used = new Set();
        this.selectedFields.forEach((f) => {
            const custom = this.fieldCustom[f.apiName] || {};
            let name = this.sanitizeName(custom.boApiName || this.defaultBoApiName(f.apiName), '__c');
            name = this.uniqueBoApiName(name, used);
            used.add(name.toLowerCase());
            this.fieldCustom[f.apiName] = { ...custom, boApiName: name };
        });
        this.fieldCustom = { ...this.fieldCustom };
    }

    handleSubmit() {
        // Normalize every generated name BEFORE validating/building the payload, so any label or
        // typo (spaces, namespaces, leading digits, long names) still produces a deployable request.
        this.normalizeNames();

        if (this.validationErrors.length) {
            this.showToast('Cannot submit', this.validationErrors.join(' '), 'warning');
            return;
        }

        // Defensive: guarantee required-for-restore fields are in the payload even if a datatable
        // selection quirk dropped one, so the Big Object can always recreate the record on unarchive.
        const includedNames = new Set(this.selectedFields.map((f) => f.apiName));
        const missingRequired = this.fields.filter(
            (f) => this.requiredSupportedNames.includes(f.apiName) && !includedNames.has(f.apiName)
        );
        const fieldsForPayload = [...this.selectedFields, ...missingRequired];

        const request = {
            label: this.bigObjectLabel,
            pluralLabel: this.bigObjectPluralLabel,
            apiName: this.bigObjectApiName,
            fields: fieldsForPayload.map((f) => {
                const custom = this.fieldCustom[f.apiName] || {};
                const boLabel = custom.label !== undefined && custom.label.trim() ? custom.label.trim() : f.label;
                const boApiName = custom.boApiName ? custom.boApiName : this.defaultBoApiName(f.apiName);
                return {
                    apiName: f.apiName,
                    bigObjectApiName: boApiName,
                    label: boLabel,
                    type: f.type,
                    length: f.length,
                    scale: f.scale == null ? 0 : f.scale,
                    // Index fields must be required; mark them required in the request.
                    required: f.isRequired || !!(this.indexConfig[f.apiName] && this.indexConfig[f.apiName].included),
                    referenceTo: f.referenceTo
                };
            }),
            indexFields: this.fieldRows
                .filter((c) => c.included)
                .map((c) => ({ apiName: c.apiName, sortDirection: c.sortDirection }))
        };

        this.isCreating = true;
        createBigObject({ requestJson: JSON.stringify(request) })
            .then((jobId) => this.pollDeploy(jobId))
            .catch((error) => {
                this.isCreating = false;
                this.showToast('Creation failed', this.reduceError(error), 'error');
            });
    }

    // The Big Object is deployed via the async Metadata API; poll until the deploy finishes.
    // Bounded: stops after MAX_POLL_ATTEMPTS (~5 min) so a stuck deploy never polls forever.
    pollDeploy(jobId, attempt = 0) {
        const MAX_POLL_ATTEMPTS = 120; // 120 × 2.5s ≈ 5 minutes
        checkCreateStatus({ jobId })
            .then((status) => {
                if (!status.done) {
                    if (attempt >= MAX_POLL_ATTEMPTS) {
                        this.isCreating = false;
                        this.showToast(
                            'Still deploying',
                            'The Big Object deploy is taking longer than expected. Check Setup → Deployment Status; it may still complete. Refresh the list before retrying so you do not create a duplicate.',
                            'warning'
                        );
                        return;
                    }
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => this.pollDeploy(jobId, attempt + 1), 2500);
                    return;
                }
                this.isCreating = false;
                if (status.success) {
                    // Remember what we built, then jump to the inline mapping step for it.
                    this.createdBigObject = this.bigObjectApiName;
                    this.createdSource = this.selectedObject;
                    this.showMapping = true;
                    this.showToast('Success', status.message, 'success');
                } else {
                    this.showToast('Creation failed', status.message, 'error');
                }
            })
            .catch((error) => {
                this.isCreating = false;
                this.showToast('Creation failed', this.reduceError(error), 'error');
            });
    }

    // Reset the whole flow so the admin can build another Big Object.
    handleCreateAnother() {
        this.showMapping = false;
        this.createdBigObject = undefined;
        this.createdSource = undefined;
        this.objectType = undefined;
        this.objectSearch = '';
        this.selectedObject = undefined;
        this.bigObjectLabel = '';
        this.bigObjectPluralLabel = '';
        this.bigObjectApiName = '';
        this.resetDownstreamState();
    }

    // ---- helpers -----------------------------------------------------------

    resetDownstreamState() {
        this.fields = [];
        this.selectedFields = [];
        this.selectedRowKeys = [];
        this.requiredSupportedNames = [];
        this.requiredUnsupportedList = [];
        this.fieldCustom = {};
        this.indexConfig = {};
        this.fieldFilter = FILTER_SUPPORTED;
    }

    // ---- required-field notices --------------------------------------------

    get hasAutoIncludedRequired() {
        return this.requiredSupportedNames.length > 0;
    }

    get autoIncludedRequiredLabel() {
        return this.requiredSupportedNames.join(', ');
    }

    // Coerced fields among those currently selected (stored as text, restored to type).
    get coercedSelectedLabel() {
        return this.selectedFields
            .filter((f) => f.isCoerced)
            .map((f) => `${f.label} (${f.sourceType})`)
            .join(', ');
    }

    get hasCoercedSelected() {
        return this.selectedFields.some((f) => f.isCoerced);
    }

    get hasRequiredUnsupported() {
        return this.requiredUnsupportedList.length > 0;
    }

    get requiredUnsupportedLabel() {
        return this.requiredUnsupportedList.map((f) => `${f.apiName} (${f.type})`).join(', ');
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unknown error';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
