# Smart Log — Presentation Pack

Tech Titans · ICT3411 / COM3405 · Rajarata University of Sri Lanka
Supervisor: Mrs. A.K.N.L. Aththanagoda

**Read your own section. Then read "The database, explained simply" and
"Panel questions" — those are for everybody.**

---

## 0. Before the day — the checklist

| # | Do this | Why |
|---|---|---|
| 1 | Deploy the Firestore rules | Without it nothing reaches the cloud and the live demo fails |
| 2 | Rehearse the airplane-mode demo on the real phone | The timing of reconnection is the only fiddly part |
| 3 | Open Profile once and change a setting | SharedPreferences only writes a key once it is set |
| 4 | Save one stack | So the saved-records and report screens are not empty |
| 5 | Install `scrcpy` and test it | Puts the phone on the projector next to VS Code |

```bash
npx firebase-tools deploy --only firestore:rules --project smart-log-a7a8b
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" "https://firestore.googleapis.com/v1/projects/smart-log-a7a8b/databases/(default)/documents/users?pageSize=1"
```

`403` means the rules are live and correct. `200` means anyone can read your
users' data — do not present until it says 403.

---

## 1. What Smart Log is, in one paragraph

Anyone can say this if asked to open.

> Smart Log is a mobile application for the timber trade. A sawmill owner or
> a timber merchant points their phone at a log; the app measures it, works
> out its volume in the units the Sri Lankan trade actually uses, finds
> surface defects, and calculates the best way to saw that log into boards.
> Everything is stored on the phone first so it works in a timber yard with
> no signal, and copied to the cloud so nothing is lost if the phone is.

**Three research components:**

1. **LiDAR measurement** — measuring a log from a phone scan
2. **Defect detection** — finding knots, cracks and rot from photographs
3. **Optimal cutting** — deciding how to saw the log for maximum yield

---

## 2. The database, explained simply

**Everybody must be able to answer this.** It is the easiest thing for a
panel to probe and the easiest place to look unprepared.

### There are three places data lives

| Where | What it holds | Why there |
|---|---|---|
| **SQLite** (on the phone) | stacks, logs, defects, cutting patterns, reports, users, diagnostics, sync queue | Relational data with relationships between rows. Works with no signal. |
| **SharedPreferences** (on the phone) | measurement settings, device id, saw presets | Simple key/value settings. Not rows, so a table would be the wrong shape. |
| **Firestore** (cloud) | a mirror of the above, per user | So history survives a lost phone and follows the user to a new one |

> **Say this:** "The phone is the source of truth. The cloud is a mirror of
> it. That order matters — a timber yard has no signal, and a measurement
> must never fail because the internet is down."

### The eight SQLite tables

| Table | What one row is | Key columns |
|---|---|---|
| `users` | The signed-in person's local profile | `uid` (PK), name, email, phone, company |
| `stacks` | A batch of logs sold together | `id` (PK), name, totalVolume, totalCost, customerName |
| `logs` | One physical log | `id` (PK), `stackId` (FK), diameter, lengthFeet, volume, **provenance columns** |
| `defects` | One flaw on one log | `id` (PK), `logId` (FK), kind, **confidence**, automatic |
| `cutting_patterns` | The chosen sawing plan for a log | `logId` (FK, **unique**), strategy, boardCount, yieldPercent, wasteVolume |
| `reports` | An exported PDF or CSV | id, stackId/logId, format, filePath, createdAt |
| `diagnostics` | An error or a timing | kind, module, code, message, durationMs |
| `sync_outbox` | Work waiting to reach the cloud | entity, operation, localId, attempts, lastError |

### The four things worth pointing out

**1. `logs` stores *how* it was measured, not just the number.**
Columns `measurementSource`, `rawDiameterInches`, `deductionInches`,
`measurementQuality`. If a buyer disputes a volume six months later, you can
show whether it came from the sensor or the keyboard, and what bark
allowance was applied at the time. **A volume without provenance cannot be
defended.**

