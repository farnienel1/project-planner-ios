# Project Planner — UK Toolbox Talk Library (Comprehensive)

> **Companion to `HS-IMPLEMENTATION-REFERENCE.md`.** The embedded Toolbox Talk library and the issue/sign/track flow.
>
> ⚠️ **Safety / liability note.** These entries are **structured starting points** (title, purpose, key control points) to seed the library and drive the UI — **not** certified, ready-to-deliver scripts. Toolbox talks carry legal weight (CDM 2015 / HSWA 1974). The full body of any talk **must be reviewed and approved by a competent H&S person** for the specific site/task before issue. The `status` field (`draft` → `approved`) is that gate.

---

## 1. Model: universal library, filter operatives by trade

The library is **universal** — every firm sees all talks regardless of their own trades (a small main contractor issues across many trades). **Trade filtering happens at the recipient step:** when issuing, the manager filters *operatives* by the trade on each operative's profile (single-select: tap "Electrical" → see electricians). General talks (`isGeneral:true`) show to everyone. Identical in Projects and Small Works via the H&S tile.

## 2. Trades on operative profiles

`Trade` enum on `OperativeProfile.trade`: `general` (pseudo), `electrical`, `mechanical`, `plumbing_gas`, `groundworks`, `scaffolding`, `brick_block`, `joinery`, `drylining`, `painting`, `roofing`, `demolition`, `steel_fixing`, `plant`.

## 3. Data model

See `HS-IMPLEMENTATION-REFERENCE.md` §3 for `ToolboxTalk`, `OperativeProfile`, `ToolboxTalkIssue`, `ToolboxTalkSignature`, and the issue-time filter. `ToolboxTalk` carries `category`, `isGeneral`, `trades[]`, `purpose`, `keyPoints[]`, `source`, `status`, `version`.

---

## 4. SEED CONTENT

> Load as `source:"library"`. General → `isGeneral:true, trades:[]`. Trade talks → `isGeneral:false` + the section trade. Default General `approved`; trade talks per your competent person (`draft` blocks issue).

### 4.0 General H&S — all trades (`isGeneral:true`)

**TBT-GEN-001 · Working at Height**
Purpose: Falls from height are the single biggest cause of fatal and major injury in UK construction.
Key points:
   - Apply the hierarchy: avoid working at height, then prevent falls with collective protection, then minimise distance and consequences.
   - Select the right access equipment for the task and duration — tower, MEWP, podium or scaffold; never makeshift platforms.
   - Inspect ladders and stepladders before use; use only for short-duration light work where a risk assessment allows.
   - Ensure guardrails, toe boards and edge protection are fitted to all platforms and leading edges.
   - Where collective protection isn't possible use a harness to a suitable anchor, and confirm the rescue plan.
   - Keep exclusion zones below overhead work and never overreach from a platform.

**TBT-GEN-002 · Working Near Openings, Voids & Risers**
Purpose: Unprotected floor openings, stairwells and riser shafts cause falls and dropped-object incidents.
Key points:
   - Identify and protect every opening with fixed, load-rated covers or sturdy edge barriers.
   - Covers must be secured, clearly marked and never removed without authorisation and immediate reinstatement.
   - Guard riser shafts on every floor and keep them protected throughout the works.
   - Report any uncovered or unguarded opening immediately — do not walk past it.
   - Keep materials away from edges to prevent objects falling through openings.

**TBT-GEN-003 · Manual Handling**
Purpose: Musculoskeletal injuries from poor lifting and carrying are among the most common site injuries.
Key points:
   - Assess the Task, Individual, Load and Environment (TILE) before lifting.
   - Use mechanical aids — trolleys, hoists, vacuum lifters — wherever possible.
   - Keep a stable base, bend the knees not the back, and hold the load close to the body.
   - Never twist while carrying; turn with the feet instead.
   - Team-lift heavy or awkward loads and plan the route and resting points first.

**TBT-GEN-004 · Slips, Trips & Falls on the Level**
Purpose: Same-level slips and trips are the most frequently reported site injuries.
Key points:
   - Keep walkways clear and tidy — clean as you go.
   - Manage trailing cables and hoses with covers or routing off the ground.
   - Clean up spills immediately and use warning signs.
   - Ensure adequate lighting in work and access areas.
   - Wear suitable footwear and report damaged flooring or temporary ramps.

**TBT-GEN-005 · Personal Protective Equipment (PPE)**
Purpose: PPE is the last line of defence and only protects when correct, worn and maintained.
Key points:
   - Wear site-minimum PPE at all times: hard hat, hi-vis, safety boots and eye protection.
   - Use task-specific PPE — gloves, RPE, hearing protection — as the risk assessment requires.
   - Inspect PPE before use and ensure RPE is face-fit tested.
   - Report damaged or defective PPE and replace it; PPE is provided free of charge.
   - Store PPE correctly to keep it serviceable.

**TBT-GEN-006 · COSHH — Hazardous Substances**
Purpose: Many site materials are harmful to health if mishandled — COSHH controls protect you.
Key points:
   - Check the COSHH assessment and safety data sheet before using any substance.
   - Store and decant substances correctly and keep containers labelled.
   - Ensure adequate ventilation and use the RPE/gloves specified.
   - Never mix products; know the spill procedure and where the kit is.
   - Wash hands before eating, drinking or smoking.

**TBT-GEN-007 · Dust & Silica (RCS) Control**
Purpose: Respirable crystalline silica causes silicosis and lung cancer — exposure is cumulative and irreversible.
Key points:
   - Eliminate or substitute high-dust tasks where possible.
   - Use on-tool extraction (M-class) or water suppression when cutting, grinding or chasing.
   - Never dry-sweep — use an H or M-class vacuum.
   - Wear FFP3 RPE that has been face-fit tested.
   - Rotate tasks to reduce individual exposure time.

**TBT-GEN-008 · Noise at Work**
Purpose: Excessive noise causes permanent, irreversible hearing loss and tinnitus.
Key points:
   - Identify high-noise tasks and equipment, and use quieter alternatives where possible.
   - Observe hearing-protection zones and wear the protection provided.
   - Limit exposure time and maintain distance from noisy plant.
   - Report ringing in the ears or hearing changes early.
   - Maintain equipment to keep noise levels down.

**TBT-GEN-009 · Hand-Arm Vibration (HAVS)**
Purpose: Vibrating tools can cause permanent nerve and circulation damage to the hands and arms.
Key points:
   - Use low-vibration tools and keep cutting consumables sharp.
   - Observe trigger-time limits and take breaks from vibrating tools.
   - Rotate tasks among the team to reduce exposure.
   - Keep hands warm and dry to maintain circulation.
   - Report tingling, numbness or blanching fingers promptly.

**TBT-GEN-010 · Fire Safety & Emergency Procedures**
Purpose: Fire on site endangers everyone — prevention and a known escape plan save lives.
Key points:
   - Know your nearest exits, assembly point and how to raise the alarm.
   - Keep escape routes and fire points clear at all times.
   - Understand the extinguisher types and their correct use.
   - Store combustibles safely and control ignition sources.
   - Hot works require a separate permit and fire watch.

**TBT-GEN-011 · First Aid, Welfare & Accident Reporting**
Purpose: Quick reporting and access to first aid reduce harm and meet legal (RIDDOR) duties.
Key points:
   - Know who the first aiders are and where the kits and welfare facilities are.
   - Report ALL accidents and near-misses, however minor.
   - Know the site address for a 999 call.
   - Use welfare facilities and keep them clean.
   - Cooperate with any accident investigation.

**TBT-GEN-012 · Site Induction & Site Rules Refresh**
Purpose: Rules, traffic routes and hazards change as a project progresses — stay current.
Key points:
   - Understand site boundaries, one-way systems and segregation.
   - Know which areas are permit-controlled.
   - Sign in and out so everyone is accounted for in an emergency.
   - Observe speed limits and parking rules.
   - Be aware of the current high-risk activities on site.

**TBT-GEN-013 · Plant & Pedestrian Segregation**
Purpose: Being struck by a moving vehicle or plant is a leading cause of site fatalities.
Key points:
   - Keep to designated pedestrian walkways.
   - Make eye contact with operators before approaching plant.
   - Never walk behind reversing vehicles or into blind spots.
   - Observe exclusion zones and obey banksman signals.
   - Wear hi-vis at all times in plant areas.

**TBT-GEN-014 · Hand & Power Tools**
Purpose: Everyday tools cause frequent and sometimes serious injuries when misused or poorly maintained.
Key points:
   - Select the right tool for the job and inspect it before use (including PAT).
   - Keep guards in place and never remove safety features.
   - Use 110V or battery tools on site, not 230V.
   - Disconnect from power before adjusting or changing accessories.
   - Quarantine and report defective tools.

**TBT-GEN-015 · Adverse Weather**
Purpose: Heat, cold, rain and wind change the risk profile of most outdoor tasks.
Key points:
   - Stop work at height in high winds and secure loose materials.
   - Stay hydrated and protected from the sun in hot weather.
   - Take warm breaks and maintain grip and dexterity in the cold.
   - Beware of slippery surfaces in wet or icy conditions.
   - Review the forecast at the daily briefing.

**TBT-GEN-016 · Housekeeping & Waste**
Purpose: Good housekeeping prevents fires, trips and dropped objects and keeps the job efficient.
Key points:
   - Clear waste as you go and use the segregated skips provided.
   - Keep access routes, stairs and escape routes clear.
   - Stack materials safely and within load limits.
   - Control combustible waste to reduce fire risk.
   - Keep welfare and break areas clean.

**TBT-GEN-017 · Mental Health & Fatigue**
Purpose: Wellbeing and alertness are safety issues — fatigue and stress increase the risk of error.
Key points:
   - Recognise the signs of stress and fatigue in yourself and colleagues.
   - Speak up and use the support routes available — it's encouraged.
   - Manage working hours and take adequate rest.
   - Look out for one another on site.
   - Raise concerns early before they escalate.

**TBT-GEN-018 · Drugs & Alcohol**
Purpose: Being unfit for work through drink or drugs endangers you and everyone around you.
Key points:
   - Never attend site under the influence of drink or drugs.
   - Disclose prescription medicines that may affect your work.
   - Understand the site testing policy.
   - Report concerns about a colleague's fitness for work.
   - Seek help through the support routes if you need it.

**TBT-GEN-019 · Environmental Awareness — Spills & Pollution**
Purpose: Preventing pollution protects the environment and avoids prosecution.
Key points:
   - Store oils and chemicals in bunded areas away from drains.
   - Keep spill kits available and know how to use them.
   - Never allow any discharge to surface-water drains or watercourses.
   - Control dust, mud and noise affecting neighbours.
   - Report all spills immediately.

**TBT-GEN-020 · Near-Miss Reporting**
Purpose: Reporting near-misses prevents the accidents that haven't happened yet.
Key points:
   - Understand what a near-miss is — an unplanned event that could have caused harm.
   - Report near-misses promptly through the site system.
   - Reporting is no-blame — it's about learning, not fault.
   - Lessons learned are shared with the whole team.
   - Follow up that actions have been closed out.

**TBT-GEN-021 · Lone Working**
Purpose: Working alone increases the consequences of any incident.
Key points:
   - Get authorisation before any lone working.
   - Maintain a check-in regime and a means of raising the alarm.
   - Never carry out high-risk tasks alone (live work, confined space, height).
   - Keep an emergency contact informed of your location.
   - Use a buddy system where possible.

**TBT-GEN-022 · Temporary Works Awareness**
Purpose: Props, supports and falsework hold structures up — interfering with them risks collapse.
Key points:
   - Never alter or remove props, supports or scaffold without authorisation.
   - Report any movement, damage or deflection immediately.
   - Follow the temporary works design and loading sequence.
   - Obtain a permit before loading temporary works.
   - Respect exclusion zones around temporary works.

**TBT-GEN-023 · Asbestos Awareness**
Purpose: Disturbing asbestos releases lethal fibres; many pre-2000 buildings still contain it.
Key points:
   - Check the asbestos survey / register before disturbing any material.
   - STOP work immediately if you find suspected asbestos.
   - Do not disturb or attempt to remove it — only licensed contractors may.
   - Report the discovery and follow the unexpected-discovery procedure.
   - Decontaminate if you suspect exposure.

**TBT-GEN-024 · Confined Spaces Awareness**
Purpose: Confined spaces carry asphyxiation, engulfment and entrapment risks that kill.
Key points:
   - Identify confined spaces — chambers, tanks, risers, voids.
   - Never enter without a confined-space permit and gas testing.
   - Ensure ventilation, monitoring and a rescue plan are in place.
   - Only trained, authorised people may enter.
   - Never enter to attempt a rescue without the right equipment.

**TBT-GEN-025 · Dropped Objects & Tool Tethering**
Purpose: A small tool dropped from height carries enough energy to kill or cause life-changing head injuries.
Key points:
   - Treat every object at height as a potential dropped object — tools, offcuts, fixings and debris.
   - Tether hand tools and use closed containers or tool bags when working above others.
   - Fit toe boards, brick guards, netting or debris sheeting to platforms and edges.
   - Establish and respect exclusion zones beneath overhead work; never take a shortcut through one.
   - Never carry loose items up or down ladders — hoist or pass materials properly.
   - Report any dropped object, even where nobody was hurt, as a near miss.

**TBT-GEN-026 · Permit to Work Systems**
Purpose: Permits control the highest-risk activities on site by forcing checks before work starts.
Key points:
   - Know which activities are permit-controlled here: hot works, confined space, excavation, live electrical, roof access.
   - Work must not begin until the permit is issued, signed and in your possession.
   - Read the conditions — the permit describes controls that must be in place, not just permission to start.
   - A permit is time-limited and area-limited; if the job changes, stop and re-permit.
   - Sign the permit back when the work is finished or suspended, and leave the area safe.
   - Never sign a permit on someone else's behalf or work under an expired one.

**TBT-GEN-027 · Point-of-Work Risk Assessment (Take 5)**
Purpose: Conditions change through the day; the written risk assessment only describes how the job was expected to be.
Key points:
   - Pause before you start and check that the task, the area and the controls match the RAMS.
   - Look for what has changed since the briefing — other trades, weather, access, deliveries.
   - Identify who could be harmed by your work and who could harm you from above or alongside.
   - Confirm you have the right equipment, PPE and competence before the first cut or lift.
   - If anything has changed materially, stop and speak to your supervisor — do not improvise.
   - Record the check where the site requires it; it evidences the decision you made.

**TBT-GEN-028 · RAMS & Method Statement Briefing**
Purpose: The method statement is the agreed safe sequence of work — being briefed on it is a legal expectation, not paperwork.
Key points:
   - Every operative must be briefed on the RAMS for their task before starting and must sign the briefing record.
   - Ask questions if any step, control or sequence is unclear — a briefing is a conversation, not a signature hunt.
   - Follow the sequence as written; deviating from it removes the controls that were assessed.
   - Any change to method, equipment or sequence needs the RAMS revised and re-briefed.
   - Know where the current RAMS is kept and check you are working to the latest revision.
   - Raise it immediately if the method cannot be followed in practice on the ground.

**TBT-GEN-029 · Occupational Skin Health & Dermatitis**
Purpose: Cement, solvents, resins and constant wet work cause occupational dermatitis, which can end a trade career.
Key points:
   - Recognise the signs early: dryness, redness, itching, cracking or blistering, usually on the hands and forearms.
   - Avoid direct skin contact — use tools, decanting aids and the gloves specified in the COSHH assessment.
   - Change gloves when contaminated inside and never share gloves between operatives.
   - Wash with soap and warm water, dry thoroughly, and apply after-work cream.
   - Do not use solvents, thinners or fuel to clean skin.
   - Report skin changes early; health surveillance exists to catch this before it becomes permanent.

**TBT-GEN-030 · Eye Protection & Eye Injuries**
Purpose: Most site eye injuries are preventable and happen in seconds — from grinding sparks, dust, splashes and UV.
Key points:
   - Wear impact-rated eye protection as a site minimum and upgrade for the task.
   - Match the protection to the hazard: goggles for dust and splash, face shield for grinding and cutting, filters for welding.
   - Check lenses for scratches and pitting before use; damaged lenses reduce protection and vision.
   - Use anti-fog or ventilated types rather than lifting glasses to see better.
   - Never rub the eye after a foreign body — irrigate with clean eyewash and get first aid.
   - Prescription wearers must use overspecs or prescription safety eyewear, not ordinary glasses.

**TBT-GEN-031 · Hand & Finger Injuries — Glove Selection**
Purpose: Hand injuries are the most common reportable injury on site and gloves only help when the right type is chosen.
Key points:
   - Match the glove to the hazard: cut level for blades and sharp edges, chemical resistance for COSHH, grip for handling.
   - Gloves are not the first control — guarding, push sticks, clamps and better tools come first.
   - Never wear gloves near rotating machinery where entanglement is a risk.
   - Watch for pinch points, line-of-fire and crush zones when handling and landing materials.
   - Keep hands out of blind spaces; use a bar or hook rather than fingers to move or align loads.
   - Replace gloves as soon as they are cut, worn or contaminated.

