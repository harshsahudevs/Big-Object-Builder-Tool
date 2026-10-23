import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPolicies from '@salesforce/apex/ArchivePolicyController.getPolicies';
import getPolicy from '@salesforce/apex/ArchivePolicyController.getPolicy';
import getObjectOptions from '@salesforce/apex/ArchivePolicyController.getObjectOptions';
import getFieldOptions from '@salesforce/apex/ArchivePolicyController.getFieldOptions';
import getBigObjectsForSource from '@salesforce/apex/ArchivePolicyController.getBigObjectsForSource';
import getPicklistValues from '@salesforce/apex/ArchivePolicyController.getPicklistValues';
import savePolicy from '@salesforce/apex/ArchivePolicyController.savePolicy';
import getPreviewCount from '@salesforce/apex/ArchivePolicyController.getPreviewCount';
import runNow from '@salesforce/apex/ArchivePolicyController.runNow';
import setActive from '@salesforce/apex/ArchivePolicyController.setActive';
import getExecutionLogs from '@salesforce/apex/ArchivePolicyController.getExecutionLogs';

const BOOLEAN_OPTIONS = [
    { label: 'True', value: 'true' },
    { label: 'False', value: 'false' }
];
const BIG_OBJECT_BUILDER_TAB = 'Big_Object_Builder';

const ACTION_OPTIONS = [
    { label: 'Soft Delete', value: 'Soft Delete' },
    { label: 'Hard Delete', value: 'Hard Delete' },
    { label: 'Move to Big Object', value: 'Move to Big Object' },
    { label: 'External Store', value: 'External Store' }
];
const OPERATOR_OPTIONS = [
    { label: 'Equals', value: 'Equals' },
    { label: 'Not Equals', value: 'Not Equals' },
    { label: 'Greater Than', value: 'Greater Than' },
    { label: 'Less Than', value: 'Less Than' },
    { label: 'Greater Or Equal', value: 'Greater Or Equal' },
    { label: 'Less Or Equal', value: 'Less Or Equal' },
    { label: 'Contains', value: 'Contains' },
    { label: 'In', value: 'In' },
    { label: 'Relative Date', value: 'Relative Date' }
];
const RELATIVE_OPTIONS = [
    { label: 'N_DAYS_AGO', value: 'N_DAYS_AGO' },
    { label: 'LAST_N_DAYS', value: 'LAST_N_DAYS' },
    { label: 'LAST_N_WEEKS', value: 'LAST_N_WEEKS' },
    { label: 'LAST_N_MONTHS', value: 'LAST_N_MONTHS' },
    { label: 'LAST_N_YEARS', value: 'LAST_N_YEARS' }
];
const SCHEDULE_OPTIONS = [
    { label: 'Daily', value: 'Daily' },
    { label: 'Weekly', value: 'Weekly' },
    { label: 'Monthly', value: 'Monthly' },
    { label: 'Cron', value: 'Cron' }
];
const DAY_OPTIONS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
    .map((d) => ({ label: d, value: d }));

const STEPS = [
    { label: 'Basic Info', value: '1' },
    { label: 'Filter Builder', value: '2' },
    { label: 'Cascade & Settings', value: '3' },
    { label: 'Scheduling', value: '4' }
];