**2. `defects.confidence` is stored with every prediction.**
That is what lets the cutting engine apply its 0.60 threshold — only defects
the model is reasonably sure about are turned into no-go zones.

**3. `cutting_patterns.logId` is UNIQUE.**
The specification says a log holds at most one saved pattern and
recalculating replaces it. That rule is enforced by the *schema*, not by
remembering to delete the old one in code.

**4. `sync_outbox` is not data — it is infrastructure.**
This is the table to be proud of. It is why the app works with no signal.

### The sync queue, in plain words

> When you save a log, two things happen in the same moment: the log goes
> into SQLite, and a row goes into `sync_outbox` saying "this needs
> uploading". A background worker empties that queue whenever there is a
> connection. If there is no connection, the row simply waits. Nothing is
> ever lost because the signal was bad.

**Why it is a queue and not just "try to upload":** an upload that fails
with no record of the failure is data silently gone. We had exactly that bug
— every upload was being rejected and nothing told us, because the errors
were being swallowed.

### Migrations — six versions

The database has been migrated six times, each with a written reason:

- **v2** — cost and timestamps
- **v3** — measurement provenance (the audit trail above)
- **v4** — customer name and remarks on a stack
- **v5** — `cloudId` on every row + the sync outbox
- **v6** — users, defects, cutting_patterns, reports, diagnostics

> **If asked "why cloudId?":** without it, restoring onto a new phone gives
> every row a fresh local id, and the next upload creates a *second* cloud
> document. The backup would grow a duplicate copy of itself with every
> reinstall.

---

## 3. Individual scripts

Each section covers the functional requirements assigned to that member on
the IRAF, plus their research responsibility.

---

### H.M.S.S.W. Bandara — ICT/2022/145 (Index 5946)

**Your functional requirements: 07, 08, 09, 10, 11, 12**
**Your research: LiDAR data cleaning + 3D shape; optimal cutting model**

You own **the scan**: from pressing the button to a volume on screen.

**FR07 — Check LiDAR availability and permissions.** Before anything, the
app asks the device whether it has the sensor and asks the OS for camera and
motion permission. If either is missing it does not fail — it redirects to
manual entry. *Say: "the app degrades to manual entry rather than blocking
the user."*

**FR08 — Activate LiDAR and guide the scan.** An ARKit session starts and
the screen guides the user around the log, tracking angular coverage live.

**FR09 — Capture point cloud.** Depth frames, RGB frames and camera
transforms are captured and reprojected into one world coordinate frame,
accumulating a single point cloud.

**FR10 — Validate scan quality.** Coverage and point density are checked
against a threshold. Below it, the user is asked to rescan and the bad data
is discarded rather than kept.

**FR11 — Process and calculate volume.** This is your research contribution.
The pipeline:

1. **Voxel downsampling** — reduce millions of points to a manageable, evenly
   spaced set
2. **Statistical outlier removal** — drop stray points (dust, background)
3. **RANSAC ground-plane removal** — delete the ground the log sits on
4. **PCA** — find the log's principal axis and rotate into a log-aligned frame
5. **Slice into cross-sections** along that axis
6. **Least-squares circle fit** per slice → sectional diameter + residual
7. **Sum the sectional volumes** → total volume

> **Key point to make:** we model the log as a **sequence of tapered circular
> sections, not one cylinder**. A real log is thinner at one end. Treating it
> as a cylinder of average diameter overstates volume.

**FR12 — Display and save.** The result is shown with a confidence
indicator, and only saved once the user confirms. The save works with no
internet.

**Your second research area — the cutting model.** The engine considers two
real sawmill strategies and costs both:

- **Cant sawing** — square the log into a block first, then saw the block
  into boards. Uniform, square-edged boards.
- **Live sawing** — saw straight through without turning the log. Fewer
  handling steps, often more timber, but widths vary.

