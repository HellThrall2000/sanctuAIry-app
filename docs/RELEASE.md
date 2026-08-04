# Shipping sanctuAIry

Everything between a working debug build and a Play Store listing. Work through
it in order — later steps depend on identifiers produced by earlier ones.

| | |
| --- | --- |
| Application ID | `com.sanctuairy.app` — **permanent once published** |
| Display name | sanctuAIry |
| Store assets | [`store/`](../store) — 512×512 icon, 1024×500 feature graphic |
| Min / target SDK | 24 / 36 |

## Where each piece lives

A common confusion, worth settling first: **nothing "hosts" the app the way a
website is hosted.** This is a compiled Android binary, not a web app, and four
separate things live in four separate places.

| | Lives at | Cost |
| --- | --- | --- |
| **Source code** | GitHub | Free |
| **The app itself** (`.aab`) | Google Play — you upload it, Play stores it and serves it to every installer | One-off **$25** developer registration |
| **The model** (2.41 GB) | Cloudflare R2, downloaded on first run | Free (zero egress) |
| **Accounts + usage data** | Firebase Auth and Firestore | Free (Spark) |

**Firebase does not host the app.** It is a login service and a database, nothing
more. Firebase *Hosting* exists but serves static websites, which this is not —
it plays no part here.

The one unavoidable payment is the **$25 one-time Google Play developer
registration**, which does require a card. There is no free route onto the Play
Store. (Apple's is $99/year, recurring.)

---

## 1. The upload key

Generate it yourself. It is deliberately not in this repository and I have not
created one for you: the signing key is the app's identity for the rest of its
life, and a password that has passed through a chat log is not a secret.

```bash
keytool -genkey -v -keystore sanctuairy-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Put it somewhere outside the repository, then create `android/key.properties`:

```properties
storeFile=C:/keys/sanctuairy-upload.jks
storePassword=…
keyPassword=…
keyAlias=upload
```

`android/key.properties`, `*.jks` and `*.keystore` are already gitignored.
`bundleRelease` fails loudly if this file is missing rather than quietly
producing a debug-signed bundle that Play rejects on upload.

**Turn on Play App Signing** when you create the listing. Google then holds the
real signing key and you only ever hold the upload key — which means losing your
keystore costs you a support ticket instead of the app. This matters again in
step 3.

---

## 2. Host the model

The companion is a 2.41 GB `.litertlm`. It cannot ship inside the bundle, so the
app downloads it on first run — see
[`lib/services/model_download_service.dart`](../lib/services/model_download_service.dart).

**Already configured**, pointing at Cloudflare R2. The rest of this section
matters only if you move it.

### Hosts, with measured numbers

| Host | Verdict |
| --- | --- |
| **Cloudflare R2** | ✅ **In use.** Zero egress fees, `Range` verified. Needs a card to sign up |
| OCI Object Storage | Works — **2.5–3.9 MB/s** to the test tablet. 20 GB free, 10 TB/month egress |
| Hugging Face | Works — **751 KB/s with a 3-minute stall at 93%** on the same tablet |
| Firebase Storage | ❌ ~1 GB/day egress on Spark. One user exhausts it |
| GitHub Releases | ❌ 2 GiB cap per asset; this file is 2.41 GB |
| Git LFS | ❌ 1 GB bandwidth/month free |
| Google Drive | ❌ Virus-scan interstitial, no usable ranges |

### The two R2 URLs are different, and it matters

| | URL | Auth |
| --- | --- | --- |
| **Upload** | `<account>.r2.cloudflarestorage.com` (S3 API) | SigV4 signed — credentials required |
| **Download** | `pub-<hash>.r2.dev` | None |

There is no anonymous write to R2, and "Public" makes a bucket *readable*, never
writable. So uploading always needs an **R2 API token** (R2 → Overview →
*Manage R2 API tokens*, on the right under Account details — **not** in the
bucket's own settings, which is where everyone looks first). Scope it to Object
Read & Write on the one bucket.

The dashboard's upload button caps at 300 MB, so it cannot be used for this file.
Upload over the S3 API with credentials in `~/.aws/credentials`:

```bash
pip install boto3
python scratch/r2_upload.py     # multipart, progress, verifies size afterwards
```

**Set `request_checksum_calculation="when_required"` in the botocore `Config`.**
botocore ≥ 1.36 sends CRC32 integrity headers by default and R2 answers them with
`501 Not Implemented` — the most common way an R2 upload fails for no obvious
reason.

### Enabling downloads

Bucket → **Public Development URL → Enable**. Without it every download is a 401.

> **`r2.dev` is rate-limited and Cloudflare documents it as unsuitable for
> production.** It is correct for testing and a small beta. Before launch, attach
> **Custom Domains → Add** on a domain in your Cloudflare account (~£10/yr):
> unmetered, edge-cached, no throttle. Egress is free either way, so that domain
> is the entire cost of this route.

Also confirm the object's storage class is **Standard**, not Infrequent Access —
IA charges per GB retrieved, on a file every install downloads.

CORS is not needed; it is browser-enforced and this is a native app.

### Verify before shipping

```bash
curl -s -o /dev/null -D - -H "Range: bytes=0-99"   "https://pub-<hash>.r2.dev/gemma-4-E2B-it.litertlm"   | grep -iE "^HTTP|content-range"
```

Want `206 Partial Content` and `content-range: bytes 0-99/2588147712`. A `200`
means ranges are ignored and every interruption restarts from zero; `401`/`404`
means the public URL is not enabled.

**Check the User-Agent too.** Cloudflare's bot rules reject some clients: a
request identifying as `Python-urllib/3.13` gets **403** from this exact bucket,
while `Dart/3.12 (dart:io)` — what the app actually sends — gets `206`. Test with
the UA your client uses, not with whatever is convenient.

### Updating the size and hash

Both live in `ModelCatalog`. The size drives the free-space pre-flight check; a
stale hash makes every download look corrupt and be deleted on arrival.

```bash
stat -c%s gemma-4-E2B-it.litertlm
sha256sum gemma-4-E2B-it.litertlm
```

### Mirrors

[`ModelRelease.mirrors`](../lib/services/model_catalog.dart) takes alternates,
tried in order when the primary fails, keeping bytes already fetched. The shipped
catalog has **none** — R2 is the single source. Any mirror added must be
**byte-identical**, because a download resumes against whichever host answers.

---

## 3. Firebase

Free (Spark) plan throughout. Accounts and usage counting are entirely optional —
the app builds and runs without any of this, and
[`FirebaseGateway`](../lib/services/firebase_gateway.dart) reports itself
unavailable at runtime.

1. Create a project at <https://console.firebase.google.com>.
2. **Authentication → Sign-in method**: enable **Anonymous** *and* **Google**.
   Anonymous is not optional — it is the default account every install gets, and
   without it usage goes uncounted. Its absence shows up as
   `operation-not-allowed` in the log.
3. **Add an Android app** with package name `com.sanctuairy.app`.
4. Add SHA-1 fingerprints — **both of them**:

   ```bash
   # Your upload key
   cd android && ./gradlew signingReport
   ```

   …and then, *after your first upload*, the **App signing key certificate**
   SHA-1 from **Play Console → Test and release → Setup → App signing**.

   > This is the single most common way Google Sign-In ships broken. It works
   > perfectly in testing on the upload key, then fails for every real user,
   > because Play re-signs the app with its own key and Firebase has never seen
   > that fingerprint. Add both.

5. Download `google-services.json` into `android/app/`. It is read by the Gradle
   plugin, which is applied only when the file exists.
6. **Firestore → Create database** in production mode, then deploy the rules —
   do not leave the defaults, which are either world-writable for 30 days or
   deny the app outright:

   ```bash
   firebase deploy --only firestore:rules
   ```

   The policy is in [`firebase/firestore.rules`](../firebase/firestore.rules):
   a signed-in user may touch exactly one document, their own, with an
   allowlisted set of fields.

`google-services.json` is not a secret — it holds public identifiers, and Google
publishes this guidance. Security comes from the rules above and from the
package-name plus SHA-1 restriction on the API key, not from hiding the file.
The keystore from step 1 is the thing that is actually secret.

### What the data looks like

```
users/{uid}                    profile: accountKind, email, displayName,
                               appVersion, platform, firstSeenAt, lastSeenAt
users/{uid}/daily/2026-08-03   activeSeconds, activeHours, sessions,
                               messages, journalEntries, modelLoads
```

One document per calendar day, keyed on the **local** date, holding that day's
absolute totals. So "hours used per day per user" is a single collection-group
query, and there is no content anywhere in it.

### Staying inside the free tier

Spark allows 20,000 Firestore writes a day. `UsageMetrics` keeps a local ledger
and syncs **once, when the app is backgrounded** — two writes per session (the
profile and the day) rather than one per message. That is around 10,000 sessions
a day before you approach the limit. Analytics events are free and unlimited.

### Offline

The local ledger is the source of truth, so usage is recorded whether or not
there is a network, and pushed when one appears — a fortnight offline syncs as a
fortnight of daily documents. Because each day is written as an absolute total
rather than an increment, a duplicated or late-arriving write converges on the
right answer instead of double-counting. A day is deleted from local storage as
soon as the server acknowledges it, so the app never holds a second copy of data
that is already safe.

---

## 4. Build

```bash
flutter clean
flutter build appbundle --release
# build/app/outputs/bundle/release/app-release.aab
```

Bump `version:` in `pubspec.yaml` before every upload — Play rejects a
`versionCode` it has already seen. `1.0.0+1` → `1.0.0+2`.

To sanity-check a release build on a device first:

```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

R8 (`minifyEnabled`) is deliberately **off**. The saving is small — this APK is
native libraries and the Flutter engine, not Java bytecode — and litertlm reaches
its classes through JNI, which R8 cannot see. A stripped symbol surfaces as a
crash inside `nativeCreateEngine` that looks exactly like the low-memory kills
this project already spent weeks chasing. Only turn it on behind a full
on-device model load test.

---

## 5. Play Console

### Data safety — read this before filling the form

The app is unusually clean here, but **"we store no personal data" is not the
answer to give**, and getting this wrong is a suspension risk rather than a
matter of taste. Under both the Play Data Safety taxonomy and GDPR, an email
address, a display name and a persistent user ID *are* personal data. Declare:

| Data type | Collected | Why | Notes |
| --- | --- | --- | --- |
| Email address | Yes, **required** | Analytics | Sign-in is mandatory on Android |
| Name | Yes, **required** | Analytics | As above |
| User IDs | Yes | Analytics | The Firebase uid |
| App interactions | Yes | Analytics | Daily hours, session counts, action counts |
| Crash logs / diagnostics | No | | The engine log stays on the device |
| **Messages** | **No** | | Never leaves the device |
| **Health and fitness** | **No** | | Never leaves the device |
| **Photos, contacts, location, files** | **No** | | Not collected at all |

Also declare: data **is** encrypted in transit, and users **can** request
deletion (the account dialog does it in-app).

Mark email and name as **required, not optional**, because on Android they are:
[`Consent.requiresAccount`](../lib/services/consent.dart) gates the app behind
Google sign-in on that platform. Declaring them optional when the app will not
open without them is the kind of mismatch the Data Safety review actually
catches. On iOS the same fields are genuinely optional — see the iOS section.

Two consequences of the Android gate worth knowing before you ship it:

- **The app cannot be opened offline on a fresh install.** Sign-in needs the
  network, so a first launch with no connection stops at the welcome screen.
  Every launch after that is offline-capable as before. For an app whose pitch is
  that it works without a connection, that first-run exception is worth being
  deliberate about.
- **It counts only the people who agree.** Install figures will cover users who
  completed sign-in, not everyone who installed. Play Console's own install count
  remains the number for the latter.

The claim that conversations and diary entries never leave the device is
structural rather than a promise — `UsageMetrics` has no method that accepts
user text. See the comments in
[`lib/services/usage_metrics.dart`](../lib/services/usage_metrics.dart).

### Foreground service — this one needs written justification

The app declares a **`specialUse`** foreground service
([`GenerationService.kt`](../android/app/src/main/kotlin/com/sanctuairy/app/GenerationService.kt)).
Play asks you to justify that type in the console, and a blank or vague answer
is a rejection. Paste something close to this:

> sanctuAIry runs a language model entirely on the user's device. When the user
> sends a message, the reply is computed locally on the CPU and takes roughly
> 15–30 seconds in the foreground and up to 90 seconds when backgrounded. The
> foreground service exists solely to let that reply finish if the user leaves
> the app, and stops itself the moment it completes. No network request is made
> and no data leaves the device. There is no predefined foreground service type
> for local model inference.

**Why not one of the standard types.** Both alternatives were tried or
considered and rejected on the evidence:

| Type | Why not |
| --- | --- |
| `shortService` | **Measured failure.** Capped at ~3 minutes and then force-stopped. A backgrounded reply took 180 s on the test device; one run finished, the next crossed the ceiling, `onTimeout` fired, and the process was reclaimed mid-generation — losing the reply. Logs showed `VM exiting with result code 0`. |
| `dataSync` | Would likely pass review with less scrutiny, and is what several on-device AI apps use. But nothing is being synced or transferred, so it is a false declaration — and a false declaration is a worse position to be in at review than an honest one that needs explaining. |

**If Play rejects `specialUse`**, the fallback order is: (1) reply with the
justification above and a link to the source file; (2) if still refused, switch
to `dataSync` and accept the inaccuracy; (3) as a last resort drop the service
entirely — the app still works, because an unanswered message is detected and
answered on next launch (`_answerUnansweredMessage`). Option 3 costs users a
reply whenever they switch away mid-generation, which is common.

### Permissions, and what each is for

Expect to be asked about these; none are in Play's restricted set.

| Permission | Used for |
| --- | --- |
| `INTERNET` | The one-time model download, and Google sign-in |
| `ACCESS_NETWORK_STATE` | Wi-Fi-only default for a 2.4 GB download |
| `WAKE_LOCK` | Held during generation so the CPU does not idle mid-reply |
| `FOREGROUND_SERVICE` + `..._SPECIAL_USE` | Finishing a reply after the user leaves — see above |
| `POST_NOTIFICATIONS` | Check-ins, and telling the user a reply arrived while they were away |
| `RECEIVE_BOOT_COMPLETED` | So a pending check-in survives a reboot |

`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` was **removed** — it was declared but
never called, and it *is* on Play's restricted list.

### Everything else

- **Privacy policy URL** — mandatory. Publish [`docs/PRIVACY.md`](PRIVACY.md)
  somewhere public (GitHub Pages is fine) and paste the URL.
- **Health apps declaration** — a mental-health companion falls under Play's
  health policy. Expect extra review. Do not describe the app as providing
  medical advice, diagnosis or treatment; it is a journalling and
  self-reflection companion. The boundary enforcement in
  [`lib/services/guard.dart`](../lib/services/guard.dart) exists partly for this.
- **Content rating** questionnaire — answer honestly about the mental-health
  subject matter.
- **Target audience** — not children. An AI companion aimed at under-13s pulls in
  the Families policy and a great deal more review.
- **Crisis resources** — Play looks for these in apps touching self-harm. The
  app already has [`crisis_guard.dart`](../lib/services/crisis_guard.dart); make
  sure the listing mentions that it is not a crisis service.

---

## 6. iOS — not close yet

Worth being clear that this is a port, not a checkbox:

- **There is no Xcode project.** [`ios/`](../ios) holds a stray `AppDelegate.swift`
  and a generated plugin registrant — no `.xcodeproj`, no `Podfile`. Run
  `flutter create --platforms=ios .` to scaffold one.
- **There is no inference engine.** `flutter_litert_lm` is Android-only. Until an
  iOS backend exists the companion cannot run at all on the platform; the diary
  and soundscapes would.
- **Do not make sign-in mandatory.** App Store guideline 5.1.1(v) forbids
  requiring account creation when the core features do not depend on it. The
  current optional-by-default design is already compliant; a launch gate would
  not be.
- Google Sign-In on iOS needs the reversed client ID in `Info.plist` as a URL
  scheme, plus `GoogleService-Info.plist`.

---

## Checklist

- [ ] `android/key.properties` present, keystore backed up somewhere safe
- [ ] Play App Signing enabled
- [ ] Model hosted on a `Range`-capable host; `ModelCatalog` has URL, size, SHA-256
- [ ] Firebase project created; Anonymous **and** Google sign-in enabled
- [ ] Both SHA-1 fingerprints registered (upload key **and** Play app signing key)
- [ ] `android/app/google-services.json` in place
- [ ] Firestore rules deployed
- [ ] `version:` bumped in `pubspec.yaml`
- [ ] Privacy policy published and URL pasted into the console
- [ ] Data safety form filled per the table above
- [ ] Health apps declaration completed
- [ ] `specialUse` foreground service justified in the console (text above)
- [ ] Release build installed and tested on a real device, including a cold
      first-run download
