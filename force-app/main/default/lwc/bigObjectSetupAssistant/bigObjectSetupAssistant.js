import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSetupStatus from '@salesforce/apex/BigObjectSetupController.getSetupStatus';
import testConnection from '@salesforce/apex/BigObjectSetupController.testConnection';

export default class BigObjectSetupAssistant extends LightningElement {
    status;
    errorMessage;
    isTesting = false;
    isDisconnecting = false;
    showDisconnectConfirm = false;
    connectionVerified = false;
    lastTestMessage;
    lastTestSuccess;
    autoChecked = false;

    _wiredStatus;

    @wire(getSetupStatus)
    wiredStatus(result) {
        this._wiredStatus = result;
        if (result.data) {
            this.status = result.data;
            this.errorMessage = undefined;
            // Verify once on load so the status reflects reality after a refresh.
            this.autoVerify();
        } else if (result.error) {
            this.errorMessage = this.reduceError(result.error);
        }
    }

    // Silent live check on load when the credential exists — no toast, just updates the status.
    autoVerify() {
        if (!this.exists || this.autoChecked || this.isTesting) {
            return;
        }
        this.autoChecked = true;
        testConnection()
            .then((result) => {
                this.connectionVerified = !!(result && result.isSuccess);
                this.lastTestSuccess = this.connectionVerified;
                this.lastTestMessage = result ? result.message : undefined;
            })
            .catch(() => {
                this.connectionVerified = false;
            });
    }

    // ---- derived state -----------------------------------------------------

    get isBusy() {
        return this.isTesting || this.isDisconnecting;
    }

    get exists() {
        return !!(this.status && this.status.exists);
    }

    get namedCredentialName() {
        return this.status ? this.status.namedCredentialName : 'Metadata_API';
    }

    get endpoint() {
        return this.status ? this.status.endpoint : undefined;
    }

    get isConnected() {
        return this.exists && this.connectionVerified;
    }

    get currentStep() {
        if (this.isConnected) {
            return 'done';
        }
        return this.exists ? 'test' : 'create';
    }

    get statusLabel() {
        if (this.isConnected) {
            return 'Setup Complete';
        }
        return this.exists ? 'Verify Connection' : 'Setup Required';
    }

    get statusTheme() {
        if (this.isConnected) {
            return 'slds-badge slds-theme_success';
        }
        return this.exists ? 'slds-badge slds-theme_warning' : 'slds-badge slds-theme_error';
    }

    get statusIcon() {
        if (this.isConnected) {
            return 'utility:success';
        }
        return this.exists ? 'utility:clock' : 'utility:warning';
    }

    get statusIconVariant() {
        if (this.isConnected) {
            return 'success';
        }
        return this.exists ? 'warning' : 'error';
    }

    get statusHeadline() {
        if (this.isConnected) {
            return 'Connected to the Metadata API.';
        }
        if (this.exists) {
            return 'Named Credential found — run a test to confirm it works.';
        }
        return 'Create the Named Credential below to connect the tool.';
    }

    get testButtonLabel() {
        return this.isConnected ? 'Re-test Connection' : 'Test Connection';
    }

    get testButtonDisabled() {
        // Always allow a live test — it is the only reliable truth about connectivity.
        return this.isTesting;
    }

    get isDisconnectDisabled() {
        return !this.exists || this.isDisconnecting;
    }

    get showSetupValues() {
        return !this.isConnected;
    }

    get showTestResult() {
        return this.lastTestMessage != null;
    }

    get testResultClass() {
        return this.lastTestSuccess
            ? 'slds-text-body_small slds-text-color_success slds-m-top_x-small'
            : 'slds-text-body_small slds-text-color_error slds-m-top_x-small';
    }

    // Setup pages live on the *.my.salesforce-setup.com domain. Derive it from the org (My Domain)
    // URL; fall back to a relative Setup path if the domain pattern is not recognized.
    get setupBase() {
        const url = (this.status && this.status.recommendedUrl) || '';
        if (url.indexOf('.my.salesforce.com') !== -1) {
            return url.replace('.my.salesforce.com', '.my.salesforce-setup.com');
        }
        return '';
    }

    get externalClientAppUrl() {
        return this.setupBase
            ? this.setupBase + '/lightning/setup/ManageExternalClientApplication/home'
            : '/lightning/setup/ManageExternalClientApplication/home';
    }

    get authProviderUrl() {
        return this.setupBase
            ? this.setupBase + '/lightning/setup/AuthProviders/home'
            : '/lightning/setup/AuthProviders/home';
    }

    get namedCredentialUrl() {
        return this.setupBase
            ? this.setupBase + '/lightning/setup/NamedCredential/home'
            : '/lightning/setup/NamedCredential/home';
    }

