import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBigObjects from '@salesforce/apex/BigObjectSettingsController.getBigObjects';
import getObjectFields from '@salesforce/apex/BigObjectSettingsController.getObjectFields';
import getBigObjectFields from '@salesforce/apex/BigObjectSettingsController.getBigObjectFields';
import getMappings from '@salesforce/apex/BigObjectSettingsController.getMappings';
import saveMappings from '@salesforce/apex/BigObjectSettingsController.saveMappings';
import getObjects from '@salesforce/apex/BigObjectConfiguratorController.getObjects';

const UNMAPPED = '';

export default class BigObjectSettings extends LightningElement {
    // When set (e.g. embedded right after a Big Object is created) the component locks onto this
    // Big Object + source object and jumps straight into the mapping editor.
    @api presetBigObject;
    @api presetSourceObject;

    bigObjects = [];
    sourceObjectOptions = [];

    selectedBigObject;
    selectedSourceObject;

    // mapping editor rows: { bigObjectField, bigObjectLabel, sourceField }
    mappingRows = [];
    sourceFieldOptions = [{ label: '— Not mapped —', value: UNMAPPED }];

    isLoading = false;
    isSaving = false;

    _presetApplied = false;

    // ---- static lists ------------------------------------------------------

    @wire(getBigObjects)
    wiredBigObjects({ data, error }) {
        if (data) {
            this.bigObjects = data.map((o) => ({
                apiName: o.apiName,
                label: o.label,
                variant: o.apiName === this.selectedBigObject ? 'brand' : 'neutral'
            }));
        } else if (error) {
            this.toast('Error', this.reduceError(error), 'error');
        }
    }

    @wire(getObjects)
    wiredObjects({ data, error }) {
        if (data) {
            this.sourceObjectOptions = data.map((o) => ({
                label: `${o.label} (${o.apiName})`,
                value: o.apiName
            }));
        } else if (error) {
            this.toast('Error', this.reduceError(error), 'error');
        }
    }

    // Apply a preset (set by a host like the configurator) exactly once.
    renderedCallback() {
        if (this.presetBigObject && !this._presetApplied) {
            this._presetApplied = true;
            this.selectBigObject(this.presetBigObject);
        }
    }

    // ---- getters -----------------------------------------------------------

    get embedded() {
        return !!this.presetBigObject;
    }

    get showBigObjectList() {
        return !this.embedded && this.bigObjects.length > 0;
    }

    get showNoBigObjects() {
        return !this.embedded && this.bigObjects.length === 0;
    }

    get showEditor() {
        return !!this.selectedBigObject;
    }

    get showMappingRows() {
        return !!this.selectedSourceObject && this.mappingRows.length > 0;
    }

    get isSaveDisabled() {
        return this.isSaving || !this.selectedSourceObject || this.mappingRows.length === 0;
    }

    get autoMappedCount() {
        return this.mappingRows.filter((r) => r.sourceField).length;
    }

    get mappingSummary() {
        if (!this.mappingRows.length) {
            return '';
        }
        return `${this.autoMappedCount} of ${this.mappingRows.length} field(s) auto-matched by name. Review, adjust any unmatched, then Save.`;
    }

    // ---- Big Object selection ---------------------------------------------

    handleSelectBigObject(event) {
        this.selectBigObject(event.currentTarget.dataset.id);
    }

    selectBigObject(apiName) {
        this.selectedBigObject = apiName;
        this.bigObjects = this.bigObjects.map((o) => ({
            ...o,
            variant: o.apiName === apiName ? 'brand' : 'neutral'
        }));
        this.selectedSourceObject = undefined;
        this.mappingRows = [];
        this.sourceFieldOptions = [{ label: '— Not mapped —', value: UNMAPPED }];
        this.loadExistingThenEditor();
    }

