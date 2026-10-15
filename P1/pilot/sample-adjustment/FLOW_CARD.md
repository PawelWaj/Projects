# Flow card: sample-change-prj / sample-adjustment

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
| destination | jndi.sampleTopic |
| is_topic | True |
| durable_subscription | true |
| selector | (resource='Sample Resource') AND (eventType='approved') |
| message_type | Text |
| payload_format | json |
| nxsd | sample-change-nxsd |

## 2 Branches (route ids)

| Route id | Condition (plain) | Condition (OSB) | Outputs |
|---|---|---|---|
| branch-haspartnerengagement-check-partner-path | hasPartnerEngagement equals 'true' anywhere in the payload | $xmlvar//*:hasPartnerEngagement/text()='true' | out-partner-engagement |
| branch-hasmainengagement-check-main-path | hasMainEngagement equals 'true' anywhere in the payload | $xmlvar//*:hasMainEngagement/text()='true' | out-sample-adjustment |

## 3 Scenario mapping (from the logs → tests)

| Scenario | Messages in export | Branch / path | Output |
|---|---|---|---|
| businessTransaction=?/hasPartnerEngagement=?/hasMainEngagement=? | 3 | error handler / payload not JSON | out-sample-adjustment-error-queue |
| hasPartnerEngagement=true/hasMainEngagement=true | 0 | both / partner + main | out-partner-engagement, out-sample-adjustment |
| hasPartnerEngagement=true/hasMainEngagement!=true | 0 | hasPartnerEngagement check / Partner path | out-partner-engagement |
| hasPartnerEngagement!=true/hasMainEngagement=true | 0 | hasMainEngagement check / Main path | out-sample-adjustment |
| hasPartnerEngagement!=true/hasMainEngagement!=true | 0 | none / consumed, nothing sent | none |

## 4 Outputs

| Route id | Name | Destination | Property | Headers |
|---|---|---|---|---|
| out-sample-adjustment | sample-adjustment BS output | jndi.mainQueue | out.sample-adjustment | - |
| out-partner-engagement | partner-engagement BS output | jndi.partnerQueue | out.partner-engagement | - |
| out-sample-adjustment-error-queue | error queue output | jndi.errorQueue | out.sample-adjustment-error-queue | errorCode←$fault errorCode, errorMessage←$fault detail or reason, debugInfo←$fault location stage, traceId←$uuId, resource←inbound user-header resource, eventType←inbound user-header eventType |

Error output: `out-sample-adjustment-error-queue`.

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
| pipeline error handler | all faults | sample-adjustment-error-queue | errorCode, errorMessage, debugInfo, traceId, resource, eventType | none at pipeline level |

## 8 Log lines (same text as OSB, logName oracle.osb.logging.pipeline)

| Stage | Level | Template |
|---|---|---|
| request-logging-stage | INFO | Request Received to Project sample-change-prj :: for PS sample-adjustment from JMS sampleTopic for Resource Name: {resource} event with TraceID - {traceId} ::{body} |
| errorhandler-stage | INFO | Error captured for Project sample-change-prj :: for PS sample-adjustment with TraceID: {traceId} :: fault - {fault} |

## 9 Open questions (each: answered, or accepted with a reason, before approval)

- [ ] 3 messages in 28 days start with `{[[` (raw log, not our masking) and have no resource header, so they were probably sent by hand: assumed OSB's nXSD fails on them -> error queue, as the Camel route does. Confirm once on the OSB test console.

- [ ] route vs publish: if both flags are true, does OSB send to both queues or only the first?
- [ ] errorCode values the error-queue consumer relies on