> **The insight worth stating:** we score on **volume, not board count**.
> Counting boards rewards cutting many narrow ones, which is the opposite of
> what a mill wants.

---

### K.G.T.N. Bandara — ICT/2022/081 (Index 5685)

**Your functional requirements: 01, 02, 03, 04, 05, 06, 23**
**Your research: volume calculation + accuracy vs tape measurements**

You own **accounts and reporting** — the first thing a user sees and the
last thing they produce.

**FR01–02 — Registration and validation.** The form validates before
anything is sent: all fields present, email format correct, and the password
rule — **at least 8 characters with an uppercase letter, a lowercase letter,
a digit and a special character**. A strength bar fills as the user types.

> **Worth saying:** Firebase itself only enforces six characters and nothing
> else. Every other rule is enforced in our own validator, which is a pure
> function so it can be tested exhaustively.

**FR03 — Duplicate email.** Checked by Firebase Authentication; email must be
unique across all accounts.

**FR04 — Create account.** Firebase creates the account and returns a token.
**We then write a local profile record into the `users` table** — name,
email, phone, company. **No password is ever stored on the device**;
credentials stay in Firebase and the session token in the platform keystore.

**FR05–06 — Login and redirect.** Credentials go to Firebase; on success the
local profile is loaded and the user lands on the dashboard. The failure
message deliberately does **not** say whether the email or the password was
wrong — telling an attacker which half was right is a way to enumerate
accounts.

**FR23 — Reports, PDF and CSV.** Both formats are supported:

- **PDF** — a formatted document to print or hand to a buyer
- **CSV** — one row per log, opens in Excel for reconciliation

Every export writes a row into the `reports` table — id, format, file path,
volume, cost, timestamp — so a document already given to a buyer can be found
and re-sent rather than regenerated from data that may have changed.

> **A detail worth mentioning if asked about CSV:** values containing commas
> are quoted and embedded quotes doubled. A customer named `Perera, W.` would
> otherwise shift every column after it and silently corrupt the volumes.
> The file also starts with a byte-order mark so Excel reads it as UTF-8.

**Your research — accuracy.** Volume from the scan is compared against manual
tape measurements on the same logs. Two volume methods are supported and the
user chooses in their profile:

- **Standard geometric** calculation
- **The Sri Lankan reference table** (quarter-girth / Hoppus measure)

> **If the panel asks why not Smalian's formula / cubic metres** (as the EC04
> states): the trade this app serves quotes in **adi and angal** from a
> printed ready-reckoner. Matching the book the buyer already uses matters
> more commercially than matching a textbook formula. The standard method is
> still available as a setting. **Be honest that this is a deliberate
> deviation from the document, and say why.**

---

### R.S.R. Ranathunga — ICT/2022/139 (Index 5740)

**Your functional requirements: 16, 17, 21, 22, 25, 26**
**Your research: building and training the defect detection model**

You own **manual entry, retrieval, security and monitoring**.

**FR16–17 — Manual entry and validation.** When there is no LiDAR — or the
user simply prefers it — dimensions are typed. Values are validated as
numeric, positive and in range, converted, and the volume computed. This
path is always available, on any device.

**FR21 — Browse and search.** Saved stacks and logs are listed newest first,
with **keyword search** (name, customer, remarks) and a **date range
filter**.

> **Worth stating:** filtering happens **in SQL, not in Dart**. Loading every
> row into memory to throw most away gets slower exactly as the user builds
> up history. The requirement is retrieval under two seconds at 500 entries;
> doing it in the database is how that target survives.

**FR22 — Full log detail.** A saved log now opens with its defects and its
cutting pattern, because both are stored in their own tables with a foreign
key back to the log.

**FR25 — Security.** Three things:

- The session token is stored in the **platform keystore**, not app storage
- **No password is ever written to SQLite** — you can show the `users` table
  has no password column
