/**
 * Creates a Big Object (__b) + its Permission Set through the FILE-BASED Metadata API deploy()
 * (a zipped package), not CRUD createMetadata(). This matters: non-index Big Object fields created
 * via createMetadata exist as metadata but never register in the queryable schema (FieldDefinition /
 * SOQL). A proper deploy() provisions every field as queryable.
 *
 * The deploy is asynchronous: startDeploy() returns a job id; the LWC polls checkStatus() until done.
 * The package zip is assembled in Apex with a self-contained "stored" (uncompressed) ZIP builder —
 * no third-party dependency. The Metadata API accepts stored zips.
 */
public with sharing class BigObjectDeployService {
    private static final String MD_NS = 'http://soap.sforce.com/2006/04/metadata';
    private static final String API_VERSION = '67.0';

    /** Async deploy status surfaced to the LWC. */
    public class DeployStatus {
        @AuraEnabled public Boolean done;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
    }

    /** Every Big Object field must be a deploy-safe local custom (__c) name. */
    @TestVisible
    private static String toBigObjectFieldName(String sourceApiName) {
        return sanitizeApiName(sourceApiName, '__c');
    }

    /**
     * Turns any raw string into a deploy-safe Salesforce DeveloperName with the given suffix
     * ('__b'/'__c'). Invalid chars -> '_', consecutive '_' collapsed (so managed-package namespaces
     * like pi__score and accidental double underscores both normalize), leading digits/underscores
     * and trailing underscores stripped, blank -> 'X', 40-char base cap. Idempotent + deterministic,
     * so this (Apex) and the LWC's sanitizeName agree on the final name.
     */
    @TestVisible
    private static String sanitizeApiName(String raw, String suffix) {
        String s = (raw == null) ? '' : raw.trim();
        if (suffix != null && s.length() >= suffix.length()
                && s.substring(s.length() - suffix.length()).equalsIgnoreCase(suffix)) {
            s = s.substring(0, s.length() - suffix.length());
        }
        s = s.replaceAll('[^a-zA-Z0-9_]', '_');
        s = s.replaceAll('_+', '_');
        s = s.replaceAll('^[_0-9]+', '');
        s = s.replaceAll('_+$', '');
        if (String.isBlank(s)) {
            s = 'X';
        }
        if (s.length() > 40) {
            s = s.substring(0, 40).replaceAll('_+$', '');
        }
        return s + (suffix == null ? '' : suffix);
    }

    /**
     * The final Big Object field API name: the user's custom name when provided,
     * otherwise the normalized source name. (The controller already normalizes it, so this
     * is a safe fallback for any path that builds a request directly.)
     */
    private static String effectiveBoName(BigObjectConfiguratorController.FieldSelection f) {
        // Always run the provided name through the sanitizer too (idempotent) so any path that builds
        // a request directly — not just the UI — produces a deploy-safe name.
        String raw = String.isBlank(f.bigObjectApiName) ? f.apiName : f.bigObjectApiName;
        return sanitizeApiName(raw, '__c');
    }

    // ---- Public entry points ----------------------------------------------

    /**
     * Starts a file-based deploy of the Big Object + Permission Set.
     * @param request Validated configuration from the controller.
     * @param checkOnly true = validate only (commits nothing); false = real deploy.
     * @return The async job id to poll with checkStatus().
     */
    public static String startDeploy(
        BigObjectConfiguratorController.BigObjectRequest request, Boolean checkOnly
    ) {
        MetadataService.MetadataPort service = MetadataServiceFactory.createService();

        // Authoritative, defense-in-depth: normalize the Big Object API name here too, so the object,
        // index, permission set, and file paths all use the same deploy-safe name regardless of input.
        request.apiName = sanitizeApiName(request.apiName, '__b');
        String psName = sanitizeApiName(request.apiName.removeEnd('__b') + '_Access', null);
        MetadataZip zip = new MetadataZip();
        zip.addFile('package.xml', buildPackageXml(request, psName));
        zip.addFile('objects/' + request.apiName + '.object', buildObjectXml(request));
        zip.addFile('permissionsets/' + psName + '.permissionset', buildPermissionSetXml(request, psName));

        // Every DeployOptions boolean must be set: apex-mdapi serializes them all, and a null one
        // goes over the wire as an empty string, which the SOAP endpoint rejects for xsd:boolean.
        MetadataService.DeployOptions options = new MetadataService.DeployOptions();
        options.allowMissingFiles = false;
        options.autoUpdatePackage = false;
        options.checkOnly = (checkOnly == true);
        options.ignoreWarnings = false;
        options.performRetrieve = false;
        options.purgeOnDelete = false;
        options.rollbackOnError = true;
        options.singlePackage = true;
        options.testLevel = 'NoTestRun';

        MetadataService.AsyncResult ar = service.deploy(zip.buildBase64(), options);
        return ar.id;
    }

    /** Polls a running deploy. */
    public static DeployStatus checkStatus(String jobId) {
        MetadataService.MetadataPort service = MetadataServiceFactory.createService();
        MetadataService.DeployResult dr = service.checkDeployStatus(jobId, true);

        DeployStatus status = new DeployStatus();
        status.done = (dr.done == true);
        status.success = ('Succeeded'.equalsIgnoreCase(dr.status));
        if (!status.done) {
            status.message = 'Deployment in progress...';
        } else if (status.success) {
            status.message = 'Big Object created successfully.';
        } else {
            status.message = buildFailureMessage(dr);
        }
        return status;
    }

    private static String buildFailureMessage(MetadataService.DeployResult dr) {
        List<String> problems = new List<String>();
        if (dr.details != null && dr.details.componentFailures != null) {
            for (MetadataService.DeployMessage dm : dr.details.componentFailures) {
                if (String.isNotBlank(dm.problem)) {
                    problems.add((String.isBlank(dm.fullName) ? '' : dm.fullName + ': ') + dm.problem);
                }
            }
        }
        if (problems.isEmpty()) {
            return String.isNotBlank(dr.errorMessage) ? dr.errorMessage : 'Deployment failed.';
        }
        return String.join(problems, ' | ');
    }

    // ---- Metadata (.object / .permissionset / package.xml) builders --------

    private static String buildPackageXml(
        BigObjectConfiguratorController.BigObjectRequest request, String psName
    ) {
        return '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<Package xmlns="' + MD_NS + '">\n'
            + '    <types><members>' + request.apiName + '</members><name>CustomObject</name></types>\n'
            + '    <types><members>' + psName + '</members><name>PermissionSet</name></types>\n'
            + '    <version>' + API_VERSION + '</version>\n'
            + '</Package>';
    }

    private static String buildObjectXml(BigObjectConfiguratorController.BigObjectRequest request) {
        Set<String> indexNames = new Set<String>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            indexNames.add(idx.apiName);
        }
        // Source field API name -> final Big Object field API name (honors custom overrides).
        Map<String, String> boNameBySource = new Map<String, String>();
        for (BigObjectConfiguratorController.FieldSelection f : request.fields) {
            boNameBySource.put(f.apiName, effectiveBoName(f));
        }
        String plural = String.isBlank(request.pluralLabel) ? request.label + 's' : request.pluralLabel;

        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<CustomObject xmlns="' + MD_NS + '">\n'
            + '    <deploymentStatus>Deployed</deploymentStatus>\n'
            + '    <label>' + xmlEscape(request.label) + '</label>\n'
            + '    <pluralLabel>' + xmlEscape(plural) + '</pluralLabel>\n';

        for (BigObjectConfiguratorController.FieldSelection f : request.fields) {
            xml += buildFieldXml(f, indexNames.contains(f.apiName));
        }

        xml += '    <indexes>\n'
            + '        <fullName>' + request.apiName.removeEnd('__b') + '_Index</fullName>\n'
            + '        <label>' + xmlEscape(truncate(request.label + ' Index', 40)) + '</label>\n';
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            String boName = boNameBySource.containsKey(idx.apiName)
                ? boNameBySource.get(idx.apiName)
                : toBigObjectFieldName(idx.apiName);
            xml += '        <fields>\n'
                + '            <name>' + boName + '</name>\n'
                + '            <sortDirection>' + ('DESC'.equalsIgnoreCase(idx.sortDirection) ? 'DESC' : 'ASC') + '</sortDirection>\n'
                + '        </fields>\n';
        }
        xml += '    </indexes>\n'
            + '</CustomObject>';
        return xml;
    }

    private static String buildFieldXml(
        BigObjectConfiguratorController.FieldSelection f, Boolean isIndex
    ) {
        String name = effectiveBoName(f);
        // Big Objects can't reference arbitrary lookup targets: polymorphic lookups and system/setup
        // objects (e.g. Group, ActionCadence) are not valid __b lookup targets. Since this is an
        // archive, store the related record Id as Text(18) rather than a live relationship —
        // universally valid across orgs, queryable, and it round-trips faithfully on restore.
        String effectiveType = (f.type == 'Lookup') ? 'Text' : f.type;
        // A Big Object Text column maxes at 255; anything longer is promoted to LongTextArea so the
        // value is never truncated.
        Integer textLen = null;
        if (effectiveType == 'Text') {
            textLen = (f.type == 'Lookup') ? 18 : (f.length == null ? 255 : f.length);
            if (textLen > 255) {
                effectiveType = 'LongTextArea';
            } else if (textLen < 1) {
                textLen = 255;
            }
        }
        // Big Object field labels (MasterLabel) max out at 40 characters.
        String x = '    <fields>\n'
            + '        <fullName>' + name + '</fullName>\n'
            + '        <label>' + xmlEscape(truncate(f.label, 40)) + '</label>\n'
            + '        <type>' + effectiveType + '</type>\n';
        if (effectiveType == 'Text') {
            x += '        <length>' + textLen + '</length>\n';
        } else if (effectiveType == 'LongTextArea') {
            // Big Object LongTextArea length must be 256..131072. Source TextAreas (e.g. address
            // Street = 255) describe below the minimum, so clamp into the valid range.
            Integer len = (f.length == null) ? 32768 : f.length;
            if (len < 256) {
                len = 256;
            } else if (len > 131072) {
                len = 131072;
            }
            x += '        <length>' + len + '</length>\n'
                + '        <visibleLines>3</visibleLines>\n';
        } else if (effectiveType == 'Number') {
            Integer p = (f.length == null || f.length <= 0) ? 18 : Math.min(f.length, 18);
            Integer s = (f.scale == null || f.scale < 0) ? 0 : f.scale;
            if (s >= p) {
                s = p - 1;
            }
            x += '        <precision>' + p + '</precision>\n'
                + '        <scale>' + s + '</scale>\n';
        }
        // Big Object rule: only index fields may be required.
        x += '        <required>' + (isIndex ? 'true' : 'false') + '</required>\n'
            + '    </fields>\n';
        return x;
    }

    private static String buildPermissionSetXml(
        BigObjectConfiguratorController.BigObjectRequest request, String psName
    ) {
        Set<String> indexNames = new Set<String>();
        for (BigObjectConfiguratorController.IndexFieldSelection idx : request.indexFields) {
            indexNames.add(idx.apiName);
        }
        String x = '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<PermissionSet xmlns="' + MD_NS + '">\n'
            + '    <label>' + xmlEscape(request.label + ' Access') + '</label>\n'
            + '    <hasActivationRequired>false</hasActivationRequired>\n'
            + '    <objectPermissions>\n'
            + '        <object>' + request.apiName + '</object>\n'
            + '        <allowRead>true</allowRead>\n'
            + '        <allowCreate>true</allowCreate>\n'
            + '        <allowEdit>false</allowEdit>\n'
            + '        <allowDelete>false</allowDelete>\n'
            + '        <viewAllRecords>false</viewAllRecords>\n'
            + '        <modifyAllRecords>false</modifyAllRecords>\n'
            + '    </objectPermissions>\n';
        // Index fields are required (implicitly accessible) — must NOT appear in fieldPermissions.
        for (BigObjectConfiguratorController.FieldSelection f : request.fields) {
            if (indexNames.contains(f.apiName)) {
                continue;
            }
            x += '    <fieldPermissions>\n'
                + '        <field>' + request.apiName + '.' + effectiveBoName(f) + '</field>\n'
                + '        <readable>true</readable>\n'
                + '        <editable>true</editable>\n'
                + '    </fieldPermissions>\n';
        }
        x += '</PermissionSet>';
        return x;
    }

    private static String xmlEscape(String s) {
        if (s == null) {
            return '';
        }
        return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;').replace('\'', '&apos;');
    }

    /** Cap a label at the given length (Big Object field/index labels max out at 40 chars). */
    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return '';
        }
        return s.length() > maxLen ? s.substring(0, maxLen) : s;
    }

    // ---- Self-contained "stored" ZIP builder -------------------------------

    private static final String HEXCHARS = '0123456789abcdef';
    private static Long[] crcTable;

    public class MetadataZip {
        private List<String> names = new List<String>();
        private List<String> dataHexes = new List<String>();

        public void addFile(String name, String content) {
            names.add(name);
            dataHexes.add(EncodingUtil.convertToHex(Blob.valueOf(content)));
        }

        public String buildBase64() {
            String local = '';
            String central = '';
            for (Integer i = 0; i < names.size(); i++) {
                String nameHex = EncodingUtil.convertToHex(Blob.valueOf(names[i]));
                String dataHex = dataHexes[i];
                Integer dataLen = dataHex.length() / 2;
                Integer nameLen = nameHex.length() / 2;
                Long crc = crc32(dataHex);
                Integer offset = local.length() / 2;

                // Local file header + data (method 0 = stored, no compression).
                local += '504b0304' + '1400' + '0000' + '0000' + '0000' + '2100'
                    + leHex(crc, 4) + leHex(dataLen, 4) + leHex(dataLen, 4)
                    + leHex(nameLen, 2) + '0000' + nameHex + dataHex;

                // Central directory record.
                central += '504b0102' + '1400' + '1400' + '0000' + '0000' + '0000' + '2100'
                    + leHex(crc, 4) + leHex(dataLen, 4) + leHex(dataLen, 4)
                    + leHex(nameLen, 2) + '0000' + '0000' + '0000' + '0000' + '00000000'
                    + leHex(offset, 4) + nameHex;
            }
            Integer entries = names.size();
            Integer cdOffset = local.length() / 2;
            Integer cdSize = central.length() / 2;
            String eocd = '504b0506' + '0000' + '0000'
                + leHex(entries, 2) + leHex(entries, 2)
                + leHex(cdSize, 4) + leHex(cdOffset, 4) + '0000';

            return EncodingUtil.base64Encode(EncodingUtil.convertFromHex(local + central + eocd));
        }
    }

    // Apex has no hex literals, so these constants are decimal: 255 = 0xFF,
    // 4294967295 = 0xFFFFFFFF, 3988292384 = 0xEDB88320 (the CRC-32 reversed polynomial).
    private static final Long MASK_BYTE = 255L;
    private static final Long MASK_32 = 4294967295L;
    private static final Long CRC_POLY = 3988292384L;

    /** Little-endian hex of a value across the given number of bytes. */
    private static String leHex(Long value, Integer numBytes) {
        String out = '';
        for (Integer i = 0; i < numBytes; i++) {
            out += byteHex((Integer) ((value >> (8 * i)) & MASK_BYTE));
        }
        return out;
    }

    private static String byteHex(Integer b) {
        b = b & 255;
        return HEXCHARS.substring(b / 16, b / 16 + 1) + HEXCHARS.substring(Math.mod(b, 16), Math.mod(b, 16) + 1);
    }

    /** CRC-32 (IEEE 802.3) over the bytes represented by a lowercase hex string. */
    private static Long crc32(String dataHex) {
        if (crcTable == null) {
            crcTable = new Long[256];
            for (Integer n = 0; n < 256; n++) {
                Long c = (Long) n;
                for (Integer k = 0; k < 8; k++) {
                    c = ((c & 1L) == 1L) ? (CRC_POLY ^ (c >>> 1)) : (c >>> 1);
                }
                crcTable[n] = c & MASK_32;
            }
        }
        Long crc = MASK_32;
        for (Integer i = 0; i < dataHex.length(); i += 2) {
            Integer b = (HEXCHARS.indexOf(dataHex.substring(i, i + 1)) * 16)
                + HEXCHARS.indexOf(dataHex.substring(i + 1, i + 2));
            Integer idx = (Integer) ((crc ^ b) & MASK_BYTE);
            crc = (crcTable[idx] ^ (crc >>> 8)) & MASK_32;
        }
        return (crc ^ MASK_32) & MASK_32;
    }
}
