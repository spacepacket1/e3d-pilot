// F vs E planted-error tasks (docs/methodology/expert-councils.md, arms E and F). Twelve short documents, each with three planted errors.
// An error counts as CAUGHT by an answer when every regex in `all` matches that answer (case-insensitive) AND a flag word is present
// (the answer is saying something is wrong, not restating the document). Keys are the specific facts that conflict, so a restatement alone does not match.
export const FLAG = /(inconsisten|contradict|mismatch|conflict|discrepan|doesn.t (match|add up)|does not (match|add up)|incorrect|wrong|error|should be|actually|miscalculat|off by|typo|but (section|the|it)|whereas|however)/i;
const E = (id, desc, ...all) => ({ id, desc, all });
export const TASKS = [
{ id: 't01', title: 'Pricing proposal', doc: `Pricing proposal for the team plan (draft 2).
Plan A is billed annually at $20 per seat per month, which is $240 per seat per year. For a team of 15 seats that is $3,000 per year.
Plan B is billed monthly at $30 per seat. For the same 15 seats that is $450 per month, or $5,400 per year.
We expect 60% of customers to choose Plan A, so the blended revenue per seat per year is 0.6 x $240 + 0.4 x $360 = $288.
Our cost to serve is $9 per seat per month, which is $108 per seat per year. The gross margin on Plan A is therefore ($240 - $108) / $240 = 71%.
Recommendation: launch with Plan A only, because Plan B has the lower margin, and revisit after one quarter.`,
  errors: [E('a', '15 x $240 is $3,600, not $3,000', /3,?000/, /3,?600/), E('b', 'Plan A margin is 55%, not 71%', /71\s*%/, /55\s*%|0\.55|55 percent/), E('c', 'Plan B margin is 64% which is higher than Plan A, so the stated reason is wrong', /plan b/i, /(higher|better|greater).{0,40}margin|margin.{0,60}(higher|better|greater)|64\s*%/)] },
{ id: 't02', title: 'Incident review', doc: `Incident review: checkout outage, 14 March.
Timeline (all times UTC). 09:12 the deploy of release 4.18 completed. 09:20 error rate on /checkout rose above 5%. 09:41 the on-call engineer was paged. 09:55 the release was rolled back. 10:10 error rate returned to normal.
Impact: checkout was degraded for 58 minutes, from 09:12 to 10:10. About 2,400 orders failed; at an average order value of $50 that is $120,000 of lost revenue.
Root cause: a database migration in 4.18 added an index without the CONCURRENTLY option, which locked the orders table. The alert that should have fired within 5 minutes did not, because its threshold was set to 10%.
Actions: lower the alert threshold to 2%; require CONCURRENTLY in migration review; add a rollback drill. The migration was written by the on-call engineer, so no further review is needed on the process.`,
  errors: [E('a', '2,400 x $50 = $120,000 is correct but degradation window: errors began 09:20 so 50 minutes not 58', /58/, /(09:20|50 minutes|50 min)/), E('b', 'Page at 09:41 is 21 minutes after errors began, but the alert was said to fire within 5 minutes and threshold 10% vs 5% error rate: with a 5% observed rate the 10% threshold would not fire, yet the paging happened; the page delay is unexplained / inconsistent', /(09:41|21 minutes)/, /(5\s*%|10\s*%)/), E('c', 'Conclusion that no process review is needed because the author was the on-call engineer is a non sequitur', /(author|written by|on-call)/i, /(non sequitur|does not follow|doesn.t follow|bias|independent|conflict|self-review|reviewed by someone|process review)/i)] },
{ id: 't03', title: 'API rate limit spec', doc: `Rate limit specification v2.
Each API key may make 600 requests per minute, which is an average of 20 requests per second. Bursts of up to 50 requests in one second are allowed.
When the limit is exceeded the API returns HTTP 429 with a Retry-After header. Clients must wait the number of seconds given before retrying.
Free keys are limited to 100 requests per minute (about 1.7 per second). Paid keys get 600. Enterprise keys get 3,000 requests per minute, which is 30 requests per second.
The limit window is a fixed one-minute window that resets on the minute, so a client can never exceed 600 requests in any 60-second period.
Limits are enforced per key, and each organisation may create up to 10 keys, so an organisation on the paid plan is limited to 6,000 requests per minute in total across all of its keys.`,
  errors: [E('a', '600 per minute is 10 per second, not 20', /20 requests per second|20 per second|20 requests\/s/i, /\b10\b/), E('b', '3,000 per minute is 50 per second, not 30', /30 requests per second|30 per second/i, /\b50\b/), E('c', 'A fixed window allows up to 1,200 in 60 seconds across a boundary, so "never exceed 600 in any 60-second period" is false', /fixed/i, /(boundary|1,?200|double|twice|straddl|edge of the window|sliding)/i)] },
{ id: 't04', title: 'Hiring plan', doc: `Engineering hiring plan, next two quarters.
We have 12 engineers today. Attrition has averaged 10% per year, so we expect to lose about 1 engineer over the next six months.
The target is 18 engineers by the end of Q2. That means 6 net new hires; with the expected departure we need to make 7 offers.
Offer acceptance is historically 50%, so we need to extend 14 offers to land 7 hires. Each hire takes 9 weeks from first interview to start date, and Q1 has 12 weeks left, so all hires can start within Q1.
Budget: a fully loaded engineer costs $200,000 per year. Seven hires for a half year is 7 x $200,000 x 0.5 = $700,000, which fits the $800,000 hiring budget.
Risk: none of the senior roles has an internal candidate, so we will rely on external recruiting.`,
  errors: [E('a', '12 to 18 is 6 net, plus 1 replacement = 7 hires; offers at 50% acceptance is 14 - consistent. Planted: 10% of 12 is 1.2 per YEAR, so six months is about 0.6; the expected departure is overstated', /(1 engineer|about 1|lose)/i, /(0\.6|half|six months|per year|annual)/i), E('b', 'All hires cannot start within Q1: 14 offers cannot all be run and start within the remaining 12 weeks at 9 weeks each unless fully parallel; more importantly a start within Q1 is claimed but the plan is for end of Q2 so spend timing is inconsistent with half-year budget', /(9 weeks|12 weeks)/, /(parallel|sequential|capacity|interview|timeline|not all|cannot all|unrealistic|half)/i), E('c', 'Half-year cost assumes everyone starts on day one; the plan has hires starting across Q1 so cost is lower, but also the budget claim uses 0.5 year for all 7 hires', /700,?000/, /(start|ramp|partial|phased|stagger|all (seven|7)|day one|full half)/i)] },
{ id: 't05', title: 'Study summary', doc: `Summary of a retention study.
We surveyed 400 customers who cancelled in 2024 and 400 customers who stayed. Of the cancelled group, 60 said price was the main reason, which is 20% of that group.
Among customers who stayed, 30% said they had contacted support at least once. Among those who cancelled, 45% had contacted support. We conclude that contacting support causes customers to cancel.
Our sample of cancelled customers was drawn from those who answered an optional exit survey; the response rate was 22%.
Satisfaction scores averaged 7.4 for the stayers and 6.9 for the cancelled group, a difference of 0.4 points, which we consider large.
Recommendation: reduce support contact by moving to a self-serve model, which we expect to cut cancellations in half.`,
  errors: [E('a', '60 of 400 is 15%, not 20%', /20\s*%/, /15\s*%|0\.15|15 percent/), E('b', 'Correlation is not causation: support contact likely follows problems', /(caus)/i, /(correlat|reverse|confound|because they have problems|already unhappy|reverse causation)/i), E('c', '7.4 minus 6.9 is 0.5 not 0.4; also self-selected exit survey with 22% response is a biased sample', /0\.4/, /(0\.5|self-select|selection bias|response rate|biased|non-response|22\s*%)/i)] },
{ id: 't06', title: 'Migration runbook', doc: `Runbook: move the primary database to the new cluster.
Estimated data size: 800 GB. The copy runs at a sustained 200 MB/s, so the initial copy takes about 40 minutes.
Plan: 1. Announce a maintenance window of 1 hour. 2. Put the app in read-only mode. 3. Start the copy. 4. When the copy finishes, switch the connection string and restart the app. 5. Verify row counts. 6. Re-enable writes.
The window is enough because the copy takes 40 minutes and the other steps take about 10 minutes together.
Rollback: if verification fails, point the app back to the old cluster and re-enable writes. The old cluster will be kept for 30 days.
Note: writes made to the new cluster before rollback do not need to be carried back because verification happens before writes are re-enabled.`,
  errors: [E('a', '800 GB at 200 MB/s is 4,000 seconds, about 67 minutes, not 40', /40 minutes/, /(67|66|4,?000 s|over an hour|about an hour|1 hour 7|exceeds)/i), E('b', 'Window of 1 hour is insufficient given 67+10 minutes', /(1 hour|one hour|window)/i, /(too short|insufficient|not enough|exceed|longer than|77 minutes|78)/i), E('c', 'Rollback after re-enable could lose writes; the note claims verification precedes writes but step 5 then 6 means any rollback after step 6 loses writes; also read-only so no issue; planted: no check for replication lag or consistency, "verify row counts" is not sufficient to prove integrity', /(row counts|verif)/i, /(checksum|integrity|not sufficient|insufficient|weak|only counts|consistency|hash)/i)] },
{ id: 't07', title: 'Market sizing', doc: `Market size estimate for a developer tool.
There are about 27 million software developers worldwide. We target professional developers at companies with more than 50 staff, which we estimate is 40% of the total, about 10.8 million.
We assume 5% adoption in year 3, which is 54,000 users. At $30 per month, annual revenue per user is $360, so year-3 revenue is about $19.4 million.
Competitors: the leading tool has 2 million paying users, so reaching 54,000 users is only 0.27% of their base, which shows the target is very conservative.
We therefore forecast 100% growth every year for the following five years, reaching $620 million in year 8.
The total addressable market is therefore at least $620 million.`,
  errors: [E('a', '5% of 10.8M is 540,000, not 54,000', /54,?000/, /540,?000/), E('b', '54,000 is 2.7% of 2 million, not 0.27%', /0\.27\s*%/, /2\.7\s*%|2\.7 percent/), E('c', 'Doubling five years from 19.4M gives 620M, but that is a forecast not a TAM, and TAM cannot be inferred from a growth forecast', /(total addressable|TAM)/i, /(forecast|not a TAM|cannot|conflat|confus|growth|not the same)/i)] },
{ id: 't08', title: 'Security policy excerpt', doc: `Password and access policy excerpt.
All staff passwords must be at least 12 characters and be changed every 90 days. Multi-factor authentication is required for all staff accounts.
Administrator accounts must use a hardware security key. Shared accounts are not permitted, except the break-glass account, which uses a shared password stored in the team wiki.
Access reviews are performed every 6 months. Accounts of departed staff are disabled within 30 days of the departure date.
Logs of administrator actions are retained for 90 days, which meets the requirement of our customers' contracts to retain security logs for one year.
Exceptions to this policy require approval from the person requesting the exception.`,
  errors: [E('a', 'Break-glass shared password stored in a wiki contradicts no shared accounts and weak storage', /(break-glass|shared)/i, /(wiki|plain|insecure|contradict|exception|vault|secrets manager)/i), E('b', '90 day retention does not meet a one year requirement', /90 days/, /(one year|1 year|12 months|365)/i), E('c', 'Exceptions approved by the requester is self-approval', /(exception)/i, /(requester|self-approv|themselves|independent|conflict of interest|separation)/i)] },
{ id: 't09', title: 'Roadmap commitment', doc: `Q3 roadmap commitment to the customer advisory board.
We have 5 engineers on the platform team, each with about 60 working days in the quarter after holidays and meetings, so 300 engineer-days of capacity.
Committed work: the SSO integration (80 days), the audit log export (60 days), the new billing page (90 days), the API v2 migration (120 days).
That totals 340 days, which is within the 300 available once we account for the 15% buffer we always keep.
Dependencies: SSO depends on the identity vendor delivering their SDK by 15 July; their last two releases slipped by a month each. We have marked this as low risk.
We are confident in committing to all four items for the end of Q3.`,
  errors: [E('a', '80+60+90+120 = 350, not 340', /340/, /350/), E('b', '350 or 340 exceeds 300, and with a 15% buffer capacity is 255', /(within|enough|fits)/i, /(255|exceed|over|more than|only 300|does not fit|doesn.t fit|beyond)/i), E('c', 'Vendor slipped a month twice, so low risk is unjustified', /(low risk|SDK|vendor)/i, /(slipp|history|track record|high risk|not low|unjustified|optimis)/i)] },
{ id: 't10', title: 'A/B test result', doc: `A/B test result: new onboarding flow.
Variant A (control): 5,000 visitors, 400 signups (8.0%). Variant B (new flow): 5,000 visitors, 460 signups (9.2%).
The relative improvement is 9.2 / 8.0 = 1.15, a 15% lift. We ran the test for 3 days, including a weekend promotion that drove most of the traffic to variant B.
The difference is statistically significant (p = 0.03) so we are shipping variant B to all users.
We also looked at 14 other metrics and found that time-on-page was significantly different at p = 0.04 for variant B, which we will report as a second win.
The expected annual benefit is 15% more signups, 15% x 10,000 signups per month x 12 = 18,000 extra signups a year.`,
  errors: [E('a', 'The 15% lift applies to the baseline rate; 15% x 10,000 x 12 is 18,000 only if baseline is 10,000 per month, but baseline at 8% of traffic suggests different; planted: 460/5000 = 9.2% correct. Weekend promotion confounds the traffic allocation', /(weekend|promotion)/i, /(confound|bias|not random|skew|imbalanc|allocation|invalid)/i), E('b', 'Testing 14 other metrics at p=0.04 needs a multiple comparisons correction', /(14|other metrics|p = 0\.04|0\.04)/i, /(multiple|comparison|bonferroni|false positive|correction|chance|fishing)/i), E('c', 'Three days is too short to cover weekly cycles', /(3 days|three days)/i, /(too short|week|cycle|novelty|seasonal|full week)/i)] },
{ id: 't11', title: 'Release notes', doc: `Release notes, version 3.2.0.
New: the export endpoint now supports CSV and JSON. The previous version (3.1.0) supported only CSV.
Breaking change: the field "created" has been renamed to "created_at" in all responses. Clients that read "created" must update. This is a minor release so no action is needed for existing integrations.
Deprecated: the v1 authentication endpoint will be removed in version 3.4.0, planned for this month. Clients have until the end of next quarter to migrate.
Fixed: a bug where pagination returned duplicate rows when the page size was greater than 100.
Upgrade: run the migration script before starting the new version. The script is idempotent and safe to re-run, and it deletes the old "created" column.`,
  errors: [E('a', 'A breaking rename in a minor release contradicts "no action is needed" and semantic versioning', /(minor)/i, /(breaking|semver|semantic|major version|contradict|action)/i), E('b', 'Removal planned this month contradicts a migration window to end of next quarter', /(3\.4\.0|v1|removed)/i, /(this month|end of next quarter|contradict|inconsisten|timeline|window)/i), E('c', 'Deleting the old column in an idempotent re-runnable script makes rollback impossible / data loss; "safe" is unjustified', /(deletes|delete|drop)/i, /(rollback|irreversible|data loss|destructive|backup|not safe|unsafe)/i)] },
{ id: 't12', title: 'Budget request', doc: `Budget request for a data warehouse project.
Year one costs: licences $120,000; implementation $80,000; training $15,000; contingency 10% of the total, so $21,500. The total request is therefore $236,500.
Savings: the project will retire two legacy reporting tools costing $90,000 per year together, so the project pays for itself in just over two years.
We also expect to avoid hiring two analysts at $70,000 each, so a further $140,000 per year in savings.
With total savings of $230,000 per year against a cost of $236,500, the payback period is about 12 months.
Risks: the vendor has raised prices by 25% at each of the last two renewals, which we have not included. The licence cost above is therefore firm.`,
  errors: [E('a', '120+80+15 = 215; 10% is 21.5K; total 236.5K is right. Planted: payback with only the $90,000 saving is 236.5/90 = 2.6 years not just over two', /(just over two|two years|2 years)/i, /(2\.6|2\.63|nearly three|almost three|about 2\.6|more than two)/i), E('b', '236.5/230 is about 12.3 months only if the analysts are not hired; avoided hires are costs not incurred, not savings, if the headcount was never planned', /(avoid|analyst|hire|hiring)/i, /(not a saving|not real|never|speculative|cost avoidance|not budgeted|hypothetical)/i), E('c', 'Price rises of 25% at each renewal contradict "firm"', /(firm)/i, /(25\s*%|raised|renewal|contradict|not firm|not included|escalat)/i)] },
];
