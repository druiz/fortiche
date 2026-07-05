# App Review notes (paste into App Store Connect → App Review Information)

No account or sign-in — the full app is immediately testable.

## Suggested test flow

1. Programs → New Program → paste the sample below → Create Program → Save.
   Parsing runs on-device via Apple Intelligence (FoundationModels). On
   devices/regions without Apple Intelligence a built-in parser handles the
   same text — no network in either case.
2. Tap the play button on a day to start a workout. Adjust weight/reps with
   the steppers, complete a set, observe the rest timer and the Live
   Activity on the Lock Screen (with working Log Set / Skip Rest / Pause
   buttons).
3. End & Save → workout appears in History (records + weekly volume) and in
   Apple Health as a strength-training workout (one workout activity per
   exercise).
4. With a paired Apple Watch: the program appears on the watch; a workout
   started there mirrors live to the iPhone, and edits flow both ways.
5. Siri: "Start my Push day in Fortiche", "Log a set in Fortiche",
   "Skip my rest in Fortiche".

Sample program to paste:

    Push A:
    Bench Press 3x5 @ 80kg
    Overhead Press 3x8-12 @ 40kg
    Dips 3xAMRAP

    Pull A:
    Deadlift 5x3 @ 140kg rest 180s
    Barbell Row 4x8 @ 60kg
    Pullups 3xAMRAP

## Notes for reviewers

- HealthKit: writes workouts; reads heart rate (live display during watch
  workouts) and body mass (plate math). Usage strings are in both Info.plists.
- Workouts shorter than 3 minutes are intentionally discarded (accidental
  starts) — the end dialog says so.
- Exercise database: free-exercise-db, public domain (credited in
  Settings → Acknowledgements).
- No third-party SDKs, no analytics, no network calls except optional lazy
  loading of exercise photos from GitHub's CDN in the exercise detail view.

## App Privacy questionnaire

"Data Not Collected" across the board: the developer operates no server and
receives nothing. All data stays on-device, in the user's private iCloud
(CloudKit), and in Apple Health under the user's control.