- Logout invalidates the Firebase session, clears the cached token and the
  in-memory state, and **works with no internet**

**FR26 — Performance monitoring.** Every major operation is timed and the
result written to the `diagnostics` table. The store keeps the **200 most
recent entries** and discards older ones — trimmed on write, so the file
cannot quietly grow for months.

> **A detail that impresses:** we report the **90th percentile, not the
> average**. With seventeen fast runs and three slow ones, the mean is about
> 145ms and looks fine; the 90th percentile reports the slow tail, which is
> the thing the target actually exists to catch.

**Your research — the defect model.** ResNet-50, fine-tuned, five classes:
Healthy, Knot, Crack, Rot, Other. Target is a macro-averaged F1 of 0.85.
Evaluation is on a held-out test partition **split at log level** — images of
the same log must not appear in both training and test, or the score
measures memorisation rather than recognition.

> **Be straight about status:** the classifier is specified and the app's
> defect pipeline is built and storing records with confidence values, but
> the trained model is not yet running on the device. **Manual defect marking
> works today and feeds the cutting engine.** Say what is done and what is
> next; a panel respects that far more than a vague claim.

---

### A.K.A. Sanjula — ICT/2022/093 (Index 5696)

**Your functional requirements: 13, 14, 15, 24**
**Your research: showing detected defects on the image; on-device model**

You own **defect detection end to end** — capture, inference, display, and
what happens when any of it fails.

**FR13 — Capture images.** Either live from the camera or from the RGB
frames retained during a scan. Each image is checked for blur and brightness
and rejected if it fails, with a prompt to retake. Minimum 1920×1080.

**FR14 — Run the model.** Each accepted image is resized to 224×224 and
normalised with the ImageNet channel mean and standard deviation — the same
normalisation used in training, or the network sees a different distribution
than it learnt. Softmax gives a probability per class; the highest wins.
**Confidence below 0.60 is marked uncertain.** Inference runs on the device
and needs no internet.

**FR15 — Display with CAM overlay and save.** A class activation map
highlights the regions that most influenced the prediction, overlaid on the
source image.

> **Why CAM matters — say this:** it makes the model's decision inspectable.
> A sawmill owner will not act on "this log has rot" from a black box. Being
> able to see *where* the model is looking is what makes it trustworthy — and
> it also catches a model that is right for the wrong reason, such as keying
> on the background instead of the timber.

Every prediction is stored in the `defects` table **with its confidence**,
its source image path, its overlay reference, and a foreign key to the log.

**FR24 — Error handling.** This is genuinely yours and worth a moment:

1. Exceptions are caught **at the module where they occur** — scan, model or
   optimisation
2. Classified as a sensor, model or optimisation failure
3. Mapped to a **readable message and a recovery action** — rescan, retry,
   retake, adjust constraints
4. Recoverable session data is preserved
5. A diagnostic row is written with timestamp, error code and module

> **Two rules to quote:** *a raw exception trace is never shown to the user*,
> and *no partial or invalid record is ever persisted as a result of a
> failure*.

**Your research — on-device deployment.** The model runs on the phone rather
than a server. Three reasons: it works in a timber yard with no signal, no
photographs of a customer's stock leave the device, and there is no
per-inference cost.

---

### S.M.S.C. Seneviratne — ICT/2022/086 (Index 5690)

**Your functional requirements: 18, 19, 20**
**Your research: dataset collection and accuracy testing**

You own **the cutting optimisation** and **how we know any of this works**.

**FR18 — Accept constraints.** Board width, board thickness and blade
thickness (kerf). Validated as positive, and board dimensions must be
smaller than the log's small-end diameter. The form remembers the last
settings, so a mill cutting the same product daily re-enters nothing.

There are **two modes**:

- **Exact size** — every board the same size, for filling an order
- **Maximum yield** — you fix only the thickness and the app takes the widest
  boards the log will give

