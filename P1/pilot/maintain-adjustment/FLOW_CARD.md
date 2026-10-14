# Flow card: beneficiary-engagement-change-prj / maintain-adjustment

Source: research pack `research.json` sha256 581bca6b076ccc39 (no OSB code in this card).
Status: draft
Approver: 
Date: 

Approve by setting `Status: approved`, your name and the date, after checking every table against RESEARCH.md
and resolving or accepting each open question. The implementer does not start before that.

## 1 Entry

| Item | Value |
|---|---|
| transport | jms |
| destination | jndi.contributorAgreementTopic |
| is_topic | True |
| durable_subscription | true |
| selector | (resource='Contributory Wage') AND (eventType='update-approved') |
| message_type | Text |
| payload_format | json |
| nxsd | beneficiary-engagement-change-nxsd |

## 2 Branches (route ids)

| Route id | Condition (plain) | Condition (OSB) | Outputs |
|---|---|---|---|
| branch-hasppaengagement-check-ppa-path | hasPPAEngagement equals 'true' anywhere in the payload | $xmlvar//*:hasPPAEngagement/text()='true' | out-ppa-engagement |
| branch-hasgosiengagement-check-gosi-path | hasGOSIEngagement equals 'true' anywhere in the payload | $xmlvar//*:hasGOSIEngagement/text()='true' | out-maintain-adjustment |

## 3 Scenario mapping (from the logs → tests)

| Scenario | Messages in export | Branch / path | Output |
|---|---|---|---|
| hasPPAEngagement=true/hasGOSIEngagement=true | 0 | both / PPA + GOSI | out-ppa-engagement, out-maintain-adjustment |
| hasPPAEngagement=true/hasGOSIEngagement!=true | 0 | hasPPAEngagement check / PPA path | out-ppa-engagement |
| hasPPAEngagement!=true/hasGOSIEngagement=true | 0 | hasGOSIEngagement check / GOSI path | out-maintain-adjustment |
| hasPPAEngagement!=true/hasGOSIEngagement!=true | 0 | none / consumed, nothing sent | none |

## 4 Outputs

| Route id | Name | Destination | Property | Headers |
|---|---|---|---|---|
| out-maintain-adjustment | maintain-adjustment BS output | jndi.beneficiaryEngagementChangeQueue | out.maintain-adjustment | - |
| out-ppa-engagement | ppa-engagement BS output | jndi.ppaBeneficiaryEngagementChangeQueue | out.ppa-engagement | - |
| out-maintain-adjustment-error-queue | error queue output | jndi.contributorAgreementErrorQueue | out.maintain-adjustment-error-queue | errorCode←$fault errorCode, errorMessage←$fault detail or reason, debugInfo←$fault location stage, traceId←$uuId, resource←inbound user-header resource, eventType←inbound user-header eventType |

Error output: `out-maintain-adjustment-error-queue`.

## 5 Backends (L1: mock endpoints with stubs)

| Route id | Type | Operation | Called when | Response use | Retry | Timeout | On fault |
|---|---|---|---|---|---|---|---|
| none | | | | | | | |

## 6 Transforms (original files kept, run by camel-saxon / camel-xslt-saxon)

| Name | Purpose | fn-bea functions | Mappings in research |
|---|---|---|---|
| nXSD JSON-to-XML translation | JSON -> XML in $xmlvar for the two conditions only; body stays the original JSON | - | 0 |

## 7 Errors (one test each in FlowErrorTest)

| Scope | Catches | Goes to | Headers | Redelivery |
|---|---|---|---|---|
| pipeline error handler | all faults | maintain-adjustment-error-queue | errorCode, errorMessage, debugInfo, traceId, resource, eventType | none at pipeline level |

## 8 Log lines (same text as OSB, logName oracle.osb.logging.pipeline)

| Stage | Level | Template |
|---|---|---|
| request-logging-stage | INFO | Request Received to Project beneficiary-engagement-change-prj :: for PS maintain-adjustment from JMS contributorAgreementTopic for Resource Name: {resource} event with TraceID - {traceId} ::{body} |
| errorhandler-stage | INFO | Error captured for Project beneficiary-engagement-change-prj :: for PS maintain-adjustment with TraceID: {traceId} :: fault - {fault} |

## 9 Open questions (each: answered, or accepted with a reason, before approval)

- [ ] route vs publish: if both flags are true, does OSB send to both queues or only the first?
- [ ] errorCode values the error-queue consumer relies on