const DASHBOARD_COLUMNS = [
    { label: 'Policy', fieldName: 'name', type: 'text' },
    { label: 'Target Object', fieldName: 'targetObject', type: 'text' },
    { label: 'Action', fieldName: 'actionType', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'Schedule', fieldName: 'scheduleType', type: 'text' },
    { label: 'Conditions', fieldName: 'conditionCount', type: 'number', fixedWidth: 110 },
    { label: 'Last Run', fieldName: 'lastRun', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
    { label: 'Last Result', fieldName: 'lastRunStatus', type: 'text' },
    {
        type: 'action',
        typeAttributes: { rowActions: { fieldName: 'rowActions' } }
    }
];

export default class ArchivePolicyManager extends NavigationMixin(LightningElement) {
    @track policies = [];
    @track conditions = [];
    @track policy = {};
    @track objectOptions = [];
    @track fieldOptions = [];
    @track bigObjectOptions = [];
    @track logs = [];

    booleanOptions = BOOLEAN_OPTIONS;
    noBigObjects = false;

    columns = DASHBOARD_COLUMNS;
    actionOptions = ACTION_OPTIONS;
    operatorOptions = OPERATOR_OPTIONS;
    relativeOptions = RELATIVE_OPTIONS;
    scheduleOptions = SCHEDULE_OPTIONS;
    dayOptions = DAY_OPTIONS;
    steps = STEPS;

    view = 'dashboard'; // 'dashboard' | 'wizard'
    currentStep = '1';
    isLoading = false;
    isWorking = false;
    errorMessage;
    previewCount;
    previewRan = false;

    showLogs = false;
    logsPolicyName = '';

    connectedCallback() {
        this.loadPolicies();
    }

    // ---- dashboard ---------------------------------------------------------

    loadPolicies() {
        this.isLoading = true;
        getPolicies()
            .then((rows) => {
                this.policies = (rows || []).map((r) => ({
                    ...r,
                    rowActions: this.rowActionsFor(r)
                }));
            })
            .catch((e) => {
                this.errorMessage = this.reduceError(e);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    rowActionsFor(row) {
        const actions = [{ label: 'Run Now', name: 'run' }, { label: 'Edit', name: 'edit' }];
        if (row.status === 'Active') {
            actions.push({ label: 'Deactivate', name: 'deactivate' });
        } else {
            actions.push({ label: 'Activate', name: 'activate' });
        }
        actions.push({ label: 'View Logs', name: 'logs' });
        return actions;
    }

    handleRowAction(event) {
        const name = event.detail.action.name;
        const row = event.detail.row;
        if (name === 'run') {
            this.doRunNow(row.id);
        } else if (name === 'edit') {
            this.openEdit(row.id);
        } else if (name === 'activate') {
            this.doSetActive(row.id, true);
        } else if (name === 'deactivate') {
            this.doSetActive(row.id, false);
        } else if (name === 'logs') {
            this.openLogs(row.id, row.name);
        }
    }

    doRunNow(policyId) {
        this.isWorking = true;
        runNow({ policyId })
            .then(() => {
                this.toast('Run started', 'The policy is running in the background. Check its logs for results.', 'success');
            })
            .catch((e) => this.toast('Run failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    doSetActive(policyId, active) {
        this.isWorking = true;
        setActive({ policyId, active })
            .then(() => {
                this.toast(active ? 'Activated' : 'Deactivated',
                    active ? 'The policy is scheduled and active.' : 'The policy is inactive and unscheduled.', 'success');
                this.loadPolicies();
            })
            .catch((e) => this.toast('Update failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    // ---- wizard open/close -------------------------------------------------

    openNew() {
        this.policy = {
            Name: '',
            Target_Object__c: '',
            Action_Type__c: 'Soft Delete',
            Target_Big_Object__c: '',
            Filter_Logic__c: '',
            Batch_Size__c: 200,
            Cascade_Children__c: false,
            Schedule_Type__c: 'Daily',
            Schedule_Time__c: null,
            Day_Of_Week__c: 'Monday',
            Day_Of_Month__c: 1,
            Cron_Expression__c: ''
        };
        this.conditions = [];
        this.fieldOptions = [];
        this.bigObjectOptions = [];
        this.noBigObjects = false;
        this.currentStep = '1';
        this.previewRan = false;
        this.previewCount = undefined;
        this.view = 'wizard';
        this.ensureObjectOptions();
    }

    openEdit(policyId) {
        this.isWorking = true;
        getPolicy({ policyId })
            .then((detail) => {
                this.policy = { ...detail.policy };
                this.conditions = (detail.conditions || []).map((c, i) => ({
                    key: c.Id || `k${i}`,
                    id: c.Id,
                    sequence: c.Sequence__c || i + 1,
                    field: c.Field_API_Name__c,
                    operator: c.Operator__c,
                    value: c.Value__c,
                    relativeFunction: c.Relative_Function__c,
                    valueOptions: []
                }));
                this.currentStep = '1';
                this.previewRan = false;
                this.view = 'wizard';
                return this.ensureObjectOptions().then(() => {
                    if (this.policy.Target_Object__c) {
                        return Promise.all([
                            this.loadFields(this.policy.Target_Object__c),
                            this.loadBigObjects(this.policy.Target_Object__c)
                        ]).then(() => this.enrichPicklistConditions());
                    }
                    return null;
                });
            })
            .catch((e) => this.toast('Load failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    cancelWizard() {
        this.view = 'dashboard';
        this.loadPolicies();
    }

    ensureObjectOptions() {
        if (this.objectOptions.length) {
            return Promise.resolve();
        }
        return getObjectOptions()
            .then((opts) => {
                this.objectOptions = (opts || []).map((o) => ({ label: `${o.label} (${o.value})`, value: o.value }));
            })
            .catch((e) => this.toast('Load failed', this.reduceError(e), 'error'));
    }

    loadFields(objectApiName) {
        return getFieldOptions({ objectApiName })
            .then((opts) => {
                this.fieldOptions = (opts || []).map((o) => ({ label: `${o.label} (${o.value})`, value: o.value }));
            })
            .catch((e) => this.toast('Load failed', this.reduceError(e), 'error'));
    }

    // ---- wizard field handlers --------------------------------------------

    handlePolicyChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.policy = { ...this.policy, [field]: value };
        if (field === 'Target_Object__c' && value) {
            this.fieldOptions = [];
            this.policy = { ...this.policy, Target_Big_Object__c: '' };
            this.loadFields(value);
            this.loadBigObjects(value);
        }
    }

    loadBigObjects(sourceObject) {
        this.bigObjectOptions = [];
        this.noBigObjects = false;
        return getBigObjectsForSource({ sourceObject })
            .then((opts) => {
                this.bigObjectOptions = (opts || []).map((o) => ({ label: `${o.label} (${o.value})`, value: o.value }));
                this.noBigObjects = this.bigObjectOptions.length === 0;
            })
            .catch((e) => this.toast('Load failed', this.reduceError(e), 'error'));
    }

    // Jump to the Big Object Builder app's Configure screen to create a Big Object for this source.
    navigateToBuilder() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: BIG_OBJECT_BUILDER_TAB }
        });
    }

    addCondition() {
        this.conditions = [
            ...this.conditions,
            {
                key: `k${Date.now()}`,
                id: null,
                sequence: this.conditions.length + 1,
                field: '',
                operator: 'Equals',
                value: '',
                relativeFunction: 'N_DAYS_AGO',
                valueOptions: []
            }
        ];
    }

    removeCondition(event) {
        const key = event.target.dataset.key;
        this.conditions = this.conditions
            .filter((c) => c.key !== key)
            .map((c, i) => ({ ...c, sequence: i + 1 }));
    }

    handleConditionChange(event) {
        const key = event.target.dataset.key;
        const prop = event.target.dataset.prop;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.conditions = this.conditions.map((c) => (c.key === key ? { ...c, [prop]: value } : c));
        if (prop === 'field') {
            // New field: clear the value and (re)load picklist values if applicable.
            this.conditions = this.conditions.map((c) =>
                c.key === key ? { ...c, value: '', valueOptions: [] } : c
            );
            this.maybeLoadPicklist(key, value);
        }
    }

    maybeLoadPicklist(key, fieldApiName) {
        const type = this.fieldTypeOf(fieldApiName);
        if (type !== 'picklist' && type !== 'multipicklist') {
            return;
        }
        getPicklistValues({ objectApiName: this.policy.Target_Object__c, fieldApiName })
            .then((values) => {
                const mapped = (values || []).map((v) => ({ label: v.label, value: v.value }));
                this.conditions = this.conditions.map((c) =>
                    c.key === key ? { ...c, valueOptions: mapped } : c
                );
            })
            .catch(() => {
                /* leave as free text if picklist values can't load */
            });
    }

    enrichPicklistConditions() {
        this.conditions.forEach((c) => {
            if (c.field) {
                this.maybeLoadPicklist(c.key, c.field);
            }
        });
    }

    // ---- preview + save ----------------------------------------------------

    runPreview() {
        if (!this.policy.Target_Object__c) {
            this.toast('Pick an object', 'Select a target object first.', 'warning');
            return;
        }
        this.isWorking = true;
        getPreviewCount({
            targetObject: this.policy.Target_Object__c,
            conditionsJson: JSON.stringify(this.conditionsForApex()),
            filterLogic: this.policy.Filter_Logic__c
        })
            .then((count) => {
                this.previewCount = count;
                this.previewRan = true;
            })
            .catch((e) => this.toast('Preview failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    saveWizard() {
        if (!this.policy.Name || !this.policy.Target_Object__c) {
            this.toast('Missing info', 'Policy Name and Target Object are required.', 'warning');
            this.currentStep = '1';
            return;
        }
        if (this.policy.Action_Type__c === 'Move to Big Object' && !this.policy.Target_Big_Object__c) {
            this.toast('Missing Big Object', 'Move to Big Object needs a Target Big Object.', 'warning');
            this.currentStep = '1';
            return;
        }
        this.isWorking = true;
        savePolicy({
            policyJson: JSON.stringify(this.policyForApex()),
            conditionsJson: JSON.stringify(this.conditionsForApex())
        })
            .then(() => {
                this.toast('Saved', 'The archive policy has been saved.', 'success');
                this.view = 'dashboard';
                this.loadPolicies();
            })
            .catch((e) => this.toast('Save failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    policyForApex() {
        // Only the Archive_Policy__c field keys; drop any UI-only props.
        const p = this.policy;
        const out = {
            Name: p.Name,
            Target_Object__c: p.Target_Object__c,
            Action_Type__c: p.Action_Type__c,
            Target_Big_Object__c: p.Target_Big_Object__c,
            Filter_Logic__c: p.Filter_Logic__c,
            Batch_Size__c: p.Batch_Size__c,
            Cascade_Children__c: p.Cascade_Children__c,
            Schedule_Type__c: p.Schedule_Type__c,
            Schedule_Time__c: p.Schedule_Time__c,
            Day_Of_Week__c: p.Day_Of_Week__c,
            Day_Of_Month__c: p.Day_Of_Month__c,
            Cron_Expression__c: p.Cron_Expression__c
        };
        if (p.Id) {
            out.Id = p.Id;
        }
        return out;
    }

    conditionsForApex() {
        return this.conditions.map((c) => {
            const out = {
                Sequence__c: c.sequence,
                Field_API_Name__c: c.field,
                Operator__c: c.operator,
                Value__c: c.value,
                Relative_Function__c: c.relativeFunction
            };
            if (c.id) {
                out.Id = c.id;
            }
            return out;
        });
    }

    // ---- logs modal --------------------------------------------------------

    openLogs(policyId, policyName) {
        this.logsPolicyName = policyName;
        this.isWorking = true;
        getExecutionLogs({ policyId })
            .then((rows) => {
                this.logs = rows || [];
                this.showLogs = true;
            })
            .catch((e) => this.toast('Load failed', this.reduceError(e), 'error'))
            .finally(() => {
                this.isWorking = false;
            });
    }

    closeLogs() {
        this.showLogs = false;
        this.logs = [];
    }

    // ---- step navigation ---------------------------------------------------

    get isStep1() {
        return this.currentStep === '1';
    }
    get isStep2() {
        return this.currentStep === '2';
    }
    get isStep3() {
        return this.currentStep === '3';
    }
    get isStep4() {
        return this.currentStep === '4';
    }
    get isFirstStep() {
        return this.currentStep === '1';
    }
    get isLastStep() {
        return this.currentStep === '4';
    }

    nextStep() {
        this.currentStep = String(Math.min(4, parseInt(this.currentStep, 10) + 1));
    }
    prevStep() {
        this.currentStep = String(Math.max(1, parseInt(this.currentStep, 10) - 1));
    }

    // ---- view + conditional getters ---------------------------------------

    get isDashboard() {
        return this.view === 'dashboard';
    }
    get isWizard() {
        return this.view === 'wizard';
    }
    get hasPolicies() {
        return this.policies.length > 0;
    }
    get showBigObjectField() {
        return this.policy.Action_Type__c === 'Move to Big Object';
    }
    get isWeekly() {
        return this.policy.Schedule_Type__c === 'Weekly';
    }
    get isMonthly() {
        return this.policy.Schedule_Type__c === 'Monthly';
    }
    get isCron() {
        return this.policy.Schedule_Type__c === 'Cron';
    }
    get showTime() {
        return this.policy.Schedule_Type__c !== 'Cron';
    }
    get decoratedConditions() {
        return this.conditions.map((c) => {
            const kind = this.inputKind(this.fieldTypeOf(c.field), c.operator);
            return {
                ...c,
                valueOptions: c.valueOptions || [],
                showRelative: kind === 'relative',
                isPicklist: kind === 'picklist',
                isBoolean: kind === 'boolean',
                isDate: kind === 'date',
                isDatetime: kind === 'datetime',
                isNumber: kind === 'number',
                isText: kind === 'text'
            };
        });
    }

    fieldTypeOf(fieldApiName) {
        const match = this.fieldOptions.find((f) => f.value === fieldApiName);
        return match ? match.type : '';
    }

    // Decides which input a condition's value should use, from the field type + operator.
    inputKind(fieldType, operator) {
        if (operator === 'Relative Date') {
            return 'relative';
        }
        if (operator === 'In' || operator === 'Contains') {
            return 'text';
        }
        switch (fieldType) {
            case 'picklist':
            case 'multipicklist':
                return 'picklist';
            case 'boolean':
                return 'boolean';
            case 'date':
                return 'date';
            case 'datetime':
                return 'datetime';
            case 'currency':
            case 'double':
            case 'integer':
            case 'long':
            case 'percent':
                return 'number';
            default:
                return 'text';
        }
    }
    get previewLabel() {
        return this.previewRan ? `${this.previewCount} matching record(s)` : '';
    }
    get wizardTitle() {
        return this.policy.Id ? 'Edit Archive Policy' : 'New Archive Policy';
    }
    get hasLogs() {
        return this.logs.length > 0;
    }

    // ---- helpers -----------------------------------------------------------

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
