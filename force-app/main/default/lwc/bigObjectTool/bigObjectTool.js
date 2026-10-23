import { LightningElement, wire } from 'lwc';
import getSetupStatus from '@salesforce/apex/BigObjectSetupController.getSetupStatus';

/**
 * Unified "Big Object Builder" shell. A single left-nav workspace (one URL, no per-page icons)
 * that swaps the active tool in place — Dashboard, Configure, Browse, and Policies. Configure stays
 * gated behind the Metadata API Named Credential setup; the other sections need no setup.
 * Per-record Archive/Restore remain record-page Quick Actions and are intentionally not here.
 */
export default class BigObjectTool extends LightningElement {
    activeSection = 'dashboard';

    // Setup-gate state (applies to the Configure section only).
    credentialExists = false;
    verifiedThisSession = false;
    statusLoaded = false;

    @wire(getSetupStatus)
    wiredStatus({ data }) {
        if (data) {
            this.credentialExists = !!data.exists;
            this.statusLoaded = true;
        }
    }

    handleNavSelect(event) {
        this.activeSection = event.detail.name;
    }

    handleSetupComplete() {
        this.verifiedThisSession = true;
    }

    // ---- gate ----
    get isUnlocked() {
        return this.credentialExists || this.verifiedThisSession;
    }
    get showGateMessage() {
        return this.statusLoaded && !this.isUnlocked;
    }

    // ---- section routing ----
    get isDashboard() {
        return this.activeSection === 'dashboard';
    }
    get isConfigure() {
        return this.activeSection === 'configure';
    }
    get isBrowse() {
        return this.activeSection === 'browse';
    }
    get isPolicies() {
        return this.activeSection === 'policies';
    }
    get isSettings() {
        return this.activeSection === 'settings';
    }

    get headerTitle() {
        switch (this.activeSection) {
            case 'configure':
                return 'Configure Big Objects';
            case 'browse':
                return 'Browse Archived Records';
            case 'policies':
                return 'Archive Policies';
            case 'settings':
                return 'Settings';
            default:
                return 'Dashboard';
        }
    }

    get headerSubtitle() {
        switch (this.activeSection) {
            case 'configure':
                return 'Create archive Big Objects and map their fields.';
            case 'browse':
                return 'View and unarchive stored records.';
            case 'policies':
                return 'Define, schedule, and audit automated archival.';
            case 'settings':
                return 'Metadata API connection and object field mappings.';
            default:
                return 'Health and activity across your archives.';
        }
    }
}