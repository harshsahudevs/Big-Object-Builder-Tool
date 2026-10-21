import { LightningElement, wire } from 'lwc';
import getSetupStatus from '@salesforce/apex/BigObjectSetupController.getSetupStatus';

/**
 * Gate wrapper: keeps bigObjectConfigurator locked until the Metadata API Named Credential
 * setup is complete. Unlocks immediately when the Setup Assistant fires `setupcomplete`,
 * and stays unlocked across reloads when getSetupStatus reports the credential exists.
 */
export default class BigObjectTool extends LightningElement {
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

    // Unlocked when the credential exists (survives reload) or was just verified live.
    get isUnlocked() {
        return this.credentialExists || this.verifiedThisSession;
    }

    get showGateMessage() {
        return this.statusLoaded && !this.isUnlocked;
    }

    handleSetupComplete() {
        this.verifiedThisSession = true;
    }
}