> **Why the second mode exists:** a mill that cuts one thickness all day does
> not care about exact widths — it wants the most timber out of the log. That
> is a real business, and the first mode cannot serve it.

**FR19 — Run the optimisation.** The algorithm:

1. Represent the cross-section from the **traced outline of the real log
   face**, not an assumed circle
2. Turn defects with confidence **≥ 0.60** into exclusion regions
3. Generate candidates by varying the **rotation angle** and the **cut phase
   offset**
4. Score each on **recovered board volume**, applying the kerf between
   boards and excluding defects
5. Take the best

> **The honest framing:** this is a **near-optimal** solution found by
> searching a discretised parameter space, not a proven global optimum. Say
> "near-optimal" — a panel will respect the precision and may well ask why.

**Two technical points worth having ready:**

- **Kerf is real timber.** Every saw pass turns 3mm of wood into sawdust. On
  fourteen cuts through a 3m log that is a measurable volume, and it is
  subtracted, not ignored.
- **The honest yield number is the widest rectangle inside each slab.** Mills
  saw flitches with wane and edge them afterwards, so the board that actually
  gets sold *is* that inscribed rectangle.

**FR20 — Display and save.** The pattern is drawn **on the user's own
photograph, inside the boundary they traced**, with the cant highlighted in
its own colour because it is the first cut the sawyer physically makes.
Shown alongside: yield percentage, usable volume, waste, sawdust, edgings,
and saw passes. On save it goes into `cutting_patterns` — one per log,
recalculating replaces it.

**Your research — the dataset and testing.** Images collected and labelled
at **log level**, split into train/validation/test so no log appears in two
splits. Evaluation is macro-averaged F1, per-class precision and recall, and
a confusion matrix. Volume accuracy is validated against tape measurements
on the same physical logs.

> **You should be the one to mention the test suite: 315 automated tests,
> all passing.** That is your accuracy-and-testing responsibility in its most
> visible form.

---

## 4. The live demonstration

Three acts, about six minutes.

### Act 1 — The design (VS Code, 1 min)

Open `lib/database/local_db.dart`, scroll to `onUpgrade`. Six migrations,
each with a written reason. Then `firestore.rules` — one ownership rule.

### Act 2 — The proof (phone + Firebase console, 3 min)

Phone mirrored via `scrcpy` on one side, this open on the other:

https://console.firebase.google.com/project/smart-log-a7a8b/firestore/data

1. Save a log → **it appears in the console live**, no refresh
2. **Airplane mode.** Save three more → app does not stall, logs are visible
3. Profile → *"3 items waiting"*
4. Open the developer screen (Profile → tap the version line ×5) → the
   `sync_outbox` table with three rows, named
5. **Wifi back on** → without touching anything, the rows vanish and three
   documents appear in Firestore

### Act 3 — The verification (VS Code terminal, 1 min)

```bash
flutter test
```

**315 tests, all passing.** Then show the EC04 file specifically — the test
names read as the requirements themselves:

```bash
flutter test test/ec04_requirements_test.dart
```

---

## 5. Panel questions — and your answers

### On the database

**Q: Why SQLite and Firebase both? Isn't that duplication?**
> They do different jobs. SQLite is the source of truth and works with no
> signal — essential in a timber yard. Firestore is a backup so a lost phone
> does not mean lost records. They are not duplicates; one is authoritative
> and the other is a mirror of it.

**Q: What happens if the phone has no internet for a week?**
> Everything keeps working. Each save also writes a row into `sync_outbox`.
> When a connection returns, that queue is emptied oldest-first. We can
> demonstrate this — we do it in the demo with airplane mode.

**Q: Why only three tables?** *(if they saw an earlier version)*
> There are eight. `users`, `stacks`, `logs`, `defects`, `cutting_patterns`,
> `reports`, `diagnostics` and `sync_outbox`.

