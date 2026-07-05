# TestFlight "What to Test" (build 1.0.0)

Paste into App Store Connect → TestFlight → build → Test Details.

---

First TestFlight build — the full core loop is in:

- Paste any workout program as text (from ChatGPT/Claude/Gemini, a coach, a
  forum) → Programs → + → paste → Create Program. Parsing runs on-device.
- Start a day on iPhone or Apple Watch. Crown adjusts weight on the watch;
  Double Tap logs a set. Phone mirrors a watch workout live and can edit
  weight/reps/sets mid-set.
- Rest timer starts itself; check the Lock Screen Live Activity — the
  Done Set / Skip Rest / Pause buttons work without unlocking.
- Try Siri: "Start my push day in Fortiche", "Log a set in Fortiche".
- Finish a workout (3+ minutes) → History shows records and weekly volume;
  the workout lands in Apple Health.

Known gaps in this build:
- Watch↔iPhone live sync over the production (HealthKit mirroring) path is
  freshly verified hardware territory — report any case where the two devices
  disagree after a disconnect/reconnect.
- Workouts under 3 minutes are discarded by design.
- iCloud sync of programs between iPhones is untested.

Please report: parsing mistakes (send the program text!), sync divergence,
Live Activity buttons that don't respond, and anything that feels slow or
fiddly with sweaty hands.