**TBT-GEN-032 · Sharps, Needles & Biological Hazards**
Purpose: Refurbishment, strip-out and derelict sites can hide needles, sewage, bird droppings and rodent contamination.
Key points:
   - Never put hands into voids, gaps, ducts or bin bags you cannot see into — use a tool or mirror.
   - Treat all discarded needles as infectious; do not pick them up by hand.
   - Use the sharps procedure and container; report the find to the supervisor.
   - Wear appropriate gloves and cover all cuts and grazes with waterproof dressings before starting.
   - Know the risks of leptospirosis (Weil's disease) near water and rodents, and of psittacosis from bird guano.
   - After any needlestick or contamination, wash, encourage bleeding, report immediately and seek medical advice.

**TBT-GEN-033 · Working in Occupied & Live Buildings**
Purpose: Building users have not been inducted and do not know what your work involves.
Key points:
   - Segregate the works with robust barriers, screens and clear signage — not tape alone.
   - Maintain occupants' escape routes at all times and never block fire exits or fire doors.
   - Agree noisy, dusty and disruptive works with the client and give notice.
   - Control dust and fume from spreading into occupied areas; use extraction and negative pressure where needed.
   - Keep tools, materials and cables out of circulation routes and secure them when unattended.
   - Leave the area clean and safe at the end of every shift, not just at the end of the job.

**TBT-GEN-034 · Deliveries, Unloading & Vehicle Marshalling**
Purpose: Deliveries bring vehicles, lifting and unfamiliar drivers into an active site and are a common cause of serious injury.
Key points:
   - Book deliveries in and receive them in the designated area, never on the public highway unless agreed.
   - Use a trained marshall or banksman for all reversing and unloading.
   - Keep clear of the load-fall zone during offloading — never work under a suspended load.
   - Check the load is stable before releasing straps; unstable loads collapse when restraint is removed.
   - Brief the driver on site rules, PPE and where they may and may not walk.
   - Land materials on firm, level ground and stack within safe heights.

**TBT-GEN-035 · Abrasive Wheels & Cut-Off Saws**
Purpose: A bursting wheel or a kicking saw causes catastrophic injuries in an instant.
Key points:
   - Only trained and appointed persons may mount abrasive wheels.
   - Check the wheel speed rating against the machine and inspect for cracks before fitting.
   - Never exceed the wheel's maximum rpm or use a cutting disc for grinding.
   - Keep guards correctly set and never remove or wedge them back.
   - Control kickback: secure the workpiece, stand out of the line of the disc and use both hands.
   - Combine with dust suppression, eye, face, hearing and respiratory protection every time.

**TBT-GEN-036 · Ladders & Stepladders — Safe Use**
Purpose: Ladders remain a leading source of falls, usually because they are used for the wrong job or set up badly.
Key points:
   - Use a ladder only for short-duration, low-risk work where a safer platform is not reasonably practicable.
   - Pre-use check every time: stiles, rungs, feet, locking bars and labels.
   - Set leaning ladders at a 1:4 angle, on firm level ground, and secure them at the top or foot.
   - Maintain three points of contact and keep your body within the stiles — never overreach.
   - Do not carry heavy or bulky items up a ladder, and never stand on the top two steps of a stepladder.
   - Keep ladders away from doors, traffic routes and overhead lines.

**TBT-GEN-037 · Lifting Operations & Lift Plans (LOLER)**
Purpose: Every lift must be planned, supervised and carried out by competent people — LOLER makes this a legal duty.
Key points:
   - No lift starts without a lift plan appropriate to its complexity and an Appointed Person where required.
   - Know the roles on the day: Appointed Person, lift supervisor, operator and slinger/signaller.
   - Check accessories for LOLER certification, ID tags and damage before every use, and check the SWL against the load.
   - Establish the exclusion zone and keep everyone clear of the load path and out from under the load.
   - Agree the communication method — hand signals or radio — before the lift, and use one signaller only.
   - Carry out a trial lift of 100–200mm to check balance and rigging before the full lift.

**TBT-GEN-038 · Site Security & Unauthorised Access**
Purpose: An insecure site puts children, trespassers and neighbours at risk and puts the company in the dock.
Key points:
   - Keep hoarding, gates and fencing secure and report any breach or damage immediately.
   - Challenge politely anyone on site you do not recognise, or report them to the supervisor.
   - Sign visitors in and never allow anyone on site without an induction and escort.
   - Make plant, ladders, scaffolds and excavations safe against unauthorised use at the end of each shift.
   - Store hazardous substances, gas bottles and tools locked away out of hours.
   - Be alert to children playing near the boundary and to attractions such as water, mounds and scaffolds.

**TBT-GEN-039 · New Starters, Young Persons & Apprentices**
Purpose: Workers are most likely to be injured in their first weeks on a site, before they know its hazards.
Key points:
   - Every new starter gets a full induction before going to the work face — no exceptions for short visits.
   - Young persons under 18 need a specific risk assessment and closer supervision.
   - Pair new starters with an experienced buddy for their first period on site.
   - Never assume experience elsewhere means familiarity with this site's rules, routes and hazards.
   - Encourage questions — not knowing is safe, guessing is not.
   - Check understanding rather than asking "is that clear?"; ask them to explain it back.

**TBT-GEN-040 · Language, Literacy & Communicating Safely**
Purpose: Safety-critical information is worthless if the person receiving it does not understand it.
Key points:
   - Do not assume a signature on a briefing sheet means the content was understood.
   - Use pictures, demonstrations and site walkarounds alongside spoken briefings.
   - Provide translation or a competent interpreter where operatives do not speak English confidently.
   - Keep instructions short and specific; avoid jargon, abbreviations and slang.
   - Check understanding by asking open questions and having the method described back.
   - Anyone can ask for a briefing to be repeated — nobody should feel they must pretend to understand.

**TBT-GEN-041 · Violence, Aggression & Respect for People**
Purpose: Abuse, bullying and aggression are safety issues — they distract, isolate and cause people to take risks.
Key points:
   - Everyone on this site has the right to work free from harassment, bullying and discrimination.
   - Do not tolerate or join in with "banter" that targets a person's race, sex, faith, age or disability.
   - Report aggression from the public, occupants or visitors rather than confronting it.
   - Walk away from confrontation and get the supervisor involved.
   - Support colleagues who are targeted — bystanders make the difference.
   - Know the reporting and support routes, including anonymous ones.

**TBT-GEN-042 · Night, Shift & Out-of-Hours Working**
Purpose: The body is least alert at night, while lighting, supervision and rescue cover are all reduced.
Key points:
   - Plan task lighting to the standard required — general site lighting is not enough for detailed work.
   - Confirm first aid, supervision and emergency arrangements cover the whole shift.
   - Manage shift patterns and travel so nobody drives home exhausted.
   - Keep hydrated and take proper breaks; avoid heavy meals and excessive caffeine late in the shift.
   - Increase hi-vis standards and be extra alert around plant and traffic in the dark.
   - Report fatigue rather than pushing through — errors cluster in the last hours of a shift.

**TBT-GEN-043 · Rescue Planning & Emergency Recovery**
Purpose: Calling 999 is not a rescue plan — suspension trauma and confined-space collapse can kill within minutes.
Key points:
   - Every high-risk task needs a rescue plan written and rehearsed before work starts.
   - Know who performs the rescue, with what equipment, and where that equipment is right now.
   - A person suspended in a harness must be recovered in minutes, not hours.
   - Never enter a confined space to attempt a rescue without training, equipment and monitoring.
   - Make sure someone can direct the emergency services to the exact location on site.
   - Test the plan — a rescue that has never been practised usually fails.

**TBT-GEN-044 · Pushing, Pulling & Moving Loads on Wheels**
Purpose: Mechanical aids reduce lifting injuries but introduce their own crush, trap and runaway risks.
Key points:
   - Push rather than pull wherever possible so you can see ahead and control the load.
   - Check the route first for ramps, kerbs, steps, cables and changes of surface.
   - Keep the load stable and within the height that lets you see over or around it.
   - Use the brakes whenever the trolley or cage is stationary, especially on any slope.
   - Watch for feet, fingers and doorways — trapped hands are the common injury.
   - Get help for heavy, tall or awkward loads and never ride on trolleys or cages.

**TBT-GEN-045 · Sun Exposure & Skin Cancer Prevention**
Purpose: Outdoor workers receive several times the UV dose of indoor workers, and skin cancer is a recognised occupational disease.
Key points:
   - UV is a risk from spring to autumn and on cloudy days — not just in bright sunshine.
   - Keep shoulders, arms and the back of the neck covered; use a neck flap under the hard hat.
   - Apply a high-factor sunscreen to exposed skin and reapply through the day.
   - Take breaks in shade where possible, especially between 11am and 3pm.
   - Drink water regularly and recognise heat exhaustion: headache, cramps, dizziness, nausea.
   - Check moles and skin changes and get anything new or changing looked at.

**TBT-GEN-046 · Stop Work Authority & Challenging Unsafe Acts**
Purpose: Every person on site has the authority to stop work that is unsafe — using it is expected, not optional.
Key points:
   - If you believe a task is unsafe, stop it and tell your supervisor — you will be supported, not penalised.
   - Challenge unsafe acts you see, whatever trade or company the person belongs to.
   - Challenge the behaviour, not the person, and do it calmly and early.
   - Make the area safe before leaving it, and do not restart until the issue is resolved.
   - Escalate if the response is inadequate; there is always someone above.
   - Record what happened so the cause is fixed, not just the symptom.

**TBT-GEN-047 · Fire Doors, Compartmentation & Life Safety Systems**
Purpose: Cutting through a fire wall or wedging a fire door open removes protection the building depends on.
Key points:
   - Never wedge, prop or disable a fire door, including during material movements.
   - Any penetration through a fire-rated wall, floor or ceiling must be firestopped by a competent installer.
   - Do not isolate detection, alarm or sprinkler systems without authorisation and an impairment plan.
   - Reinstate temporary protection and firestopping before leaving the area at the end of the shift.
   - Report damaged fire doors, seals and missing firestopping — do not assume another trade will.
   - Keep records: life safety work forms part of the building's golden thread of information.

**TBT-GEN-048 · Mobile Phones & Distraction on Site**
Purpose: Distraction removes the attention that keeps you out of the line of fire around plant, edges and machinery.
Key points:
   - Do not use a phone while walking in plant or traffic areas, at height or near moving machinery.
   - Stop, stand clear in a safe place, and then take the call.
   - Never use a handheld phone while operating plant or driving on site.
   - Avoid earphones and anything that masks reversing alarms, horns and shouted warnings.
   - Respect site rules on photography, especially in secure or client-occupied areas.
   - Be aware that personal worries are distracting too — speak to someone if your head is not in the job.

### 4.2 Electrical (`electrical`)

**TBT-ELE-001 · Safe Isolation Procedure**
Purpose: Working on assumed-dead conductors that are actually live causes electrocution and arc-flash burns.
Key points:
   - Follow the safe isolation sequence and prove dead with an approved voltage indicator.
   - Prove the tester on a known source before and after (prove-test-prove).
   - Lock off the isolation and apply caution tags.
   - Never rely on a switch position alone.
   - Obtain a permit to work where required.

**TBT-ELE-002 · Working Near Live Services & Cable Strike**
Purpose: Hidden cables and live services cause serious burns, electrocution and explosions.
Key points:
   - Check drawings and scan with CAT & Genny before drilling, chasing or fixing.
   - Assume buried and embedded services are live.
   - Use safe-digging and safe-fixing practices near services.
   - Isolate circuits where possible before work.
   - Obtain a permit to break into existing installations.

**TBT-ELE-003 · Temporary Electrical Installations**
Purpose: Site supplies and leads are exposed to damage and weather.
Key points:
   - Use 110V centre-tapped-earth equipment on site.
   - Ensure RCD protection is in place and tested.
   - Route leads off the ground and away from traffic and water.
   - Inspect connectors and never daisy-chain extensions.
   - Report and quarantine damaged equipment.

**TBT-ELE-004 · Working in Risers & Confined Electrical Spaces**
Purpose: Restricted spaces add isolation, access and emergency-egress risks.
Key points:
   - Protect floor openings at every riser level.
   - Maintain strict isolation discipline.
   - Provide adequate task lighting.
   - Handle heavy cable drums with mechanical aids.
   - Keep a clear means of escape.

**TBT-ELE-005 · Live Working (Prohibited / Exceptional)**
Purpose: Live working is dangerous and only permitted in rare, justified circumstances.
Key points:
   - Live work must be avoided wherever reasonably practicable.
   - Only proceed with a specific risk assessment and written authorisation.
   - Use insulated tools, mats and appropriate PPE.
   - Only competent, authorised persons may work live.
   - Have an accompanying person and rescue arrangements.

**TBT-ELE-006 · Use of Test Instruments (GS38)**
Purpose: Faulty or wrongly-rated test leads cause arc-flash and shock.
Key points:
   - Use GS38-compliant test leads and probes with finger guards.
   - Check instruments are calibrated and undamaged.
   - Select the correct measurement category for the system.
   - Inspect leads before every use.
   - Replace damaged equipment, don't repair improvised.

**TBT-ELE-007 · Cable Tray & Containment at Height**
Purpose: Installing containment combines height work with sharp materials and handling.
Key points:
   - Select suitable access — tower, MEWP or podium.
   - Control dropped objects and tether tools.
   - Protect against sharp cut edges with gloves and deburring.
   - Handle long lengths with a second person.
   - Coordinate with trades working below.

**TBT-ELE-008 · Battery, Solar PV & Stored Energy**
Purpose: DC systems and batteries can't simply be switched off and carry arc and chemical risks.
Key points:
   - Understand that PV arrays remain live in daylight.
   - Isolate DC correctly and lock off.
   - Beware arc-flash energy in battery systems.
   - Handle batteries with correct PPE for acid/chemicals.
   - Only competent persons should work on stored-energy systems.

**TBT-ELE-009 · Cable Pulling & Handling**
Purpose: Pulling cables involves manual handling, trip and entanglement risks.
Key points:
   - Plan the pull and clear the route.
   - Use rollers and pulling aids to reduce strain.
   - Coordinate signals between team members.
   - Watch for trapped fingers and snatch loads.
   - Keep the area clear of other trades during the pull.

**TBT-ELE-010 · Working in Ceiling Voids & Above Ceilings**
Purpose: Confined, dusty voids with limited access and hidden services.
Key points:
   - Check for asbestos and live services before entry.
   - Use suitable access platforms, not ceiling grids.
   - Provide lighting and ventilation.
   - Beware fragile ceiling tiles and openings.
   - Limit time and rotate due to awkward postures.

**TBT-ELE-011 · Portable Appliance & Equipment Inspection**
Purpose: Damaged portable equipment is a major cause of electric shock and fire.
Key points:
   - Carry out user checks before each use.
   - Ensure PAT testing is in date.
   - Look for damaged leads, plugs and casings.
   - Remove and label defective equipment.
   - Never use taped-up or improvised repairs.

**TBT-ELE-012 · Working Near Overhead Power Lines**
Purpose: Contact with or arcing from overhead lines is frequently fatal.
Key points:
   - Identify overhead lines and establish exclusion zones.
   - Use goal posts and barriers to control plant.
   - Lower jibs and tipping bodies before moving.
   - Assume lines are live.
   - Follow GS6 clearance distances.

**TBT-ELE-013 · Electric Shock & Emergency Response**
Purpose: Knowing how to respond to a shock can save a life.
Key points:
   - Do not touch a casualty still in contact with a live source.
   - Isolate the supply before approaching.
   - Call for help and first aid immediately.
   - Start CPR if trained and the casualty is unresponsive.
   - Report and investigate the incident.

**TBT-ELE-014 · Generators & Temporary Power**
Purpose: Generators bring fuel, fumes and earthing hazards.
Key points:
   - Site generators in ventilated areas away from occupied spaces.
   - Ensure correct earthing and RCD protection.
   - Refuel with the engine off and control spills.
   - Keep combustibles away from hot exhausts.
   - Guard against carbon-monoxide build-up.

**TBT-ELE-015 · Fire Alarm & Emergency Lighting Works**
Purpose: Disabling life-safety systems during installation creates serious risk.
Key points:
   - Notify the principal contractor before isolating any system.
   - Use impairment procedures and a fire watch when systems are down.
   - Restore and test systems before leaving site.
   - Coordinate with other trades and occupants.
   - Document isolations and restorations.

**TBT-ELE-016 · EV Charger Installation**
Purpose: High-current DC/AC equipment with earthing and load considerations.
Key points:
   - Verify supply capacity and earthing arrangement.
   - Isolate and prove dead before work.
   - Follow manufacturer and IET Code of Practice guidance.
   - Protect cabling routes and provide RCD/RDC-DD protection.
   - Commission and test before energising.

**TBT-ELE-017 · Working in Plant Rooms & Switch Rooms**
Purpose: Concentrated electrical risk with restricted egress.
Key points:
   - Maintain isolation discipline and lock-off.
   - Keep the room tidy and exits clear.
   - Beware arc-flash from switchgear.
   - Use appropriate PPE.
   - Never work alone on high-risk equipment.

**TBT-ELE-018 · Drilling, Chasing & Fixing**
Purpose: Penetrations risk striking cables, pipes and structure.
Key points:
   - Scan before drilling or chasing into walls and slabs.
   - Control silica dust with extraction.
   - Check for structural or post-tensioned elements.
   - Wear eye and hearing protection.
   - Maintain safe access for overhead fixing.

**TBT-ELE-019 · Lighting Installation at Height**
Purpose: Repetitive overhead work with handling and dropped-object risk.
Key points:
   - Use appropriate access equipment for the height and duration.
   - Tether tools and control dropped objects.
   - Manage awkward postures with rotation.
   - Isolate circuits before work.
   - Coordinate with other trades.

**TBT-ELE-020 · Hand Tools for Electricians**
Purpose: Cutters, strippers and screwdrivers cause frequent cuts and punctures.
Key points:
   - Use insulated tools rated for the task.
   - Keep blades sharp and cut away from the body.
   - Inspect insulation on tools before use.
   - Store tools safely to prevent injury and damage.
   - Replace damaged tools.

**TBT-ELE-021 · Arc Flash Awareness & Protection**
Purpose: An arc flash releases intense heat, light and pressure in milliseconds and causes severe burns even without contact.
Key points:
   - Understand that arc energy rises with fault level — switchrooms and incomers carry the highest risk.
   - Work dead wherever reasonably practicable; arc flash is largely a live-working hazard.
   - Wear arc-rated clothing, face protection and gloves where live work is unavoidably authorised.
   - Avoid loose conductive items — watches, chains, metal tape measures and rings.
   - Keep the enclosure closed where possible and stand to the side when operating switchgear.
   - Never work alone on equipment with significant arc-flash potential.

**TBT-ELE-022 · Lock-Off, Tag-Out & Key Control**
Purpose: Most electrocutions during maintenance happen when someone re-energises a circuit another person is working on.
Key points:
   - Apply your own personal lock and tag — one lock per person, one key per lock.
   - Use a multi-lock hasp where several people work on the same isolation.
   - Never remove another person's lock or tag, for any reason, without the formal override procedure.
   - Tag with your name, date, contact number and the reason for isolation.
   - Verify the isolation by proving dead after locking off, not before.
   - Remove your lock only when your work is complete, the circuit is safe and you have told the permit holder.

**TBT-ELE-023 · Initial Verification & Dead Testing**
Purpose: Testing an installation places you in contact with conductors and equipment whose condition is unknown.
Key points:
   - Carry out dead tests — continuity, insulation resistance, polarity — before energising anything.
   - Isolate and lock off, and confirm nobody else can reconnect during the test.
   - Disconnect or protect sensitive equipment before applying insulation resistance test voltages.
   - Warn others in the area that testing is in progress and post notices.
   - Never leave test leads connected and unattended.
   - Record results as you go and investigate anomalies before moving to live tests.

**TBT-ELE-024 · Thermal Imaging & Live Panel Surveys**
Purpose: Thermographic surveys are done on energised equipment and open enclosures, which is inherently live working.
Key points:
   - A live survey requires a specific risk assessment, authorisation and arc-rated PPE.
   - Only a competent person may open and close the enclosure; the surveyor works at a safe distance.
   - Use insulated tools and avoid contact with any internal part.
   - Keep the number of people in the room to a minimum and control access.
   - Stop the survey if any equipment shows signs of damage, arcing or overheating — isolate instead.
   - Close and secure all panels before leaving the area.

**TBT-ELE-025 · Distribution Boards & Consumer Unit Changes**
Purpose: Working in boards means working close to live incoming terminals that are often not isolated.
Key points:
   - Identify the point of isolation upstream and confirm it before opening the board.
   - Remember the incoming tails and meter side may remain live after the main switch is off.
   - Involve the supply company or meter operator where cutting-out fuses must be pulled.
   - Shroud or insulate any live parts that must remain exposed.
   - Label circuits accurately and complete the schedule before handover.
   - Prove dead with a proved voltage indicator at every point you intend to touch.

**TBT-ELE-026 · Data, Fibre Optic & Comms Cabling**
Purpose: Low voltage does not mean low risk — fibre shards, laser light and shared containment create real hazards.
Key points:
   - Never look directly into a fibre end or an active transmitter; use a power meter, not your eye.
   - Dispose of fibre offcuts in a dedicated sharps container — glass shards embed in skin and fingers.
   - Keep food and drink away from splicing areas and wash hands afterwards.
   - Treat cleaving solvents and cleaners as COSHH substances and ventilate.
   - Segregate data from power containment and never assume a shared tray is dead.
   - Support and route cables properly; overloaded baskets fail without warning.

**TBT-ELE-027 · Laser Levels & Optical Radiation**
Purpose: Construction lasers can damage the retina and are easily misaligned into other people's eye level.
Key points:
   - Use the lowest class of laser adequate for the job and check the class marking.
   - Set the beam above or below head height and never align it at eye level.
   - Post warning signs at the boundary of the laser area and tell adjacent trades.
   - Never look into the beam or view it with optical instruments.
   - Switch off and cover the unit when not in use, and secure it against being knocked.
   - Remove reflective surfaces from the beam path where practicable.

**TBT-ELE-028 · Cable Drums — Storage, De-reeling & Handling**
Purpose: Drums are heavy, roll easily and cause crush injuries when they move unexpectedly.
Key points:
   - Store drums on firm level ground and chock them to prevent rolling.
   - Never roll a drum down a slope or attempt to control it by hand.
   - Use a drum stand, jacks and spindle to de-reel; never pull cable off a drum lying on its side.
   - Keep hands, feet and clothing clear of the rotating drum and the running cable.
   - Use mechanical handling for moving drums, not muscle.
   - Protect projecting nails and staples on wooden drums and dispose of them safely.

**TBT-ELE-029 · Trunking, Basket & Swarf — Sharp Edges**
Purpose: Cut containment leaves razor edges and hot swarf that cause lacerations and eye injuries.
Key points:
   - Deburr and file all cut edges immediately after cutting, before installation.
   - Fit end caps and edge protection to open ends at head and hand height.
   - Wear cut-resistant gloves and eye protection when cutting and handling.
   - Control swarf — it embeds in skin, contaminates the area and shorts live equipment.
   - Use the correct tool for the cut, secured in a vice or stand rather than held by hand.
   - Clear offcuts as you go rather than leaving sharps on floors and platforms.

**TBT-ELE-030 · Electrical Work in Wet & Damp Environments**
Purpose: Water dramatically lowers body resistance and turns a survivable shock into a fatal one.
Key points:
   - Do not work on or near electrical equipment in standing water or heavy rain without controls.
   - Use RCD protection and keep connections, joints and transformers out of wet areas and off the ground.
   - Use IP-rated enclosures and connectors suited to the environment.
   - Keep hands, gloves and boots dry and change wet PPE.
   - Beware of condensation and leaks in plant rooms, basements and external cabinets.
   - Isolate and dry out flooded equipment before energising; never assume it has recovered.

**TBT-ELE-031 · Earthing & Bonding Works**
Purpose: Disconnecting an earth or bond removes the protection that makes a fault survivable.
Key points:
   - Never break a main earthing conductor or bond without a temporary continuity bond in place.
   - Confirm the earthing arrangement of the installation before altering anything.
   - Treat exposed metalwork as potentially live when earthing is disturbed.
   - Test continuity after any alteration and record the results.
   - Label and protect earth conductors so other trades do not cut them.
   - Be aware of rising earth potential near substations and lightning protection systems.

**TBT-ELE-032 · Temporary Site Lighting Installation**
Purpose: Temporary lighting is installed early, damaged often, and relied on for safe movement around site.
Key points:
   - Use reduced low voltage or suitably protected 230V festoon with RCD protection.
   - Install lighting to cover access routes, stairs, excavations and work faces, not just work areas.
   - Fix fittings securely; never hang them from cables, scaffold tubes or services.
   - Keep leads off the ground and clear of water, plant routes and sharp edges.
   - Provide emergency and escape-route lighting where the site requires it.
   - Inspect and replace damaged fittings promptly rather than working in gloom.

**TBT-ELE-033 · Working on Existing & Legacy Installations**
Purpose: Old installations hide undocumented circuits, obsolete wiring colours and unsafe previous work.
Key points:
   - Never trust existing labelling — trace and prove every circuit for yourself.
   - Be aware of old wiring colours, rubber and lead-sheathed cable and asbestos-containing components.
   - Expect back-feeds, borrowed neutrals and unexpected interconnections between boards.
   - Isolate wider than you think necessary and prove dead at every point of work.
   - Stop and report any material you suspect contains asbestos.
   - Record what you find and update the schedules for whoever comes next.

**TBT-ELE-034 · Switchgear Racking & Breaker Operation**
Purpose: Racking a breaker in or out releases stored mechanical and electrical energy at close range.
Key points:
   - Only authorised, competent persons may rack or operate switchgear.
   - Use remote racking where available and stand to the side of the panel.
   - Wear arc-rated PPE and confirm the operating sequence before you start.
   - Never force a mechanism — interlocks exist for a reason.
   - Confirm indication and position after every operation rather than assuming.
   - Restrict access to the room and keep the escape route behind you clear.

**TBT-ELE-035 · HV & Substation Awareness**
Purpose: High voltage can arc across air — you do not have to touch anything to be killed.
Key points:
   - Never enter an HV substation or enclosure without authorisation and an HV permit.
   - Observe barriers, signage and minimum approach distances at all times.
   - Assume all HV equipment is live, including after switching, until earths are applied.
   - Only an Authorised Person may switch, earth or issue permits on HV systems.
   - Keep ladders, scaffold tubes and long items well clear of HV enclosures.
   - Report unlocked or damaged HV enclosures immediately.

**TBT-ELE-036 · UPS & Standby Power Systems**
Purpose: UPS and standby systems energise circuits automatically, even when the mains supply is isolated.
Key points:
   - Isolating the mains does not make a UPS-fed circuit dead — isolate the UPS output too.
   - Battery strings remain live at all times and carry very high fault currents.
   - Follow the manufacturer's shutdown and bypass sequence exactly.
   - Beware auto-start generators — inhibit the start signal and lock it off.
   - Wear appropriate PPE for battery electrolyte and observe ventilation requirements.
   - Prove dead at the point of work after every isolation step.

**TBT-ELE-037 · Commissioning, Energisation & Handover**
Purpose: Energising an installation changes it from a construction area to a live electrical system in one moment.
Key points:
   - Confirm all dead testing is complete and recorded before applying power.
   - Notify everyone working in or near the installation and clear the area of other trades.
   - Post live warning notices and secure panels and enclosures.
   - Energise in a planned sequence, section by section, checking as you go.
   - Do not leave partially commissioned equipment live and unattended without protection.
   - Hand over formally with certificates, schedules and as-installed information.

**TBT-ELE-038 · Core & Diamond Drilling for Electrical Routes**
Purpose: Coring combines water, electricity, silica dust, structural risk and heavy falling cores.
Key points:
   - Obtain permission and a permit before coring any structural element.
   - Scan for reinforcement, post-tensioning and buried services before drilling.
   - Control the water supply and slurry so it cannot reach live equipment or floors below.
   - Secure the rig, and catch or support the core so it cannot fall through.
   - Protect and barrier the area below the drilling point.
   - Make good and firestop the penetration before leaving.

**TBT-ELE-039 · Fire Stopping Around Electrical Penetrations**
Purpose: An unsealed cable penetration lets fire and smoke pass through a compartment wall in minutes.
Key points:
   - Every penetration through a fire-rated element must be sealed with a tested, compatible system.
   - Use the correct product for the substrate, cable type and fire rating — do not improvise with foam.
   - Do not overfill a penetration with cables beyond the tested configuration.
   - Seal temporarily at the end of each shift where the permanent seal is not yet possible.
   - Photograph and record each seal — it forms part of the building safety record.
   - Report any penetration you find unsealed, whoever made it.

**TBT-ELE-040 · Site Accommodation & Welfare Unit Electrics**
Purpose: Cabins are lived in all day and their electrics are frequently overloaded and abused.
Key points:
   - Ensure the supply, RCD protection and earthing to cabins are installed and tested by a competent person.
   - Do not overload sockets with extension leads, heaters and kettles.
   - Inspect and PAT test appliances in welfare areas as for any other site equipment.
   - Route and protect the supply cable so vehicles and plant cannot damage it.
   - Check smoke detection and emergency lighting in cabins are working.
   - Report and remove damaged appliances, sockets and leads immediately.

### 4.3 Mechanical / HVAC (`mechanical`)

**TBT-MEC-001 · Hot Works — Welding, Brazing & Cutting**
Purpose: Hot works are a leading cause of construction fires.
Key points:
   - Obtain a hot works permit before starting.
   - Remove or protect combustibles within the work zone.
   - Maintain a fire watch during and for at least 60 minutes after.
   - Use local exhaust ventilation for fume.
   - Use screens and store gas bottles correctly.

**TBT-MEC-002 · Pressure Testing of Pipework**
Purpose: Stored energy in pressurised systems can release violently.
Key points:
   - Follow the test procedure and pressure limits.
   - Establish an exclusion zone during testing.
   - Use calibrated, in-date gauges.
   - Pressurise gradually and never leave under test unattended.
   - Depressurise fully before adjusting.

**TBT-MEC-003 · Ductwork Installation at Height**
Purpose: Large, awkward components installed overhead.
Key points:
   - Use MEWPs or towers suited to the load and height.
   - Control dropped objects and tether tools.
   - Team-lift large duct sections.
   - Coordinate with trades working below.
   - Manage sharp edges with gloves.

**TBT-MEC-004 · Lifting & Rigging of Plant**
Purpose: Lifting AHUs, chillers and heavy plant involves serious load risks.
Key points:
   - Work to a lift plan with an appointed person.
   - Use LOLER-inspected lifting gear.
   - Establish exclusion zones and use tag lines.
   - Never stand under a suspended load.
   - Observe weather limits for lifting.

**TBT-MEC-005 · Refrigerants & F-Gas Handling**
Purpose: Refrigerants can asphyxiate and cause cold burns; some are flammable.
Key points:
   - Only F-Gas competent persons may handle refrigerants.
   - Ensure ventilation and beware oxygen displacement.
   - Use leak detection.
   - Recover refrigerant safely — never vent to atmosphere.
   - Wear correct PPE for cold burns.

**TBT-MEC-006 · Commissioning Rotating Plant**
Purpose: Test-running pumps, fans and motors creates entanglement and energy risks.
Key points:
   - Fit and check guarding before running.
   - Lock off before accessing moving parts.
   - Beware entanglement with loose clothing and tools.
   - Maintain isolation discipline.
   - Run controlled tests with clear communication.

**TBT-MEC-007 · Insulation & Lagging**
Purpose: Mineral fibres irritate skin and lungs; old lagging may contain asbestos.
Key points:
   - Wear RPE and skin protection for fibre work.
   - Treat legacy lagging as possible asbestos — stop and report.
   - Control dust and offcuts.
   - Use sharp knives safely, cutting away from the body.
   - Keep the area tidy.

**TBT-MEC-008 · Plant Room Working**
Purpose: Concentrated services, noise, heat and restricted space.
Key points:
   - Beware hot surfaces and pipework.
   - Maintain isolation of services before work.
   - Manage noise with hearing protection.
   - Keep the room tidy and exits clear.
   - Use mechanical aids for heavy items.

**TBT-MEC-009 · Working with Compressed Gases**
Purpose: Cylinders are high-pressure hazards that can become missiles.
Key points:
   - Secure cylinders upright and transport with trolleys.
   - Keep oxygen away from oils and greases.
   - Use flashback arrestors on fuel gases.
   - Store full and empty cylinders separately and ventilated.
   - Check hoses and regulators before use.

**TBT-MEC-010 · Steam & High-Temperature Systems**
Purpose: Steam and hot fluids cause severe burns and scalds.
Key points:
   - Isolate, drain and confirm cool before work.
   - Beware residual pressure and trapped condensate.
   - Use appropriate PPE for hot surfaces.
   - Establish exclusion zones during commissioning.
   - Follow permit requirements.

**TBT-MEC-011 · Mechanical First & Second Fix at Height**
Purpose: Repetitive overhead pipe and component installation.
Key points:
   - Use suitable access for the task and duration.
   - Tether tools and control dropped objects.
   - Handle long pipework with two people.
   - Rotate to manage awkward postures.
   - Coordinate with other trades.

**TBT-MEC-012 · Pipe Freezing & Hot/Cold Work**
Purpose: Pipe-freezing and live system work bring cold-burn and release risks.
Key points:
   - Follow the procedure and manufacturer guidance.
   - Wear PPE for cold burns.
   - Manage water release and protect finishes.
   - Confirm isolation points.
   - Have a contingency for freeze failure.

**TBT-MEC-013 · Mechanical Lifting Aids & Hoists**
Purpose: Chain blocks and hoists used in tight spaces.
Key points:
   - Inspect lifting equipment before use (LOLER).
   - Confirm the safe working load.
   - Rig to suitable anchor points only.
   - Keep clear of suspended loads.
   - Use tag lines to control the load.

**TBT-MEC-014 · Working with Heavy Valves & Fittings**
Purpose: Large valves and fittings cause crush and handling injuries.
Key points:
   - Use mechanical aids and team lifts.
   - Beware trapped fingers and pinch points.
   - Support components during installation.
   - Plan the route and resting points.
   - Wear gloves and toe protection.

**TBT-MEC-015 · BMS & Controls Installation**
Purpose: Combines electrical, height and coordination risks.
Key points:
   - Isolate associated electrical circuits.
   - Use suitable access for ceiling/high-level work.
   - Coordinate with electrical and other trades.
   - Protect cabling and control panels.
   - Test safely before handover.

**TBT-MEC-016 · Soldering & Brazing Fume**
Purpose: Fume from fluxes and filler metals harms the lungs.
Key points:
   - Use local exhaust ventilation or work in ventilated areas.
   - Wear suitable RPE where needed.
   - Control hot works with a permit and fire watch.
   - Protect surrounding combustibles.
   - Allow joints to cool safely.

**TBT-MEC-017 · Working in Ceiling & Floor Voids**
Purpose: Confined, dusty access with hidden services.
Key points:
   - Check for asbestos and live services first.
   - Use crawl boards over fragile surfaces.
   - Provide lighting and ventilation.
   - Limit time due to awkward postures.
   - Beware openings and edges.

**TBT-MEC-018 · Drainage & Soil Pipe Installation**
Purpose: Below-ground and in-building drainage with biological and handling risks.
Key points:
   - Maintain hygiene and cover cuts (Weil's disease).
   - Apply excavation controls below ground.
   - Handle long pipe with care for the back.
   - Control solvent-weld fumes.
   - Beware confined-space chambers.

**TBT-MEC-019 · Mechanical Plant Commissioning Coordination**
Purpose: Multiple systems energised together raise cross-trade risks.
Key points:
   - Coordinate energisation with all trades.
   - Use permits for high-risk commissioning.
   - Communicate clearly before starting plant.
   - Keep exclusion zones around running plant.
   - Restore safety systems after testing.

**TBT-MEC-020 · Working with Chilled & LTHW Systems**
Purpose: Large water systems bring flooding, weight and commissioning risks.
Key points:
   - Confirm isolation and drain-down before breaking in.
   - Manage water release and protect finishes.
   - Handle heavy headers and pumps with aids.
   - Vent and fill systems safely.
   - Beware pressure during commissioning.

**TBT-MEC-021 · Ductwork Cleaning & Access Panels**
Purpose: Cleaning ductwork combines confined space, contamination and working at height in one task.
Key points:
   - Isolate and lock off fans and dampers before opening any access panel.
   - Treat accumulated dust and grease as a health and fire hazard; use RPE and avoid dry brushing.
   - Assess whether the duct is a confined space before entry and permit it accordingly.
   - Support and refit access panels correctly — loose panels fall and cut.
   - Beware sharp internal edges, fixings and insulation fibres.
   - Restore fire dampers and controls to service and record the work.

**TBT-MEC-022 · Air Handling Unit Assembly & Internal Access**
Purpose: AHUs are built in confined plant rooms from heavy sections with trapping and crush points.
Key points:
   - Plan the assembly sequence and the lifting method before the first section arrives.
   - Keep hands clear of mating faces when sections are being drawn together.
   - Isolate and lock off fans before entering any section; impellers freewheel and can start remotely.
   - Use proper access, not the unit frame, to reach high sections.
   - Watch for sharp panel edges, insulation and exposed fixings.
   - Fit and secure all panels, guards and interlocks before commissioning.

**TBT-MEC-023 · Fan, Belt & Machinery Guarding**
Purpose: Rotating machinery removes fingers and hands instantly, and most incidents involve a missing guard.
Key points:
   - Never run machinery with a guard removed, wedged or defeated.
   - Isolate, lock off and prove zero energy before removing any guard for maintenance.
   - Wait for rotating parts to come to a complete stop — inertia can last minutes.
   - Keep loose clothing, gloves, lanyards and long hair away from rotating parts.
   - Refit guards fully before restoring power, even for a quick test.
   - Report and quarantine machinery with damaged or missing guarding.

**TBT-MEC-024 · Chemical Cleaning & System Flushing**
Purpose: Flushing chemicals are corrosive, and flushing rigs contain pressure and hot water.
Key points:
   - Read the safety data sheet and COSHH assessment for every chemical used.
   - Wear the specified gloves, goggles or face shield and chemical-resistant clothing.
   - Never mix chemicals and always add chemical to water, not water to chemical.
   - Contain and neutralise the discharge; never release to surface water drains.
   - Secure hoses and connections against whip and check pressure ratings.
   - Know where the eyewash and emergency shower are before you open a drum.

**TBT-MEC-025 · Water Treatment Chemicals (COSHH)**
Purpose: Biocides, inhibitors and glycols used in building services are hazardous to skin, eyes and lungs.
Key points:
   - Store chemicals in a locked, bunded, ventilated area away from incompatible substances.
   - Decant with a pump or funnel, never by pouring from a height or by mouth siphon.
   - Keep labels intact and never transfer chemicals into drinks containers.
   - Ventilate enclosed plant rooms when dosing and use the RPE specified.
   - Have a spill kit available and know the neutralisation procedure.
   - Wash before eating and change contaminated clothing immediately.

**TBT-MEC-026 · Working on Roof-Mounted Plant**
Purpose: Roof plant combines fall risk, fragile surfaces, wind and isolation from help.
Key points:
   - Confirm safe roof access and the fall protection arrangement before going up.
   - Identify fragile rooflights, skylights and ducts and keep clear or cover them.
   - Check wind conditions — roof work with panels and covers is dangerous in gusts.
   - Isolate and lock off plant before opening it; roof units often restart automatically.
   - Secure tools, covers and small components against being blown or dropped.
   - Agree a means of communication and a rescue plan for the roof.

**TBT-MEC-027 · Pipe Supports & Bracketry Installation**
Purpose: Bracketry work means overhead drilling, sharp steel and heavy components at height.
Key points:
   - Select suitable access for the height and duration; do not work off pipes or fittings.
   - Scan before drilling into slabs and walls for services and post-tensioning.
   - Control silica dust with on-tool extraction and wear FFP3 RPE.
   - Deburr cut threaded rod and channel, and cap projecting ends at head height.
   - Verify the fixing type and load rating against the design before installation.
   - Manage overhead posture with rotation and breaks.

**TBT-MEC-028 · Threading, Grooving & Roll-Grooving Machines**
Purpose: Pipe machines are powerful, unguarded at the workpiece and cause severe entanglement injuries.
Key points:
   - Only trained operatives may set up and use threading and grooving machines.
   - Never wear gloves, loose sleeves, rings or lanyards near the rotating pipe.
   - Use the foot switch and keep it clear so you can stop instantly.
   - Support long pipe lengths on stands to stop whip and rotation.
   - Keep the machine and floor clear of cutting oil to prevent slips.
   - Isolate before changing dies, cleaning swarf or clearing a jam.

**TBT-MEC-029 · Press-Fit Systems & Battery Press Tools**
Purpose: Press tools exert tonnes of force at a point where fingers are usually placed.
Key points:
   - Keep fingers well clear of the jaw and the pipe during the press cycle.
   - Use the correct jaw for the material and diameter and check it is fully engaged.
   - Inspect jaws and tool for cracks and wear before use.
   - Deburr and mark insertion depth before pressing; incomplete joints fail under pressure.
   - Support the pipe so the tool does not swing or drop when the cycle completes.
   - Charge and store lithium batteries per the manufacturer's instructions and away from combustibles.

**TBT-MEC-030 · Sharp Sheet Metal & Stainless Steel Edges**
Purpose: Cut duct and sheet edges are as sharp as blades and cause deep, slow-healing lacerations.
Key points:
   - Wear cut-resistant gloves rated for the task whenever handling sheet metal.
   - Deburr and fold edges as soon as they are cut.
   - Carry sheets vertically with two people rather than flat and alone.
   - Beware wind catching sheet material, particularly at height and externally.
   - Store offcuts in a bin, not leaning against walls or laid on the floor.
   - Clean and dress every cut promptly — metalwork cuts infect readily.

**TBT-MEC-031 · Hot Surfaces & Burn Prevention**
Purpose: Flues, steam lines, pumps and freshly brazed joints hold enough heat to cause deep burns long after work stops.
Key points:
   - Assume pipework and plant are hot until proven otherwise; use a thermometer, not your hand.
   - Allow brazed and welded joints to cool before handling, and mark them as hot.
   - Wear heat-resistant gloves and long sleeves when working near hot surfaces.
   - Isolate, drain and allow systems to cool before breaking into them.
   - Fit insulation and guards to hot surfaces in accessible locations.
   - Cool any burn with running water for at least 20 minutes and get first aid.

**TBT-MEC-032 · Fire Dampers & Firestopping to Services**
Purpose: A missing damper or unsealed service penetration defeats the building's fire compartmentation.
Key points:
   - Install fire dampers exactly per the tested detail — position, fixing and frame all matter.
   - Do not cut new openings through fire-rated construction without authorisation.
   - Seal penetrations with a tested system compatible with the pipe, insulation and substrate.
   - Keep access to dampers so they can be inspected and tested later.
   - Photograph and record each installation for the building safety record.
   - Report any damper or seal you find damaged, missing or painted shut.

**TBT-MEC-033 · Confined Space Entry — Tanks, AHUs & Ductwork**
Purpose: Tanks and plant enclosures can hold oxygen-deficient or toxic atmospheres that give no warning.
Key points:
   - Never enter without a confined space permit, gas testing and a standby person.
   - Isolate, lock off and drain all services into the space, including fans and dampers.
   - Test the atmosphere before entry and monitor continuously throughout.
   - Ensure forced ventilation and adequate low-voltage lighting.
   - Have a rescue plan and equipment at the entry point before anyone enters.
   - Never attempt an unaided rescue — most confined space deaths are would-be rescuers.

**TBT-MEC-034 · Working Near Live Building Services**
Purpose: In refurbishment the systems around you are often still running and serving occupants.
Key points:
   - Identify which systems are live before opening ceilings, risers or plant rooms.
   - Never break into a live system without an isolation, a permit and agreement from the building operator.
   - Beware pressurised, hot or chemically dosed systems that discharge when cut.
   - Label your own temporary isolations clearly so nobody restores them early.
   - Protect live cables, pipes and controls from damage by your works.
   - Restore and test services before leaving, and tell the building operator what changed.

**TBT-MEC-035 · Valve Isolation & System Draining**
Purpose: A system thought to be drained can still hold hot water, pressure or chemicals behind a closed valve.
Key points:
   - Identify and physically verify every isolation point, not just the valve schedule.
   - Lock off and tag valves and confirm zero pressure at a vent before breaking any joint.
   - Crack joints slowly with a drip tray and stand clear of the likely spray direction.
   - Beware trapped pressure and thermal expansion between two closed valves.
   - Control and contain drained water and treatment chemicals away from drains.
   - Refill, vent and recommission in a planned sequence.

**TBT-MEC-036 · Flue & Exhaust System Installation**
Purpose: A badly installed flue carries combustion products, including carbon monoxide, back into occupied space.
Key points:
   - Install flues strictly to the manufacturer's instructions and the required clearances to combustibles.
   - Support the flue independently and never rely on the appliance to carry the weight.
   - Seal joints correctly and ensure the correct fall and termination position.
   - Beware working at height and on roofs when installing terminals.
   - Never run flues through voids without the required fire protection and inspection access.
   - Test for spillage and integrity before handover.

**TBT-MEC-037 · Glycol & Chilled Water Chemical Handling**
Purpose: Glycol mixtures are slippery, harmful if swallowed and damaging if released to the environment.
Key points:
   - Use only the specified glycol type and concentration; food grade and industrial grades differ.
   - Wear gloves and eye protection when decanting and dosing.
   - Contain spills immediately — glycol creates an extreme slip hazard on hard floors.
   - Never allow glycol to enter surface water drains; it is highly polluting.
   - Store drums in bunds away from heat and label all decanted containers.
   - Wash thoroughly after handling and never eat or drink in the dosing area.

**TBT-MEC-038 · Working at Height in Mechanical Risers**
Purpose: Risers are tall, narrow and full of services, with fall and dropped-object risk at every level.
Key points:
   - Protect the riser opening at every floor before work starts and reinstate before leaving.
   - Use a proprietary access system designed for risers, not improvised platforms.
   - Never climb on installed pipework, brackets or containment.
   - Control dropped objects rigorously — anything dropped falls the full height of the building.
   - Provide task lighting and keep the escape route clear.
   - Agree communication between levels before starting lifts and pulls.

**TBT-MEC-039 · Positioning Heavy Plant — Skates & Rollers**
Purpose: Moving heavy plant into position by hand is where crush and trap injuries happen.
Key points:
   - Plan the route and check floor loading, door widths, thresholds and levels beforehand.
   - Use skates, rollers, pallet trucks and machine dollies rated for the load.
   - Keep hands and feet out from under the load and use bars, not fingers, to adjust.
   - Control movement on any slope — heavy loads accelerate quickly and cannot be stopped by hand.
   - Chock the load whenever it is stationary and before anyone works near it.
   - Appoint one person to direct the move and to call stop.

**TBT-MEC-040 · Temporary Heating & Drying Equipment**
Purpose: Temporary heaters are a common cause of site fires and carbon monoxide incidents.
Key points:
   - Use only approved heater types for the location; avoid LPG heaters in enclosed occupied areas.
   - Keep the required clearance from combustibles, sheeting and stored materials.
   - Ensure adequate ventilation and fit CO monitoring where fuel-burning heaters are used.
   - Secure heaters against being knocked over and fit them with tilt cut-outs.
   - Store fuel and cylinders outside in a secure, ventilated location.
   - Switch heaters off and check the area at the end of every shift unless a fire watch is in place.

### 4.4 Plumbing & Gas (`plumbing_gas`)

**TBT-PLG-001 · Gas Safe Working & Purging**
Purpose: Gas work carries fire, explosion and asphyxiation risks — only Gas Safe operatives may work on gas.
Key points:
   - Confirm Gas Safe registration for the work.
   - Carry out tightness testing.
   - Purge and vent safely to a safe location.
   - Control all ignition sources.
   - Use gas detection and know the emergency procedure.

**TBT-PLG-002 · Hot Works on Pipework — Soldering & Brazing**
Purpose: Naked flame near combustibles in occupied or fit-out areas causes fires.
Key points:
   - Obtain a hot works permit.
   - Use heat-resistant mats and protect timber and insulation.
   - Maintain a fire watch during and after.
   - Keep an extinguisher to hand.
   - Ensure adequate ventilation.

**TBT-PLG-003 · Legionella & Water System Hygiene**
Purpose: Poorly managed water systems can harbour Legionella bacteria.
Key points:
   - Follow the flushing regime and keep records.
   - Avoid dead-legs in the pipework.
   - Maintain correct hot and cold temperatures.
   - Disinfect systems as specified.
   - Wear PPE when handling chemicals.

**TBT-PLG-004 · Below-Ground Drainage Connections**
Purpose: Drainage work crosses into excavation and biological-hazard risk.
Key points:
   - Apply excavation safety controls and support.
   - Maintain hygiene and cover cuts (Weil's disease).
   - Treat chambers as confined spaces.
   - Handle pipework safely for the back.
   - Locate services before digging.

**TBT-PLG-005 · Soil & Waste Installation at Height**
Purpose: Long pipe runs installed overhead with handling and fume risk.
Key points:
   - Use suitable access equipment.
   - Handle long lengths with two people.
   - Control solvent-weld fumes with ventilation.
   - Tether tools and control dropped objects.
   - Coordinate with trades below.

**TBT-PLG-006 · Solvent Cements & Adhesives**
Purpose: Plumbing adhesives are flammable and give off harmful vapours.
Key points:
   - Work in ventilated areas and use RPE if needed.
   - Keep away from ignition sources.
   - Protect skin and eyes.
   - Store and seal containers correctly.
   - Follow the COSHH assessment.

**TBT-PLG-007 · Carbon Monoxide Awareness**
Purpose: CO is a colourless, odourless killer produced by faulty combustion appliances.
Key points:
   - Check flues and ventilation before commissioning.
   - Recognise the symptoms of CO poisoning.
   - Use CO alarms where appropriate.
   - Never use or leave a faulty appliance in service.
   - Ventilate and evacuate if CO is suspected.

**TBT-PLG-008 · Water Bursts & Flood Control**
Purpose: Uncontrolled water damages property and creates slip and electrical risks.
Key points:
   - Know the isolation points and stop-cock locations.
   - Act fast to isolate and contain.
   - Protect finishes and electrical equipment.
   - Pump out and dry affected areas.
   - Report and record the incident.

**TBT-PLG-009 · Working in Bathrooms & Wet Areas**
Purpose: Confined, wet spaces with electrical and slip risks.
Key points:
   - Beware electrical risk in wet areas.
   - Manage slips with housekeeping.
   - Ventilate when using adhesives and sealants.
   - Handle heavy sanitaryware with care.
   - Protect finished surfaces.

**TBT-PLG-010 · Pipe Threading & Cutting Machines**
Purpose: Powered threading machines cause entanglement and crush injuries.
Key points:
   - Never wear gloves or loose clothing near rotating parts.
   - Use guards and keep hands clear.
   - Secure the workpiece.
   - Manage cutting oil and slips.
   - Isolate before clearing or adjusting.

**TBT-PLG-011 · Manual Handling of Boilers & Cylinders**
Purpose: Heavy appliances cause back and crush injuries.
Key points:
   - Use mechanical aids and team lifts.
   - Plan the route and resting points.
   - Secure loads on stairs.
   - Beware trapped fingers.
   - Wear gloves and toe protection.

**TBT-PLG-012 · Working at Height for Plumbing**
Purpose: First-fix and tank work often at height in voids and roof spaces.
Key points:
   - Use podiums and towers, not stepladders for sustained work.
   - Beware fragile surfaces and openings in roof spaces.
   - Provide lighting in voids.
   - Tether tools.
   - Coordinate with other trades.

**TBT-PLG-013 · Underfloor Heating Installation**
Purpose: Repetitive low-level work with manual handling and screed interaction.
Key points:
   - Manage kneeling and posture with knee pads and rotation.
   - Handle manifolds and pipe coils safely.
   - Coordinate with screeding works.
   - Pressure-test safely.
   - Protect installed pipework.

**TBT-PLG-014 · Drain Clearance & Jetting**
Purpose: High-pressure jetting and foul water bring injury and biological risks.
Key points:
   - Use correct PPE including face protection.
   - Maintain hygiene against Weil's disease.
   - Control high-pressure hoses and reaction forces.
   - Beware confined-space chambers.
   - Isolate and sign the work area.

**TBT-PLG-015 · Rainwater & Guttering at Height**
Purpose: External height work exposed to weather.
Key points:
   - Use suitable access — tower or MEWP.
   - Stop work in high winds.
   - Control dropped objects below.
   - Handle long lengths with two people.
   - Beware fragile roof edges.

**TBT-PLG-016 · Sealants & Silicones**
Purpose: Skin and eye irritation and confined-space fume.
Key points:
   - Ventilate when applying in enclosed areas.
   - Protect skin and eyes.
   - Follow COSHH guidance.
   - Dispose of cartridges correctly.
   - Store away from heat.

**TBT-PLG-017 · Working with Lead & Legacy Materials**
Purpose: Lead and old materials present toxic and handling risks.
Key points:
   - Wear gloves and wash hands after handling lead.
   - Avoid creating lead dust or fume.
   - Treat unknown legacy materials with caution.
   - Follow COSHH controls.
   - Dispose of waste correctly.

**TBT-PLG-018 · Commissioning Heating Systems**
Purpose: Hot water and pressure during commissioning cause burns and releases.
Key points:
   - Beware hot surfaces and scalding water.
   - Manage system pressure during fill and test.
   - Bleed and vent safely.
   - Check for leaks methodically.
   - Follow manufacturer procedures.

**TBT-PLG-019 · Mains Water Connections**
Purpose: Working on live mains brings flooding and pressure risk.
Key points:
   - Confirm isolation with the supplier where needed.
   - Control water release and flooding.
   - Beware pressure when breaking into mains.
   - Maintain hygiene standards.
   - Reinstate and test before handover.

**TBT-PLG-020 · Tank & Cylinder Installation in Lofts**
Purpose: Heavy tanks installed in awkward roof spaces.
Key points:
   - Use crawl boards over joists.
   - Beware fragile surfaces and openings.
   - Team-lift tanks and cylinders.
   - Provide loft lighting.
   - Secure tanks correctly.

**TBT-PLG-021 · Gas Escape & Emergency Procedure**
Purpose: A gas escape can fill a building and ignite from any spark — the first minutes decide the outcome.
Key points:
   - If you smell gas, do not operate switches, phones or doorbells inside the building.
   - Turn off the emergency control valve if it is safe to reach and open doors and windows.
   - Evacuate the building and keep people away from the area.
   - Call the National Gas Emergency Service on 0800 111 999 from outside.
   - Never attempt repairs unless you are Gas Safe registered for that work.
   - Report the incident to the site team and record what was found and done.

**TBT-PLG-022 · LPG Cylinders & Bulk Storage**
Purpose: LPG is heavier than air, pools in low areas and forms an explosive mixture.
Key points:
   - Store cylinders upright, secured, outdoors in a ventilated cage away from drains and basements.
   - Never take LPG cylinders into excavations, basements or confined spaces.
   - Check hoses, regulators and connections for damage and use leak detection fluid, never a flame.
   - Close the cylinder valve at the end of every shift, not just the appliance tap.
   - Keep the required separation from ignition sources, oxygen cylinders and combustibles.
   - Move cylinders with a trolley and never by rolling or dragging.

**TBT-PLG-023 · Unvented Hot Water Systems (Building Regs G3)**
Purpose: An unvented cylinder is a pressure vessel — failure of the safety devices can cause explosion and scalding.
Key points:
   - Only operatives holding the relevant G3 competence may install or service unvented systems.
   - Never adjust, bypass or remove the expansion vessel, pressure relief or temperature relief devices.
   - Terminate discharge pipework safely and visibly so a discharge cannot scald anyone.
   - Check the expansion vessel charge and the incoming pressure against the design.
   - Isolate, depressurise and allow to cool before working on any part of the system.
   - Commission, label and record the installation and leave the user instructions.

**TBT-PLG-024 · Loft & Roof Space Access for Plumbers**
Purpose: Lofts combine fragile ceilings, poor lighting, awkward access and hidden hazards.
Key points:
   - Never step between joists — use crawl boards and a proper working platform.
   - Secure the loft ladder or use a tower; the hatch opening itself is a fall risk.
   - Provide task lighting rather than relying on a torch held in the mouth.
   - Check for asbestos, wiring, wasp nests and vermin contamination before entering.
   - Mind insulation fibres and wear suitable gloves, RPE and eye protection.
   - Keep the hatch guarded while open and never drop tools or materials through it.

**TBT-PLG-025 · Press-Fit & Crimping Tools**
Purpose: Crimping tools close with tonnes of force exactly where fingers naturally sit.
Key points:
   - Keep fingers and gloves clear of the jaw throughout the press cycle.
   - Select the correct jaw and profile for the fitting and confirm it locks fully in place.
   - Inspect tool and jaws for cracks before use and withdraw damaged ones.
   - Mark insertion depth and deburr pipe ends; a partly inserted fitting will fail under pressure.
   - Support the pipework so the tool cannot drop or swing when the cycle ends.
   - Store and charge batteries safely away from combustible materials.

**TBT-PLG-026 · Chlorination & Disinfection of Water Systems**
Purpose: Disinfection chemicals are strongly oxidising and dangerous to eyes, skin and lungs.
Key points:
   - Work to the COSHH assessment and safety data sheet for the specific product.
   - Wear goggles or a face shield, chemical gloves and protective clothing when dosing.
   - Ventilate the area — chlorine-based products release irritant gas in confined plant rooms.
   - Never mix disinfection chemicals with acids or other cleaning products.
   - Sign and lock off outlets so nobody can draw dosed water during the process.
   - Neutralise and dispose of the discharge in agreement with the water authority.

**TBT-PLG-027 · Backflow Prevention & Contamination Risk**
Purpose: Backflow can draw contaminated water into the wholesome supply and make people seriously ill.
Key points:
   - Identify the fluid category of the installation and fit the correct protection device.
   - Never make a cross-connection between potable and non-potable systems.
   - Keep hoses out of tanks, buckets and drains where back-siphonage can occur.
   - Protect open ends and store pipework and fittings capped and clean.
   - Sanitise tools and hands before working on potable systems.
   - Report and correct any unprotected connection you find, however old.

**TBT-PLG-028 · Working in Occupied Homes**
Purpose: In someone's home there are no barriers, no inductions and often children, pets and vulnerable people.
Key points:
   - Agree the working area with the occupier and screen or barrier it off.
   - Never leave tools, blades, hot pipework or open holes unattended.
   - Isolate services with the occupier's knowledge and tell them when water or heat will be off.
   - Manage dust with extraction and sheeting and clean up before leaving each day.
   - Be alert to vulnerable occupiers and follow the company's safeguarding procedure.
   - Park considerately, protect floors and coverings, and keep escape routes clear.

**TBT-PLG-029 · Bathroom Pods & Modular Installations**
Purpose: Pods are heavy, tall, unstable units that must be lifted and slid into tight openings.
Key points:
   - Follow the lift plan and use the designed lifting points only.
   - Keep out of the load path and never guide a suspended pod by hand — use tag lines.
   - Check the route, floor loading and openings before the lift starts.
   - Beware of crush points as the pod is landed and slid into position.
   - Brace or restrain the pod until it is fixed; unrestrained pods topple.
   - Protect the finished unit and control access once installed.

**TBT-PLG-030 · Macerators, Pumps & Foul Water**
Purpose: Foul water carries bacteria and viruses, and macerator blades cause serious injury.
Key points:
   - Isolate and lock off electrically before opening any macerator or pump.
   - Assume the unit still holds foul water and pressure; drain it under control.
   - Wear waterproof gloves, eye protection and coveralls; cover cuts beforehand.
   - Never put hands into the cutting chamber — use a tool to clear blockages.
   - Bag and dispose of contaminated waste properly and disinfect the area.
   - Wash thoroughly before eating, drinking or smoking, and report any illness afterwards.

**TBT-PLG-031 · Air Source Heat Pump Installation**
Purpose: Heat pumps combine heavy outdoor units, electrical supply, refrigerant and working at height.
Key points:
   - Plan the lift and positioning of the unit; they are heavier and more awkward than they look.
   - Ensure the base or bracket is designed for the load and the wall can carry it.
   - Isolate and prove dead before connecting or working on the electrical supply.
   - Only F-Gas certified operatives may work on the refrigerant circuit.
   - Beware of fan blades, sharp fins and stored energy when opening the casing.
   - Commission, test and record the installation before handover.

**TBT-PLG-032 · F-Gas & Refrigerant Awareness for Plumbers**
Purpose: Refrigerants can asphyxiate in enclosed spaces, cause cold burns and, with some newer gases, ignite.
Key points:
   - Never vent refrigerant to atmosphere — it is a criminal offence as well as a hazard.
   - Only F-Gas certified persons may break into, charge or recover from a refrigerant circuit.
   - Understand the flammability class of the refrigerant present, particularly A2L gases.
   - Ventilate the area and avoid working in enclosed spaces where gas could accumulate.
   - Wear gloves and eye protection — liquid refrigerant causes immediate cold burns.
   - Keep ignition sources away and use leak detection appropriate to the gas.

**TBT-PLG-033 · Boiler Flue Routes & External Access**
Purpose: Flue installation puts plumbers on ladders and roofs, often at the end of a long day.
Key points:
   - Assess the flue route before starting and choose the access equipment for the whole task.
   - Never work off a ladder to make flue connections requiring both hands.
   - Check terminal positions against the required clearances from openings and boundaries.
   - Core drilling through walls needs scanning, dust control and protection of the area below.
   - Ensure flues in voids have the required inspection hatches and fire protection.
   - Test for spillage and complete the commissioning record.

**TBT-PLG-034 · Live Electrics in Plumbing Works**
Purpose: Plumbers regularly meet live wiring at boilers, pumps, controls and immersion heaters.
Key points:
   - Isolate at the correct point, lock off and prove dead before touching any wiring.
   - Remember boilers can be fed from more than one circuit and controls may be permanently live.
   - Never work on electrics beyond your competence — call the electrician.
   - Beware water and electricity together, especially in cylinder cupboards and under floors.
   - Scan before drilling or fixing near existing cables.
   - Reinstate covers, glands and earthing before energising.

**TBT-PLG-035 · Cutting & Grinding Pipework — Sparks & Swarf**
Purpose: Cutting pipe in situ throws sparks and hot swarf into voids, insulation and other trades' work.
Key points:
   - Obtain a hot works permit where grinding or cutting creates sparks.
   - Remove or protect combustibles and screen the work area.
   - Maintain a fire watch during and after the work as the permit requires.
   - Confirm the pipe is drained and depressurised, and check what it contained.
   - Wear eye, face and hand protection; hot swarf goes straight through ordinary clothing.
   - Deburr cut ends and clear swarf before it is walked through the building.

**TBT-PLG-036 · Basements, Plant Rooms & Restricted Spaces**
Purpose: Below-ground plumbing spaces have poor ventilation, single exits and gas accumulation risk.
Key points:
   - Assess whether the space is a confined space and permit it if so.
   - Never take LPG cylinders below ground level.
   - Ensure ventilation, lighting and a clear, unobstructed means of escape.
   - Watch for sumps, open channels and standing water.
   - Keep a means of raising the alarm and tell someone where you are.
   - Beware of build-up from fumes, solvents and engine exhausts in enclosed rooms.

**TBT-PLG-037 · Pressure Testing Water Systems**
Purpose: Water under pressure stores energy and a failed joint or fitting can release it violently.
Key points:
   - Test to the specified pressure only, using calibrated and in-date gauges.
   - Brace and support pipework and blank ends before pressurising.
   - Raise pressure gradually and keep people clear during the test.
   - Never use compressed air or gas to test a system designed for water testing.
   - Post signs, barrier the area and never leave a system under test unattended.
   - Depressurise fully before breaking any joint or removing a blank.

**TBT-PLG-038 · Service Pipe Trenches & Mains Laying**
Purpose: Trenches for water and gas services carry collapse, service strike and confined-space risks.
Key points:
   - Check service records and scan with CAT and Genny before breaking ground.
   - Support, batter or box any trench where collapse is possible, regardless of depth.
   - Provide safe access and edge protection and keep spoil back from the edge.
   - Beware of striking existing gas, water and electricity services when digging near buildings.
   - Never enter an unsupported trench to make a connection.
   - Backfill, compact and reinstate correctly and protect the trench overnight.

**TBT-PLG-039 · Manual Handling of Radiators & Pipework**
Purpose: Radiators, cylinders and pipe bundles are awkward, sharp-edged and often carried up stairs.
Key points:
   - Assess the load and route first; plan the rest points before lifting.
   - Use two people for radiators, cylinders and long pipe lengths.
   - Keep loads close to the body and avoid twisting, particularly on stairs and landings.
   - Mind fingers on brackets, valves and pipe ends and wear suitable gloves.
   - Use trolleys, stair-climbers and sack barrows wherever access allows.
   - Drain radiators before removal — a full radiator is far heavier and will spill dirty water.

**TBT-PLG-040 · Water on Floors — Slips During Plumbing Works**
Purpose: Plumbing creates wet floors in exactly the areas people walk through.
Key points:
   - Have a bucket, drip tray and absorbent materials ready before breaking any joint.
   - Clean up spills immediately and dry the surface rather than leaving it to evaporate.
   - Use warning signs while a floor is wet, and remove them once it is dry.
   - Beware of newly wetted smooth floors, tiles and painted screed — they become extremely slippery.
   - Keep hoses and temporary drainage out of walkways.
   - Protect finished floors and report leaks that could reach electrical equipment below.

### 4.5 Groundworks & Drainage (`groundworks`)

**TBT-GRD-001 · Excavations — Collapse & Access**
Purpose: Excavation collapse can bury and kill in seconds.
Key points:
   - Support or batter excavations as designed.
   - Inspect excavations daily and after any event.
   - Keep spoil and plant set back from the edge.
   - Provide safe ladder access and edge barriers.
   - Locate services before digging and obtain a permit.

**TBT-GRD-002 · Underground Services Avoidance**
Purpose: Striking buried electric, gas, water or comms is potentially fatal.
Key points:
   - Check utility drawings and scan with CAT & Genny.
   - Dig trial holes and hand-dig near services.
   - Assume all buried services are live.
   - Work within safe-dig zones.
   - Know the emergency procedure for a strike.

**TBT-GRD-003 · Confined Spaces — Chambers & Manholes**
Purpose: Confined spaces carry asphyxiation, gas and engulfment risks.
Key points:
   - Work only under a confined-space permit.
   - Test and monitor the atmosphere continuously.
   - Provide forced ventilation.
   - Have a rescue plan and equipment ready.
   - Never enter to rescue without proper equipment.

**TBT-GRD-004 · Plant on Groundworks**
Purpose: Excavators and dumpers create the highest plant-pedestrian risk.
Key points:
   - Segregate plant from people.
   - Use a banksman and obey signals.
   - Check quick-hitches are engaged.
   - Never use plant to lift or carry people.
   - Refuel safely with the engine off.

**TBT-GRD-005 · Concrete & Wet Pours**
Purpose: Wet concrete burns skin and pump lines can whip dangerously.
Key points:
   - Wear PPE — wet concrete causes burns and dermatitis.
   - Control pump-line whip and never overreach.
   - Establish exclusion zones around pours.
   - Keep wash stations available.
   - Communicate clearly with the pump operator.

**TBT-GRD-006 · Working Near Water & Flooding**
Purpose: Excavations and sites near water risk drowning and Weil's disease.
Key points:
   - Provide edge protection and rescue equipment.
   - Manage water with sumps and pumps.
   - Monitor weather and rising water.
   - Maintain hygiene against Weil's disease.
   - Wear buoyancy aids where required.

**TBT-GRD-007 · Reduced Level Dig & Battering**
Purpose: Bulk dig and sloping faces can fail without control.
Key points:
   - Batter slopes to a safe angle for the ground.
   - Assess ground conditions and water.
   - Keep surcharge loads (plant, spoil) back from edges.
   - Inspect faces regularly.
   - Re-assess after rain.

**TBT-GRD-008 · Piling Operations**
Purpose: Piling rigs are large, powerful and unstable on poor ground.
Key points:
   - Establish exclusion zones around the rig.
   - Ensure rig stability on prepared platforms.
   - Manage noise and vibration.
   - Handle spoil and arisings safely.
   - Check for overhead and underground services.

**TBT-GRD-009 · Drainage Laying & Bedding**
Purpose: Repetitive work in trenches with handling and collapse risk.
Key points:
   - Apply trench support and access controls.
   - Use mechanical aids for pipes and bedding.
   - Maintain hygiene around foul drainage.
   - Keep the trench edge clear.
   - Inspect the excavation regularly.

**TBT-GRD-010 · Kerbing & Paving**
Purpose: Heavy units and repetitive handling cause MSDs.
Key points:
   - Use mechanical lifters for heavy kerbs and flags.
   - Observe two-person and weight limits.
   - Manage posture and rotation.
   - Cut with water suppression for silica.
   - Beware passing traffic on highways works.

**TBT-GRD-011 · Road & Highway Works**
Purpose: Live traffic is a major hazard on or near the highway.
Key points:
   - Set out traffic management to the approved plan.
   - Wear hi-vis and maintain a safe zone from traffic.
   - Beware vehicles entering the works.
   - Light and sign the works at night.
   - Never work outside the protected area.

**TBT-GRD-012 · Compaction Plant & Rollers**
Purpose: Vibrating rollers and plates cause HAVS, noise and crush risks.
Key points:
   - Keep clear of moving compaction plant.
   - Manage HAVS with trigger-time limits on plates.
   - Wear hearing protection.
   - Beware reversing rollers and blind spots.
   - Maintain segregation.

**TBT-GRD-013 · Working with Geotextiles & Membranes**
Purpose: Handling large rolls and working on slopes.
Key points:
   - Handle heavy rolls with mechanical aids or teams.
   - Beware slips on membranes.
   - Secure materials against wind.
   - Use sharp knives safely.
   - Maintain footing on slopes.

**TBT-GRD-014 · Dewatering & Pumping**
Purpose: Managing groundwater brings electrical, slip and discharge risks.
Key points:
   - Use RCD-protected pumps and route cables safely.
   - Control discharge — no pollution to drains/watercourses.
   - Manage slips around wet areas.
   - Maintain pumps and check regularly.
   - Beware confined-space sumps.

**TBT-GRD-015 · Setting Out & Surveying**
Purpose: Surveyors move around live plant and excavation areas.
Key points:
   - Wear hi-vis and stay alert to plant.
   - Beware excavation edges and openings.
   - Coordinate with plant operators.
   - Protect against weather for long periods outside.
   - Keep equipment cables and tripods tidy.

**TBT-GRD-016 · Muck Away & Spoil Removal**
Purpose: Loading and hauling spoil involves plant and traffic risks.
Key points:
   - Segregate loading operations from people.
   - Use a banksman for reversing wagons.
   - Sheet loads to prevent spillage.
   - Control mud on the highway.
   - Beware overhead lines during tipping.

**TBT-GRD-017 · Service Trench Reinstatement**
Purpose: Backfilling and compacting trenches with services present.
Key points:
   - Protect newly-laid services during backfill.
   - Compact in layers to avoid over-stressing.
   - Manage HAVS from compaction plant.
   - Keep the trench supported until backfilled.
   - Reinstate surfaces safely near traffic.

**TBT-GRD-018 · Ground Contamination Awareness**
Purpose: Contaminated ground exposes workers to chemical and biological hazards.
Key points:
   - Check the site investigation/contamination report.
   - Wear the specified PPE and RPE.
   - Maintain hygiene and decontamination.
   - Control dust and run-off.
   - Report unexpected contamination.

**TBT-GRD-019 · Temporary Works in Excavations**
Purpose: Trench boxes and shoring must be used and handled correctly.
Key points:
   - Install and remove support to the design sequence.
   - Never enter an unsupported excavation.
   - Handle trench boxes with suitable plant.
   - Inspect support systems regularly.
   - Report any movement immediately.

**TBT-GRD-020 · Site Establishment & Welfare Setup**
Purpose: Setting up compounds involves plant, services and handling.
Key points:
   - Locate services before setting cabins.
   - Use plant safely to position units.
   - Provide safe access and steps.
   - Connect services by competent persons.
   - Segregate the compound from works.

**TBT-GRD-021 · Trench Support — Boxes, Shoring & Sheet Piles**
Purpose: A cubic metre of soil weighs over a tonne; an unsupported face gives no warning before it collapses.
Key points:
   - Install support as the excavation proceeds — never dig deep and support afterwards.
   - Use the support system specified in the temporary works design, not what is on the wagon.
   - Install and remove trench boxes from outside the excavation using the excavator.
   - Never work outside the protected zone of the box or below an unsupported overhang.
   - Check supports at the start of every shift and after rain, frost or plant movement.
   - Remove support only in the sequence set out in the design as backfill proceeds.

**TBT-GRD-022 · Service Strike — Emergency Response**
Purpose: What happens in the ten seconds after a strike determines whether it becomes a fatality.
Key points:
   - Stop work, keep everyone clear and do not touch plant that may be in contact with a cable.
   - For an electricity strike, stay in the cab if safe, or jump clear without touching machine and ground together.
   - For a gas strike, evacuate upwind, prohibit ignition sources and call 0800 111 999.
   - For a water strike, isolate if possible and control flooding and undermining.
   - Call the emergency services and the utility immediately and cordon the area.
   - Report and investigate every strike, including glancing damage to ducts and sheathing.

**TBT-GRD-023 · CAT & Genny — Use and Limitations**
Purpose: A locator is a tool, not a guarantee — most strikes happen where someone trusted the box completely.
Key points:
   - Only trained operatives should use locating equipment, and it must be in calibration.
   - Use all modes — power, radio and genny — and scan in two directions across the area.
   - Understand the limits: plastic pipes, deep services and ducts may not be detected.
   - Always combine location with drawings, trial holes and safe hand-digging.
   - Mark up the ground and refresh the marks as they wear away.
   - Re-scan whenever the work moves or the ground level changes.

**TBT-GRD-024 · Excavation Inspection & Records**
Purpose: Excavations must be inspected by a competent person at set intervals and the record is a legal document.
Key points:
   - Inspect at the start of every shift, after any event likely to affect stability, and after accidental fall of material.
   - Record inspections and make the record available on site.
   - Look for movement, cracking, seepage, undermining, loose material and damaged supports.
   - Check edge protection, access ladders, barriers and lighting at the same time.
   - Do not allow entry where the inspection has raised a defect until it is put right.
   - Anybody can report a concern between inspections — do not wait for the next one.

**TBT-GRD-025 · Spoil Heaps & Surcharge Loading**
Purpose: Material stored at the edge adds load that the excavation face was never designed to carry.
Key points:
   - Keep spoil, materials and plant back from the edge by the distance in the design.
   - Never store pipes, kerbs or fittings where they can roll into the excavation.
   - Watch for plant tracking close to the edge and surcharging it.
   - Batter spoil heaps and keep them stable; do not undercut them.
   - Remove arisings promptly rather than letting heaps grow through the shift.
   - Barrier the crest and keep pedestrians away from the edge.

**TBT-GRD-026 · Underpinning & Working Near Structures**
Purpose: Excavating next to a foundation removes the support the building relies on.
Key points:
   - Work strictly to the underpinning sequence and bay widths in the temporary works design.
   - Never open more bays than the design allows or leave bays open overnight without approval.
   - Monitor the structure for movement, cracking or distress and report it immediately.
   - Provide support and propping before entering any bay.
   - Check for party wall agreements and neighbouring notices before starting.
   - Backfill, pin and ram up each bay fully before moving on.

**TBT-GRD-027 · Groundwater, Springs & Running Sand**
Purpose: Water changes soil behaviour completely and can liquefy a face that looked stable.
Key points:
   - Expect groundwater where the ground investigation predicted it, and where it did not.
   - Stop work and re-assess if water enters the excavation or the face begins to run.
   - Never rely on pumping alone to hold an unstable face.
   - Watch for washing out behind sheeting and undermining of supports.
   - Beware of the sudden collapse risk in fine sands and silts.
   - Escalate to the temporary works coordinator rather than adapting the method on the ground.

**TBT-GRD-028 · Manholes, Chambers & Cover Handling**
Purpose: Covers are heavy and seized, and the hole beneath them is a confined space.
Key points:
   - Use proper lifting keys and cover lifters; never lever with a bar and bare hands.
   - Two people minimum for heavy covers, and keep feet and fingers clear as it lands.
   - Guard the open chamber immediately — never leave it open and unattended.
   - Treat every chamber as a confined space: test the atmosphere and permit entry.
   - Beware of Weil's disease and sewage contamination; cover cuts and wash afterwards.
   - Reseat covers correctly and check they are fully bedded before leaving.

**TBT-GRD-029 · Concrete Deliveries & Wagon Movements**
Purpose: Concrete wagons are heavy, reverse frequently and often work close to excavation edges.
Key points:
   - Plan and mark the delivery route and standing position before the wagon arrives.
   - Use a trained banksman for all reversing and discharge positioning.
   - Keep the wagon back from excavation edges by the distance in the design, with stop blocks.
   - Stand clear of the chute and never put hands or tools near a moving chute.
   - Beware of wet concrete splash — protect skin and eyes and wash off immediately.
   - Wash out only in the designated area and never to drains or watercourses.

**TBT-GRD-030 · Blinding, Formwork & Ground Slabs**
Purpose: Slab work means kneeling, wet concrete, protruding fixings and constant plant movement.
Key points:
   - Cap or cover starter bars and projecting fixings before anyone works around them.
   - Use knee pads and rotate kneeling tasks to protect joints.
   - Keep formwork pins, nails and offcuts cleared as you go.
   - Protect skin fully from wet concrete and know the burn symptoms.
   - Keep clear of pour zones, pump lines and skips.
   - Maintain safe access across reinforcement using proper walkways, not by walking the bars.

**TBT-GRD-031 · Service Ducts & Draw Pits**
Purpose: Duct runs and draw pits create open holes, trip hazards and confined spaces across the site.
Key points:
   - Cover or barrier every open pit and duct end as soon as it is formed.
   - Cap duct ends to keep out water, vermin and debris.
   - Treat draw pits as confined spaces and permit any entry.
   - Beware of cable pulling forces, snatch and entanglement during draw-in.
   - Bed and surround ducts to the specification so they do not collapse under later loading.
   - Mark duct positions accurately for the record before backfilling.

**TBT-GRD-032 · Hydraulic Breakers & Excavator Attachments**
Purpose: Breakers throw debris, transmit vibration and can penetrate the machine cab or a person.
Key points:
   - Only trained operators may use breaker attachments and they must fit the machine.
   - Establish and enforce an exclusion zone against flying debris.
   - Check the attachment, pins and quick hitch security before every use.
   - Never break with the tool at an angle or use it to lever or lift.
   - Manage noise and hand-arm and whole-body vibration exposure through rotation.
   - Depressurise and isolate before changing or servicing an attachment.

**TBT-GRD-033 · Landscaping, Topsoil & Planting**
Purpose: Soft landscaping is late in the programme when everyone is rushing and plant is moving amongst people.
Key points:
   - Keep pedestrian routes separate from muck shifting and topsoil placement.
   - Beware of buried services close to the surface and previously installed ducts and drainage.
   - Assess soil and compost for contamination and biological hazards; cover cuts and wash hands.
   - Use mechanical aids for trees, turf rolls and paving — they are heavier than they look.
   - Watch footing on soft, uneven and sloping ground.
   - Protect completed drainage, kerbs and services from plant damage.

**TBT-GRD-034 · Retaining Walls & Gabion Baskets**
Purpose: Retaining structures are only stable when built and backfilled exactly as designed.
Key points:
   - Follow the design for backfill, drainage and compaction sequence — do not backfill early or in deep lifts.
   - Never surcharge a new wall with plant or spoil before it has gained strength or been drained.
   - Keep people clear of the face during filling and compaction.
   - Handle gabion mesh with cut-resistant gloves and eye protection.
   - Watch for trapped fingers when placing stone and closing baskets.
   - Report bulging, leaning or seepage in any retaining structure immediately.

**TBT-GRD-035 · Haul Routes, Site Roads & Wheel Wash**
Purpose: Poor haul routes cause overturns, collisions and mud on the public highway.
Key points:
   - Keep haul routes well formed, drained, graded and free of standing water.
   - Maintain separation between plant routes and pedestrian walkways with physical barriers.
   - Observe site speed limits and one-way systems; most site collisions happen at low speed.
   - Keep the wheel wash working and use it — mud on the road is an offence and a hazard.
   - Repair potholes and ruts promptly; they cause load shifts and back injuries.
   - Provide lighting, signage and reflective markers for use in the dark.

**TBT-GRD-036 · Working Adjacent to Live Traffic (Chapter 8)**
Purpose: Passing traffic is the biggest hazard on any highway-adjacent job.
Key points:
   - Set out signing, lighting and guarding to the approved Chapter 8 layout before work starts.
   - Wear the correct class of high-visibility clothing for the road type.
   - Never step outside the coned area or work with your back to live traffic.
   - Install and remove traffic management in the correct sequence, from the safe side.
   - Keep materials, plant and parking inside the works area.
   - Stop and re-assess if cones are struck, displaced or visibility deteriorates.

**TBT-GRD-037 · Trial Holes & Hand Digging**
Purpose: Hand digging is the last defence against a service strike, and only works if done properly.
Key points:
   - Dig trial holes to prove the position and depth of every service before machine excavation.
   - Use insulated tools and dig alongside a service, never directly over it.
   - Loosen ground with a spade or trowel rather than driving a fork or pick down.
   - Never use a machine to break ground within the safe distance of a known service.
   - Expose and support services before excavating beneath them.
   - Record what is found and mark it up for everyone working in the area.

**TBT-GRD-038 · Whole-Body Vibration in Groundworks**
Purpose: Long hours on rough ground in plant cause back pain and long-term spinal damage.
Key points:
   - Keep haul routes maintained — the ground surface is the main cause of exposure.
   - Adjust the suspension seat to your weight and keep it serviceable.
   - Drive at a speed suited to the surface rather than the schedule.
   - Take regular breaks out of the machine and rotate operators on rough ground.
   - Report seat and suspension defects and back symptoms early.
   - Avoid twisting in the seat; use mirrors, cameras and turn the whole body.

**TBT-GRD-039 · Japanese Knotweed & Invasive Species**
Purpose: Spreading invasive species is a criminal offence and can make soil a controlled waste.
Key points:
   - Learn to recognise Japanese knotweed, giant hogweed and ragwort on site.
   - Stop work and report a suspected find rather than digging or cutting it.
   - Never move contaminated soil or track plant through a stand — a fragment can start a new colony.
   - Beware of giant hogweed sap, which causes severe burns and blistering in sunlight.
   - Clean plant, boots and tools before leaving a treatment area.
   - Follow the specialist management plan for removal and disposal.

**TBT-GRD-040 · Archaeology, UXO & Unexpected Finds**
Purpose: Unexploded ordnance, burials and contamination stop a job instantly and can kill if mishandled.
Key points:
   - Know the site's UXO risk assessment and whether magnetometer survey has been done.
   - Stop work immediately on any suspicious object, bone, drum or unexpected material.
   - Do not touch, move or attempt to identify the find.
   - Withdraw to a safe distance, cordon the area and inform the site manager.
   - Follow the unexpected finds procedure; the police, EOD or archaeologist will attend as required.
   - Do not resume work in the area until formally authorised.

### 4.6 Scaffolding (`scaffolding`)

**TBT-SCA-001 · Scaffold Erection & Dismantle (SG4)**
Purpose: Erectors work at height while collective protection is incomplete.
Key points:
   - Work to SG4 using advance guardrail systems.
   - Clip on with a harness during erection and dismantle.
   - Establish exclusion zones below.
   - Inspect components before use.
   - Only CISRS-competent operatives may erect.

**TBT-SCA-002 · Scaffold Inspection & Tagging**
Purpose: Users must only access inspected, tagged scaffolds.
Key points:
   - Check the scaffold tag before every use.
   - Never use an untagged or incomplete scaffold.
   - Inspections every 7 days and after any event.
   - Report alterations or damage.
   - Do not modify scaffold without authorisation.

**TBT-SCA-003 · Loading & Dropped Objects**
Purpose: Overloading and falling materials endanger people below.
Key points:
   - Observe loading bay limits and SWL.
   - Fit toe boards and brick guards.
   - Use netting and fans where required.
   - Control and tether materials and tools.
   - Load evenly and as designed.

**TBT-SCA-004 · Mobile Towers (PASMA)**
Purpose: Towers collapse or cause falls if mis-built or moved occupied.
Key points:
   - Build using 3T or advance-guardrail method.
   - Lock all castors before use.
   - Never move a tower while occupied.
   - Observe height-to-base ratios.
   - Only PASMA-trained operatives may build.

**TBT-SCA-005 · Ties, Bracing & Stability**
Purpose: Removing ties or bracing can collapse a scaffold.
Key points:
   - Never remove ties or bracing without authorisation.
   - Report missing or damaged components.
   - Use sole boards and base plates on firm ground.
   - Check stability in high winds.
   - Maintain the scaffold as designed.

**TBT-SCA-006 · Working Platforms & Boarding**
Purpose: Gaps and trap-ends cause falls and trips.
Key points:
   - Fully board working platforms with no gaps.
   - Secure boards against displacement.
   - Maintain double guardrails and toe boards.
   - Keep platforms clear of debris.
   - Beware trap-end boards.

**TBT-SCA-007 · Manual Handling of Scaffold Materials**
Purpose: Tubes, boards and fittings cause MSDs and impact injuries.
Key points:
   - Team-lift long tubes and boards.
   - Use gloves to protect hands.
   - Pass materials safely, not throw.
   - Plan lifting routes.
   - Rotate to manage repetitive strain.

**TBT-SCA-008 · Edge Protection Systems**
Purpose: Temporary edge protection must be correctly installed.
Key points:
   - Install to manufacturer/design specification.
   - Check posts and rails are secure.
   - Never remove without reinstatement.
   - Inspect after any impact.
   - Report damage immediately.

**TBT-SCA-009 · Loading Bays & Hoists**
Purpose: Material movement points concentrate risk.
Key points:
   - Use gates and barriers at loading bays.
   - Observe SWL on hoists and bays.
   - Keep the bay clear when not loading.
   - Communicate during loading operations.
   - Guard against falls at open edges.

**TBT-SCA-010 · Public Protection & Pavement Scaffolds**
Purpose: Scaffolds over public areas must protect passers-by.
Key points:
   - Provide fans, netting and protected walkways.
   - Light and sign the scaffold for the public.
   - Prevent dropped objects onto the public.
   - Maintain safe headroom and access.
   - Inspect public-facing protection regularly.

**TBT-SCA-011 · Weather & High Winds**
Purpose: Wind and weather affect scaffold work and stability.
Key points:
   - Stop erection/dismantle in high winds.
   - Secure loose materials and sheeting.
   - Check ties and stability after storms.
   - Beware ice on platforms.
   - Re-inspect after severe weather.

**TBT-SCA-012 · Sheeting & Netting**
Purpose: Wind loading on sheeted scaffolds increases forces.
Key points:
   - Ensure additional ties for sheeted scaffolds.
   - Fix sheeting and netting securely.
   - Inspect for tears and flapping.
   - Account for wind loading in the design.
   - Remove damaged sheeting promptly.

**TBT-SCA-013 · Access & Egress on Scaffolds**
Purpose: Safe ways on and off prevent falls.
Key points:
   - Use proper ladder access or stair towers.
   - Maintain ladder tie-offs and landing gates.
   - Keep access points clear.
   - Three points of contact on ladders.
   - Never climb the scaffold frame.

**TBT-SCA-014 · Cantilever & Complex Scaffolds**
Purpose: Non-standard scaffolds need design and competence.
Key points:
   - Build only to a specific design.
   - Verify the design and loadings.
   - Use competent advanced scaffolders.
   - Inspect thoroughly before handover.
   - Tag clearly with limitations.

**TBT-SCA-015 · Scaffold Adaptations**
Purpose: Unauthorised changes compromise safety.
Key points:
   - Only competent scaffolders may adapt scaffolds.
   - Re-inspect and re-tag after changes.
   - Record adaptations.
   - Never remove components to gain access.
   - Report and reinstate any interference.

**TBT-SCA-016 · Hoisting Materials by Hand (Gin Wheels)**
Purpose: Manual hoisting drops loads and strains backs.
Key points:
   - Check the gin wheel and rope condition and SWL.
   - Secure loads before hoisting.
   - Keep the area below clear.
   - Use good lifting technique.
   - Communicate during the lift.

**TBT-SCA-017 · Birdcage & Internal Scaffolds**
Purpose: Internal access scaffolds in occupied/fit-out areas.
Key points:
   - Protect floors and finishes.
   - Maintain clear escape routes.
   - Fully board and guard platforms.
   - Coordinate with other trades.
   - Light the work area.

**TBT-SCA-018 · Scaffold Foundations & Ground**
Purpose: Poor ground causes settlement and collapse.
Key points:
   - Use sole boards and base plates on firm, level ground.
   - Assess ground bearing capacity.
   - Beware excavations and voids beneath.
   - Monitor for settlement.
   - Re-level if movement occurs.

**TBT-SCA-019 · Falling Object Prevention**
Purpose: Tools and materials falling from scaffolds injure those below.
Key points:
   - Use toe boards, brick guards and nets.
   - Tether tools at height.
   - Keep platforms tidy.
   - Establish exclusion zones.
   - Wear head protection below scaffolds.

**TBT-SCA-020 · Manual Tasks & Repetitive Strain**
Purpose: Scaffolding is physically demanding and repetitive.
Key points:
   - Warm up and rotate tasks.
   - Use correct lifting techniques.
   - Take breaks to manage fatigue.
   - Stay hydrated.
   - Report aches and strains early.

**TBT-SCA-021 · TG20 Compliance & Design Briefs**
Purpose: A scaffold outside the TG20 compliant scope needs a bespoke design, and building it by eye is how scaffolds fail.
Key points:
   - Confirm before erection whether the scaffold is TG20 compliant or requires a bespoke design.
   - Keep the compliance sheet or design drawing on site and build strictly to it.
   - Do not change tie patterns, bay lengths, lift heights or bracing without going back to the designer.
   - Check the intended duty class against how the scaffold will actually be loaded.
   - Raise it if the ground, structure or obstructions prevent building to the drawing.
   - Record any approved variation before the scaffold is handed over.

**TBT-SCA-022 · Handover Certificates & Scaffold Handover**
Purpose: A scaffold is not in service until it is complete, inspected and formally handed over.
Key points:
   - Never allow other trades onto an incomplete scaffold, even for a quick job.
   - Tag the scaffold red or use a physical barrier until it is complete and inspected.
   - Issue the handover certificate stating the duty class, loading limits and any restrictions.
   - Brief the receiving contractor on what the scaffold may and may not be used for.
   - Record the inspection and keep the register on site and up to date.
   - Re-inspect and re-tag after any alteration before returning it to service.

**TBT-SCA-023 · Temporary Roofs & Temporary Buildings**
Purpose: Temporary roofs create huge sail areas and place heavy loads on the scaffold below.
Key points:
   - Build only to the specific design; temporary roofs are never TG20 compliant standard work.
   - Check that the supporting scaffold, ties and foundations are designed for the additional loads.
   - Sequence sheeting so wind loading is not applied before the structure is complete and tied.
   - Monitor wind speeds and stop work at the limit stated in the design.
   - Inspect sheeting, fixings and ties after every period of high wind.
   - Manage the additional fall and dropped-object risk of working at roof level.

**TBT-SCA-024 · System Scaffold Assembly**
Purpose: System scaffold assembles quickly, which makes it easy to leave out components and move on.
Key points:
   - Use only matched components from a single system — never mix manufacturers.
   - Check every ledger, transom and brace is fully engaged and wedged or locked.
   - Inspect components for damage, distortion and corrosion before they go up.
   - Build to the manufacturer's user guide and the approved configuration.
   - Do not substitute tube and fitting into a system scaffold without design approval.
   - Segregate damaged components so they cannot be reused.

**TBT-SCA-025 · Advance Guardrail Systems**
Purpose: Advance guardrails give collective protection to the scaffolder building the lift above.
Key points:
   - Use advance guardrails as the primary control wherever the system allows it.
   - Install the guardrail from the lift below before anyone steps onto the new lift.
   - Check the guardrail is engaged and locked before relying on it.
   - Maintain the harness as the backup, not the substitute, where SG4 requires it.
   - Remove advance guardrails only as the permanent guardrails are installed.
   - Report missing or damaged advance guardrail components before starting the lift.

**TBT-SCA-026 · Harness & Lanyard Inspection for Scaffolders**
Purpose: A harness only works if it is undamaged, correctly fitted and attached to something that will hold.
Key points:
   - Carry out a pre-use check every day: webbing, stitching, D-rings, buckles, energy absorber and connectors.
   - Check the formal inspection is in date and the equipment is within its service life.
   - Fit the harness correctly — loose leg straps cause severe injury in a fall.
   - Attach only to an anchor capable of taking the load, and keep the lanyard short to limit fall distance.
   - Consider the clearance below: a fall arrest lanyard needs room to deploy.
   - Quarantine any harness or lanyard that has arrested a fall or shows damage.

**TBT-SCA-027 · Unauthorised Alteration by Other Trades**
Purpose: Removing a single tie or board to get access has collapsed scaffolds and killed people.
Key points:
   - Only trained scaffolders may alter, add to or remove any part of a scaffold.
   - Never remove ties, braces, boards, guardrails or toe boards to make access easier.
   - Report any alteration or missing component you find, whoever made it.
   - Check the scaffold tag before using any scaffold; a missing or red tag means do not use.
   - Alterations must be inspected and re-tagged before the scaffold goes back into service.
   - Raise a request with the scaffold contractor instead of adapting it yourself.

**TBT-SCA-028 · Beams, Bridging & Heavy Components**
Purpose: Beams and bridging units are heavy, long and awkward to place at height.
Key points:
   - Plan the lift — use a hoist, crane or gin wheel rather than manhandling beams up the scaffold.
   - Use enough people and agree who calls the move before lifting starts.
   - Secure and pin beams immediately; an unsecured beam can roll or slide off the bearing.
   - Keep clear of the beam ends and never work beneath a beam being positioned.
   - Check bearing lengths, fixings and support standards against the design.
   - Watch for pinch points when landing and levelling heavy components.

**TBT-SCA-029 · Scaffolds on Occupied Buildings**
Purpose: Scaffolding an occupied building puts residents, staff and the public directly beneath the works.
Key points:
   - Agree working hours, access and protection with the building occupier before starting.
   - Fit fans, netting and brick guards to protect people below.
   - Maintain occupiers' escape routes and never obstruct fire exits or fire escape windows.
   - Consider security — scaffolds give access to windows, so fit alarms or anti-climb where required.
   - Keep noise and disruption to the agreed times and give notice of noisy operations.
   - Screen and light the scaffold so occupants are not put at risk after dark.

**TBT-SCA-030 · Scaffolding Near Overhead Power Lines**
Purpose: Scaffold tube conducts, and a tube raised near a line can kill without contact.
Key points:
   - Identify overhead lines during survey and record them in the design brief.
   - Arrange isolation or diversion with the network operator where possible.
   - Where lines remain live, observe the GS6 clearance distances and use barriers and goal posts.
   - Never raise tube, boards or beams vertically near a line — carry them horizontally.
   - Treat all lines as live regardless of appearance.
   - Stop work in high winds where tubes or sheeting could move toward the line.

**TBT-SCA-031 · Fall Restraint vs Fall Arrest**
Purpose: Restraint stops you reaching the edge; arrest catches you after you fall — they are not interchangeable.
Key points:
   - Prefer collective protection first; restraint before arrest where personal protection is needed.
   - Restraint lanyards must be short enough that you cannot physically reach the fall edge.
   - Fall arrest requires an energy absorber, a rated anchor and sufficient clearance below.
   - Calculate the total fall distance including lanyard, absorber deployment and body length.
   - Beware pendulum swing when anchored to one side of the work position.
   - Always have a rescue plan in place before anyone clips on.

**TBT-SCA-032 · Loading & Offloading Scaffold Vehicles**
Purpose: Offloading is where scaffolders are crushed by falling tube and boards.
Key points:
   - Offload on firm, level ground in a segregated area away from other trades.
   - Never stand on the bed or between the load and the body while releasing restraints.
   - Expect the load to have shifted in transit; release straps from the safe side.
   - Use mechanical offloading where the load is heavy or unstable.
   - Stack tube, boards and fittings in dedicated stillages and within safe heights.
   - Keep the working area clear as materials come off — do not build a trip hazard.

**TBT-SCA-033 · Rubbish Chutes & Debris Removal**
Purpose: Chutes concentrate falling material and generate dust at both ends.
Key points:
   - Fit chutes to the manufacturer's instructions with the designed support and ties.
   - Enclose and barrier the bottom of the chute and never let anyone work beside the skip.
   - Do not overload the chute or force oversized material into it.
   - Suppress dust at the top and bottom and wear RPE where dust cannot be controlled.
   - Keep the hopper guarded so nobody can fall into it.
   - Inspect the chute and its fixings regularly, particularly after high winds.

**TBT-SCA-034 · Mast Climbers & Suspended Platforms**
Purpose: Powered access platforms carry the risk of uncontrolled descent, overload and entrapment.
Key points:
   - Only trained and authorised operatives may operate mast climbers and cradles.
   - Check the daily pre-use inspection and the thorough examination certificate.
   - Never exceed the rated load or distribute it unevenly on the platform.
   - Keep the mast, ties and the base area clear and inspected.
   - Maintain guardrails and never climb on them or use ladders on the platform.
   - Know the emergency lowering procedure and the rescue plan before going up.

**TBT-SCA-035 · Scaffolding Over Water & Restricted Sites**
Purpose: Water adds drowning risk to every fall and makes rescue far harder.
Key points:
   - Provide edge protection, buoyancy aids and throw lines where work is over or near water.
   - Have a rescue craft or trained rescue arrangement in place before work begins.
   - Never work alone over water and maintain a means of raising the alarm.
   - Check tidal and flow conditions and stop work when they exceed the plan.
   - Beware of unstable riverbeds, soft ground and scour affecting scaffold foundations.
   - Consider Weil's disease risk: cover cuts, wash hands and report flu-like symptoms.

**TBT-SCA-036 · Gaps, Traps & Incomplete Scaffold**
Purpose: Most falls from scaffolds are through gaps, not over guardrails.
Key points:
   - Board out platforms fully with no traps, gaps or unsupported board ends.
   - Check board overhang and support spacing — a trap board tips when stepped on.
   - Fill gaps at returns, corners and around the building face.
   - Never leave a partly boarded lift accessible at the end of a shift.
   - Fit guardrails and toe boards to all open edges including internal gaps over 300mm.
   - Report and correct any gap you find rather than stepping around it.

**TBT-SCA-037 · Lighting & Low-Visibility Scaffold Work**
Purpose: Poor light hides gaps, edges and obstructions on a structure where every step matters.
Key points:
   - Provide adequate task and access lighting before starting any work in the dark.
   - Light the access routes, ladder bays and landing points, not just the work face.
   - Use head torches as a supplement, never as the main lighting.
   - Increase hi-vis standards and be aware of reduced visibility to plant operators.
   - Beware glare and shadow that make board gaps invisible.
   - Consider stopping work rather than continuing in inadequate light.

**TBT-SCA-038 · Third-Party Damage & Vehicle Impact**
Purpose: A struck standard or a removed tie can compromise a whole scaffold without anyone noticing.
Key points:
   - Protect scaffolds near traffic routes with barriers, bollards and high-visibility marking.
   - Report any vehicle or plant impact immediately, however minor it looks.
   - Take the scaffold out of use, tag it red and have it inspected before reuse.
   - Inspect after high winds, impacts and any event likely to affect stability.
   - Look for bent standards, sprung fittings, displaced boards and pulled ties.
   - Record the damage and the remedial work in the inspection register.

**TBT-SCA-039 · Ice, Contamination & Slippery Boards**
Purpose: Scaffold boards become treacherous with ice, algae, mud, frost and spilled materials.
Key points:
   - Check platforms for ice and frost before starting and treat or clear them.
   - Clear mud, mortar, resin and algae from boards rather than working around them.
   - Wear boots with good tread and clean them before climbing.
   - Take extra care on ladder rungs and access points in wet and cold weather.
   - Delay the start of work rather than climbing onto frozen platforms.
   - Report contaminated or damaged boards for replacement.

**TBT-SCA-040 · Communication & Signalling in Scaffold Gangs**
Purpose: Scaffolding is a team operation carried out at height where a misunderstanding causes a drop.
Key points:
   - Brief the gang on the sequence and everyone's role before starting each lift.
   - Agree clear calls for lifting, lowering and stopping, and use one voice at a time.
   - Confirm each handover of a component verbally — never let go until the other person has it.
   - Keep noise, radios and phones from masking instructions.
   - Anyone may call a stop at any point without explanation.
   - Re-brief whenever the gang, the sequence or the conditions change.

### 4.7 Bricklaying & Blockwork (`brick_block`)

**TBT-BRK-001 · Silica Dust from Cutting Blocks & Bricks**
Purpose: Cutting masonry is a major source of lung-damaging silica dust.
Key points:
   - Use water suppression or on-tool extraction when cutting.
   - Wear face-fit-tested FFP3 RPE.
   - Cut outside or in well-ventilated areas.
   - Never dry-sweep — use an M-class vacuum.
   - Rotate tasks to limit exposure.

**TBT-BRK-002 · Manual Handling of Blocks**
Purpose: Heavy and repetitive block-laying causes back injuries.
Key points:
   - Use lighter blocks or mechanical aids where possible.
   - Two-person lift heavy blocks.
   - Set spot boards at working height.
   - Rotate tasks and take breaks.
   - Keep the load close and avoid twisting.

**TBT-BRK-003 · Working Platforms for Brickwork**
Purpose: Brickwork is sustained height work needing stable platforms.
Key points:
   - Use proprietary towers or hop-ups, not makeshift platforms.
   - Raise platforms in correct lift heights.
   - Maintain guardrails.
   - Never overload the platform.
   - Keep platforms tidy.

**TBT-BRK-004 · Cement & Mortar — Dermatitis & Burns**
Purpose: Wet cement is corrosive and causes burns and dermatitis.
Key points:
   - Wear waterproof gloves.
   - Avoid skin contact and wash off promptly.
   - Check skin regularly for damage.
   - Manage mixing dust with RPE.
   - Keep wash stations available.

**TBT-BRK-005 · Cutting Stations & Bench Saws**
Purpose: Masonry saws cause cuts, silica and noise hazards.
Key points:
   - Use guards and water feed.
   - Wear eye, hearing and respiratory protection.
   - Secure the workpiece.
   - Only trained users operate saws.
   - Isolate before clearing or adjusting.

**TBT-BRK-006 · Mortar Silos & Mixers**
Purpose: Silos and mixers bring entanglement, dust and collapse risks.
Key points:
   - Isolate mixers before clearing.
   - Beware entanglement with moving parts.
   - Control silica dust from dry mortar.
   - Check silo stability and access.
   - Wear RPE and eye protection.

**TBT-BRK-007 · Scaffold Use for Bricklayers**
Purpose: Bricklayers rely on others' scaffolds — use them correctly.
Key points:
   - Check the scaffold tag before use.
   - Never overload with bricks and blocks.
   - Report damage or missing components.
   - Keep loading within bay limits.
   - Maintain toe boards and guardrails.

**TBT-BRK-008 · Lifting Materials to Height**
Purpose: Getting bricks and mortar up safely.
Key points:
   - Use hoists or telehandlers, not manual throwing.
   - Observe SWL and loading bays.
   - Control dropped objects.
   - Communicate during lifting.
   - Stack safely at height.

**TBT-BRK-009 · Manual Handling of Lintels & Beams**
Purpose: Heavy structural units cause crush and back injuries.
Key points:
   - Use mechanical lifting for heavy lintels.
   - Team-lift and plan the route.
   - Beware trapped fingers during placement.
   - Support until fixed.
   - Wear gloves and toe protection.

**TBT-BRK-010 · Hot Weather & Mortar Work**
Purpose: Heat affects both workers and the work.
Key points:
   - Stay hydrated and protected from the sun.
   - Manage cement burns made worse by sweat.
   - Take breaks in shade.
   - Protect fresh work from rapid drying.
   - Watch for heat stress.

**TBT-BRK-011 · Pointing & Repointing**
Purpose: Repetitive close work with dust and posture issues.
Key points:
   - Control silica dust when raking out.
   - Manage posture and rotate.
   - Use suitable access for height.
   - Wear eye and respiratory protection.
   - Keep tools sharp and in good order.

**TBT-BRK-012 · Brick & Block Deliveries**
Purpose: Offloading heavy packs creates crush and plant risks.
Key points:
   - Use mechanical offloading.
   - Segregate from pedestrians.
   - Stack packs on firm, level ground.
   - Beware unstable or banded packs.
   - Use a banksman for plant.

**TBT-BRK-013 · Working at Leading Edges**
Purpose: Building up to open edges risks falls.
Key points:
   - Provide edge protection at open edges.
   - Use platforms with guardrails.
   - Beware reaching over edges.
   - Coordinate with scaffolders.
   - Maintain exclusion zones below.

**TBT-BRK-014 · Hand Tools for Bricklayers**
Purpose: Trowels, bolsters and hammers cause cuts and impact injuries.
Key points:
   - Keep tools in good condition.
   - Wear eye protection when cutting with bolsters.
   - Cut and strike away from the body.
   - Store tools safely.
   - Replace damaged tools.

**TBT-BRK-015 · Cavity Wall Insulation Handling**
Purpose: Insulation fibres and boards irritate and need handling care.
Key points:
   - Wear gloves and RPE for fibre insulation.
   - Handle boards to avoid back strain.
   - Cut with sharp knives safely.
   - Keep the area tidy.
   - Avoid skin and eye contact.

**TBT-BRK-016 · Concrete Blockwork Stability**
Purpose: Freshly-laid blockwork can be unstable.
Key points:
   - Prop tall or freestanding walls until cured.
   - Beware wind loading on new walls.
   - Do not overload fresh work.
   - Follow temporary works requirements.
   - Inspect for stability.

**TBT-BRK-017 · Wall Ties & Restraint Fixings**
Purpose: Drilling and fixing into masonry and structure.
Key points:
   - Scan before drilling into structure.
   - Control silica dust.
   - Wear eye and hand protection.
   - Use the correct fixings.
   - Maintain safe access for high-level fixing.

**TBT-BRK-018 · Mixing & COSHH for Bricklayers**
Purpose: Additives and cements are hazardous substances.
Key points:
   - Follow COSHH assessments for additives.
   - Control mixing dust with RPE.
   - Protect skin and eyes.
   - Store materials correctly.
   - Wash before eating.

**TBT-BRK-019 · Repetitive Strain & Posture**
Purpose: Block-laying is highly repetitive.
Key points:
   - Set work at the right height with spot boards.
   - Rotate tasks across the day.
   - Warm up and stretch.
   - Use mechanical aids.
   - Report strains early.

**TBT-BRK-020 · Banker Masonry & Stone Cutting**
Purpose: Cutting and dressing stone produces high silica dust.
Key points:
   - Use water suppression and extraction.
   - Wear FFP3 RPE.
   - Beware sharp tools and flying chips.
   - Manage posture at the banker.
   - Keep the area tidy.

**TBT-BRK-021 · Thin-Joint & Aircrete Systems**
Purpose: Aircrete cuts and sands easily, which means high dust generation and large, awkward units.
Key points:
   - Cut aircrete with a handsaw or with on-tool extraction — never dry-cut with a disc cutter.
   - Wear FFP3 RPE and eye protection; aircrete dust contains respirable silica.
   - Handle large-format blocks with two people or a mechanical aid — they are bulky, not light.
   - Mix thin-joint mortar to the instructions and protect skin from the cement content.
   - Watch stability: thin-joint walls gain strength quickly but are vulnerable when freshly built.
   - Keep the cutting station away from other trades and clear dust with an M-class vacuum.

**TBT-BRK-022 · Mast Climbing Work Platforms for Brickwork**
Purpose: Mast climbers carry bricklayers and heavy materials and fail badly when overloaded.
Key points:
   - Only trained and authorised operatives may operate the platform.
   - Check the pre-use inspection and the thorough examination certificate before use.
   - Never exceed the rated load and distribute materials evenly along the platform.
   - Keep the mast, ties and base area clear and inspected, especially after deliveries.
   - Maintain the guardrails and gap between platform and wall; never climb on the rails.
   - Know the emergency lowering and rescue procedure before going up.

**TBT-BRK-023 · Chasing & Cutting Existing Masonry**
Purpose: Chasing generates high silica dust and regularly strikes buried cables and pipes.
Key points:
   - Scan for services before chasing and isolate circuits where possible.
   - Use a wall chaser with on-tool extraction, never an unguarded grinder.
   - Wear FFP3 RPE that has been face-fit tested, plus eye, face and hearing protection.
   - Check for asbestos in older buildings before disturbing any material.
   - Do not chase structural elements or exceed the permitted depth without approval.
   - Clean up with an M-class vacuum, never by dry sweeping or blowing.

**TBT-BRK-024 · Natural & Reconstituted Stone Handling**
Purpose: Stone units are dense, heavy and slippery when wet, with high crush potential.
Key points:
   - Never lift stone units by hand beyond the safe weight — use a lifting aid or two people.
   - Check for cracks and flaws before lifting; stone can break in the hands.
   - Use vacuum lifters or slings rated for the load and keep hands out from under it.
   - Chock and stack stone flat and stable, never on edge against a wall.
   - Cut stone wet with proper suppression; reconstituted stone is high in silica.
   - Protect feet and hands with the right PPE for the weight and edges.

**TBT-BRK-025 · Lime Mortar & Heritage Masonry**
Purpose: Hot and hydraulic limes burn skin and eyes more aggressively than cement.
Key points:
   - Treat quicklime and hot-mixed lime as corrosive; slaking generates heat and splashes.
   - Wear goggles, gauntlets and full skin cover when mixing or handling lime.
   - Never allow lime to get inside gloves or boots — remove and wash immediately.
   - Irrigate any eye contact for at least 20 minutes and seek medical attention.
   - Work on heritage structures only with the agreed method; old masonry may be unstable.
   - Beware lead paint, asbestos and bird contamination in historic buildings.

**TBT-BRK-026 · DPCs, Cavity Trays & Cavity Cleanliness**
Purpose: Working in the cavity means sharp edges, awkward reach and dropped debris on those below.
Key points:
   - Keep the cavity clean as you build; dropped mortar bridges the cavity and causes damp.
   - Use a cavity batten and lift it carefully to avoid showering debris down the wall.
   - Beware sharp DPC and tray edges and use suitable gloves.
   - Avoid over-reaching into the cavity from a platform; move the platform instead.
   - Check no one is working below when clearing cavity debris.
   - Follow the detail — trays and DPCs are part of the building's weather and fire performance.

**TBT-BRK-027 · Profiles, Lines & Trip Hazards**
Purpose: Lines, pins, profiles and spot boards turn a working platform into an obstacle course.
Key points:
   - Set profiles and lines so they do not cross walking routes at shin or neck height.
   - Flag lines and pins so they are visible, particularly in poor light.
   - Keep spot boards, tubs and materials in a consistent position away from the walkway.
   - Clear tools, offcuts and mortar droppings from the platform as you go.
   - Secure profiles properly; a falling profile is a dropped object.
   - Remove lines and pins as soon as the work is complete.

**TBT-BRK-028 · Winter Working & Frost Protection**
Purpose: Cold weather affects both the operative and the masonry, and frost damage can bring walls down.
Key points:
   - Do not lay masonry when the temperature is below the specified minimum or falling.
   - Protect new work with frost blankets and hessian and secure them against wind.
   - Keep hands warm and dry to maintain grip and reduce vibration injury risk.
   - Watch for ice on scaffold boards, ladders and access routes.
   - Take regular warm breaks and watch colleagues for signs of cold stress.
   - Never use antifreeze additives unless specified by the designer.

**TBT-BRK-029 · Working Below Other Trades on Scaffold**
Purpose: Bricklayers spend the day under the lift above and are exposed to everything dropped from it.
Key points:
   - Check what is happening on the lifts above before starting work below.
   - Insist on toe boards, brick guards and netting where work is going on overhead.
   - Wear a hard hat correctly at all times — chin straps where there is a risk of it being knocked off.
   - Agree exclusion zones and sequencing with the trades above rather than working through.
   - Report anything dropped, including near misses with no injury.
   - Never store or stack materials where they can be knocked off a lift.

**TBT-BRK-030 · Angle Grinders on Masonry**
Purpose: Grinders cause the most severe hand and face injuries on site and generate huge dust clouds.
Key points:
   - Never dry-cut masonry — use water suppression or on-tool extraction as standard.
   - Only appointed persons may change abrasive wheels and discs.
   - Check the disc rating against the machine speed and inspect for cracks.
   - Keep the guard fitted and positioned between you and the disc.
   - Secure the work; never hold a small block in one hand and cut with the other.
   - Wear face shield, eye protection, hearing protection and FFP3 RPE every time.

**TBT-BRK-031 · Feature Brickwork, Arches & Formers**
Purpose: Arch centring and feature work involve temporary support that must not be struck too early.
Key points:
   - Use a former or centring designed for the load and support it properly.
   - Never strike centring until the mortar has gained adequate strength and it is authorised.
   - Support heavy feature units until the surrounding brickwork is complete.
   - Beware of working in awkward positions when setting soldiers, corbels and bands.
   - Cut special shapes at the cutting station with suppression, not in position on the wall.
   - Check the stability of freestanding feature panels against wind loading.

**TBT-BRK-032 · Telehandler & Forklift Interface for Bricklayers**
Purpose: Most bricklayers work within metres of a telehandler placing packs all day.
Key points:
   - Never stand beneath or alongside a raised load being landed on a scaffold or platform.
   - Agree a landing sequence and signals with the operator before the lift.
   - Check the scaffold or platform is designed for the load being placed on it.
   - Keep clear of the machine's slew, reach and reversing path; make eye contact before approaching.
   - Land packs squarely and remove banding only once the pack is stable and clear of the forks.
   - Report damaged pallets, banding and packs rather than working with them.

**TBT-BRK-033 · Cement Burns — Recognition & First Aid**
Purpose: Wet cement causes chemical burns that develop slowly and can need skin grafts.
Key points:
   - Wet cement and mortar are highly alkaline and burn on prolonged contact, often without pain at first.
   - Never kneel or stand in wet mortar or let it get inside boots and gloves.
   - Change contaminated clothing immediately rather than working on in it.
   - Wash affected skin with clean water immediately and keep washing.
   - Get medical advice for any reddening, blistering or burning sensation.
   - Report every cement burn — they are RIDDOR reportable when serious.

**TBT-BRK-034 · Wind Loading on Freestanding & New Walls**
Purpose: Newly built freestanding walls have collapsed in wind and killed bystanders.
Key points:
   - Follow the temporary works design for maximum unsupported heights and propping.
   - Prop or brace freestanding and gable walls before leaving them at the end of a shift.
   - Reduce lift heights in exposed positions and in windy conditions.
   - Never rely on new mortar for stability — it has almost no strength for the first day.
   - Barrier off the area both sides of a freestanding wall.
   - Stop work and make safe when wind speeds reach the limit in the method statement.

**TBT-BRK-035 · Chimneys & High-Level Masonry**
Purpose: Chimney work is at the highest, most exposed point of a building with fragile roof below.
Key points:
   - Provide a proper scaffold with edge protection at chimney level — never work off a roof ladder alone.
   - Assess the stability of the existing stack before working on or dismantling it.
   - Lower materials, never throw them, and protect the area below.
   - Beware of fragile roof coverings, rooflights and rotten timbers around the stack.
   - Check for flue gases, birds' nests and asbestos-containing flue liners.
   - Stop work in high winds — exposure at stack level is far greater than at ground.

**TBT-BRK-036 · Movement Joints & Sealants**
Purpose: Sealant work adds COSHH exposure and awkward postures to the masonry trade.
Key points:
   - Read the safety data sheet; many sealants and primers contain isocyanates and solvents.
   - Ventilate the work area and wear the gloves and RPE specified.
   - Avoid skin contact with uncured sealant and never clean hands with solvent.
   - Use a proper gun and technique to reduce repetitive strain on the hand and wrist.
   - Install joint fillers and backer rods to the design so the joint performs.
   - Dispose of cartridges and offcuts as hazardous waste where required.

**TBT-BRK-037 · Brick Slips & Cladding Systems**
Purpose: Slip systems combine adhesives, cutting, height work and fire performance requirements.
Key points:
   - Use only the tested system components; substitutions can invalidate fire performance.
   - Cut slips at a suppressed cutting station, never dry in position.
   - Follow COSHH controls for adhesives, primers and resins.
   - Check mechanical fixings and rail alignment against the design before bonding.
   - Work from a suitable platform and control dropped slips and tools.
   - Record the installation for the building safety information where required.

**TBT-BRK-038 · Spot Boards, Boards & Housekeeping on Lifts**
Purpose: A bricklayer's platform fills with mortar, offcuts and packaging within an hour.
Key points:
   - Keep a clear walking route along the lift at all times.
   - Clear mortar droppings before they set and become trip hazards.
   - Bag banding, shrink wrap and packaging immediately — wind takes them over the edge.
   - Keep offcuts in a bin, never stacked on the toe board or guardrail.
   - Do not overload the lift with materials beyond its duty class.
   - Leave the platform clean and safe at the end of every shift.

**TBT-BRK-039 · Hearing Protection During Masonry Cutting**
Purpose: Cutting and breaking masonry routinely exceeds the noise levels that cause permanent hearing damage.
Key points:
   - Recognise that disc cutters, breakers and mixers all exceed the upper exposure action value.
   - Wear the hearing protection provided in designated zones and during noisy tasks.
   - Choose protection that attenuates enough without cutting you off from warnings and alarms.
   - Fit plugs correctly and keep muffs sealed against the head — a gap destroys the protection.
   - Rotate noisy tasks and use quieter methods where they exist.
   - Report ringing, muffled hearing or difficulty following conversation.

**TBT-BRK-040 · Scaffold Ties Through Brickwork**
Purpose: Ties passing through the wall affect both the scaffold's stability and the masonry's integrity.
Key points:
   - Never remove or reposition a scaffold tie to continue building — request a scaffold alteration.
   - Do not build tight around a tie in a way that traps it or prevents later removal.
   - Report ties that are loose, pulled or bearing on unsupported masonry.
   - Make good tie holes correctly once the scaffold is struck.
   - Check that new or green masonry can take tie loads before the scaffold relies on it.
   - Coordinate tie positions with the scaffold contractor before building the lift.

### 4.8 Carpentry & Joinery (`joinery`)

**TBT-JOI-001 · Woodworking Machinery & Saws**
Purpose: Saws, routers and planers cause severe lacerations and amputations.
Key points:
   - Keep guards and riving knives in place.
   - Use push sticks and never wear gloves near rotating tools.
   - Only trained users operate machinery.
   - Use LEV for dust.
   - Isolate before changing blades or clearing.

**TBT-JOI-002 · Wood Dust (Carcinogen)**
Purpose: Hardwood and softwood dust cause respiratory disease and cancer.
Key points:
   - Use LEV and on-tool extraction.
   - Wear suitable RPE.
   - Clean with an H/M-class vacuum, not a brush.
   - Ventilate enclosed work areas.
   - Minimise dust at source.

**TBT-JOI-003 · Nail Guns & Cartridge Tools**
Purpose: High-energy fixing tools cause serious puncture injuries.
Key points:
   - Never bypass the safety tip or contact trip.
   - Keep the free hand clear of the firing line.
   - Disconnect when not in use or clearing jams.
   - Wear eye protection.
   - Only trained users operate them.

**TBT-JOI-004 · First Fix at Height & Access**
Purpose: First-fix carpentry often involves height and long materials.
Key points:
   - Use podiums and towers for sustained height work.
   - Handle long timber with two people.
   - Control dropped objects.
   - Maintain tidy access routes.
   - Coordinate with other trades.

**TBT-JOI-005 · Adhesives, Sealants & Solvents**
Purpose: Joinery adhesives are flammable and give off vapours.
Key points:
   - Ventilate the work area.
   - Use RPE where needed.
   - Keep away from ignition sources.
   - Protect skin and eyes.
   - Store and seal correctly.

**TBT-JOI-006 · Manual Handling of Sheet Materials**
Purpose: Large boards are heavy, awkward and have sharp edges.
Key points:
   - Use panel lifters or two-person lifts.
   - Beware sharp edges and splinters.
   - Watch for pinch points.
   - Keep routes clear.
   - Store sheets safely to prevent toppling.

**TBT-JOI-007 · Hand Tools for Joiners**
Purpose: Chisels, knives and saws cause frequent cuts.
Key points:
   - Keep blades sharp and cut away from the body.
   - Use the correct tool for the task.
   - Store sharp tools safely.
   - Inspect handles and blades.
   - Wear cut-resistant gloves where suitable.

**TBT-JOI-008 · Second Fix & Finishing**
Purpose: Detailed work with repetitive tasks and finishing products.
Key points:
   - Manage posture and rotate tasks.
   - Ventilate when using finishing products.
   - Protect finished surfaces.
   - Control dust from sanding.
   - Keep the area tidy.

**TBT-JOI-009 · Door & Frame Installation**
Purpose: Heavy doors and frames cause crush and handling injuries.
Key points:
   - Team-lift heavy doors and frames.
   - Support during installation.
   - Beware trapped fingers.
   - Use wedges and props safely.
   - Protect glazed doors.

**TBT-JOI-010 · Staircase Installation**
Purpose: Awkward heavy components fitted around openings.
Key points:
   - Protect floor openings during install.
   - Team-lift staircases.
   - Provide temporary edge protection.
   - Beware falls at the opening.
   - Secure components during fixing.

**TBT-JOI-011 · Kitchen & Worktop Fitting**
Purpose: Heavy units and worktops with cutting hazards.
Key points:
   - Team-lift worktops and units.
   - Control silica/stone dust when cutting stone worktops.
   - Beware sharp edges.
   - Use suitable access for wall units.
   - Protect finishes and appliances.

**TBT-JOI-012 · Bench & Site Saw Use**
Purpose: Site saws cause cuts, kickback and dust.
Key points:
   - Use guards, riving knife and push sticks.
   - Beware kickback — stand to one side.
   - Extract or suppress dust.
   - Secure the workpiece.
   - Isolate to clear or adjust.

**TBT-JOI-013 · Routers & Trimmers**
Purpose: High-speed cutters cause cuts and eye injuries.
Key points:
   - Secure the workpiece and keep hands clear.
   - Wear eye and hearing protection.
   - Let the tool stop before setting down.
   - Extract dust.
   - Inspect cutters before use.

**TBT-JOI-014 · Working with MDF & Treated Timber**
Purpose: Engineered and treated timbers carry chemical dust risks.
Key points:
   - Control MDF dust (contains resins) with extraction.
   - Wear RPE when cutting MDF.
   - Beware preservatives in treated timber.
   - Wash hands before eating.
   - Dispose of offcuts correctly.

**TBT-JOI-015 · Floor Laying & Kneeling Work**
Purpose: Repetitive low-level work causes knee and back strain.
Key points:
   - Use knee pads and rotate tasks.
   - Manage posture and take breaks.
   - Ventilate when using adhesives.
   - Beware trip hazards from materials.
   - Handle flooring packs with care.

**TBT-JOI-016 · Temporary Protection & Hoarding**
Purpose: Joiners build site protection and hoardings.
Key points:
   - Build hoardings to withstand wind loading.
   - Secure against collapse.
   - Maintain safe access during build.
   - Control dropped objects.
   - Light and sign public-facing hoardings.

**TBT-JOI-017 · Glue & Resin Systems**
Purpose: Two-part resins and glues are hazardous.
Key points:
   - Follow COSHH for two-part systems.
   - Ventilate and use RPE.
   - Protect skin and eyes.
   - Manage exotherm/heat from curing.
   - Store and mix safely.

**TBT-JOI-018 · Site Carpentry Around Openings**
Purpose: Working near floor and stair openings.
Key points:
   - Maintain opening protection.
   - Use edge protection and covers.
   - Beware falls while measuring and fixing.
   - Coordinate with other trades.
   - Reinstate any protection removed.

**TBT-JOI-019 · Repetitive Tasks & Vibration**
Purpose: Sanders and powered tools cause HAVS and strain.
Key points:
   - Manage vibration trigger-times.
   - Rotate repetitive tasks.
   - Use anti-vibration tools.
   - Take breaks.
   - Report symptoms early.

**TBT-JOI-020 · Bench Joinery & Workshop Safety**
Purpose: Workshop machines and benches concentrate hazards.
Key points:
   - Guard all machines and use extraction.
   - Keep the workshop tidy.
   - Store tools and materials safely.
   - Manage noise and dust.
   - Only trained users operate machines.

**TBT-JOI-021 · Circular Saws & Kickback**
Purpose: Kickback throws the saw or the workpiece back at the operator faster than anyone can react.
Key points:
   - Set the blade depth just proud of the material and keep the riving knife fitted and aligned.
   - Never remove or wedge the retracting lower guard.
   - Support the workpiece so the cut cannot close and pinch the blade.
   - Stand to the side of the blade line, not directly behind the saw.
   - Let the blade reach full speed before cutting and stop before lifting the saw.
   - Isolate before changing the blade and check the blade is the right type and sharp.

**TBT-JOI-022 · Chop Saws & Mitre Saws**
Purpose: Chop saws are used constantly, often on an improvised bench, with the blade close to the hands.
Key points:
   - Set the saw on a stable, level bench at a safe working height with material support both sides.
   - Keep hands outside the marked no-hands zone and never cross your arm over the blade.
   - Clamp small or short pieces rather than holding them by hand.
   - Wait for the blade to stop before lifting the head or clearing offcuts.
   - Fit dust extraction and wear eye, hearing and respiratory protection.
   - Position the saw so the discharge of dust and offcuts is away from walkways and other trades.

**TBT-JOI-023 · Planers, Thicknessers & Spindle Moulders**
Purpose: These machines cause some of the most severe amputations in woodworking.
Key points:
   - Only trained and authorised operatives may use these machines.
   - Keep bridge guards and all guarding correctly set for every cut.
   - Always use push blocks, push sticks and a false fence — never hands near the cutter.
   - Never remove workpieces or clear shavings while the cutter is turning.
   - Isolate and lock off before changing cutters, and check cutter security afterwards.
   - Run the extraction and keep the floor clear of shavings around the machine.

**TBT-JOI-024 · Knives, Blades & Cutting Injuries**
Purpose: Utility knives cause more injuries on site than almost any other tool.
Key points:
   - Use a safety knife with a retracting or self-retracting blade wherever possible.
   - Always cut away from the body and never towards a supporting hand.
   - Change blades when they start to drag; blunt blades need force and slip.
   - Retract or sheath the blade the moment you finish the cut.
   - Dispose of used blades in a sharps container, never loose in a bin or pocket.
   - Wear cut-resistant gloves appropriate to the task.

**TBT-JOI-025 · Timber Deliveries & Stacking**
Purpose: Timber packs are heavy, roll easily and collapse when badly stacked.
Key points:
   - Offload with mechanical means onto firm, level ground and never stand beneath the load.
   - Release banding from the safe side and expect the pack to spring or shift.
   - Stack timber level, on bearers, within safe heights and chocked against rolling.
   - Keep stacks clear of walkways, escape routes and scaffold edges.
   - Sheet and secure stacks against wind and weather.
   - Take from the top of a stack, never pull from the middle or bottom.

**TBT-JOI-026 · Joists, Trusses & Open Floors**
Purpose: Working on open joists is one of the highest fall risks in carpentry.
Key points:
   - Never walk the joists — use a fully boarded platform or proprietary decking.
   - Install temporary edge protection and cover openings before work starts.
   - Brace and restrain trusses to the design as they are erected; unbraced trusses topple.
   - Use safety netting or airbags beneath open floor work where specified.
   - Plan the lifting of trusses and beams; do not manhandle them into position at height.
   - Keep the area below clear and barriered against dropped tools and materials.

**TBT-JOI-027 · Fire Doors & Fire-Rated Joinery**
Purpose: A fire door only performs if the door, frame, seals and ironmongery are installed as tested.
Key points:
   - Install to the certified specification — do not substitute ironmongery, seals or packing.
   - Maintain the specified gaps and do not trim beyond the permitted amount.
   - Fit intumescent seals, smoke seals and closers exactly as the certification requires.
   - Never wedge, prop or remove a fire door during construction works.
   - Label, photograph and record each installation for the building safety record.
   - Report damaged doors, missing seals and failed closers rather than making do.

**TBT-JOI-028 · Glass & Glazing Handling**
Purpose: Glass fails suddenly and causes deep, life-threatening cuts.
Key points:
   - Plan every glass move; use suction lifters, trolleys and enough people.
   - Carry glass on edge, never flat, and keep it vertical and under control.
   - Wear cut-resistant gauntlets, arm protection and eye protection.
   - Check for chips and edge damage before lifting — damaged glass breaks in the hands.
   - Store glass in racks, never leaning free against a wall, and mark it clearly.
   - Beware wind catching glazed units, especially at height or in openings.

**TBT-JOI-029 · External Timber Cladding**
Purpose: Cladding means working at height with long boards in the wind and using treated timber.
Key points:
   - Use a scaffold or MEWP giving safe access to the full face — not ladders.
   - Two people minimum for long boards; the wind turns a board into a sail.
   - Cut treated timber with extraction and RPE; preservative dust is harmful.
   - Never cut or sand treated timber in enclosed areas or burn the offcuts.
   - Control dropped boards, fixings and offcuts with toe boards and exclusion zones.
   - Check cavity barriers and fire performance requirements before fixing.

**TBT-JOI-030 · Dust Extraction on Woodworking Machines**
Purpose: Hardwood and composite dusts are carcinogens, and the control is only as good as the extraction.
Key points:
   - Never run a woodworking machine without its extraction connected and working.
   - Check hoods, hoses and filters daily for blockages, splits and detachment.
   - Use an M-class or better vacuum for cleaning up; never dry-sweep or blow down with air.
   - Empty and change bags and filters carefully, wearing RPE, in a ventilated area.
   - Ensure LEV has a current thorough examination and report any loss of suction.
   - Wear FFP3 RPE in addition to extraction for high-dust operations.

**TBT-JOI-031 · Cordless Tools & Lithium Battery Safety**
Purpose: Lithium batteries have caused serious site and van fires that develop in seconds.
Key points:
   - Charge batteries on a hard, non-combustible surface away from materials and escape routes.
   - Use only the manufacturer's charger and never leave batteries charging unattended overnight.
   - Withdraw any battery that is swollen, damaged, hot or has been dropped hard.
   - Do not charge or store batteries in extreme heat or cold, or in a sealed van in summer.
   - Keep loose batteries away from metal objects that can short the terminals.
   - Know that a lithium fire cannot be simply smothered — evacuate and raise the alarm.

**TBT-JOI-032 · Loft Hatches & Access Openings**
Purpose: Every opening a joiner forms is a fall risk until it is protected.
Key points:
   - Guard or cover any opening you form immediately, before moving on.
   - Never leave an opening unprotected at the end of a shift or during a break.
   - Mark and secure covers so they cannot be removed accidentally or blown off.
   - Use proper access to and through the opening, not the frame or ladder edge.
   - Check the area below before cutting and barrier it against falling debris.
   - Reinstate protection after any other trade has used the opening.

**TBT-JOI-033 · Formwork & Temporary Works Carpentry**
Purpose: Formwork carries enormous loads and failure during a pour is sudden and catastrophic.
Key points:
   - Build strictly to the temporary works design — do not substitute timber sizes or fixing centres.
   - Check props, ties and bracing are complete and tightened before any pour.
   - Have the formwork inspected and signed off by the temporary works coordinator.
   - Keep clear of the formwork during the pour except at designated safe positions.
   - Never strike formwork or props without written authorisation.
   - Clear nails, ties and offcuts as formwork is struck to prevent puncture injuries.

**TBT-JOI-034 · Handrails, Balustrades & Guarding**
Purpose: Temporary and permanent guarding is what stops people falling on a site full of edges.
Key points:
   - Install permanent handrails and balustrades as early as the programme allows.
   - Never remove temporary edge protection until the permanent guarding is fixed and complete.
   - Check fixings are into sound substrate and can take the required loading.
   - Verify heights, gaps and infill against Building Regulations before signing off.
   - Protect open stair flights and landings while working on them.
   - Report and reinstate any guarding removed by other trades.

**TBT-JOI-035 · Stud & Partition Carpentry**
Purpose: Studwork means repetitive nailing, overhead fixing and working near services.
Key points:
   - Scan or check drawings before fixing into walls, floors and ceilings.
   - Use suitable access for head and sole plates — not buckets, boards or hop-ups improvised on site.
   - Keep nail gun safety contacts working and never disable sequential trip mechanisms.
   - Brace partitions until they are fixed both ends; freestanding studwork falls easily.
   - Manage repetitive strain with task rotation and correct tool selection.
   - Clear offcuts and protruding fixings as you go.

**TBT-JOI-036 · Joinery in Occupied Properties**
Purpose: In an occupied building the public are the people most likely to be hurt by your work.
Key points:
   - Screen and barrier the work area and keep tools and offcuts inside it.
   - Never leave power tools, blades or nail guns unattended where children can reach them.
   - Control dust with on-tool extraction and protect floors and furnishings.
   - Keep fire doors, escape routes and corridors clear and functional at all times.
   - Agree noisy work times with the occupier and give notice.
   - Leave the area clean, secure and free of hazards at the end of every day.

**TBT-JOI-037 · Nails, Splinters & Puncture Wounds**
Purpose: A nail through a boot or a deep splinter can cause tetanus and serious infection.
Key points:
   - De-nail or bend over protruding nails in stripped timber immediately.
   - Never leave timber with nails up on floors, platforms or walkways.
   - Wear midsole-protected footwear where puncture risk exists.
   - Remove splinters promptly and clean the wound; report any that cannot be removed.
   - Report deep puncture wounds — tetanus status matters.
   - Bag and remove nailed offcuts rather than stacking them.

**TBT-JOI-038 · Site Workshop Set-Up & Power Supply**
Purpose: A well-set-up workshop prevents most of the injuries that happen in a badly improvised one.
Key points:
   - Site the workshop on level ground with space around each machine for infeed and outfeed.
   - Provide adequate lighting, extraction and a clear escape route.
   - Use 110V supply, RCD protection and route leads off the floor.
   - Fit emergency stops and make sure everyone knows where they are.
   - Keep floors clear of offcuts and shavings; sweep with a vacuum, not a brush.
   - Control access so only trained operatives enter and use the machines.

**TBT-JOI-039 · Timber Frame Erection**
Purpose: Timber frame goes up fast, at height, with panels acting as sails and fire risk while unclad.
Key points:
   - Follow the erection sequence and temporary bracing design exactly.
   - Never release a crane hook until the panel is braced and secure.
   - Use tag lines and never guide panels by hand in wind.
   - Stop erection when wind speeds reach the limit in the method statement.
   - Manage the very high fire risk of an unclad frame: no hot works, controlled ignition sources, fire points in place.
   - Install edge protection and floor decking as the frame rises, not afterwards.

**TBT-JOI-040 · Protecting & Storing Finished Joinery**
Purpose: Moving and protecting finished joinery causes manual handling injuries and damage claims late in a job.
Key points:
   - Store joinery flat or racked in a dry, secure area away from traffic routes.
   - Never lean doors and panels against walls where they can slide or fall on someone.
   - Use two people and trolleys for doors, worktops and large units.
   - Apply protection materials that do not create slip or fire hazards.
   - Keep protected areas clear of hot works and ignition sources.
   - Check for concealed damage before lifting — a split unit can fail in the hands.

### 4.9 Drylining & Plastering (`drylining`)

**TBT-DRY-001 · Board Handling & Working at Height**
Purpose: Large plasterboards combine handling and height risk.
Key points:
   - Use board lifters or two-person handling.
   - Use podium steps, not trestles, for height.
   - Wear head protection for overhead fixing.
   - Plan routes and resting points.
   - Beware sharp edges.

**TBT-DRY-002 · Dust from Sanding & Mixing**
Purpose: Joint and plaster dust harms the lungs.
Key points:
   - Use dust-reducing sanders with extraction.
   - Wear RPE.
   - Use wet methods where possible.
   - Ventilate the area.
   - Vacuum, don't sweep.

**TBT-DRY-003 · Stilts Policy & Use**
Purpose: Stilts are high-risk and often prohibited.
Key points:
   - Follow the site stilts policy and competence requirements.
   - Keep floors clear of obstructions and trip hazards.
   - Consider podiums as a safer alternative.
   - Never use damaged stilts.
   - Work within capability.

**TBT-DRY-004 · Plaster & Lime — Skin & Eye Hazards**
Purpose: Plasters and limes are corrosive and irritant.
Key points:
   - Wear gloves and eye protection.
   - Wash off splashes promptly.
   - Beware burns from lime.
   - Keep wash stations available.
   - Follow COSHH guidance.

**TBT-DRY-005 · Metal Stud Partition Erection**
Purpose: Sharp metal track and studs with handling risks.
Key points:
   - Wear cut-resistant gloves for metal track.
   - Handle long lengths with care.
   - Control fixings and dropped objects.
   - Maintain access for high fixing.
   - Keep the area tidy.

**TBT-DRY-006 · Suspended Ceiling Installation**
Purpose: Sustained overhead work with handling and access risk.
Key points:
   - Use podiums/towers for ceiling work.
   - Manage awkward overhead postures with rotation.
   - Control dropped grid and tiles.
   - Beware existing openings.
   - Coordinate with services trades.

**TBT-DRY-007 · Tape & Joint Work**
Purpose: Repetitive finishing with dust and posture issues.
Key points:
   - Control sanding dust with extraction.
   - Manage posture and rotate.
   - Use suitable access.
   - Wear RPE for dry sanding.
   - Ventilate the area.

**TBT-DRY-008 · Drywall Cutting & Silica**
Purpose: Some boards and backing contain silica.
Key points:
   - Score and snap rather than power-cut where possible.
   - Use extraction when power-cutting.
   - Wear RPE.
   - Avoid dry-sweeping.
   - Ventilate.

**TBT-DRY-009 · Manual Handling of Plaster Bags**
Purpose: Heavy bags cause back injuries.
Key points:
   - Use mechanical aids or team lifts.
   - Lift with good technique.
   - Store bags safely.
   - Rotate tasks.
   - Keep routes clear.

**TBT-DRY-010 · Fire-Rated & Acoustic Systems**
Purpose: Compliance and detailing affect life-safety performance.
Key points:
   - Install to the tested system specification.
   - Use correct fixings and spacings.
   - Seal penetrations correctly.
   - Do not substitute materials.
   - Record and protect completed work.

**TBT-DRY-011 · Working at Height for Ceilings**
Purpose: Ceiling work is sustained overhead at height.
Key points:
   - Use stable platforms with guardrails.
   - Beware overreaching.
   - Rotate to manage neck/shoulder strain.
   - Control dropped objects.
   - Maintain tidy access.

**TBT-DRY-012 · Adhesives & Bonding Compounds**
Purpose: Dot-and-dab and adhesives bring COSHH and handling risks.
Key points:
   - Follow COSHH for adhesives.
   - Control mixing dust.
   - Protect skin and eyes.
   - Ventilate.
   - Handle heavy boards with aids.

**TBT-DRY-013 · External Render & EWI**
Purpose: External rendering at height with weather exposure.
Key points:
   - Use suitable access and stop in high winds.
   - Manage silica and cement hazards.
   - Protect skin from render.
   - Secure materials against wind.
   - Coordinate with scaffolders.

**TBT-DRY-014 · Sanding & RPE**
Purpose: Final sanding generates fine respirable dust.
Key points:
   - Always use extraction or wet sanding.
   - Wear face-fit-tested RPE.
   - Ventilate and isolate the area.
   - Clean with a vacuum.
   - Limit exposure time.

**TBT-DRY-015 · Coving & Decorative Work**
Purpose: Detailed overhead finishing.
Key points:
   - Use suitable access.
   - Manage adhesives and COSHH.
   - Handle long lengths with care.
   - Protect finished surfaces.
   - Rotate repetitive tasks.

**TBT-DRY-016 · Partition Demolition & Strip-Out**
Purpose: Removing old partitions exposes hidden hazards.
Key points:
   - Check for asbestos and services first.
   - Control dust during strip-out.
   - Manage sharp edges and fixings.
   - Provide safe waste routes.
   - Wear appropriate PPE.

**TBT-DRY-017 · Site Logistics & Material Storage**
Purpose: Boards and bags need safe storage.
Key points:
   - Store boards flat and secured against toppling.
   - Keep routes and exits clear.
   - Stack within safe heights.
   - Protect from damp.
   - Manage manual handling from storage.

**TBT-DRY-018 · Repetitive Strain Management**
Purpose: Drylining is physically repetitive overhead work.
Key points:
   - Rotate tasks and take breaks.
   - Use mechanical aids.
   - Warm up and stretch.
   - Set work at suitable heights.
   - Report strains early.

**TBT-DRY-019 · Render Pumps & Spray Application**
Purpose: Powered render application brings pressure and dust risks.
Key points:
   - Manage pump pressure and blockages.
   - Wear RPE and eye protection.
   - Control overspray.
   - Beware slips from spilled render.
   - Clean equipment safely.

**TBT-DRY-020 · Beading & Edge Trims**
Purpose: Sharp metal beads cause cuts.
Key points:
   - Wear cut-resistant gloves.
   - Handle long beads with care.
   - Cut and fix safely.
   - Store offcuts tidily.
   - Beware sharp edges at low level.

**TBT-DRY-021 · Board Lifters & Panel Hoists**
Purpose: Board lifters remove the worst of the manual handling but introduce crush and toppling risks.
Key points:
   - Use a board lifter for ceiling boarding as the default, not as a last resort.
   - Set up on firm, level ground and lock the wheels before loading.
   - Keep hands clear of the cradle, mast and winch mechanism during raising and lowering.
   - Never overload the lifter or use it to lift people or other materials.
   - Control the board when releasing it; an unrestrained board slides off fast.
   - Inspect the winch, cable and frame before use and report defects.

**TBT-DRY-022 · Firestopping & Service Penetrations**
Purpose: Linings form the fire compartments — a hole left unsealed defeats the whole system.
Key points:
   - Seal every penetration through a fire-rated lining with a tested, compatible system.
   - Do not cut new openings in fire-rated construction without authorisation.
   - Use the correct board type, thickness, layers and fixing centres for the rating.
   - Fill and tape joints as the tested system requires — a missed joint is a failed wall.
   - Photograph and record firestopping before it is covered up.
   - Report unsealed penetrations made by other trades rather than boarding over them.

**TBT-DRY-023 · Shaft Walls & Lift Shaft Linings**
Purpose: Lining a shaft means working on the edge of a full-height void.
Key points:
   - Protect the shaft opening at every level before work starts and never remove protection to gain access.
   - Use a designed access platform or shaft deck; never lean into the void from the floor edge.
   - Wear fall protection where collective protection cannot fully cover the edge.
   - Control dropped objects absolutely — anything dropped falls the whole height of the shaft.
   - Handle long boards with two people; they swing and catch easily in confined shafts.
   - Provide task lighting and keep the escape route clear.

**TBT-DRY-024 · Board Stacking & Leaning Board Collapse**
Purpose: Stacks of plasterboard have fallen and killed; a leaning stack topples without warning.
Key points:
   - Stack boards flat on bearers on a floor confirmed as able to carry the load.
   - Never lean boards free against a wall or stud partition.
   - Keep stacks away from walkways, doorways, escape routes and open edges.
   - Take boards from the top of the stack, never drag from the middle.
   - Watch for the stack sliding as boards are removed unevenly.
   - Distribute loads across the floor rather than concentrating packs in one place.

**TBT-DRY-025 · Encapsulation, Boxing In & Bulkheads**
Purpose: Boxing in puts operatives into awkward positions around live services and structure.
Key points:
   - Confirm services are isolated or protected before framing around them.
   - Maintain required access and inspection panels — do not box in valves, dampers or joints.
   - Check for asbestos before fixing into or encapsulating existing structure.
   - Use suitable access for high-level bulkheads rather than reaching from below.
   - Watch for sharp edges on metal framing and cut board.
   - Confirm fire and acoustic requirements for the enclosure before building it.

**TBT-DRY-026 · Wet Plastering & Skimming**
Purpose: Plastering is wet, overhead, repetitive work with real chemical and slip risks.
Key points:
   - Protect skin from plaster and cement; prolonged contact causes dermatitis and burns.
   - Wear eye protection when working overhead — plaster in the eye is alkaline and damaging.
   - Keep floors clear of spilled plaster and clean it before it sets.
   - Use hop-ups and podiums of the right height rather than over-reaching.
   - Rotate overhead work to manage shoulder and neck strain.
   - Wash thoroughly and apply after-work cream at the end of each shift.

**TBT-DRY-027 · Overhead Work — Neck & Shoulder Strain**
Purpose: Ceiling work sustained over years causes chronic shoulder, neck and back injury.
Key points:
   - Set the working platform height so the work is at or just above shoulder level, not above the head.
   - Rotate operatives between ceiling and wall tasks through the shift.
   - Use lifting aids and support props rather than holding boards up by hand.
   - Take short, frequent breaks rather than long continuous overhead periods.
   - Use lightweight and low-vibration tools for overhead work.
   - Report shoulder, neck or arm pain early rather than working through it.

**TBT-DRY-028 · Hop-Ups, Podiums & Access for Drylining**
Purpose: Most drylining falls are short falls from improvised access onto hard floors.
Key points:
   - Use purpose-made podiums and hop-ups; never stand on buckets, boards, stacks or radiators.
   - Check the access equipment is inspected, undamaged and set on level ground.
   - Keep guardrails and gates closed on podium steps.
   - Do not move a platform while standing on it.
   - Keep the platform clear of tools and offcuts to avoid trips at height.
   - Choose the height that avoids overreaching rather than stretching from a lower one.

**TBT-DRY-029 · Screw Guns & Collated Screw Systems**
Purpose: Repetitive screw fixing causes hand and wrist injury and drives screws into hidden services.
Key points:
   - Check for cables and pipes behind the board line before fixing.
   - Set the depth stop correctly to avoid over-driving and breaking the paper face.
   - Keep the non-working hand away from the screw path.
   - Use the collated extension for floor work rather than kneeling and reaching.
   - Manage vibration and repetitive strain with rotation and correct grip.
   - Isolate before clearing a jam in a collated magazine.

**TBT-DRY-030 · Cutting Boards — Knives & Blades**
Purpose: Board cutting is the single most frequent cause of cuts in drylining.
Key points:
   - Use a retractable or safety knife and keep the blade sharp.
   - Score away from the body and never towards the supporting hand.
   - Retract the blade immediately after every cut, including when moving between boards.
   - Support the board properly so it does not move mid-cut.
   - Wear cut-resistant gloves and dispose of blades in a sharps container.
   - Snap boards away from you and control the offcut as it falls.

**TBT-DRY-031 · Mineral Fibre & Acoustic Insulation Handling**
Purpose: Mineral wool irritates skin, eyes and airways, particularly when installed overhead.
Key points:
   - Wear coveralls with cuffs closed, gloves, eye protection and RPE when handling insulation.
   - Cut insulation with a knife or saw rather than tearing it to reduce fibre release.
   - Ventilate the area and avoid working in enclosed spaces without air movement.
   - Do not use compressed air to clean clothing or skin.
   - Wash in cool water first to close pores, and change clothing before travelling home.
   - Bag offcuts immediately rather than leaving them to be walked through.

**TBT-DRY-032 · Working Near Electrical & Mechanical Services**
Purpose: Drylining closes walls and ceilings around live services that cannot be seen once boarded.
Key points:
   - Scan or check drawings before drilling, screwing or fixing track.
   - Assume cables in existing walls are live and in unpredictable positions.
   - Do not compress or damage cables and pipes when packing out or insulating.
   - Leave the required access panels and do not board over isolation valves or junction boxes.
   - Report any damage to a service immediately, even if it appears superficial.
   - Coordinate with M&E before closing up so first fix is signed off.

**TBT-DRY-033 · Lime Plaster & Heritage Plastering**
Purpose: Lime is more caustic than gypsum and heritage buildings hold unexpected hazards.
Key points:
   - Treat lime as corrosive: goggles, gauntlets and full skin cover when mixing and applying.
   - Never allow lime to sit inside gloves, boots or clothing.
   - Irrigate eye contact for at least 20 minutes and get medical attention.
   - Check for asbestos, lead paint and animal hair binders before stripping old plaster.
   - Assess the stability of laths, ceilings and substrates before working beneath them.
   - Control dust from stripping with suppression and RPE.

**TBT-DRY-034 · Bagged Materials & Silo Deliveries**
Purpose: Bagged plaster is heavy and dusty and silos bring pressure, height and delivery vehicles.
Key points:
   - Use trolleys and mechanical aids; 25kg bags handled all day cause back injuries.
   - Cut bags cleanly and tip at low level to reduce dust release.
   - Site silos on a designed base with the required clearances from overhead lines and traffic.
   - Keep clear during silo filling — blow-back and dust release are hazards.
   - Never climb on or under a silo, and check the safety devices are in place.
   - Wear RPE and eye protection when mixing and store bags out of the weather.

**TBT-DRY-035 · Access Panels & Openings in Linings**
Purpose: Every opening formed in a lining is a hazard until it is made safe.
Key points:
   - Check what is behind before cutting any opening — services, voids, shafts or other trades.
   - Guard openings in ceilings and walls immediately after forming them.
   - Never cut openings in fire-rated linings without an approved, rated access panel.
   - Keep cut-outs and offcuts collected rather than dropped into voids.
   - Verify the panel rating matches the wall or ceiling it sits in.
   - Record fire-rated panel installations for the building safety information.

**TBT-DRY-036 · Working in Corridors & Escape Routes**
Purpose: Corridors are both the work area and the escape route for everyone else on the floor.
Key points:
   - Never fully block a corridor; maintain a clear route past the works at all times.
   - Keep board stacks, trestles and lifters to one side and clearly marked.
   - Do not obstruct or disable fire doors, call points or exit signage.
   - Light the route properly when working with temporary lighting.
   - Clear the corridor completely at the end of every shift.
   - Coordinate with other trades so two jobs do not close the route between them.

**TBT-DRY-037 · Drying Out & Temporary Heating**
Purpose: Drying out combines fire risk, fumes and humidity in an enclosed building.
Key points:
   - Use approved heater types and keep the specified clearance from combustibles and sheeting.
   - Never use LPG heaters in enclosed or poorly ventilated areas without CO monitoring.
   - Ventilate to remove moisture rather than sealing the building up.
   - Secure heaters and dehumidifiers against being knocked and route cables safely.
   - Turn heaters off at the end of the shift unless a fire watch is in place.
   - Watch for condensation creating slip hazards on floors and stairs.

**TBT-DRY-038 · Mechanical Fixings into Concrete & Steel**
Purpose: Fixing into hard substrates brings silica dust, hand-arm vibration and structural risk.
Key points:
   - Check the substrate and fixing type against the design before drilling.
   - Scan for reinforcement, post-tensioning and services before any drilling into structure.
   - Use on-tool extraction and FFP3 RPE for all drilling into concrete and masonry.
   - Manage hand-arm vibration with trigger-time limits, sharp bits and rotation.
   - Never fire cartridge tools without training, authorisation and area control.
   - Achieve the specified embedment depth and torque; under-fixed track fails later.

**TBT-DRY-039 · Waste Board Disposal & Housekeeping**
Purpose: Plasterboard waste must be segregated by law and creates dust, trips and fire load if left.
Key points:
   - Segregate plasterboard from general waste — gypsum must not go to general landfill.
   - Clear offcuts to the skip as you go rather than at the end of the day.
   - Keep waste out of corridors, stairs, escape routes and behind doors.
   - Bag dusty waste to prevent re-release when it is moved.
   - Do not overfill skips or allow board to overhang.
   - Sweep with an M-class vacuum, never a brush.

**TBT-DRY-040 · Laser Levels & Setting Out**
Purpose: Lasers speed up setting out but can damage eyes when set at head height.
Key points:
   - Use the lowest laser class suitable for the job and check the class marking.
   - Position the beam above or below eye level and never point it at another person.
   - Post warning signage and tell adjacent trades a laser is in use.
   - Never view the beam with optical aids and avoid reflective surfaces in the path.
   - Secure the tripod so it cannot be knocked into a walkway or off a platform.
   - Switch off and cover the instrument when not in use.

### 4.10 Painting & Decorating (`painting`)

**TBT-PNT-001 · Solvents & Isocyanates (COSHH)**
Purpose: Paints and coatings emit harmful, sometimes sensitising, vapours.
Key points:
   - Check the SDS and COSHH assessment.
   - Ventilate the work area.
   - Use appropriate RPE, especially for 2-pack/isocyanate products.
   - Protect skin and eyes.
   - Eliminate ignition sources.

**TBT-PNT-002 · Access for Decorating**
Purpose: Decorating is sustained low- and high-level access work.
Key points:
   - Use podiums and towers, not overreaching from ladders.
   - Keep footing stable.
   - Maintain tidy access.
   - Beware wet, slippery surfaces.
   - Coordinate with other trades.

**TBT-PNT-003 · Spray Painting**
Purpose: Spraying creates flammable mists and inhalation risk.
Key points:
   - Control overspray and ventilate.
   - Use the correct RPE for spraying.
   - Manage flammable atmospheres and ignition.
   - Mask and protect adjacent areas.
   - Follow COSHH and manufacturer guidance.

**TBT-PNT-004 · Surface Prep, Sanding & Lead Paint**
Purpose: Pre-1980 paint may contain lead; sanding creates hazardous dust.
Key points:
   - Assume pre-1980 coatings may contain lead.
   - Do not dry-sand suspect coatings.
   - Use dust control and RPE.
   - Maintain hygiene and wash before eating.
   - Dispose of waste correctly.

**TBT-PNT-005 · Working at Height for Decorators**
Purpose: High-level painting needs safe access.
Key points:
   - Use towers/MEWPs for high work.
   - Stop external work in high winds.
   - Beware overreaching.
   - Control dropped tools and tins.
   - Coordinate with scaffolders.

**TBT-PNT-006 · Manual Handling of Paint & Materials**
Purpose: Tins, drums and equipment cause back and handling strain.
Key points:
   - Use mechanical aids for drums.
   - Decant into smaller containers.
   - Lift with good technique.
   - Store materials safely.
   - Keep routes clear.

**TBT-PNT-007 · Flammable Materials Storage**
Purpose: Paints and thinners are fire hazards.
Key points:
   - Store in designated, ventilated areas.
   - Keep away from ignition and heat.
   - Control quantities on site.
   - Manage waste and rags (spontaneous combustion).
   - Keep extinguishers nearby.

**TBT-PNT-008 · Dust & Decorating in Occupied Areas**
Purpose: Working around occupants needs extra control.
Key points:
   - Segregate and protect occupied areas.
   - Control dust and fumes.
   - Maintain escape routes.
   - Use low-odour products where possible.
   - Communicate with occupants.

**TBT-PNT-009 · Wallpapering & Adhesives**
Purpose: Pastes and steam strippers bring slip, electrical and COSHH risks.
Key points:
   - Manage water and slips with steam strippers.
   - Beware electrical risk near wet surfaces.
   - Ventilate when using adhesives.
   - Use suitable access.
   - Follow COSHH.

**TBT-PNT-010 · External Decorating & Weather**
Purpose: Outdoor work exposed to weather and height.
Key points:
   - Stop work in high winds and rain.
   - Use suitable access.
   - Protect against UV and sun.
   - Secure materials against wind.
   - Beware fragile surfaces.

**TBT-PNT-011 · Floor Coatings & Resins**
Purpose: Resin floor coatings are hazardous and slippery when wet.
Key points:
   - Follow COSHH for resins and hardeners.
   - Ventilate enclosed areas.
   - Manage slips on wet coatings.
   - Protect skin and eyes.
   - Control ignition sources.

**TBT-PNT-012 · Intumescent & Fire Coatings**
Purpose: Specialist coatings with compliance and COSHH needs.
Key points:
   - Apply to the specified thickness/system.
   - Follow COSHH for the products.
   - Ventilate and use RPE.
   - Record coverage and DFT.
   - Do not substitute products.

**TBT-PNT-013 · Sanding Machines & Dust**
Purpose: Powered sanders generate fine dust.
Key points:
   - Use extraction with sanders.
   - Wear RPE.
   - Ventilate and isolate the area.
   - Vacuum, don't sweep.
   - Limit exposure.

**TBT-PNT-014 · Working with Strong Cleaners & Strippers**
Purpose: Chemical strippers and cleaners are corrosive.
Key points:
   - Follow COSHH and wear PPE.
   - Ventilate and avoid skin/eye contact.
   - Beware fumes in enclosed spaces.
   - Store and dispose correctly.
   - Have eyewash available.

**TBT-PNT-015 · Hand Tools for Decorators**
Purpose: Scrapers and knives cause cuts.
Key points:
   - Cut and scrape away from the body.
   - Keep blades controlled and stored.
   - Inspect tools.
   - Wear gloves where suitable.
   - Dispose of blades safely.

**TBT-PNT-016 · Lone & Out-of-Hours Decorating**
Purpose: Decorators often work alone or out of hours.
Key points:
   - Follow lone-working procedures.
   - Maintain check-ins.
   - Ensure ventilation when alone with solvents.
   - Know emergency arrangements.
   - Avoid high-risk tasks alone.

**TBT-PNT-017 · Protecting & Masking**
Purpose: Masking materials create trip and fire considerations.
Key points:
   - Keep masking clear of escape routes.
   - Control trip hazards from sheeting.
   - Beware flammable masking near hot works.
   - Remove redundant protection.
   - Maintain housekeeping.

**TBT-PNT-018 · Skin Care & Dermatitis**
Purpose: Frequent contact with paints and solvents harms skin.
Key points:
   - Wear gloves and use barrier creams.
   - Wash and moisturise hands.
   - Avoid solvent skin cleaning.
   - Check skin regularly.
   - Report dermatitis early.

**TBT-PNT-019 · Airless Spray Equipment**
Purpose: Airless sprayers inject paint under extreme pressure — injection injuries are serious.
Key points:
   - Never point the gun at anyone — injection injuries need urgent surgery.
   - Engage the trigger lock when not spraying.
   - Relieve pressure before maintenance.
   - Wear PPE and ventilate.
   - Only trained operators.

**TBT-PNT-020 · Ladder Use for Decorators**
Purpose: Short-duration ladder work still causes falls.
Key points:
   - Use ladders only for short, light tasks.
   - Maintain three points of contact.
   - Secure or foot the ladder.
   - Avoid overreaching.
   - Consider podiums instead.

**TBT-PNT-021 · Confined Space Painting & Ventilation**
Purpose: Solvent vapour is heavier than air, displaces oxygen and forms an explosive atmosphere in enclosed spaces.
Key points:
   - Treat tanks, ducts, pits and unventilated rooms as confined spaces and permit the work.
   - Provide forced ventilation and continuous atmosphere monitoring throughout.
   - Use air-fed breathing apparatus where solvent concentrations cannot be controlled.
   - Eliminate all ignition sources — use intrinsically safe lighting and equipment.
   - Never work alone; have a standby person and a rescue plan at the entry point.
   - Limit exposure time and rotate operatives out of the space.

**TBT-PNT-022 · Two-Pack & Epoxy Coatings**
Purpose: Two-pack products contain isocyanates and hardeners that cause occupational asthma and severe sensitisation.
Key points:
   - Read the COSHH assessment and safety data sheet for both components before opening them.
   - Once sensitised to isocyanates, even tiny future exposures cause reactions — prevention is the only control.
   - Use air-fed RPE for spraying and face-fit tested RPE for brush and roller application.
   - Wear chemical-resistant gloves and protect all exposed skin.
   - Mix only in a well-ventilated area and never mix more than will be used.
   - Attend health surveillance and report breathlessness, wheezing or chest tightness.

**TBT-PNT-023 · Shot Blasting & Abrasive Surface Prep**
Purpose: Blasting generates extreme dust, noise and projectile energy.
Key points:
   - Never use silica sand as an abrasive — use approved low-silica media.
   - Fully enclose or screen the blasting area and exclude everyone not involved.
   - Use air-fed blast helmets, not filter masks, and protective clothing.
   - Check hoses, couplings and deadman controls before every use; a whipping hose kills.
   - Beware of lead and other hazardous coatings being removed from the substrate.
   - Manage noise exposure and monitor the surrounding area for dust escape.

**TBT-PNT-024 · Working in Stairwells & Atriums**
Purpose: Stairwells combine the fall risk of an open void with the difficulty of setting up access.
Key points:
   - Use a purpose-built stairwell tower or platform, never ladders spanning flights.
   - Protect the void and stair edges before setting up and keep protection in place.
   - Check the floor and stair loading before positioning towers and staging.
   - Keep the stair usable as an escape route or agree an alternative with the site team.
   - Control dropped tools and materials — they fall the full height of the well.
   - Provide adequate lighting; stairwells are often the darkest part of the building.

**TBT-PNT-025 · Mobile Towers for Decorators**
Purpose: Decorators use towers constantly and move them constantly, which is where falls happen.
Key points:
   - Only PASMA-trained operatives may erect, alter or dismantle a tower.
   - Build to the manufacturer's instruction manual including all braces and stabilisers.
   - Never move a tower with a person, tools or materials on it.
   - Lock the castors on level ground and check the tower is plumb before climbing.
   - Access the platform through the internal trapdoor, never by climbing the outside.
   - Inspect the tower before each use and after any alteration or event.

**TBT-PNT-026 · Anti-Graffiti & Specialist Coatings**
Purpose: Specialist coatings often contain strong solvents and require higher application temperatures.
Key points:
   - Check the safety data sheet — specialist products are rarely water-based.
   - Ventilate thoroughly and use the specified RPE, gloves and eye protection.
   - Control overspray and drift onto vehicles, the public and adjacent property.
   - Beware flammability and keep ignition sources away from application and drying areas.
   - Store and dispose of these products as hazardous waste.
   - Allow the specified cure time and keep the area controlled while it cures.

**TBT-PNT-027 · Line Marking & Road Paints**
Purpose: Line marking is done next to live traffic with hot or solvent-based materials.
Key points:
   - Set out traffic management to the approved layout before any work starts.
   - Wear the correct class of high-visibility clothing and never work with your back to traffic.
   - Treat thermoplastic as a burn hazard — it is applied hot and sticks to skin.
   - Use the specified RPE for solvent and MMA-based products.
   - Keep the public and other operatives clear of wet markings and hot equipment.
   - Control fuel, gas bottles and burners used with thermoplastic equipment.

**TBT-PNT-028 · Paint Waste & Environmental Disposal**
Purpose: Paint, solvents and washings are hazardous waste and must never reach a drain.
Key points:
   - Never wash brushes, rollers or spray equipment into drains, gullies or watercourses.
   - Use a designated washout area with containment and dispose of washings properly.
   - Keep solvent, paint and water-based waste segregated and labelled.
   - Store waste containers closed, bunded and away from ignition sources.
   - Use consignment notes where required and keep the records.
   - Report any spill immediately and use the spill kit before it spreads.

**TBT-PNT-029 · Steel Painting & Corrosion Protection**
Purpose: Painting structural steel means working at height around sharp edges with high-solvent products.
Key points:
   - Plan access for the whole element — steel is awkward to reach safely.
   - Beware of existing coatings containing lead, chromate or isocyanates when preparing.
   - Use the RPE specified for both the preparation and the coating stages.
   - Watch for sharp edges, bolt heads and trip hazards on steelwork.
   - Control overspray and drips onto areas and equipment below.
   - Apply within the specified temperature and humidity range or the coating will fail.

**TBT-PNT-030 · Silica & Cement Dust in Prep Work**
Purpose: Preparing masonry, render and concrete before decorating releases respirable crystalline silica.
Key points:
   - Use on-tool extraction or water suppression for all grinding, sanding and raking out.
   - Never dry-sand or grind masonry without control measures.
   - Wear FFP3 RPE that has been face-fit tested, plus eye protection.
   - Clean up with an M-class vacuum, never a brush or compressed air.
   - Warn and screen off adjacent trades from the dust.
   - Rotate tasks to reduce individual exposure time.

**TBT-PNT-031 · Working from Cradles & Rope Access**
Purpose: Suspended access puts decorators over a drop with weather and equipment failure risk.
Key points:
   - Only trained and certificated operatives may use cradles or rope access systems.
   - Check the thorough examination certificate and carry out a pre-use inspection.
   - Attach to an independent fall arrest line as well as the working platform.
   - Never exceed the rated load or ride a cradle with excess materials.
   - Stop work and descend when wind speeds exceed the operating limit.
   - Have the rescue plan and equipment in place before anyone goes over the edge.

**TBT-PNT-032 · Heat Guns & Hot Air Strippers**
Purpose: Hot air strippers reach temperatures that ignite timber and dust and release lead fume.
Key points:
   - Obtain a hot works permit where the site requires one and maintain a fire watch.
   - Never use a heat gun on paint that may contain lead — heat releases toxic fume.
   - Keep the gun moving and away from voids where hot air can ignite concealed dust and debris.
   - Never put a hot gun down on a combustible surface; use the stand.
   - Ventilate and wear RPE appropriate to the fumes produced.
   - Check the area for smouldering before leaving and again an hour later.

**TBT-PNT-033 · Wet Edges, Wet Floors & Slips**
Purpose: Freshly coated floors and spilled paint create some of the most slippery surfaces on site.
Key points:
   - Barrier and sign wet floor coatings and control access until fully cured.
   - Clean spills immediately — paint on a smooth floor is treacherous.
   - Plan the application sequence so nobody has to walk over wet work.
   - Watch for wet paint transferring to boot soles and being carried onto stairs.
   - Keep dust sheets flat and taped; rucked sheets are a major trip hazard.
   - Remove and dispose of contaminated sheets rather than reusing them.

**TBT-PNT-034 · Task Lighting & Temporary Power for Decorators**
Purpose: Decorators work in unlit shells and rely on temporary lighting and leads that create their own hazards.
Key points:
   - Use 110V or battery lighting with RCD protection and keep leads off the floor.
   - Position lights to avoid glare and shadow where the work is judged by eye.
   - Never use halogen lamps near sheeting, paper or solvent vapour.
   - Use intrinsically safe lighting where flammable vapours are present.
   - Keep leads out of wet areas and away from spray and washing zones.
   - Check leads and fittings daily and remove damaged equipment.

**TBT-PNT-035 · Asbestos in Textured Coatings**
Purpose: Textured coatings applied before 2000 frequently contain asbestos, and sanding releases fibres.
Key points:
   - Never sand, scrape or dry-remove a textured coating without checking the asbestos survey.
   - Stop work immediately and report if you disturb a suspect coating.
   - Treat any pre-2000 textured ceiling or wall coating as suspect until tested.
   - Removal requires a trained contractor with the correct controls, even for non-licensed work.
   - Overcoating may be acceptable, but only with the correct assessment and method.
   - Decontaminate and report if you believe you have been exposed.

**TBT-PNT-036 · Mould, Damp & Biocidal Washes**
Purpose: Mould spores and the chemicals used to kill them both affect the airways.
Key points:
   - Identify the cause of the damp before decorating; painting over it solves nothing.
   - Wear RPE, gloves and eye protection when disturbing mould growth.
   - Ventilate and avoid dry brushing that puts spores into the air.
   - Never mix biocidal washes with other cleaning chemicals, especially bleach and acids.
   - Follow the contact time and dilution on the product label.
   - Be aware of the health risk to occupants and report severe damp to the site team.

**TBT-PNT-037 · Respiratory Protection & Face Fit for Sprayers**
Purpose: RPE that does not seal gives no protection at all, whatever it costs.
Key points:
   - Every tight-fitting mask must be face-fit tested to the individual wearing it.
   - Be clean shaven where the mask seals — stubble breaks the seal completely.
   - Carry out a fit check every time you put the mask on.
   - Use air-fed RPE for two-pack and isocyanate spraying; filters are not sufficient.
   - Store RPE clean, dry and protected, and change filters to schedule.
   - Report damaged masks and never share a mask between operatives.

**TBT-PNT-038 · Scaffolding & Sheeting for Decorators**
Purpose: Decorators work from scaffolds sheeted for weather protection, which changes how the scaffold behaves.
Key points:
   - Never alter, remove or cut sheeting or netting to improve access or light.
   - Check the scaffold tag before use; do not use an untagged or red-tagged scaffold.
   - Be aware that sheeting increases wind load — report any movement or flapping.
   - Keep materials and equipment within the scaffold's duty class.
   - Watch for condensation and solvent vapour building up inside sheeted areas.
   - Ventilate sheeted work areas when using solvent-based products.

**TBT-PNT-039 · Vehicle Loading & Transporting Paint**
Purpose: Paint and solvents in a van are a fire risk and a load that shifts.
Key points:
   - Secure all containers so they cannot topple or slide in transit.
   - Keep lids tight and store solvents upright; check quantities against carriage limits.
   - Never carry open containers or store solvents in the cab.
   - Ventilate the van before entering after transporting solvent products.
   - Keep no ignition sources in the load area and carry a suitable extinguisher.
   - Unload with mechanical aids and avoid carrying multiple tins in one hand.

**TBT-PNT-040 · Working Near the Public — Overspray & Drift**
Purpose: Overspray travels far further than expected and damages vehicles, property and people.
Key points:
   - Assess wind direction and speed before spraying and stop when drift cannot be controlled.
   - Screen and mask the work area fully and extend the exclusion zone downwind.
   - Give notice to neighbours and move or cover vehicles before starting.
   - Consider brush or roller application where the public cannot be excluded.
   - Barrier pavements and provide a safe route past the works.
   - Stop immediately if members of the public enter the spray zone.

### 4.11 Roofing (`roofing`)

**TBT-ROO-001 · Roof Edge Protection & Fragile Surfaces**
Purpose: Roof falls and fragile-surface failures are frequently fatal.
Key points:
   - Provide edge protection or guardrails.
   - Identify and cover fragile surfaces and rooflights.
   - Use nets or airbags as collective protection.
   - Use a harness to an anchor where needed.
   - Observe weather limits.

**TBT-ROO-002 · Hot Works on Roofs (Torch-On)**
Purpose: Torch-on systems are a major cause of roof fires.
Key points:
   - Obtain a hot works permit.
   - Use gas safely and store cylinders correctly.
   - Maintain a fire watch during and after.
   - Keep extinguishers to hand.
   - Separate work from combustibles.

**TBT-ROO-003 · Material Handling to Roof Level**
Purpose: Getting materials up safely.
Key points:
   - Use hoists or telehandlers, not manual carrying up ladders.
   - Control dropped objects with exclusion zones.
   - Handle long/heavy materials with teams.
   - Beware weather affecting lifts.
   - Stack safely on the roof.

**TBT-ROO-004 · Working on Pitched Roofs**
Purpose: Pitch increases fall and slip risk.
Key points:
   - Use roof ladders and crawl boards.
   - Use harnesses and anchors.
   - Stop work in poor weather.
   - Provide safe access to the roof.
   - Beware fragile or mossy surfaces.

**TBT-ROO-005 · Flat Roof Work**
Purpose: Open flat roofs have unprotected edges.
Key points:
   - Provide edge protection to all open edges.
   - Protect rooflights and openings.
   - Manage materials and trip hazards.
   - Beware standing water and slips.
   - Control access to the roof.

**TBT-ROO-006 · Working Near Skylights & Rooflights**
Purpose: Rooflights are often fragile and easily missed.
Key points:
   - Cover or barrier all rooflights.
   - Never step on rooflights.
   - Mark and sign fragile areas.
   - Use nets below where appropriate.
   - Maintain protection throughout.

**TBT-ROO-007 · Weather & Wind on Roofs**
Purpose: Wind and weather dramatically increase roof risk.
Key points:
   - Stop work in high winds.
   - Secure loose materials and sheets.
   - Beware wet, icy or mossy surfaces.
   - Monitor the forecast.
   - Re-inspect after storms.

**TBT-ROO-008 · Bitumen Boilers & Hot Bitumen**
Purpose: Hot bitumen causes severe burns and fire.
Key points:
   - Site boilers safely away from combustibles.
   - Wear heat-resistant PPE.
   - Manage hot bitumen handling and transport.
   - Maintain a fire watch.
   - Beware fumes — ventilate.

**TBT-ROO-009 · Manual Handling of Roofing Materials**
Purpose: Tiles, membranes and sheets are heavy and awkward.
Key points:
   - Use mechanical aids and team lifts.
   - Beware sharp edges on metal sheets.
   - Plan lifting routes.
   - Rotate repetitive tasks.
   - Stack safely against wind.

**TBT-ROO-010 · Roof Access & Ladders**
Purpose: Getting on and off the roof safely.
Key points:
   - Secure and tie off access ladders.
   - Maintain three points of contact.
   - Use landing platforms where possible.
   - Keep access points clear.
   - Inspect ladders before use.

**TBT-ROO-011 · Slating & Tiling at Height**
Purpose: Repetitive height work with dropped-object risk.
Key points:
   - Control dropped tiles and tools.
   - Use edge protection.
   - Manage posture and rotation.
   - Cut tiles with dust control.
   - Beware fragile areas.

**TBT-ROO-012 · Sheet Metal & Cladding**
Purpose: Sharp, large sheets with wind and cut hazards.
Key points:
   - Wear cut-resistant gloves.
   - Control sheets in wind.
   - Use mechanical handling for large sheets.
   - Beware sharp edges and swarf.
   - Provide edge protection.

**TBT-ROO-013 · Liquid Roofing Systems & COSHH**
Purpose: Liquid systems involve hazardous chemicals.
Key points:
   - Follow COSHH for resins and primers.
   - Ventilate and use RPE.
   - Manage slips on wet coatings.
   - Control ignition sources.
   - Protect skin and eyes.

**TBT-ROO-014 · Rope Access & Specialist Work**
Purpose: Specialist access needs specific competence.
Key points:
   - Only IRATA/competent persons use rope access.
   - Inspect equipment before use.
   - Have rescue arrangements.
   - Establish exclusion zones below.
   - Follow the access plan.

**TBT-ROO-015 · Lightning Protection & Metalwork**
Purpose: Working with conductive metalwork at height.
Key points:
   - Beware overhead lines and lightning risk.
   - Stop work in electrical storms.
   - Handle long metal lengths safely.
   - Use suitable access.
   - Control dropped objects.

**TBT-ROO-016 · Solar PV on Roofs**
Purpose: Combines roof, electrical and handling risks.
Key points:
   - Provide roof edge protection.
   - Beware live DC in daylight.
   - Handle panels with teams.
   - Control dropped objects.
   - Coordinate roof and electrical works.

**TBT-ROO-017 · Gutters, Fascias & Soffits at Height**
Purpose: Edge work with access and weather exposure.
Key points:
   - Use suitable access — tower or MEWP.
   - Stop in high winds.
   - Control dropped objects.
   - Handle long lengths with two people.
   - Beware fragile roof edges.

**TBT-ROO-018 · Roof Inspections & Surveys**
Purpose: Surveyors access roofs with full fall risk.
Key points:
   - Plan safe access before going on the roof.
   - Use fall protection.
   - Beware fragile surfaces.
   - Never survey alone without arrangements.
   - Stop in poor weather.

**TBT-ROO-019 · Roof Edge Loading & Storage**
Purpose: Storing materials at roof edges risks overload and falls.
Key points:
   - Keep materials back from edges.
   - Distribute loads to avoid overstress.
   - Secure against wind.
   - Maintain edge protection.
   - Control dropped objects.

**TBT-ROO-020 · Working Around Roof Plant**
Purpose: Rooftop plant adds electrical and access hazards.
Key points:
   - Beware live rooftop plant and services.
   - Maintain access around plant.
   - Isolate where working on plant.
   - Provide edge protection.
   - Coordinate with M&E trades.

**TBT-ROO-021 · Man-Safe Systems & Anchor Points**
Purpose: A fall arrest system is only as good as the anchor, and many roof anchors have never been tested.
Key points:
   - Check the anchor or line has a current test and inspection certificate before clipping on.
   - Confirm the anchor is rated for the number of users and the direction of loading.
   - Use restraint where possible so a fall cannot occur, rather than relying on arrest.
   - Calculate the clearance below and beware of pendulum swing toward edges and openings.
   - Inspect harness, lanyard and connectors before every use.
   - Have a rescue plan and the equipment on the roof before anyone attaches.

**TBT-ROO-022 · Single Ply Membrane Installation**
Purpose: Single ply work involves hot air welding, large loose sheets and slippery membranes.
Key points:
   - Check whether hot air welding requires a hot works permit on this site.
   - Keep the welding gun in its stand and never lay it on the membrane or insulation.
   - Control sheets in wind — an unrestrained membrane can lift an operative off their feet.
   - Beware of the slip risk on wet or frosty membrane, especially near edges.
   - Maintain edge protection at all times during laying and welding.
   - Weight and secure loose material at the end of every shift.

**TBT-ROO-023 · Green & Blue Roof Systems**
Purpose: Green and blue roofs bring heavy loads, standing water and maintenance access risks.
Key points:
   - Confirm the roof loading capacity before landing substrate, ballast or water.
   - Plan the lift and distribution of bulk materials; do not concentrate loads in one area.
   - Beware of the slip and trip risk on uneven substrate and vegetation.
   - Maintain edge protection — planted roofs hide the edge and change the perceived boundary.
   - Treat standing water on blue roofs as a drowning and slip hazard, especially for lone workers.
   - Manage biological hazards in soil and compost: cover cuts and wash hands.

**TBT-ROO-024 · Roof Ladders & Crawling Boards**
Purpose: Roof ladders spread load on a surface that will not take a person's weight directly.
Key points:
   - Use a properly hooked roof ladder that bears on the ridge, not on the tiles or gutter.
   - Never rely on a roof ladder as the only fall protection — edge protection is still required.
   - Check the ridge, tiles and battens are sound enough to take the ladder.
   - Use crawling boards on fragile surfaces and never step off them.
   - Secure ladders against sliding and displacement in wind.
   - Inspect roof ladders before every use and withdraw damaged ones.

**TBT-ROO-025 · Asbestos Cement Roof Sheets**
Purpose: Asbestos cement sheets are both a fragile surface and an asbestos-containing material.
Key points:
   - Treat all cement roof sheets on pre-2000 buildings as asbestos-containing until proven otherwise.
   - Never walk on asbestos cement sheets — they are fragile and have caused many fatalities.
   - Use crawling boards, staging and edge protection with a full access plan.
   - Do not break, drill, cut or power-wash the sheets; removal must be controlled.
   - Stop work and report immediately if sheets are broken or damaged.
   - Follow decontamination procedures if you suspect exposure.

**TBT-ROO-026 · Cut Roofs, Rafters & Open Structures**
Purpose: An open roof structure is all edges and holes with nothing to stand on.
Key points:
   - Install safety netting or a proprietary fall protection system before working on open rafters.
   - Never walk or balance on rafters, purlins or wall plates.
   - Provide a boarded working platform or use a MEWP where the structure allows.
   - Brace and restrain new roof structure as it is erected.
   - Protect the area below against dropped tools, timber and fixings.
   - Stop work in high winds when handling roof timbers.

**TBT-ROO-027 · Leadwork & Lead Welding**
Purpose: Lead welding is hot work on a roof with molten metal and fume at close range.
Key points:
   - Obtain a hot works permit and maintain a fire watch during and after the work.
   - Remove or protect combustibles, especially old roof timbers and bird nesting material.
   - Use oxy-acetylene equipment correctly with flashback arrestors and secure bottles.
   - Wear eye protection suited to the process and heat-resistant gloves.
   - Ventilate the position and keep your head out of the fume plume.
   - Allow lead to cool before handling and never leave hot material unattended.

**TBT-ROO-028 · Lead Exposure, Hygiene & Health Surveillance**
Purpose: Lead is absorbed by ingestion and fume inhalation and accumulates in the body.
Key points:
   - Never eat, drink or smoke where lead is handled, and wash hands thoroughly before breaks.
   - Avoid generating fume, dust and swarf; hot-cut only with ventilation and RPE.
   - Keep work clothing separate from personal clothing and do not take it home to wash.
   - Attend health surveillance and blood monitoring where the work requires it.
   - Be aware of the specific risk to pregnant workers and young persons.
   - Collect and store lead offcuts securely — they are valuable and a theft target.

**TBT-ROO-029 · Roof Strip & Tear-Off**
Purpose: Stripping a roof removes the structure's protection and fills the area with falling debris.
Key points:
   - Establish edge protection and exclusion zones below before stripping starts.
   - Use a chute or hoist; never throw material off the roof.
   - Check the structure's stability as loads are removed and the roof is opened up.
   - Watch for hidden hazards — asbestos, bird guano, live services and rotten timber.
   - Strip only the area that can be made weathertight before the end of the shift.
   - Control dust and clear debris promptly to keep the working surface safe.

**TBT-ROO-030 · Safety Nets & Soft Landing Systems**
Purpose: Nets provide collective protection but only when rigged and maintained by competent riggers.
Key points:
   - Only trained net riggers may install, alter or remove safety netting.
   - Check the net has a current test tag and inspect for damage and debris before working above it.
   - Ensure the net is rigged as close beneath the work as possible to limit fall distance.
   - Check the clearance below the net so a falling person does not strike the floor.
   - Never use a net as a working platform or store materials on it.
   - Report any fall into or damage to a net immediately — it must be inspected before reuse.

**TBT-ROO-031 · Scaffold Interface for Roofers**
Purpose: Roofers rely on the scaffold being right for roof work, not just for the walls.
Key points:
   - Check the scaffold tag and that the top lift is set at the correct height for the roof.
   - Ensure guardrails are at the right height above the eaves for the work being done.
   - Never alter, remove or step over scaffold components to reach the roof.
   - Confirm the scaffold's duty class allows the materials you intend to load.
   - Report gaps between the scaffold and the building at eaves level.
   - Request a scaffold alteration through the scaffold contractor rather than adapting it.

**TBT-ROO-032 · Roof Deliveries & Telehandler Placement**
Purpose: Landing heavy packs on a roof or scaffold can overload both the structure and the people below.
Key points:
   - Confirm the roof or platform can carry the load and where it may be placed.
   - Agree the lift sequence and signals with the operator before it starts.
   - Never stand beneath a suspended load or guide it by hand — use tag lines.
   - Distribute packs rather than concentrating them in one position.
   - Secure and band materials against wind as soon as they are landed.
   - Check ground conditions and overhead lines at the telehandler position.

**TBT-ROO-033 · Cold-Applied & Self-Adhesive Systems**
Purpose: Cold-applied systems avoid naked flame but bring solvent and adhesive exposure.
Key points:
   - Read the safety data sheet — many primers and adhesives are highly flammable.
   - Ventilate the work area and keep ignition sources well away.
   - Wear the specified gloves, RPE and eye protection for the product.
   - Beware the slip risk of release films and offcuts on the roof surface.
   - Collect and bag release paper immediately; it blows away and is very slippery.
   - Store containers closed, upright and out of direct sun.

**TBT-ROO-034 · Insulation Boards & Wind Uplift**
Purpose: Insulation boards are large, light and act as sails, pulling operatives towards the edge.
Key points:
   - Stop handling boards when the wind exceeds the limit in the method statement.
   - Never carry a board single-handed in wind or near an unprotected edge.
   - Weight or mechanically fix boards as they are laid; do not leave loose boards on the roof.
   - Band and weight stacks and check them after every period of high wind.
   - Beware of walking on unfixed boards — they slide on the vapour barrier.
   - Keep the edge protection intact and stand inside it when handling boards.

**TBT-ROO-035 · Valleys, Hips & Ridge Work**
Purpose: Detail work puts roofers in the most awkward and exposed positions on the roof.
Key points:
   - Plan access to detail areas so you are never reaching beyond a safe working position.
   - Use a roof ladder or staging rather than kneeling on the slope.
   - Keep materials and tools contained — offcuts slide down a valley and off the eaves.
   - Beware slips on wet slates, tiles and metal flashings.
   - Watch for awkward postures and rotate detail work to manage strain.
   - Check that edge protection covers the full working area including hips and verges.

**TBT-ROO-036 · Roof Openings, Smoke Vents & Hatches**
Purpose: Openings in a roof are falls waiting to happen and are often hidden by materials.
Key points:
   - Identify and mark every opening, rooflight and smoke vent before work starts.
   - Cover openings with load-rated, secured covers or install guardrails around them.
   - Never remove or stand on a cover, and reinstate it immediately after access.
   - Beware of automatic opening vents that operate without warning — isolate them.
   - Keep materials from being stacked over an opening where the cover cannot be seen.
   - Check covers again at the start of every shift.

**TBT-ROO-037 · Temporary Weather Protection & Tarpaulins**
Purpose: Sheeting a roof creates huge wind loads and a false floor that will not take weight.
Key points:
   - Never walk on a tarpaulin or sheet covering an opening — it hides the hole beneath.
   - Secure temporary coverings against wind with proper fixings, not loose ballast.
   - Check the structure can carry the additional wind load of the covering.
   - Inspect and re-secure coverings after every period of high wind or rain.
   - Keep the covering clear of flues, vents and hot equipment.
   - Plan the sequence so only the area that can be covered before the end of shift is opened.

**TBT-ROO-038 · Roof Drainage, Outlets & Ponding**
Purpose: Blocked outlets cause ponding, which adds weight the roof may not be designed to carry.
Key points:
   - Keep outlets and gutters clear of debris, offcuts and packaging throughout the works.
   - Report ponding — standing water is heavy and indicates a drainage or falls problem.
   - Treat gutters and parapets as edges, not as working platforms.
   - Beware of biological contamination in gutters and standing water.
   - Fit and protect outlet guards and do not allow site debris into the system.
   - Check drainage performance before handover and after heavy rain.

**TBT-ROO-039 · Working Over Occupied Buildings**
Purpose: People below have no idea what is happening above them and no protection.
Key points:
   - Establish exclusion zones, fans and netting over entrances and circulation routes below.
   - Agree working hours and noisy operations with the building occupier.
   - Never drop or throw material — use chutes, hoists and bags.
   - Protect openings, rooflights and smoke vents that open into occupied space.
   - Manage dust, fume and hot works so they do not enter occupied areas or trigger alarms.
   - Keep the occupier's escape routes clear at all times.

**TBT-ROO-040 · Heat, Glare & Dehydration on Roofs**
Purpose: Roof surfaces reflect and radiate heat, pushing working temperatures far above ground level.
Key points:
   - Recognise heat exhaustion early: headache, cramps, dizziness, nausea, confusion.
   - Drink water regularly through the shift, not just at breaks.
   - Schedule the heaviest work for cooler parts of the day where possible.
   - Use shade, rotate operatives and take breaks off the roof.
   - Protect skin from UV and glare; membranes and metal reflect strongly.
   - Watch colleagues for signs of heat stress — they may not notice it themselves.

### 4.12 Demolition & Soft Strip (`demolition`)

**TBT-DEM-001 · Asbestos & Unexpected Discovery**
Purpose: Disturbing asbestos releases lethal fibres — common in demolition.
Key points:
   - Check the asbestos survey/R&D before work.
   - STOP if suspect material is found.
   - Do not disturb — report immediately.
   - Only licensed contractors remove asbestos.
   - Decontaminate if exposure is suspected.

**TBT-DEM-002 · Structural Stability During Demolition**
Purpose: Uncontrolled collapse endangers workers and the public.
Key points:
   - Follow the demolition sequence and method statement.
   - Never freelance the sequence.
   - Establish exclusion zones.
   - Provide competent supervision.
   - Monitor for instability.

**TBT-DEM-003 · Dust, Noise & Vibration in Strip-Out**
Purpose: Demolition generates high levels of dust, noise and vibration.
Key points:
   - Suppress dust with water.
   - Wear RPE and hearing protection.
   - Manage HAVS from breakers.
   - Rotate tasks.
   - Control silica dust.

**TBT-DEM-004 · Manual Strip-Out & Sharps**
Purpose: Soft strip exposes sharps, fixings and biological hazards.
Key points:
   - Beware protruding nails and fixings.
   - Maintain safe waste routes.
   - Manage hygiene and biological hazards.
   - Wear appropriate PPE.
   - Light the work area.

**TBT-DEM-005 · Plant in Demolition**
Purpose: Excavators with attachments demolish at scale.
Key points:
   - Establish large exclusion zones.
   - Segregate plant from people.
   - Use trained operators and banksmen.
   - Beware falling debris.
   - Suppress dust during machine demolition.

**TBT-DEM-006 · Working with Breakers & Power Tools**
Purpose: Breakers cause HAVS, noise and silica exposure.
Key points:
   - Manage HAVS trigger-times.
   - Wear hearing and respiratory protection.
   - Suppress silica dust.
   - Rotate tasks.
   - Inspect tools before use.

**TBT-DEM-007 · Falling Materials & Debris**
Purpose: Demolition creates significant dropped-object risk.
Key points:
   - Establish exclusion zones below.
   - Use chutes for debris.
   - Wear head protection.
   - Control the direction of collapse.
   - Keep the public protected.

**TBT-DEM-008 · Hazardous Materials in Demolition**
Purpose: Old buildings contain many hazards beyond asbestos.
Key points:
   - Survey for lead, PCBs, refrigerants and contamination.
   - Isolate and make safe services first.
   - Follow removal procedures.
   - Wear appropriate PPE.
   - Dispose of hazardous waste correctly.

**TBT-DEM-009 · Service Isolation Before Demolition**
Purpose: Live services during demolition are deadly.
Key points:
   - Confirm all services are isolated and capped.
   - Obtain disconnection certificates.
   - Scan for hidden services.
   - Never assume services are dead.
   - Permit-control any breaking-in.

**TBT-DEM-010 · Confined Spaces in Demolition**
Purpose: Basements, tanks and voids present confined-space risk.
Key points:
   - Apply confined-space permits.
   - Test and monitor the atmosphere.
   - Ventilate.
   - Have rescue arrangements.
   - Only trained entrants.

**TBT-DEM-011 · Working at Height in Demolition**
Purpose: Demolishing upper floors and roofs at height.
Key points:
   - Provide edge protection or fall arrest.
   - Beware unstable structures.
   - Use safe access.
   - Control debris.
   - Stop in poor weather.

**TBT-DEM-012 · Fire Risk During Demolition**
Purpose: Hot works and combustible materials raise fire risk.
Key points:
   - Permit-control hot works.
   - Maintain fire watches.
   - Manage combustible waste.
   - Keep extinguishers available.
   - Maintain escape routes.

**TBT-DEM-013 · Public & Site Boundary Protection**
Purpose: Demolition near the public needs robust protection.
Key points:
   - Provide hoarding and fans.
   - Control dust and debris reaching the public.
   - Sign and secure the boundary.
   - Manage vehicle movements.
   - Maintain protection at all times.

**TBT-DEM-014 · Crusher & Processing Plant**
Purpose: On-site crushing brings dust, noise and machinery risk.
Key points:
   - Keep clear of the crusher and conveyors.
   - Suppress dust.
   - Wear hearing protection.
   - Isolate before clearing blockages.
   - Only trained operators.

**TBT-DEM-015 · Waste Segregation & Removal**
Purpose: Handling and hauling demolition waste.
Key points:
   - Segregate waste types including hazardous.
   - Use mechanical handling.
   - Sheet loads and control mud.
   - Beware sharps in waste.
   - Use banksmen for wagons.

**TBT-DEM-016 · Temporary Propping & Support**
Purpose: Partial demolition needs temporary support.
Key points:
   - Install propping to the temporary works design.
   - Never remove support without authorisation.
   - Monitor for movement.
   - Beware overloading.
   - Follow the sequence.

**TBT-DEM-017 · Soft Strip in Occupied Buildings**
Purpose: Strip-out near occupants or live areas.
Key points:
   - Segregate and protect occupied areas.
   - Control dust and noise.
   - Maintain escape routes.
   - Isolate services in the work area.
   - Communicate with occupants.

**TBT-DEM-018 · Manual Handling of Debris**
Purpose: Repetitive lifting of heavy, awkward debris.
Key points:
   - Use mechanical aids and chutes.
   - Team-lift heavy items.
   - Beware sharps and unstable loads.
   - Plan routes.
   - Rotate tasks.

**TBT-DEM-019 · Pre-Demolition Surveys**
Purpose: Surveying buildings before demolition exposes surveyors to many hazards.
Key points:
   - Assess structural stability before entry.
   - Check for asbestos and contamination.
   - Beware fragile floors and openings.
   - Never survey alone without arrangements.
   - Wear appropriate PPE.

**TBT-DEM-020 · Mechanical vs Manual Demolition Planning**
Purpose: Choosing the method affects everyone's safety.
Key points:
   - Follow the demolition method statement.
   - Establish exclusion zones for machine work.
   - Coordinate manual and machine activities.
   - Suppress dust.
   - Supervise competently.

**TBT-DEM-021 · Deconstruction Sequence & Engineer's Brief**
Purpose: Demolition sequence is engineered — taking elements out of order causes uncontrolled collapse.
Key points:
   - Work strictly to the demolition method statement and the engineer's sequence.
   - Never remove a structural element out of sequence, however convenient it looks.
   - Understand which elements are load-bearing, which are propping and which are ties.
   - Stop and consult the engineer if the structure behaves differently from expectation.
   - Re-brief the gang whenever the sequence or the structure changes.
   - Record progress against the sequence so the next shift knows exactly where it stands.

**TBT-DEM-022 · High-Reach Demolition Machines**
Purpose: High-reach machines bring material down from great height into an area that must be empty.
Key points:
   - Establish and enforce the exclusion zone based on the machine's reach and the structure's height.
   - Nobody enters the exclusion zone while the machine is operating — no exceptions.
   - Check ground bearing, level and stability at the machine position every shift.
   - Watch for material falling outside the predicted zone as the structure breaks up.
   - Maintain clear communication between the operator and the supervisor.
   - Use water suppression to control dust and to keep visibility for the operator.

**TBT-DEM-023 · Remote Controlled Demolition Robots**
Purpose: Remote machines keep the operator out of danger but only if the exclusion zone holds.
Key points:
   - Only trained operators may use remote demolition machines.
   - Maintain line of sight and a safe operating distance from the working area at all times.
   - Check floor loading before working on suspended slabs.
   - Beware of the machine's stability on slopes, debris and uneven ground.
   - Keep the exclusion zone clear; the operator's attention is on the machine, not on people.
   - Shut down and isolate before approaching the machine for any reason.

**TBT-DEM-024 · Explosive Demolition Awareness**
Purpose: Explosive demolition involves total site clearance and an exclusion zone measured in hundreds of metres.
Key points:
   - Only licensed explosives engineers may handle, place or initiate charges.
   - Understand the exclusion zone, the signals and the all-clear procedure before the day.
   - Comply absolutely with evacuation instructions and marshalling arrangements.
   - Never re-enter the exclusion zone until the all-clear is formally given.
   - Report any misfire or unexploded charge and keep everyone away.
   - Expect dust, noise, vibration and debris well beyond the structure's footprint.

**TBT-DEM-025 · Water Suppression & Dust Boom Systems**
Purpose: Demolition dust contains silica, asbestos fibres and hazardous particulates.
Key points:
   - Run suppression continuously during breaking, crushing and pulling operations.
   - Position booms and hoses to wet the material at the point of release, not just the air.
   - Manage water run-off so it does not undermine excavations or enter drains untreated.
   - Beware of ice from suppression water in cold weather.
   - Wear FFP3 RPE in addition to suppression where dust cannot be fully controlled.
   - Monitor dust at the boundary and stop work if it is escaping the site.

**TBT-DEM-026 · Façade Retention Systems**
Purpose: A retained façade is held up entirely by temporary steelwork that must never be disturbed.
Key points:
   - Never cut, alter or remove any part of the retention structure without the engineer's authorisation.
   - Report any movement, cracking, distortion or loosening of ties immediately.
   - Keep the retention system's load path clear — do not stack material against it.
   - Follow the monitoring regime and check the instrumentation readings.
   - Beware of wind loading on a free-standing façade and stop work at the design limit.
   - Maintain exclusion zones both sides of the façade.

**TBT-DEM-027 · Contaminated Dust & Lead Paint**
Purpose: Old buildings are coated in lead paint and contaminated with decades of industrial residue.
Key points:
   - Assume pre-1992 paint contains lead and do not burn, sand or grind it uncontrolled.
   - Use wet methods, extraction and FFP3 RPE when disturbing coated surfaces.
   - Never eat, drink or smoke in the work area and wash thoroughly before breaks.
   - Keep contaminated work clothing separate and do not take it home.
   - Attend health surveillance where lead exposure is significant.
   - Bag and dispose of contaminated waste as hazardous waste.

**TBT-DEM-028 · Rodent, Bird & Biological Hazards**
Purpose: Derelict buildings carry leptospirosis, psittacosis, histoplasmosis and tetanus risks.
Key points:
   - Treat bird guano, rodent droppings and stagnant water as biologically hazardous.
   - Never dry-sweep or disturb guano — wet it down and use RPE, coveralls and gloves.
   - Cover all cuts and grazes with waterproof dressings before entering.
   - Wash hands thoroughly before eating, drinking or smoking.
   - Report flu-like symptoms after working in contaminated areas and tell the doctor where you worked.
   - Check tetanus vaccination status is current.

**TBT-DEM-029 · Floor Loading & Debris Accumulation**
Purpose: Debris left on a suspended floor can overload a structure already weakened by demolition.
Key points:
   - Know the permitted floor loading and never allow debris to accumulate beyond it.
   - Clear debris progressively rather than at the end of the job.
   - Keep plant, skips and material stacks off suspended floors unless the engineer allows it.
   - Watch for deflection, cracking and sagging in floors and report it immediately.
   - Use chutes and hoists to remove debris rather than piling it up.
   - Do not work beneath floors carrying accumulated debris.

**TBT-DEM-030 · Scaffold & Access in Demolition**
Purpose: Scaffold on a structure being demolished is tied to something that is being taken away.
Key points:
   - Confirm the scaffold design accounts for demolition loading and the removal of tie points.
   - Never remove a tie or a structural element the scaffold depends on without the designer's approval.
   - Re-inspect the scaffold after every significant demolition operation and re-tag it.
   - Protect the scaffold from impact and falling debris.
   - Keep access routes and ladder bays clear of rubble.
   - Take the scaffold out of use immediately if the supporting structure is disturbed.

**TBT-DEM-031 · Fuel, Oil & Tank Removal**
Purpose: Old tanks hold flammable vapour and residue long after they appear empty.
Key points:
   - Never cut into a tank until it has been emptied, cleaned, purged and gas-freed by specialists.
   - Treat tank interiors as confined spaces with permit, testing and rescue arrangements.
   - Eliminate all hot works and ignition sources near tanks and their vent pipes.
   - Contain and dispose of residues as hazardous waste; never to ground or drains.
   - Watch for tanks becoming buoyant in groundwater during excavation.
   - Check for buried tanks the survey may have missed before excavating.

**TBT-DEM-032 · Glass Removal & Deglazing**
Purpose: Removing glazing from a building being stripped is where severe lacerations happen.
Key points:
   - Deglaze before mechanical demolition wherever possible rather than smashing it out.
   - Wear cut-resistant gauntlets, arm protection, eye and face protection.
   - Assume old glazing is unstable, cracked or loose in the frame.
   - Control the pane at all times and never let it fall outward into a public area.
   - Clear broken glass promptly into dedicated containers, not general skips.
   - Beware of glazing containing wired glass, laminates and asbestos-containing putty.

**TBT-DEM-033 · Salvage & Reclamation Handling**
Purpose: Salvage work is manual, in a partly demolished building, with tempting but heavy materials.
Key points:
   - Confirm the structure is stable and the area is released for manual work before entering.
   - Use mechanical handling for heavy items — flagstones, beams, radiators and stonework.
   - Check for asbestos, lead and contamination before handling any reclaimed material.
   - Watch for nails, glass, sharp edges and hidden voids.
   - Stack salvaged materials stably in a designated area, not in access routes.
   - Do not take unauthorised material from site.

**TBT-DEM-034 · Cutting Structural Steel & Hot Works**
Purpose: Cutting steel releases both fire risk and the load the steel was carrying.
Key points:
   - Obtain a hot works permit and maintain a fire watch during and after cutting.
   - Confirm with the engineer that the member can be cut and in what sequence.
   - Support or restrain the member before the final cut so it cannot fall or swing.
   - Check for coatings containing lead, zinc or asbestos before applying heat.
   - Use local exhaust ventilation and suitable RPE for welding and cutting fume.
   - Secure gas bottles, use flashback arrestors and store them safely at shift end.

**TBT-DEM-035 · Basement & Below-Ground Demolition**
Purpose: Basements combine confined space, contamination, collapse and restricted access.
Key points:
   - Test the atmosphere before entry; basements accumulate fumes, gas and oxygen-deficient air.
   - Never take petrol or LPG plant below ground without ventilation and monitoring.
   - Provide two means of escape wherever practicable and keep them clear.
   - Support retained walls and check for surcharge from adjacent ground and structures.
   - Manage water ingress and pumping so the excavation is not undermined.
   - Provide adequate lighting and communication to the surface.

**TBT-DEM-036 · Party Walls & Adjoining Owners**
Purpose: Demolition next to someone else's building can bring their property down.
Key points:
   - Check the party wall award and its conditions before starting work at the boundary.
   - Never remove support to an adjoining structure without the designed temporary works in place.
   - Weatherproof and make good exposed party walls as demolition proceeds.
   - Monitor the adjoining building for movement and cracking and record it.
   - Report any damage to the adjoining property immediately.
   - Keep noise, dust and vibration within the agreed limits and hours.

**TBT-DEM-037 · Vibration & Neighbouring Structures**
Purpose: Breaking and crushing transmits vibration that can damage structures and services nearby.
Key points:
   - Follow the vibration monitoring regime and observe the trigger levels.
   - Stop work and report if monitors exceed the alert threshold.
   - Be aware of sensitive neighbours: hospitals, listed buildings, laboratories and services.
   - Use lower-vibration methods close to boundaries and sensitive structures.
   - Watch for cracking, movement and dislodged material in nearby buildings.
   - Manage operatives' own hand-arm and whole-body vibration exposure at the same time.

**TBT-DEM-038 · Demolition Exclusion Zones & Banksmen**
Purpose: The exclusion zone is the single control that keeps people away from collapsing structure.
Key points:
   - Set the exclusion zone from the method statement and mark it physically, not with tape alone.
   - Nobody enters while demolition is in progress; work stops before anyone crosses the line.
   - Use a dedicated banksman who watches people, not the machine.
   - Review the zone as the structure changes height and shape through the job.
   - Keep visitors, deliveries and other trades briefed on the boundary.
   - Anyone can call a stop if they see someone entering the zone.

**TBT-DEM-039 · Emergency Stop & Rescue in Demolition**
Purpose: A demolition site is the hardest place to reach and extract a casualty.
Key points:
   - Know the emergency stop procedure and the signal that stops all plant immediately.
   - Keep an emergency access route into the site clear for the ambulance and fire service.
   - Maintain a rescue plan for confined spaces, height and entrapment before those works start.
   - Know the site address, grid reference and nearest access point for a 999 call.
   - Never attempt to move a casualty trapped under debris without the emergency services.
   - Account for everyone on site immediately after any incident.

**TBT-DEM-040 · Site Clearance & Final Reinstatement**
Purpose: The end of a demolition job leaves voids, obstructions and services in unpredictable states.
Key points:
   - Cap, seal and record all redundant services before the site is left.
   - Fill or barrier every void, basement and excavation before demobilising.
   - Remove or make safe all projecting reinforcement, fixings and sharp debris.
   - Leave the site secured against unauthorised access, especially children.
   - Confirm the ground is stable and correctly compacted for the next stage.
   - Complete the records of what was removed, found and left in place.

### 4.13 Steel Fixing & Concrete (`steel_fixing`)

**TBT-STL-001 · Rebar Handling & Protruding Bar**
Purpose: Reinforcement bar causes impalement and handling injuries.
Key points:
   - Cap all protruding bar to prevent impalement.
   - Use mechanical aids for heavy bar.
   - Beware sharp cut ends.
   - Team-lift long lengths.
   - Maintain clear routes.

**TBT-STL-002 · Working at Height on Rebar Mats**
Purpose: Falls through or onto rebar mats are severe.
Key points:
   - Provide access platforms over mats.
   - Use edge protection.
   - Beware foot placement on mats.
   - Cap bar below.
   - Use fall protection where needed.

**TBT-STL-003 · Concrete Pours & Pump Lines**
Purpose: Stored energy in pump lines and wet-concrete burns.
Key points:
   - Control pump-line whip and blockages.
   - Establish exclusion zones.
   - Wear PPE for wet-concrete burns.
   - Never overreach.
   - Communicate with the pump operator.

**TBT-STL-004 · Vibrating Poker & HAVS**
Purpose: Concrete vibration tools cause HAVS.
Key points:
   - Manage trigger-time on pokers.
   - Maintain grip and keep hands warm.
   - Rotate tasks.
   - Report symptoms.
   - Inspect equipment.

**TBT-STL-005 · Formwork & Falsework**
Purpose: Formwork holds wet concrete loads — failure is catastrophic.
Key points:
   - Never alter formwork/falsework without authorisation.
   - Follow the loading sequence and striking times.
   - Get temporary works coordinator sign-off.
   - Inspect before pours.
   - Report any movement.

**TBT-STL-006 · Steel Erection & Connections**
Purpose: Erecting structural steel at height with heavy loads.
Key points:
   - Use fall protection during erection.
   - Follow the lift and erection plan.
   - Beware swinging loads.
   - Bolt up and stabilise as you go.
   - Establish exclusion zones.

**TBT-STL-007 · Lifting Operations for Steel**
Purpose: Heavy steel lifts need rigorous planning.
Key points:
   - Work to a lift plan with an appointed person.
   - Use LOLER-inspected gear.
   - Use tag lines and never stand under loads.
   - Observe weather limits.
   - Communicate clearly.

**TBT-STL-008 · Cutting & Grinding Steel**
Purpose: Hot works and metal dust/sparks.
Key points:
   - Permit-control hot cutting.
   - Wear eye, face and respiratory protection.
   - Control sparks and combustibles.
   - Beware hot metal.
   - Use guards on grinders.

**TBT-STL-009 · Bar Bending & Cutting Machines**
Purpose: Powered bar machines cause crush and amputation.
Key points:
   - Keep hands clear of cutting/bending points.
   - Use guards.
   - Isolate before clearing.
   - Only trained operators.
   - Secure the bar.

**TBT-STL-010 · Working Over Edges & Voids**
Purpose: Steel and concrete frames have many open edges.
Key points:
   - Maintain edge protection.
   - Cover voids and openings.
   - Use fall protection.
   - Control dropped objects.
   - Coordinate with other trades.

**TBT-STL-011 · Wet Concrete & Dermatitis**
Purpose: Prolonged skin contact with concrete burns.
Key points:
   - Wear waterproof gloves and boots.
   - Wash off splashes promptly.
   - Check skin for damage.
   - Keep wash stations available.
   - Avoid kneeling in wet concrete.

**TBT-STL-012 · Precast Concrete Handling**
Purpose: Heavy precast units with crush and lifting risk.
Key points:
   - Use lifting plans and certified anchors.
   - Never stand under suspended units.
   - Use tag lines.
   - Brace units until fixed.
   - Beware trapped fingers.

**TBT-STL-013 · Post-Tensioning Awareness**
Purpose: Tensioned cables store huge energy.
Key points:
   - Never drill/cut into post-tensioned slabs.
   - Identify PT zones from drawings.
   - Keep clear during stressing.
   - Only competent persons stress tendons.
   - Establish exclusion zones.

**TBT-STL-014 · Reinforcement Fixing Posture**
Purpose: Repetitive bending and tying causes MSDs.
Key points:
   - Use tying tools to reduce strain.
   - Rotate tasks.
   - Manage posture.
   - Take breaks.
   - Report strains early.

**TBT-STL-015 · Concrete Finishing & Power Floats**
Purpose: Power floats cause entanglement and slips.
Key points:
   - Keep clear of the float blades.
   - Beware wet, slippery surfaces.
   - Manage HAVS/noise.
   - Isolate before clearing.
   - Only trained operators.

**TBT-STL-016 · Slab Edge & Mesh Work**
Purpose: Working at slab edges with mesh and bar.
Key points:
   - Provide edge protection at slab edges.
   - Cap protruding mesh and bar.
   - Beware trips on mesh.
   - Handle mesh sheets with care.
   - Control dropped objects.

**TBT-STL-017 · Crane-Supported Steelwork**
Purpose: Crane lifts dominate steel erection safety.
Key points:
   - Follow the lift plan and exclusion zones.
   - Use trained slingers/signallers.
   - Never walk under loads.
   - Check gear before each lift.
   - Stop lifting in high winds.

**TBT-STL-018 · Site Welding & Fume**
Purpose: Welding fume harms the lungs and eyes.
Key points:
   - Use LEV for welding fume.
   - Wear correct eye/face protection.
   - Permit-control hot works.
   - Screen others from arc flash.
   - Ventilate enclosed areas.

**TBT-STL-019 · Mesh & Fabric Reinforcement Handling**
Purpose: Sheets of mesh are heavy, springy and sharp.
Key points:
   - Team-lift mesh sheets.
   - Beware springy, sharp ends.
   - Cap protruding ends.
   - Store flat and secured.
   - Wear gloves and eye protection.

**TBT-STL-020 · Grouting & Non-Shrink Products**
Purpose: Grouts and additives are hazardous and dusty.
Key points:
   - Follow COSHH for grouts and additives.
   - Control mixing dust.
   - Protect skin and eyes.
   - Ventilate.
   - Wash before eating.

**TBT-STL-021 · Rebar Cages — Stability During Assembly**
Purpose: A part-built reinforcement cage is unstable and has collapsed onto the fixers building it.
Key points:
   - Prop, brace and tie cages progressively as they are assembled — never leave them freestanding.
   - Follow the temporary stability arrangement in the design; do not rely on the tying wire.
   - Beware of wind loading on tall cages and walls of reinforcement.
   - Never climb a cage that is not designed and braced as an access structure.
   - Keep clear of a cage being lifted and use tag lines to control it.
   - Stop and report any movement, leaning or deflection immediately.

**TBT-STL-022 · Couplers, Threaded Bar & Mechanical Splices**
Purpose: Couplers put projecting threaded ends at body height and rely on correct installation for strength.
Key points:
   - Cap all projecting threaded ends — they cause the same impalement risk as plain bar.
   - Cut and thread bar at a proper station with guarding, not held by hand.
   - Achieve the specified engagement and torque; a partly engaged coupler fails under load.
   - Keep swarf and cutting oil cleared to prevent slips and contamination.
   - Protect threads from damage and corrosion before assembly.
   - Never substitute coupler types or sizes without the engineer's approval.

**TBT-STL-023 · Tying Wire, Nippers & Hand Injuries**
Purpose: Tying is thousands of repetitions a day with sharp wire ends at hand height.
Key points:
   - Use a power tying tool where available to reduce repetitive strain and hand injury.
   - Cut wire ends short and turn them inward, away from where people work and walk.
   - Wear gloves suited to wire handling and check them for wear.
   - Keep offcut wire collected — loose ends puncture boots, tyres and skin.
   - Rotate tying tasks and stretch to manage wrist and forearm strain.
   - Report tingling, numbness or persistent wrist pain early.

**TBT-STL-024 · Column & Wall Formwork Erection**
Purpose: Tall formwork panels are heavy, top-loaded and unstable until fully braced.
Key points:
   - Erect strictly to the temporary works design including all props, ties and kickers.
   - Never release the crane hook until the panel is fully braced and secured.
   - Use the built-in access platforms and ladders, not the formwork frame.
   - Keep clear of panels being landed and use tag lines to control them.
   - Check tie rods, wedges and clamps are complete and tight before any pour.
   - Watch for wind loading on large panels during erection.

**TBT-STL-025 · Striking Formwork & Falsework**
Purpose: Striking too early or out of sequence causes structural collapse.
Key points:
   - Never strike formwork or props without written authorisation from the temporary works coordinator.
   - Confirm the concrete has reached the specified strength, not just an expected number of days.
   - Follow the striking sequence exactly; back-propping may be required.
   - Lower panels under control — do not drop or pull them away.
   - Keep the area below clear and barriered during striking.
   - De-nail, clean and stack struck formwork safely rather than leaving it loose.

**TBT-STL-026 · Slipform & Jumpform Systems**
Purpose: Climbing formwork is a continuously moving workplace at height with hydraulic power.
Key points:
   - Only trained operatives may work on or operate climbing formwork systems.
   - Check all anchors, brackets and shoes before every climb.
   - Nobody may be in an unauthorised position during a climb; follow the climb procedure exactly.
   - Maintain edge protection on every platform level and close all trapdoors after use.
   - Control dropped objects rigorously — the fall height is the full building.
   - Stop climbing operations in high winds and follow the weather limits in the plan.

**TBT-STL-027 · Concrete Skips & Crane-Placed Concrete**
Purpose: A full skip is a heavy suspended load moving over people working in reinforcement.
Key points:
   - Follow the lift plan and keep the load path away from people wherever possible.
   - Never stand under or reach beneath a suspended skip.
   - Check the skip, its gate mechanism and lifting eyes before use.
   - Use tag lines to control the skip and keep hands off the underside of the gate.
   - Agree signals between the slinger and the crane operator before starting.
   - Watch footing on reinforcement while positioning to receive the skip.

**TBT-STL-028 · Admixtures, Curing Compounds & Release Oils**
Purpose: Concrete chemicals are irritant, some are corrosive, and release oils create slip hazards.
Key points:
   - Check the COSHH assessment and safety data sheet before using any concrete chemical.
   - Wear gloves, eye protection and skin cover; admixtures and retarders burn on contact.
   - Apply release agents sparingly and contain overspray — oiled formwork and floors are lethally slippery.
   - Ventilate when spraying curing compounds in enclosed areas and use the specified RPE.
   - Store products bunded and labelled, away from drains.
   - Never allow chemicals or washings to reach surface water drains.

**TBT-STL-029 · Concrete Cutting & Diamond Sawing**
Purpose: Cutting concrete combines silica dust, water, electricity, heavy blades and structural risk.
Key points:
   - Obtain approval from the engineer before cutting any structural element.
   - Scan for reinforcement, post-tensioning and services before cutting.
   - Use water suppression and check the slurry cannot reach live equipment or floors below.
   - Support the cut section so it cannot drop; plan and control the removal of the piece.
   - Barrier the area above and below the cut.
   - Wear eye, face, hearing protection and FFP3 RPE, and check blade condition before use.

**TBT-STL-030 · Concrete Repair & Hydrodemolition**
Purpose: High-pressure water jetting cuts through concrete and will cut through a person instantly.
Key points:
   - Only trained, certificated operatives may use high-pressure jetting equipment.
   - Never place any part of the body in line with the jet, even momentarily.
   - Use a dead-man control and check hoses, lances and couplings before every use.
   - Establish a strict exclusion zone — the jet and debris travel a long way.
   - Wear the full jetting PPE specified, including protection against injection injury.
   - Any jetting injury, however small it looks, is a medical emergency — say it was a water jet.

**TBT-STL-031 · Shear Studs & Through-Deck Welding**
Purpose: Stud welding is high-current hot work carried out on an open metal deck.
Key points:
   - Obtain a hot works permit and control combustibles below the deck.
   - Ensure the deck is dry — moisture causes violent expulsion of molten metal.
   - Wear welding gloves, eye protection and flame-resistant clothing.
   - Keep leads and equipment clear of walkways and out of standing water.
   - Beware of the fume and ventilate the area, especially in enclosed bays.
   - Maintain edge protection and deck fixing before working across the deck.

**TBT-STL-032 · Metal Decking Installation**
Purpose: Decking is laid at height on open steel frame with unfixed sheets underfoot.
Key points:
   - Never step onto decking that has not been fixed down — unfixed sheets slide.
   - Install safety netting beneath the decking operation before it starts.
   - Handle bundles with the crane; do not drag or carry sheets in wind.
   - Wear cut-resistant gloves — deck edges are extremely sharp.
   - Fix edge protection at the leading edge and to the perimeter as the deck advances.
   - Stop work when wind speeds reach the limit; deck sheets act as sails.

**TBT-STL-033 · Bolting Up & Access on Steel Frames**
Purpose: Bolting up puts steel erectors in exposed positions on narrow members at height.
Key points:
   - Use MEWPs or designed access platforms as the primary means of access, not climbing the steel.
   - Where climbing is unavoidable, use a fall arrest system with a suitable anchor and rescue plan.
   - Never release the crane hook until the member is adequately bolted and stable.
   - Tether spanners, podgers and bolts to prevent dropped objects.
   - Install temporary bracing and fit safety wires as the frame goes up.
   - Stop erection in wind, ice or poor visibility beyond the method statement limits.

**TBT-STL-034 · Safety Netting Beneath Steelwork**
Purpose: Netting is the collective protection that makes steel erection survivable.
Key points:
   - Only trained net riggers may install, alter or remove nets.
   - Check the net has a current test tag and is free of damage, debris and burns.
   - Rig the net as close beneath the work as possible and check the clearance below it.
   - Never store materials or offcuts on a net or use it as a platform.
   - Protect nets from hot works — sparks and slag destroy the fibres.
   - Report and quarantine any net that has arrested a fall.

**TBT-STL-035 · Fire Watch During Structural Hot Works**
Purpose: Most construction fires start during hot works and are discovered after the crew has left.
Key points:
   - Maintain a dedicated fire watch during the work and for at least 60 minutes after.
   - Check below, behind and inside the structure — sparks travel a long way through voids.
   - Remove or protect combustibles within the work zone before starting.
   - Have the right extinguisher immediately to hand and know how to use it.
   - Never leave hot works unattended or hand the watch over informally.
   - Sign off the permit only after the final check confirms no smouldering.

**TBT-STL-036 · Slinger & Signaller Duties for Steel Loads**
Purpose: The slinger controls the load and the signaller controls the crane — both hold the lift in their hands.
Key points:
   - Only trained and appointed slingers and signallers may perform these roles.
   - Check accessories for certification, tags and damage, and check the SWL against the load.
   - Assess the centre of gravity and use the correct sling angle — angles multiply the load.
   - Use one signaller only, in a position where they can see the load and be seen.
   - Keep everyone out of the load path and never guide a load by hand — use tag lines.
   - Carry out a trial lift and stop immediately if the load is unstable.

**TBT-STL-037 · Temperature Effects on Concrete Operations**
Purpose: Heat and cold change how concrete sets and how safe the operation is.
Key points:
   - Do not pour onto frozen ground or frozen reinforcement.
   - Protect fresh concrete from frost with insulation and monitor the temperature.
   - In hot weather, plan for rapid set: shorter pours, more people, earlier starts.
   - Beware of steam and heat from accelerators and thermal blankets.
   - Confirm strength gain before striking or loading, using cube results and not the calendar.
   - Manage the workforce for heat and cold stress during long pours.

**TBT-STL-038 · Leading Edge Work on Steel Frames**
Purpose: The leading edge is the point where protection has not yet been installed.
Key points:
   - Plan the erection sequence so the leading edge is protected before anyone works at it.
   - Install perimeter edge protection and netting as the frame advances, not afterwards.
   - Use fall arrest with a suitable anchor while working at an unprotected edge.
   - Keep the number of people at the leading edge to the minimum required.
   - Watch for the pendulum swing risk when anchored to one side.
   - Stop work at the edge in high winds, rain or poor visibility.

**TBT-STL-039 · Rebar Deliveries & Bundle Handling**
Purpose: Bundles of bar are heavy, spring when cut and roll without warning.
Key points:
   - Offload mechanically onto firm, level ground and never stand beneath the load.
   - Cut banding from the safe side and expect the bundle to spring open.
   - Chock bundles to prevent rolling and stack them stable and low.
   - Use a crane or telehandler to distribute bar; do not carry long bars by hand where avoidable.
   - Carry long bars with two people and be aware of the ends near others and near overhead lines.
   - Cap the ends of stored bar in walkways and working areas.

**TBT-STL-040 · Concrete Sampling, Cubes & Testing**
Purpose: Sampling puts people close to the pour, the pump and the wet concrete.
Key points:
   - Take samples from an agreed safe position, clear of the discharge and pump line.
   - Wear gloves, eye protection and waterproofs; wet concrete burns on prolonged contact.
   - Handle cube moulds and filled cubes with care — they are heavier than they look.
   - Keep the sampling area clear of traffic and plant movements.
   - Store cubes in the curing tank safely and use the correct lifting technique.
   - Wash off any concrete contact immediately and report reddening or burning.

### 4.14 Plant & Machinery (`plant`)

**TBT-PLA-001 · Operator Competence & Daily Checks**
Purpose: Untrained operation and unchecked plant cause failures and injuries.
Key points:
   - Hold a valid CPCS/NPORS card for the machine.
   - Carry out and record pre-use inspections.
   - Report and quarantine defects.
   - Wear the seatbelt.
   - Never operate unauthorised plant.

**TBT-PLA-002 · MEWP Safe Use & Rescue**
Purpose: MEWPs risk entrapment, overturn and falls.
Key points:
   - Be IPAF-trained for the machine type.
   - Assess the ground before use.
   - Wear a harness in boom-type MEWPs.
   - Establish exclusion zones.
   - Have a rescue plan.

**TBT-PLA-003 · Telehandler & Forklift Operations**
Purpose: Material handlers cause tip-overs and pedestrian strikes.
Key points:
   - Observe load charts and SWL.
   - Maintain visibility or use a banksman.
   - Use the correct attachments.
   - Beware tip-over on slopes.
   - Exclude pedestrians from the area.

**TBT-PLA-004 · Excavator Operations**
Purpose: Excavators are versatile but high-risk machines.
Key points:
   - Check quick-hitches are engaged.
   - Segregate from pedestrians.
   - Use a banksman near services.
   - Never lift or carry people.
   - Beware overhead and underground services.

**TBT-PLA-005 · Dumpers & Site Vehicles**
Purpose: Dumpers overturn and strike pedestrians.
Key points:
   - Wear the seatbelt.
   - Never overload or obscure visibility.
   - Beware edges and slopes.
   - Use a banksman when reversing.
   - Maintain segregation.

**TBT-PLA-006 · Refuelling & Battery/EV Plant**
Purpose: Fuel and batteries bring fire and chemical risks.
Key points:
   - Refuel with the engine off and control spills.
   - Keep ignition sources away.
   - Follow EV charging and isolation procedures.
   - Handle batteries with correct PPE.
   - Store fuels safely.

**TBT-PLA-007 · Plant Maintenance & Isolation**
Purpose: Maintenance exposes workers to stored energy and moving parts.
Key points:
   - Isolate and lock off before maintenance.
   - Release stored energy/pressure.
   - Use props for raised components.
   - Only competent persons maintain plant.
   - Follow safe systems of work.

**TBT-PLA-008 · Working Near Cranes**
Purpose: Mobile and tower cranes dominate site lifting risk.
Key points:
   - Stay out of exclusion zones.
   - Never walk under suspended loads.
   - Obey signallers.
   - Beware slewing counterweights.
   - Report unsafe lifts.

**TBT-PLA-009 · Lifting Accessories & LOLER**
Purpose: Chains, slings and shackles must be inspected.
Key points:
   - Inspect accessories before use.
   - Check SWL markings.
   - Use the correct accessory for the load.
   - Quarantine damaged gear.
   - Maintain inspection records.

**TBT-PLA-010 · Ground Conditions for Plant**
Purpose: Plant overturns on poor or unprepared ground.
Key points:
   - Assess ground bearing capacity.
   - Use mats and prepared platforms.
   - Beware excavations and voids.
   - Keep plant back from edges.
   - Re-assess after rain.

**TBT-PLA-011 · Plant Movements & Loading**
Purpose: Loading plant onto transport is high-risk.
Key points:
   - Use suitable ramps and firm ground.
   - Beware tip-over during loading.
   - Secure loads for transport.
   - Segregate people from loading.
   - Use a banksman.

**TBT-PLA-012 · Quick-Hitch Safety**
Purpose: Quick-hitch failures drop attachments.
Key points:
   - Verify the quick-hitch is fully engaged.
   - Carry out the check procedure.
   - Beware semi-automatic hitch risks.
   - Inspect before use.
   - Report defects.

**TBT-PLA-013 · Reversing & Blind Spots**
Purpose: Reversing plant strikes pedestrians.
Key points:
   - Use banksmen and reversing aids.
   - Minimise reversing with one-way systems.
   - Maintain eye contact.
   - Fit and use cameras/sensors.
   - Keep pedestrians clear.

**TBT-PLA-014 · Noise & Vibration from Plant**
Purpose: Operators face noise and whole-body vibration.
Key points:
   - Maintain seats and cabs.
   - Limit exposure and take breaks.
   - Wear hearing protection where needed.
   - Maintain plant to reduce noise.
   - Report excessive vibration.

**TBT-PLA-015 · Crushing & Trapping Hazards**
Purpose: Plant creates serious crush and trap points.
Key points:
   - Stay clear of slewing and articulation zones.
   - Beware pinch points.
   - Maintain segregation.
   - Use exclusion zones.
   - Never position yourself between plant and a fixed object.

**TBT-PLA-016 · Plant on Public Highways**
Purpose: Plant near the public and traffic.
Key points:
   - Follow traffic management plans.
   - Use banksmen and signage.
   - Control mud on the road.
   - Beware pedestrians and cyclists.
   - Maintain exclusion zones.

**TBT-PLA-017 · Concrete Pumps**
Purpose: Booms and lines store energy and reach high.
Key points:
   - Set up on firm, level ground with outriggers.
   - Beware overhead lines with the boom.
   - Control line whip and blockages.
   - Establish exclusion zones.
   - Communicate with the team.

**TBT-PLA-018 · Site Dumper Tipping**
Purpose: Tipping near edges and excavations risks overturn.
Key points:
   - Never tip too close to edges.
   - Use stop blocks.
   - Tip on firm, level ground.
   - Beware sticky loads raising the centre of gravity.
   - Wear the seatbelt.

**TBT-PLA-019 · Abnormal & Wide Loads**
Purpose: Moving large plant and loads on site and road.
Key points:
   - Plan routes and check clearances.
   - Use escorts and banksmen.
   - Secure loads correctly.
   - Beware overhead lines and structures.
   - Communicate movements.

**TBT-PLA-020 · Plant Theft & Out-of-Hours Security**
Purpose: Securing plant protects people and property.
Key points:
   - Immobilise and secure plant when not in use.
   - Remove keys and lock cabs.
   - Store attachments safely.
   - Report suspicious activity.
   - Follow site security procedures.

**TBT-PLA-021 · Tower Crane Operations & Exclusion Zones**
Purpose: A tower crane slews over the whole site, and everything beneath it is in the drop zone.
Key points:
   - Never walk under a suspended load or stand in the load path.
   - Observe exclusion zones around lifting and landing areas and around the crane base.
   - Do not enter the crane base or climb the tower without authorisation.
   - Report any dropped object, load swing or near miss involving the crane immediately.
   - Be aware of the out-of-service slew radius and keep materials clear of it.
   - Stop lifting operations in wind, lightning or poor visibility per the crane's limits.

**TBT-PLA-022 · Mobile Crane Set-Up, Outriggers & Ground Bearing**
Purpose: Most mobile crane overturns are caused by inadequate ground beneath an outrigger.
Key points:
   - Confirm ground bearing capacity and the outrigger mat sizes from the lift plan.
   - Check for voids, drains, basements, cellars and backfilled trenches beneath the set-up position.
   - Fully extend and set all outriggers and level the crane before lifting.
   - Keep everyone clear of the outrigger sweep during set-up and stowing.
   - Re-check levels and mats during the shift; ground settles under load.
   - Stop and reassess if the crane shows any sign of settlement or list.

**TBT-PLA-023 · Lift Plans & the Appointed Person**
Purpose: Every lift needs a plan proportionate to its risk, produced by a competent Appointed Person.
Key points:
   - No lift proceeds without an appropriate lift plan and a briefing to everyone involved.
   - Know the roles on the day: Appointed Person, lift supervisor, operator, slinger and signaller.
   - Check the load weight, centre of gravity, radius and the crane's capacity at that radius.
   - Complex, tandem and blind lifts require a specific plan, never a generic one.
   - Stop the lift if anything differs from the plan — weight, ground, weather or people.
   - Re-plan rather than adapt on the day.

**TBT-PLA-024 · Telehandler Attachments & Load Charts**
Purpose: A telehandler's capacity falls dramatically as the boom extends, and the chart is the only guide.
Key points:
   - Read the load chart for the attachment fitted — each attachment has its own chart.
   - Never exceed the rated capacity at the working radius; capacity is not a single number.
   - Confirm the attachment is correctly fitted, pinned and, where applicable, hydraulically locked.
   - Keep the load low and close when travelling, and travel with the boom retracted.
   - Never use a telehandler to lift people unless fitted with an approved man platform and using the correct mode.
   - Check ground conditions and slopes before lifting or travelling with a load.

**TBT-PLA-025 · Skid Steer & Compact Track Loaders**
Purpose: Compact loaders are highly manoeuvrable, work close to people and have serious blind spots.
Key points:
   - Only trained operators may use skid steers, and the restraint bar must be in place.
   - Never enter or leave the cab over a raised loader arm or with the engine running.
   - Support raised arms with the approved locks before any work beneath them.
   - Keep pedestrians well clear; the machine pivots on the spot with no warning.
   - Beware of tipping on slopes — travel with the load uphill.
   - Lower the attachment to the ground, engage the brake and remove the key before dismounting.

**TBT-PLA-026 · Tracked Plant Movement & Transport on Site**
Purpose: Tracked machines move slowly but have huge blind spots and damage surfaces and services.
Key points:
   - Use a banksman for tracking in congested areas and near excavations.
   - Check the route for buried services, ducts, drainage and soft ground before tracking.
   - Protect completed drainage, kerbs and slabs with running mats or plates.
   - Keep everyone out of the slew and track path; tracks crush without the operator feeling it.
   - Track up and down slopes, not across, and with the heavy end uphill.
   - Park on level ground with attachments grounded and the machine secured.

**TBT-PLA-027 · Operator Fatigue, Cab Comfort & Visibility**
Purpose: An operator's alertness and sightlines are the last line of defence for everyone on foot.
Key points:
   - Clean windows, mirrors and camera lenses at the start of every shift.
   - Adjust seat, mirrors and controls before starting work, not while moving.
   - Take regular breaks out of the cab; long periods of repetitive operation cause lapses.
   - Report fatigue rather than continuing — an operator who nods off kills someone.
   - Keep the cab free of loose items that can roll under the controls.
   - Stop and reposition rather than operating from a position where you cannot see.

**TBT-PLA-028 · Seat Belts & Rollover Protection (ROPS/FOPS)**
Purpose: In an overturn the seat belt keeps you inside the protective structure, which is what saves you.
Key points:
   - Wear the seat belt whenever the machine is moving or operating — this is not optional.
   - Never operate a machine with damaged, modified or missing ROPS or FOPS.
   - Do not attempt to jump clear during an overturn; stay belted inside the cab.
   - Check the belt, mountings and cab structure during the pre-use inspection.
   - Report any impact, overturn or structural damage to the cab immediately.
   - Never carry passengers unless there is a designed, belted seat for them.

**TBT-PLA-029 · Thorough Examination & Plant Records**
Purpose: Statutory examination catches the failures that daily checks cannot see.
Key points:
   - Check the thorough examination is in date before using any lifting equipment or MEWP.
   - Lifting equipment for people requires examination every 6 months, other lifting equipment every 12.
   - Keep daily and weekly inspection records up to date and available on site.
   - Never use plant with an expired certificate or an outstanding defect.
   - Record defects when you find them; a verbal report disappears at shift change.
   - Quarantine and label defective plant so nobody else starts it.

**TBT-PLA-030 · Hydraulic Fluid Injection Injuries**
Purpose: A pinhole leak at high pressure injects fluid through skin and causes amputation if not treated fast.
Key points:
   - Never search for a hydraulic leak with your hand — use cardboard or paper.
   - Depressurise and isolate the system before working on any hydraulic component.
   - Beware of stored pressure in accumulators and raised attachments.
   - Wear gloves and eye protection when working on hydraulics.
   - Any suspected injection injury is a surgical emergency — go to A&E immediately and say it was hydraulic fluid.
   - Report and replace weeping and chafed hoses rather than running them on.

**TBT-PLA-031 · Bucket & Attachment Changeover**
Purpose: Changeover is when people are closest to a machine with an attachment that can drop.
Key points:
   - Carry out changeovers on firm, level ground with the machine shut down and isolated where possible.
   - Only the person doing the change is near the machine, with clear communication to the operator.
   - Follow the quick-hitch procedure exactly and fit the safety pin every time.
   - Visually and physically check the attachment is fully engaged before use.
   - Test the attachment by crowding it against the ground before working with it.
   - Never stand under or reach beneath a raised attachment.

**TBT-PLA-032 · Plant Emissions & Air Quality (NRMM)**
Purpose: Diesel engine exhaust emissions are a known carcinogen and accumulate in enclosed areas.
Key points:
   - Never run combustion engines inside buildings, basements or enclosed spaces without extraction.
   - Use electric or battery plant where available, especially indoors.
   - Check the machine meets the emissions stage required in low emission zones.
   - Position generators and compressors so exhaust is not drawn into work or welfare areas.
   - Switch engines off rather than idling.
   - Fit and monitor CO detection where engines run in partly enclosed areas.

**TBT-PLA-033 · Goods & Passenger Hoists**
Purpose: Hoists move people and materials up the outside of a building on a mast that must be maintained.
Key points:
   - Only trained and authorised operators may use the hoist.
   - Never exceed the rated load or the maximum number of passengers.
   - Keep gates and barriers closed; never reach into the hoistway or ride on a goods-only hoist.
   - Load evenly, secure the load and never allow anything to protrude beyond the cage.
   - Check the daily inspection and thorough examination are current.
   - Know the emergency lowering and evacuation procedure.

**TBT-PLA-034 · Site Speed Limits & Traffic Management Plans**
Purpose: Most site vehicle injuries happen at low speed in areas that were supposed to be segregated.
Key points:
   - Observe the site speed limit and the one-way system at all times.
   - Keep vehicles to designated routes and out of pedestrian areas.
   - Use designated crossing points and make eye contact with drivers before crossing.
   - Keep the traffic management plan up to date as the site changes and re-brief everyone.
   - Maintain signage, barriers and lighting on routes, particularly in winter.
   - Report near misses between vehicles and pedestrians; they predict the next injury.

**TBT-PLA-035 · Loading & Securing Plant on Trailers**
Purpose: Loading plant onto a trailer involves ramps, slopes and heavy machines close to people.
Key points:
   - Load on firm, level ground with the trailer braked and, where fitted, the tractor unit connected.
   - Keep everyone clear of the ramps and the machine during loading.
   - Position the machine centrally and lower attachments onto the bed before securing.
   - Use rated chains and binders at the designed lashing points; check the securing standard.
   - Re-check the securing after a short distance and at each stop.
   - Check the overall height and route clearances before leaving site.

**TBT-PLA-036 · Electric & Hybrid Plant Charging**
Purpose: Electric plant removes exhaust emissions but adds high-voltage and battery fire risks.
Key points:
   - Only trained persons may work on high-voltage traction systems; treat them as live.
   - Charge from a suitably rated, RCD-protected supply on a designated hard standing.
   - Keep charging areas clear of combustibles and provide ventilation.
   - Inspect charging cables and connectors before every use and route them away from traffic.
   - Withdraw and isolate any machine with a damaged, swollen or hot battery pack.
   - Know that a lithium battery fire needs evacuation and the fire service — not an extinguisher alone.

**TBT-PLA-037 · Jacking, Chocking & Working Under Plant**
Purpose: Machines have crushed fitters when a jack, prop or raised attachment failed.
Key points:
   - Never rely on a jack or hydraulics alone to support a machine you are working under.
   - Use rated axle stands, props or the machine's own locking devices.
   - Isolate the machine, remove the key and apply a lock and tag before starting.
   - Chock wheels and tracks and work on firm, level ground.
   - Release stored energy in hydraulics, springs and accumulators first.
   - Never work alone under a machine.

**TBT-PLA-038 · Vacuum Excavation Units**
Purpose: Vacuum excavation reduces service strikes but brings high-pressure air, water and suction hazards.
Key points:
   - Only trained operatives may use vacuum excavation equipment.
   - Keep hands, feet and clothing away from the suction nozzle and the air lance.
   - Treat the air lance as capable of penetrating skin and causing air embolism.
   - Wear the full PPE specified including eye, face and hand protection.
   - Manage the spoil tank discharge safely and away from people and drains.
   - Continue to use CAT and Genny and trial holes — vacuum excavation is not a substitute for locating.

**TBT-PLA-039 · Banksman & Signaller Duties**
Purpose: The banksman is the operator's eyes, and standing in the wrong place makes them the casualty.
Key points:
   - Only trained banksmen may direct plant, and one banksman controls one machine at a time.
   - Stand where you can see the hazard and the operator can see you — never in the path of travel.
   - Use agreed, standard hand signals and keep them clear and unhurried.
   - Wear the correct high-visibility clothing and make yourself distinguishable.
   - If you lose sight of the operator, or they lose sight of you, stop the movement.
   - Anyone can signal stop; only the banksman signals go.

**TBT-PLA-040 · Plant Clearance Under Structures & Services**
Purpose: Machines strike overhead lines, gantries, canopies and soffits because nobody checked the height.
Key points:
   - Survey the route for overhead lines, pipe bridges, canopies and low structures before moving plant.
   - Fit and observe goal posts, height restriction barriers and warning signage.
   - Lower booms, jibs and tipping bodies fully before travelling.
   - Treat all overhead lines as live and observe GS6 clearance distances.
   - Use a banksman where clearances are tight and never guess a gap.
   - Stop and report immediately if any part of the machine contacts a structure or line.

---

## 5. Downloadable / viewable talk = the branded PDF

Every talk renders to the professional Project Planner PDF (logo, branded header, purpose, key control points, references, and an **auto-populating attendee sign-off table** — one row per operative with Name · Trade · Signature · Date/time; pending operatives show as empty rows). See `toolbox-talk-template.pdf` (blank) and `toolbox-talk-example-signed.pdf` (filled).

## 6. Seeding checklist

1. `Trade` enum on `OperativeProfile.trade`.
2. Extend `ToolboxTalk` with `source/ownerContractorId/status`.
3. Import §4 entries as `source:"library"`. General → `isGeneral:true`.
4. General talks default `approved`; trade talks per competent-person review.
5. Universal library browse; operative trade-filter at issue time.
6. Render talks + sign-off sheet with the branded PDF template.

> **Gate restated:** a talk is issuable only when `status == approved`, owned by a competent person.