**Q: Is the data normalised?**
> Yes. `logs` references `stacks` by foreign key; `defects` and
> `cutting_patterns` reference `logs`. Settings are key/value so they live in
> SharedPreferences rather than being forced into a table.

**Q: How do you handle two devices with the same account?**
> Cloud document ids are `deviceId_localId`, so two phones can never collide
> on the same document. Restore is one-way and only onto an empty database —
> we do not do live two-way merge, because deciding which of two edited
> versions wins is a question only the user can answer.

**Q: Is user data secure?**
> Firestore rules allow a user to read and write only their own node — we can
> show the rules file. No password is stored on the device. The session token
> is in the platform keystore.

### On measurement

**Q: How accurate is it?**
> That is what our evaluation measures — scan results against tape
> measurements on the same logs. We report the error distribution, not a
> single number.

**Q: A log is not a perfect cylinder. How do you handle taper?**
> We slice the point cloud into cross-sections along the principal axis, fit
> a circle to each, and sum the sectional volumes. Modelling it as one
> cylinder would overstate the volume.

**Q: Why the minimum girth for cutting rather than the average?**
> A full-length board has to fit the whole log. The thinnest section is
> genuinely the limiting one, so using it is correct, not conservative.

**Q: What if the phone has no LiDAR?**
> Manual entry, always available. And the photo-tracing path works on any
> camera — the tape reading gives the scale.

### On defect detection

**Q: Why ResNet-50?**
> A well-understood architecture with strong ImageNet pretraining, which
> matters when the dataset is small. Fine-tuning is far more data-efficient
> than training from scratch.

**Q: What is your accuracy?**
> Target is macro-averaged F1 of 0.85. Be honest about current status.

**Q: How do you know it is not memorising?**
> The split is at **log level**, not image level. Images of the same log
> never appear in both training and test.

**Q: What if the model is wrong?**
> Every prediction is stored with its confidence, anything below 0.60 is
> marked uncertain, and only defects at 0.60 or above are turned into cutting
> exclusions. The CAM overlay lets a user see what the model looked at and
> overrule it.

### On cutting optimisation

**Q: Is this the optimal solution?**
> Near-optimal. We search a discretised space of rotation angles and cut
> offsets and take the best candidate. A proven global optimum for
> irregular cross-sections is a much harder problem.

**Q: Why two strategies rather than one answer?**
> Because a mill without a resaw physically cannot cut a cant. We cost both
> and let the sawyer choose on their own terms.

**Q: Do you account for the saw blade?**
> Yes. Kerf is subtracted between every board, and reported separately as
> sawdust volume so a mill can see what a thinner blade would be worth.

### Hard questions — be ready

**Q: What does not work yet?**
> Have a straight answer. The trained defect model is not yet running on the
> device; manual defect marking works and feeds the cutting engine. LiDAR
> requires an iPhone Pro. Two-way live sync between devices is out of scope
> for this phase.

**Q: What was the hardest bug?**
> A good one to have ready. Ours: the Firestore security rules granted access
> to `users/{uid}` only — and **Firestore rules do not cascade into
> subcollections** — so every stack and every log was being rejected. Because
> the errors were being swallowed, the app looked like it was working while
> nothing had ever been backed up. We fixed the rules, and we made failures
> visible so it can never hide again.

**Q: How do you know your code works?**
> 315 automated tests covering the volume pipeline, the ellipse fitting, the
> cutting engine, the sync queue and the requirements themselves. We can run
> them now.

**Q: What would you do differently?**
> Make failures visible from the start. Every silent `catch` we wrote cost us
> more time later than an error message would have.

---

## 6. Rules for the room

- **Never say "it should work".** Either it does and you show it, or it does
  not and you say what is next.
- **If you do not know, say so** and offer who on the team does.
- **Do not talk over each other.** Whoever owns that FR answers.
- **Have the app already open** on the screen you will need next.
- **If a live demo fails**, do not debug in front of them. Say "let me show
  you the test that covers this" and run it.
