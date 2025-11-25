import com.atlassian.jira.component.ComponentAccessor
import com.atlassian.jira.issue.MutableIssue
import com.atlassian.jira.bc.issue.search.SearchService
import com.atlassian.jira.jql.parser.JqlQueryParser
import com.atlassian.jira.issue.IssueInputParameters
import com.atlassian.jira.bc.issue.IssueService
import com.atlassian.jira.issue.label.LabelManager
import groovy.json.JsonSlurper
import org.apache.commons.io.FilenameUtils
import com.atlassian.jira.issue.comments.CommentManager

// =====================================================================
// CONFIG — UZUPEŁNIJ
// =====================================================================
final String TECH_USER = "automation"                // user wykonujący operacje
final String PROJECT_KEY = "OPS"                    // projekt
final String CF_EXTERNAL_ID = "customfield_12345"   // pole z ID
final String CF_LABELS = "customfield_98765"        // jeśli masz CF typu labels
// =====================================================================

def log = ComponentAccessor.getComponentOfType(org.apache.log4j.Logger)
def user = ComponentAccessor.userManager.getUserByName(TECH_USER)
def issueService = ComponentAccessor.issueService
def commentManager = ComponentAccessor.commentManager
def labelManager = ComponentAccessor.getComponent(LabelManager)

// =====================================================================
// 1. Pobranie treści maila
// =====================================================================
String body = message.getBody()
log.info("MAIL BODY:\n" + body)

// =====================================================================
// 2. Wycięcie JSON z tekstu
//    Szukamy pierwszej { i ostatniej }
// =====================================================================
int start = body.indexOf("{")
int end = body.lastIndexOf("}")

if (start < 0 || end < 0) {
    log.warn("Brak JSON w mailu.")
    return
}

String jsonText = body.substring(start, end + 1)

log.info("JSON extracted:\n" + jsonText)

// parse JSON
def json
try {
    json = new JsonSlurper().parseText(jsonText)
} catch(Exception e) {
    log.error("Niepoprawny JSON", e)
    return
}

// =====================================================================
// JSON EXPECTED FORMAT (TWÓJ MAIL):
//
// "akcja": "create" / "update"
// "klucz": "AROR-10"
// "typ_zgloszenia": "Bug"
// "pola": { ... }
// "etykiety": []
// =====================================================================

String externalId = json.klucz
String action = json.akcja?.toLowerCase()

// =====================================================================
// 3. Szukanie po custom field (externalId)
// =====================================================================
def jql = "\"External ID\" ~ \"${externalId}\" AND project = ${PROJECT_KEY}"
def query = ComponentAccessor.getComponent(JqlQueryParser).parseQuery(jql)
def results = ComponentAccessor.getComponent(SearchService)
        .search(user, query, com.atlassian.jira.web.bean.PagerFilter.getUnlimitedFilter())

MutableIssue issue = results.total > 0 ? results.issues[0] as MutableIssue : null
boolean isUpdate = issue != null

// =====================================================================
// 4. Mapowanie priorytetu
// =====================================================================
def mapPriority = { String p ->
    if (!p) return null
    switch(p.toLowerCase()) {
        case "medium": return "Normal"
        case "low": return "Minor"
        case "high": return "Major"
        default: return p
    }
}

// =====================================================================
// 5. Formatowanie DESCRIPTION (code blocks)
// =====================================================================
def formatDescription = { String desc ->
    if (!desc) return ""

    // zamieniamy {code}...{code} na format Jira
    desc = desc.replaceAll(/\{code\}/, "{code}")
    return desc
}

// =====================================================================
// 6. Tworzenie/Update issue
// =====================================================================
IssueInputParameters params = issueService.newIssueInputParameters()

if (!isUpdate) {
    log.info("TWORZENIE NOWEGO ISSUE")

    params
        .setSummary(json.pola?.tytul ?: externalId)
        .setDescription(formatDescription(json.pola?.opis))
        .setIssueTypeId("10001") // Task — zmień jeśli trzeba
        .setProjectKey(PROJECT_KEY)
        .addCustomFieldValue(CF_EXTERNAL_ID, externalId)

    def prio = mapPriority(json.pola?.priorytet)
    if (prio) params.setPriorityId(ComponentAccessor.constantsManager.priorities.findByName(prio)?.id)

    def validate = issueService.validateCreate(user, params)
    if (!validate.isValid()) {
        log.error("VALIDATION CREATE FAILED: " + validate.errorCollection)
        return
    }
    def result = issueService.create(user, validate)
    issue = result.issue as MutableIssue
    log.info("Created: " + issue.key)

} else {
    log.info("AKTUALIZACJA ISSUE " + issue.key)

    params.setDescription(formatDescription(json.pola?.opis))

    def prio = mapPriority(json.pola?.priorytet)
    if (prio) params.setPriorityId(ComponentAccessor.constantsManager.priorities.findByName(prio)?.id)

    def validate = issueService.validateUpdate(user, issue.id, params)
    if (!validate.isValid()) {
        log.error("VALIDATION UPDATE FAILED: " + validate.errorCollection)
        return
    }
    issueService.update(user, validate)
}

// =====================================================================
// 7. Labels — issue.labels + customfield labels
// =====================================================================
if (json.etykiety instanceof List) {
    def newLabels = json.etykiety*.toString().collect { it.trim().toLowerCase() }
    labelManager.setLabels(user, issue.id, newLabels.toSet(), false)
}

if (json.custom_labels instanceof List) {
    issue.setCustomFieldValue(
        ComponentAccessor.customFieldManager.getCustomFieldObject(CF_LABELS),
        json.custom_labels
    )
}

// =====================================================================
// 8. Załączniki ZIP
// =====================================================================
if (message.attachments) {
    def attachmentManager = ComponentAccessor.attachmentManager

    message.attachments.each { att ->
        if (FilenameUtils.getExtension(att.filename)?.toLowerCase() == "zip") {
            attachmentManager.createAttachment(
                    att.inputStream,
                    att.filename,
                    att.contentType,
                    user,
                    issue
            )
        }
    }
}

// =====================================================================
// 9. TRANSITION — po NAZWIE
// =====================================================================
def transitionName = json.pola?.status
if (transitionName) {
    def workflow = ComponentAccessor.workflowManager.getWorkflow(issue)
    def actions = workflow.getLinkedStep(issue.status).metaAttributes

    def transitions = ComponentAccessor.workflowManager.getTransitionsByName(issue, transitionName)
    if (transitions && transitions.size() == 1) {
        def transId = transitions[0].id

        def transValidate = issueService
                .validateTransition(user, issue.id, transId, issueService.newIssueInputParameters())

        if (transValidate.isValid()) {
            issueService.transition(user, transValidate)
            log.info("Transition executed: " + transitionName)
        }
    }
}

// =====================================================================
// 10. Komentarz z całego maila
// =====================================================================
commentManager.create(issue, user, body, false)

log.info("DONE.")