    // Load Big Object fields + existing mappings, then pick a default source object and pre-map.
    loadExistingThenEditor() {
        this.isLoading = true;
        Promise.all([
            // Big Object side: Tooling-backed so ALL custom fields show (incl. non-index fields
            // that the runtime describe omits). Source side still uses describe.
            getBigObjectFields({ bigObjectApiName: this.selectedBigObject }),
            getMappings({ bigObjectApiName: this.selectedBigObject })
        ])
            .then(([bigFields, existing]) => {
                this._bigObjectFields = bigFields || [];
                this._existingByBigField = {};
                let savedSource;
                (existing || []).forEach((m) => {
                    this._existingByBigField[m.Big_Object_Field__c] = m.Source_Field__c;
                    savedSource = m.Source_Object__c;
                });
                // Default source object: saved mapping's source > preset > derived from the BO name.
                const source =
                    savedSource || this.presetSourceObject || this.deriveSourceObject(this.selectedBigObject);
                if (source) {
                    this.selectedSourceObject = source;
                    return this.loadSourceFields(source);
                }
                return null;
            })
            .catch((error) => this.toast('Error', this.reduceError(error), 'error'))
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleSourceChange(event) {
        this.selectedSourceObject = event.detail.value;
        this.isLoading = true;
        this.loadSourceFields(this.selectedSourceObject)
            .catch((error) => this.toast('Error', this.reduceError(error), 'error'))
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadSourceFields(sourceObject) {
        return getObjectFields({ objectApiName: sourceObject }).then((sourceFields) => {
            const fields = sourceFields || [];
            this.sourceFieldOptions = [{ label: '— Not mapped —', value: UNMAPPED }].concat(
                fields.map((f) => ({ label: `${f.label} (${f.apiName})`, value: f.apiName }))
            );
            // Normalized lookup so each Big Object field can be matched to the closest source field.
            const sourceByKey = {};
            fields.forEach((f) => {
                const apiKey = this.normalizeName(f.apiName);
                if (apiKey && !(apiKey in sourceByKey)) {
                    sourceByKey[apiKey] = f.apiName;
                }
                const labelKey = this.normalizeName(f.label);
                if (labelKey && !(labelKey in sourceByKey)) {
                    sourceByKey[labelKey] = f.apiName;
                }
            });
            const existing = this._existingByBigField || {};
            this.mappingRows = (this._bigObjectFields || []).map((f) => {
                // Prefer a saved mapping; otherwise auto-match by normalized name.
                let src = existing[f.apiName];
                if (!src) {
                    src = sourceByKey[this.normalizeName(f.apiName)] || UNMAPPED;
                }
                return {
                    bigObjectField: f.apiName,
                    bigObjectLabel: `${f.label} (${f.apiName})`,
                    sourceField: src || UNMAPPED
                };
            });
        });
    }

    handleMappingChange(event) {
        const bigField = event.target.dataset.id;
        const value = event.detail.value;
        this.mappingRows = this.mappingRows.map((r) =>
            r.bigObjectField === bigField ? { ...r, sourceField: value } : r
        );
    }

    handleSave() {
        if (this.isSaveDisabled) {
            return;
        }
        this.isSaving = true;
        const rows = this.mappingRows.map((r) => ({
            bigObjectField: r.bigObjectField,
            sourceField: r.sourceField
        }));
        saveMappings({
            bigObjectApiName: this.selectedBigObject,
            sourceObjectApiName: this.selectedSourceObject,
            mappingsJson: JSON.stringify(rows)
        })
            .then(() => {
                this.toast('Saved', 'Field mappings saved for ' + this.selectedBigObject + '.', 'success');
            })
            .catch((error) => {
                this.toast('Save failed', this.reduceError(error), 'error');
            })
            .finally(() => {
                this.isSaving = false;
            });
    }

    // ---- helpers -----------------------------------------------------------

    // Best-effort source object from a Big Object name: Lead_Archive__b -> Lead.
    deriveSourceObject(bigObjectApiName) {
        if (!bigObjectApiName) {
            return undefined;
        }
        let base = bigObjectApiName.replace(/__b$/i, '');
        base = base.replace(/_archive.*$/i, '');
        const match = this.sourceObjectOptions.find((o) => o.value.toLowerCase() === base.toLowerCase());
        return match ? match.value : undefined;
    }

    // Normalize a name/label for fuzzy matching: drop a trailing __c, lowercase, strip non-alphanumerics.
    normalizeName(value) {
        if (!value) {
            return '';
        }
        return value.toLowerCase().replace(/__c$/, '').replace(/[^a-z0-9]/g, '');
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