    get setupUrl() {
        return this.namedCredentialUrl;
    }

    // Step 1 — External Client App field/value table (copy where it helps).
    get step1Rows() {
        return [
            { key: 's1name', label: 'App Name', value: 'Metadata API App', copyable: true },
            { key: 's1oauth', label: 'Enable OAuth', value: 'Yes — enable OAuth settings', copyable: false },
            {
                key: 's1callback',
                label: 'Callback URL (temporary)',
                value: 'https://login.salesforce.com/services/oauth2/callback',
                copyable: true
            },
            { key: 's1scopes', label: 'OAuth Scopes', value: 'full, refresh_token, api', copyable: true }
        ];
    }

    // Step 2 — Auth Provider field/value table.
    get step2Rows() {
        return [
            { key: 's2type', label: 'Provider Type', value: 'Salesforce', copyable: false },
            { key: 's2name', label: 'Name', value: 'MetadataApiProvider', copyable: true },
            { key: 's2suffix', label: 'URL Suffix', value: 'MetadataApiProvider', copyable: true },
            { key: 's2key', label: 'Consumer Key', value: 'Paste from Step 1', copyable: false },
            { key: 's2secret', label: 'Consumer Secret', value: 'Paste from Step 1', copyable: false },
            { key: 's2scope', label: 'Default Scopes', value: 'full refresh_token', copyable: true }
        ];
    }

    // Step 3 — Named Credential field/value table (API name must be Metadata_API).
    get configRows() {
        const url = this.status ? this.status.recommendedUrl : '';
        return [
            { key: 'label', label: 'Label', value: 'Metadata API', copyable: true },
            { key: 'name', label: 'Name', value: this.namedCredentialName, copyable: true },
            { key: 'url', label: 'URL', value: url, copyable: true },
            { key: 'identity', label: 'Identity Type', value: 'Named Principal', copyable: false },
            { key: 'protocol', label: 'Authentication Protocol', value: 'OAuth 2.0', copyable: false },
            { key: 'provider', label: 'Authentication Provider', value: 'MetadataApiProvider', copyable: true },
            { key: 'scope', label: 'Scope', value: 'full refresh_token', copyable: true }
        ];
    }

    // ---- actions -----------------------------------------------------------

    handleOpenSetup() {
        window.open(this.setupUrl, '_blank');
    }

    handleOpenUrl(event) {
        const url = event.currentTarget.dataset.url;
        if (url) {
            window.open(url, '_blank');
        }
    }

    handleRecheck() {
        return refreshApex(this._wiredStatus);
    }

    handleCopy(event) {
        const value = event.currentTarget.dataset.value;
        if (!value) {
            return;
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard
                .writeText(value)
                .then(() => this.toast('Copied', value + ' copied to clipboard.', 'success'));
        } else {
            const el = document.createElement('textarea');
            el.value = value;
            this.template.host.appendChild(el);
            el.select();
            document.execCommand('copy');
            this.template.host.removeChild(el);
            this.toast('Copied', value + ' copied to clipboard.', 'success');
        }
    }

    handleTestConnection() {
        if (this.isTesting) {
            return;
        }
        this.isTesting = true;
        this.lastTestMessage = undefined;
        testConnection()
            .then((result) => {
                this.connectionVerified = !!(result && result.isSuccess);
                this.lastTestSuccess = this.connectionVerified;
                this.lastTestMessage = result ? result.message : 'Unknown error';
                if (this.connectionVerified) {
                    this.toast('Success', result.message, 'success');
                    this.dispatchEvent(new CustomEvent('setupcomplete'));
                } else {
                    this.toast('Connection failed', result ? result.message : 'Unknown error', 'error');
                }
            })
            .catch((error) => {
                this.connectionVerified = false;
                this.lastTestSuccess = false;
                this.lastTestMessage = this.reduceError(error);
                this.toast('Connection failed', this.lastTestMessage, 'error');
            })
            .finally(() => {
                this.isTesting = false;
            });
    }

    handleDisconnectClick() {
        this.showDisconnectConfirm = true;
    }

    handleDisconnectCancel() {
        this.showDisconnectConfirm = false;
    }

    // Non-destructive: this only resets the in-session connection state so the admin can
    // reconfigure. The Named Credential is NOT deleted (it stays in Setup).
    handleDisconnectConfirm() {
        this.connectionVerified = false;
        this.lastTestSuccess = false;
        this.lastTestMessage = undefined;
        this.autoChecked = true; // don't immediately auto re-verify this session
        this.showDisconnectConfirm = false;
        this.toast(
            'Disconnected',
            'Connection reset for this session. The Named Credential was kept — re-test or reconfigure below.',
            'success'
        );
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
